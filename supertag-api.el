;;; supertag-api.el --- Plain-data API for agents and bridges -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; The callee surface Supertag offers to an external agent host (for example
;; a superchat bridge plugin).  Every function here takes and returns plain
;; data — strings, numbers, t/nil, keywords, and plists with keyword keys —
;; so a host can register each one as an LLM tool without learning
;; Supertag's internals, and `supertag-api-json' renders any result as JSON.
;;
;; Three functions read:
;;   `supertag-api-query'   — run a query, return node summaries
;;   `supertag-api-node'    — one node with fields, links and references
;;   `supertag-api-schema'  — one Tag with its fields and Link Definitions
;; Three functions write:
;;   `supertag-api-set-field' — set a field value with provenance
;;   `supertag-api-link'      — create a typed Link between two nodes
;;   `supertag-api-add-field' — define a field on a Tag
;; `supertag-api-catalog' declares each function's effect (`:read' or
;; `:write') and parameters so a host can map them onto its own authority
;; model instead of guessing.
;;
;; Writes go through the same Ops functions the UI uses, inside the same
;; transactions and validation.  A field value written here carries
;; provenance (`:origin :agent' by default, bound to the node's current
;; `:hash'), so views can tell agent projections from human-confirmed facts
;; and a host can re-extract a value once the source text changed.  This
;; module never creates document references (`[[id:…]]' links): those are
;; projections of the Org text, which only the document itself may change.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-core-schema)
(require 'supertag-ops-node)
(require 'supertag-ops-tag)
(require 'supertag-ops-schema)
(require 'supertag-ops-field)
(require 'supertag-ops-global-field)
(require 'supertag-ops-relation)
(require 'supertag-ops-link-definition)
(require 'supertag-services-query)
(require 'supertag-services-link)

;;; --- Argument helpers ---

(defun supertag-api--string (value name)
  "Return VALUE when it is a non-blank string; otherwise signal naming NAME."
  (unless (and (stringp value) (not (string-blank-p value)))
    (error "%s must be a non-empty string, got %S" name value))
  value)

(defun supertag-api--keyword (value)
  "Return VALUE as a keyword; strings and symbols are accepted, nil stays nil."
  (cond
   ((null value) nil)
   ((keywordp value) value)
   ((symbolp value) (intern (concat ":" (symbol-name value))))
   ((stringp value)
    (let ((text (string-trim value)))
      (if (string-empty-p text)
          nil
        (intern (concat ":" (string-remove-prefix ":" text))))))
   (t (error "Expected a keyword or string, got %S" value))))

(defun supertag-api--list (value)
  "Return VALUE as a list; vectors (from JSON arrays) are converted."
  (if (vectorp value) (append value nil) value))

(defun supertag-api--plist (&rest pairs)
  "Return a plist from PAIRS, dropping every pair whose value is nil."
  (let (result)
    (while pairs
      (let ((key (pop pairs))
            (value (pop pairs)))
        (when value
          (setq result (append result (list key value))))))
    result))

(defun supertag-api--node (node-id)
  "Return the node plist for NODE-ID or signal when it does not exist."
  (supertag-api--string node-id "node id")
  (or (supertag-node-get node-id)
      (error "Unknown node %s" node-id)))

(defun supertag-api--tag-id (tag)
  "Resolve TAG (Tag ID, name or alias) to a Tag ID or signal."
  (supertag-api--string tag "tag")
  (or (and (supertag-tag-get tag) tag)
      (supertag-tag-resolve-occurrence tag)
      (error "Unknown tag %s" tag)))

;;; --- Shapes ---

(defun supertag-api--tag-summary (tag-id)
  "Return TAG-ID as (:id :name)."
  (let ((tag (supertag-tag-get tag-id)))
    (list :id tag-id :name (or (plist-get tag :name) tag-id))))

(defun supertag-api--node-summary (node-id)
  "Return a compact summary of NODE-ID, or nil when it does not exist."
  (when-let* ((node (supertag-node-get node-id)))
    (list :id node-id
          :title (or (plist-get node :title) "")
          :tags (supertag-query-node-tags node-id)
          :file (plist-get node :file))))

(defun supertag-api--field-schema (field)
  "Return global FIELD definition as plain data."
  (let ((default (plist-get field :default)))
    (list :id (plist-get field :id)
          :name (plist-get field :name)
          :type (plist-get field :type)
          :options (plist-get field :options)
          :required (and (plist-get field :required) t)
          :default (unless (functionp default) default)
          :description (plist-get field :description))))

(defun supertag-api--link-schema (definition)
  "Return Link DEFINITION as plain data."
  (list :id (plist-get definition :id)
        :name (plist-get definition :name)
        :inverse-name (plist-get definition :inverse-name)
        :from (plist-get definition :from-tag-id)
        :to (plist-get definition :to-tag-id)
        :from-cardinality (plist-get definition :from-cardinality)
        :to-cardinality (plist-get definition :to-cardinality)))

(defun supertag-api--node-fields (node-id tag-ids)
  "Return NODE-ID's field values across TAG-IDS, one entry per global field.
`:value' is the stored value (nil when unset; `:default' shows the schema
default), `:provenance' the record from `supertag-field-provenance', and
`:stale' whether an agent value predates the node's current text."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (tag-id tag-ids)
      (dolist (field (ignore-errors (supertag-tag-get-all-fields tag-id)))
        (let ((field-id (plist-get field :id))
              (name (plist-get field :name)))
          (unless (or (null field-id) (gethash field-id seen))
            (puthash field-id t seen)
            (push (append (list :tag tag-id)
                          (supertag-api--field-schema field)
                          (list :value (supertag-field-get node-id tag-id name)
                                :provenance (supertag-field-provenance
                                             node-id tag-id name)
                                :stale (and (supertag-field-stale-p
                                             node-id tag-id name)
                                            t)))
                  result)))))
    (nreverse result)))

(defun supertag-api--node-links (node-id)
  "Return typed Link instances touching NODE-ID as plain data."
  (mapcar (lambda (instance)
            (list :link (plist-get instance :definition-id)
                  :name (plist-get instance :label)
                  :direction (plist-get instance :direction)
                  :node (plist-get instance :other-node-id)
                  :title (plist-get instance :other-title)))
          (supertag-link-service-instances node-id)))

(defun supertag-api--node-refs (node-ids)
  "Return NODE-IDS as (:id :title) entries."
  (mapcar (lambda (id)
            (list :id id
                  :title (or (plist-get (supertag-node-get id) :title) "")))
          node-ids))

;;; --- Read ---

(defun supertag-api--parse-query (query)
  "Return QUERY (a string or an S-expression) as a validated query sexp."
  (let ((sexp
         (cond
          ((consp query) query)
          ((stringp query)
           (let ((text (string-trim (supertag-query-expand query))))
             (when (string-empty-p text)
               (error "Query is empty"))
             (condition-case err
                 (car (read-from-string text))
               (error (error "Malformed query %S: %s"
                             query (error-message-string err))))))
          (t (error "Query must be a string or a list, got %S" query)))))
    (supertag-query-validate sexp)))

(defun supertag-api-query (query &optional limit)
  "Run QUERY and return the result as plain data.

QUERY is a query string as written in a query block, for example
\"(and (tag \\\"project\\\") (field \\\"Status\\\" \\\"active\\\"))\", or the
same S-expression.  Dynamic variables such as <%today%> are expanded.

For node queries the result is (:query :count :truncated :nodes), where
each node is (:id :title :tags :file); LIMIT caps the number of nodes.
An aggregate query yields (:query :value), and one with group-by
yields (:query :groups ((:key :value) ...))."
  (when (and limit (not (and (integerp limit) (>= limit 0))))
    (error "Limit must be a non-negative integer, got %S" limit))
  (let* ((sexp (supertag-api--parse-query query))
         (result (supertag-query-evaluate sexp))
         (printed (prin1-to-string sexp)))
    (cond
     ((and (listp result) (cl-every #'stringp result))
      (let* ((total (length result))
             (truncated (and limit (< limit total) t))
             (ids (if truncated (seq-take result limit) result)))
        (list :query printed
              :count total
              :truncated truncated
              :nodes (delq nil (mapcar #'supertag-api--node-summary ids)))))
     ((and (consp result)
           (cl-every (lambda (entry) (and (consp entry) (atom (car entry))))
                     result))
      (list :query printed
            :groups (mapcar (lambda (entry)
                              (list :key (car entry) :value (cdr entry)))
                            result)))
     (t (list :query printed :value result)))))

(defun supertag-api-node (node-id)
  "Return NODE-ID as plain data.

The result carries :id, :title, :content, :file, :hash (the sync
fingerprint of the node's text, to bind agent-written values to), :tags
as (:id :name) entries, :fields (see `supertag-api--node-fields'), :links
(typed Link instances, each :link :name :direction :node :title), and the
document references :references / :referenced-by as (:id :title) entries."
  (let* ((node (supertag-api--node node-id))
         (tag-ids (supertag-query-node-tags node-id)))
    (list :id node-id
          :title (or (plist-get node :title) "")
          :content (or (plist-get node :content) "")
          :file (plist-get node :file)
          :hash (plist-get node :hash)
          :tags (mapcar #'supertag-api--tag-summary tag-ids)
          :fields (supertag-api--node-fields node-id tag-ids)
          :links (supertag-api--node-links node-id)
          :references
          (supertag-api--node-refs
           (mapcar (lambda (relation) (plist-get relation :to))
                   (supertag-query-relations-from node-id :reference)))
          :referenced-by
          (supertag-api--node-refs
           (mapcar (lambda (relation) (plist-get relation :from))
                   (supertag-query-relations-to node-id :reference))))))

(defun supertag-api-schema (tag)
  "Return the schema of TAG (a Tag ID, name or alias) as plain data.

The result carries :id, :name, :aliases, :extends, :description, :fields
(every field including inherited ones, see `supertag-api--field-schema'),
:links (Link Definitions touching the Tag) and :node-count."
  (let* ((tag-id (supertag-api--tag-id tag))
         (record (supertag-tag-get tag-id)))
    (list :id tag-id
          :name (or (plist-get record :name) tag-id)
          :aliases (plist-get record :aliases)
          :extends (plist-get record :extends)
          :description (plist-get record :description)
          :fields (mapcar #'supertag-api--field-schema
                          (supertag-tag-get-all-fields tag-id))
          :links (mapcar #'supertag-api--link-schema
                         (supertag-link-definition-find-by-tag tag-id))
          :node-count (length (supertag-query-node-ids-by-tag tag-id)))))

;;; --- Write ---

(defun supertag-api--field-owner (node-id field)
  "Return the first Tag of NODE-ID that defines FIELD, or signal."
  (let ((tag-ids (supertag-query-node-tags node-id)))
    (or (cl-find-if (lambda (tag-id) (supertag-tag-get-field tag-id field))
                    tag-ids)
        (error "Field %s is not defined on any tag of node %s (%s)"
               field node-id
               (if tag-ids (string-join tag-ids ", ") "no tags")))))

(cl-defun supertag-api-set-field
    (node-id field value &key tag origin model note source-hash)
  "Set FIELD of NODE-ID to VALUE and record where the value came from.

FIELD is a field name or id; TAG names the Tag supplying the schema and
defaults to the first of the node's Tags that defines FIELD.  VALUE is
normalized and validated against the field type; an invalid value signals
and nothing is written.  A literal nil VALUE removes the stored value.

ORIGIN is `:agent' (default) or `:human'; MODEL and NOTE are free strings.
SOURCE-HASH binds an agent value to the node text it was derived from and
defaults to the node's current :hash, which lets `supertag-field-stale-p'
and views flag the value once the text changes.  When an agent overwrites a
human or unprovenanced value, that prior value is retained as `:previous'
provenance so rejecting the agent value can restore it.

Return (:node :tag :field :name :value :previous :changed :provenance)."
  (let* ((node (supertag-api--node node-id))
         (tag-id (if tag
                     (supertag-api--tag-id tag)
                   (supertag-api--field-owner node-id field)))
         (definition (or (supertag-tag-get-field tag-id field)
                         (error "Field %s is not defined on tag %s"
                                field tag-id)))
         (name (plist-get definition :name))
         (field-id (plist-get definition :id))
         (origin (or (supertag-api--keyword origin) :agent))
         (previous-raw (supertag-node-get-global-field
                        node-id field-id supertag-field--missing))
         (previous-exists (not (eq previous-raw supertag-field--missing)))
         (previous (and previous-exists previous-raw))
         (previous-provenance
          (supertag-field-provenance node-id tag-id name)))
    (unless (memq origin supertag-field-provenance-origins)
      (error "Provenance :origin must be one of %S, got %S"
             supertag-field-provenance-origins origin))
    (let* ((provenance
            (supertag-api--plist
             :origin origin
             :model model
             :note note
             :source-hash (or source-hash
                              (and (eq origin :agent)
                                   (plist-get node :hash)))))
           (rollback-present
            (and (eq origin :agent)
                 (or (and (eq (plist-get previous-provenance :origin) :agent)
                          (plist-member previous-provenance :previous))
                     (and previous-exists
                          (not (eq (plist-get previous-provenance :origin)
                                   :agent))))))
           (rollback
            (if (and (eq (plist-get previous-provenance :origin) :agent)
                     (plist-member previous-provenance :previous))
                (plist-get previous-provenance :previous)
              previous))
           (provenance
            (if rollback-present
                (append provenance (list :previous (copy-tree rollback)))
              provenance))
           (stored (supertag-field-set
                    node-id tag-id name value provenance)))
      (list :node node-id
            :tag tag-id
            :field field-id
            :name name
            :value stored
            :previous previous
            :changed (if (null value)
                         previous-exists
                       (or (not previous-exists)
                           (not (equal previous stored))))
            :provenance (supertag-field-provenance node-id tag-id name)))))

(cl-defun supertag-api-link (node-id link target-id &key direction replace)
  "Create typed Link LINK from NODE-ID to TARGET-ID.

LINK is a Link Definition id, name or ontology key.  DIRECTION is
`:forward' (default; NODE-ID is the source) or `:reverse' (NODE-ID is the
target).  Both endpoints are validated against the definition's Tags and
cardinality; when the new link would exceed cardinality the call signals
unless REPLACE is non-nil, in which case the conflicting links are
removed atomically.  An identical existing link is returned unchanged.

Return (:id :link :name :from :to :created)."
  (supertag-api--node node-id)
  (supertag-api--node target-id)
  (let* ((definition (supertag-link-definition-resolve link))
         (definition-id (plist-get definition :id))
         (direction (or (supertag-api--keyword direction) :forward))
         (from-id (if (eq direction :reverse) target-id node-id))
         (to-id (if (eq direction :reverse) node-id target-id)))
    (unless (memq direction '(:forward :reverse))
      (error "Direction must be :forward or :reverse, got %S" direction))
    (let* ((existing (car (supertag-link-find definition-id from-id to-id)))
           (relation
            (cond
             (existing existing)
             (replace
              (supertag-link-create-replacing-conflicts
               definition-id from-id to-id))
             (t
              (let ((conflicts
                     (supertag-link-conflicts definition-id from-id to-id)))
                (when conflicts
                  (error "Link %s from %s to %s conflicts with %d existing link(s); pass :replace t to replace them"
                         definition-id from-id to-id (length conflicts))))
              (supertag-link-create definition-id from-id to-id)))))
      (list :id (plist-get relation :id)
            :link definition-id
            :name (plist-get definition :name)
            :from from-id
            :to to-id
            :created (not existing)))))

(cl-defun supertag-api-add-field
    (tag name type &key options required default description)
  "Define field NAME of TYPE on TAG and return its schema.

TYPE is one of `supertag-field-types' (a keyword or its string form, for
example \"options\").  OPTIONS lists the allowed values of an :options
field and is required for that type.  A global field with the same id
that already exists is reused as-is and only associated with TAG; it must
have the same TYPE.  Signal when TAG already carries NAME.

Return the field schema plus :tag and :created (nil when reused)."
  (let* ((tag-id (supertag-api--tag-id tag))
         (name (supertag-api--string name "field name"))
         (type (supertag-api--keyword type))
         (options (supertag-api--list options))
         (field-id (supertag-sanitize-field-id name))
         (existing (supertag-global-field-get field-id)))
    (unless (memq type supertag-field-types)
      (error "Unknown field type %S; valid types: %s" type
             (mapconcat (lambda (k) (substring (symbol-name k) 1))
                        supertag-field-types ", ")))
    (when (and (eq type :options) (null options))
      (error "An :options field needs a non-empty :options list"))
    (when (supertag-tag-get-field tag-id name)
      (error "Field %s already exists on tag %s" name tag-id))
    (if existing
        (progn
          (unless (eq (plist-get existing :type) type)
            (error "Global field %s already exists with type %s, not %s"
                   field-id (plist-get existing :type) type))
          (supertag-tag-associate-field tag-id field-id)
          (supertag-ops-schema-rebuild-cache))
      (supertag-tag-add-field
       tag-id
       (supertag-api--plist :name name :type type :options options
                            :required (and required t)
                            :default default :description description)))
    (append (list :tag tag-id :created (not existing))
            (supertag-api--field-schema
             (supertag-tag-get-field tag-id name)))))

;;; --- Catalog ---

(defconst supertag-api--catalog
  '((:name "query" :function supertag-api-query :effect :read
     :description "Run a Supertag query and return the matching nodes (id, title, tags, file)."
     :parameters
     ((:name "query" :type :string :required t
       :description "Query expression such as (and (tag \"project\") (field \"Status\" \"active\")); <%today%> and friends are expanded.")
      (:name "limit" :type :integer :required nil
       :description "Maximum number of nodes to return.")))
    (:name "node" :function supertag-api-node :effect :read
     :description "Return one node with its title, content, tags, field values (with provenance), typed links and references."
     :parameters
     ((:name "node_id" :type :string :required t
       :description "The node's id.")))
    (:name "schema" :function supertag-api-schema :effect :read
     :description "Return a Tag's fields (name, type, options) and Link Definitions."
     :parameters
     ((:name "tag" :type :string :required t
       :description "Tag id, name or alias.")))
    (:name "set_field" :function supertag-api-set-field :effect :write
     :description "Set a field value on a node; the value is validated and recorded as an agent-written value unless origin says otherwise."
     :parameters
     ((:name "node_id" :type :string :required t :description "The node's id.")
      (:name "field" :type :string :required t :description "Field name or id.")
      (:name "value" :type :any :required t :description "The value, in the field's type.")
      (:name "tag" :type :string :required nil :description "Tag supplying the schema; defaults to the node's Tag that defines the field.")
      (:name "origin" :type :string :required nil :description "agent (default) or human.")
      (:name "model" :type :string :required nil :description "Model that produced the value.")
      (:name "note" :type :string :required nil :description "Short rationale.")
      (:name "source_hash" :type :string :required nil :description "Node hash the value was derived from; defaults to the current one.")))
    (:name "link" :function supertag-api-link :effect :write
     :description "Create a typed Link between two nodes according to a Link Definition."
     :parameters
     ((:name "node_id" :type :string :required t :description "Source node id (target when direction is reverse).")
      (:name "link" :type :string :required t :description "Link Definition id, name or ontology key.")
      (:name "target_id" :type :string :required t :description "The other node's id.")
      (:name "direction" :type :string :required nil :description "forward (default) or reverse.")
      (:name "replace" :type :boolean :required nil :description "Replace links that would exceed cardinality.")))
    (:name "add_field" :function supertag-api-add-field :effect :write
     :description "Define a new field on a Tag."
     :parameters
     ((:name "tag" :type :string :required t :description "Tag id, name or alias.")
      (:name "name" :type :string :required t :description "Field name.")
      (:name "type" :type :string :required t :description "string, number, integer, boolean, date, timestamp, options, url, email, tag or node-reference.")
      (:name "options" :type :list :required nil :description "Allowed values for an options field.")
      (:name "required" :type :boolean :required nil :description "Whether the field is required.")
      (:name "default" :type :any :required nil :description "Default value.")
      (:name "description" :type :string :required nil :description "Human-readable description."))))
  "Declared API functions: name, Elisp function, effect and parameters.")

(defun supertag-api-catalog ()
  "Return the API catalog as plain data.
Each entry carries :name, :function (the Elisp symbol), :effect (`:read'
or `:write') and :parameters, so a host can register tools and map the
effect onto its own authority model."
  (copy-tree supertag-api--catalog))

;;; --- JSON ---

(defconst supertag-api--boolean-keys
  '(:changed :created :stale :required :truncated :replace)
  "Plist keys whose nil value is JSON false rather than null.")

(defconst supertag-api--list-keys
  '(:nodes :fields :links :tags :references :referenced-by :aliases
    :options :groups :parameters)
  "Plist keys whose nil value is an empty JSON array rather than null.")

(defun supertag-api--json-value (value &optional kind)
  "Return VALUE converted for `json-serialize'.
KIND is `:boolean' or `:list' when VALUE sits under a key of that kind,
which decides what nil becomes."
  (cond
   ((null value) (pcase kind (:boolean :false) (:list []) (_ :null)))
   ((eq value t) t)
   ((memq value '(:false :null)) value)
   ((stringp value) value)
   ((numberp value) value)
   ((keywordp value) (substring (symbol-name value) 1))
   ((symbolp value) (symbol-name value))
   ((hash-table-p value)
    (let ((table (make-hash-table :test #'equal)))
      (maphash (lambda (key item)
                 (puthash (format "%s" key)
                          (supertag-api--json-value item)
                          table))
               value)
      table))
   ((vectorp value)
    (vconcat (mapcar #'supertag-api--json-value value)))
   ((and (consp value) (keywordp (car value)))
    (let ((rest value) out)
      (while rest
        (let ((key (pop rest))
              (item (pop rest)))
          (push key out)
          (push (supertag-api--json-value
                 item
                 (cond ((memq key supertag-api--boolean-keys) :boolean)
                       ((memq key supertag-api--list-keys) :list)))
                out)))
      (nreverse out)))
   ((proper-list-p value)
    (vconcat (mapcar #'supertag-api--json-value value)))
   (t (format "%S" value))))

(defun supertag-api-json (value)
  "Return VALUE, a result of this API, as a JSON string.
Plists become objects, lists and vectors arrays, keywords strings, t true;
nil is null except under boolean keys (false) and list keys ([])."
  (json-serialize (supertag-api--json-value value)))

(provide 'supertag-api)
;;; supertag-api.el ends here
