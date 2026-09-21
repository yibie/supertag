;;; supertag-field-options-test.el --- Tests for :options field values -*- lexical-binding: t; -*-

;; Covers the normalize / validate / store contract for `:options' fields:
;; a stored options value is a scalar string (single select) or a list of
;; strings (multi select), and `supertag-field-normalize' followed by
;; `supertag-field-validate' must round-trip for both shapes.

(require 'ert)
(require 'cl-lib)
(require 'supertag-core-store)
(require 'supertag-core-schema)
(require 'supertag-ops-field)
(require 'supertag-ops-tag)
(require 'supertag-services-ui)

(defmacro supertag-field-options-test--isolated (&rest body)
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

(defun supertag-field-options-test--install ()
  "Install one Tag with a global `status' options field and one node."
  (supertag-store-put-entity
   :tags "project"
   '(:id "project" :type :tag :name "Project" :extends nil))
  (supertag-store-put-entity
   :field-definitions "status"
   '(:id "status" :name "Status" :type :options
     :options ("idea" "active" "blocked" "done") :required nil))
  (supertag-store-put-entity
   :tag-field-associations "project"
   '((:field-id "status" :order 0)))
  (supertag-store-put-entity
   :nodes "project-1"
   '(:id "project-1" :type :node :title "One" :tags ("project"))))

;;; --- supertag--convert-type ---

(ert-deftest supertag-field-options-convert-keeps-scalar-string ()
  (should (equal "done" (supertag--convert-type "done" :options))))

(ert-deftest supertag-field-options-convert-keeps-comma-inside-scalar-string ()
  (should (equal "active,blocked"
                 (supertag--convert-type "active,blocked" :options))))

(ert-deftest supertag-field-options-convert-preserves-list ()
  (should (equal '("done") (supertag--convert-type '("done") :options)))
  (should (equal '("active" "done")
                 (supertag--convert-type '("active" "done") :options))))

;;; --- supertag-field-validate ---

(ert-deftest supertag-field-options-validate-scalar-member ()
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (should (supertag-field-validate "project" "status" "done"))
    (should (supertag-field-validate "project" "status" "idea"))))

(ert-deftest supertag-field-options-validate-list-of-members ()
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (should (supertag-field-validate "project" "status" '("done")))
    (should (supertag-field-validate "project" "status"
                                     '("active" "blocked")))))

(ert-deftest supertag-field-options-validate-rejects-scalar-non-member ()
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (should-not (supertag-field-validate "project" "status" "bogus"))
    (should-not (supertag-field-validate "project" "status" "Done"))))

(ert-deftest supertag-field-options-validate-rejects-list-with-non-member ()
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (should-not (supertag-field-validate "project" "status" '("bogus")))
    (should-not (supertag-field-validate "project" "status"
                                         '("done" "bogus")))))

(ert-deftest supertag-field-options-validate-rejects-nil-when-options-declared ()
  "nil is neither a declared option nor a selection list; keep it invalid."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (should-not (supertag-field-validate "project" "status" nil))))

;;; --- normalize -> validate round trip ---

(ert-deftest supertag-field-options-normalize-then-validate-scalar ()
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (let ((normalized (supertag-field-normalize "project" "status" "done")))
      (should (equal "done" normalized))
      (should (supertag-field-validate "project" "status" normalized)))))

(ert-deftest supertag-field-options-normalize-then-validate-list ()
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (let ((normalized (supertag-field-normalize "project" "status"
                                                '("active" "done"))))
      (should (equal '("active" "done") normalized))
      (should (supertag-field-validate "project" "status" normalized)))))

(ert-deftest supertag-field-options-comma-inside-declared-option-round-trips ()
  "A comma in one programmatic option is data, not a multi-select delimiter."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (supertag-store-put-field-definition
     "status"
     '(:id "status" :name "Status" :type :options
       :options ("Washington, D.C." "New York") :required nil))
    (supertag-field-set
     "project-1" "project" "status" "Washington, D.C.")
    (should (equal "Washington, D.C."
                   (supertag-field-get
                    "project-1" "project" "status")))
    (should (equal "Washington, D.C."
                   (supertag-store-get-field-value
                    "project-1" "status")))))

(ert-deftest supertag-field-options-normalize-does-not-infer-list-from-comma ()
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (let ((normalized (supertag-field-normalize "project" "status"
                                                "active,done")))
      (should (equal "active,done" normalized))
      (should-not (supertag-field-validate "project" "status" normalized)))))

(ert-deftest supertag-field-options-normalize-then-validate-rejects-non-member ()
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (let ((normalized (supertag-field-normalize "project" "status" "bogus")))
      (should (equal "bogus" normalized))
      (should-not (supertag-field-validate "project" "status" normalized)))))

(ert-deftest supertag-field-options-normalized-value-stores-as-scalar ()
  "Normalize -> validate -> set keeps the scalar shape readers expect."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (let ((normalized (supertag-field-normalize "project" "status" "done")))
      (should (supertag-field-validate "project" "status" normalized))
      (supertag-field-set "project-1" "project" "status" normalized)
      (should (equal "done" (supertag-field-get "project-1" "project" "status")))
      (should (equal "done"
                     (supertag-store-get-field-value "project-1" "status"))))))

(ert-deftest supertag-field-set-preserves-explicit-multi-select-list ()
  "Every writer stores an explicit multi-select list without reshaping it."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (supertag-field-set
     "project-1" "project" "status" '("active" "done"))
    (should (equal '("active" "done")
                   (supertag-field-get "project-1" "project" "status")))))

(ert-deftest supertag-field-set-rejects-invalid-value-with-context ()
  "A failed validation names the field, expected shape, and supplied value."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (let ((message
           (condition-case err
               (progn
                 (supertag-field-set
                  "project-1" "project" "status" "bogus")
                 nil)
             (user-error (error-message-string err)))))
      (should message)
      (should (string-match-p "Status" message))
      (should (string-match-p "options" message))
      (should (string-match-p "bogus" message))
      (should-not (supertag-store-get-field-value "project-1" "status")))))

(ert-deftest supertag-field-set-explicit-nil-clears-value-despite-default ()
  "Explicit nil removes a stored value; defaults remain read-time fallback."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (let ((definition
           (copy-tree (supertag-store-get-field-definition "status"))))
      (supertag-store-put-field-definition
       "status" (plist-put definition :default "idea")))
    (supertag-field-set "project-1" "project" "status" "active"
                        '(:origin :agent))
    (supertag-field-set "project-1" "project" "status" nil)
    (should
     (eq supertag-field--missing
         (supertag-store-get-field-value
          "project-1" "status" supertag-field--missing)))
    (should-not
     (supertag-store-get-field-provenance "project-1" "status"))
    (should (equal "idea"
                   (supertag-field-get-with-default
                    "project-1" "project" "status")))))

(ert-deftest supertag-field-set-many-clears-options-without-rolling-back-batch ()
  "A nil clear is a valid batch operation and later writes still commit."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install)
    (supertag-store-put-field-definition
     "summary" '(:id "summary" :name "Summary" :type :string))
    (supertag-store-put-tag-field-associations
     "project"
     '((:field-id "status" :order 0) (:field-id "summary" :order 1)))
    (supertag-field-set "project-1" "project" "status" "active"
                        '(:origin :agent))
    (supertag-field-set-many
     "project-1"
     '((:tag "project" :field "status" :value nil)
       (:tag "project" :field "summary" :value "kept")))
    (should
     (eq supertag-field--missing
         (supertag-store-get-field-value
          "project-1" "status" supertag-field--missing)))
    (should (equal "kept"
                   (supertag-field-get
                    "project-1" "project" "summary")))))

(ert-deftest supertag-ui-options-editor-carries-current-selection ()
  "Editing options exposes all current choices instead of replacing them."
  (let (seen-initial)
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (_prompt _collection _predicate _require-match
                        initial-input &rest _)
                 (setq seen-initial initial-input)
                 '("active" "done"))))
      (should (equal '("active" "done")
                     (supertag-ui-read-field-value
                      '(:name "Status" :type :options
                        :options ("idea" "active" "blocked" "done"))
                      '("active" "done"))))
      (should (string-match-p "active" seen-initial))
      (should (string-match-p "done" seen-initial)))))

(ert-deftest supertag-ui-options-editor-keeps-single-value-shape ()
  "A one-option edit remains a scalar value for existing readers."
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (&rest _) '("active"))))
    (should (equal "active"
                   (supertag-ui-read-field-value
                    '(:name "Status" :type :options
                      :options ("idea" "active" "blocked" "done"))
                    "active")))))

;;; --- :boolean false is a valid value, not a failed type check ---

(defun supertag-field-options-test--install-boolean ()
  "Install one Tag with a global `flag' boolean field."
  (supertag-store-put-entity
   :tags "project"
   '(:id "project" :type :tag :name "Project" :extends nil))
  (supertag-store-put-entity
   :field-definitions "flag"
   '(:id "flag" :name "Flag" :type :boolean :required nil))
  (supertag-store-put-entity
   :tag-field-associations "project"
   '((:field-id "flag" :order 0))))

(ert-deftest supertag-field-boolean-validate-accepts-false ()
  "A :boolean converts nil / \"false\" / `false' to nil; that is a valid
value, so validation must not fail just because the converted value is nil."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install-boolean)
    (should (supertag-field-validate "project" "flag" nil))
    (should (supertag-field-validate "project" "flag" "false"))
    (should (supertag-field-validate "project" "flag" 'false))
    (should (supertag-field-validate "project" "flag" 0))))

(ert-deftest supertag-field-boolean-validate-accepts-true ()
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install-boolean)
    (should (supertag-field-validate "project" "flag" t))
    (should (supertag-field-validate "project" "flag" "true"))
    (should (supertag-field-validate "project" "flag" 1))))

(ert-deftest supertag-field-boolean-validate-rejects-non-boolean ()
  "Values `supertag--convert-type' cannot coerce still fail validation."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install-boolean)
    (should-error (supertag-field-validate "project" "flag" "maybe"))
    (should-error (supertag-field-validate "project" "flag" '("true")))))

(ert-deftest supertag-field-boolean-normalize-false-then-validate ()
  "normalize -> validate round-trips a false boolean without dropping it."
  (supertag-field-options-test--isolated
    (supertag-field-options-test--install-boolean)
    (let ((normalized (supertag-field-normalize "project" "flag" "false")))
      (should (null normalized))
      (should (supertag-field-validate "project" "flag" normalized)))))

(provide 'supertag-field-options-test)

;;; supertag-field-options-test.el ends here
