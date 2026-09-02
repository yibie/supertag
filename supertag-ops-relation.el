;;; supertag/ops/relation.el --- Relation operations for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file provides standardized operations for Relation entities in the
;; Supertag data-centric architecture. All operations leverage
;; the core transform mechanism and adhere to the defined schema.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-id)
(require 'supertag-core-store)
(require 'supertag-core-schema)
(require 'supertag-core-transform)
(require 'supertag-core-index)
(require 'supertag-ops-link-definition)
(require 'sha1)

(declare-function supertag-node-get "supertag-ops-node" (id))
(declare-function supertag-node-format-link "supertag-ops-node" (id &optional title))
(declare-function supertag-node-link-pattern "supertag-ops-node" (id))
(declare-function supertag-tag-update "supertag-ops-tag" (id updater))

(defvar supertag-change--suppress-legacy-store-changed)

;;; --- Reference Field Ownership ---

(defvar supertag-relation--last-error nil
  "Last error produced by `supertag-relation-add-reference`.
Value is a plist:
  :reason  symbol keyword for programmatic branching
  :message human-readable error message
  :detail  optional low-level detail.")

(defcustom supertag-reference-backlink-include-timestamp nil
  "Legacy option retained for compatibility.
Reciprocal links are no longer written."
  :type 'boolean
  :group 'supertag)

(defun supertag-relation-last-error ()
  "Return the last error payload from `supertag-relation-add-reference`."
  supertag-relation--last-error)

(defun supertag-relation--set-last-error (reason message &optional detail)
  "Store structured relation error with REASON, MESSAGE and DETAIL."
  (setq supertag-relation--last-error
        (list :reason reason :message message :detail detail))
  nil)

(defun supertag-reference--normalize-id-list (value)
  "Normalize VALUE into a list of non-empty string ids."
  (let* ((candidates (cond
                      ((null value) '())
                      ((and (listp value) (not (stringp value))) value)
                      ((stringp value) (list value))
                      (t (list (format "%s" value)))))
         (cleaned (cl-remove-if
                   (lambda (item)
                     (or (null item)
                         (and (stringp item) (= (length item) 0))))
                   (mapcar (lambda (item)
                             (cond
                              ((null item) nil)
                              ((stringp item) item)
                              (t (format "%s" item))))
                           candidates))))
    cleaned))

(defun supertag-reference--pack-targets (targets)
  "Pack TARGETS list into stored field form."
  (pcase targets
    ('() nil)
    (`(,single) single)
    (_ targets)))

(defun supertag-reference--collect-targets (from-id field-id)
  "Read authoritative reference targets for FROM-ID/FIELD-ID."
  (supertag-reference--normalize-id-list
   (supertag-store-get-field-value from-id field-id)))

(defun supertag-reference-get-targets (from-id field-id)
  "Return authoritative reference targets for FROM-ID/FIELD-ID."
  (when (and from-id field-id)
    (supertag-reference--collect-targets from-id field-id)))

(defun supertag-reference-set-targets (from-id field-id targets)
  "Set authoritative reference TARGETS and reconcile their projection."
  (let ((desired (supertag-reference--normalize-id-list targets)))
    (supertag-with-transaction
      (supertag-store-put-field-value
       from-id field-id (supertag-reference--pack-targets desired) t)
      (supertag-relation-reconcile-field-reference from-id field-id))
    desired))

;;; --- Internal Helper ---

;; Deterministic IDs are now the default for optimal data consistency
;; This prevents duplicate relations and ensures predictable behavior

(defun supertag--validate-relation-data (data)
  "Strict validation for relation DATA.
Typed ontology links additionally validate their Link Definition, endpoint
types, and cardinality before any Store mutation occurs."
  (unless (plist-get data :type)
    (error "Relation missing required :type field: %S" data))
  (unless (plist-get data :from)
    (error "Relation missing required :from field: %S" data))
  (unless (plist-get data :to)
    (error "Relation missing required :to field: %S" data))
  (unless (stringp (plist-get data :from))
    (error "Relation :from must be a string, got: %S" (plist-get data :from)))
  (unless (stringp (plist-get data :to))
    (error "Relation :to must be a string, got: %S" (plist-get data :to)))
  (let ((type (plist-get data :type))
        (definition-id (plist-get data :link-definition-id)))
    (when (eq type :ontology-link)
      (unless (and (stringp definition-id)
                   (not (string-empty-p definition-id)))
        (error "Ontology Link relation requires a non-empty :link-definition-id: %S"
               data)))
    (when definition-id
      (unless (stringp definition-id)
        (error "Relation :link-definition-id must be a string: %S" data))
      (unless (eq type :ontology-link)
        (error "Typed Link relations must use :ontology-link type: %S" data))
      (unless (eq (supertag-relation-kind data) :semantic-edge)
        (error "Typed Link relations must be semantic edges: %S" data))
      (supertag-link-definition-validate-instance
       definition-id
       (plist-get data :from)
       (plist-get data :to)
       (plist-get data :id))))
  data)

(defun supertag-ops-relation--ensure-plist (data)
  "Return a plist copy of DATA, converting hash tables when necessary."
  (cond
   ((null data) nil)
   ((hash-table-p data)
    (let (plist)
      (maphash (lambda (k v)
                 (setq plist (plist-put plist k v)))
               data)
      plist))
   ((listp data)
    (copy-tree data))
   (t
    (error "Unsupported relation entity format: %S" data))))

(defun supertag-ops-relation--normalize-keyword (name)
  "Normalize NAME into a keyword symbol."
  (cond
   ((keywordp name) name)
   ((symbolp name) (intern (concat ":" (symbol-name name))))
   ((stringp name) (intern (concat ":" name)))
   (t (error "Unsupported property key: %S" name))))

(defun supertag-relation-kind (relation)
  "Return RELATION's explicit or safely inferred ownership kind."
  (or (plist-get relation :kind)
      (pcase (plist-get relation :origin)
        (:org (pcase (plist-get relation :type)
                (:node-tag :tag-membership)
                (:reference :document-link)
                (_ :legacy-relation)))
        (:field-value (if (eq (plist-get relation :type) :reference)
                          :field-reference
                        :legacy-relation))
        (:semantic :semantic-edge))
      (pcase (plist-get relation :type)
        (:node-tag :tag-membership)
        (:reference :legacy-reference)
        (_ :semantic-edge))))

(defun supertag-relation-kind-p (relation kind)
  "Return non-nil when RELATION has ownership KIND."
  (eq (supertag-relation-kind relation) kind))

(defun supertag-relation-field-reference-p (relation &optional field-id)
  "Return non-nil when RELATION projects FIELD-ID's authoritative value."
  (and (supertag-relation-kind-p relation :field-reference)
       (or (null field-id)
           (equal field-id (plist-get relation :field-id)))))

(defun supertag-relation--validate-owner (data)
  "Validate DATA's explicit owner, allowing unclassified legacy references."
  (when-let* ((kind (plist-get data :kind)))
    (let ((type (plist-get data :type))
          (origin (plist-get data :origin))
          (expected-origin
           (pcase kind
             (:document-link :org)
             (:field-reference :field-value)
             (:tag-membership :org)
             (:semantic-edge :semantic)
             (_ (error "Unknown relation kind: %S" kind)))))
      (unless (eq origin expected-origin)
        (error "%S relations must use %S origin: %S"
               kind expected-origin data))
      (when (and (eq kind :field-reference)
                 (not (stringp (plist-get data :field-id))))
        (error "Field Reference missing string :field-id: %S" data))
      (when (and (memq kind '(:document-link :field-reference))
                 (not (eq type :reference)))
        (error "%S relations must use :reference type: %S" kind data))
      (when (and (eq kind :tag-membership)
                 (not (eq type :node-tag)))
        (error "Tag Membership must use :node-tag type: %S" data))))
  data)

(defun supertag-relation--normalize-owner (data)
  "Return DATA with an explicit relation owner."
  (let* ((type (plist-get data :type))
         (kind (or (plist-get data :kind)
                   (if (eq type :node-tag)
                       :tag-membership
                     :semantic-edge)))
         (expected-origin
          (pcase kind
            (:document-link :org)
            (:field-reference :field-value)
            (:tag-membership :org)
            (:semantic-edge :semantic)
            (_ (error "Unknown relation kind: %S" kind))))
         (origin (or (plist-get data :origin) expected-origin)))
    (supertag-relation--validate-owner
     (plist-put (plist-put data :kind kind) :origin origin))))

(defun supertag-generate-relation-id
    (from-id to-id type &optional kind field-id link-definition-id)
  "Generate a deterministic relation ID for one owned relation fact.
LINK-DEFINITION-ID distinguishes different typed links between the same two
nodes without overloading the instance's physical :type slot."
  (let ((identity (format "%s|%s|%s" from-id to-id type)))
    (when (eq type :reference)
      (setq identity (format "%s|%s|%s" identity kind (or field-id ""))))
    (when link-definition-id
      (setq identity (format "%s|link-definition|%s"
                             identity link-definition-id)))
    (format "rel-%s" (secure-hash 'sha1 identity))))


;;; --- Relation Operations ---

;; 5.1 Basic Operations

(defun supertag-relation-create (relation-data)
  "Create a new relation using the unified commit system.
RELATION-DATA is a plist of relation properties.
Returns the created relation data."
  (let* ((data (supertag-relation--normalize-owner
                (supertag-ops-relation--ensure-plist relation-data)))
         (type (plist-get data :type))
         (from (plist-get data :from))
         (to   (plist-get data :to))
         (kind (plist-get data :kind))
         (field-id (plist-get data :field-id))
         (link-definition-id (plist-get data :link-definition-id))
         (rel-id (supertag-generate-relation-id
                  from to type kind field-id link-definition-id))
         (relation-plist (plist-put data :id rel-id)))

    ;; Ensure created-at exists but don't overwrite if caller provided it.
    (unless (plist-get relation-plist :created-at)
      (setq relation-plist (plist-put relation-plist :created-at (current-time))))

    ;; Strict validation
    (supertag--validate-relation-data relation-plist)

    ;; Check if relation already exists
    (let* ((existing-relations (supertag-relation-find-between from to type kind))
           ;; Be defensive against malformed/nil entries in relation buckets.
           (existing-relation
            (cl-find-if
             (lambda (relation)
               (and
                (or (not (eq kind :field-reference))
                    (equal field-id (plist-get relation :field-id)))
                (or (null link-definition-id)
                    (equal link-definition-id
                           (plist-get relation :link-definition-id)))))
             existing-relations)))
      (if existing-relation
          ;; Return the first valid existing relation.
          existing-relation
        ;; Create new relation if none exists
        ;; Use unified commit system
        (supertag-ops-commit
         :operation :create
         :collection :relations
         :id rel-id
         :new relation-plist
         :perform (lambda ()
                    (supertag-store-put-entity :relations rel-id relation-plist)
                    (supertag-index--on-relation-changed
                     rel-id nil nil from to)
                    relation-plist))))))

(defun supertag-relation-get (id)
  "Get relation data.
ID is the unique identifier of the relation.
Returns relation data, or nil if it does not exist."
  (supertag-store-get-entity :relations id))

(defun supertag-relation-update (id updater)
  "Update relation data using the unified commit system.
ID is the unique identifier of the relation.
UPDATER is a function that receives the current relation data and returns the updated data.
Returns the updated relation data."
  (let ((previous (supertag-relation-get id)))
    (when previous
      (supertag-ops-commit
       :operation :update
       :collection :relations
       :id id
       :previous previous
       :perform (lambda ()
                  (let ((updated-relation
                         (funcall updater (copy-tree previous))))
                    (when updated-relation
                      (let* ((updated-relation (plist-put updated-relation :id id))
                             (final-relation
                              (supertag-relation--validate-owner
                               (plist-put updated-relation :modified-at
                                          (current-time)))))
                        (dolist (identity-key
                                 '(:from :to :type :kind :field-id
                                   :link-definition-id))
                          (unless (equal (plist-get previous identity-key)
                                         (plist-get final-relation identity-key))
                            (error
                             "Relation identity field %S cannot be changed in place; delete and recreate the relation"
                             identity-key)))
                        (supertag--validate-relation-data final-relation)
                        (supertag-store-put-entity :relations id final-relation)
                        final-relation))))))))

(defun supertag-relation-delete (id)
  "Delete a relation by its ID.
ID is the unique identifier of the relation.
Returns the deleted relation data."
  (let ((previous (supertag-relation-get id)))
    (when previous
      (supertag-ops-commit
       :operation :delete
       :collection :relations
       :id id
       :previous previous
       :perform (lambda ()
                  ;; `supertag-ops-commit' owns the one public path event for
                  ;; this logical delete.  Suppress the Store helper's earlier
                  ;; notification while retaining its transaction bookkeeping.
                  (let ((supertag-change--suppress-legacy-store-changed t))
                    (supertag-store-remove-entity :relations id))
                  (let ((from-id (plist-get previous :from))
                        (to-id (plist-get previous :to)))
                    (supertag-index--on-relation-changed
                     id from-id to-id nil nil))
                  nil)))))

;;; --- Typed Link Instance API ---

(defun supertag-link-create (definition-id from-id to-id &optional properties)
  "Create one typed Link instance from FROM-ID to TO-ID."
  (let ((data (copy-tree properties)))
    (setq data (plist-put data :type :ontology-link))
    (setq data (plist-put data :kind :semantic-edge))
    (setq data (plist-put data :origin :semantic))
    (setq data (plist-put data :link-definition-id definition-id))
    (setq data (plist-put data :from from-id))
    (setq data (plist-put data :to to-id))
    (supertag-relation-create data)))

(defun supertag-link--matches-definition-p (relation definition-id)
  (and (eq (plist-get relation :type) :ontology-link)
       (equal definition-id (plist-get relation :link-definition-id))))

(defun supertag-link-find (definition-id &optional from-id to-id)
  "Return typed Link instances for DEFINITION-ID.
Optional FROM-ID and TO-ID narrow either endpoint and use relation indexes."
  (let ((candidates
         (cond
          ((and from-id to-id)
           (supertag-relation-find-between from-id to-id :ontology-link
                                           :semantic-edge))
          (from-id
           (supertag-relation-find-by-from from-id :ontology-link
                                           :semantic-edge))
          (to-id
           (supertag-relation-find-by-to to-id :ontology-link
                                         :semantic-edge))
          (t
           (let (all)
             (maphash (lambda (_id relation) (push relation all))
                      (supertag-store-get-collection :relations))
             all)))))
    (cl-remove-if-not
     (lambda (relation)
       (and (supertag-link--matches-definition-p relation definition-id)
            (or (null from-id) (equal from-id (plist-get relation :from)))
            (or (null to-id) (equal to-id (plist-get relation :to)))))
     candidates)))

(defun supertag-link-targets (definition-id from-id)
  "Return target node IDs linked from FROM-ID through DEFINITION-ID."
  (mapcar (lambda (relation) (plist-get relation :to))
          (supertag-link-find definition-id from-id nil)))

(defun supertag-link-sources (definition-id to-id)
  "Return source node IDs linked to TO-ID through DEFINITION-ID."
  (mapcar (lambda (relation) (plist-get relation :from))
          (supertag-link-find definition-id nil to-id)))

(defun supertag-link-delete (definition-id from-id to-id)
  "Delete the typed Link instance identified by schema and endpoints."
  (let ((relation (car (supertag-link-find definition-id from-id to-id))))
    (when relation
      (supertag-relation-delete (plist-get relation :id)))))

(defun supertag-link-conflicts (definition-id from-id to-id)
  "Return existing instances that conflict with FROM-ID -> TO-ID cardinality."
  (let ((definition (supertag-link-definition-get definition-id)) conflicts)
    (unless definition (error "Unknown Link Definition %s" definition-id))
    (when (eq (plist-get definition :from-cardinality) :one)
      (dolist (relation (supertag-link-find definition-id from-id nil))
        (unless (equal to-id (plist-get relation :to))
          (push relation conflicts))))
    (when (eq (plist-get definition :to-cardinality) :one)
      (dolist (relation (supertag-link-find definition-id nil to-id))
        (unless (equal from-id (plist-get relation :from))
          (push relation conflicts))))
    (cl-delete-duplicates conflicts
                          :key (lambda (relation) (plist-get relation :id))
                          :test #'equal)))

(defun supertag-link-create-replacing-conflicts
    (definition-id from-id to-id &optional properties)
  "Create FROM-ID -> TO-ID, atomically replacing cardinality conflicts."
  (or (car (supertag-link-find definition-id from-id to-id))
      (supertag-with-transaction
        (dolist (relation (supertag-link-conflicts definition-id from-id to-id))
          (supertag-relation-delete (plist-get relation :id)))
        (supertag-link-create definition-id from-id to-id properties))))

(defun supertag-link-instances-for-node (node-id)
  "Return all typed Link instances touching NODE-ID."
  (cl-delete-duplicates
   (append
    (cl-remove-if-not
     (lambda (relation) (eq (plist-get relation :type) :ontology-link))
     (supertag-relation-find-by-from node-id :ontology-link :semantic-edge))
    (cl-remove-if-not
     (lambda (relation) (eq (plist-get relation :type) :ontology-link))
     (supertag-relation-find-by-to node-id :ontology-link :semantic-edge)))
   :key (lambda (relation) (plist-get relation :id)) :test #'equal))

;; 5.2 Reference Service

(defun supertag-relation-document-link-p (relation)
  "Return non-nil when RELATION is an Org-owned Document Link projection."
  (and (supertag-relation-kind-p relation :document-link)
       (eq (plist-get relation :origin) :org)))

(defun supertag-relation-project-document-link (from-id to-id)
  "Project the Org link FROM-ID -> TO-ID without modifying either Org file.
Partially classified Document Links are completed in place."
  (let ((existing
         (cl-find-if #'identity
                     (supertag-relation-find-between
                      from-id to-id :reference :document-link))))
    (cond
     ((null existing)
      (supertag-relation-create
       (list :type :reference :from from-id :to to-id
             :kind :document-link :origin :org)))
     ((supertag-relation-document-link-p existing)
      existing)
     ((and (memq (plist-get existing :kind) '(nil :document-link))
           (memq (plist-get existing :origin) '(nil :org)))
      (supertag-relation-update
       (plist-get existing :id)
       (lambda (relation)
         (plist-put
          (plist-put (copy-sequence relation) :kind :document-link)
          :origin :org))))
     (t
      (error "Document Link conflicts with owned relation %s"
             (plist-get existing :id))))))

(defun supertag-relation-project-field-reference (from-id to-id field-id)
  "Project authoritative FROM-ID/FIELD-ID value pointing to TO-ID."
  (supertag-relation-create
   (list :type :reference :from from-id :to to-id
         :kind :field-reference :origin :field-value :field-id field-id)))

(defun supertag-relation-reconcile-field-reference (from-id field-id)
  "Make FROM-ID/FIELD-ID's Field Reference projection match its value."
  (let* ((desired (supertag-reference--collect-targets from-id field-id))
         (current
          (cl-remove-if-not
           (lambda (relation)
             (supertag-relation-field-reference-p relation field-id))
           (supertag-relation-find-by-from
            from-id :reference :field-reference))))
    (dolist (relation current)
      (unless (member (plist-get relation :to) desired)
        (supertag-relation-delete (plist-get relation :id))))
    (dolist (target desired)
      (unless (cl-find target current
                       :key (lambda (relation) (plist-get relation :to))
                       :test #'string=)
        (supertag-relation-project-field-reference from-id target field-id)))
    desired))

(defun supertag-relation-reconcile-field-references ()
  "Rebuild every Field Reference projection from global field values."
  (let (stale)
    (maphash
     (lambda (_id relation)
       (when (supertag-relation-field-reference-p relation)
         (let ((field-id (plist-get relation :field-id)))
           (unless (and (eq :node-reference
                            (plist-get
                             (supertag-store-get-field-definition field-id)
                             :type))
                        (member
                         (plist-get relation :to)
                         (supertag-reference--collect-targets
                          (plist-get relation :from) field-id)))
             (push (plist-get relation :id) stale)))))
     (supertag-store-get-collection :relations))
    (dolist (id stale)
      (supertag-relation-delete id))
    (maphash
     (lambda (node-id values)
       (when (hash-table-p values)
         (maphash
          (lambda (field-id _value)
            (when (eq :node-reference
                      (plist-get (supertag-store-get-field-definition field-id)
                                 :type))
              (supertag-relation-reconcile-field-reference node-id field-id)))
          values)))
     (supertag-store-get-collection :field-values))))

(defun supertag-relation-add-reference (from-id to-id)
  "Create a database-owned Semantic Edge from FROM-ID to TO-ID.
Returns t on success and nil on failure.  Document Links and Field References
use their projection functions instead."
  (setq supertag-relation--last-error nil)
  (cond
   ((or (not (stringp from-id)) (string-empty-p from-id))
    (supertag-relation--set-last-error :invalid-from
                                       "Failed to add reference: source node ID is missing or invalid."))
   ((or (not (stringp to-id)) (string-empty-p to-id))
    (supertag-relation--set-last-error :invalid-to
                                       "Failed to add reference: target node ID is missing or invalid."))
   ((null (supertag-node-get from-id))
    (supertag-relation--set-last-error :from-node-missing
                                       (format "Failed to add reference: source node %s does not exist in store." from-id)))
   ((null (supertag-node-get to-id))
    (supertag-relation--set-last-error :to-node-missing
                                       (format "Failed to add reference: target node %s does not exist in store." to-id)))
   (t
    (condition-case rel-err
        (if (supertag-relation-create
             (list :type :reference :from from-id :to to-id
                   :kind :semantic-edge :origin :semantic))
            t
          (supertag-relation--set-last-error
           :db-create-failed
           "Failed to add reference: relation creation returned nil."))
      (error
       (supertag-relation--set-last-error
        :exception
        (format "Failed to add reference: %s" (error-message-string rel-err))
        (error-message-string rel-err)))))))
;; 5.3 Relation Query Operations

(defun supertag-relation-find-by-from (from-id &optional type kind)
  "Find all relations originating from a specific entity.
FROM-ID is the unique identifier of the source entity.
TYPE and KIND are optional relation filters.
Returns a list of relations.
Uses the in-memory from-index for O(k) lookup instead of O(N) scan."
  (let ((relations (supertag-index-find-by-from from-id type)))
    (if kind
        (cl-remove-if-not
         (lambda (relation) (supertag-relation-kind-p relation kind))
         relations)
      relations)))

(defun supertag-relation-find-by-to (to-id &optional type kind)
  "Find all relations targeting a specific entity.
TO-ID is the unique identifier of the target entity.
TYPE and KIND are optional relation filters.
Returns a list of relations.
Uses the in-memory to-index for O(k) lookup instead of O(N) scan."
  (let ((relations (supertag-index-find-by-to to-id type)))
    (if kind
        (cl-remove-if-not
         (lambda (relation) (supertag-relation-kind-p relation kind))
         relations)
      relations)))

(defun supertag-relation-find-between (from-id to-id &optional type kind)
  "Find all relations connecting two specific entities.
FROM-ID is the unique identifier of the source entity.
TO-ID is the unique identifier of the target entity.
TYPE and KIND are optional relation filters.
Returns a list of relations.
Uses the in-memory from-index for O(k) lookup instead of O(N) scan."
  (let ((relations (supertag-index-find-between from-id to-id type)))
    (if kind
        (cl-remove-if-not
         (lambda (relation) (supertag-relation-kind-p relation kind))
         relations)
      relations)))

;; 5.3 Relation Cleanup Operations

(defun supertag-relation-cleanup-duplicates ()
  "Clean up duplicate relations in the database.
Keeps the first relation for each owned relation identity."
  (interactive)
  (let ((relations (supertag-store-get-collection :relations))
        (relation-groups (make-hash-table :test 'equal))
        (duplicates-found 0)
        (removed-count 0))

    ;; Projection kinds, Field IDs, and Link Definition IDs are distinct facts
    ;; even with the same endpoints and physical relation type.
    (when (hash-table-p relations)
      (maphash (lambda (id relation-data)
                 (let* ((from (plist-get relation-data :from))
                        (to (plist-get relation-data :to))
                        (type (plist-get relation-data :type))
                        (kind (supertag-relation-kind relation-data))
                        (field-id (plist-get relation-data :field-id))
                        (link-definition-id
                         (plist-get relation-data :link-definition-id))
                        (key (format "%s|%s|%s|%s|%s|%s"
                                     from to type kind (or field-id "")
                                     (or link-definition-id ""))))
                   (when (and from to type)
                     (let ((existing-group (gethash key relation-groups)))
                       (if existing-group
                           (progn
                             (push (cons id relation-data) existing-group)
                             (puthash key existing-group relation-groups)
                             (cl-incf duplicates-found))
                         (puthash key (list (cons id relation-data)) relation-groups))))))
               relations))

    ;; Process duplicate groups
    (maphash (lambda (key relation-list)
               (when (> (length relation-list) 1)
                 (message "Found %d duplicate relations for key '%s'" (length relation-list) key)
                 ;; Keep the first relation, delete the rest
                 (let ((keep-relation (car relation-list))
                       (delete-relations (cdr relation-list)))
                   (message "Keeping relation ID: %s" (car keep-relation))
                   (dolist (dup-relation delete-relations)
                     (message "Deleting duplicate relation ID: %s" (car dup-relation))
                     (supertag-relation-delete (car dup-relation))
                     (cl-incf removed-count)))))
             relation-groups)

    (message "Duplicate relation cleanup complete. Found %d duplicates, removed %d relations."
             duplicates-found removed-count)
    removed-count))

(defun supertag-relation-delete-for-node (node-id)
  "Delete all relations associated with a specific node.
NODE-ID is the unique identifier of the node.
Returns the number of deleted relations."
  (supertag-index--ensure-relations)
  (let ((count 0)
        ;; Collect relation ids first to avoid modifying indexes while iterating.
        (ids-to-delete '()))
    (let ((from-set (gethash node-id supertag--index-relations-by-from)))
      (when from-set
        (maphash (lambda (rel-id _v) (push rel-id ids-to-delete)) from-set)))
    (let ((to-set (gethash node-id supertag--index-relations-by-to)))
      (when to-set
        (maphash (lambda (rel-id _v)
                   (unless (member rel-id ids-to-delete)
                     (push rel-id ids-to-delete)))
                 to-set)))
    (dolist (id ids-to-delete)
      (supertag-relation-delete id)
      (setq count (1+ count)))
    count))

(defun supertag-relation-delete-for-tag (tag-id)
  "Delete all relations associated with a specific tag.
TAG-ID is the unique identifier of the tag.
Returns the number of deleted relations."
  (supertag-index--ensure-relations)
  (let ((count 0)
        (ids-to-delete '()))
    ;; Collect from index-based lookups
    (let ((from-set (gethash tag-id supertag--index-relations-by-from)))
      (when from-set
        (maphash (lambda (rel-id _v) (push rel-id ids-to-delete)) from-set)))
    (let ((to-set (gethash tag-id supertag--index-relations-by-to)))
      (when to-set
        (maphash (lambda (rel-id _v)
                   (unless (member rel-id ids-to-delete)
                     (push rel-id ids-to-delete)))
                 to-set)))
    ;; Also scan for :node-field relations where tag-id is in :props
    ;; (these won't be found by from/to index since tag-id is in props, not from/to)
    (let ((relations (supertag-store-get-collection :relations)))
      (when relations
        (maphash
         (lambda (id relation)
           (when (and relation
                      (eq (plist-get relation :type) :node-field)
                      (equal (plist-get (plist-get relation :props) :tag-id) tag-id)
                      (not (member id ids-to-delete)))
             (push id ids-to-delete)))
         relations)))
    (dolist (id ids-to-delete)
      (supertag-relation-delete id)
      (setq count (1+ count)))
    count))

;;; --- Notion-style Relation Operations ---

(defun supertag-relation-create-notion-style (relation-data)
  "Create a Notion-style relation with enhanced properties.
RELATION-DATA should contain:
- :type - Relation type (:one-to-one, :one-to-many, :many-to-many, etc.)
- :from - Source entity ID
- :to - Target entity ID
- :sync-direction - :unidirectional or :bidirectional
- :sync-fields - List of fields to sync
- :rollup-field - Field name for rollup calculations
- :rollup-function - Function for rollup calculation

Returns the created relation data."
  (supertag-with-transaction
    (let* ((type (plist-get relation-data :type))
           (from (plist-get relation-data :from))
           (to (plist-get relation-data :to))
           (sync-direction (or (plist-get relation-data :sync-direction) :unidirectional))
           (sync-fields (plist-get relation-data :sync-fields))
           (rollup-field (plist-get relation-data :rollup-field))
           (rollup-function (plist-get relation-data :rollup-function)))

      ;; Validate Notion-style relation types
      (unless (memq type '(:one-to-one :one-to-many :many-to-many :rollup :formula :sync-field))
        (error "Invalid Notion-style relation type: %s" type))

      ;; Create enhanced relation data
      (let ((enhanced-relation
             (list :type type
                   :from from
                   :to to
                   :sync-direction sync-direction
                   :sync-fields sync-fields
                   :rollup-field rollup-field
                   :rollup-function rollup-function
                   :props (plist-get relation-data :props))))

        ;; Use existing creation function with enhanced data
        (let ((relation (supertag-relation-create enhanced-relation)))

          ;; If bidirectional sync is enabled, create reverse relation
          (when (eq sync-direction :bidirectional)
            (supertag-relation-create
             (list :type type
                   :from to
                   :to from
                   :sync-direction :unidirectional
                   :sync-fields sync-fields
                   :props (list :reverse-of (plist-get relation :id)))))

          ;; Trigger initial sync if fields are specified
          (when sync-fields
            (supertag-relation-sync-fields (plist-get relation :id)))

          ;; Calculate initial rollup if specified
          (when rollup-field
            (supertag-relation-calculate-rollup (plist-get relation :id)))

          relation)))))

(defun supertag-relation-sync-fields (relation-id)
  "Sync fields between related entities based on relation configuration.
RELATION-ID is the identifier of the relation defining the sync rules."
  (let ((relation (supertag-relation-get relation-id)))
    (when relation
      (let* ((from-id (plist-get relation :from))
             (to-id (plist-get relation :to))
             (sync-fields (plist-get relation :sync-fields))
             (from-entity (or (supertag-store-get-entity :nodes from-id)
                              (supertag-store-get-entity :tags from-id)))
             (from-plist (supertag-ops-relation--ensure-plist from-entity))
             (target-node (supertag-store-get-entity :nodes to-id))
             (target-tag (and (not target-node) (supertag-store-get-entity :tags to-id))))
        (when (and from-plist (or target-node target-tag) sync-fields)
          (dolist (prop-name sync-fields)
            (let* ((prop-key (supertag-ops-relation--normalize-keyword prop-name))
                   (field-id (substring (symbol-name prop-key) 1))
                   (source-fields (and (supertag-store-get-entity :nodes from-id)
                                       (gethash from-id
                                                (supertag-store-get-collection
                                                 :field-values))))
                   (prop-value
                    (if (and source-fields (ht-contains? source-fields field-id))
                        (gethash field-id source-fields)
                      (plist-get from-plist prop-key))))
              (when prop-value
                (if target-node
                    (unless (equal (supertag-store-get-field-value to-id field-id)
                                   prop-value)
                      (supertag-store-put-field-value to-id field-id prop-value))
                  (when (and target-tag (fboundp 'supertag-tag-update))
                    (supertag-tag-update
                     to-id
                     (lambda (tag)
                       (let* ((plist (supertag-ops-relation--ensure-plist tag))
                              (current (plist-get plist prop-key)))
                         (if (equal current prop-value)
                             nil
                           (plist-put plist prop-key prop-value)))))))))))
        (message "Synced properties for relation %s: %s" relation-id sync-fields)))))

(defun supertag-relation-calculate-rollup (relation-id)
  "Calculate rollup value for a relation.
RELATION-ID is the identifier of the rollup relation.
Return the derived value without storing it in a node or tag entity."
  (let ((relation (supertag-relation-get relation-id)))
    (when relation
      ;; Lazy require: `supertag-services-formula' must not be required at
      ;; load time (it would close a require cycle with the query service).
      (require 'supertag-services-formula)
      (let* ((from-id (plist-get relation :from))
             (to-id (plist-get relation :to))
             (rollup-field (plist-get relation :rollup-field))
             (rollup-function (plist-get relation :rollup-function))
             (related-entities
              (supertag-relation-find-by-from from-id nil :semantic-edge)))

        (when (and rollup-field rollup-function)
          ;; Collect values from related entities
          (let ((values '()))
            (dolist (rel related-entities)
              (let* ((entity-id (plist-get rel :to))
                     (entity (or (supertag-store-get-entity :nodes entity-id)
                                 (supertag-store-get-entity :tags entity-id)))
                     (entity-plist (supertag-ops-relation--ensure-plist entity))
                     (value-key (supertag-ops-relation--normalize-keyword rollup-field))
                     (value (when entity-plist
                              (plist-get entity-plist value-key))))
                (when value
                  (push value values))))

            (let ((result (supertag-rollup-apply rollup-function values)))
              (message "Calculated rollup for %s: %s = %s"
                       to-id rollup-field result)
              result)))))))

(defun supertag-relation-define-database-relation (from-tag to-tag relation-config)
  "Define a Notion-style database relation between two tags.
FROM-TAG and TO-TAG are tag IDs representing virtual databases.
RELATION-CONFIG is a plist with:
- :type - Relation type (:one-to-many, :many-to-many, etc.)
- :from-property - Field name in from-tag
- :to-property - Field name in to-tag
- :sync-fields - List of fields to sync
- :rollup-config - Rollup configuration

Returns the created relation."
  (let* ((relation-type (plist-get relation-config :type))
         (from-prop (plist-get relation-config :from-property))
         (to-prop (plist-get relation-config :to-property))
         (sync-props (plist-get relation-config :sync-fields))
         (rollup-config (plist-get relation-config :rollup-config)))

    ;; Create the database relation
    (supertag-relation-create-notion-style
     (list :type relation-type
           :from from-tag
           :to to-tag
           :sync-direction :bidirectional
           :sync-fields sync-props
           :rollup-field (plist-get rollup-config :field)
           :rollup-function (plist-get rollup-config :function)
           :props (list :from-property from-prop
                       :to-property to-prop
                       :database-relation t)))))

(defun supertag-relation-get-database-relations (tag-id)
  "Get all database relations for a tag (virtual database).
TAG-ID is the tag identifier.
Returns list of database relations.
Uses relation indexes for O(k) lookup instead of O(N) scan."
  (let ((result '()))
    (dolist (rel (supertag-index-find-by-from tag-id))
      (when (plist-get (plist-get rel :props) :database-relation)
        (push rel result)))
    (dolist (rel (supertag-index-find-by-to tag-id))
      (when (and (plist-get (plist-get rel :props) :database-relation)
                 ;; Avoid duplicates if tag-id is both from and to
                 (not (equal (plist-get rel :from) tag-id)))
        (push rel result)))
    result))

(defun supertag-relation-update-all-rollups ()
  "Update all rollup calculations in the system.
This function finds all rollup relations and recalculates their values."
  (interactive)
  (let ((relations (supertag-store-get-collection :relations))
        (count 0))
    (when relations
      (maphash
       (lambda (id relation)
         (when (eq (plist-get relation :type) :rollup)
           (supertag-relation-calculate-rollup id)
           (cl-incf count)))
       relations))
    (message "Updated %d rollup calculations" count)
    count))

(defun supertag-relation-sync-all-fields ()
  "Sync all field synchronization relations in the system."
  (interactive)
  (let ((relations (supertag-store-get-collection :relations))
        (count 0))
    (when relations
      (maphash
       (lambda (id relation)
         (when (plist-get relation :sync-fields)
           (supertag-relation-sync-fields id)
           (cl-incf count)))
       relations))
    (message "Synced %d field synchronization relations" count)
    count))

(provide 'supertag-ops-relation)
