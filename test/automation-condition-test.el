;;; automation-condition-test.el --- Automation condition grammar parity -*- lexical-binding: t; -*-

;;; Commentary:
;; task008: automation :condition accepts the query grammar directly;
;; legacy conditions convert deterministically, forms without a query
;; equivalent keep their dedicated evaluation path.

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-ops-field)
(require 'supertag-query)
(require 'supertag-automation)

(defmacro automation-condition-test--with-store (&rest body)
  "Run BODY with an isolated Store holding two fixture nodes."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-automation-condition-test" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag--store nil)
          (supertag--store-origin nil))
     (unwind-protect
         (progn
           (supertag--ensure-store)
           (supertag-store-put-entity
            :nodes "node-a"
            (list :id "node-a" :title "a" :tags (list "project")))
           (supertag-store-put-entity
            :nodes "node-b"
            (list :id "node-b" :title "b" :tags (list "project" "done")))
           (supertag-store-put-field-value "node-a" "status" "stale")
           (supertag-store-put-field-value "node-b" "status" "fresh")
           ,@body)
       (ignore-errors (delete-directory tmp t)))))

(ert-deftest automation-condition-query-grammar-matches-legacy ()
  "New query syntax and converted legacy syntax agree on the matched set."
  (automation-condition-test--with-store
    (let ((legacy '(and (has-tag "project") (field-equals "status" "stale")))
          (new '(and (tag "project") (field "status" "stale"))))
      ;; Deterministic conversion.
      (should (equal new (supertag-automation--condition-to-query legacy)))
      ;; Both grammars agree per node.
      (should (supertag-automation--evaluate-condition legacy "node-a"))
      (should-not (supertag-automation--evaluate-condition legacy "node-b"))
      (should (supertag-automation--evaluate-condition new "node-a"))
      (should-not (supertag-automation--evaluate-condition new "node-b")))))

(ert-deftest automation-condition-multi-tag-conversion ()
  "has-any-tag/has-all-tags convert to or/and of tag queries."
  (automation-condition-test--with-store
    (let ((any '(has-any-tag "project" "done"))
          (all '(has-all-tags "project" "done")))
      (should (equal '(or (tag "project") (tag "done"))
                     (supertag-automation--condition-to-query any)))
      (should (equal '(and (tag "project") (tag "done"))
                     (supertag-automation--condition-to-query all)))
      (should (supertag-automation--evaluate-condition any "node-a"))
      (should (supertag-automation--evaluate-condition all "node-b"))
      (should-not (supertag-automation--evaluate-condition all "node-a")))))

(ert-deftest automation-condition-event-forms-keep-dedicated-path ()
  "Event/test conditions without a query equivalent still evaluate."
  (automation-condition-test--with-store
    ;; property-changed converts to nil and evaluates via the legacy path.
    (should-not (supertag-automation--condition-to-query
                 '(property-changed "status")))
    (let ((orig (symbol-function 'supertag-automation--property-changed-p)))
      (fset 'supertag-automation--property-changed-p (lambda (_key) t))
      (unwind-protect
          (should (supertag-automation--evaluate-condition
                   '(property-changed "status") "node-a"))
        (fset 'supertag-automation--property-changed-p orig)))
    ;; Mixed conditions (query part + event part) also fall back to the
    ;; legacy evaluator, which still handles tags.
    (should-not (supertag-automation--condition-to-query
                 '(and (has-tag "project") (property-changed "status"))))
    (let ((orig (symbol-function 'supertag-automation--property-changed-p)))
      (fset 'supertag-automation--property-changed-p (lambda (_key) t))
      (unwind-protect
          (should (supertag-automation--evaluate-condition
                   '(and (has-tag "project") (property-changed "status"))
                   "node-a"))
        (fset 'supertag-automation--property-changed-p orig)))))

(ert-deftest automation-condition-nil-and-t-pass-through ()
  "nil/t conditions keep their unconditional semantics."
  (should (supertag-automation--evaluate-condition nil "node-a"))
  (should (supertag-automation--evaluate-condition t "node-a")))

(provide 'automation-condition-test)

;;; automation-condition-test.el ends here
