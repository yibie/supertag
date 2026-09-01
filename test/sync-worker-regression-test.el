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

(require 'ert)
(require 'cl-lib)
(require 'bytecomp)
(require 'supertag-services-sync)

(declare-function supertag-create-node "supertag-ui-commands")

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
    (supertag-store-put-field-value "node" "semantic-note" "keep")
    (supertag-sync--reconcile-node parsed)
    (should-not
     (plist-member (supertag-store-get-entity :nodes "node") :semantic-note))
    (should (equal "keep"
                   (supertag-store-get-field-value "node" "semantic-note")))))

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
          (should-not (supertag-sync--snapshot-status)))
      (ignore-errors (delete-file first))
      (ignore-errors (delete-file second)))))

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

(ert-deftest supertag-create-node-persists-id-before-projecting-heading ()
  "Explicit node creation reparses the heading after writing its Org ID."
  (require 'supertag-ui-commands)
  (let ((supertag--store nil))
    (supertag--ensure-store)
    (with-temp-buffer
      (org-mode)
      (setq buffer-file-name "/tmp/supertag-explicit-node.org")
      (insert "* Persistent heading\nBody\n")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'org-id-new) (lambda (&rest _) "persistent-id")))
        (should (equal "persistent-id" (supertag-create-node)))
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
          (supertag-store-put-field-value "child" "semantic-note" "keep")
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
          (supertag-store-put-field-value "child" "semantic-note" "keep")
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
                         (supertag-store-get-field-value
                          "child" "semantic-note")))
          (should (equal '("Parent" "Child") (plist-get point-node :olp)))
          (should (equal "file-id" (plist-get point-node :parent-id))))
      (when (buffer-live-p source-buffer)
        (kill-buffer source-buffer))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-sync-deferred-file-is-retained-for-explicit-retry ()
  "A failed worker retains its filename and exposes an explicit retry."
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
            (should (equal supertag-async--failed-items (list file)))
            (should (= 1 (supertag-async-failed-count)))
            (let ((log
                   (with-current-buffer (messages-buffer)
                     (buffer-substring-no-properties
                      messages-start (point-max)))))
              (should (string-match-p (regexp-quote file) log))
              (should (string-match-p "Org source file was not modified" log))
              (should (string-match-p "supertag-async-retry-failed" log)))
            (should (= 1 (supertag-async-retry-failed)))
            (should (equal supertag-async--queue (list file)))
            (should (null supertag-async--failed-items))))
      (ignore-errors (delete-file file)))))

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
