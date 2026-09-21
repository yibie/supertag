;;; sync-worker-regression-test.el --- sync worker regressions -*- lexical-binding: t; -*-

;;; Commentary:
;; Behavioral regressions for the guarded sync worker: early return from
;; byte-compiled code and deferred heading deletion retries after restart or
;; async worker failure.
;;
;; Run:
;;   emacs -Q --batch -L . --eval "(package-initialize)" \
;;     -l test/sync-worker-regression-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'legacy-field-fixture)
(require 'ert)
(require 'cl-lib)
(require 'bytecomp)
(require 'supertag-services-sync)

(declare-function supertag-service-org-create-node-at-point "supertag-service-org")

(defconst supertag-sync-worker-test--root
  (expand-file-name
   ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root.")

(defun supertag-sync-worker-test--without-volatile-node-data (node)
  "Return NODE without wall-clock fields that differ between test runs."
  (let ((copy (copy-tree node)))
    (setq copy (plist-put copy :created-at nil))
    (plist-put copy :modified-at nil)))

(ert-deftest supertag-sync-verify-file-nodes-skips-when-guarded ()
  "Byte-compiled `supertag-sync--verify-file-nodes' returns nil when
destructive sync is disallowed, instead of signalling a void
--cl-block-...-- variable (the async worker crash)."
  (let ((fn-form nil))
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name "supertag-services-sync.el"
                         supertag-sync-worker-test--root))
      (goto-char (point-min))
      (condition-case nil
          (while (not fn-form)
            (let ((form (read (current-buffer))))
              (when (and (memq (car-safe form) '(defun cl-defun))
                         (eq (cadr form) 'supertag-sync--verify-file-nodes))
                (setq fn-form form))))
        (end-of-file nil)))
    (should fn-form)
    ;; Scope both the guard stub and the definition under test so the
    ;; test leaves no redefinitions behind in a live session.
    (cl-letf (((symbol-function 'supertag-sync--allow-destructive-p)
               (lambda () nil))
              ((symbol-function 'supertag-sync--verify-file-nodes) nil))
      (eval fn-form t)
      (let ((byte-compile-warnings nil))
        (byte-compile 'supertag-sync--verify-file-nodes))
      (should (null (supertag-sync--verify-file-nodes
                     "/tmp/supertag-cl-block-test-nonexistent.org"
                     (list :nodes-deleted 0)))))))

(ert-deftest supertag-sync-deferred-deletion-retries-after-restart ()
  "A guarded deletion remains retryable when another node also changes.
The deferred-files table is session-local, so persisted sync state must keep
the old mtime until destructive cleanup is allowed."
  (let* ((file (make-temp-file "supertag-deferred-" nil ".org" "* Keep\n"))
         (state-table (make-hash-table :test 'equal))
         (supertag-sync--state (list :sync-state state-table))
         (supertag-sync--deferred-files (make-hash-table :test 'equal))
         (mtime (file-attribute-modification-time (file-attributes file)))
         (state-saved nil))
    (unwind-protect
        (progn
          (puthash file
                   (list :mtime (time-subtract mtime (seconds-to-time 60))
                         :size 1 :content-hash "old" :hash-algo 'sha1)
                   state-table)
          (cl-letf (((symbol-function 'supertag-sync--allow-destructive-p)
                     (lambda () nil))
                    ((symbol-function 'supertag-sync--parse-file-header)
                     (lambda () nil))
                    ((symbol-function 'supertag--parse-org-nodes-from-current-buffer)
                     (lambda (_file)
                       (list (list :id "keep" :file file :level 1
                                   :title "new"))))
                    ((symbol-function 'supertag-sync--upsert-file-node)
                     (lambda (&rest _) nil))
                    ((symbol-function 'supertag-find-nodes-by-file)
                     (lambda (_file)
                       (list (cons "gone" (list :id "gone" :file file :level 1))
                             (cons "keep" (list :id "keep" :file file :level 1
                                                :title "old")))))
                    ((symbol-function 'supertag-node-changed-p)
                     (lambda (&rest _) t))
                    ((symbol-function 'supertag-db-add-with-hash)
                     (lambda (&rest _) nil))
                    ((symbol-function 'supertag-node-mark-deleted-from-file)
                     (lambda (&rest _)
                       (ert-fail "destructive deletion ran while guarded")))
                    ((symbol-function 'supertag-sync-save-state)
                     (lambda () (setq state-saved t))))
            (supertag-sync--async-processor file))
          (should state-saved)
          (should (gethash file supertag-sync--deferred-files))
          ;; Restart drops only the in-memory retry marker.
          (clrhash supertag-sync--deferred-files)
          (cl-letf (((symbol-function 'supertag-sync--in-sync-scope-p)
                     (lambda (_file) t)))
            (should (equal (list file) (supertag-get-modified-files)))))
      (ignore-errors (delete-file file)))))

(ert-deftest supertag-reindex-org-parses-unchanged-files ()
  "Reindex reparses files even when their content hash is unchanged."
  (let* ((file (make-temp-file "supertag-reindex-" nil ".org" "* Note\n"))
         (state-table (make-hash-table :test 'equal))
         (supertag-sync--state (list :sync-state state-table))
         (supertag-sync--deferred-files (make-hash-table :test 'equal))
         (supertag-sync--is-full-rescan-p t)
         (parsed nil))
    (unwind-protect
        (progn
          (with-temp-buffer
            (insert-file-contents file)
            (puthash file
                     (list :content-hash (secure-hash 'sha1 (current-buffer)))
                     state-table))
          (cl-letf (((symbol-function 'supertag-sync--allow-destructive-p)
                     (lambda () t))
                    ((symbol-function 'supertag-sync--parse-file-header)
                     (lambda () nil))
                    ((symbol-function 'supertag--parse-org-nodes-from-current-buffer)
                     (lambda (_file) (setq parsed t) nil))
                    ((symbol-function 'supertag-sync--upsert-file-node)
                     (lambda (&rest _) nil))
                    ((symbol-function 'supertag-find-nodes-by-file)
                     (lambda (_file) nil)))
            (supertag-sync--process-single-file
             file (list :nodes-created 0 :nodes-updated 0 :nodes-deleted 0)))
          (should parsed))
      (ignore-errors (delete-file file)))))

(ert-deftest supertag-reindex-replaces-unchanged-node-projection ()
  "A full reindex drops legacy node extensions even when the hash matches."
  (let* ((supertag--store nil)
         (supertag-sync--is-full-rescan-p t)
         (parsed '(:id "node" :type :node :title "Node" :file "/tmp/node.org"
                   :level 1 :content "Body" :properties nil :tags nil
                   :ref-to nil))
         (legacy (plist-put (copy-tree parsed) :semantic-note "legacy")))
    (supertag--ensure-store)
    (setq legacy (plist-put legacy :hash (supertag-node-hash parsed)))
    (supertag-node-create legacy)
    (supertag-test-legacy-value "node" "semantic-note" "keep")
    (supertag-sync--reconcile-node parsed)
    (should-not
     (plist-member (supertag-store-get-entity :nodes "node") :semantic-note))
    (should (equal "keep"
                   (supertag-test-read-legacy-value "node" "semantic-note")))))

(ert-deftest supertag-reindex-org-aborts-incomplete-snapshot-without-deletion ()
  "An incomplete snapshot returns a report without touching projections."
  (let* ((file (make-temp-file "supertag-reindex-partial-" nil ".org" "* Note\n"))
         (supertag--store nil)
         (supertag-sync--state
          (list :sync-state (make-hash-table :test 'equal)))
         report legacy-report)
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-store-put-entity
           :nodes "keep" (list :id "keep" :type :node :file file))
          (cl-letf (((symbol-function 'supertag-sync--ensure-state-source) #'ignore)
                    ((symbol-function 'supertag-sync--snapshot-build)
                     (lambda ()
                       (list :status 'partial :files (list file)
                             :errors '((:error "unreadable child")))))
                    ((symbol-function 'supertag-sync--process-single-file)
                     (lambda (&rest _) (ert-fail "partial snapshot was processed")))
                    ((symbol-function 'supertag-sync-validate-nodes)
                     (lambda (&rest _) (ert-fail "partial snapshot validated")))
                    ((symbol-function 'supertag-sync-garbage-collect-orphaned-nodes)
                     (lambda () (ert-fail "partial snapshot ran GC")))
                    ((symbol-function 'supertag-sync-save-state)
                     (lambda () (ert-fail "partial snapshot saved state"))))
            (setq report (supertag-reindex-org))
            (setq legacy-report (supertag-sync-full-rescan)))
          (should (eq 'aborted (plist-get report :status)))
          (should (eq 'partial (plist-get report :snapshot-status)))
          (should (= 0 (plist-get report :files-processed)))
          (should (equal report legacy-report))
          (should (supertag-node-get "keep")))
      (ignore-errors (delete-file file)))))

(ert-deftest supertag-reindex-org-rolls-back-on-processing-error ()
  "A file failure rolls back earlier projection mutations and skips cleanup."
  (let* ((first (make-temp-file "supertag-reindex-first-" nil ".org" "* One\n"))
         (second (make-temp-file "supertag-reindex-second-" nil ".org" "* Two\n"))
         (supertag--store nil)
         (supertag-sync--state
          (list :sync-state (make-hash-table :test 'equal)))
         (supertag-automation-sync--enabled t)
         (calls 0)
         report)
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-store-put-entity
           :nodes "keep" (list :id "keep" :type :node :file first))
          (cl-letf (((symbol-function 'supertag-sync--ensure-state-source) #'ignore)
                    ((symbol-function 'supertag-sync--snapshot-build)
                     (lambda ()
                       (list :status 'complete :files (list first second)
                             :errors nil)))
                    ((symbol-function 'supertag-sync--process-single-file)
                     (lambda (&rest _)
                       (should-not supertag-automation-sync--enabled)
                       (setq calls (1+ calls))
                       (if (= calls 1)
                           (supertag-store-remove-entity :nodes "keep")
                         (error "deliberate reindex failure"))))
                    ((symbol-function 'supertag-sync-validate-nodes)
                     (lambda (&rest _) (ert-fail "failed reindex validated")))
                    ((symbol-function 'supertag-sync-garbage-collect-orphaned-nodes)
                     (lambda () (ert-fail "failed reindex ran GC")))
                    ((symbol-function 'supertag-sync-save-state)
                     (lambda () (ert-fail "failed reindex saved state"))))
            (setq report (supertag-reindex-org)))
          (should (eq 'failed (plist-get report :status)))
          (should (= 1 (plist-get report :files-processed)))
          (should (string-match-p
                   "deliberate reindex failure"
                   (car (plist-get report :errors))))
          (should (supertag-node-get "keep"))
          (should supertag-automation-sync--enabled)
          (should-not (supertag-sync--snapshot-status)))
      (ignore-errors (delete-file first))
      (ignore-errors (delete-file second)))))

(ert-deftest supertag-reindex-restores-automation-gate-after-quit ()
  "A nonlocal quit cannot leave the shared Automation gate disabled."
  (let* ((file (make-temp-file "supertag-reindex-quit-" nil ".org" "* One\n"))
         (supertag--store nil)
         (supertag-sync--state
          (list :sync-state (make-hash-table :test 'equal)))
         (supertag-automation-sync--enabled t)
         caught)
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (cl-letf (((symbol-function 'supertag-sync--ensure-state-source) #'ignore)
                    ((symbol-function 'supertag-sync--snapshot-build)
                     (lambda () (list :status 'complete :files (list file))))
                    ((symbol-function 'supertag-sync--process-single-file)
                     (lambda (&rest _)
                       (should-not supertag-automation-sync--enabled)
                       (signal 'quit nil))))
            (condition-case nil
                (supertag-reindex-org)
              (quit (setq caught t))))
          (should caught)
          (should supertag-automation-sync--enabled))
      (ignore-errors (delete-file file)))))

(ert-deftest supertag-projector-idless-headings-never-get-ephemeral-ids ()
  "Repeated projection skips ID-less headings without inventing identities."
  (with-temp-buffer
    (org-mode)
    (insert "* No persistent identity\nBody\n")
    (let ((supertag-sync-auto-create-node t)
          (before (buffer-string))
          (generated 0))
      (cl-letf (((symbol-function 'org-id-new)
                 (lambda (&rest _)
                   (setq generated (1+ generated))
                   (format "ephemeral-%d" generated))))
        (should-not (supertag--parse-org-nodes-from-current-buffer
                     "/tmp/idless.org"))
        (should-not (supertag--parse-org-nodes-from-current-buffer
                     "/tmp/idless.org"))
        (should (= generated 0))
        (should (equal before (buffer-string)))))))

(ert-deftest supertag-service-org-create-node-at-point-persists-id-before-projecting-heading ()
  "Explicit node creation reparses the heading after writing its Org ID."
  (require 'supertag-service-org)
  (let ((supertag--store nil))
    (supertag--ensure-store)
    (with-temp-buffer
      (org-mode)
      (setq buffer-file-name "/tmp/supertag-explicit-node.org")
      (insert "* Persistent heading\nBody\n")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'org-id-new) (lambda (&rest _) "persistent-id")))
        (should (equal "persistent-id" (supertag-service-org-create-node-at-point)))
        (let ((node (supertag-node-get "persistent-id")))
          (should (equal "Persistent heading" (plist-get node :title)))
          (should (equal "Body\n" (plist-get node :content)))
          (should (equal "persistent-id" (org-entry-get nil "ID"))))))))

(ert-deftest supertag-projector-hash-covers-schedule-deadline-and-references ()
  "Every Document Fact that drives reconciliation changes the node hash."
  (let* ((base '(:id "node" :file "/tmp/node.org" :level 1
                 :title "Node" :raw-value "Node" :olp ("Node")
                 :tags nil :todo nil :priority nil :scheduled nil
                 :deadline nil :content "Body\n" :properties nil
                 :ref-to nil :position 1 :pos 1 :parent-id "file"
                 :link-type id))
         (old (plist-put (copy-tree base) :hash (supertag-node-hash base))))
    (dolist (change '((:scheduled . "<2026-08-13 Thu>")
                      (:deadline . "<2026-08-14 Fri>")
                      (:ref-to . ("target"))))
      (let ((new (plist-put (copy-tree base) (car change) (cdr change))))
        (should (supertag-node-changed-p old new))))))

(ert-deftest supertag-projector-point-and-file-sync-have-node-parity ()
  "Point and file entry points apply the same node reconciliation."
  (let* ((tmp (make-temp-file "supertag-projector-parity-" t))
         (file (expand-file-name "note.org" (file-truename tmp)))
         (supertag-data-directory tmp)
         (supertag-db-file (expand-file-name "supertag-db.el" tmp))
         (supertag-db-backup-directory (expand-file-name "backups" tmp))
         (supertag-sync--state
          (list :sync-state (make-hash-table :test 'equal)))
         (supertag-sync--deferred-files (make-hash-table :test 'equal))
         (seed (list :id "child" :type :node :title "Old" :raw-value "Old"
                     :file nil :level 2 :semantic-note "legacy-node-extension"))
         full-node point-node source-buffer)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert ":PROPERTIES:\n:ID: file-id\n:END:\n#+TITLE: Note\n"
                    "* Parent\n:PROPERTIES:\n:ID: parent\n:END:\n"
                    "** Child\nSCHEDULED: <2026-08-13 Thu>\n"
                    ":PROPERTIES:\n:ID: child\n:CUSTOM: value\n:END:\nBody\n"))
          (setq seed (plist-put seed :hash (supertag-node-hash seed)))
          (setq supertag--store nil)
          (supertag--ensure-store)
          (supertag-node-create (copy-tree seed))
          (supertag-test-legacy-value "child" "semantic-note" "keep")
          (cl-letf (((symbol-function 'supertag-sync--allow-destructive-p)
                     (lambda () t)))
            (supertag-sync--process-single-file
             file '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                    :references-created 0 :references-deleted 0)))
          (setq full-node
                (supertag-sync-worker-test--without-volatile-node-data
                 (supertag-node-get "child")))

          (setq supertag--store nil)
          (supertag--ensure-store)
          (supertag-node-create (copy-tree seed))
          (supertag-test-legacy-value "child" "semantic-note" "keep")
          (setq source-buffer (find-file-noselect file))
          (with-current-buffer source-buffer
            (org-mode)
            (goto-char (point-min))
            (re-search-forward "^:ID: child$" nil t)
            (org-back-to-heading t)
            (supertag-node-sync-at-point))
          (setq point-node
                (supertag-sync-worker-test--without-volatile-node-data
                 (supertag-node-get "child")))
          (should (equal full-node point-node))
          (should-not (plist-member point-node :semantic-note))
          (should (equal "keep"
                         (supertag-test-read-legacy-value
                          "child" "semantic-note")))
          (should (equal '("Parent" "Child") (plist-get point-node :olp)))
          (should (equal "file-id" (plist-get point-node :parent-id))))
      (when (buffer-live-p source-buffer)
        (kill-buffer source-buffer))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-sync-deferred-file-is-dropped-by-complete-full-rescan ()
  "A failed worker retains its filename; a complete full rescan drops it."
  (let* ((file (make-temp-file "supertag-deferred-worker-" nil ".org" "* Keep\n"))
         (directory (file-name-directory file))
         (supertag-sync--state
          (list :sync-state (make-hash-table :test 'equal)))
         (supertag-sync--deferred-files (make-hash-table :test 'equal))
         (supertag-async--queue nil)
         (supertag-async--failed-items nil)
         (supertag-async--timer nil)
         (supertag-async--processor-fn
          (lambda (_file) (error "deliberate worker failure")))
         (supertag-async-batch-size 1)
         (supertag-sync-quiet-when-idle t)
         (messages-start
          (with-current-buffer (messages-buffer) (point-max))))
    (unwind-protect
        (progn
          (puthash file :pending supertag-sync--deferred-files)
          (cl-letf (((symbol-function 'supertag-sync--effective-directories)
                     (lambda () (list directory)))
                    ((symbol-function 'supertag-sync--snapshot-build)
                     (lambda () (list :status 'complete :files (list file))))
                    ((symbol-function 'supertag-get-modified-files)
                     (lambda () nil))
                    ((symbol-function 'supertag-sync--snapshot-files-to-remove)
                     (lambda (_files) nil))
                    ((symbol-function 'supertag-sync--snapshot-new-files)
                     (lambda (_files) nil))
                    ((symbol-function 'supertag-sync--in-sync-scope-p)
                     (lambda (_file) t))
                    ((symbol-function 'supertag-sync-garbage-collect-orphaned-nodes)
                     (lambda () nil))
                    ((symbol-function 'supertag-async--ensure-timer)
                     (lambda () nil)))
            (supertag-sync--check-and-sync-guarded)
            (should (equal supertag-async--queue (list file)))
            (supertag-async--worker)
            (should (null supertag-async--queue))
            (setq supertag-async--queue (list "queued"))
            (should (equal supertag-async--failed-items (list file)))
            (should (= 1 (length supertag-async--failed-items)))
            (let ((log
                   (with-current-buffer (messages-buffer)
                     (buffer-substring-no-properties
                      messages-start (point-max)))))
              (should (string-match-p (regexp-quote file) log))
              (should (string-match-p "Org source file was not modified" log))
              (should (string-match-p "supertag-sync-full-rescan" log)))
            (let ((report (list :status 'aborted
                                :snapshot-status 'partial
                                :files-discovered 0 :files-processed 0
                                :errors nil)))
              (cl-letf (((symbol-function 'supertag-reindex-org)
                         (lambda () report)))
                (should (eq (supertag-sync-full-rescan) report))))
            (should (equal supertag-async--queue (list "queued")))
            (should (equal supertag-async--failed-items (list file)))
            (let ((report (list :status 'failed
                                :snapshot-status 'complete
                                :files-discovered 1 :files-processed 0
                                :errors (list "boom"))))
              (cl-letf (((symbol-function 'supertag-reindex-org)
                         (lambda () report)))
                (should (eq (supertag-sync-full-rescan) report))))
            (should (equal supertag-async--queue (list "queued")))
            (should (equal supertag-async--failed-items (list file)))
            (let ((report (list :status 'complete
                                :snapshot-status 'complete
                                :files-discovered 1 :files-processed 1
                                :nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                                :references-created 0 :references-deleted 0
                                :garbage-collected 0)))
              (cl-letf (((symbol-function 'supertag-reindex-org)
                         (lambda () report)))
                (should (eq (supertag-sync-full-rescan) report))))
            (should (equal supertag-async--queue (list "queued")))
            (should (null supertag-async--failed-items))))
      (ignore-errors (delete-file file)))))

(ert-deftest supertag-async-worker-preserves-queue-when-item-reenqueues-mid-processing ()
  "Re-enqueuing the active item must not discard the next queued item."
  (let* ((supertag-async--queue '(first second))
         (supertag-async--failed-items nil)
         (supertag-async--timer nil)
         (supertag-async-batch-size 1)
         processed
         (supertag-async--processor-fn
          (lambda (item)
            (push item processed)
            (when (eq item 'first)
              (supertag-async-enqueue item)))))
    (cl-letf (((symbol-function 'supertag-async--ensure-timer)
               (lambda () nil)))
      (supertag-async--worker))
    (should (equal '(first) processed))
    (should (equal '(second first) supertag-async--queue))
    (should-not supertag-async--failed-items)))

(ert-deftest supertag-sync-validate-nodes-keeps-legacy-file-nodes ()
  "Validate legacy file nodes without identity metadata by file existence.
Such nodes predate `:link-type', so a live file is the only safe evidence.
A deleted-file node and a heading whose ID is absent are still orphaned."
  (let* ((file (make-temp-file "supertag-validate-" nil ".org"
                               "#+title: ai\n* Heading\nno id drawer here\n"))
         (gone-file (concat (make-temp-name
                             (expand-file-name "supertag-validate-gone-"
                                               temporary-file-directory))
                            ".org"))
         (marked '()))
    (unwind-protect
        (cl-letf (((symbol-function 'supertag-traverse-nodes)
                   (lambda (fn)
                     (funcall fn "FILE-NODE-UUID"
                              (list :id "FILE-NODE-UUID" :type :node
                                    :level 0 :file file :title "ai"))
                     (funcall fn "FILE-NODE-GONE"
                              (list :id "FILE-NODE-GONE" :type :node
                                    :level 0 :file gone-file :title "gone-file"))
                     (funcall fn "MISSING-HEADING"
                              (list :id "MISSING-HEADING" :type :node
                                    :level 1 :file file :title "gone"))))
                  ((symbol-function 'supertag-node-mark-deleted-from-file)
                   (lambda (id) (push id marked))))
          (supertag-sync-validate-nodes)
          ;; File node with a live file is kept; the deleted-file node and the
          ;; genuinely missing heading are orphaned.
          (should-not (member "FILE-NODE-UUID" marked))
          (should (member "FILE-NODE-GONE" marked))
          (should (member "MISSING-HEADING" marked))
          (should (= (length marked) 2)))
      (ignore-errors (delete-file file)))))

(defun supertag-sync-worker-test--identity-replacement
    (link-type contents old-id new-id)
  "Verify identity replacement for LINK-TYPE using CONTENTS and node IDs."
  (let* ((tmp (make-temp-file "supertag-validate-identity-" t))
         (file (expand-file-name "note.org" tmp))
         (supertag-data-directory tmp)
         (supertag-db-file (expand-file-name "supertag-db.el" tmp))
         (supertag--store nil)
         (counters (list :nodes-deleted 0)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert contents))
          (supertag--ensure-store)
          (supertag-node-create
           (list :id old-id :type :node :level 0 :link-type link-type
                 :file file :title "Old"))
          (supertag-node-create
           (list :id new-id :type :node :level 0 :link-type link-type
                 :file file :title "New"))
          (supertag-sync-validate-nodes counters)
          (should-not (plist-get (supertag-node-get old-id) :file))
          (should (equal (plist-get (supertag-node-get new-id) :file) file))
          (should (equal (car (supertag-find-file-node file)) new-id))
          (should (= (plist-get counters :nodes-deleted) 1)))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-sync-validate-nodes-orphans-replaced-org-id ()
  "A file node stops owning a file after its top-level Org ID changes."
  (supertag-sync-worker-test--identity-replacement
   'id ":PROPERTIES:\n:ID: new-file-id\n:END:\n#+TITLE: Note\n"
   "old-file-id" "new-file-id"))

(ert-deftest supertag-sync-validate-nodes-orphans-replaced-denote-id ()
  "A file node stops owning a file after its Denote identifier changes."
  (supertag-sync-worker-test--identity-replacement
   'denote "#+TITLE: Note\n#+IDENTIFIER: new-denote-id\n"
   "old-denote-id" "new-denote-id"))

(provide 'sync-worker-regression-test)
;;; sync-worker-regression-test.el ends here

;;; V2-SYNC-B independent queue entry, lifecycle and real projection controls.
(defconst supertag-sync-worker-test--syb-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(let* ((tree (getenv \"SYB_TREE\")) (tmp (file-truename (getenv \"SYB_TMP\"))) (case (getenv \"SYB_CASE\"))\n       (before (equal (getenv \"SUPERTAG_SYB_STAGE\") \"before\"))\n       (entry (if (string-prefix-p \"git\" case) 'supertag-git\n                (if (member case '(\"owner\" \"preset\" \"queue\" \"quit\"))\n                    (if before 'supertag-core-async 'supertag-services-sync) 'supertag-services-sync)))\n       (root (expand-file-name \"org/\" tmp)) (file (expand-file-name \"one.org\" root))\n       (data (expand-file-name \"data/\" tmp)) (state-file (expand-file-name \"sync-state.el\" data))\n       (fn-names '(supertag-async-init supertag-async-enqueue supertag-async-clear\n                   supertag-async-clear-failed supertag-async--ensure-timer supertag-async--worker))\n       (vars '(supertag-async--queue supertag-async--failed-items supertag-async--timer\n               supertag-async--processor-fn supertag-async-idle-delay supertag-async-batch-size))\n       (preset nil) (seen nil) (failure nil))\n  (setq user-emacs-directory (file-name-as-directory tmp) default-directory tmp after-init-time nil\n        supertag-data-directory data supertag-db-file (expand-file-name \"store.el\" data)\n        supertag-db-backup-directory (expand-file-name \"backups/\" data)\n        supertag-sync-state-file state-file org-id-locations-file (expand-file-name \"ids\" tmp)\n        org-id-track-globally nil supertag-sync-directories (list root)\n        supertag-active-sync-directory nil supertag-sync-directories-mode 'unified\n        supertag-sync-auto-start nil supertag-file-id-source 'disabled supertag-tag-auto-enable nil)\n  (make-directory root t)\n  (cl-labels\n      ((bytes (p) (when (file-exists-p p) (with-temp-buffer (insert-file-contents-literally p) (buffer-string))))\n       (note (title) (with-temp-file file (insert (format \"* %s\\n:PROPERTIES:\\n:ID: syb-node\\n:END:\\nBody\\n\" title))))\n       (fire () (let ((timer supertag-async--timer))\n                  (should (timerp timer)) (should (memq timer timer-idle-list))\n                  (should (eq 'supertag-async--worker (timer--function timer)))\n                  (should-not (timer--repeat-delay timer))\n                  ;; Deterministic invocation of actual one-shot callback, not proof of idle-loop scheduling.\n                  (cancel-timer timer) (funcall (timer--function timer))))\n       (graph (label)\n         (princ (format \"SYB-GRAPH %s %S processor=%S\\n\" label\n                        (mapcar (lambda (f) (cons f (featurep f)))\n                                '(supertag-core-async supertag-services-sync supertag-git org supertag-query supertag-link supertag-service-org))\n                        (and (boundp 'supertag-async--processor-fn) supertag-async--processor-fn)))))\n    (unwind-protect\n        (progn\n          (when (equal case \"preset\")\n            (setq supertag-async--queue (list \"prequeued\") supertag-async--failed-items (list \"prefailed\")\n                  supertag-async--timer (run-with-idle-timer 600 nil #'ignore)\n                  supertag-async--processor-fn (lambda (item) (push item seen))\n                  supertag-async-idle-delay 77 supertag-async-batch-size 3)\n            (setq preset (mapcar #'symbol-value vars)))\n          (when (string-match-p \"qd\" case)\n            (when (string-suffix-p \"orgfirst\" case) (require 'org))\n            (setq org-babel-load-languages '((supertag-query-block . t))))\n          (graph 'pre-entry)\n          (condition-case err (require entry) (error (setq failure err)))\n          (princ (format \"SYB-ENTRY case=%s entry=%s failure=%S org=%S query=%S queue-bound=%S\\n\"\n                         case entry failure (featurep 'org) (featurep 'supertag-query) (boundp 'supertag-async--queue)))\n          (if (string-match-p \"qd\" case)\n              (progn\n                (princ (format \"SYB-QD facts=%S\\n\" (list failure (featurep 'org) (featurep 'supertag-query)\n                                                          (mapcar #'fboundp fn-names) (boundp 'supertag-async--queue))))\n                (should-not failure)\n                (should (featurep 'org)) (should (featurep 'supertag-query))\n                (dolist (n fn-names) (should (fboundp n)))\n                (should-not supertag-async--processor-fn))\n            (should-not failure)\n            (dolist (n fn-names)\n              (should (fboundp n))\n              (should (equal (if (and before (not (getenv \"SYB_OWNER_RED\"))) \"supertag-core-async.el\" \"supertag-services-sync.el\")\n                             (file-name-nondirectory (symbol-file n 'defun)))))\n            (dolist (v vars) (should (boundp v)))\n            (should (get 'supertag-async 'custom-group))\n            (should (equal \"Asynchronous processing settings for Supertag.\" (get 'supertag-async 'group-documentation)))\n            (should (eq 'number (get 'supertag-async-idle-delay 'custom-type)))\n            (should (eq 'integer (get 'supertag-async-batch-size 'custom-type)))\n            (unless before\n              (should-not (featurep 'supertag-core-async)) (should-not (locate-library \"supertag-core-async\"))\n              (should-not (cl-find-if (lambda (x) (and (stringp (car x)) (equal \"supertag-core-async.el\" (file-name-nondirectory (car x))))) load-history)))\n            (pcase case\n              (\"owner\"\n               (should-not supertag-async--queue) (should-not supertag-async--failed-items)\n               (should-not supertag-async--processor-fn) (should-not supertag-async--timer)\n               (when before (should-not (featurep 'org)) (should-not (featurep 'supertag-services-sync))))\n              (\"preset\"\n               (should (cl-every #'identity (cl-mapcar #'eq preset (mapcar #'symbol-value vars))))\n               (let ((cell (symbol-function 'supertag-async-enqueue)))\n                 (require entry) (should (eq cell (symbol-function 'supertag-async-enqueue))))\n               (load (expand-file-name (concat (symbol-name entry) \".el\") tree) nil nil t)\n               (should (cl-every #'identity (cl-mapcar #'eq preset (mapcar #'symbol-value vars))))\n               (should (= 77 supertag-async-idle-delay)) (should (= 3 supertag-async-batch-size)))\n              (\"queue\"\n               (setq supertag-async-idle-delay 600 supertag-async-batch-size 2)\n               (should (= 1 (supertag-async-enqueue \"A\")))\n               (let ((timer supertag-async--timer))\n                 (should (= 600 (float-time (timer--time timer))))\n                 (supertag-async-enqueue \"B\") (supertag-async-enqueue \"A\")\n                 (should (eq timer supertag-async--timer)) (should (equal '(\"B\" \"A\") supertag-async--queue))\n                 (fire) (should (equal '(\"B\" \"A\") supertag-async--queue))\n                 (should-not (eq timer supertag-async--timer)) (should-not supertag-async--timer))\n               (let ((timer supertag-async--timer))\n                 (setq supertag-async--failed-items '(\"A\"))\n                 (supertag-async-init\n                  (lambda (item) (push item seen) (when (equal item \"A\") (error \"SYB ordinary failure\"))))\n                 (should (eq timer supertag-async--timer))\n                 (should-not supertag-async--queue) (should-not supertag-async--failed-items)\n                 (supertag-async-enqueue \"A\") (supertag-async-enqueue \"B\") (fire)\n                 (should (equal '(\"B\" \"A\") seen)) (should-not supertag-async--queue)\n                 (should (equal '(\"A\") supertag-async--failed-items))\n                 (supertag-async-enqueue \"A\") (should-not supertag-async--failed-items)\n                 (setq supertag-async--failed-items '(\"X\" \"Y\"))\n                 (should (= 2 (supertag-async-clear-failed))) (should-not supertag-async--failed-items)\n                 (let ((timer supertag-async--timer))\n                   (supertag-async-clear) (should (eq timer supertag-async--timer))\n                   (should-not supertag-async--queue))\n                 (setq seen nil supertag-async-batch-size 1)\n                 (supertag-async-init (lambda (item) (push item seen) (when (equal item \"A\") (supertag-async-enqueue \"A\"))))\n                 (supertag-async-enqueue \"A\") (supertag-async-enqueue \"B\") (fire)\n                 (should (equal '(\"B\" \"A\") supertag-async--queue))\n                 (fire) (should (equal '(\"A\") supertag-async--queue))\n                 (should (equal '(\"B\" \"A\") seen))))\n              (\"quit\"\n               (setq supertag-async-idle-delay 600 supertag-async-batch-size 2)\n               (supertag-async-init (lambda (item) (push item seen) (signal 'quit nil)))\n               (supertag-async-enqueue \"A\") (supertag-async-enqueue \"B\")\n               (let ((caught nil)) (condition-case nil (fire) (quit (setq caught t))) (should caught))\n               (should (equal '(\"A\") seen)) (should (equal '(\"B\") supertag-async--queue))\n               (should-not supertag-async--failed-items) (should-not supertag-async--timer))\n              (_\n               (note \"Alpha\") (setq supertag-async-idle-delay 600)\n               (should-not supertag-async--processor-fn)\n               (if (equal case \"git\")\n                   (progn (supertag-git--project-files root '(\"one.org\") nil)\n                          (should (equal (list file) supertag-async--queue))\n                          (should-not (supertag-node-get \"syb-node\")))\n                 (supertag-async-enqueue file))\n               (let ((idle supertag-async--timer))\n                 (supertag-sync-start-auto-sync 600)\n                 (should-not supertag-async--queue) (should (eq idle supertag-async--timer))\n                 (should (eq 'supertag-sync--async-processor supertag-async--processor-fn))\n                 (should (timerp supertag-sync--timer)) (should (= 600 (timer--repeat-delay supertag-sync--timer)))\n                 ;; Cancel only the periodic test timer before deterministic real idle callback.\n                 (cancel-timer supertag-sync--timer)\n                 (if (equal case \"git\") (supertag-git--project-files root '(\"one.org\") nil) (supertag-async-enqueue file))\n                 (fire)\n                 (should (equal \"Alpha\" (plist-get (supertag-node-get \"syb-node\") :title)))\n                 (should (= 1 (length (supertag-find-nodes-by-file file))))\n                 (should (gethash file (supertag-sync--get-state-table))) (should (bytes state-file))\n                 (should-not supertag-async--queue) (should-not supertag-async--failed-items)\n                 (princ (format \"SYB-ACTUAL title=%S index=%S state=%S\\n\"\n                                (plist-get (supertag-node-get \"syb-node\") :title)\n                                (supertag-find-nodes-by-file file) (gethash file (supertag-sync--get-state-table))))\n                 (when (getenv \"SYB_WRONG_OUTPUT\") (should (equal \"Impossible\" (plist-get (supertag-node-get \"syb-node\") :title))))\n                 (when (equal case \"projection\")\n                   (let ((disk (bytes state-file)))\n                     (note \"Changed\") (supertag-async-enqueue file)\n                     (cl-letf (((symbol-function 'supertag-sync-save-state)\n                                (lambda () (should-not supertag--transaction-active)\n                                  (princ \"SYB-INJECT after-real-process-before-save\\n\") (error \"SYB named save failure\")))) (fire))\n                     (should (equal \"Changed\" (plist-get (supertag-node-get \"syb-node\") :title)))\n                     (should (equal disk (bytes state-file))) (should (equal (list file) supertag-async--failed-items))\n                     (should-not supertag-async--queue)\n                     (supertag-async-enqueue file) (should-not supertag-async--failed-items) (fire)\n                     (should-not supertag-async--queue) (should-not supertag-async--failed-items)\n                     (supertag-async-enqueue (concat file \".missing\")) (fire)\n                     (should-not supertag-async--failed-items)))\n                 (let ((timer nil))\n                   (supertag-async-enqueue file) (setq timer supertag-async--timer)\n                   (puthash \"x\" t supertag-sync--deferred-files) (puthash \"y\" t supertag-sync--internal-modifications)\n                   (supertag-sync--reset-runtime)\n                   (should (= 0 (hash-table-count supertag-sync--deferred-files)))\n                   (should (= 0 (hash-table-count supertag-sync--internal-modifications)))\n                   (should (equal (list file) supertag-async--queue)) (should (eq timer supertag-async--timer))\n                   (setq supertag-async--failed-items '(\"old\"))\n                   (supertag-sync-stop-auto-sync)\n                   (should-not supertag-sync--timer) (should-not supertag-async--queue) (should-not supertag-async--failed-items)\n                   (should (eq timer supertag-async--timer)) (should (memq timer timer-idle-list)))))))\n          (graph 'complete)\n          (princ (format \"SYB-DONE %s\\n\" case)))\n      (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)\n      (mapc #'cancel-timer (append timer-list timer-idle-list)))))\n")

(defun supertag-sync-worker-test--syb-child (case)
  "Run CASE against real source in an isolated fresh child process."
  (let* ((tmp (make-temp-file "supertag-syb-" t))
         (tree (expand-file-name "tree/" tmp))
         (source (or (getenv "SUPERTAG_SYB_ROOT") supertag-sync-worker-test--root))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) (evidence (getenv "SUPERTAG_SYB_EVIDENCE")))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (f (directory-files source t "\\.el\\'")) (copy-file f (expand-file-name (file-name-nondirectory f) tree)))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "SYB_TREE" tree) (setenv "SYB_TMP" tmp) (setenv "SYB_CASE" case)
          (let ((script (expand-file-name "child.el" tmp)))
            (with-temp-file script (insert supertag-sync-worker-test--syb-program))
            (with-temp-buffer
              (let ((status (apply #'call-process program nil t nil
                                   (append '("-Q" "--batch")
                                           (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                           (list "-L" tree "-l" script)))))
                (when evidence
                  (let ((out (expand-file-name (concat case "/") evidence)))
                    (make-directory out t)
                    (copy-file script (expand-file-name "child.el" out) t)
                    (write-region (point-min) (point-max) (expand-file-name "child.log" out) nil 'silent)
                    (with-temp-file (expand-file-name "child.exit" out) (insert (format "%s\n" status)))))
                (princ (buffer-string))
                (should (equal 0 status))
                (should (string-match-p (format "SYB-ENTRY case=%s " case) (buffer-string)))
                (should (string-match-p (format "SYB-DONE %s" case) (buffer-string)))))))
      (delete-directory tmp t))))

(ert-deftest supertag-sync-syb-owner () (supertag-sync-worker-test--syb-child "owner"))

(ert-deftest supertag-sync-syb-preset () (supertag-sync-worker-test--syb-child "preset"))

(ert-deftest supertag-sync-syb-queue () (supertag-sync-worker-test--syb-child "queue"))

(ert-deftest supertag-sync-syb-quit () (supertag-sync-worker-test--syb-child "quit"))

(ert-deftest supertag-sync-syb-projection () (supertag-sync-worker-test--syb-child "projection"))

(ert-deftest supertag-sync-syb-git () (supertag-sync-worker-test--syb-child "git"))

(ert-deftest supertag-sync-syb-qd-sync-noorg () (supertag-sync-worker-test--syb-child "qd-sync-noorg"))

(ert-deftest supertag-sync-syb-qd-sync-orgfirst () (supertag-sync-worker-test--syb-child "qd-sync-orgfirst"))

(ert-deftest supertag-sync-syb-git-qd-noorg () (supertag-sync-worker-test--syb-child "git-qd-noorg"))

(ert-deftest supertag-sync-syb-git-qd-orgfirst () (supertag-sync-worker-test--syb-child "git-qd-orgfirst"))
