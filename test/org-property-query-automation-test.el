;;; org-property-query-automation-test.el --- Org property query path -*- lexical-binding: t; -*-

;;; Code:

(require 'legacy-field-fixture)
(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-services-sync)
(require 'supertag-query)
(require 'supertag-service-org)
(require 'supertag-automation)

(defmacro supertag-org-property-query-test--with-vault (&rest body)
  "Run BODY with an isolated, synchronized two-node Org vault."
  (declare (indent 0) (debug t))
  `(supertag-ownership-test-with-vault
     (let ((supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--state-source
            (expand-file-name "sync-state.el" supertag-data-directory))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-sync--internal-modifications (make-hash-table :test 'equal))
           (supertag--subscribers (make-hash-table :test 'equal)))
       (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore))
         (should (eq 'complete (plist-get (supertag-reindex-org) :status))))
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (buffer-list))
           (when-let* ((file (buffer-file-name buffer)))
             (when (file-in-directory-p file vault)
               (with-current-buffer buffer (set-buffer-modified-p nil))
               (kill-buffer buffer))))))))

(defun supertag-org-property-query-test--set-and-sync (file name value)
  "Set local property NAME to VALUE in FILE, save, and synchronize."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (if value
         (org-entry-put nil name value)
       (org-entry-delete nil name))
     (save-buffer)))
  (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))))

(defun supertag-org-property-query-test--disk-property (file name)
  "Read local property NAME from FILE's first heading."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (goto-char (point-min))
    (org-entry-get nil name nil)))

(ert-deftest supertag-query-property-normalizes-key-and-validates-strings ()
  "The property operator has one canonical key and two-string arguments."
  (should (eq :STAGE (supertag-query-normalize-property-key "stage")))
  (dolist (query '((property "" "ready")
                   (property STAGE "ready")
                   (property "STAGE" ready)
                   (property "STAGE")
                   (property "STAGE" "ready" "extra")))
    (should-error (supertag-query-node-ids query))))

(ert-deftest supertag-query-property-is-exact-and-distinguishes-empty-missing ()
  "Saved projected text matches exactly; explicit empty differs from absent."
  (supertag-org-property-query-test--with-vault
    (let ((first (car files))
          (second (cadr files)))
      (supertag-org-property-query-test--set-and-sync first "stage" "ready")
      (supertag-org-property-query-test--set-and-sync second "STAGE" "Ready")
      (should (equal (list supertag-ownership-test-node-a)
                     (supertag-query-node-ids '(property "stage" "ready"))))
      (should (equal (list supertag-ownership-test-node-b)
                     (supertag-query-node-ids '(property "STAGE" "Ready"))))
      (should-not (supertag-query-node-ids '(property "STAGE" "READY")))
      (supertag-org-property-query-test--set-and-sync first "EMPTY" "")
      (should (equal (list supertag-ownership-test-node-a)
                     (supertag-query-node-ids '(property "empty" ""))))
      (should-not (member supertag-ownership-test-node-b
                          (supertag-query-node-ids '(property "EMPTY" "")))))))

(ert-deftest supertag-query-property-tracks-saved-update-and-deletion ()
  "Manual saved Org edits change queries and shared Automation conditions."
  (supertag-org-property-query-test--with-vault
    (let ((file (car files))
          (condition '(and (property "STAGE" "ready")
                           (not (property "BLOCKED" "yes")))))
      (supertag-org-property-query-test--set-and-sync file "STAGE" "ready")
      (should (supertag-automation--evaluate-condition
               condition supertag-ownership-test-node-a))
      (supertag-org-property-query-test--set-and-sync file "STAGE" "done")
      (should-not (supertag-query-node-ids '(property "STAGE" "ready")))
      (should-not (supertag-automation--evaluate-condition
                   condition supertag-ownership-test-node-a))
      (supertag-org-property-query-test--set-and-sync file "STAGE" nil)
      (should-not (plist-member
                   (plist-get (supertag-node-get supertag-ownership-test-node-a)
                              :properties)
                   :STAGE)))))

(ert-deftest supertag-query-property-never-falls-back-to-global-field ()
  "A conflicting legacy field value cannot supply an Org property match."
  (supertag-org-property-query-test--with-vault
    (supertag-test-legacy-definition
     "STAGE" '(:id "STAGE" :name "STAGE" :type :text))
    (supertag-test-legacy-value
     supertag-ownership-test-node-a "STAGE" "ready")
    (should-not (supertag-query-node-ids '(property "STAGE" "ready")))
    (supertag-org-property-query-test--set-and-sync
     (cadr files) "STAGE" "ready")
    (should (equal (list supertag-ownership-test-node-b)
                   (supertag-query-node-ids '(property "STAGE" "ready"))))))

(ert-deftest supertag-automation-property-source-index-and-real-action ()
  "A normalized property event selects a rule whose action writes real Org."
  (supertag-org-property-query-test--with-vault
    (let ((file (car files)))
      (supertag-org-property-query-test--set-and-sync file "STAGE" "ready")
      (let ((rule
             (supertag-automation-create
              '(:name "project-ready"
                :trigger :on-property-change
                :condition (property "stage" "ready")
                :actions ((:action :update-property
                           :params (:property "RESULT" :value "matched")))))))
        (should (equal '(:STAGE)
                       (supertag--extract-trigger-sources
                        '(property "stage" "ready"))))
        (supertag-automation--handle-node-change
         (list :nodes supertag-ownership-test-node-a :properties :STAGE)
         nil "ready")
        (should (equal "matched"
                       (supertag-org-property-query-test--disk-property
                        file "RESULT")))
        (should (equal "matched"
                       (plist-get
                        (plist-get
                         (supertag-node-get supertag-ownership-test-node-a)
                         :properties)
                        :RESULT)))
        (should (plist-get rule :id))))))

(provide 'org-property-query-automation-test)

;;; org-property-query-automation-test.el ends here
