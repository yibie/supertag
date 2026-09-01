;;; supertag-api-test.el --- Tests for the plain-data agent API -*- lexical-binding: t; -*-

;; Covers `supertag-api': the six plain-data functions a bridge registers
;; as LLM tools (query / node / schema read; set-field / link / add-field
;; write), the effect catalog, and the JSON rendering of their results.

(require 'ert)
(require 'ht)
(require 'supertag-core-store)
(require 'supertag-core-index)
(require 'supertag-ops-link-definition)
(require 'supertag-ops-relation)
(require 'supertag-api)

(defmacro supertag-api-test--isolated (&rest body)
  "Run BODY with an empty Store, cleared indexes and quiet transactions."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (ht-create))
         (supertag--transaction-active nil)
         (supertag--transaction-log nil)
         (supertag--subscribers (make-hash-table :test #'eq))
         (supertag-after-operation-hook nil)
         (supertag-ops-deferred-event-errors nil))
     (supertag--ensure-store)
     (supertag-index-clear-all)
     ,@body))

(defun supertag-api-test--install ()
  "Install two Tags, two fields, two nodes and one Link Definition."
  (supertag-store-put-entity
   :tags "project"
   '(:id "project" :type :tag :name "Project" :aliases ("project" "proj")
     :extends nil :description "A project"))
  (supertag-store-put-entity
   :tags "task"
   '(:id "task" :type :tag :name "Task" :aliases ("task") :extends nil))
  (supertag-store-put-entity
   :field-definitions "status"
   '(:id "status" :name "Status" :type :options
     :options ("idea" "active" "done") :required nil))
  (supertag-store-put-entity
   :field-definitions "summary"
   '(:id "summary" :name "Summary" :type :string :required nil))
  (supertag-store-put-entity
   :tag-field-associations "project"
   '((:field-id "status" :order 0) (:field-id "summary" :order 1)))
  (supertag-store-put-entity
   :nodes "project-1"
   '(:id "project-1" :type :node :title "Alpha" :tags ("project")
     :file "/tmp/alpha.org" :content "Alpha body text" :hash "hash-v1"))
  (supertag-store-put-entity
   :nodes "task-1"
   '(:id "task-1" :type :node :title "Do it" :tags ("task") :hash "hash-t1"))
  (supertag-link-definition-create
   '(:id "tasks" :name "Tasks" :inverse-name "Project"
     :from-tag-id "project" :to-tag-id "task"
     :from-cardinality :many :to-cardinality :many)))

;;; --- query ---

(ert-deftest supertag-api-query-string-returns-node-summaries ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (let ((result (supertag-api-query "(tag \"project\")")))
      (should (= 1 (plist-get result :count)))
      (should-not (plist-get result :truncated))
      (let ((node (car (plist-get result :nodes))))
        (should (equal "project-1" (plist-get node :id)))
        (should (equal "Alpha" (plist-get node :title)))
        (should (equal '("project") (plist-get node :tags)))
        (should (equal "/tmp/alpha.org" (plist-get node :file)))))))

(ert-deftest supertag-api-query-sexp-and-limit ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (let ((result (supertag-api-query '(or (tag "project") (tag "task")) 1)))
      (should (= 2 (plist-get result :count)))
      (should (plist-get result :truncated))
      (should (= 1 (length (plist-get result :nodes)))))
    (should-error (supertag-api-query '(tag "project") -1))))

(ert-deftest supertag-api-query-aggregate-returns-value ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (let ((result (supertag-api-query "(and (tag \"project\") (count))")))
      (should (equal 1 (plist-get result :value))))))

(ert-deftest supertag-api-query-rejects-bad-input ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (should-error (supertag-api-query ""))
    (should-error (supertag-api-query "(tag \"project\""))
    (should-error (supertag-api-query 42))))

;;; --- node ---

(ert-deftest supertag-api-node-composes-fields-links-and-references ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (supertag-field-set "project-1" "project" "Status" "active"
                        '(:origin :agent :model "m" :source-hash "hash-v0"))
    (supertag-link-create "tasks" "project-1" "task-1")
    (supertag-relation-create '(:type :reference :from "task-1" :to "project-1"))
    (let ((node (supertag-api-node "project-1")))
      (should (equal "Alpha" (plist-get node :title)))
      (should (equal "Alpha body text" (plist-get node :content)))
      (should (equal "hash-v1" (plist-get node :hash)))
      (should (equal '((:id "project" :name "Project")) (plist-get node :tags)))
      (let* ((fields (plist-get node :fields))
             (status (cl-find "status" fields
                              :key (lambda (f) (plist-get f :id)) :test #'equal))
             (summary (cl-find "summary" fields
                               :key (lambda (f) (plist-get f :id)) :test #'equal)))
        (should (= 2 (length fields)))
        (should (equal "active" (plist-get status :value)))
        (should (eq :options (plist-get status :type)))
        (should (equal '("idea" "active" "done") (plist-get status :options)))
        (should (eq :agent (plist-get (plist-get status :provenance) :origin)))
        ;; hash-v0 != hash-v1: the agent value predates the current text.
        (should (eq t (plist-get status :stale)))
        (should-not (plist-get summary :value))
        (should-not (plist-get summary :provenance))
        (should-not (plist-get summary :stale)))
      (let ((link (car (plist-get node :links))))
        (should (equal "tasks" (plist-get link :link)))
        (should (equal "Tasks" (plist-get link :name)))
        (should (eq :out (plist-get link :direction)))
        (should (equal "task-1" (plist-get link :node)))
        (should (equal "Do it" (plist-get link :title))))
      (should-not (plist-get node :references))
      (should (equal '((:id "task-1" :title "Do it"))
                     (plist-get node :referenced-by))))
    ;; The inverse side sees the same link as incoming.
    (let ((link (car (plist-get (supertag-api-node "task-1") :links))))
      (should (eq :in (plist-get link :direction)))
      (should (equal "Project" (plist-get link :name)))
      (should (equal "project-1" (plist-get link :node))))))

(ert-deftest supertag-api-node-rejects-unknown-node ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (should-error (supertag-api-node "nope"))
    (should-error (supertag-api-node ""))
    (should-error (supertag-api-node nil))))

;;; --- schema ---

(ert-deftest supertag-api-schema-resolves-id-name-and-alias ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (dolist (reference '("project" "Project" "proj"))
      (let ((schema (supertag-api-schema reference)))
        (should (equal "project" (plist-get schema :id)))
        (should (equal "Project" (plist-get schema :name)))
        (should (= 1 (plist-get schema :node-count)))
        (should (equal '("status" "summary")
                       (mapcar (lambda (f) (plist-get f :id))
                               (plist-get schema :fields))))
        (let ((link (car (plist-get schema :links))))
          (should (equal "tasks" (plist-get link :id)))
          (should (equal "project" (plist-get link :from)))
          (should (equal "task" (plist-get link :to)))
          (should (eq :many (plist-get link :to-cardinality))))))
    (should-error (supertag-api-schema "nope"))))

;;; --- set-field ---

(ert-deftest supertag-api-set-field-records-agent-provenance ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (let ((result (supertag-api-set-field "project-1" "Status" "active"
                                          :model "test-model" :note "seen in text")))
      (should (equal "project" (plist-get result :tag)))
      (should (equal "status" (plist-get result :field)))
      (should (equal "active" (plist-get result :value)))
      (should-not (plist-get result :previous))
      (should (eq t (plist-get result :changed)))
      (let ((provenance (plist-get result :provenance)))
        (should (eq :agent (plist-get provenance :origin)))
        (should (equal "test-model" (plist-get provenance :model)))
        (should (equal "seen in text" (plist-get provenance :note)))
        ;; Bound to the node's current hash by default.
        (should (equal "hash-v1" (plist-get provenance :source-hash)))))
    (should (equal "active" (supertag-field-get "project-1" "project" "Status")))
    ;; Same value again: unchanged, previous reported.
    (let ((again (supertag-api-set-field "project-1" "Status" "active")))
      (should (equal "active" (plist-get again :previous)))
      (should-not (plist-get again :changed)))))

(ert-deftest supertag-api-set-field-accepts-human-origin-and-explicit-tag ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (let ((result (supertag-api-set-field "project-1" "summary" "By hand"
                                          :tag "Project" :origin "human")))
      (should (equal "Summary" (plist-get result :name)))
      (should (eq :human (plist-get (plist-get result :provenance) :origin)))
      ;; A human value is not bound to a source hash.
      (should-not (plist-get (plist-get result :provenance) :source-hash)))))

(ert-deftest supertag-api-set-field-validates-and-writes-nothing-on-error ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (should-error (supertag-api-set-field "project-1" "Status" "bogus"))
    (should-error (supertag-api-set-field "project-1" "Nope" "x"))
    (should-error (supertag-api-set-field "task-1" "Status" "active"))
    (should-error (supertag-api-set-field "project-1" "Status" "active"
                                          :origin "robot"))
    (should-error (supertag-api-set-field "missing" "Status" "active"))
    (should-not (supertag-field-get "project-1" "project" "Status"))
    (should-not (supertag-field-provenance "project-1" "project" "Status"))))

;;; --- link ---

(ert-deftest supertag-api-link-creates-idempotently ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (let ((result (supertag-api-link "project-1" "Tasks" "task-1")))
      (should (equal "tasks" (plist-get result :link)))
      (should (equal "project-1" (plist-get result :from)))
      (should (equal "task-1" (plist-get result :to)))
      (should (eq t (plist-get result :created)))
      (should (stringp (plist-get result :id))))
    (let ((again (supertag-api-link "project-1" "tasks" "task-1")))
      (should-not (plist-get again :created)))
    (should (= 1 (length (supertag-link-find "tasks" "project-1" "task-1"))))
    ;; Reverse direction from the task's point of view is the same link.
    (let ((reverse (supertag-api-link "task-1" "tasks" "project-1"
                                      :direction "reverse")))
      (should-not (plist-get reverse :created))
      (should (equal "project-1" (plist-get reverse :from))))))

(ert-deftest supertag-api-link-validates-endpoints-and-cardinality ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    ;; Wrong endpoint types.
    (should-error (supertag-api-link "task-1" "tasks" "project-1"))
    (should-error (supertag-api-link "project-1" "nope" "task-1"))
    (should-error (supertag-api-link "project-1" "tasks" "missing"))
    (should-error (supertag-api-link "project-1" "tasks" "task-1"
                                     :direction "sideways"))
    (should (= 0 (hash-table-count (supertag-store-get-collection :relations))))
    ;; Cardinality: a task belongs to one project (:to-cardinality :one
    ;; bounds the links each target may receive).
    (supertag-store-put-entity
     :nodes "project-2"
     '(:id "project-2" :type :node :title "Beta" :tags ("project")))
    (supertag-link-definition-create
     '(:id "owner" :name "Owner" :from-tag-id "project" :to-tag-id "task"
       :from-cardinality :many :to-cardinality :one))
    (supertag-api-link "project-1" "owner" "task-1")
    (should-error (supertag-api-link "project-2" "owner" "task-1"))
    (let ((replaced (supertag-api-link "project-2" "owner" "task-1" :replace t)))
      (should (eq t (plist-get replaced :created))))
    (should (equal '("project-2") (supertag-link-sources "owner" "task-1")))))

;;; --- add-field ---

(ert-deftest supertag-api-add-field-creates-global-field-and-association ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (let ((result (supertag-api-add-field "task" "Priority" "options"
                                          :options ["High" "Low"]
                                          :description "How urgent")))
      (should (equal "task" (plist-get result :tag)))
      (should (eq t (plist-get result :created)))
      (should (equal "priority" (plist-get result :id)))
      (should (eq :options (plist-get result :type)))
      (should (equal '("High" "Low") (plist-get result :options)))
      (should (equal "How urgent" (plist-get result :description))))
    (should (supertag-tag-get-field "task" "Priority"))
    (should (equal "High"
                   (plist-get (supertag-api-set-field "task-1" "Priority" "High")
                              :value)))))

(ert-deftest supertag-api-add-field-reuses-existing-global-field ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    ;; "status" already exists globally (on project); task gets it too,
    ;; without its options being rewritten.
    (let ((result (supertag-api-add-field "task" "Status" :options
                                          :options '("open" "closed"))))
      (should-not (plist-get result :created))
      (should (equal '("idea" "active" "done") (plist-get result :options))))
    (should (supertag-tag-get-field "task" "Status"))
    ;; Conflicts are refused.
    (should-error (supertag-api-add-field "task" "Status" :options
                                          :options '("x")))
    (should-error (supertag-api-add-field "task" "Summary" :number))
    (should-error (supertag-api-add-field "task" "Effort" "weird"))
    (should-error (supertag-api-add-field "task" "Mood" :options))
    (should-error (supertag-api-add-field "nope" "Mood" :string))))

;;; --- catalog and JSON ---

(ert-deftest supertag-api-catalog-declares-six-functions-with-effects ()
  (let ((catalog (supertag-api-catalog)))
    (should (equal '("query" "node" "schema" "set_field" "link" "add_field")
                   (mapcar (lambda (entry) (plist-get entry :name)) catalog)))
    (should (equal '(:read :read :read :write :write :write)
                   (mapcar (lambda (entry) (plist-get entry :effect)) catalog)))
    (dolist (entry catalog)
      (should (fboundp (plist-get entry :function)))
      (should (stringp (plist-get entry :description)))
      (dolist (parameter (plist-get entry :parameters))
        (should (stringp (plist-get parameter :name)))
        (should (keywordp (plist-get parameter :type)))
        (should (stringp (plist-get parameter :description)))))))

(ert-deftest supertag-api-json-renders-plain-data ()
  (let* ((json (supertag-api-json
                (list :id "n1" :type :options :changed nil :stale nil
                      :fields nil :tags '("a" "b") :value nil
                      :nodes (list (list :id "x" :created t))
                      :count 2 :ratio 0.5)))
         (parsed (json-parse-string json :object-type 'alist
                                    :array-type 'list)))
    (should (equal "n1" (alist-get 'id parsed)))
    (should (equal "options" (alist-get 'type parsed)))
    (should (eq :false (alist-get 'changed parsed)))
    (should (eq :false (alist-get 'stale parsed)))
    (should (equal nil (alist-get 'fields parsed)))
    (should (string-match-p "\"fields\":\\[\\]" json))
    (should (equal '("a" "b") (alist-get 'tags parsed)))
    (should (eq :null (alist-get 'value parsed)))
    (should (eq t (alist-get 'created (car (alist-get 'nodes parsed)))))
    (should (= 2 (alist-get 'count parsed)))
    (should (= 0.5 (alist-get 'ratio parsed)))))

(ert-deftest supertag-api-json-round-trips-a-node ()
  (supertag-api-test--isolated
    (supertag-api-test--install)
    (supertag-api-set-field "project-1" "Status" "active")
    (let* ((json (supertag-api-json (supertag-api-node "project-1")))
           (parsed (json-parse-string json :object-type 'alist
                                      :array-type 'list))
           (status (car (alist-get 'fields parsed))))
      (should (equal "project-1" (alist-get 'id parsed)))
      (should (equal "active" (alist-get 'value status)))
      (should (equal "agent" (alist-get 'origin (alist-get 'provenance status))))
      (should (eq :false (alist-get 'stale status)))
      (should (equal nil (alist-get 'links parsed)))
      (should (string-match-p "\"links\":\\[\\]" json)))))

(provide 'supertag-api-test)
;;; supertag-api-test.el ends here
