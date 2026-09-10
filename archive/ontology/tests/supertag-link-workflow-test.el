;;; supertag-link-workflow-test.el --- Link workflow and query tests. -*- lexical-binding: t; -*-

(require 'ert)
(require 'ht)
(require 'cl-lib)
(require 'supertag-core-store)
(require 'supertag-core-index)
(require 'supertag-tag)
(require 'supertag-ops-global-field)
(require 'supertag-ops-link-definition)
(require 'supertag-link)
(require 'supertag-link)
(require 'supertag-query)
(require 'supertag-view-schema)
(require 'supertag-ontology)

(defmacro supertag-v5-test--isolated (&rest body)
  (declare (indent 0))
  `(let ((supertag--store (ht-create))
         (supertag-ontology-registry--raw (make-hash-table :test #'equal))
         (supertag-ontology-runtime-tags-provider nil)
         (supertag-ontology-runtime-fields-provider nil)
         (supertag-ontology-runtime-associations-provider nil)
         (supertag-ontology-runtime-links-provider nil)
         (supertag-schema-authority-provider-function nil))
     (supertag--ensure-store)
     (supertag-index-clear-all)
     ,@body))

(defun supertag-v5-test--put-tag (id name &optional extends)
  (supertag-store-put-entity
   :tags id (list :id id :name name :type :tag :extends extends)))

(defun supertag-v5-test--put-node (id title tags)
  (supertag-store-put-entity
   :nodes id (list :id id :title title :type :node :tags tags)))

(defun supertag-v5-test--put-definition
    (id name from to &optional from-card to-card module key)
  (supertag-link-definition-create
   (list :id id :name name :from-tag-id from :to-tag-id to
         :from-cardinality (or from-card :many)
         :to-cardinality (or to-card :many)
         :managed-by (if module :ontology :interactive)
         :ontology-module module :ontology-key key)))

(ert-deftest supertag-v5-logical-identity-is-readable-and-module-aware ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work '(:version 1 (type project :label "Project")) nil))
         (entity (car (plist-get model :types))))
    (should (eq 'work (plist-get entity :module)))
    (should (equal "work/type/project" (plist-get entity :logical-id)))))

(ert-deftest supertag-v5-field-types-and-options-normalize-for-runtime ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 1
             (field title :type text)
             (field status :type options :options (idea active done))
             (field parent :type reference))
           nil))
         (fields (plist-get model :fields)))
    (should (eq :string (plist-get (nth 0 fields) :type)))
    (should (eq :options (plist-get (nth 1 fields) :type)))
    (should (equal '("idea" "active" "done")
                   (plist-get (nth 1 fields) :options)))
    (should (eq :node-reference (plist-get (nth 2 fields) :type)))
    (should-not (supertag-ontology-validator-validate model))))

(ert-deftest supertag-v5-validator-rejects-unsupported-field-type ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work '(:version 1 (field mystery :type quantum)) nil))
         (issues (supertag-ontology-validator-validate model)))
    (should (cl-find :invalid-field-type issues
                     :key (lambda (issue) (plist-get issue :code))))))

(ert-deftest supertag-v5-runtime-snapshot-reads-real-associations ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-project" "Project")
    (supertag-store-put-field-definition
     "status" '(:id "status" :name "Status" :type :string))
    (supertag-store-put-tag-field-associations
     "tag-project" '((:field-id "status" :order 0)))
    (let* ((snapshot (supertag-ontology-runtime-snapshot))
           (type (supertag-ontology-runtime-find snapshot :type "tag-project")))
      (should (equal '("status") (plist-get type :fields))))))

(ert-deftest supertag-v5-binding-is-a-canonical-store-entity ()
  (supertag-v5-test--isolated
    (supertag-ontology-runtime-binding-put
     '(:owner :ontology :module work :kind :type :key project
       :logical-id "work/type/project" :runtime-id "tag-project"))
    (should (gethash "work|:type|project"
                     (supertag-store-get-collection :ontology-bindings)))
    (should (equal "tag-project"
                   (plist-get
                    (supertag-ontology-runtime-binding-get 'work :type 'project)
                    :runtime-id)))))

(ert-deftest supertag-v5-explicit-adoption-produces-binding-operation ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-project" "Project")
    (let* ((model
            (supertag-ontology-model-normalize
             'work '(:version 1
                     (type project :runtime-id "tag-project" :label "Project"))
             '(:file "work.el" :line 1)))
           (plan (supertag-ontology-plan-build model)))
      (should (eq :bind-entity
                  (plist-get (car (plist-get plan :operations)) :operation))))))

(ert-deftest supertag-v5-deploys-field-type-association-and-link-end-to-end ()
  (supertag-v5-test--isolated
    (let* ((model
            (supertag-ontology-model-normalize
             'work '(:version 1
                     (field status :label "Status" :type :string)
                     (type project :label "Project" :fields (status))
                     (type task :label "Task")
                     (link tasks :label "Tasks" :inverse-label "Project"
                           :from project :to task
                           :from-cardinality many :to-cardinality one))
             '(:file "work.el" :line 1)))
           (plan (supertag-ontology-plan-build model)))
      (should (supertag-ontology-plan-safe-p plan))
      (supertag-ontology-deploy-apply-plan plan)
      (let* ((project-binding
              (supertag-ontology-runtime-binding-get 'work :type 'project))
             (field-binding
              (supertag-ontology-runtime-binding-get 'work :field 'status))
             (link-binding
              (supertag-ontology-runtime-binding-get 'work :link 'tasks))
             (associations
              (supertag-store-get-tag-field-associations
               (plist-get project-binding :runtime-id))))
        (should project-binding)
        (should field-binding)
        (should link-binding)
        (should (equal (plist-get field-binding :runtime-id)
                       (plist-get (car associations) :field-id)))
        (should (supertag-link-definition-get
                 (plist-get link-binding :runtime-id))))
      (should (supertag-ontology-plan-empty-p
               (supertag-ontology-plan-build model))))))

(ert-deftest supertag-v5-stale-plan-is-rejected ()
  (supertag-v5-test--isolated
    (let* ((model
            (supertag-ontology-model-normalize
             'work '(:version 1 (type project :label "Project"))
             '(:file "work.el" :line 1)))
           (plan (supertag-ontology-plan-build model)))
      (supertag-v5-test--put-tag "tag-other" "Other")
      (should-error (supertag-ontology-deploy-apply-plan plan)))))

(ert-deftest supertag-v5-noop-plan-does-not-enter-transaction ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-project" "Project")
    (let* ((model
            (supertag-ontology-model-normalize
             'work '(:version 1
                     (type project :runtime-id "tag-project" :label "Project"))
             '(:file "work.el" :line 1)))
           (model-hash (supertag-ontology-model-hash model))
           (transactions 0))
      (supertag-ontology-runtime-binding-put
       '(:owner :ontology :module work :kind :type :key project
         :logical-id "work/type/project" :runtime-id "tag-project"))
      (supertag-ontology-runtime-module-put
       (list :module 'work :version 1 :model-hash model-hash
             :source-file "work.el"))
      (let* ((plan (supertag-ontology-plan-build model))
             (supertag-ontology-deploy-transaction-function
              (lambda (thunk) (cl-incf transactions) (funcall thunk))))
        (should (supertag-ontology-plan-empty-p plan))
        (supertag-ontology-deploy-apply-plan plan)
        (should (= 0 transactions))))))

(ert-deftest supertag-v5-link-definition-resolver-is-explicit-on-ambiguity ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-a" "A")
    (supertag-v5-test--put-tag "tag-b" "B")
    (supertag-v5-test--put-definition
     "link-1" "Links" "tag-a" "tag-b" nil nil 'work 'related)
    (supertag-v5-test--put-definition
     "link-2" "Links" "tag-a" "tag-b" nil nil 'personal 'related)
    (should (equal "link-1"
                   (plist-get (supertag-link-definition-resolve "work/related")
                              :id)))
    (should-error (supertag-link-definition-resolve 'related))))

(ert-deftest supertag-v5-link-service-exposes-both-directions ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-project" "Project")
    (supertag-v5-test--put-tag "tag-task" "Task")
    (supertag-v5-test--put-node "project" "Project A" '("tag-project"))
    (supertag-v5-test--put-node "task" "Task A" '("tag-task"))
    (supertag-v5-test--put-definition
     "tasks" "Tasks" "tag-project" "tag-task")
    (should (eq :out
                (plist-get (car (supertag-link-service-directions "project"))
                           :direction)))
    (should (eq :in
                (plist-get (car (supertag-link-service-directions "task"))
                           :direction)))))

(ert-deftest supertag-v5-candidate-filter-respects-endpoint-type ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-project" "Project")
    (supertag-v5-test--put-tag "tag-task" "Task")
    (supertag-v5-test--put-node "project" "Project" '("tag-project"))
    (supertag-v5-test--put-node "task" "Task" '("tag-task"))
    (supertag-v5-test--put-node "other" "Other" '("tag-project"))
    (supertag-v5-test--put-definition
     "tasks" "Tasks" "tag-project" "tag-task")
    (let ((direction (car (supertag-link-service-directions "project"))))
      (should (equal '("task")
                     (supertag-link-service-candidate-node-ids
                      "project" direction))))))

(ert-deftest supertag-v5-replace-conflicts-is-atomic-domain-operation ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-person" "Person")
    (supertag-v5-test--put-tag "tag-team" "Team")
    (supertag-v5-test--put-node "person" "Person" '("tag-person"))
    (supertag-v5-test--put-node "team-a" "A" '("tag-team"))
    (supertag-v5-test--put-node "team-b" "B" '("tag-team"))
    (supertag-v5-test--put-definition
     "team" "Team" "tag-person" "tag-team" :one :many)
    (supertag-link-create "team" "person" "team-a")
    (supertag-link-create-replacing-conflicts "team" "person" "team-b")
    (should (equal '("team-b") (supertag-link-targets "team" "person")))))

(ert-deftest supertag-v5-link-query-operators-compose-with-existing-query ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-project" "Project")
    (supertag-v5-test--put-tag "tag-task" "Task")
    (supertag-v5-test--put-node "project-a" "A" '("tag-project"))
    (supertag-v5-test--put-node "project-b" "B" '("tag-project"))
    (supertag-v5-test--put-node "task-a" "Task" '("tag-task"))
    (supertag-v5-test--put-definition
     "tasks" "Tasks" "tag-project" "tag-task")
    (supertag-link-create "tasks" "project-a" "task-a")
    (should (equal '("project-a")
                   (supertag-query-node-ids
                    '(and (tag "tag-project")
                          (link "tasks" (tag "tag-task"))))))
    (should (equal '("task-a")
                   (supertag-query-node-ids
                    '(reverse-link "tasks" (tag "tag-project")))))
    (should (equal '("project-a")
                   (supertag-query-node-ids '(has-link "tasks"))))))

(ert-deftest supertag-v5-schema-link-projection-carries-stable-context ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-a" "A")
    (supertag-v5-test--put-tag "tag-b" "B")
    (supertag-v5-test--put-definition "related" "Related" "tag-a" "tag-b")
    (with-temp-buffer
      (supertag-schema--insert-link-definitions
       (plist-get (supertag-schema--build-view-state nil)
                  :link-definitions))
      (goto-char (point-min))
      (search-forward "Related")
      (let ((context (get-text-property (line-beginning-position)
                                        'supertag-context)))
        (should (eq :link-definition (plist-get context :type)))
        (should (equal "related" (plist-get context :link-definition-id)))))))



(ert-deftest supertag-v5-validator-rejects-duplicate-runtime-id-and-label ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 1
             (type project :runtime-id "tag-shared" :label "Work Item")
             (type task :runtime-id "tag-shared" :label "Work Item"))
           nil))
         (issues (supertag-ontology-validator-validate model)))
    (should (cl-find :duplicate-runtime-id issues
                     :key (lambda (issue) (plist-get issue :code))))
    (should (cl-find :duplicate-label issues
                     :key (lambda (issue) (plist-get issue :code))))))

(ert-deftest supertag-v5-plan-is-pure-with-respect-to-supplied-snapshot ()
  (supertag-v5-test--isolated
    ;; Live Store contains a binding that is deliberately absent from SNAPSHOT.
    (supertag-v5-test--put-tag "tag-live" "Live Project")
    (supertag-ontology-runtime-binding-put
     '(:owner :ontology :managed-by :ontology
       :module work :kind :type :key project
       :logical-id "work/type/project" :runtime-id "tag-live"))
    (let* ((model
            (supertag-ontology-model-normalize
             'work '(:version 1 (type project :label "Project")) nil))
           (snapshot
            '(:fields nil :types nil :links nil
              :bindings nil :modules nil))
           (plan (supertag-ontology-plan-build model snapshot)))
      (should-not (supertag-ontology-plan-errors-p plan))
      (should (eq :create-type
                  (plist-get (car (plist-get plan :operations)) :operation))))))

(ert-deftest supertag-v5-legacy-control-metadata-migrates-on-apply ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-project" "Project")
    (let ((bindings (make-hash-table :test #'equal))
          (modules (make-hash-table :test #'equal)))
      (puthash "work|:type|project"
               '(:owner :ontology :managed-by :ontology
                 :module work :kind :type :key project
                 :logical-id "work/:type/project"
                 :runtime-id "tag-project")
               bindings)
      (puthash 'work
               '(:module work :version 1 :model-hash "legacy")
               modules)
      (puthash :ontology-control-plane
               (list :version 1 :bindings bindings :modules modules)
               supertag--store))
    (let* ((model
            (supertag-ontology-model-normalize
             'work
             '(:version 1
               (type project :runtime-id "tag-project" :label "Project"))
             nil))
           (plan (supertag-ontology-plan-build model)))
      (should-not (supertag-ontology-plan-errors-p plan))
      (should (cl-find :bind-entity (plist-get plan :operations)
                       :key (lambda (operation)
                              (plist-get operation :operation))))
      (supertag-ontology-deploy-apply-plan plan)
      (let ((binding
             (supertag-store-get-entity
              :ontology-bindings "work|:type|project")))
        (should binding)
        (should (equal "work/type/project"
                       (plist-get binding :logical-id))))
      (should (supertag-store-get-entity :ontology-modules "work")))))

(ert-deftest supertag-v5-link-query-supports-reverse-existence-and-nesting ()
  (supertag-v5-test--isolated
    (supertag-v5-test--put-tag "tag-project" "Project")
    (supertag-v5-test--put-tag "tag-task" "Task")
    (supertag-v5-test--put-tag "tag-person" "Person")
    (supertag-v5-test--put-node "project-1" "Project 1" '("tag-project"))
    (supertag-v5-test--put-node "task-1" "Task 1" '("tag-task"))
    (supertag-v5-test--put-node "person-1" "Person 1" '("tag-person"))
    (supertag-v5-test--put-definition
     "link-tasks" "Tasks" "tag-project" "tag-task" :many :one 'work 'tasks)
    (supertag-v5-test--put-definition
     "link-assignee" "Assignee" "tag-task" "tag-person" :one :many 'work 'assignee)
    (supertag-link-create "link-tasks" "project-1" "task-1")
    (supertag-link-create "link-assignee" "task-1" "person-1")
    (should (equal '("task-1")
                   (supertag-query-node-ids
                    '(has-reverse-link work/tasks))))
    (should (equal '("project-1")
                   (supertag-query-node-ids
                    '(exists-link work/tasks (tag "tag-task")))))
    (should (equal '("project-1")
                   (supertag-query-node-ids
                    '(link work/tasks
                           (link work/assignee
                                 (tag "tag-person"))))))))

(provide 'supertag-link-workflow-test)
;;; supertag-link-workflow-test.el ends here
