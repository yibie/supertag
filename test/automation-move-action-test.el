;;; automation-move-action-test.el --- Automation move adapter errors -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-service-org)
(require 'supertag-automation)

(defun supertag-automation-move-test--disk (file)
  "Return FILE's literal text."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (buffer-string)))

(defmacro supertag-automation-move-test--with-node (&rest body)
  "Run BODY with one projected node and two real synthetic Org files."
  (declare (indent 0) (debug t))
  `(let* ((tmp (make-temp-file "supertag-automation-move-test-" t))
          (source (expand-file-name "source.org" tmp))
          (target (expand-file-name "target.org" tmp))
          (source-text
           "* Move me\n:PROPERTIES:\n:ID:       move-id\n:END:\nBody\n* Stay\n")
          (target-text "* Existing\n")
          (supertag--store nil)
          (supertag--subscribers (make-hash-table :test 'equal))
          (supertag-sync--internal-modifications (make-hash-table :test 'equal))
          buffers)
     (unwind-protect
         (progn
           (with-temp-file source (insert source-text))
           (with-temp-file target (insert target-text))
           (supertag--ensure-store)
           (supertag-node-create
            `(:id "move-id" :title "Move me" :file ,source
              :position 1 :level 1 :tags nil))
           (setq buffers (list (find-file-noselect source)
                               (find-file-noselect target)))
           ,@body)
       (dolist (buffer buffers)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-automation-move-save-failure-propagates-and-stops-actions ()
  "A real compensated save failure prevents the next synchronous action."
  (supertag-automation-move-test--with-node
    (let ((real-save (symbol-function 'save-buffer))
          (saves 0)
          later
          caught)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (apply real-save args)
                   (when (= 2 (cl-incf saves))
                     (error "move-save-sentinel")))))
        (setq caught
              (condition-case err
                  (progn
                    (supertag-automation--execute-actions
                     `((:action :move-node :params (:target-file ,target))
                       (:action :call-function
                        :params (:function ,(lambda (&rest _) (setq later t)))))
                     "move-id" nil)
                    nil)
                (error err))))
      (should caught)
      (should (equal "move-save-sentinel" (error-message-string caught)))
      (should-not later)
      (should (equal source-text
                     (supertag-automation-move-test--disk source)))
      (should (equal target-text
                     (supertag-automation-move-test--disk target))))))

(ert-deftest supertag-automation-move-projection-error-keeps-retry-payload ()
  "The adapter propagates the singular service's structured Projection error."
  (supertag-automation-move-test--with-node
    (let (caught)
      (cl-letf (((symbol-function 'supertag-service-org--retry-move-projection)
                 (lambda (&rest _) (error "move-project-sentinel"))))
        (condition-case err
            (supertag-automation-action-move-node
             "move-id" (list :target-file target))
          (error (setq caught err))))
      (should (eq 'supertag-projection-error (car caught)))
      (should (eq 'supertag-service-org--retry-move-projection
                  (plist-get (cdr caught) :retry)))
      (should (equal (list source target)
                     (plist-get (cdr caught) :retry-args)))
      (should-not (string-match-p ":ID:       move-id"
                                  (supertag-automation-move-test--disk source)))
      (should (string-match-p ":ID:       move-id"
                              (supertag-automation-move-test--disk target)))
      (apply (plist-get (cdr caught) :retry)
             (plist-get (cdr caught) :retry-args))
      (should (equal (file-truename target)
                     (plist-get (supertag-node-get "move-id") :file))))))

(ert-deftest supertag-automation-move-real-success-uses-singular-service ()
  "The adapter returns success after one real cross-file relocation."
  (supertag-automation-move-test--with-node
    (should (supertag-automation-action-move-node
             "move-id" (list :target-file target)))
    (should-not (string-match-p ":ID:       move-id"
                                (supertag-automation-move-test--disk source)))
    (should (string-match-p ":ID:       move-id"
                            (supertag-automation-move-test--disk target)))
    (should (equal (file-truename target)
                   (plist-get (supertag-node-get "move-id") :file)))))

(ert-deftest supertag-automation-move-same-file-and-alias-are-noops ()
  "A valid source path or physical alias does not invoke same-file relocation."
  (supertag-automation-move-test--with-node
    (let ((alias (expand-file-name "source-alias.org" tmp))
          called)
      (make-symbolic-link source alias)
      (cl-letf (((symbol-function 'supertag-service-org-move-node-to-file)
                 (lambda (&rest _) (setq called t))))
        (should-not
         (supertag-automation-action-move-node
          "move-id" (list :target-file source)))
        (should-not
         (supertag-automation-action-move-node
          "move-id" (list :target-file alias))))
      (should-not called)
      (should (equal source-text
                     (supertag-automation-move-test--disk source))))))

(ert-deftest supertag-automation-move-invalid-input-and-source-signal ()
  "Missing node, target, and valid source location are explicit errors."
  (supertag-automation-move-test--with-node
    (should-error
     (supertag-automation-action-move-node nil (list :target-file target))
     :type 'user-error)
    (should-error
     (supertag-automation-action-move-node "move-id" nil)
     :type 'user-error)
    (should-error
     (supertag-automation-action-move-node
      "missing-id" (list :target-file target))
     :type 'user-error)
    (supertag-node-update
     "move-id" (lambda (node)
                 (plist-put (copy-tree node) :file
                            (expand-file-name "missing.org" tmp))))
    (should-error
     (supertag-automation-action-move-node
      "move-id" (list :target-file target))
     :type 'user-error)))

(ert-deftest supertag-automation-move-real-trigger-relocates-org ()
  "A committed matching database event executes the real Org move writer."
  (supertag-automation-move-test--with-node
    (supertag-tag-create '(:id "move-trigger" :name "move-trigger"))
    (supertag-subscribe :store-changed
                        #'supertag-automation--handle-entity-change)
    (supertag-automation-create
     `(:name "move-trigger-rule"
       :trigger (:on-tag-added "move-trigger")
       :actions ((:action :move-node :params (:target-file ,target)))))
    (supertag-node-add-tag "move-id" "move-trigger")
    (should-not (string-match-p ":ID:       move-id"
                                (supertag-automation-move-test--disk source)))
    (should (string-match-p ":ID:       move-id"
                            (supertag-automation-move-test--disk target)))
    (should (equal (file-truename target)
                   (plist-get (supertag-node-get "move-id") :file)))))

(provide 'automation-move-action-test)
;;; automation-move-action-test.el ends here
