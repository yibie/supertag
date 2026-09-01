;;; supertag-ontology-migration-test.el --- Migration DSL tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'ht)
(require 'supertag-core-store)
(require 'supertag-core-index)
(require 'supertag-ontology)
(require 'supertag-ops-relation)

(defmacro supertag-migration-v8-test--isolated (&rest body)
  "Run BODY with an empty Store and isolated declaration registries."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (ht-create))
         (supertag-ontology-registry--raw (make-hash-table :test #'equal))
         (supertag-ontology-migration-registry--raw
          (make-hash-table :test #'equal))
         (supertag-ontology-runtime-tags-provider nil)
         (supertag-ontology-runtime-fields-provider nil)
         (supertag-ontology-runtime-associations-provider nil)
         (supertag-ontology-runtime-links-provider nil))
     (supertag--ensure-store)
     (supertag-index-clear-all)
     ,@body))

(defun supertag-migration-v8-test--register-ontology (body)
  "Register work ontology BODY and return its normalized model."
  (supertag-ontology-registry-register
   'work body '(:file "work-ontology.el" :line 1))
  (supertag-ontology-registry-get 'work))

(defun supertag-migration-v8-test--deploy-v1-field ()
  "Deploy a version-one Project/status ontology."
  (supertag-migration-v8-test--register-ontology
   '(:version 1
     (field status :label "Status" :type text)
     (type project :label "Project" :fields (status))))
  (supertag-ontology-apply 'work))

(defun supertag-migration-v8-test--binding-id (kind key)
  "Return work ontology runtime binding for KIND KEY."
  (plist-get (supertag-ontology-runtime-binding-get 'work kind key)
             :runtime-id))

(defun supertag-migration-v8-test--status-transform (value _context)
  "Normalize legacy status VALUE."
  (pcase value
    ((or "doing" "in progress") "active")
    ((or "finished" "done") "done")
    (_ "idea")))

(defun supertag-migration-v8-test--explode (_value _context)
  "Test transformer that always fails."
  (error "intentional transform failure"))

(defun supertag-migration-v8-test--clear (_value _context)
  "Test transformer that silently maps every value to nil."
  nil)

(defun supertag-migration-v8-test--drop (_value _context)
  "Test transformer that explicitly removes every value."
  supertag-ontology-migration-drop)

(defun supertag-migration-v8-test--impure-transform (value _context)
  "Test transformer that attempts a forbidden Store write."
  (supertag-store-put-entity
   :nodes "preview-side-effect"
   '(:id "preview-side-effect" :type :node :title "Side effect"))
  value)

(defun supertag-migration-v8-test--keep-first (relations _context)
  "Return deterministic first relation from RELATIONS."
  (car
   (sort (copy-sequence relations)
         (lambda (left right)
           (string< (plist-get left :id) (plist-get right :id))))))

(defun supertag-migration-v8-test--register-status-v2 (&optional on-error)
  "Register status v2 ontology and migration."
  (supertag-migration-v8-test--register-ontology
   '(:version 2
     (field status :label "Status" :type options
            :options (idea active done))
     (type project :label "Project" :fields (status))))
  (supertag-ontology-migration-registry-register
   'status-v2
   `(:module work :from 1 :to 2
     (transform-field status
                      :using supertag-migration-v8-test--status-transform
                      :on-error ,(or on-error :abort)))
   '(:file "work-migrations.el" :line 1))
  (supertag-ontology-migration-registry-get 'status-v2))

(ert-deftest supertag-migration-v8-registration-is-pure ()
  (supertag-migration-v8-test--isolated
    (let ((before (hash-table-count supertag--store)))
      (supertag-ontology-migration-registry-register
       'status-v2
       '(:module work :from 1 :to 2
         (transform-field status
                          :using supertag-ontology-migration-identity))
       '(:file "migrations.el" :line 1))
      (should (supertag-ontology-migration-registry-get 'status-v2))
      (should (= before (hash-table-count supertag--store))))))


(ert-deftest supertag-migration-v8-registry-uses-module-scoped-identity ()
  (let ((supertag-ontology-migration-registry--raw
         (make-hash-table :test #'equal)))
    (supertag-ontology-migration-registry-register
     'status-v2
     '(:module work :from 1 :to 2
       (transform-field status
                        :using supertag-ontology-migration-identity))
     nil)
    (supertag-ontology-migration-registry-register
     'status-v2
     '(:module crm :from 1 :to 2
       (transform-field status
                        :using supertag-ontology-migration-identity))
     nil)
    (should (= 2 (length (supertag-ontology-migration-registry-ids))))
    (should (eq 'work
                (plist-get
                 (supertag-ontology-migration-registry-get
                  "work/migration/status-v2")
                 :module)))
    (should-error
     (supertag-ontology-migration-registry-get 'status-v2)
     :type 'user-error)))

(ert-deftest supertag-migration-v8-validator-is-total ()
  (let* ((migration
          (supertag-ontology-migration-model-normalize
           'bad
           '(:module 42 :from "one" :to 0
             (transform-field :bad :using missing-function :wat t))
           nil))
         (issues
          (supertag-ontology-migration-validator-validate migration)))
    (should (listp issues))
    (should (cl-find :invalid-module issues
                     :key (lambda (issue) (plist-get issue :code))))
    (should (cl-find :invalid-transformer issues
                     :key (lambda (issue) (plist-get issue :code))))
    (should (cl-find :unknown-step-keyword issues
                     :key (lambda (issue) (plist-get issue :code))))))

(ert-deftest supertag-migration-v8-plan-requires-exact-destructive-coverage ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (supertag-migration-v8-test--register-ontology
     '(:version 2
       (field status :label "Status" :type options
              :options (active done))
       (type project :label "Project" :fields (status))))
    (let* ((migration
            (supertag-ontology-migration-model-normalize
             'empty '(:module work :from 1 :to 2
                       (detach-field project status)) nil))
           (plan (supertag-ontology-migration-plan-build migration)))
      (should (supertag-ontology-migration-plan-errors-p plan))
      (should (cl-find :uncovered-field-change (plist-get plan :issues)
                       :key (lambda (issue) (plist-get issue :code))))
      (should (cl-find :unused-step (plist-get plan :issues)
                       :key (lambda (issue) (plist-get issue :code)))))))

(ert-deftest supertag-migration-v8-preview-rolls-back-impure-transformer ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status)))
      (supertag-store-put-entity
       :nodes "node-a" '(:id "node-a" :type :node :title "A" :tags nil))
      (supertag-store-put-field-value "node-a" field-id "doing")
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (field status :label "Status" :type options
                :options (idea active done))
         (type project :label "Project" :fields (status))))
      (let* ((migration
              (supertag-ontology-migration-model-normalize
               'impure
               '(:module work :from 1 :to 2
                 (transform-field status
                                  :using supertag-migration-v8-test--impure-transform
                                  :on-error :drop))
               nil))
             (plan (supertag-ontology-migration-plan-build migration)))
        (should (supertag-ontology-migration-plan-errors-p plan))
        (should (cl-find :impure-transformer (plist-get plan :issues)
                         :key (lambda (issue) (plist-get issue :code))))
        (should-not
         (supertag-store-get-entity :nodes "preview-side-effect"))
        (should (equal "doing"
                       (supertag-store-get-field-value "node-a" field-id)))))))

(ert-deftest supertag-migration-v8-transforms-field-and-records-ledger ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status)))
      (supertag-store-put-entity
       :nodes "node-a" '(:id "node-a" :type :node :title "A" :tags nil))
      (supertag-store-put-field-value "node-a" field-id "doing")
      (let* ((migration (supertag-migration-v8-test--register-status-v2))
             (plan (supertag-ontology-migration-plan-build migration)))
        (should (supertag-ontology-migration-plan-ready-p plan))
        (should (= 1 (length
                      (supertag-ontology-migration-plan-actions plan))))
        (supertag-ontology-migration-deploy-apply-plan plan)
        (should (equal "active"
                       (supertag-store-get-field-value "node-a" field-id)))
        (should (eq :options
                    (plist-get
                     (supertag-store-get-field-definition field-id) :type)))
        (should (= 2
                   (plist-get
                    (supertag-ontology-runtime-module-get 'work) :version)))
        (should
         (supertag-ontology-migration-runtime-get
          (plist-get migration :logical-id)))))))

(ert-deftest supertag-migration-v8-destructive-executor-is-not-a-force-flag ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let* ((migration (supertag-migration-v8-test--register-status-v2))
           (plan (supertag-ontology-migration-plan-build migration)))
      (should (supertag-ontology-migration-plan-ready-p plan))
      (should-error
       (supertag-ontology-deploy-execute-plan
        (plist-get plan :ontology-plan) t)))))

(ert-deftest supertag-migration-v8-cannot-run-twice ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let* ((migration (supertag-migration-v8-test--register-status-v2))
           (plan (supertag-ontology-migration-plan-build migration)))
      (supertag-ontology-migration-deploy-apply-plan plan)
      (should-error
       (supertag-ontology-migration-deploy-apply-plan plan)
       :type 'user-error)
      (should (cl-find :already-applied
                       (plist-get
                        (supertag-ontology-migration-plan-build migration)
                        :issues)
                       :key (lambda (issue) (plist-get issue :code)))))))

(ert-deftest supertag-migration-v8-rejects-stale-data-plan ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status)))
      (supertag-store-put-entity
       :nodes "node-a" '(:id "node-a" :type :node :title "A" :tags nil))
      (supertag-store-put-field-value "node-a" field-id "doing")
      (let* ((migration (supertag-migration-v8-test--register-status-v2))
             (plan (supertag-ontology-migration-plan-build migration)))
        (supertag-store-put-field-value "node-a" field-id "finished")
        (should-error
         (supertag-ontology-migration-deploy-apply-plan plan)
         :type 'user-error)
        (should (equal "finished"
                       (supertag-store-get-field-value "node-a" field-id)))
        (should (= 1
                   (plist-get
                    (supertag-ontology-runtime-module-get 'work) :version)))))))


(ert-deftest supertag-migration-v8-rejects-missing-action-node ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status)))
      (supertag-store-put-entity
       :nodes "node-a" '(:id "node-a" :type :node :title "A" :tags nil))
      (supertag-store-put-field-value "node-a" field-id "doing")
      (let* ((migration (supertag-migration-v8-test--register-status-v2))
             (plan (supertag-ontology-migration-plan-build migration)))
        ;; Simulate an orphaned field bucket whose source node disappeared after
        ;; preview; the relevant data hash alone cannot detect node existence.
        (supertag-store-remove-entity :nodes "node-a")
        (should-error
         (supertag-ontology-migration-deploy-apply-plan plan)
         :type 'user-error)
        (should (equal "doing"
                       (supertag-store-get-field-value "node-a" field-id)))))))

(ert-deftest supertag-migration-v8-transform-error-aborts-planning ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status)))
      (supertag-store-put-entity
       :nodes "node-a" '(:id "node-a" :type :node :title "A" :tags nil))
      (supertag-store-put-field-value "node-a" field-id "doing")
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (field status :label "Status" :type options :options (active))
         (type project :label "Project" :fields (status))))
      (let* ((migration
              (supertag-ontology-migration-model-normalize
               'bad-transform
               '(:module work :from 1 :to 2
                 (transform-field status
                                  :using supertag-migration-v8-test--explode))
               nil))
             (plan (supertag-ontology-migration-plan-build migration)))
        (should (supertag-ontology-migration-plan-errors-p plan))
        (should (cl-find :field-transform-failed (plist-get plan :issues)
                         :key (lambda (issue) (plist-get issue :code))))
        (should (equal "doing"
                       (supertag-store-get-field-value "node-a" field-id)))))))

(ert-deftest supertag-migration-v8-on-error-drop-is-explicit ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status)))
      (supertag-store-put-entity
       :nodes "node-a" '(:id "node-a" :type :node :title "A" :tags nil))
      (supertag-store-put-field-value "node-a" field-id "bad")
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (field status :label "Status" :type options :options (active))
         (type project :label "Project" :fields (status))))
      (let* ((migration
              (supertag-ontology-migration-model-normalize
               'drop-invalid
               '(:module work :from 1 :to 2
                 (transform-field status
                                  :using supertag-migration-v8-test--explode
                                  :on-error :drop))
               nil))
             (plan (supertag-ontology-migration-plan-build migration)))
        (should (supertag-ontology-migration-plan-ready-p plan))
        (supertag-ontology-migration-deploy-apply-plan plan)
        (should (eq :missing
                    (supertag-store-get-field-value
                     "node-a" field-id :missing)))))))

(ert-deftest supertag-migration-v8-warns-when-transform-clears-values ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status)))
      (supertag-store-put-entity
       :nodes "node-a" '(:id "node-a" :type :node :title "A" :tags nil))
      (supertag-store-put-field-value "node-a" field-id "doing")
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (field status :label "Status" :type options
                :options (active done))
         (type project :label "Project" :fields (status))))
      (cl-flet ((plan-with (name transformer)
                  (supertag-ontology-migration-plan-build
                   (supertag-ontology-migration-model-normalize
                    name
                    `(:module work :from 1 :to 2
                      (transform-field status :using ,transformer))
                    nil)))
                (clears-issue (plan)
                  (cl-find :transform-clears-value (plist-get plan :issues)
                           :key (lambda (issue) (plist-get issue :code)))))
        ;; Explicit removal via the drop marker is intentional: no warning.
        (should-not (clears-issue
                     (plan-with 'drop-status
                                'supertag-migration-v8-test--drop)))
        (let* ((plan (plan-with 'clear-status
                                'supertag-migration-v8-test--clear))
               (issue (clears-issue plan))
               (step-plan (car (plist-get plan :step-plans))))
          (should issue)
          (should (eq :warning (plist-get issue :severity)))
          (should (string-match-p "node-a" (plist-get issue :message)))
          (should (= 1 (plist-get step-plan :cleared)))
          ;; The warning must surface in the preview without blocking an
          ;; intentional clearing migration.
          (should-not (supertag-ontology-migration-plan-errors-p plan))
          (should (supertag-ontology-migration-plan-ready-p plan))
          (supertag-ontology-migration-deploy-apply-plan plan)
          (should (null (supertag-store-get-field-value
                         "node-a" field-id :missing))))))))

(ert-deftest supertag-migration-v8-required-target-cannot-drop-value ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--register-ontology
     '(:version 1
       (field status :label "Status" :type text :required t)
       (type project :label "Project" :fields (status))))
    (supertag-ontology-apply 'work)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status)))
      (supertag-store-put-entity
       :nodes "node-a" '(:id "node-a" :type :node :title "A" :tags nil))
      (supertag-store-put-field-value "node-a" field-id "legacy")
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (field status :label "Status" :type options
                :options (active done) :required t)
         (type project :label "Project" :fields (status))))
      (supertag-ontology-migration-registry-register
       'required-drop
       '(:module work :from 1 :to 2
         (transform-field status
                          :using supertag-migration-v8-test--explode
                          :on-error :drop))
       nil)
      (let ((plan
             (supertag-ontology-migration-plan-build
              (supertag-ontology-migration-registry-get 'required-drop))))
        (should (supertag-ontology-migration-plan-errors-p plan))
        (should (cl-find :field-transform-failed
                         (plist-get plan :issues)
                         :key (lambda (issue) (plist-get issue :code))))))))

(ert-deftest supertag-migration-v8-detaches-field-without-hidden-data-deletion ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status))
          (type-id (supertag-migration-v8-test--binding-id :type 'project)))
      (supertag-store-put-field-value "node-a" field-id "legacy")
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (field status :label "Status" :type text)
         (type project :label "Project")))
      (let* ((migration
              (supertag-ontology-migration-model-normalize
               'detach-status
               '(:module work :from 1 :to 2
                 (detach-field project status)) nil))
             (plan (supertag-ontology-migration-plan-build migration)))
        (should (supertag-ontology-migration-plan-ready-p plan))
        (supertag-ontology-migration-deploy-apply-plan plan)
        (should-not
         (cl-find field-id
                  (supertag-store-get-tag-field-associations type-id)
                  :key (lambda (entry) (plist-get entry :field-id))
                  :test #'equal))
        ;; v1 intentionally separates schema detachment from value deletion.
        (should (equal "legacy"
                       (supertag-store-get-field-value "node-a" field-id)))))))

(ert-deftest supertag-migration-v8-tightens-link-cardinality ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--register-ontology
     '(:version 1
       (type project :label "Project")
       (type task :label "Task")
       (link tasks :label "Tasks" :from project :to task
             :from-cardinality many :to-cardinality many)))
    (supertag-ontology-apply 'work)
    (let ((project-tag (supertag-migration-v8-test--binding-id :type 'project))
          (task-tag (supertag-migration-v8-test--binding-id :type 'task))
          (link-id (supertag-migration-v8-test--binding-id :link 'tasks)))
      (supertag-store-put-entity
       :nodes "project-a" (list :id "project-a" :type :node
                                :title "A" :tags (list project-tag)))
      (supertag-store-put-entity
       :nodes "project-b" (list :id "project-b" :type :node
                                :title "B" :tags (list project-tag)))
      (supertag-store-put-entity
       :nodes "task-a" (list :id "task-a" :type :node
                             :title "Task" :tags (list task-tag)))
      (supertag-link-create link-id "project-a" "task-a")
      (supertag-link-create link-id "project-b" "task-a")
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (type project :label "Project")
         (type task :label "Task")
         (link tasks :label "Tasks" :from project :to task
               :from-cardinality many :to-cardinality one)))
      (let* ((migration
              (supertag-ontology-migration-model-normalize
               'single-project
               '(:module work :from 1 :to 2
                 (tighten-link tasks
                               :target-resolver
                               supertag-migration-v8-test--keep-first))
               nil))
             (plan (supertag-ontology-migration-plan-build migration)))
        (should (supertag-ontology-migration-plan-ready-p plan))
        (should (= 1 (length
                      (supertag-ontology-migration-plan-actions plan))))
        (supertag-ontology-migration-deploy-apply-plan plan)
        (should (= 1 (length
                      (supertag-link-definition-instance-relations link-id))))
        (should (eq :one
                    (plist-get
                     (supertag-link-definition-get link-id)
                     :to-cardinality)))))))

(ert-deftest supertag-migration-v8-link-conflict-needs-resolver ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--register-ontology
     '(:version 1
       (type project) (type task)
       (link tasks :from project :to task
             :from-cardinality many :to-cardinality many)))
    (supertag-ontology-apply 'work)
    (let ((project-tag (supertag-migration-v8-test--binding-id :type 'project))
          (task-tag (supertag-migration-v8-test--binding-id :type 'task))
          (link-id (supertag-migration-v8-test--binding-id :link 'tasks)))
      (dolist (spec `(("p1" ,project-tag) ("p2" ,project-tag)
                      ("task" ,task-tag)))
        (supertag-store-put-entity
         :nodes (car spec)
         (list :id (car spec) :type :node :title (car spec)
               :tags (list (cadr spec)))))
      (supertag-link-create link-id "p1" "task")
      (supertag-link-create link-id "p2" "task")
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (type project) (type task)
         (link tasks :from project :to task
               :from-cardinality many :to-cardinality one)))
      (let* ((migration
              (supertag-ontology-migration-model-normalize
               'missing-resolver
               '(:module work :from 1 :to 2 (tighten-link tasks)) nil))
             (plan (supertag-ontology-migration-plan-build migration)))
        (should (cl-find :missing-link-resolver (plist-get plan :issues)
                         :key (lambda (issue) (plist-get issue :code))))))))

(ert-deftest supertag-migration-v8-rollback-restores-data-and-ledger ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let ((field-id (supertag-migration-v8-test--binding-id :field 'status)))
      (supertag-store-put-entity
       :nodes "node-a" '(:id "node-a" :type :node :title "A" :tags nil))
      (supertag-store-put-field-value "node-a" field-id "doing")
      (let* ((migration (supertag-migration-v8-test--register-status-v2))
             (plan (supertag-ontology-migration-plan-build migration))
             (supertag-ontology-deploy-operation-function
              (lambda (&rest _args) (error "forced deployment failure"))))
        (should-error
         (supertag-ontology-migration-deploy-apply-plan plan))
        (should (equal "doing"
                       (supertag-store-get-field-value "node-a" field-id)))
        (should-not
         (supertag-ontology-migration-runtime-get
          (plist-get migration :logical-id)))
        (should (= 1
                   (plist-get
                    (supertag-ontology-runtime-module-get 'work) :version)))))))


(ert-deftest supertag-migration-v8-cardinality-relaxation-applies-with-instances ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--register-ontology
     '(:version 1
       (type project) (type task)
       (link tasks :from project :to task
             :from-cardinality one :to-cardinality one)))
    (supertag-ontology-apply 'work)
    (let ((project-tag (supertag-migration-v8-test--binding-id :type 'project))
          (task-tag (supertag-migration-v8-test--binding-id :type 'task))
          (link-id (supertag-migration-v8-test--binding-id :link 'tasks)))
      (dolist (spec `(("project" ,project-tag) ("task" ,task-tag)))
        (supertag-store-put-entity
         :nodes (car spec)
         (list :id (car spec) :type :node :title (car spec)
               :tags (list (cadr spec)))))
      (supertag-link-create link-id "project" "task")
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (type project) (type task)
         (link tasks :from project :to task
               :from-cardinality many :to-cardinality many)))
      (supertag-ontology-apply 'work)
      (should (eq :many
                  (plist-get (supertag-link-definition-get link-id)
                             :from-cardinality)))
      (should (eq :many
                  (plist-get (supertag-link-definition-get link-id)
                             :to-cardinality)))
      (should (= 1 (length
                    (supertag-link-definition-instance-relations link-id)))))))

(ert-deftest supertag-migration-v8-loosening-cardinality-is-safe ()
  (let* ((runtime
          '(:kind :link :runtime-id "link-1" :label "Tasks"
            :from-runtime-id "project" :to-runtime-id "task"
            :from-cardinality :one :to-cardinality :one))
         (model
          (supertag-ontology-model-normalize
           'work
           '(:version 2
             (type project :runtime-id "project")
             (type task :runtime-id "task")
             (link tasks :runtime-id "link-1" :from project :to task
                   :from-cardinality many :to-cardinality many)) nil))
         (snapshot
          (list :fields nil
                :types '((:kind :type :runtime-id "project" :label "project"
                          :extends nil :fields nil)
                         (:kind :type :runtime-id "task" :label "task"
                          :extends nil :fields nil))
                :links (list runtime) :bindings nil :modules nil))
         (plan (supertag-ontology-plan-build model snapshot)))
    (should-not (supertag-ontology-plan-destructive-p plan))))

(ert-deftest supertag-migration-v8-rejects-changed-migration-declaration ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let* ((migration (supertag-migration-v8-test--register-status-v2))
           (plan (supertag-ontology-migration-plan-build migration)))
      (supertag-ontology-migration-registry-register
       'status-v2
       '(:module work :from 1 :to 2
         (transform-field status
                          :using supertag-ontology-migration-identity))
       '(:file "changed-migrations.el" :line 9))
      (should-error
       (supertag-ontology-migration-deploy-apply-plan plan)
       :type 'user-error))))

(ert-deftest supertag-migration-v8-rejects-changed-desired-ontology ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--deploy-v1-field)
    (let* ((migration (supertag-migration-v8-test--register-status-v2))
           (plan (supertag-ontology-migration-plan-build migration)))
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (field status :label "Workflow status" :type options
                :options (idea active done))
         (type project :label "Project" :fields (status))))
      (should-error
       (supertag-ontology-migration-deploy-apply-plan plan)
       :type 'user-error))))


(ert-deftest supertag-migration-v8-field-default-and-required-relaxation-are-live-schema ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--register-ontology
     '(:version 1
       (field status :label "Status" :type text
              :required t :default "idea")
       (type project :label "Project" :fields (status))))
    (supertag-ontology-apply 'work)
    (let* ((field-id (supertag-migration-v8-test--binding-id :field 'status))
           (definition (supertag-store-get-field-definition field-id))
           (snapshot-field
            (supertag-ontology-runtime-find
             (supertag-ontology-runtime-snapshot) :field field-id)))
      (should (eq t (plist-get definition :required)))
      (should (equal "idea" (plist-get definition :default)))
      (should (eq t (plist-get snapshot-field :required)))
      (should (equal "idea" (plist-get snapshot-field :default)))
      (supertag-migration-v8-test--register-ontology
       '(:version 2
         (field status :label "Status" :type text
                :required nil :default "active")
         (type project :label "Project" :fields (status))))
      (let ((plan (supertag-ontology-plan-build
                   (supertag-ontology-registry-get 'work))))
        (should-not (supertag-ontology-plan-destructive-p plan))
        (should (cl-find :required
                         (plist-get (car (plist-get plan :operations)) :changes)
                         :key (lambda (change) (plist-get change :slot))))
        (should (cl-find :default
                         (plist-get (car (plist-get plan :operations)) :changes)
                         :key (lambda (change) (plist-get change :slot))))
        (supertag-ontology-apply 'work))
      (setq definition (supertag-store-get-field-definition field-id))
      (should-not (plist-get definition :required))
      (should (equal "active" (plist-get definition :default))))))

(ert-deftest supertag-migration-v8-required-tightening-needs-dedicated-step ()
  (supertag-migration-v8-test--isolated
    (supertag-migration-v8-test--register-ontology
     '(:version 1
       (field status :label "Status" :type text :required nil)
       (type project :label "Project" :fields (status))))
    (supertag-ontology-apply 'work)
    (supertag-migration-v8-test--register-ontology
     '(:version 2
       (field status :label "Status" :type text :required t)
       (type project :label "Project" :fields (status))))
    (let* ((migration
            (supertag-ontology-migration-model-normalize
             'make-status-required
             '(:module work :from 1 :to 2
               (transform-field status
                                :using supertag-ontology-migration-identity))
             nil))
           (plan (supertag-ontology-migration-plan-build migration)))
      (should (supertag-ontology-migration-plan-errors-p plan))
      (should (cl-find :unsupported-required-tightening
                       (plist-get plan :issues)
                       :key (lambda (issue) (plist-get issue :code))))
      ;; transform-field cannot cover missing values, so it remains unused.
      (should (cl-find :unused-step
                       (plist-get plan :issues)
                       :key (lambda (issue) (plist-get issue :code)))))))

(provide 'supertag-ontology-migration-test)
;;; supertag-ontology-migration-test.el ends here
