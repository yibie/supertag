;;; multi-instance-test.el --- Revision-stamped multi-instance persistence -*- lexical-binding: t; -*-

;;; Commentary:
;; These regressions intentionally use separate batch Emacs processes.  A
;; shared test process cannot exercise the stale in-memory Store that makes
;; multi-instance persistence hard.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst supertag-multi-instance-test--root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root used by the child Emacs processes.")

(defconst supertag-multi-instance-test--child-program
  ";;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(dolist (directory (split-string (or (getenv \"SUPERTAG_DEPS_LOADPATH\") \"\") path-separator t))
  (add-to-list 'load-path directory))
(add-to-list 'load-path (getenv \"MI_ROOT\"))
(require 'supertag-core-store)
(require 'supertag-core-persistence)
(let* ((db (getenv \"MI_DB\"))
       (directory (file-name-directory db))
       (ready (getenv \"MI_READY\"))
       (go (getenv \"MI_GO\"))
       (result (getenv \"MI_RESULT\"))
       (phase (getenv \"MI_PHASE\"))
       (id (getenv \"MI_ID\")))
  (setq supertag-data-directory directory
        supertag-db-file db
        supertag-db-backup-directory (expand-file-name \"backups/\" directory)
        supertag-db-auto-migrate nil
        supertag-db-verify-after-save t
        supertag-presence-enable nil
        ;; This is normally set by the Sync service before persistence runs.
        ;; Child processes deliberately do no Org scan, so seed the matching
        ;; source identity instead.
        supertag-sync--state-source (expand-file-name \"sync-state.el\" directory))
  (cl-labels
      ((node-ids ()
         (let (ids)
           (maphash (lambda (key _value) (push key ids))
                    (supertag-store-get-collection :nodes))
           (sort ids #'string<)))
       (add-node (node-id)
         (puthash node-id (list :id node-id :type :node :title node-id :file \"/tmp/multi.org\")
                  (supertag-store-get-collection :nodes))
         (supertag-mark-dirty))
       (emit (&rest extra)
         (with-temp-file result
           (prin1 (append (list :revision supertag--store-revision
                                :disk (supertag--disk-revision)
                                :ids (node-ids)
                                :dirty (supertag-dirty-p))
                          extra)
                  (current-buffer))))
       (wait-for-go ()
         (when ready (write-region \"ready\" nil ready nil 'silent))
         (let ((deadline (+ (float-time) 20)))
           (while (and go (not (file-exists-p go)) (< (float-time) deadline))
             (sleep-for 0.05))
           (unless (or (not go) (file-exists-p go))
             (error \"Timed out waiting for multi-instance peer\")))))
    (supertag-load-store)
    (supertag--ensure-store)
    (pcase phase
      (\"save\"
       (add-node id)
       (emit :saved (supertag-save-store)))
      (\"delete\"
       (remhash id (supertag-store-get-collection :nodes))
       (supertag-mark-dirty)
       (emit :saved (supertag-save-store)))
      (\"wait-follow\"
       (wait-for-go)
       (supertag--follow-store)
       (emit))
      (\"wait-dirty-save-force\"
       (add-node \"Y\")
       (wait-for-go)
       (let ((normal (supertag-save-store))
             (force (supertag-save-store-force)))
         (emit :normal normal :force force)))
      (\"legacy-save\"
       (add-node id)
       (emit :saved (supertag-save-store))))))
"
  "Program evaluated by each isolated multi-instance test child.")

(defun supertag-multi-instance-test--emacs ()
  "Return the Emacs executable used for this test's child processes."
  (or (getenv "EMACS_BIN")
      (expand-file-name invocation-name invocation-directory)))

(defun supertag-multi-instance-test--write-child (directory)
  "Write the child test program below DIRECTORY and return its path."
  (let ((file (expand-file-name "multi-instance-child.el" directory)))
    (with-temp-file file
      (insert supertag-multi-instance-test--child-program))
    file))

(defun supertag-multi-instance-test--environment (db phase result &optional ready go id)
  "Return child environment for DB PHASE RESULT and optional rendezvous files."
  (append
   (list (format "MI_ROOT=%s" supertag-multi-instance-test--root)
         (format "MI_DB=%s" db)
         (format "MI_PHASE=%s" phase)
         (format "MI_RESULT=%s" result))
   (when ready (list (format "MI_READY=%s" ready)))
   (when go (list (format "MI_GO=%s" go)))
   (when id (list (format "MI_ID=%s" id)))))

(defun supertag-multi-instance-test--read-result (file)
  "Read a child result plist from FILE, failing with its absence clearly."
  (should (file-exists-p file))
  (with-temp-buffer
    (insert-file-contents file)
    (read (current-buffer))))

(defun supertag-multi-instance-test--run (program environment)
  "Run child PROGRAM synchronously with ENVIRONMENT and return its output."
  (with-temp-buffer
    (let ((process-environment (append environment process-environment)))
      (let ((status (call-process (supertag-multi-instance-test--emacs) nil t nil
                                  "-Q" "--batch" "-l" program)))
        (unless (= status 0)
          (ert-fail (format "multi-instance child failed (%s): %s" status
                            (buffer-string))))
        (buffer-string)))))

(defun supertag-multi-instance-test--start (program environment)
  "Start child PROGRAM asynchronously with ENVIRONMENT and return its process."
  (let ((buffer (generate-new-buffer " *supertag multi instance*"))
        (process-environment (append environment process-environment)))
    (make-process :name "supertag-multi-instance"
                  :buffer buffer
                  :command (list (supertag-multi-instance-test--emacs)
                                 "-Q" "--batch" "-l" program)
                  :noquery t)))

(defun supertag-multi-instance-test--await-file (file process)
  "Wait until FILE exists while checking PROCESS has not failed."
  (let ((deadline (+ (float-time) 20)))
    (while (and (not (file-exists-p file)) (< (float-time) deadline)
                (process-live-p process))
      (accept-process-output process 0.05))
    (unless (file-exists-p file)
      (ert-fail (format "multi-instance rendezvous failed: %s" file)))))

(defun supertag-multi-instance-test--await (process)
  "Wait for PROCESS and assert success, returning its captured output."
  (while (process-live-p process)
    (accept-process-output process 0.05))
  (let ((output (with-current-buffer (process-buffer process) (buffer-string))))
    (unwind-protect
        (progn
          (unless (= 0 (process-exit-status process))
            (ert-fail (format "multi-instance peer failed: %s" output)))
          output)
      (kill-buffer (process-buffer process)))))

(ert-deftest supertag-multi-instance-test-revision-stamped-follow-conflict-force-and-legacy ()
  "Exercise revision following and conflicts across actual isolated Emacsen."
  (let* ((directory (make-temp-file "supertag-multi-instance-" t))
         (db (expand-file-name "supertag-db.el" directory))
         (program (supertag-multi-instance-test--write-child directory)))
    (unwind-protect
        (progn
          ;; (a) B starts at revision 0, then cleanly follows A's saved X.
          (let* ((ready (expand-file-name "a-ready" directory))
                 (go (expand-file-name "a-go" directory))
                 (b-result (expand-file-name "a-b-result" directory))
                 (b (supertag-multi-instance-test--start
                     program (supertag-multi-instance-test--environment
                              db "wait-follow" b-result ready go))))
            (supertag-multi-instance-test--await-file ready b)
            (let ((a-result (expand-file-name "a-a-result" directory)))
              (supertag-multi-instance-test--run
               program (supertag-multi-instance-test--environment db "save" a-result nil nil "X"))
              (should (= 1 (plist-get (supertag-multi-instance-test--read-result a-result) :revision))))
            (write-region "go" nil go nil 'silent)
            (supertag-multi-instance-test--await b)
            (let ((followed (supertag-multi-instance-test--read-result b-result)))
              (should (equal '("X") (plist-get followed :ids)))
              (should (= (plist-get followed :revision) (plist-get followed :disk)))))
          ;; (b) A holds the prior clean view while B deletes X and saves.
          (let* ((ready (expand-file-name "b-ready" directory))
                 (go (expand-file-name "b-go" directory))
                 (a-result (expand-file-name "b-a-result" directory))
                 (a (supertag-multi-instance-test--start
                     program (supertag-multi-instance-test--environment
                              db "wait-follow" a-result ready go))))
            (supertag-multi-instance-test--await-file ready a)
            (let ((b-result (expand-file-name "b-b-result" directory)))
              (let ((output
                     (supertag-multi-instance-test--run
                      program (supertag-multi-instance-test--environment db "delete" b-result nil nil "X"))))
                (should-not (string-match-p "locked by another Emacs" output)))
              (should (= 2 (plist-get (supertag-multi-instance-test--read-result b-result) :revision))))
            (write-region "go" nil go nil 'silent)
            (supertag-multi-instance-test--await a)
            (should-not (member "X" (plist-get (supertag-multi-instance-test--read-result a-result) :ids))))
          ;; (c) A stays dirty with Y while B saves Z.  Its normal save must
          ;; refuse; force intentionally writes Y at the next revision.
          (let* ((ready (expand-file-name "c-ready" directory))
                 (go (expand-file-name "c-go" directory))
                 (a-result (expand-file-name "c-a-result" directory))
                 (a (supertag-multi-instance-test--start
                     program (supertag-multi-instance-test--environment
                              db "wait-dirty-save-force" a-result ready go))))
            (supertag-multi-instance-test--await-file ready a)
            (let ((b-result (expand-file-name "c-b-result" directory)))
              (supertag-multi-instance-test--run
               program (supertag-multi-instance-test--environment db "save" b-result nil nil "Z"))
              (let ((saved (supertag-multi-instance-test--read-result b-result)))
                (should (= 3 (plist-get saved :revision)))
                (should (member "Z" (plist-get saved :ids)))
                (should-not (member "Y" (plist-get saved :ids)))))
            (write-region "go" nil go nil 'silent)
            (supertag-multi-instance-test--await a)
            (let ((forced (supertag-multi-instance-test--read-result a-result)))
              (should-not (plist-get forced :normal))
              (should (plist-get forced :force))
              (should (= 4 (plist-get forced :revision)))
              (should (member "Y" (plist-get forced :ids)))
              (should-not (member "Z" (plist-get forced :ids))))
            (let ((disk-result (expand-file-name "c-disk-result" directory)))
              (supertag-multi-instance-test--run
               program (supertag-multi-instance-test--environment db "wait-follow" disk-result))
              (let ((disk (supertag-multi-instance-test--read-result disk-result)))
                (should (= 4 (plist-get disk :revision)))
                (should (member "Y" (plist-get disk :ids)))
                (should-not (member "Z" (plist-get disk :ids))))))
          ;; (d) A legacy root without revision starts at zero and first save
          ;; emits revision one.  Use a fresh database so the assertion is
          ;; independent of the previous conflict sequence.
          (let* ((legacy (expand-file-name "legacy.el" directory))
                 (result (expand-file-name "legacy-result" directory)))
            (with-temp-file legacy
              (prin1 (let ((store (make-hash-table :test 'equal)))
                       (puthash :nodes (make-hash-table :test 'equal) store)
                       store)
                     (current-buffer)))
            (supertag-multi-instance-test--run
             program (supertag-multi-instance-test--environment legacy "legacy-save" result nil nil "legacy"))
            (let ((saved (supertag-multi-instance-test--read-result result)))
              (should (= 1 (plist-get saved :revision)))
              (should (= 1 (plist-get saved :disk))))))
      (ignore-errors (delete-directory directory t)))))

(provide 'multi-instance-test)

;;; multi-instance-test.el ends here
