;;; migration-property-field-test.el --- Property-to-field migration tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'ht)
(require 'supertag-core-store)
(require 'supertag-ops-field)
(require 'supertag-migration)

(defmacro supertag-migration-property-test--isolated (&rest body)
  "Run BODY with an empty Store and quiet transaction state."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (make-hash-table :test #'equal))
         (supertag--transaction-active nil)
         (supertag--transaction-log nil)
         (supertag--subscribers (make-hash-table :test #'eq))
         (supertag-after-operation-hook nil)
         (supertag-ops-deferred-event-errors nil))
     (supertag--ensure-store)
     ,@body))

(defun supertag-migration-property-test--install ()
  "Install one tag and three tagged nodes."
  (supertag-store-put-entity
   :tags "event"
   '(:id "event" :type :tag :name "Event" :extends nil))
  (dolist (node-id '("node-1" "node-2" "node-3"))
    (supertag-store-put-entity
     :nodes node-id
     (list :id node-id :type :node :title node-id :tags '("event")))))

(ert-deftest supertag-migration-property-continues-after-invalid-historical-value ()
  "One unconvertible node is reported without abandoning later nodes."
  (supertag-migration-property-test--isolated
    (supertag-migration-property-test--install)
    (let ((properties (ht-create)))
      (puthash "FLAG"
               '(("node-1" . "true")
                 ("node-2" . "not-a-boolean")
                 ("node-3" . "false"))
               properties)
      (cl-letf (((symbol-function 'supertag-migration--infer-field-type)
                 (lambda (_occurrences) :boolean)))
        (let ((result
               (supertag-migration--convert-single-property
                "FLAG" "event" properties)))
          (should (= 2 (plist-get result :values-set)))
          (should (equal '("node-1" "node-3")
                         (plist-get result :successful-nodes)))
          (should (equal '("node-2")
                         (plist-get result :failed-nodes)))
          (should (= 1 (length (plist-get result :failures))))
          (should (eq t (supertag-store-get-field-value "node-1" "flag")))
          (should (eq supertag-field--missing
                      (supertag-store-get-field-value
                       "node-2" "flag" supertag-field--missing)))
          ;; Boolean false is a real stored value even though its Lisp
          ;; representation is nil.
          (should (null (supertag-store-get-field-value
                         "node-3" "flag" supertag-field--missing)))
          (should-not (eq supertag-field--missing
                          (supertag-store-get-field-value
                           "node-3" "flag" supertag-field--missing))))))))

(ert-deftest supertag-batch-migration-returns-node-success-and-failure-lists ()
  "The interactive batch surface completes and exposes its partial result."
  (supertag-migration-property-test--isolated
    (supertag-migration-property-test--install)
    (let ((properties (ht-create)))
      (puthash "FLAG"
               '(("node-1" . "true")
                 ("node-2" . "not-a-boolean")
                 ("node-3" . "false"))
               properties)
      (cl-letf (((symbol-function 'supertag-migration--collect-all-properties)
                 (lambda () properties))
                ((symbol-function 'supertag-migration--infer-field-type)
                 (lambda (_occurrences) :boolean))
                ((symbol-function 'supertag-query)
                 (lambda (&rest _args) '(("event"))))
                ((symbol-function 'completing-read-multiple)
                 (lambda (&rest _args) '("FLAG")))
                ((symbol-function 'completing-read)
                 (lambda (&rest _args) "event")))
        (let* ((results (supertag-batch-convert-properties-to-fields))
               (result (car results)))
          (should (= 2 (plist-get result :values-set)))
          (should (equal '("node-1" "node-3")
                         (plist-get result :successful-nodes)))
          (should (equal '("node-2")
                         (plist-get result :failed-nodes))))))))

(provide 'migration-property-field-test)

;;; migration-property-field-test.el ends here
