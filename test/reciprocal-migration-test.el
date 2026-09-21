;;; reciprocal-migration-test.el --- reciprocal link migration tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-migration)
(require 'supertag-services-sync)

(defun supertag-reference-migration-test--file-hash (file)
  "Return a byte-exact hash for FILE."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun supertag-reference-migration-test--store-hash ()
  "Return a deterministic hash for the complete Store."
  (let ((print-circle t)
        (print-length nil)
        (print-level nil))
    (secure-hash
     'sha256
     (prin1-to-string
      (supertag--persistence--canonicalize-value supertag--store)))))

(defmacro supertag-reference-migration-test--with-mutual-vault (&rest body)
  "Run BODY with one explicit link in each direction."
  (declare (indent 0) (debug t))
  `(supertag-ownership-test-with-vault
     (let ((supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-sync--internal-modifications (make-hash-table :test 'equal)))
       (with-temp-buffer
         (insert-file-contents (cadr files))
         (goto-char (point-max))
         (insert "Links back to [[id:ownership-node-a][Project Alpha]].\n")
         (write-region nil nil (cadr files) nil 'silent))
       (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
       ,@body)))

(ert-deftest supertag-reference-migration-preview-is-read-only ()
  "Preview reports exact directed occurrences without changing files or Store."
  (supertag-reference-migration-test--with-mutual-vault
    (let ((file-hashes (mapcar #'supertag-reference-migration-test--file-hash files))
          (store-hash (supertag-reference-migration-test--store-hash))
          report buffer)
      (setq report
            (cl-letf (((symbol-function 'display-buffer) #'ignore))
              (call-interactively #'supertag-migration-preview-reciprocal-links)))
      (setq buffer (get-buffer "*Supertag Reciprocal Link Migration*"))
      (should (eq 'preview (plist-get report :status)))
      (should (= 2 (plist-get report :candidate-count)))
      (should (= 2 (length (plist-get report :candidates))))
      (should (buffer-live-p buffer))
      (with-current-buffer buffer
        (should (derived-mode-p 'special-mode))
        (should buffer-read-only))
      (should (equal file-hashes
                     (mapcar #'supertag-reference-migration-test--file-hash files)))
      (should (equal store-hash
                     (supertag-reference-migration-test--store-hash)))
      (kill-buffer buffer))))

(ert-deftest supertag-reference-migration-abort-never-writes ()
  "Empty selection and rejected confirmation both leave all state untouched."
  (supertag-reference-migration-test--with-mutual-vault
    (let* ((preview (supertag-migration-preview-reciprocal-links))
           (candidate (car (plist-get preview :candidates)))
           (file-hashes (mapcar #'supertag-reference-migration-test--file-hash files))
           (store-hash (supertag-reference-migration-test--store-hash))
           (executed nil)
           report)
      (setq report (supertag-migration-execute-reciprocal-links preview nil))
      (should (eq 'aborted (plist-get report :status)))
      (should (eq 'no-selection (plist-get report :reason)))
      (setq report
            (cl-letf (((symbol-function 'display-buffer) #'ignore)
                      ((symbol-function 'completing-read-multiple)
                       (lambda (&rest _) (list (plist-get candidate :label))))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                      ((symbol-function 'supertag-migration-execute-reciprocal-links)
                       (lambda (&rest _) (setq executed t))))
              (call-interactively #'supertag-migrate-reciprocal-links)))
      (should-not executed)
      (should (eq 'aborted (plist-get report :status)))
      (should (eq 'confirmation-declined (plist-get report :reason)))
      (should (equal file-hashes
                     (mapcar #'supertag-reference-migration-test--file-hash files)))
      (should (equal store-hash
                     (supertag-reference-migration-test--store-hash)))
      (when-let* ((buffer (get-buffer "*Supertag Reciprocal Link Migration*")))
        (kill-buffer buffer)))))

(ert-deftest supertag-reference-migration-removes-only-confirmed-occurrence ()
  "Execution deletes only the exact directed occurrence selected by ID."
  (supertag-reference-migration-test--with-mutual-vault
    (let* ((preview (supertag-migration-preview-reciprocal-links))
           (candidate
            (cl-find-if
             (lambda (item)
               (and (equal supertag-ownership-test-node-b (plist-get item :from))
                    (equal supertag-ownership-test-node-a (plist-get item :to))))
             (plist-get preview :candidates)))
           (project-hash (supertag-reference-migration-test--file-hash (car files)))
           (report
            (supertag-migration-execute-reciprocal-links
             preview (list (plist-get candidate :id)))))
      (should (eq 'complete (plist-get report :status)))
      (should (= 1 (plist-get report :removed)))
      (should (= 1 (plist-get report :files-changed)))
      (should (= 1 (length (plist-get report :backups))))
      (should (file-exists-p (cdar (plist-get report :backups))))
      (should (equal project-hash
                     (supertag-reference-migration-test--file-hash (car files))))
      (with-temp-buffer
        (insert-file-contents (cadr files))
        (should-not (search-forward "[[id:ownership-node-a]" nil t)))
      (should (supertag-relation-find-between
               supertag-ownership-test-node-a
               supertag-ownership-test-node-b :reference))
      (should-not (supertag-relation-find-between
                   supertag-ownership-test-node-b
                   supertag-ownership-test-node-a :reference)))))

(ert-deftest supertag-reference-migration-restores-files-on-projection-error ()
  "A projection failure restores exact file bytes and Store relations."
  (supertag-reference-migration-test--with-mutual-vault
    (let* ((preview (supertag-migration-preview-reciprocal-links))
           (ids (mapcar (lambda (item) (plist-get item :id))
                        (plist-get preview :candidates)))
           (file-hashes (mapcar #'supertag-reference-migration-test--file-hash files))
           (store-hash (supertag-reference-migration-test--store-hash))
           (visited (find-file-noselect (car files)))
           (project (symbol-function 'supertag-sync--process-single-file))
           (calls 0)
           report)
      (unwind-protect
          (progn
            (setq report
                  (cl-letf (((symbol-function 'supertag-sync--process-single-file)
                             (lambda (&rest args)
                               (cl-incf calls)
                               (if (= calls 1)
                                   (apply project args)
                                 (error "deliberate projection failure")))))
                    (supertag-migration-execute-reciprocal-links preview ids)))
            (should (eq 'failed (plist-get report :status)))
            (should (= 0 (plist-get report :removed)))
            (should (string-match-p
                     "deliberate projection failure"
                     (car (plist-get report :errors))))
            (should (equal file-hashes
                           (mapcar #'supertag-reference-migration-test--file-hash files)))
            (should (equal store-hash
                           (supertag-reference-migration-test--store-hash)))
            (with-current-buffer visited
              (should-not (buffer-modified-p))
              (should (search-forward "[[id:ownership-node-b]" nil t))))
        (kill-buffer visited)))))

(provide 'reciprocal-migration-test)

;;; reciprocal-migration-test.el ends here
