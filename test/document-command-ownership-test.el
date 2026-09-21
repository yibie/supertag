;;; document-command-ownership-test.el --- Document command ownership contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-ui-commands)

(defmacro supertag-document-command-test--with-file (contents &rest body)
  "Run BODY in an isolated file-backed Org buffer containing CONTENTS."
  (declare (indent 1) (debug t))
  `(let* ((tmp (make-temp-file "supertag-document-command-test" t))
          (file (expand-file-name "nodes.org" tmp))
          (supertag--store nil)
          (supertag--subscribers (make-hash-table :test 'equal))
          (supertag-sync--internal-modifications
           (make-hash-table :test 'equal))
          buffer)
     (unwind-protect
         (progn
           (with-temp-file file
             (insert ,contents))
           (supertag--ensure-store)
           (setq buffer (find-file-noselect file))
           (with-current-buffer buffer
             (org-mode)
             (goto-char (point-min))
             ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-document-command-test--seed-node (file)
  "Create the projected test node for FILE."
  (supertag-node-create
   `(:id "node-id" :title "Node" :file ,file :level 1 :position 1)))

(ert-deftest supertag-create-node-save-failure-does-not-create-projection ()
  "Creating a node cannot project an ID that failed to save."
  (supertag-document-command-test--with-file "* Draft\nBody\n"
    (let (signaled)
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () "new-id"))
                ((symbol-function 'save-buffer)
                 (lambda (&rest _)
                   (error "deliberate save failure"))))
        (condition-case nil
            (supertag-create-node)
          (error (setq signaled t))))
      (should signaled)
      (should-not (supertag-node-get "new-id")))))

