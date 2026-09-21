;;; view-schema-impact-test.el --- Schema impact and removal regressions -*- lexical-binding: t; -*-

;;; Commentary:
;; Focused regressions for Schema View type-change previews and the explicit
;; distinction between tag unbinding and global field deletion.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ht)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-view-schema)

(defmacro supertag-view-schema-impact-test--with-store (&rest body)
  "Run BODY with a fresh in-memory Supertag store."
  (declare (indent 0))
  `(let ((supertag--store nil)
         (supertag--transaction-active nil)
         (supertag--transaction-log nil)
         (supertag--transaction-seen nil))
     (supertag--ensure-store)
     ,@body))

(defun supertag-view-schema-impact-test--put-value
    (node-id field-id value)
  "Put VALUE directly into the isolated test Store."
  (let ((bucket (ht-create)))
    (puthash field-id value bucket)
    (puthash node-id bucket
             (supertag-store-get-collection :field-values))))

(ert-deftest supertag-view-schema-impact-classifies-values-with-node-ids ()
  "The preview counts values and names convertible/failing nodes."
  (supertag-view-schema-impact-test--with-store
    (supertag-view-schema-impact-test--put-value "n-ok" "status" "open")
    (supertag-view-schema-impact-test--put-value "n-list" "status" '("open"))
    (supertag-view-schema-impact-test--put-value "n-bad" "status" "closed")
    (let* ((impact
            (supertag-schema--field-type-impact
             "status" '(:type :options :options ("open"))))
           (convertible (plist-get impact :convertible))
           (failed (plist-get impact :failed)))
      (should (= 3 (plist-get impact :total)))
      (should (= 2 (length convertible)))
      (should (= 1 (length failed)))
      (should (equal '("n-ok" "n-list")
                     (mapcar (lambda (entry) (plist-get entry :node-id))
                             convertible)))
      (should (equal "n-bad" (plist-get (car failed) :node-id)))
      (should (string-match-p "schema rejected"
                              (plist-get (car failed) :error))))))

(ert-deftest supertag-view-schema-type-change-cancelled-before-update ()
  "Declining an impact prompt performs no schema write and no refresh."
  (let ((old '(:id "status" :name "Status" :type :string))
        (new '(:name "Status" :type :boolean))
        prompt
        updated)
    (cl-letf (((symbol-function 'supertag-schema--get-context-at-point)
               (lambda () '(:type :field :tag-id "task"
                            :field-name "Status")))
              ((symbol-function 'supertag-tag-get-field)
               (lambda (&rest _) old))
              ((symbol-function 'supertag-global-field-get)
               (lambda (_field-id) old))
              ((symbol-function 'supertag-global-field-edit-interactive)
               (lambda (_field-id)
                 (supertag-global-field-update
                  "status" (lambda (_definition) new))))
              ((symbol-function 'supertag-global-field-update)
               (lambda (&rest _args) (setq updated t)))
              ((symbol-function 'supertag-schema--field-type-impact)
               (lambda (&rest _)
                 '(:total 2
                   :convertible ((:node-id "n1" :value "true"
                                  :converted t))
                   :failed ((:node-id "n2" :value "maybe"
                             :error "Cannot convert")))))
              ((symbol-function 'y-or-n-p)
               (lambda (text) (setq prompt text) nil))
              ((symbol-function 'supertag-view-refresh)
               (lambda (&rest _) (ert-fail "unexpected manual refresh"))))
      (supertag-schema--edit-field-definition-at-point))
    (should-not updated)
    (should (string-match-p "string -> boolean" prompt))
    (should (string-match-p "2 node(s) have stored values" prompt))
    (should (string-match-p "1 will fail" prompt))
    (should (string-match-p "will NOT be rewritten" prompt))))

(ert-deftest supertag-view-schema-type-change-confirmed-uses-existing-update-path ()
  "Accepting the preview calls the updater and relies on Store subscription."
  (let ((old '(:id "status" :name "Status" :type :string))
        (new '(:name "Status" :type :boolean))
        updated-definition)
    (cl-letf (((symbol-function 'supertag-schema--get-context-at-point)
               (lambda () '(:type :field :tag-id "task"
                            :field-name "Status")))
              ((symbol-function 'supertag-tag-get-field)
               (lambda (&rest _) old))
              ((symbol-function 'supertag-global-field-get)
               (lambda (_field-id) old))
              ((symbol-function 'supertag-global-field-edit-interactive)
               (lambda (_field-id)
                 (supertag-global-field-update
                  "status" (lambda (_definition) new))))
              ((symbol-function 'supertag-global-field-update)
               (lambda (_field-id updater)
                 (setq updated-definition (funcall updater old))))
              ((symbol-function 'supertag-schema--field-type-impact)
               (lambda (&rest _)
                 '(:total 0 :convertible nil :failed nil)))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'supertag-view-refresh)
               (lambda (&rest _) (ert-fail "unexpected manual refresh"))))
      (supertag-schema--edit-field-definition-at-point))
    (should (equal new updated-definition))))

(ert-deftest supertag-view-schema-field-action-menu-states-data-consequences ()
  "The field action menu explicitly describes unbind and global delete."
  (let (shown)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (setq shown choices)
                 (car choices))))
      (should
       (eq :unbind
           (supertag-schema--read-field-delete-action
            "task" "Status" "status" 4))))
    (should (= 3 (length shown)))
    (should (string-match-p "keep global definition and 4 node value"
                            (nth 0 shown)))
    (should (string-match-p
             "remove definition, all bindings, and 4 node value"
             (nth 1 shown)))
    (should (string-match-p "Cancel" (nth 2 shown)))))

(ert-deftest supertag-view-schema-unbind-preserves-global-field-data-path ()
  "Choosing unbind never calls the destructive global delete operation."
  (let (disassociated)
    (cl-letf (((symbol-function 'supertag-schema--get-context-at-point)
               (lambda () '(:type :field :tag-id "task"
                            :field-name "Status" :field-id "status")))
              ((symbol-function 'supertag-schema--field-values)
               (lambda (_field-id) '((:node-id "n1" :value "open"))))
              ((symbol-function 'supertag-schema--read-field-delete-action)
               (lambda (&rest _) :unbind))
              ((symbol-function 'supertag-tag-disassociate-field)
               (lambda (tag-id field-id)
                 (setq disassociated (list tag-id field-id))))
              ((symbol-function 'supertag-global-field-delete)
               (lambda (&rest _) (ert-fail "unexpected global delete")))
              ((symbol-function 'supertag-view-refresh)
               (lambda (&rest _) (ert-fail "unexpected manual refresh"))))
      (supertag-schema--delete-at-point))
    (should (equal '("task" "status") disassociated))))

(ert-deftest supertag-view-schema-global-delete-is-confirmed-and-prunes-data ()
  "Choosing global delete confirms counts and calls Ops with prune-values."
  (let (deleted prompt)
    (cl-letf (((symbol-function 'supertag-schema--get-context-at-point)
               (lambda () '(:type :field :tag-id "task"
                            :field-name "Status" :field-id "status")))
              ((symbol-function 'supertag-schema--field-values)
               (lambda (_field-id)
                 '((:node-id "n1" :value "open")
                   (:node-id "n2" :value "closed"))))
              ((symbol-function 'supertag-schema--read-field-delete-action)
               (lambda (&rest _) :delete-global))
              ((symbol-function 'supertag-schema--field-association-count)
               (lambda (_field-id) 3))
              ((symbol-function 'yes-or-no-p)
               (lambda (text) (setq prompt text) t))
              ((symbol-function 'supertag-global-field-delete)
               (lambda (field-id prune-values)
                 (setq deleted (list field-id prune-values))))
              ((symbol-function 'supertag-tag-disassociate-field)
               (lambda (&rest _) (ert-fail "unexpected unbind")))
              ((symbol-function 'supertag-view-refresh)
               (lambda (&rest _) (ert-fail "unexpected manual refresh"))))
      (supertag-schema--delete-at-point))
    (should (equal '("status" t) deleted))
    (should (string-match-p "3 tag binding(s)" prompt))
    (should (string-match-p "2 stored node value(s)" prompt))
    (should (string-match-p "provenance" prompt))
    (should (string-match-p "cannot be undone" prompt))))

(provide 'view-schema-impact-test)

;;; view-schema-impact-test.el ends here
