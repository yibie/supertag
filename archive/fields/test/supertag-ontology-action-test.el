;;; supertag-ontology-action-test.el --- Corrected Function and Action tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'supertag-ontology)
(require 'supertag-ui-action)

(defun supertag-v10-test-progress (_node arguments _context)
  "Return supplied progress or 100."
  (or (car arguments) 100))

(defun supertag-v10-test-explicit-nil (_node arguments _context)
  "Return the first ordered argument, preserving nil."
  (car arguments))

(defun supertag-v10-test-write (_node _arguments _context)
  "Attempt a forbidden Store mutation."
  (supertag-store-put-entity :nodes "forbidden" '(:id "forbidden")))

(defun supertag-v10-test-mutate-copy (node _arguments _context)
  "Mutate NODE's nested hash copy and return true."
  (puthash "changed" t (plist-get node :nested))
  t)

(defun supertag-v10-test-status-active-p (_node _arguments context)
  "Return non-nil when CONTEXT node has active status."
  (equal "active"
         (supertag-store-get-field-value
          (plist-get context :node-id) "status")))

(defmacro supertag-v10-test-with-store (&rest body)
  "Run BODY with isolated Store, event queues, Policy tokens, and registries."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (make-hash-table :test #'equal))
         (supertag--transaction-active nil)
         (supertag--transaction-log nil)
         (supertag-ontology-registry--raw (make-hash-table :test #'equal))
         (supertag-change--subscribers nil)
         (supertag-change--queue nil)
         (supertag-change--dispatching nil)
         (supertag-change--delivering-change-id nil)
         (supertag-ontology-policy--confirmation-tokens
          (make-hash-table :test #'equal))
         (supertag--subscribers (make-hash-table :test #'eq))
         (supertag-after-operation-hook nil)
         (supertag-ops-deferred-event-errors nil)
         (supertag-ontology-action-executed-hook nil)
         (supertag-ontology-action-hook-errors nil)
         (supertag-automation-sync--enabled t))
     (supertag--ensure-store)
     ,@body))

(defun supertag-v10-test-install-project ()
  "Install one Project Type and node."
  (supertag-store-put-entity
   :tags "project"
   '(:id "project" :type :tag :name "Project" :extends nil))
  (supertag-store-put-entity
   :nodes "project-1"
   '(:id "project-1" :type :node :title "One" :tags ("project"))))

(defun supertag-v10-test-install-task ()
  "Install one Task Type and node."
  (supertag-store-put-entity
   :tags "task"
   '(:id "task" :type :tag :name "Task" :extends nil))
  (supertag-store-put-entity
   :nodes "task-1"
   '(:id "task-1" :type :node :title "Task" :tags ("task"))))

(defun supertag-v10-test-install-status-action (&optional sensitive actors)
  "Install one deployed status Action and governing Policy."
  (supertag-v10-test-install-project)
  (supertag-store-put-entity
   :field-definitions "status"
   '(:id "status" :name "Status" :type :options
     :options ("active" "blocked" "done") :required nil))
  (supertag-store-put-entity
   :tag-field-associations "project"
   '((:field-id "status" :order 0)))
  (supertag-store-put-field-value "project-1" "status" "active")
  (supertag-store-put-entity
   :ontology-actions "complete"
   (list :id "complete" :runtime-id "complete"
         :logical-id "work/action/complete" :module 'work :key 'complete
         :label "Complete" :subject-type-id "project"
         :parameters
         (if sensitive
             '((:name value :index 0 :type :string :required t
                :has-default nil :sensitive t :options nil))
           nil)
         :preconditions nil
         :effects
         (list (list :kind :set-field :field "status"
                     :value (if sensitive '(:arg value) "done")))
         :confirmation :never :contract-hash "contract-1"))
  (supertag-store-put-entity
   :ontology-policies "complete-policy"
   (list :id "complete-policy" :runtime-id "complete-policy"
         :logical-id "work/policy/complete-access" :module 'work
         :key 'complete-access :label "Complete Access"
         :action-id "complete" :contract-hash "policy-contract-1"
         :actors
         (or actors
             '((:actor :automation :decision :deny)
               (:actor :external :decision :deny)
               (:actor :interactive-user :decision :allow)
               (:actor :llm :decision :propose-only))))))

(ert-deftest supertag-v10-function-parameter-order-is-semantic ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 10
             (type project :label "Project")
             (function progress :subject project
                       :parameters ((horizon :type integer)
                                    (blocked :type boolean))
                       :returns number
                       :implementation supertag-v10-test-progress)) nil))
         (function (car (plist-get model :functions))))
    (should (equal '(horizon blocked)
                   (mapcar (lambda (parameter)
                             (plist-get parameter :name))
                           (plist-get function :parameters))))))

(ert-deftest supertag-v10-contract-distinguishes-missing-nil-false-and-empty-list ()
  (let* ((parameters
          (supertag-ontology-contract-normalize-parameters
           '((flag :type (:maybe boolean) :default t)
             (items :type (:list string) :required nil))))
         (explicit
          (supertag-ontology-contract-bind-arguments
           parameters '(:flag nil :items ())))
         (omitted
          (supertag-ontology-contract-bind-arguments parameters nil)))
    (should (supertag-ontology-contract-argument-present-p 'flag explicit))
    (should (null (supertag-ontology-contract-argument 'flag explicit :missing)))
    (should (equal '() (supertag-ontology-contract-argument 'items explicit)))
    (should (eq t (supertag-ontology-contract-argument 'flag omitted)))
    (should-not (supertag-ontology-contract-argument-present-p 'items omitted))))

(ert-deftest supertag-v10-validator-accepts-anchored-behavior-and-policy ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 11
             (field status :type options :options (active done))
             (type project :fields (status))
             (function progress :subject project :returns number
                       :implementation supertag-v10-test-progress)
             (action complete :subject project
                     :preconditions
                     ((function progress :operator :equal :value 100))
                     :effects ((set-field status :value "done")))
             (policy complete-access :action complete
                     :actors ((interactive-user allow) (automation deny)
                              (llm propose-only) (external deny)))) nil)))
    (should-not
     (supertag-ontology-validator-errors-p
      (supertag-ontology-validator-validate model)))))

(ert-deftest supertag-v10-validator-rejects-unanchored-link-and-node-reference-field ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 11
             (field owner :type node-reference)
             (type project :fields (owner))
             (type person)
             (link reviewer :from project :to person)
             (action invalid :subject project
                     :parameters ((person :type node-reference :required nil))
                     :effects
                     ((set-field owner :value (:arg person))
                      (:kind :add-link :link reviewer
                       :from (:arg person) :to "other")))
             (policy invalid-access :action invalid
                     :actors ((interactive-user deny) (automation deny)
                              (llm deny) (external deny)))) nil))
         (issues (supertag-ontology-validator-validate model)))
    (should (cl-find :node-reference-field-effect issues
                     :key (lambda (issue) (plist-get issue :code))))
    (should (cl-find :unanchored-action-link issues
                     :key (lambda (issue) (plist-get issue :code))))
    (should (cl-find :optional-expression-argument issues
                     :key (lambda (issue) (plist-get issue :code))))))

(ert-deftest supertag-v10-validator-rejects-incompatible-precondition-contract ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 11
             (type project)
             (type task)
             (function task-ready :subject task
                       :parameters ((mode :type options
                                          :options (safe fast)
                                          :required t))
                       :returns boolean
                       :implementation supertag-v10-test-progress)
             (action complete :subject project
                     :parameters ((mode :type options
                                        :options (safe dangerous)
                                        :required t))
                     :preconditions
                     ((function task-ready
                                :arguments (:mode (:arg mode))))
                     :effects ((:kind :clear-field :field missing)))
             (policy complete-access :action complete
                     :actors ((interactive-user deny) (automation deny)
                              (llm deny) (external deny)))) nil))
         (issues (supertag-ontology-validator-validate model)))
    (should (cl-find :incompatible-precondition-subject issues
                     :key (lambda (issue) (plist-get issue :code))))
    (should (cl-find :incompatible-precondition-argument issues
                     :key (lambda (issue) (plist-get issue :code))))))

(ert-deftest supertag-v10-control-plane-requires-behavioral-approval ()
  (supertag-v10-test-with-store
    (let* ((model
            (supertag-ontology-model-normalize
             'work
             '(:version 11
               (field status :type options :options (active done))
               (type project :fields (status))
               (function progress :subject project :returns number
                         :implementation supertag-v10-test-progress)
               (action complete :subject project
                       :effects ((set-field status :value "done")))
               (policy complete-access :action complete
                       :actors ((interactive-user allow) (automation deny)
                                (llm propose-only) (external deny)))) nil))
           (plan (supertag-ontology-plan-build model)))
      (should-not (supertag-ontology-plan-errors-p plan))
      (should (supertag-ontology-plan-behavioral-p plan))
      (should-not (supertag-ontology-plan-safe-p plan))
      (should-error (supertag-ontology-deploy-apply-plan plan))
      (supertag-ontology-deploy-apply-plan plan t)
      (should (= 1 (hash-table-count
                    (supertag-store-get-collection :ontology-functions))))
      (should (= 1 (hash-table-count
                    (supertag-store-get-collection :ontology-actions))))
      (should (= 1 (hash-table-count
                    (supertag-store-get-collection :ontology-policies)))))))

(ert-deftest supertag-v10-function-read-only-seam-and-defensive-copy ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (let ((nested (make-hash-table :test #'equal)))
      (puthash "stable" '(:value 1) nested)
      (supertag-store-put-entity
       :nodes "project-1"
       (plist-put (supertag-store-get-entity :nodes "project-1")
                  :nested nested)))
    (supertag-store-put-entity
     :ontology-functions "fn-write"
     '(:id "fn-write" :runtime-id "fn-write"
       :logical-id "work/function/write" :module work :key write
       :label "Write" :subject-type-id "project" :parameters nil
       :returns :any :implementation supertag-v10-test-write))
    (supertag-store-put-entity
     :ontology-functions "fn-copy"
     '(:id "fn-copy" :runtime-id "fn-copy"
       :logical-id "work/function/copy" :module work :key copy
       :label "Copy" :subject-type-id "project" :parameters nil
       :returns :boolean :implementation supertag-v10-test-mutate-copy))
    (should-error
     (supertag-ontology-function-call "fn-write" "project-1"))
    (should-not (supertag-store-get-entity :nodes "forbidden"))
    (should
     (supertag-ontology-function-call "fn-copy" "project-1"))
    (should-not
     (gethash "changed"
              (plist-get (supertag-store-get-entity :nodes "project-1")
                         :nested)))))

(ert-deftest supertag-v10-action-rechecks-precondition-inside-transaction ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (supertag-store-put-entity
     :ontology-functions "active-p"
     '(:id "active-p" :runtime-id "active-p"
       :logical-id "work/function/active-p" :module work :key active-p
       :label "Active?" :subject-type-id "project" :parameters nil
       :returns :boolean :implementation supertag-v10-test-status-active-p))
    (let ((action (supertag-store-get-entity :ontology-actions "complete")))
      (supertag-store-put-entity
       :ontology-actions "complete"
       (plist-put action :preconditions
                  '((:function "active-p" :operator :truthy)))))
    (let ((original (symbol-function 'supertag-change-commit)))
      (cl-letf (((symbol-function 'supertag-change-commit)
                 (lambda (envelope thunk)
                   ;; Change the business fact after the UI preview but before
                   ;; the Action transaction owns the final decision.
                   (supertag-store-put-field-value
                    "project-1" "status" "blocked")
                   (funcall original envelope thunk))))
        (should-error
         (supertag-ontology-action-execute
          "complete" "project-1" nil :interactive-user))))
    (should (equal "blocked"
                   (supertag-store-get-field-value "project-1" "status")))
    (should (= 0 (hash-table-count
                  (supertag-store-get-collection
                   :ontology-action-executions))))))

(ert-deftest supertag-v10-action-commits-field-and-audit-together ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (let ((record
           (supertag-ontology-action-execute
            "complete" "project-1" nil :interactive-user)))
      (should (equal "done"
                     (supertag-store-get-field-value "project-1" "status")))
      (should (equal :succeeded (plist-get record :status)))
      (should (equal :allow
                     (plist-get (plist-get record :policy) :decision)))
      (should (= 1 (hash-table-count
                    (supertag-store-get-collection
                     :ontology-action-executions)))))))

(ert-deftest supertag-v10-action-audit-redacts-and-omits-field-values ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action t
     '((:actor :automation :decision :deny)
       (:actor :external :decision :deny)
       (:actor :interactive-user :decision :allow)
       (:actor :llm :decision :allow)))
    (let* ((record
            (supertag-ontology-action-execute
             "complete" "project-1" '(:value "done") :llm))
           (effect (car (plist-get record :effects))))
      (should (equal '((value . :redacted))
                     (plist-get record :arguments)))
      (should-not (plist-member effect :old))
      (should-not (plist-member effect :new))
      (should (eq :set-field (plist-get effect :kind))))))

(ert-deftest supertag-v10-action-rolls-back-and-drops-deferred-events ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (supertag-v10-test-install-task)
    (supertag-link-definition-create
     '(:id "project-tasks" :name "Tasks"
       :from-tag-id "project" :to-tag-id "task"
       :from-cardinality :many :to-cardinality :one))
    (let ((action (supertag-store-get-entity :ontology-actions "complete"))
          delivered)
      (setq action
            (plist-put
             action :effects
             '((:kind :set-field :field "status" :value "done")
               (:kind :add-link :link "project-tasks"
                :direction :forward :target "task-1"))))
      (supertag-store-put-entity :ontology-actions "complete" action)
      (add-hook 'supertag-after-operation-hook
                (lambda (event) (push event delivered)))
      (cl-letf (((symbol-function 'supertag-link-create)
                 (lambda (&rest _args) (error "link failed"))))
        (should-error
         (supertag-ontology-action-execute
          "complete" "project-1" nil :interactive-user)))
      (should (equal "active"
                     (supertag-store-get-field-value "project-1" "status")))
      (should-not delivered)
      (should (= 0 (hash-table-count
                    (supertag-store-get-collection
                     :ontology-action-executions)))))))

(ert-deftest supertag-v10-applicability-does-not-run-preconditions ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (let ((called 0))
      (cl-letf (((symbol-function 'supertag-ontology-function-call)
                 (lambda (&rest _) (cl-incf called) t)))
        (should (= 1 (length
                      (supertag-ontology-action-applicable "project-1"))))
        (should (= called 0))))))

(provide 'supertag-ontology-action-test)
;;; supertag-ontology-action-test.el ends here
