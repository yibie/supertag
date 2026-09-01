;;; supertag-ontology-control-plane-test.el --- Control plane tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'supertag-ontology)

(defmacro supertag-ontology-v4-test-with-store (&rest body)
  `(let ((supertag--store (make-hash-table :test #'equal))
         (supertag-ontology-registry--raw (make-hash-table :test #'equal))
         (supertag-ontology-runtime-tags-provider (lambda () nil))
         (supertag-ontology-runtime-fields-provider (lambda () nil))
         (supertag-ontology-runtime-associations-provider (lambda () nil))
         (supertag-ontology-runtime-links-provider (lambda () nil)))
     (supertag--ensure-store)
     ,@body))

(ert-deftest supertag-ontology-v4-registration-is-pure ()
  (supertag-ontology-v4-test-with-store
   (let ((before (copy-hash-table supertag--store)))
     (supertag-ontology-registry-register
      'work '(:version 1 (type project :label "Project"))
      '(:file "test.el" :line 1))
     (should (equal (hash-table-count before)
                    (hash-table-count supertag--store))))))

(ert-deftest supertag-ontology-v4-rejects-unknown-keyword ()
  (let* ((model (supertag-ontology-model-normalize
                 'work '(:version 1 (type project :lable "Project")) nil))
         (issues (supertag-ontology-validator-validate model)))
    (should (cl-find :unknown-keyword issues :key
                     (lambda (x) (plist-get x :code))))))

(ert-deftest supertag-ontology-v4-validator-is-total ()
  (let* ((model (supertag-ontology-model-normalize
                 'work '(:version 1
                         (field status :type text)
                         (type project :extends 42 :fields "status")) nil))
         (issues (supertag-ontology-validator-validate model)))
    (should (listp issues))
    (should (cl-find :invalid-extends issues :key
                     (lambda (x) (plist-get x :code))))
    (should (cl-find :invalid-fields issues :key
                     (lambda (x) (plist-get x :code))))))

(ert-deftest supertag-ontology-v4-semantic-hash-ignores-order ()
  (let ((a (supertag-ontology-model-normalize
            'work '(:version 1
                    (field a :type text)
                    (field b :type text)) '(:file "a" :line 1)))
        (b (supertag-ontology-model-normalize
            'work '(:version 1
                    (field b :type text)
                    (field a :type text)) '(:file "b" :line 99))))
    (should (equal (supertag-ontology-model-hash a)
                   (supertag-ontology-model-hash b)))))

(ert-deftest supertag-ontology-v4-rejects-implicit-adoption ()
  (supertag-ontology-v4-test-with-store
   (let* ((supertag-ontology-runtime-tags-provider
           (lambda () (list '(:id "tag-existing" :name "Project"))))
          (model (supertag-ontology-model-normalize
                  'work '(:version 1 (type project :label "Project")) nil))
          (plan (supertag-ontology-plan-build model)))
     (should (cl-find :implicit-adoption (plist-get plan :issues)
                      :key (lambda (x) (plist-get x :code)))))))

(ert-deftest supertag-ontology-v4-explicit-adoption ()
  (supertag-ontology-v4-test-with-store
   (let* ((supertag-ontology-runtime-tags-provider
           (lambda () (list '(:id "tag-existing" :name "Project"))))
          (model (supertag-ontology-model-normalize
                  'work '(:version 1
                          (type project :runtime-id "tag-existing"
                                :label "Project")) nil))
          (plan (supertag-ontology-plan-build model)))
     (should-not (supertag-ontology-plan-errors-p plan)))))

(ert-deftest supertag-ontology-v4-rejects-rebinding ()
  (supertag-ontology-v4-test-with-store
   (supertag-ontology-runtime-binding-put
    '(:owner :ontology :module work :kind :type :key project
      :logical-id "work/type/project" :runtime-id "tag-a"))
   (let* ((supertag-ontology-runtime-tags-provider
           (lambda () (list '(:id "tag-a" :name "Project")
                            '(:id "tag-b" :name "Project 2"))))
          (model (supertag-ontology-model-normalize
                  'work '(:version 1
                          (type project :runtime-id "tag-b"
                                :label "Project 2")) nil))
          (plan (supertag-ontology-plan-build model)))
     (should (cl-find :runtime-rebinding (plist-get plan :issues)
                      :key (lambda (x) (plist-get x :code)))))))

(ert-deftest supertag-ontology-v4-live-store-drift-is-planned ()
  (supertag-ontology-v4-test-with-store
   (supertag-ontology-runtime-binding-put
    '(:owner :ontology :module work :kind :field :key status
      :logical-id "work/field/status" :runtime-id "field-status"))
   (let* ((supertag-ontology-runtime-fields-provider
           (lambda () (list '(:id "field-status" :name "Status" :type text))))
          (model (supertag-ontology-model-normalize
                  'work '(:version 1
                          (field status :label "Status" :type options
                                 :options (active done))) nil))
          (plan (supertag-ontology-plan-build model)))
     (should (supertag-ontology-plan-destructive-p plan)))))

(ert-deftest supertag-ontology-v4-catches-rename-collision ()
  (supertag-ontology-v4-test-with-store
   (supertag-ontology-runtime-binding-put
    '(:owner :ontology :module work :kind :type :key project
      :logical-id "work/type/project" :runtime-id "tag-a"))
   (let* ((supertag-ontology-runtime-tags-provider
           (lambda () (list '(:id "tag-a" :name "Old")
                            '(:id "tag-b" :name "Project"))))
          (model (supertag-ontology-model-normalize
                  'work '(:version 1 (type project :label "Project")) nil))
          (plan (supertag-ontology-plan-build model)))
     (should (cl-find :runtime-label-collision (plist-get plan :issues)
                      :key (lambda (x) (plist-get x :code)))))))

(ert-deftest supertag-ontology-v4-authority-blocks-interactive-schema-write ()
  (let ((supertag-schema-authority-provider-function
         (lambda (_kind _id) '(:owner :ontology :logical-id "work/type/project")))
        (supertag-schema-authority-current-actor :interactive))
    (should-error (supertag-schema-authority-assert :type "tag-a" :update)
                  :type 'supertag-schema-authority-error)))

(ert-deftest supertag-ontology-v4-authority-allows-deployment ()
  (let ((supertag-schema-authority-provider-function
         (lambda (_kind _id) '(:owner :ontology))))
    (supertag-schema-authority-with-actor :ontology-deployment
      (should (supertag-schema-authority-assert :type "tag-a" :update)))))

(ert-deftest supertag-ontology-v4-deployment-enters-one-transaction ()
  (supertag-ontology-v4-test-with-store
   ;; `let*': the closures below must be created after TRANSACTIONS and
   ;; OPERATIONS are lexically bound, otherwise they reference free
   ;; (void) variables.
   (let* ((transactions 0)
          (operations 0)
          (supertag-ontology-deploy-transaction-function
           (lambda (thunk) (cl-incf transactions) (funcall thunk)))
          (supertag-ontology-deploy-operation-function
           (lambda (plan operation created)
             (ignore plan operation created)
             (cl-incf operations))))
     (let* ((model (supertag-ontology-model-normalize
                    'work '(:version 1
                            (field status :type text)) nil))
            (plan (supertag-ontology-plan-build model)))
       (supertag-ontology-deploy-apply-plan plan)
       (should (= transactions 1))
       (should (= operations 1))))))