(ert-deftest supertag-create-node-saves-before-projecting ()
  "The public create command saves once before creating its Projection."
  (supertag-document-command-test--with-file "* Draft\n"
    (let (order)
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () "new-id"))
                ((symbol-function 'save-buffer)
                 (lambda (&rest _)
                   (setq order (append order '(save)))))
                ((symbol-function 'supertag-node-create)
                 (lambda (props)
                   (setq order (append order '(project)))
                   props)))
        (should (equal "new-id" (supertag-create-node))))
      (should (equal '(save project) order)))))

(ert-deftest supertag-create-new-node-saves-before-projecting ()
  "The new-heading branch uses the same save-before-project contract."
  (supertag-document-command-test--with-file "Preamble\n"
    (let (order)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Fresh"))
                ((symbol-function 'supertag-node-identity-new)
                 (lambda () "new-id"))
                ((symbol-function 'save-buffer)
                 (lambda (&rest _)
                   (setq order (append order '(save)))))
                ((symbol-function 'supertag-node-create)
                 (lambda (props)
                   (setq order (append order '(project)))
                   props)))
        (should (equal "new-id" (supertag-create-node))))
      (should (equal '(save project) order))
      (goto-char (point-min))
      (should (looking-at-p "\\* Fresh")))))

(ert-deftest supertag-create-projection-failure-keeps-saved-document ()
  "A failed create Projection reports how to retry the saved Org Fact."
  (supertag-document-command-test--with-file "* Draft\n"
    (let ((real-save (symbol-function 'save-buffer))
          caught)
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () "new-id"))
                ((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (apply real-save args)))
                ((symbol-function 'supertag-node-sync-current-buffer)
                 (lambda (node-id)
                   ;; Mutate first so this test proves the outer Projection
                   ;; transaction rolls back a late Projector failure.
                   (supertag-node-create
                    `(:id ,node-id :title "partial" :file ,file
                      :level 1 :position 1))
                   (error "deliberate late projection failure"))))
        (condition-case err
            (supertag-create-node)
          (error (setq caught err))))
      (should (eq 'supertag-projection-error (car caught)))
      (let ((data (cdr caught)))
        (should (equal "new-id" (plist-get data :node-id)))
        (should (equal file (plist-get data :file)))
        (should (eq 'supertag-service-org-retry-node-projection
                    (plist-get data :retry)))
        (should (equal (list "new-id" file)
                       (plist-get data :retry-args))))
      (should-not (supertag-node-get "new-id"))
      (with-temp-buffer
        (insert-file-contents file)
        (should (search-forward "new-id" nil t)))
      (let ((data (cdr caught)))
        (apply (plist-get data :retry) (plist-get data :retry-args)))
      (should (equal "Draft"
                     (plist-get (supertag-node-get "new-id") :title))))))

(ert-deftest supertag-delete-node-save-failure-keeps-projection ()
  "A failed subtree save cannot delete the existing node Projection."
  (supertag-document-command-test--with-file
      "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\nBody\n"
    (supertag-document-command-test--seed-node file)
    (let (signaled)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'save-buffer)
                 (lambda (&rest _)
                   (error "deliberate save failure"))))
        (condition-case nil
            (supertag-delete-node)
          (error (setq signaled t))))
      (should signaled)
      (should (supertag-node-get "node-id"))
      (goto-char (point-min))
      (should (search-forward "node-id" nil t))
      (with-temp-buffer
        (insert-file-contents file)
        (should (search-forward "node-id" nil t))))))

(ert-deftest supertag-delete-node-saves-before-projecting ()
  "The public delete command saves before deleting its Projection."
  (supertag-document-command-test--with-file
      "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\nBody\n"
    (let (order)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'save-buffer)
                 (lambda (&rest _)
                   (setq order (append order '(save)))))
                ((symbol-function 'supertag-node-delete)
                 (lambda (&rest _)
                   (setq order (append order '(project))))))
        (supertag-delete-node))
      (should (equal '(save project) order)))))

(ert-deftest supertag-demote-node-save-failure-keeps-projection ()
  "A failed ID-property save cannot delete the node Projection."
  (supertag-document-command-test--with-file
      "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\nBody\n"
    (supertag-document-command-test--seed-node file)
    (let (signaled)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'save-buffer)
                 (lambda (&rest _)
                   (error "deliberate save failure"))))
        (condition-case nil
            (supertag-back-to-heading)
          (error (setq signaled t))))
      (should signaled)
      (should (supertag-node-get "node-id"))
      (goto-char (point-min))
      (should (equal "node-id" (org-entry-get nil "ID")))
      (with-temp-buffer
        (insert-file-contents file)
        (should (search-forward "node-id" nil t))))))

(ert-deftest supertag-demote-node-saves-before-projecting ()
  "The public demote command saves before deleting its Projection."
  (supertag-document-command-test--with-file
      "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\nBody\n"
    (let (order)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'save-buffer)
                 (lambda (&rest _)
                   (setq order (append order '(save)))))
                ((symbol-function 'supertag-node-delete)
                 (lambda (&rest _)
                   (setq order (append order '(project))))))
        (supertag-back-to-heading))
      (should (equal '(save project) order)))))

(ert-deftest supertag-demote-node-persists-heading-without-projection ()
  "A successful demotion keeps Org content but removes ID and Projection."
  (supertag-document-command-test--with-file
      "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\nBody\n"
    (supertag-document-command-test--seed-node file)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (supertag-back-to-heading))
    (should-not (supertag-node-get "node-id"))
    (goto-char (point-min))
    (should (looking-at-p "\\* Node"))
    (should-not (org-entry-get nil "ID"))
    (should (search-forward "Body" nil t))
    (with-temp-buffer
      (insert-file-contents file)
      (should (search-forward "* Node" nil t))
      (should (search-forward "Body" nil t))
      (should-not (search-forward "node-id" nil t)))))

(ert-deftest supertag-delete-projection-failure-keeps-saved-document-and-old-projection ()
  "Projection failure after save is retryable and does not restore Org text."
  (supertag-document-command-test--with-file
      "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\nBody\n"
    (supertag-document-command-test--seed-node file)
    (let ((real-save (symbol-function 'save-buffer))
          caught)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (apply real-save args)))
                ((symbol-function 'supertag-node-delete)
                 (lambda (&rest _)
                   (error "deliberate projection failure"))))
        (condition-case err
            (supertag-delete-node)
          (error (setq caught err))))
      (should (eq 'supertag-projection-error (car caught)))
      (let ((data (cdr caught)))
        (should (equal "node-id" (plist-get data :node-id)))
        (should (equal file (plist-get data :file)))
        (should (eq 'supertag-service-org-retry-delete-node-projection
                    (plist-get data :retry)))
        (should (equal '("node-id") (plist-get data :retry-args))))
      (should (supertag-node-get "node-id"))
      (with-temp-buffer
        (insert-file-contents file)
        (should-not (search-forward "node-id" nil t)))
      (let ((data (cdr caught)))
        (apply (plist-get data :retry) (plist-get data :retry-args)))
      (should-not (supertag-node-get "node-id")))))

(provide 'document-command-ownership-test)
;;; document-command-ownership-test.el ends here
