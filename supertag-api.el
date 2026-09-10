;;; supertag-api.el --- Plain-data API for agents and bridges -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; The callee surface Supertag offers to an external agent host (for example
;; a superchat bridge plugin).  Every function here takes and returns plain
;; data — strings, numbers, t/nil, keywords, and plists with keyword keys —
;; so a host can register each one as an LLM tool without learning
;; Supertag's internals, and `supertag-api-json' renders any result as JSON.
;;
;; Three read-only functions:
;;   `supertag-api-query'   — run a query, return node summaries
;;   `supertag-api-node'    — one node with properties, named links and references
;;   `supertag-api-schema'  — one Tag's metadata and node count
;; `supertag-api-catalog' declares their read effects and parameters.
;; Document links are projections of the Org text.


;; Commands: none; Lisp entrypoints: supertag-api-query, supertag-api-node, supertag-api-schema,
;; supertag-api-catalog, supertag-api-json.
;; Dependencies: cl-lib, subr-x, supertag-core-store, supertag-node, supertag-tag,
;; supertag-query, supertag-link.
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-tag)
(require 'supertag-query)
(require 'supertag-link)

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

(defun supertag-api--node-links (node-id)
  "Return named Org links touching NODE-ID as plain data."
  (mapcar (lambda (instance)
            (list :relation-id (plist-get instance :relation-id)
                  :label (plist-get instance :label)
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
as (:id :name) entries, :properties (projected Org property plist), :links
(named Org links, each :relation-id :label :direction :node :title), and the
document references :references / :referenced-by as (:id :title) entries."
  (let* ((node (supertag-api--node node-id))
         (tag-ids (supertag-query-node-tags node-id)))
    (list :id node-id
          :title (or (plist-get node :title) "")
          :content (or (plist-get node :content) "")
          :file (plist-get node :file)
          :hash (plist-get node :hash)
          :tags (mapcar #'supertag-api--tag-summary tag-ids)
          :properties (copy-tree (plist-get node :properties))
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

The result carries :id, :name, :aliases, :description and :node-count."
  (let* ((tag-id (supertag-api--tag-id tag))
         (record (supertag-tag-get tag-id)))
    (list :id tag-id
          :name (or (plist-get record :name) tag-id)
          :aliases (plist-get record :aliases)
          :description (plist-get record :description)
          :node-count (length (supertag-query-node-ids-by-tag tag-id)))))

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
     :description "Return one node with its title, content, tags, Org properties, named Org links and references."
     :parameters
     ((:name "node_id" :type :string :required t
       :description "The node's id.")))
    (:name "schema" :function supertag-api-schema :effect :read
     :description "Return a Tag's metadata and node count."
     :parameters
     ((:name "tag" :type :string :required t
       :description "Tag id, name or alias.")))


    )
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
  '(:nodes :links :tags :references :referenced-by :aliases
    :groups :parameters)
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
