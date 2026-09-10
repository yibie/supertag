;;; supertag-link-test.el --- Tests for typed Link Definitions -*- lexical-binding: t; -*-

(require 'ert)
(require 'ht)
(require 'supertag-core-store)
(require 'supertag-core-index)
(require 'supertag-ops-link-definition)
(require 'supertag-link)
(require 'supertag-ontology)
(require 'supertag-migration)

(defmacro supertag-link-test--isolated (&rest body)
  "Run BODY with an empty Store and isolated Ontology registry."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (ht-create))
         (supertag-ontology-registry--raw (make-hash-table :test #'equal))
         (supertag-ontology-runtime-tags-provider nil)
         (supertag-ontology-runtime-fields-provider nil)
         (supertag-ontology-runtime-associations-provider nil)
         (supertag-ontology-runtime-links-provider nil))
     (supertag--ensure-store)
     (supertag-index-clear-all)
     ,@body))

(defun supertag-link-test--put-tag (id &optional extends)
  "Insert test Tag ID with optional EXTENDS parent."
  (supertag-store-put-entity
   :tags id
   (list :id id :name id :type :tag :aliases (list id)
         :extends extends :created-at (current-time)
         :modified-at (current-time))))

(defun supertag-link-test--put-node (id tags)
  "Insert test node ID carrying TAGS."
  (supertag-store-put-entity
   :nodes id
   (list :id id :title id :type :node :tags tags
         :created-at (current-time) :modified-at (current-time))))

(defun supertag-link-test--definition
    (id from-tag to-tag &optional from-cardinality to-cardinality)
  "Create a test Link Definition and return it."
  (supertag-link-definition-create
   (list :id id :name id
         :from-tag-id from-tag :to-tag-id to-tag
         :from-cardinality (or from-cardinality :many)
         :to-cardinality (or to-cardinality :many))))

(ert-deftest supertag-link-definition-is-not-a-relation-instance ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-project")
    (supertag-link-test--put-tag "tag-task")
    (supertag-link-test--definition
     "linkdef-tasks" "tag-project" "tag-task")
    (should (supertag-link-definition-get "linkdef-tasks"))
    (should (= 1 (hash-table-count
                  (supertag-store-get-collection :link-definitions))))
    (should (= 0 (hash-table-count
                  (supertag-store-get-collection :relations))))))

(ert-deftest supertag-link-create-persists-a-typed-instance ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-project")
    (supertag-link-test--put-tag "tag-task")
    (supertag-link-test--put-node "project-a" '("tag-project"))
    (supertag-link-test--put-node "task-a" '("tag-task"))
    (supertag-link-test--definition
     "linkdef-tasks" "tag-project" "tag-task")
    (let ((relation
           (supertag-link-create
            "linkdef-tasks" "project-a" "task-a")))
      (should (eq :ontology-link (plist-get relation :type)))
      (should (eq :semantic-edge (plist-get relation :kind)))
      (should (equal "linkdef-tasks"
                     (plist-get relation :link-definition-id)))
      (should (equal '("task-a")
                     (supertag-link-targets
                      "linkdef-tasks" "project-a"))))))

(ert-deftest supertag-link-create-rejects-invalid-endpoint-type ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-project")
    (supertag-link-test--put-tag "tag-task")
    (supertag-link-test--put-node "project-a" '("tag-project"))
    (supertag-link-test--put-node "wrong-target" '("tag-project"))
    (supertag-link-test--definition
     "linkdef-tasks" "tag-project" "tag-task")
    (should-error
     (supertag-link-create
      "linkdef-tasks" "project-a" "wrong-target"))))

(ert-deftest supertag-link-endpoint-accepts-subtype-membership ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-work-item")
    (supertag-link-test--put-tag "tag-task" "tag-work-item")
    (supertag-link-test--put-tag "tag-project")
    (supertag-link-test--put-node "project-a" '("tag-project"))
    (supertag-link-test--put-node "task-a" '("tag-task"))
    (supertag-link-test--definition
     "linkdef-items" "tag-project" "tag-work-item")
    (should
     (supertag-link-create
      "linkdef-items" "project-a" "task-a"))))

(ert-deftest supertag-link-enforces-one-target-per-source ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-person")
    (supertag-link-test--put-tag "tag-team")
    (supertag-link-test--put-node "person-a" '("tag-person"))
    (supertag-link-test--put-node "team-a" '("tag-team"))
    (supertag-link-test--put-node "team-b" '("tag-team"))
    (supertag-link-test--definition
     "linkdef-team" "tag-person" "tag-team" :one :many)
    (supertag-link-create "linkdef-team" "person-a" "team-a")
    (should-error
     (supertag-link-create "linkdef-team" "person-a" "team-b"))))

(ert-deftest supertag-link-enforces-one-source-per-target ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-project")
    (supertag-link-test--put-tag "tag-task")
    (supertag-link-test--put-node "project-a" '("tag-project"))
    (supertag-link-test--put-node "project-b" '("tag-project"))
    (supertag-link-test--put-node "task-a" '("tag-task"))
    (supertag-link-test--definition
     "linkdef-tasks" "tag-project" "tag-task" :many :one)
    (supertag-link-create "linkdef-tasks" "project-a" "task-a")
    (should-error
     (supertag-link-create "linkdef-tasks" "project-b" "task-a"))))

(ert-deftest supertag-ontology-link-requires-a-definition-id ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-a")
    (supertag-link-test--put-tag "tag-b")
    (supertag-link-test--put-node "node-a" '("tag-a"))
    (supertag-link-test--put-node "node-b" '("tag-b"))
    (should-error
     (supertag-relation-create
      '(:type :ontology-link :kind :semantic-edge :origin :semantic
        :from "node-a" :to "node-b")))))

(ert-deftest supertag-link-definition-participates-in-relation-identity ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-a")
    (supertag-link-test--put-tag "tag-b")
    (supertag-link-test--put-node "node-a" '("tag-a"))
    (supertag-link-test--put-node "node-b" '("tag-b"))
    (supertag-link-test--definition "linkdef-one" "tag-a" "tag-b")
    (supertag-link-test--definition "linkdef-two" "tag-a" "tag-b")
    (let ((one (supertag-link-create "linkdef-one" "node-a" "node-b"))
          (two (supertag-link-create "linkdef-two" "node-a" "node-b")))
      (should-not (equal (plist-get one :id) (plist-get two :id)))
      (should (= 2 (hash-table-count
                    (supertag-store-get-collection :relations)))))))

(ert-deftest supertag-link-duplicate-cleanup-preserves-distinct-definitions ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-a")
    (supertag-link-test--put-tag "tag-b")
    (supertag-link-test--put-node "node-a" '("tag-a"))
    (supertag-link-test--put-node "node-b" '("tag-b"))
    (supertag-link-test--definition "linkdef-one" "tag-a" "tag-b")
    (supertag-link-test--definition "linkdef-two" "tag-a" "tag-b")
    (supertag-link-create "linkdef-one" "node-a" "node-b")
    (supertag-link-create "linkdef-two" "node-a" "node-b")
    (should (= 0 (supertag-relation-cleanup-duplicates)))
    (should (= 2 (hash-table-count
                  (supertag-store-get-collection :relations))))))

(ert-deftest supertag-link-relation-identity-cannot-change-in-place ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-a")
    (supertag-link-test--put-tag "tag-b")
    (supertag-link-test--put-node "node-a" '("tag-a"))
    (supertag-link-test--put-node "node-b" '("tag-b"))
    (supertag-link-test--definition "linkdef-one" "tag-a" "tag-b")
    (supertag-link-test--definition "linkdef-two" "tag-a" "tag-b")
    (let ((relation
           (supertag-link-create "linkdef-one" "node-a" "node-b")))
      (should-error
       (supertag-relation-update
        (plist-get relation :id)
        (lambda (current)
          (plist-put current :link-definition-id "linkdef-two"))))
      (should (equal "linkdef-one"
                     (plist-get
                      (supertag-relation-get (plist-get relation :id))
                      :link-definition-id))))))

(ert-deftest supertag-link-definition-cannot-be-rebound-between-ontologies ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-a")
    (supertag-link-test--put-tag "tag-b")
    (let ((supertag-link-definition--deployment-in-progress t))
      (supertag-link-definition-create
       '(:id "linkdef-one" :name "One"
         :from-tag-id "tag-a" :to-tag-id "tag-b"
         :managed-by :ontology :ontology-module work
         :ontology-key links)))
    (let ((supertag-link-definition--deployment-in-progress t))
      (should-error
       (supertag-link-definition-update
        "linkdef-one"
        (lambda (current)
          (setq current (plist-put current :ontology-module 'other))
          current))))))

(ert-deftest supertag-link-definition-delete-protects-instances ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-a")
    (supertag-link-test--put-tag "tag-b")
    (supertag-link-test--put-node "node-a" '("tag-a"))
    (supertag-link-test--put-node "node-b" '("tag-b"))
    (supertag-link-test--definition "linkdef-one" "tag-a" "tag-b")
    (supertag-link-create "linkdef-one" "node-a" "node-b")
    (should-error (supertag-link-definition-delete "linkdef-one"))
    (supertag-link-definition-delete "linkdef-one" t)
    (should-not (supertag-link-definition-get "linkdef-one"))
    (should (= 0 (hash-table-count
                  (supertag-store-get-collection :relations))))))

(ert-deftest supertag-link-definition-protects-endpoint-tags ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "tag-a")
    (supertag-link-test--put-tag "tag-b")
    (supertag-link-test--definition "linkdef-one" "tag-a" "tag-b")
    (should-error
     (supertag-link-definition-assert-tag-deletable "tag-a"))))

(ert-deftest supertag-ontology-normalizes-and-validates-link-definitions ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 1
             (type project :label "Project")
             (type task :label "Task")
             (link tasks :from project :to task
                         :from-cardinality many
                         :to-cardinality one))
           '(:file "work.el" :line 1)))
         (issues (supertag-ontology-validator-validate model))
         (link (car (plist-get model :links))))
    (should-not issues)
    (should (eq 'project (plist-get link :from)))
    (should (eq 'task (plist-get link :to)))
    (should (eq :many (plist-get link :from-cardinality)))
    (should (eq :one (plist-get link :to-cardinality)))))

(ert-deftest supertag-ontology-apply-creates-definition-not-instance ()
  (supertag-link-test--isolated
    (supertag-ontology-registry-register
     'work
     '(:version 1
       (type project :label "Project")
       (type task :label "Task")
       (link tasks :label "Tasks" :from project :to task
                   :from-cardinality many
                   :to-cardinality one))
     '(:file "work.el" :line 1))
    (supertag-ontology-apply 'work)
    (let ((definition
           (supertag-link-definition-find-by-ontology-key 'work 'tasks)))
      (should definition)
      (should (eq :ontology (plist-get definition :managed-by)))
      (should (= 0 (hash-table-count
                    (supertag-store-get-collection :relations)))))))

(ert-deftest supertag-ontology-link-cardinality-change-is-destructive ()
  (supertag-link-test--isolated
    (supertag-ontology-registry-register
     'work
     '(:version 1
       (type project :label "Project")
       (type task :label "Task")
       (link tasks :label "Tasks" :from project :to task
                   :from-cardinality many))
     '(:file "work.el" :line 1))
    (supertag-ontology-apply 'work)
    (supertag-ontology-registry-register
     'work
     '(:version 2
       (type project :label "Project")
       (type task :label "Task")
       (link tasks :label "Tasks" :from project :to task
                   :from-cardinality one))
     '(:file "work.el" :line 1))
    (let* ((model (supertag-ontology-registry-get 'work))
           (plan (supertag-ontology-plan-build model)))
      (should (supertag-ontology-plan-destructive-p plan)))))

(ert-deftest supertag-stable-tag-migration-rewrites-link-definition-endpoints ()
  (supertag-link-test--isolated
    (supertag-link-test--put-tag "project")
    (supertag-link-test--put-tag "task")
    (supertag-link-test--definition
     "linkdef-tasks" "project" "task")
    (let ((mapping
           '(("project" . "tag-11111111111111111111111111111111")
             ("task" . "tag-22222222222222222222222222222222"))))
      (supertag-migration--rewrite-stable-tag-link-definitions mapping)
      (let ((definition
             (supertag-link-definition-get "linkdef-tasks")))
        (should
         (equal "tag-11111111111111111111111111111111"
                (plist-get definition :from-tag-id)))
        (should
         (equal "tag-22222222222222222222222222222222"
                (plist-get definition :to-tag-id)))))))

(provide 'supertag-link-test)
;;; supertag-link-test.el ends here
