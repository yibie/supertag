;;; supertag-ontology-test.el --- Ontology facade smoke tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'supertag-core-store)
(require 'supertag-ontology)

(defmacro supertag-ontology-test--isolated (&rest body)
  "Run BODY with an empty Store and declaration registry.
The runtime providers are left nil so the snapshot reads the isolated Store:
tests that put definitions into it must see them as deployed state."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (make-hash-table :test #'equal))
         (supertag-ontology-registry--raw (make-hash-table :test #'equal))
         (supertag-ontology-runtime-tags-provider nil)
         (supertag-ontology-runtime-fields-provider nil)
         (supertag-ontology-runtime-associations-provider nil)
         (supertag-ontology-runtime-links-provider nil))
     (supertag--ensure-store)
     ,@body))

(ert-deftest supertag-ontology-facade-registration-is-pure ()
  (supertag-ontology-test--isolated
    (let ((before-count (hash-table-count supertag--store)))
      (supertag-ontology-registry-register
       'work '(:version 1 (type project :label "Project"))
       '(:file "work.el" :line 1))
      (should (supertag-ontology-get 'work))
      (should (= before-count (hash-table-count supertag--store))))))

(ert-deftest supertag-ontology-facade-plan-alias-builds-live-plan ()
  (supertag-ontology-test--isolated
    (let* ((model
            (supertag-ontology-model-normalize
             'work
             '(:version 1
               (field status :label "Status" :type text)
               (type project :label "Project" :fields (status)))
             nil))
           (plan (supertag-ontology-plan model)))
      (should (supertag-ontology-plan-safe-p plan))
      (should (= 2 (length (plist-get plan :operations)))))))

(ert-deftest supertag-ontology-facade-rejects-destructive-plan ()
  (supertag-ontology-test--isolated
    (supertag-store-put-field-definition
     "field-status" '(:id "field-status" :name "Status" :type text))
    (supertag-ontology-runtime-binding-put
     '(:owner :ontology :managed-by :ontology
       :module work :kind :field :key status
       :logical-id "work/field/status" :runtime-id "field-status"))
    (let* ((model
            (supertag-ontology-model-normalize
             'work
             '(:version 2
               (field status :label "Status" :type number
                      :runtime-id "field-status"))
             nil))
           (plan (supertag-ontology-plan model)))
      (should (supertag-ontology-plan-destructive-p plan))
      (should-error (supertag-ontology-deploy-apply-plan plan)
                    :type 'user-error))))

(ert-deftest supertag-ontology-facade-logical-id-is-stable ()
  (should (equal "work/link/tasks"
                 (supertag-ontology-model-logical-id
                  'work :link 'tasks))))

(provide 'supertag-ontology-test)
;;; supertag-ontology-test.el ends here
