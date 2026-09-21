;;; supertag-link.el --- Link feature -*- lexical-binding: t; -*-
;; Commands: supertag-add-link, supertag-delete-link, supertag-text-link-refresh
;; Dependencies: cl-lib, org, org-id, org-element, subr-x, sha1, supertag-core-store, supertag-query, supertag-service-org, supertag-node, supertag-view-framework (ordinary providers are lazy)

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'supertag-core-store)
(require 'org-id)
(require 'sha1)
(require 'supertag-query)
(require 'supertag-node)

;; Ordinary providers stay lazy; their real owner initializes runtime state.
(autoload 'supertag-service-org-create-node "supertag-service-org")
(declare-function supertag-service-org-create-node "supertag-service-org" (target-file title &optional tags content))
(autoload 'supertag-service-org-retry-node-projection "supertag-service-org")
(declare-function supertag-service-org-retry-node-projection "supertag-service-org" (node-id file))
(autoload 'supertag-view-helper-insert-section-chip "supertag-view-framework")
(declare-function supertag-view-helper-insert-section-chip "supertag-view-framework" (label count face))
(declare-function supertag-goto-node "supertag-node" (node-id &optional other-window))

;;; Relation vocabulary, session and Org protocol registration

(defgroup supertag-text-link nil
  "Configured Org link types used as relation names."
  :group 'supertag)

(defcustom supertag-text-link-relation-types nil
  "Exact non-empty Org link types that project as named relations.

After changing this option, run `supertag-text-link-refresh' and reindex the
vault.  This bounded interface does not discover or insert unknown link types."
  :type '(repeat string)
  :group 'supertag-text-link)

(defvar supertag-text-link--owned-registrations
  (make-hash-table :test #'equal)
  "Org link parameter entries currently owned by this service.")

(defvar supertag-text-link--session-types nil
  "Explicit relation types accepted during this Emacs session.")

(defconst supertag-text-link--protected-types
  '("fuzzy" "coderef" "custom-id" "radio"
    "id" "file" "attachment" "http" "https" "ftp" "mailto"
    "news" "shell" "elisp" "help" "info" "docview")
  "Org structural and native link types this service must never register.")

(defun supertag-text-link--validate-types (types)
  "Return a de-duplicated copy of configured TYPES, or signal."
  (let (result)
    (dolist (type types (nreverse result))
      (unless (and (stringp type)
                   (not (string-empty-p type))
                   (string-match-p "\\`[[:alnum:]][-+._[:alnum:]]*\\'" type))
        (user-error "Invalid text relation link type: %S" type))
      (unless (member type result)
        (push type result)))))

(defun supertag-text-link-relation-type-p (type)
  "Return non-nil when TYPE is an exact configured relation link type."
  (and (stringp type)
       (member type (supertag-text-link-relation-types))))

(defun supertag-text-link-validate-type (type)
  "Return validated explicit relation TYPE without registering it."
  (let ((validated (car (supertag-text-link--validate-types (list type)))))
    (unless validated (user-error "Relation name cannot be empty"))
    (when (member validated supertag-text-link--protected-types)
      (user-error "Org link protocol is reserved: %s" validated))
    (let ((existing (assoc validated org-link-parameters)))
      (when (and existing (not (supertag-text-link--owned-current-p validated)))
        (user-error "Org link protocol already registered: %s" validated)))
    validated))

(defun supertag-text-link-relation-types ()
  "Return configured and explicitly accepted session relation types."
  (supertag-text-link--validate-types
   (append supertag-text-link-relation-types
           supertag-text-link--session-types)))

(defun supertag-text-link-candidates ()
  "Return exact available relation names, including projected names."
  (let ((types (supertag-text-link-relation-types)))
    (when (fboundp 'supertag-store-get-collection)
      (maphash
       (lambda (_id relation)
         (when (and (fboundp 'supertag-relation-named-document-link-p)
                    (supertag-relation-named-document-link-p relation))
           (push (plist-get relation :relation-name) types)))
       (supertag-store-get-collection :relations)))
    (sort (delete-dups (copy-sequence types)) #'string<)))

(defun supertag-text-link-follow (target-id _argument)
  "Follow configured relation link TARGET-ID through node navigation."
  (supertag-goto-node target-id))

(defun supertag-text-link--owned-current-p (type)
  "Return non-nil when TYPE's current Org registration is still ours."
  (let ((current (assoc type org-link-parameters))
        (owned (gethash type supertag-text-link--owned-registrations)))
    (and current owned (equal current owned))))

(defun supertag-text-link-refresh ()
  "Refresh configured relation link registrations without taking protocols.

All conflicts are checked before registrations change.  Existing third-party
or Org protocols fail explicitly; registrations owned by this service may be
refreshed idempotently.  Reindex after changing the vocabulary."
  (interactive)
  (let ((types (supertag-text-link-relation-types)))
    ;; Preflight the complete desired set before removing or adding anything.
    (dolist (type types)
      (when (member type supertag-text-link--protected-types)
        (user-error "Org link protocol is reserved: %s" type))
      (let ((existing (assoc type org-link-parameters)))
        (when (and existing (not (supertag-text-link--owned-current-p type)))
          (user-error "Org link protocol already registered: %s" type))))
    (maphash
     (lambda (type _registration)
       (unless (member type types)
         (when (supertag-text-link--owned-current-p type)
           (setq org-link-parameters
                 (assoc-delete-all type org-link-parameters)))
         (remhash type supertag-text-link--owned-registrations)))
     (copy-hash-table supertag-text-link--owned-registrations))
    (dolist (type types)
      (unless (supertag-text-link--owned-current-p type)
        (org-link-set-parameters type :follow #'supertag-text-link-follow)
        (puthash type (copy-tree (assoc type org-link-parameters))
                 supertag-text-link--owned-registrations)))
    (org-link-make-regexps)
    types))

(defun supertag-text-link-accept-session-type (type)
  "Validate and register explicit relation TYPE for this session.
User configuration is not modified.  Failure leaves session state unchanged."
  (let ((validated (supertag-text-link-validate-type type))
        (previous supertag-text-link--session-types))
    (setq supertag-text-link--session-types
          (cons validated (delete validated (copy-sequence previous))))
    (condition-case error-data
        (progn (supertag-text-link-refresh) validated)
      (error
       (setq supertag-text-link--session-types previous)
       (signal (car error-data) (cdr error-data))))))

(defun supertag-text-link-reset-session ()
  "Forget explicit session names and refresh configured registrations."
  (setq supertag-text-link--session-types nil)
  (supertag-text-link-refresh))

(defun supertag-text-link-clear-registrations ()
  "Remove only Org link registrations still owned by this service."
  (maphash
   (lambda (type _registration)
     (when (supertag-text-link--owned-current-p type)
       (setq org-link-parameters
             (assoc-delete-all type org-link-parameters))))
   supertag-text-link--owned-registrations)
  (clrhash supertag-text-link--owned-registrations)
  (org-link-make-regexps))

;;; Relation entities, ownership, indexes and errors

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


;;; --- Internal Helper ---

;; Deterministic IDs are now the default for optimal data consistency
;; This prevents duplicate relations and ensures predictable behavior

(defun supertag--validate-relation-data (data)
  "Validate required relation DATA and string endpoints before Store mutation."
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

        (:semantic :semantic-edge))
      (pcase (plist-get relation :type)
        (:node-tag :tag-membership)
        (:reference :legacy-reference)
        (_ :semantic-edge))))

(defun supertag-relation-kind-p (relation kind)
  "Return non-nil when RELATION has ownership KIND."
  (eq (supertag-relation-kind relation) kind))


(defun supertag-relation--validate-owner (data)
  "Validate DATA's explicit owner, allowing unclassified legacy references."
  (when-let* ((kind (plist-get data :kind)))
    (let ((type (plist-get data :type))
          (origin (plist-get data :origin))
          (expected-origin
           (pcase kind
             (:document-link :org)
             (:tag-membership :org)
             (:semantic-edge :semantic)
             (_ (error "Unknown relation kind: %S" kind)))))
      (unless (eq origin expected-origin)
        (error "%S relations must use %S origin: %S"
               kind expected-origin data))

      (when (and (eq kind :document-link)
                 (not (eq type :reference)))
        (error "%S relations must use :reference type: %S" kind data))
      (when (and (eq kind :tag-membership)
                 (not (eq type :node-tag)))
        (error "Tag Membership must use :node-tag type: %S" data))
      (when-let* ((name (plist-get data :relation-name)))
        (unless (and (eq kind :document-link)
                     (eq type :reference)
                     (eq origin :org)
                     (stringp name)
                     (not (string-empty-p name))
                     (null (plist-get data :link-definition-id)))
          (error "Named relation must be an Org Document Link: %S" data)))))
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
            (:tag-membership :org)
            (:semantic-edge :semantic)
            (_ (error "Unknown relation kind: %S" kind))))
         (origin (or (plist-get data :origin) expected-origin)))
    (supertag-relation--validate-owner
     (plist-put (plist-put data :kind kind) :origin origin))))

(defun supertag-generate-relation-id
    (from-id to-id type &optional kind field-id link-definition-id relation-name)
  "Generate a deterministic relation ID for one owned relation fact.
LINK-DEFINITION-ID distinguishes different typed links between the same two
nodes without overloading the instance's physical :type slot."
  (let ((identity (format "%s|%s|%s" from-id to-id type)))
    (when (eq type :reference)
      (setq identity (format "%s|%s|%s" identity kind (or field-id ""))))
    (when link-definition-id
      (setq identity (format "%s|link-definition|%s"
                             identity link-definition-id)))
    (when relation-name
      (setq identity (format "%s|relation-name|%s" identity relation-name)))
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
         (relation-name (plist-get data :relation-name))
         (rel-id (supertag-generate-relation-id
                  from to type kind field-id link-definition-id relation-name))
         (relation-plist (plist-put data :id rel-id)))


    ;; Ensure created-at exists but don't overwrite if caller provided it.
    (unless (plist-get relation-plist :created-at)
      (setq relation-plist (plist-put relation-plist :created-at (supertag-current-time))))

    ;; Strict validation
    (supertag--validate-relation-data relation-plist)

    ;; Check if relation already exists
    (let* ((existing-relations (supertag-relation-find-between from to type kind))
           ;; Be defensive against malformed/nil entries in relation buckets.
           (existing-relation
            (cl-find-if
             (lambda (relation)
               (and
                t
                (or (null link-definition-id)
                    (equal link-definition-id
                           (plist-get relation :link-definition-id)))
                (equal relation-name (plist-get relation :relation-name))))
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
                                          (supertag-current-time)))))
                        (dolist (identity-key
                                 '(:from :to :type :kind :field-id
                                   :link-definition-id :relation-name))
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

;; 5.2 Reference Service

(defun supertag-relation-document-link-p (relation)
  "Return non-nil when RELATION is an Org-owned Document Link projection."
  (and (supertag-relation-kind-p relation :document-link)
       (eq (plist-get relation :origin) :org)))

(defun supertag-relation-named-document-link-p (relation &optional relation-name)
  "Return non-nil when RELATION is a named Org Document Link.
When RELATION-NAME is non-nil, require that exact name."
  (and (supertag-relation-document-link-p relation)
       (let ((name (plist-get relation :relation-name)))
         (and (stringp name)
              (not (string-empty-p name))
              (or (null relation-name) (equal name relation-name))))))

(defun supertag-relation-project-document-link (from-id to-id &optional relation-name)
  "Project the Org link FROM-ID -> TO-ID without modifying either Org file.
Partially classified Document Links are completed in place."
  (when (and relation-name
             (not (and (stringp relation-name)
                       (not (string-empty-p relation-name)))))
    (error "Document Link relation name must be a non-empty string: %S"
           relation-name))
  (let ((existing
         (cl-find-if
          (lambda (relation)
            (equal relation-name (plist-get relation :relation-name)))
          (supertag-relation-find-between
           from-id to-id :reference :document-link))))
    (cond
     ((null existing)
      (supertag-relation-create
       (append (list :type :reference :from from-id :to to-id
                     :kind :document-link :origin :org)
               (when relation-name (list :relation-name relation-name)))))
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
                        (relation-name (plist-get relation-data :relation-name))
                        (key (format "%s|%s|%s|%s|%s|%s|%s"
                                     from to type kind (or field-id "")
                                     (or link-definition-id "")
                                     (or relation-name ""))))
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

;;; Physical Org link formatting

(defun supertag-node-link-type (id)
  "Return the physical Org link type for node ID."
  (pcase (plist-get (supertag-node-get id) :link-type)
    ((or 'denote "denote") "denote")
    (_ "id")))

(defun supertag-node-format-link (id &optional title link-type)
  "Return an Org link to node ID with optional TITLE and exact LINK-TYPE.
When LINK-TYPE is nil, preserve the node's ordinary id or denote format."
  (format "[[%s:%s][%s]]"
          (or link-type (supertag-node-link-type id))
          id
          (or title id)))

(defun supertag-node-link-pattern (id)
  "Return a regexp matching this package's physical link to node ID."
  (format "\\[\\[%s:%s\\]"
          (regexp-quote (supertag-node-link-type id))
          (regexp-quote id)))

;;; 引用查询

(defgroup supertag-reference nil
  "Reference and contextual backlink support for Supertag."
  :group 'supertag)

(defcustom supertag-reference-context-length 220
  "Maximum number of characters in one contextual backlink excerpt."
  :type 'integer
  :group 'supertag-reference)

(defcustom supertag-reference-context-before 72
  "Preferred number of characters shown before the matched reference term."
  :type 'integer
  :group 'supertag-reference)

(defun supertag-reference-service--node-prop (node prop)
  "Return PROP from plist or hash-table NODE."
  (cond
   ((hash-table-p node) (gethash prop node))
   ((listp node) (plist-get node prop))
   (t nil)))

(defun supertag-reference-service--node-properties (node)
  "Return NODE's user properties as a plist."
  (let ((properties (supertag-reference-service--node-prop node :properties)))
    (cond
     ((hash-table-p properties)
      (let (result)
        (maphash (lambda (key value)
                   (setq result (plist-put result key value)))
                 properties)
        result))
     ((listp properties) properties)
     (t nil))))

(defun supertag-reference-service--split-aliases (value)
  "Return normalized aliases represented by VALUE."
  (cond
   ((null value) nil)
   ((listp value)
    (cl-remove-if #'string-empty-p
                  (mapcar (lambda (item)
                            (string-trim (format "%s" item)))
                          value)))
   ((stringp value)
    (cl-remove-if #'string-empty-p
                  (mapcar #'string-trim
                          (split-string value "[,，;；]" t))))
   (t nil)))

(defun supertag-reference-service-node-title (node-or-id)
  "Return a readable title for NODE-OR-ID."
  (let* ((node (if (stringp node-or-id)
                   (supertag-store-get-entity :nodes node-or-id)
                 node-or-id))
         (id (and (stringp node-or-id) node-or-id)))
    (or (supertag-reference-service--node-prop node :raw-value)
        (supertag-reference-service--node-prop node :title)
        id
        "Untitled")))

(defun supertag-reference-service-node-aliases (node)
  "Return reference aliases declared by NODE."
  (supertag-reference-service--split-aliases
   (plist-get (supertag-reference-service--node-properties node)
              :SUPERTAG_ALIASES)))

(defun supertag-reference-service-node-terms (node)
  "Return NODE's title and aliases as unique non-empty terms."
  (cl-delete-duplicates
   (cl-remove-if
    #'string-empty-p
    (mapcar (lambda (term) (string-trim (format "%s" term)))
            (cons (supertag-reference-service-node-title node)
                  (supertag-reference-service-node-aliases node))))
   :test #'string-equal))

(defun supertag-reference-service-node-location (node)
  "Return a compact, human-readable location label for NODE."
  (let* ((file (supertag-reference-service--node-prop node :file))
         (file-label (and file (file-name-nondirectory file)))
         (olp (supertag-reference-service--node-prop node :olp))
         (path (and (listp olp)
                    (string-join
                     (cl-remove-if #'string-empty-p
                                   (mapcar (lambda (item)
                                             (string-trim (format "%s" item)))
                                           olp))
                     " / "))))
    (cond
     ((and file-label path) (format "%s | %s" file-label path))
     (file-label file-label)
     (path path)
     (t "Store node"))))

(defun supertag-reference-service--node-date (node)
  "Return NODE's stored date as YYYY-MM-DD, or nil."
  (let ((stamp (or (supertag-reference-service--node-prop node :created-at)
                   (supertag-reference-service--node-prop node :modified-at))))
    (when stamp
      (ignore-errors (format-time-string "%Y-%m-%d" stamp)))))

(defun supertag-reference-service--clean-content (content)
  "Return CONTENT as compact prose, without physical Org link syntax."
  (let ((text (replace-regexp-in-string
               org-link-bracket-re
               (lambda (link)
                 (let ((path (match-string 1 link))
                       (description (match-string 2 link)))
                   (or description
                       (unless (string-prefix-p "id:" path t) path)
                       "")))
               (or content "") t t)))
    ;; Malformed source text must not leak partial link delimiters either.
    (setq text (replace-regexp-in-string "\\[\\[\\|\\]\\]" "" text t t))
    (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text))))

(defun supertag-reference-service--linked-description (content target-node)
  "Return CONTENT's physical link description for TARGET-NODE, if present."
  (when-let* ((target-id
               (supertag-reference-service--node-prop target-node :id)))
    (let ((regexp
           (format "\\[\\[\\(?:id\\|denote\\):%s\\]\\[\\([^]]+\\)\\]\\]"
                   (regexp-quote (format "%s" target-id)))))
      (when (string-match regexp (or content ""))
        (match-string 1 content)))))

(defun supertag-reference-service--snippet-adds-information-p
    (text source-node target-node &optional description)
  "Return non-nil when TEXT says more than a title or DESCRIPTION.
TEXT that is blank, equals the source or target node title, or is nothing
but the matched link's own DESCRIPTION adds nothing to an entry."
  (let ((text (and (stringp text) (string-trim text)))
        (description (and (stringp description) (string-trim description))))
    (and (not (string-empty-p text))
         (not (and description
                   (not (string-empty-p description))
                   (string-equal text description)))
         (not (cl-some
               (lambda (node)
                 (let ((title (string-trim
                               (or (supertag-reference-service-node-title node) ""))))
                   (and (not (string-empty-p title))
                        (string-equal text title))))
               (list source-node target-node))))))

(defun supertag-reference-service-context-snippet (source-node target-node)
  "Return cleaned prose from SOURCE-NODE's line linking to TARGET-NODE.
Select the physical link's line before normalization, so neighbouring
headlines never enter the excerpt; the link description stays in place
inside the sentence.  Semantic references fall back to a line containing
a target term.  An excerpt that only repeats an endpoint title or the
matched link's own description adds nothing and is omitted.  Strip link
syntax before length clipping."
  (let* ((case-fold-search t)
         (raw (or (supertag-reference-service--node-prop source-node :content) ""))
         (target-id (supertag-reference-service--node-prop target-node :id))
         (terms (sort (supertag-reference-service-node-terms target-node)
                      (lambda (left right) (> (length left) (length right)))))
         (position 0)
         match description)
    ;; Prefer the actual destination over an earlier mention of its title.
    (while (and (not match) (string-match org-link-bracket-re raw position))
      (let ((begin (match-beginning 0)) (end (match-end 0))
            (path (match-string 1 raw)))
        (when (and target-id
                   (member (downcase path)
                           (list (downcase (format "id:%s" target-id))
                                 (downcase (format "denote:%s" target-id)))))
          (setq match (cons begin end)
                description (match-string 2 raw)))
        (setq position end)))
    (dolist (term terms)
      (when (and (not match) (not (string-empty-p term))
                 (string-match (regexp-quote term) raw))
        (setq match (cons (match-beginning 0) (match-end 0)))))
    (unless match
      (when (string-match "[^ \t\r\n]" raw)
        (setq match (cons (match-beginning 0) (match-end 0)))))
    (when match
      (let* ((begin (or (cl-position ?\n raw :end (car match) :from-end t) -1))
             (end (or (cl-position ?\n raw :start (cdr match)) (length raw)))
             (text (supertag-reference-service--clean-content
                    (substring raw (1+ begin) end)))
             (limit (max 40 supertag-reference-context-length)))
        (when (supertag-reference-service--snippet-adds-information-p
               text source-node target-node description)
          (if (> (length text) limit)
              (concat (string-trim-right (substring text 0 (1- limit))) "…")
            text))))))

(defun supertag-reference-service-kind-label (kind)
  "Return a user-facing label for reference KIND."
  (pcase kind
    (:document-link "Document link")
    (:semantic-edge "Semantic mention")
    (:legacy-reference "Legacy reference")
    (_ "Reference")))

(defun supertag-reference-service--aggregate (anchor-id direction)
  "Aggregate references touching ANCHOR-ID in DIRECTION.

DIRECTION is `:out' for referenced targets or `:in' for Backlink sources."
  (let* ((anchor (supertag-store-get-entity :nodes anchor-id))
         (relations
          (when anchor
            (if (eq direction :out)
                (supertag-query-ordinary-references-from anchor-id)
              (supertag-query-ordinary-references-to anchor-id))))
         (by-endpoint (make-hash-table :test #'equal))
         result)
    (dolist (relation relations)
      (let* ((out-p (eq direction :out))
             (endpoint-id (plist-get relation (if out-p :to :from)))
             (endpoint (supertag-store-get-entity :nodes endpoint-id)))
        (when endpoint
          (let* ((existing (gethash endpoint-id by-endpoint))
                 (title (supertag-reference-service-node-title endpoint))
                 (location (supertag-reference-service-node-location endpoint))
                 (file (supertag-reference-service--node-prop endpoint :file))
                 (position
                  (or (supertag-reference-service--node-prop endpoint :position)
                      (supertag-reference-service--node-prop endpoint :pos)
                      0))
                 (source (if out-p anchor endpoint))
                 (target (if out-p endpoint anchor))
                 (item
                  (list :node-id endpoint-id
                        :title title
                        :location location
                        :file file
                        :date (supertag-reference-service--node-date endpoint)
                        :position position
                        :snippet
                        (supertag-reference-service-context-snippet source target)
                        :kinds
                        (cl-adjoin (plist-get relation :kind)
                                   (plist-get existing :kinds))
                        :relation-ids
                        (cl-adjoin (plist-get relation :id)
                                   (plist-get existing :relation-ids)
                                   :test #'equal))))
            ;; Direction-specific aliases keep the read model explicit for
            ;; callers that care which endpoint was projected.
            (setq item
                  (append item
                          (if out-p
                              (list :target-id endpoint-id
                                    :target-title title
                                    :target-location location)
                            (list :source-id endpoint-id
                                  :source-title title
                                  :source-location location
                                  :source-file file
                                  :source-position position))))
            (puthash endpoint-id item by-endpoint)))))
    (maphash (lambda (_endpoint-id item) (push item result)) by-endpoint)
    result))

(defun supertag-reference-service-backlinks (target-id)
  "Return contextual incoming references for TARGET-ID.

The result contains one item per source node. Multiple relation kinds from the
same source are aggregated instead of rendering duplicate cards."
  (sort
   (supertag-reference-service--aggregate target-id :in)
   (lambda (left right)
     (let ((left-file (or (plist-get left :file) ""))
           (right-file (or (plist-get right :file) "")))
       (if (string-equal left-file right-file)
           (< (or (plist-get left :position) 0)
              (or (plist-get right :position) 0))
         (string< left-file right-file))))))

(defun supertag-reference-service-outgoing (source-id)
  "Return contextual outgoing references for SOURCE-ID.

The result contains one item per target node. Multiple relation kinds between
the same endpoints are aggregated instead of rendering duplicate cards."
  (sort
   (supertag-reference-service--aggregate source-id :out)
   (lambda (left right)
     (string< (format "%s/%s"
                      (or (plist-get left :title) "")
                      (or (plist-get left :node-id) ""))
              (format "%s/%s"
                      (or (plist-get right :title) "")
                      (or (plist-get right :node-id) ""))))))

(defun supertag-reference-service--candidate-base-label (node)
  "Return the base completion label for NODE."
  (format "%s  (%s)"
          (supertag-reference-service-node-title node)
          (supertag-reference-service-node-location node)))

(defun supertag-reference-service-candidates (&optional exclude-id)
  "Return UI-ready reference candidates, excluding EXCLUDE-ID when non-nil."
  (let ((raw nil)
        (counts (make-hash-table :test #'equal))
        result)
    (maphash
     (lambda (node-id node)
       (when (and (not (equal node-id exclude-id))
                  (eq (supertag-reference-service--node-prop node :type) :node)
                  (not (string-empty-p
                        (string-trim
                         (supertag-reference-service-node-title node)))))
         (let ((base (supertag-reference-service--candidate-base-label node)))
           (puthash base (1+ (gethash base counts 0)) counts)
           (push (list :node-id node-id
                       :node node
                       :title (supertag-reference-service-node-title node)
                       :terms (supertag-reference-service-node-terms node)
                       :base-label base)
                 raw))))
     (supertag-store-get-collection :nodes))
    (dolist (candidate raw)
      (let* ((base (plist-get candidate :base-label))
             (display (if (> (gethash base counts 0) 1)
                          (format "%s [%s]" base (plist-get candidate :node-id))
                        base)))
        (push (plist-put (copy-sequence candidate) :display display) result)))
    (sort result
          (lambda (left right)
            (string< (plist-get left :display)
                     (plist-get right :display))))))

(defun supertag-reference-service-find-by-term (term &optional exclude-id)
  "Return the unique reference candidate matching TERM.
Signal an error when TERM names more than one node."
  (let* ((clean (string-trim (or term "")))
         (candidates (supertag-reference-service-candidates exclude-id))
         (exact
          (cl-remove-if-not
           (lambda (candidate)
             (member clean (plist-get candidate :terms)))
           candidates))
         (matches
          (or exact
              (let ((folded (downcase clean)))
                (cl-remove-if-not
                 (lambda (candidate)
                   (cl-some (lambda (candidate-term)
                              (string-equal folded (downcase candidate-term)))
                            (plist-get candidate :terms)))
                 candidates)))))
    (pcase (length matches)
      (0 nil)
      (1 (car matches))
      (_ (user-error "Reference title is ambiguous: %s" clean)))))

;;; 命名链接查询

(defun supertag-link-service-node-title (node-id)
  "Return a readable title for NODE-ID."
  (let ((node (supertag-store-get-entity :nodes node-id)))
    (or (plist-get node :raw-value) (plist-get node :title) node-id)))

(defun supertag-link-service-instances (node-id)
  "Return named Org links touching NODE-ID, with direction and peer title."
  (let (result)
    (dolist (direction '(:out :in))
      (dolist (relation (if (eq direction :out)
                           (supertag-query-named-links-from node-id)
                         (supertag-query-named-links-to node-id)))
        (let ((other-id (plist-get relation (if (eq direction :out) :to :from))))
          (push (list :relation relation
                      :relation-id (plist-get relation :id)
                      :direction direction
                      :label (plist-get relation :relation-name)
                      :other-node-id other-id
                      :other-title (supertag-link-service-node-title other-id))
                result))))
    (sort result
          (lambda (a b)
            (string< (format "%s/%s" (plist-get a :label)
                             (plist-get a :other-title))
                     (format "%s/%s" (plist-get b :label)
                             (plist-get b :other-title)))))))

;;; 写入与恢复

(define-error 'supertag-link-error
  "Add Link retained document state but could not finish")

(defvar supertag-reference--active-recovery-operation nil
  "Completion cell shared by nested stages of one reference recovery.")

(defun supertag-reference--retry-operation (step)
  "Run transient recovery STEP and mark it complete only on success."
  (let ((retry (aref step 0))
        (retry-args (aref step 1))
        (operation (aref step 2)))
    (let ((supertag-reference--active-recovery-operation operation))
      (prog1 (apply retry retry-args)
        (setcar operation t)))))

(defun supertag-reference-signal-retryable-error
    (stage source-id target-id file retry retry-args cause)
  "Signal a structured reference failure backed by one transient operation."
  (let* ((operation (or supertag-reference--active-recovery-operation
                        (list nil)))
         (step (vector retry retry-args operation)))
    (signal 'supertag-link-error
            (list :stage stage :source-id source-id :target-id target-id
                  :file file
                  :retry #'supertag-reference--retry-operation
                  :retry-args (list step)
                  :recovery-operation operation
                  :cause cause))))

(defun supertag-reference-recovery-complete-p (payload)
  "Return non-nil when PAYLOAD's exact transient recovery completed."
  (when-let* ((operation (plist-get payload :recovery-operation)))
    (car operation)))

(defun supertag-reference--source-id-at-marker (marker)
  "Return and synchronize the source node containing MARKER."
  (unless (and (marker-buffer marker) (buffer-live-p (marker-buffer marker)))
    (user-error "Reference source is no longer available"))
  (with-current-buffer (marker-buffer marker)
    (unless buffer-file-name
      (user-error "References require an Org buffer visiting a file"))
    (save-excursion
      (goto-char marker)
      (let ((source-id (supertag-ui--get-containing-node-at-point)))
        (unless source-id
          (user-error "The current location cannot own a reference"))
        (supertag-ui--ensure-node-synced source-id)
        (unless (supertag-node-get source-id)
          (user-error "The source node could not be synchronized"))
        source-id))))

(defun supertag-reference--existing-source-id-at-marker (marker)
  "Return MARKER's already persisted heading ID without creating one."
  (when (and (marker-buffer marker) (buffer-live-p (marker-buffer marker)))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (ignore-errors
          (org-back-to-heading t)
          (org-entry-get nil "ID"))))))

(defun supertag-reference--capture-draft-p ()
  "Return non-nil in a file-backed Org capture indirect buffer.
Finalization and sync own persistence; reference completion only edits
the draft."
  (and (bound-and-true-p org-capture-mode)
       (derived-mode-p 'org-mode)
       (buffer-base-buffer)
       (buffer-file-name (buffer-base-buffer))))

(defun supertag-reference-materialize
    (beg-marker end-marker target-id title &optional link-type)
  "Materialize BEG-MARKER..END-MARKER as a link to TARGET-ID titled TITLE.

This is the system's sole production gateway for reference commands that
commit a source-owned physical `[[id:]]' node link to an Org buffer.  Callers
that replace a region pass its boundary markers.  Pure display renderers and
explicitly marked machine-generated view regions may still emit link-shaped
strings because the projector excludes those regions from Document Links.
In an active Org capture draft, only replace the text; defer source identity,
saving and projection to the normal capture finalization/sync lifecycle."
  (let ((source-buffer (marker-buffer beg-marker)))
    (unless (and source-buffer (eq source-buffer (marker-buffer end-marker)))
      (user-error "Reference region is no longer valid"))
    (with-current-buffer source-buffer
      (supertag-reference--validate-source beg-marker)
      (let ((source-id
             (if (supertag-reference--capture-draft-p)
                 (supertag-reference--existing-source-id-at-marker beg-marker)
               (supertag-reference--source-id-at-marker beg-marker))))
        (when (equal source-id target-id)
          (user-error "A node cannot reference itself through this workflow"))
        (if link-type
            (supertag-ui--replace-region-with-reference
             beg-marker end-marker source-id target-id title link-type)
          (supertag-ui--replace-region-with-reference
           beg-marker end-marker source-id target-id title))
        (message "Linked to %s" title)
        target-id))))

(defun supertag-reference-materialize-at-point (target-id title &optional link-type)
  "Materialize an empty region at point as a link to TARGET-ID titled TITLE.

This is the at-point adapter for `supertag-reference-materialize'.  It owns and
releases the temporary markers required when source synchronization inserts an
Org ID or property drawer before point."
  (let ((beg-marker (copy-marker (point)))
        (end-marker (copy-marker (point) t)))
    (unwind-protect
        (if link-type
            (supertag-reference-materialize
             beg-marker end-marker target-id title link-type)
          (supertag-reference-materialize
           beg-marker end-marker target-id title))
      (set-marker beg-marker nil)
      (set-marker end-marker nil))))

(defun supertag-reference--projected-p (source-id target-id link-type)
  "Return non-nil when the requested document link Projection exists."
  (cl-find-if
   (lambda (relation)
     (and (supertag-relation-document-link-p relation)
          (if link-type
              (equal link-type (plist-get relation :relation-name))
            (null (plist-get relation :relation-name)))))
   (supertag-relation-find-between source-id target-id :reference)))

(defun supertag-reference-retry-source-projection
    (source-id file target-id link-type)
  "Retry Projection for a saved link without inserting another link."
  (if (and (supertag-node-get source-id)
           (zerop (or (plist-get (supertag-node-get source-id) :level) 1)))
      (with-current-buffer (find-file-noselect file)
        (supertag-ui--ensure-file-node-synced file))
    (supertag-service-org-retry-node-projection source-id file))
  (unless (supertag-reference--projected-p source-id target-id link-type)
    (user-error "Saved Org link still has no matching Projection"))
  target-id)

(defun supertag-reference-retry-source-save (source-id file target-id link-type)
  "Retry saving a retained live link, then rebuild its Projection once."
  (let ((definition (symbol-function 'supertag-text-link-validate-type)))
    (when (autoloadp definition)
      (autoload-do-load definition 'supertag-text-link-validate-type)))
  (let ((previous-session supertag-text-link--session-types))
    (condition-case cause
        (with-current-buffer (find-file-noselect file)
          (save-buffer))
      (error
       (setq supertag-text-link--session-types previous-session)
       (supertag-text-link-refresh)
       (signal (car cause) (cdr cause))))
    (when link-type
      (supertag-text-link-accept-session-type link-type))
    (condition-case cause
        (supertag-reference-retry-source-projection
         source-id file target-id link-type)
      (error
       (supertag-reference-signal-retryable-error
        :source-project source-id target-id file
        #'supertag-reference-retry-source-projection
        (list source-id file target-id link-type) cause)))))

(defun supertag-reference--commit-region (&rest args)
  "Compatibility wrapper for region materialization."
  (apply #'supertag-reference-materialize args))

(defun supertag-reference--create-from-template (title template)
  "Create a fresh ordinary node titled TITLE using complete TEMPLATE."
  (let ((preset (supertag-template-normalize template)))
    (supertag-service-org-create-node
     (plist-get preset :target-file) title (plist-get preset :tags)
     (list :properties (plist-get preset :properties)
           :body (plist-get preset :body)
           :create-file t))))

(defun supertag-reference--create-target (title template)
  "Create TITLE from TEMPLATE or signal a staged Add Link error."
  (condition-case cause
      (supertag-reference--create-from-template title template)
    (supertag-document-save-error
     (signal 'supertag-link-error
             (append (list :stage :target-save) (cdr cause))))
    (supertag-projection-error
     (signal 'supertag-link-error
             (append (list :stage :target-project) (cdr cause))))))

(defun supertag-reference--resolve-or-create
    (input selected &optional choose-target template)
  "Resolve INPUT or SELECTED candidate, creating when necessary.
When CHOOSE-TARGET is non-nil, prompt for the creation target."
  (let* ((selected-id
          (and selected
               (get-text-property 0 'supertag-reference-node-id selected)))
         (selected-title
          (and selected
               (get-text-property 0 'supertag-reference-title selected)))
         (explicit-create
          (and selected
               (get-text-property 0 'supertag-reference-create-title selected)))
         (clean (supertag-reference--normalize-title
                 (or selected-title explicit-create input)))
         (existing (and (not selected-id) (not explicit-create)
                        (supertag-reference-service-find-by-term clean)))
         (target-id (or selected-id (plist-get existing :node-id)))
         (title (or selected-title (plist-get existing :title) clean)))
    (when (string-empty-p title)
      (user-error "Reference title cannot be empty"))
    (unless target-id
      (setq target-id
            (supertag-reference--create-target
             title (or template (supertag-template-read)))))
    (cons target-id title)))

(defun supertag-reference--read-link-type ()
  "Read, validate and register an optional explicit relation name."
  (let ((name (string-trim
               (completing-read "Relation name: "
                                (supertag-text-link-candidates) nil nil))))
    (when (string-empty-p name)
      (user-error "Relation name cannot be empty"))
    (supertag-text-link-validate-type name)))

(defun supertag-reference--validate-source (marker)
  "Reject MARKER when it cannot own a link, without creating identity."
  (unless (and (marker-buffer marker)
               (buffer-live-p (marker-buffer marker)))
    (user-error "Reference source is no longer available"))
  (with-current-buffer (marker-buffer marker)
    (unless (and (derived-mode-p 'org-mode)
                 (or buffer-file-name (supertag-reference--capture-draft-p)))
      (user-error "References require an Org buffer visiting a file"))
    (save-excursion
      (goto-char marker)
      (or (ignore-errors (org-back-to-heading t) t)
          (supertag-node-location--file-org-id)
          (supertag-node-location--file-denote-id)
          (user-error "The current location cannot own a reference")))))

(defun supertag-ui--document-link-bounds (node-id)
  "Return the direct Org content bounds owned by NODE-ID."
  (save-excursion
    (org-with-wide-buffer
      (if (supertag-ui--file-node-p node-id)
          (progn
            (goto-char (point-min))
            (cons (point-min)
                  (if (re-search-forward "^\\*+\\s-" nil t)
                      (match-beginning 0)
                    (point-max))))
        (org-back-to-heading t)
        (org-end-of-meta-data t)
        (let ((start (point)))
          (cons start
                (if (re-search-forward org-outline-regexp-bol nil t)
                    (match-beginning 0)
                  (point-max))))))))

(defun supertag-ui--replace-region-with-reference
    (beg-marker end-marker from-id to-id title &optional link-type)
  "Implement `supertag-reference-materialize' for FROM-ID, TO-ID, and TITLE.
LINK-TYPE is an exact named relation type or nil for an ordinary link.  This
private helper is the materializer's only low-level buffer mutation."
  (let ((file (buffer-file-name)))
    (goto-char beg-marker)
    (delete-region beg-marker end-marker)
    (insert (supertag-node-format-link to-id title link-type))
    ;; An Org capture buffer shares its text with the destination but must
    ;; remain a draft: finalize/abort, not completion, owns its persistence.
    (unless (supertag-reference--capture-draft-p)
      (condition-case cause
          (save-buffer)
        (error
         (supertag-reference-signal-retryable-error
          :source-save from-id to-id file
          #'supertag-reference-retry-source-save
          (list from-id file to-id link-type) cause)))
      (condition-case cause
          (progn
            (supertag-ui--reproject-containing-node from-id)
            (unless (cl-find-if
                     (lambda (relation)
                       (and (supertag-relation-document-link-p relation)
                            (if link-type
                                (equal link-type
                                       (plist-get relation :relation-name))
                              (null (plist-get relation :relation-name)))))
                     (supertag-relation-find-between
                      from-id to-id :reference))
              (error "Saved Org link has no matching Document Link Projection")))
        (error
         (supertag-reference-signal-retryable-error
          :source-project from-id to-id file
          #'supertag-reference-retry-source-projection
          (list from-id file to-id link-type) cause))))))

;;; 补全

(defvar supertag-reference-history nil
  "Minibuffer history for create-or-link reference commands.")

(defcustom supertag-reference-shorthand-openers
  '(("[[" . "]]") ("【【" . "】】"))
  "Opener/closer pairs that start a create-or-link shorthand.

Each element is (OPENER . CLOSER).  Typing OPENER followed by a title
offers reference completion; committing a candidate rewrites the whole
shorthand, including OPENER and a CLOSER the user (or an input method)
already typed, to the canonical Org link `[[id:TARGET][Title]]'.

The full-width pair lets Chinese input methods trigger the workflow
without switching to ASCII brackets."
  :type '(repeat (cons (string :tag "Opener") (string :tag "Closer")))
  :group 'supertag)

(defun supertag-reference--opener-regexp ()
  "Return a regexp matching any configured shorthand opener."
  (regexp-opt (mapcar #'car supertag-reference-shorthand-openers)))

(defun supertag-reference--closer-regexp ()
  "Return a regexp matching any configured shorthand closer."
  (regexp-opt (mapcar #'cdr supertag-reference-shorthand-openers)))

(defun supertag-reference--opener-position (start)
  "Return the buffer position of the shorthand opener ending at START.
Return nil when no configured opener ends exactly at START."
  (save-excursion
    (goto-char start)
    (cl-loop for (opener . _closer) in supertag-reference-shorthand-openers
             for beg = (- start (length opener))
             when (and (>= beg (point-min))
                       (equal (buffer-substring-no-properties beg start)
                              opener))
             return beg)))

(defun supertag-reference--normalize-title (title)
  "Return TITLE as one trimmed line."
  (string-trim
   (replace-regexp-in-string "[ \t\n\r]+" " " (or title ""))))

(defconst supertag-reference--link-scheme-regexp
  "\\`\\(?:id\\|denote\\|file\\|https?\\|ftp\\|mailto\\):"
  "Regexp matching the path of an Org link that names a real target scheme.")

(defconst supertag-reference--create-suffix "  [Create new node]"
  "Suffix of the explicit create row offered by reference completion.")

(defun supertag-reference--shorthand-link-p (context)
  "Return non-nil when link CONTEXT is still an unfinished shorthand title.

`org-element' parses `[[Title]]' as a `link' from the moment the opener is
typed, and an auto-pairing input method adds the closer before the title is
chosen.  Such a link carries no description and no known link scheme."
  (and (not (org-element-property :contents-begin context))
       (not (string-match-p
             supertag-reference--link-scheme-regexp
             (or (org-element-property :raw-link context) "")))))

(defun supertag-reference--completion-context-p ()
  "Return non-nil when point is prose that may own a reference shorthand."
  (let* ((context (org-element-context))
         (type (org-element-type context)))
    (and (or (and (eq type 'link)
                  (supertag-reference--shorthand-link-p context))
             (not (memq type '(link code verbatim comment comment-block keyword
                               node-property property-drawer drawer src-block
                               example-block table table-row table-cell
                               fixed-width))))
         (not (org-in-commented-heading-p)))))

(defun supertag-reference--get-prefix-bounds ()
  "Return bounds after an unmatched shorthand opener before point, or nil.

Openers come from `supertag-reference-shorthand-openers' (`[[' and `【【'
by default).  The bounds cover only the user-entered title.  Existing Org
links using a known link scheme are deliberately ignored."
  (when (and (derived-mode-p 'org-mode)
             (supertag-reference--completion-context-p))
    (save-excursion
      (let ((end (point)))
        (when (re-search-backward (supertag-reference--opener-regexp)
                                  (line-beginning-position) t)
          (let* ((start (match-end 0))
                 (prefix (buffer-substring-no-properties start end)))
            (when (and (not (string-match-p
                             (supertag-reference--closer-regexp) prefix))
                       (not (string-match-p
                             supertag-reference--link-scheme-regexp
                             prefix)))
              (cons start end))))))))

(defun supertag-reference--candidate-strings (&optional exclude-id)
  "Return completion strings for reference targets excluding EXCLUDE-ID."
  (let (result)
    (dolist (candidate (supertag-reference-service-candidates exclude-id))
      (let* ((node-id (plist-get candidate :node-id))
             (title (plist-get candidate :title)))
        (dolist (term (plist-get candidate :terms))
          (let ((display
                 (if (string-equal term title)
                     (plist-get candidate :display)
                   (format "%s  -> %s"
                           term (plist-get candidate :display)))))
            (push (propertize display
                              'supertag-reference-node-id node-id
                              'supertag-reference-title title
                              'supertag-reference-term term)
                  result)))))
    (sort result
          (lambda (left right)
            (string< (substring-no-properties left)
                     (substring-no-properties right))))))

(defun supertag-reference--exact-term-p (term candidates)
  "Return non-nil when TERM exactly identifies an existing CANDIDATE term."
  (let ((folded (downcase term)))
    (cl-some
     (lambda (candidate)
       (string-equal
        folded
        (downcase
         (or (get-text-property 0 'supertag-reference-term candidate) ""))))
     candidates)))

(defun supertag-reference--node-has-term-p (node-id term)
  "Return non-nil when NODE-ID already owns TERM as a title or alias."
  (when-let* ((node (and node-id
                         (supertag-store-get-entity :nodes node-id))))
    (let ((folded (downcase term)))
      (cl-some (lambda (candidate-term)
                 (string-equal folded (downcase candidate-term)))
               (supertag-reference-service-node-terms node)))))

(defun supertag-reference--create-row-p (candidate)
  "Return non-nil when CANDIDATE is the explicit create row."
  (get-text-property 0 'supertag-reference-create-title candidate))

(defun supertag-reference--completion-candidates (title exclude-id)
  "Return completion candidates for TITLE, excluding EXCLUDE-ID.

Existing node terms come first; an explicit create row is offered last when
TITLE would create a node EXCLUDE-ID does not already own."
  (let* ((clean (supertag-reference--normalize-title title))
         (existing (supertag-reference--candidate-strings exclude-id))
         (row-regexp (concat "[ \t]+"
                             (regexp-quote
                              (string-trim-left supertag-reference--create-suffix))
                             "\\'"))
         (create
          (when (and (not (string-empty-p clean))
                     ;; The completion machinery calls the table again after it
                     ;; inserted the row; never grow a second create row from
                     ;; the row text already in the buffer.
                     (not (string-match-p row-regexp clean))
                     (not (supertag-reference--node-has-term-p exclude-id clean)))
            (list
             (propertize
              (concat clean supertag-reference--create-suffix)
              'supertag-reference-create-title clean)))))
    (append existing create)))

(defun supertag-reference--completion-title (string live-prefix)
  "Return the title the create row should name for STRING at LIVE-PREFIX.

STRING is the text the completion style completes, so it still names the
typed title when a UI calls the table back with an already inserted create
row (Corfu checks `test-completion' that way)."
  (if (and (stringp string)
           (string-suffix-p supertag-reference--create-suffix string))
      (substring string 0 (- (length string)
                             (length supertag-reference--create-suffix)))
    (supertag-reference--normalize-title live-prefix)))

(defun supertag-reference--completion-table (captured-prefix exclude-id)
  "Return a dynamic completion table for CAPTURED-PREFIX and EXCLUDE-ID."
  (lambda (string predicate action)
    (let* ((live-bounds (and (not (minibufferp))
                             (supertag-reference--get-prefix-bounds)))
           (live-prefix
            (if live-bounds
                (buffer-substring-no-properties
                 (car live-bounds) (cdr live-bounds))
              captured-prefix))
           (candidates
            (supertag-reference--completion-candidates
             (supertag-reference--completion-title string live-prefix)
             exclude-id))
           (existing (cl-remove-if #'supertag-reference--create-row-p candidates)))
      (cond
       ((eq (car-safe action) 'boundaries) nil)
       ((eq action 'metadata)
        '(metadata
          (category . supertag-reference)
          (cycle-sort-function . identity)
          (company-kind
           . (lambda (candidate)
               (if (supertag-reference--create-row-p candidate)
                   'snippet
                 'reference)))))
       ((eq action t)
        (complete-with-action t candidates string predicate))
       ((eq action 'lambda)
        ;; Only the explicit create row authorizes creation; a typed prefix
        ;; never equals the full row string, and an existing term still does.
        (test-completion string candidates predicate))
       ((null action)
        ;; An exact row completes; otherwise only existing targets shape the
        ;; common prefix, so a unique existing match still expands while the
        ;; create row never dilutes it.
        (or (try-completion string existing predicate)
            (and (test-completion string candidates predicate) t)
            string))
       (t
        (complete-with-action action candidates string predicate))))))

(defun supertag-reference--recover-selection (selected prefix exclude-id)
  "Return SELECTED as a completion candidate string, restoring properties.

Some UI paths (Corfu falls back to the plain string when its candidate list
is gone) hand the exit function text without the `supertag-reference-*'
properties.  Match the plain text against the table's candidates: a full row
plus the create title, so a bare title still creates instead of doing
nothing."
  (let ((plain (substring-no-properties selected))
        (candidates (supertag-reference--completion-candidates prefix exclude-id)))
    (or (cl-find plain candidates
                 :key #'substring-no-properties :test #'equal)
        (cl-find plain candidates
                 :key (lambda (candidate)
                        (get-text-property
                         0 'supertag-reference-create-title candidate))
                 :test #'equal)
        selected)))

(defun supertag-reference--post-completion
    (selected status open-marker &optional prefix exclude-id)
  "Commit SELECTED completion with STATUS beginning at OPEN-MARKER.

PREFIX and EXCLUDE-ID describe the completion table SELECTED came from; they
recover SELECTED when it arrives without reference text properties."
  (unwind-protect
      (when (and (memq status '(finished exact sole))
                 (marker-buffer open-marker))
        (when (and prefix
                   (not (get-text-property
                         0 'supertag-reference-node-id selected))
                   (not (get-text-property
                         0 'supertag-reference-create-title selected))
                   (not (get-text-property 0 'supertag-reference-title selected)))
          (setq selected
                (supertag-reference--recover-selection
                 selected prefix exclude-id)))
        (let* ((target-id
                (get-text-property 0 'supertag-reference-node-id selected))
               (create-title
                (get-text-property 0 'supertag-reference-create-title selected))
               (title
                (or (get-text-property 0 'supertag-reference-title selected)
                    create-title)))
          (when (or target-id create-title)
            (let* ((resolved
                    (if target-id
                        (cons target-id title)
                      (progn
                        (supertag-reference--validate-source open-marker)
                        (supertag-reference--resolve-or-create
                         create-title selected nil))))
                   (end-marker (copy-marker (point) t)))
              ;; Consume a closing pair the user (or an input method that
              ;; auto-pairs brackets) typed before completion.
              (when (looking-at (supertag-reference--closer-regexp))
                (set-marker end-marker (match-end 0)))
              (unwind-protect
                  (supertag-reference-materialize
                   open-marker end-marker (car resolved) (cdr resolved))
                (set-marker end-marker nil))))))
    (set-marker open-marker nil)))

;;;###autoload
(defun supertag-reference-completion-at-point ()
  "Complete a Supertag reference after an unmatched shorthand opener.
See `supertag-reference-shorthand-openers' for the recognised openers."
  (when-let* ((bounds (supertag-reference--get-prefix-bounds)))
    (let* ((start (car bounds))
           (end (cdr bounds))
           (prefix (buffer-substring-no-properties start end))
           (source-id
            (save-excursion
              (ignore-errors
                (org-back-to-heading t)
                (org-entry-get nil "ID"))))
           (open-marker
            (copy-marker (or (supertag-reference--opener-position start)
                             (- start 2)))))
      (list start end
            (supertag-reference--completion-table prefix source-id)
            :company-prefix-length t
            :exclusive 'yes
            :exit-function
            (lambda (selected status)
              (supertag-reference--post-completion
               selected status open-marker prefix source-id))))))

(defun supertag-reference--read-candidate (initial exclude-id)
  "Read a reference target with INITIAL input, excluding EXCLUDE-ID."
  (let* ((candidates (supertag-reference--candidate-strings exclude-id))
         (create (and initial
                      (not (string-empty-p
                            (supertag-reference--normalize-title initial)))
                      (propertize
                       (format "%s  [Create new node]"
                               (supertag-reference--normalize-title initial))
                       'supertag-reference-create-title
                       (supertag-reference--normalize-title initial))))
         (candidates (if create (append candidates (list create)) candidates))
         (plain (mapcar (lambda (candidate)
                          (cons (substring-no-properties candidate) candidate))
                        candidates))
         (input (completing-read
                 "Reference (type a new title to create): "
                 plain nil nil initial 'supertag-reference-history))
         (selected (cdr (assoc input plain))))
    (when (and (not selected)
               (not (string-empty-p (supertag-reference--normalize-title input))))
      (let* ((title (supertag-reference--normalize-title input))
             (create (propertize
                      (format "%s  [Create new node]" title)
                      'supertag-reference-create-title title))
             (choice (completing-read
                      (format "Create a new node named %s: " title)
                      (list create) nil t)))
        (setq selected (and (equal choice create) create))))
    (cons input selected)))

;;; 命令

;;;###autoload
(defun supertag-add-link (&optional named)
  "Insert or replace text with a reference to an existing or new node.

With active region, preserve its text as the link description.  Without a
region, use the target title.  With prefix argument NAMED, prompt for an exact
relationship name; ordinary invocation keeps native id or denote formatting."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "Create-or-link works only in Org buffers"))
  (let* ((beg (if (use-region-p) (region-beginning) (point)))
         (end (if (use-region-p) (region-end) (point)))
         (raw-description (and (< beg end)
                               (buffer-substring-no-properties beg end)))
         (initial (and raw-description
                       (supertag-reference--normalize-title raw-description)))
         (beg-marker (copy-marker beg))
         (end-marker (copy-marker end t)))
    (unwind-protect
        (let* ((exclude-id
                (supertag-reference--existing-source-id-at-marker beg-marker))
               (read-result
                (supertag-reference--read-candidate initial exclude-id))
               ;; Validate and synchronize the source only after the user has
               ;; committed to a target.  Cancelling completion leaves the Org
               ;; document untouched.
               (selected (cdr read-result))
               (selected-id (and selected
                                 (get-text-property
                                  0 'supertag-reference-node-id selected)))
               (explicit-create
                (and selected
                     (get-text-property
                      0 'supertag-reference-create-title selected)))
               (existing (and (not selected-id) (not explicit-create)
                              (supertag-reference-service-find-by-term
                               (car read-result) exclude-id)))
               (new-target (not (or selected-id existing)))
               (template (and new-target (supertag-template-read)))
               (link-type (and named (supertag-reference--read-link-type))))
          (supertag-reference--validate-source beg-marker)
          (let ((definition (symbol-function 'supertag-text-link-validate-type)))
            (when (autoloadp definition)
              (autoload-do-load definition 'supertag-text-link-validate-type)))
          (let* ((resolved
                  (supertag-reference--resolve-or-create
                   (car read-result) selected nil template))
                 (description (or raw-description (cdr resolved)))
                 (previous-session supertag-text-link--session-types))
            (when link-type
              (supertag-text-link-accept-session-type link-type))
            (condition-case error-data
                (supertag-reference-materialize
                 beg-marker end-marker (car resolved) description link-type)
              (error
               (unless (and (eq (car error-data) 'supertag-link-error)
                            (eq (plist-get (cdr error-data) :stage)
                                :source-project))
                 (setq supertag-text-link--session-types previous-session)
                 (supertag-text-link-refresh))
               (if (eq (car error-data) 'supertag-link-error)
                   (signal (car error-data) (cdr error-data))
                 (if new-target
                   (signal 'supertag-link-error
                           (list :stage :source-commit
                                 :target-id (car resolved)
                                 :cause error-data))
                   (signal (car error-data) (cdr error-data))))))))
      (set-marker beg-marker nil)
      (set-marker end-marker nil))))







(defun supertag-link--read-link-to-delete (from-node-id)
  "Interactively select a reference to remove from a given node.
FROM-NODE-ID is the ID of the node whose references are to be listed.
Returns the ID of the selected node to unlink."
  (let ((ref-to-ids
         (mapcar (lambda (relation) (plist-get relation :to))
                 (cl-remove-if-not
                  #'supertag-relation-document-link-p
                  (supertag-relation-find-by-from
                   from-node-id :reference)))))
    (if (not ref-to-ids)
        (progn (message "Node has no outgoing references.") nil)
      (let* ((candidates
              (mapcar (lambda (node-id)
                        (let* ((node-data (supertag-node-get node-id))
                               (title (or (plist-get node-data :title) "Untitled"))
                               (file (plist-get node-data :file)))
                          (cons (if file
                                    (format "%s  (in %s)" title (file-name-nondirectory file))
                                  (format "%s  [orphaned]" title))
                                node-id)))
                      ref-to-ids))
             (selected-display (completing-read "Delete link to: " candidates nil t)))
        (when selected-display
          (cdr (assoc selected-display candidates)))))))

(defun supertag-link--delete-link-element (from-id link)
  "Delete complete Org LINK, save its buffer, and reproject FROM-ID."
  (delete-region (org-element-property :begin link)
                 (org-element-property :end link))
  (save-buffer)
  (supertag-ui--reproject-containing-node from-id))

(defun supertag-delete-link ()
  "Remove a source-owned Document Link from the current node."
  (interactive)
  (let ((from-id (supertag-ui--get-containing-node-at-point)))
    (unless from-id
      (user-error "Point must be inside an Org heading or file node."))
    (supertag-ui--ensure-node-synced from-id)
    (let ((to-id (supertag-link--read-link-to-delete from-id)))
      (when to-id
        (let ((bounds (supertag-ui--document-link-bounds from-id))
              deleted)
          (save-excursion
            (goto-char (car bounds))
            (when (re-search-forward (supertag-node-link-pattern to-id)
                                     (cdr bounds) t)
              (goto-char (match-beginning 0))
              (when-let* ((link (org-element-context)))
                (when (and (eq (org-element-type link) 'link)
                           (string= (org-element-property :path link) to-id))
                  (supertag-link--delete-link-element from-id link)
                  (setq deleted t)))))
          ;; Preserve the command's save/projection boundary even if its
          ;; selected projected reference has no matching physical link.
          (unless deleted
            (save-buffer)
            (supertag-ui--reproject-containing-node from-id)))
        (message "Reference to node %s removed." to-id)))))

;;; 节点视图段


(defun supertag-view-reference--kind-summary (item)
  "Return a compact reference-kind summary for ITEM."
  (mapconcat #'supertag-reference-service-kind-label
             (sort (copy-sequence (or (plist-get item :kinds) '()))
                   (lambda (left right)
                     (string< (symbol-name (or left :unknown))
                              (symbol-name (or right :unknown)))))
             ", "))

(defun supertag-view-reference--insert-card (item)
  "Insert one magazine-style contextual reference ITEM.
An entry is the `→ title' line, one muted excerpt line when the excerpt
service kept one that adds information, and one muted file/date line.
Entries are separated by one blank line."
  ;; lazy-require: ordinary providers stay lazy, as this file's header states.
  (require 'supertag-view-framework)
  (let* ((node-id (or (plist-get item :node-id) (plist-get item :source-id)
                      (plist-get item :target-id)))
         (title (or (plist-get item :title) (plist-get item :source-title)
                    (plist-get item :target-title) node-id))
         (location (or (plist-get item :location) (plist-get item :source-location)
                       (plist-get item :target-location)))
         (kind-summary (supertag-view-reference--kind-summary item))
         (details (string-join (delq nil (list location
                                               (unless (string-empty-p kind-summary) kind-summary)))
                               " | "))
         (file (plist-get item :file))
         (date (plist-get item :date))
         (metadata (string-join
                    (delq nil (list (supertag-view-helper-file-display-name file)
                                    (and (stringp date) (not (string-empty-p date)) date)))
                    " · "))
         (snippet (plist-get item :snippet))
         (excerpt (and snippet
                       (car (supertag-view-helper-wrap
                             snippet (- (supertag-view-helper-width) 7) 1))))
         (start (point)))
    (insert "  ")
    (insert-text-button title 'face 'supertag-view-entry 'follow-link t
                        'action (lambda (&optional _button)
                                  (interactive)
                                  (supertag-goto-node node-id))
                        'supertag-node-id node-id
                        'help-echo (if (string-empty-p details)
                                       (format "Jump to %s" title)
                                     (format "%s — %s" details title)))
    (insert "\n")
    (supertag-view-helper-insert-excerpt excerpt)
    (unless (string-empty-p metadata)
      (insert (propertize (supertag-view-helper-clip (concat "      " metadata))
                          'face 'supertag-view-mute)
              "\n"))
    (insert "\n")
    (add-text-properties start (point)
                         `(line-spacing 0.15 supertag-reference-node-id ,node-id
                           supertag-reference-relation-ids ,(plist-get item :relation-ids)))))

(defun supertag-view-reference-insert-outgoing-section (node-id)
  "Insert nonempty contextual outgoing references for NODE-ID."
  (let ((references (supertag-reference-service-outgoing node-id)))
    (when references
      (insert "\n")
      (supertag-view-helper-insert-section-chip "References" (length references)
                                                   'supertag-view-chip1)
      (dolist (item references)
        (supertag-view-reference--insert-card item)))))

(defun supertag-view-reference-insert-backlinks-section (node-id)
  "Insert nonempty contextual backlinks for NODE-ID."
  (let ((backlinks (supertag-reference-service-backlinks node-id)))
    (when backlinks
      (insert "\n")
      (supertag-view-helper-insert-section-chip "Backlinks" (length backlinks)
                                                   'supertag-view-chip2)
      (dolist (item backlinks)
        (supertag-view-reference--insert-card item)))))

(defun supertag-view-reference-insert-sections (node-id)
  "Insert nonempty outgoing-reference and backlink sections for NODE-ID."
  (supertag-view-reference-insert-outgoing-section node-id)
  (supertag-view-reference-insert-backlinks-section node-id))

(provide 'supertag-link)
;;; supertag-link.el ends here