;;; Plan classification: which Field changes need a migration.

(defun supertag-ontology-v4-test--single-op (plan)
  "Return PLAN's only operation, asserting there is exactly one."
  (let ((operations (plist-get plan :operations)))
    (should (= 1 (length operations)))
    (car operations)))

(defmacro supertag-ontology-v4-test-with-deployed-status-field (runtime-type &rest body)
  "Run BODY with a deployed work/field/status whose runtime type is RUNTIME-TYPE."
  (declare (indent 1))
  `(supertag-ontology-v4-test-with-store
    (supertag-ontology-runtime-binding-put
     '(:owner :ontology :managed-by :ontology
       :module work :kind :field :key status
       :logical-id "work/field/status" :runtime-id "field-status"))
    (let ((supertag-ontology-runtime-fields-provider
           (lambda ()
             (list (list :id "field-status" :name "Status"
                         :type ',runtime-type)))))
      ,@body)))

(ert-deftest supertag-ontology-v4-field-type-change-is-destructive ()
  (supertag-ontology-v4-test-with-deployed-status-field :string
    (let* ((model (supertag-ontology-model-normalize
                   'work '(:version 2
                           (field status :label "Status" :type number)) nil))
           (plan (supertag-ontology-plan-build model))
           (operation (supertag-ontology-v4-test--single-op plan)))
      (should-not (supertag-ontology-plan-errors-p plan))
      (should (supertag-ontology-plan-destructive-p plan))
      (should (eq :update-field (plist-get operation :operation)))
      (should (cl-find :type (plist-get operation :changes)
                       :key (lambda (change) (plist-get change :slot))))
      (should-error (supertag-ontology-deploy-apply-plan plan)
                    :type 'user-error))))

(ert-deftest supertag-ontology-v4-field-label-change-is-safe ()
  (supertag-ontology-v4-test-with-deployed-status-field text
    (let* ((model (supertag-ontology-model-normalize
                   'work '(:version 2
                           (field status :label "State" :type text)) nil))
           (plan (supertag-ontology-plan-build model))
           (operation (supertag-ontology-v4-test--single-op plan)))
      (should (supertag-ontology-plan-safe-p plan))
      (should (eq :update-field (plist-get operation :operation)))
      (should (equal '(:label)
                     (mapcar (lambda (change) (plist-get change :slot))
                             (plist-get operation :changes)))))))

(ert-deftest supertag-ontology-v4-adding-optional-field-is-safe ()
  (supertag-ontology-v4-test-with-deployed-status-field :string
    (let* ((model (supertag-ontology-model-normalize
                   'work '(:version 2
                           (field status :label "Status" :type text)
                           (field notes :label "Notes" :type text)) nil))
           (plan (supertag-ontology-plan-build model))
           (operation (supertag-ontology-v4-test--single-op plan)))
      (should (supertag-ontology-plan-safe-p plan))
      (should (eq :create-field (plist-get operation :operation)))
      (should (eq 'notes (plist-get operation :key))))))

(ert-deftest supertag-ontology-v4-identical-field-redeploy-has-no-operations ()
  ;; The runtime spells the type as the legacy symbol `text'; the snapshot
  ;; normalizes it so an unchanged declaration plans nothing.
  (supertag-ontology-v4-test-with-deployed-status-field text
    (let* ((model (supertag-ontology-model-normalize
                   'work '(:version 1
                           (field status :label "Status" :type text)) nil))
           (plan (supertag-ontology-plan-build model)))
      (should-not (supertag-ontology-plan-errors-p plan))
      (should-not (plist-get plan :operations)))))

;;; Plan classification: Type occurrence aliases.

(ert-deftest supertag-ontology-v4-missing-key-alias-is-safe-type-update ()
  (supertag-ontology-v4-test-with-store
   (supertag-ontology-runtime-binding-put
    '(:owner :ontology :module work :kind :type :key project
      :logical-id "work/type/project" :runtime-id "tag-a"))
   (let* ((supertag-ontology-runtime-tags-provider
           (lambda () (list '(:id "tag-a" :name "Project"
                              :aliases ("Project" "tag-a")))))
          (model (supertag-ontology-model-normalize
                  'work '(:version 1
                          (type project :label "Project" :aliases (proj)))
                  nil))
          (plan (supertag-ontology-plan-build model))
          (operation (supertag-ontology-v4-test--single-op plan))
          (change (cl-find :aliases (plist-get operation :changes)
                           :key (lambda (change) (plist-get change :slot)))))
     (should (supertag-ontology-plan-safe-p plan))
     (should (eq :update-type (plist-get operation :operation)))
     (should (equal '("proj" "project") (plist-get change :add)))
     (should-not (plist-get change :remove)))))

(ert-deftest supertag-ontology-v4-tag-without-alias-slot-is-not-reconciled ()
  ;; A Tag record the ops layer never normalized carries no alias slot; the
  ;; planner does not guess its token set, so explicit adoption stays a
  ;; pure binding.
  (supertag-ontology-v4-test-with-store
   (let* ((supertag-ontology-runtime-tags-provider
           (lambda () (list '(:id "tag-a" :name "Project"))))
          (model (supertag-ontology-model-normalize
                  'work '(:version 1
                          (type project :runtime-id "tag-a" :label "Project"))
                  nil))
          (plan (supertag-ontology-plan-build model)))
     (should (equal '(:bind-entity)
                    (mapcar (lambda (operation) (plist-get operation :operation))
                            (plist-get plan :operations)))))))

(provide 'supertag-ontology-control-plane-test)
;;; supertag-ontology-control-plane-test.el ends here
