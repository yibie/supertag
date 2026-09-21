;;; supertag-query.el --- Query and document projection reads -*- lexical-binding: t; -*-
;;; Commentary:
;; Commands: supertag-add-query-block, supertag-query-build,
;; supertag-query-describe-syntax. Lisp entry points include
;; supertag-note-query-read-node, supertag-query-node-detail,
;; supertag-query-node-ids and supertag-query-evaluate.
;; Dependencies: cl-lib, subr-x, supertag-core-store, org, org-table.
;; Formula grammar, evaluation, rollups and dataset/entity read adapters live here.
;; Node, Tag and Relation ordinary providers load on demand; Store owns physical indexes;
;; Text/date/file projection scans are local reads; Tag indexes remain derived.
;; Link formatting and Tag input providers also load on demand.
;; The Babel executor is defined here; ob-supertag-query-block.el is the
;; separate loader Org requires for `(supertag-query-block . t)'.
;; A projection is not disk/live equality.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-store)
(require 'org)
(require 'org-table)

;; Ordinary providers, never eager business dependencies.
(autoload 'supertag-tag-get "supertag-tag")
(declare-function supertag-tag-get "supertag-tag" (id))
(autoload 'supertag-tag-resolve-occurrence "supertag-tag")
(declare-function supertag-tag-resolve-occurrence "supertag-tag" (token &optional tag-ids))
(autoload 'supertag-find-tag-descendants "supertag-tag")
(declare-function supertag-find-tag-descendants "supertag-tag" (tag-name))
(autoload 'supertag-index-find-node-ids-by-tags "supertag-core-store")
(declare-function supertag-index-find-node-ids-by-tags "supertag-core-store" (tag-ids))
(autoload 'supertag-node-get "supertag-node")
(declare-function supertag-node-get "supertag-node" (id))
(autoload 'supertag--ensure-plist "supertag-tag")
(declare-function supertag--ensure-plist "supertag-tag" (data))
(autoload 'supertag-tag-display-name "supertag-tag")
(declare-function supertag-tag-display-name "supertag-tag" (tag-id))
(autoload 'supertag-relation-find-by-from "supertag-link")
(declare-function supertag-relation-find-by-from "supertag-link" (from-id &optional type kind))
(autoload 'supertag-relation-find-by-to "supertag-link")
(declare-function supertag-relation-find-by-to "supertag-link" (to-id &optional type kind))
(autoload 'supertag-relation-named-document-link-p "supertag-link")
(declare-function supertag-relation-named-document-link-p "supertag-link" (relation &optional relation-name))
(autoload 'supertag-relation-get "supertag-link")
(declare-function supertag-relation-get "supertag-link" (id))

(autoload 'supertag-node-format-link "supertag-link")
(declare-function supertag-node-format-link "supertag-link" (id &optional title link-type))
(autoload 'supertag-view-api-list-tag-ids "supertag-tag")
(declare-function supertag-view-api-list-tag-ids "supertag-tag" ())
(autoload 'supertag-ui-read-tag "supertag-tag")
(declare-function supertag-ui-read-tag "supertag-tag" (prompt &optional tag-ids allow-new allow-empty allow-namespace))

;;; Isolated document projection reads

(defun supertag-note-query-normalize-property-key (name)
  "Return non-empty string NAME as an uppercase Org property keyword."
  (unless (and (stringp name) (> (length name) 0))
    (error "Org property name must be a non-empty string: %S" name))
  (intern (concat ":" (upcase name))))

(defun supertag-note-query-read-node (node-id)
  "Read NODE-ID from the initialized current Store, or return nil if absent.
Return (:id ID :node NODE :properties ENTRIES :property-count N).
ENTRIES have :key, :name and unconverted :value, stably ordered by name.
Empty values remain present; missing properties do not acquire defaults.
Returned strings, conses, vectors, boolean vectors and hash tables are detached
from Store. Flat cons spines are copied without recursion proportional to length."
  (unless (and (stringp node-id) (> (length node-id) 0))
    (error "Node ID must be a non-empty string: %S" node-id))
  (unless (and (hash-table-p supertag--store)
               (cl-every (lambda (collection)
                           (hash-table-p (gethash collection supertag--store)))
                         supertag--store-collections))
    (error "The current library Store must be initialized before reading"))
  (cl-labels ((detach (value)
                (cond
                 ((consp value)
                  (let* ((head (list nil)) (tail head))
                    ;; Recurse into elements, not along a flat list's spine.
                    (while (consp value)
                      (setcdr tail (list (detach (car value))))
                      (setq tail (cdr tail)
                            value (cdr value)))
                    (setcdr tail (detach value))
                    (cdr head)))
                 ((stringp value)
                  (let ((copy (copy-sequence value)) (position 0))
                    (while (< position (length value))
                      (let ((end (next-property-change position value (length value))))
                        (set-text-properties position end
                                             (detach (text-properties-at position value))
                                             copy)
                        (setq position end)))
                    copy))
                 ((bool-vector-p value) (copy-sequence value))
                 ((vectorp value) (apply #'vector (mapcar #'detach value)))
                 ((hash-table-p value)
                  (let ((copy (copy-hash-table value)))
                    (clrhash copy)
                    (maphash (lambda (key item)
                               (puthash (detach key) (detach item) copy)) value)
                    copy))
                 (t value))))
    (let ((node (detach (supertag-store-get-entity :nodes node-id))) entries)
      (when node
        (cl-loop for (raw-key value) on (plist-get node :properties) by #'cddr
                 for name = (cond ((keywordp raw-key)
                                   (substring (symbol-name raw-key) 1))
                                  ((stringp raw-key) raw-key))
                 when name
                 do (let ((key (supertag-note-query-normalize-property-key name)))
                      (push (list :key key :name (substring (symbol-name key) 1)
                                  :value value) entries)))
        (setq entries (cl-stable-sort (nreverse entries)
                                     (lambda (a b) (string< (plist-get a :name)
                                                            (plist-get b :name)))))
        (list :id (detach node-id) :node node :properties entries
              :property-count (length entries))))))

;;; Concrete queries and named relations

(defun supertag-query-link--relation-name (reference)
  "Normalize REFERENCE to a nonempty named Org link relation string."
  (let ((name (if (symbolp reference) (symbol-name reference) reference)))
    (unless (and (stringp name) (not (string-empty-p name)))
      (error "Named Org link requires a nonempty relation name: %S" reference))
    name))

(defun supertag-query-link--parse-binary (type args recursive-parser)
  "Parse a named Org Link operator with TYPE and two ARGS.
RECURSIVE-PARSER parses the nested query."
  (unless (= (length args) 2)
    (error "'%s' expects a relation name and one nested query, got %S"
           type args))
  (list :type type :reference (supertag-query-link--relation-name (car args))
        :child (funcall recursive-parser (cadr args))))

(defun supertag-query-link--parse-unary (type args _recursive-parser)
  "Parse a named Org Link operator with TYPE and one relation name in ARGS."
  (unless (= (length args) 1)
    (error "'%s' expects exactly one relation name, got %S" type args))
  (list :type type :reference (supertag-query-link--relation-name (car args))))

(defun supertag-query-link--unique (ids)
  "Return IDS without nil values or duplicates."
  (cl-delete-duplicates (delq nil ids) :test #'equal))

(defun supertag-query-link--execute-forward (ast recursive-executor)
  "Find sources of named Org links to AST's nested query targets."
  (let ((name (plist-get ast :reference)) result)
    (dolist (target-id (funcall recursive-executor (plist-get ast :child)))
      (setq result
            (nconc (mapcar (lambda (relation) (plist-get relation :from))
                           (supertag-query-named-links-to target-id name)) result)))
    (supertag-query-link--unique result)))

(defun supertag-query-link--execute-reverse (ast recursive-executor)
  "Find targets of named Org links from AST's nested query sources."
  (let ((name (plist-get ast :reference)) result)
    (dolist (source-id (funcall recursive-executor (plist-get ast :child)))
      (setq result
            (nconc (mapcar (lambda (relation) (plist-get relation :to))
                           (supertag-query-named-links-from source-id name)) result)))
    (supertag-query-link--unique result)))

(defun supertag-query-link--execute-has-out (ast _recursive-executor)
  "Return nodes with outgoing named Org links described by AST."
  (supertag-query-link--unique
   (mapcar (lambda (relation) (plist-get relation :from))
           (supertag-query-relations
            (lambda (relation)
              (supertag-relation-named-document-link-p
               relation (plist-get ast :reference)))))))

(defun supertag-query-link--execute-has-in (ast _recursive-executor)
  "Return nodes with incoming named Org links described by AST."
  (supertag-query-link--unique
   (mapcar (lambda (relation) (plist-get relation :to))
           (supertag-query-relations
            (lambda (relation)
              (supertag-relation-named-document-link-p
               relation (plist-get ast :reference)))))))

(defun supertag-query-normalize-property-key (name)
  "Return string or keyword NAME as an uppercase Org property keyword."
  (supertag-note-query-normalize-property-key
   (if (keywordp name) (substring (symbol-name name) 1) name)))

(defun supertag-query-node (node-id)
  "Return the Document Projection node for NODE-ID, or nil."
  (supertag-node-get node-id))

(defun supertag-query-tag-descriptors ()
  "Return sorted Semantic Tag descriptors.
Each descriptor contains :id, :name, and :display."
  (let (result)
    (maphash
     (lambda (tag-id tag)
       (let ((tag (supertag--ensure-plist tag)))
         (push (list :id tag-id
                     :name (or (plist-get tag :name) tag-id)
                     :display (supertag-tag-display-name tag-id))
               result)))
     (supertag-store-get-collection :tags))
    (sort result
          (lambda (left right)
            (let ((left-display (plist-get left :display))
                  (right-display (plist-get right :display)))
              (if (equal left-display right-display)
                  (string< (plist-get left :id) (plist-get right :id))
                (string< left-display right-display)))))))

(defun supertag-query-tags ()
  "Return Semantic Tags as (id . tag-plist) pairs."
  (let (result)
    (maphash
     (lambda (id tag)
       (push (cons id (supertag--ensure-plist tag)) result))
     (supertag-store-get-collection :tags))
    result))

(defun supertag-query-node-ids-by-tag (tag-name &optional include-descendants)
  "Return node IDs tagged with TAG-NAME.
When INCLUDE-DESCENDANTS is non-nil, include transitive `:extends' descendants."
  (supertag-index-get-nodes-by-tag tag-name include-descendants))

(defun supertag-query-automations (&optional filter)
  "Return automation rules, optionally filtered by FILTER.
FILTER is a function receiving an automation plist and returning non-nil."
  (let (result)
    (maphash
     (lambda (_id rule)
       (when (or (null filter) (funcall filter rule))
         (push rule result)))
     (supertag-store-get-collection :automations))
    (sort result
          (lambda (a b)
            (string< (plist-get a :name) (plist-get b :name))))))

(defun supertag-query-tag-occurrences ()
  "Return sorted unique Org Tag Occurrence tokens from projected nodes."
  (let (occurrences)
    (maphash
     (lambda (_node-id node-data)
       (dolist (token (plist-get node-data :tag-occurrences))
         (when (stringp token)
           (push token occurrences))))
     (supertag-store-get-collection :nodes))
    (sort (delete-dups occurrences) #'string<)))

(defun supertag-query-relations (&optional filter)
  "Return all relations, optionally filtered by FILTER predicate."
  (let (result)
    (maphash
     (lambda (_id relation)
       (when (or (null filter) (funcall filter relation))
         (push relation result)))
     (supertag-store-get-collection :relations))
    result))

(defun supertag-query-property-value (node-id name)
  "Read NODE-ID's Org property NAME with case-insensitive key matching."
  (plist-get (plist-get (supertag-node-get node-id) :properties)
             (supertag-query-normalize-property-key name)))

(defun supertag-query-relations-from (entity-id &optional type kind)
  "Return relations from ENTITY-ID, optionally filtered by TYPE and KIND."
  (supertag-relation-find-by-from entity-id type kind))

(defun supertag-query-relations-to (entity-id &optional type kind)
  "Return relations to ENTITY-ID, optionally filtered by TYPE and KIND."
  (supertag-relation-find-by-to entity-id type kind))

(defun supertag-query-named-links-from (node-id &optional relation-name)
  "Return Org named links from NODE-ID, optionally matching RELATION-NAME."
  (cl-remove-if-not
   (lambda (relation)
     (supertag-relation-named-document-link-p relation relation-name))
   (supertag-query-relations-from node-id :reference :document-link)))

(defun supertag-query-named-links-to (node-id &optional relation-name)
  "Return Org named links to NODE-ID, optionally matching RELATION-NAME."
  (cl-remove-if-not
   (lambda (relation)
     (supertag-relation-named-document-link-p relation relation-name))
   (supertag-query-relations-to node-id :reference :document-link)))

(defun supertag-query-ordinary-references-from (node-id)
  "Return legacy and ordinary references from NODE-ID, excluding named Org links."
  (cl-remove-if
   #'supertag-relation-named-document-link-p
   (supertag-query-relations-from node-id :reference)))

(defun supertag-query-ordinary-references-to (node-id)
  "Return legacy and ordinary references to NODE-ID, excluding named Org links."
  (cl-remove-if
   #'supertag-relation-named-document-link-p
   (supertag-query-relations-to node-id :reference)))

(defun supertag-query-relations-among (entity-ids &optional type kind)
  "Return relations whose endpoints are both in ENTITY-IDS.
TYPE and KIND optionally filter the induced relation set."
  (let ((id-set (make-hash-table :test 'equal))
        result)
    (dolist (entity-id entity-ids)
      (puthash entity-id t id-set))
    (maphash
     (lambda (entity-id _present)
       (dolist (relation (supertag-query-relations-from entity-id type kind))
         (when (gethash (plist-get relation :to) id-set)
           (push relation result))))
     id-set)
    (nreverse result)))

(defun supertag-query-node-tags (node-id)
  "Return the Semantic Tag IDs attached to NODE-ID."
  (when-let* ((node (supertag-query-node node-id)))
    (cl-remove-if-not #'stringp (plist-get node :tags))))

(defun supertag-query-node-properties (node-id)
  "Return NODE-ID's projected Org properties in stable name order.
Each entry contains :key, :name, and the projected :value.  Empty
properties remain present; properties absent from the projection do not
produce entries."
  (plist-get (supertag-note-query-read-node node-id) :properties))

(defun supertag-query-node-detail (node-id)
  "Return composed node detail, with node/property reads owned by Q."
  (when-let* ((detail (supertag-note-query-read-node node-id)))
    (let ((refs-to (mapcar (lambda (relation) (plist-get relation :to))
                          (supertag-query-ordinary-references-from node-id)))
          (refs-from (mapcar (lambda (relation) (plist-get relation :from))
                            (supertag-query-ordinary-references-to node-id))))
      (append detail
              (list :tags (cl-remove-if-not
                           #'stringp (plist-get (plist-get detail :node) :tags))
                    :refs-to refs-to :refs-from refs-from
                    :ref-count (+ (length refs-to) (length refs-from)))))))

(defun supertag-query (collection &optional filter)
  "Query data from a COLLECTION in the central store.
COLLECTION is the path to the collection (e.g., :nodes, :tags, :relations).
FILTER is an optional function that receives (id . data) pairs and returns t if the item should be included.
Returns a list of (id . data) pairs for matching items."
  (let* ((path (if (listp collection) collection (list collection)))
         (key (and (= (length path) 1) (car path))))
    (if key
        (let ((bucket (supertag-store-get-collection key))
              results)
          (maphash
           (lambda (id value)
             (when (or (null filter) (funcall filter id value))
               (push (cons id value) results)))
           bucket)
          (nreverse results))
      ;; Path is deeper than one segment; use store API for nested access
      (let ((data (supertag-store-get-entity (car path) (cadr path))))
        (if (not (hash-table-p data))
            '()
          (let (results)
            (maphash
             (lambda (id value)
               (when (or (null filter) (funcall filter id value))
                 (push (cons id value) results)))
             data)
            (nreverse results)))))))

(defun supertag-query-nodes (&optional filter)
  "Query all nodes in the store with an optional filter.
FILTER is an optional function that receives (id node-data) and returns t if the node should be included.
Returns a list of (id . node-data) pairs."
  (supertag-query '(:nodes) filter))

;;; Query language, execution and aggregation

(defun supertag-query-node-ids (query-sexp)
  "Execute QUERY-SEXP and return matching node IDs.
QUERY-SEXP is an S-expression like (and (tag \"foo\") (term \"bar\")).
sort-by modifiers are applied in order, so the returned IDs are sorted
when the query carries sort-by.  Aggregate queries must use
`supertag-query-evaluate' instead and signal here.
Returns a list of node IDs matching the query."
  (let* ((ast (supertag-query--parse-sexp query-sexp))
         (modifiers (supertag-query--ast-modifiers ast))
         (node-ids (supertag-query--execute-ast ast)))
    (when (cl-some
           (lambda (modifier)
             (memq (plist-get modifier :type)
                   '(sum count avg min max first last unique-count concat
                         group-by)))
           modifiers)
      (error "Aggregate queries use `supertag-query-evaluate', not `supertag-query-node-ids'"))
    (supertag-query--apply-modifiers node-ids modifiers)))

(defun supertag-query-evaluate (query-sexp)
  "Execute QUERY-SEXP and return the full result.
Without aggregate modifiers this is the matching node-ID list; with an
aggregate it is a scalar, or an alist of (group-key . value) when the
query also carries group-by."
  (let* ((ast (supertag-query--parse-sexp query-sexp))
         (node-ids (supertag-query--execute-ast ast)))
    (supertag-query--apply-modifiers
     node-ids (supertag-query--ast-modifiers ast))))

(defun supertag-query-sexp (query-sexp)
  "Compatibility entry point for `supertag-query-node-ids'."
  (supertag-query-node-ids query-sexp))

(defun supertag-query-properties (query-sexp)
  "Return property keys referenced by QUERY-SEXP, for table headers."
  (supertag-query--get-properties-from-ast
   (supertag-query--parse-sexp query-sexp)))

(defun supertag-query-validate (query-sexp)
  "Validate QUERY-SEXP with the engine's parser, returning it.
Signals the same error the executor would raise on malformed input."
  (supertag-query--parse-sexp query-sexp)
  query-sexp)

(defun supertag-query-date-valid-p (date-str)
  "Return non-nil when DATE-STR is accepted by the engine's date resolver."
  (and (supertag-query--resolve-date-string date-str) t))

(defun supertag-query-expand (query-string)
  "Expand dynamic variables in QUERY-STRING.
`<%today%>', `<%yesterday%>' and `<%tomorrow%>' become the bare day
symbols today/yesterday/tomorrow, which the date resolver turns into the
local midnight of that day.  Run this before reading the string as a sexp."
  (replace-regexp-in-string
   "<%today%>\\|<%yesterday%>\\|<%tomorrow%>"
   (lambda (variable)
     (substring variable 2 -2))
   query-string t t))

(defun supertag-query--date-arg (arg)
  "Normalize a date argument ARG to a string.
Symbols (e.g. from dynamic variables like <%today%>) become their name."
  (if (stringp arg) arg (symbol-name arg)))

(defun supertag-query--modifier-ast-p (ast)
  "Return non-nil when AST is a result modifier (sort-by/aggregate)."
  (memq (plist-get ast :type)
        '(sort-by sum count avg min max first last unique-count concat group-by)))

(defun supertag-query--parse-sexp (query-sexp)
  "Parse a query S-expression into an AST.
Built-in operators take precedence over property-name shorthand.
Unreserved symbols with one string argument desugar to `property'.
This function is compatible with the old query syntax."
  (let ((op (car query-sexp))
        (args (cdr query-sexp)))
    (cond
     ((eq op 'and)
      (let* ((children (mapcar #'supertag-query--parse-sexp args))
             (modifiers (cl-remove-if-not #'supertag-query--modifier-ast-p
                                          children))
             (filters (cl-remove-if #'supertag-query--modifier-ast-p
                                    children)))
        `(:type and :children ,filters :modifiers ,modifiers)))
     ((eq op 'or)
      (let ((children (mapcar #'supertag-query--parse-sexp args)))
        (when (cl-some #'supertag-query--modifier-ast-p children)
          (error "Result modifiers like sort-by/aggregates only belong inside 'and'"))
        `(:type or :children ,children)))
     ((eq op 'not)
      (unless (>= (length args) 1)
        (error "'not' operator expects at least one argument, but got %S" args))
      `(:type not :children ,(mapcar #'supertag-query--parse-sexp args)))
     ((eq op 'tag)
      (unless (= (length args) 1)
        (error "'tag' operator expects exactly one argument, but got %S" args))
      `(:type tag :value ,(if (stringp (car args)) (car args) (symbol-name (car args)))))
     ((eq op 'sort-by)
      (unless (<= 1 (length args) 2)
        (error "'sort-by' operator expects a property key and an optional asc/desc order, but got %S" args))
      (let* ((key (if (stringp (car args)) (car args) (symbol-name (car args))))
             (order-arg (and (cdr args) (cadr args)))
             (order (cond
                     ((null order-arg) 'desc)
                     ((eq order-arg 'asc) 'asc)
                     ((eq order-arg 'desc) 'desc)
                     ((and (stringp order-arg) (string= order-arg "asc")) 'asc)
                     ((and (stringp order-arg) (string= order-arg "desc")) 'desc)
                     (t (error "Invalid sort-by order: %S" order-arg)))))
        `(:type sort-by :key ,key :order ,order)))
     ((memq op '(sum avg min max first last unique-count concat))
      (unless (= (length args) 1)
        (error "'%s' operator expects exactly one property key, but got %S" op args))
      `(:type ,op :key ,(if (stringp (car args)) (car args)
                          (symbol-name (car args)))))
     ((eq op 'count)
      (unless (null args)
        (error "'count' operator takes no arguments, but got %S" args))
      '(:type count :key nil))
     ((eq op 'group-by)
      (unless (= (length args) 1)
        (error "'group-by' operator expects exactly one property key, but got %S" args))
      `(:type group-by :key ,(if (stringp (car args)) (car args)
                                 (symbol-name (car args)))))
     ((memq op '(todo task))
      ;; Zero or more states; zero states match no node (identity of OR).
      `(:type task
              :values ,(mapcar (lambda (a)
                                 (if (stringp a) a (symbol-name a)))
                               args)))
     ((eq op 'priority)
      ;; Zero or more priorities; zero priorities match no node.
      `(:type priority
              :values ,(mapcar (lambda (a)
                                 (if (stringp a) a (symbol-name a)))
                               args)))

     ;; `field' is a permanent input alias for `property': existing query
     ;; blocks in users' Org files keep working unchanged.  It is not offered
     ;; anywhere in the UI, docs or prompts, which all say `property'.
     ((memq op '(property field))
      (unless (and (= (length args) 2)
                   (stringp (car args))
                   (stringp (cadr args)))
        (error "'property' operator expects exactly two string arguments, but got %S"
               args))
      `(:type property
              :key ,(supertag-query-normalize-property-key (car args))
              :value ,(cadr args)))
     ((eq op 'after)
      (unless (= (length args) 1)
        (error "'after' operator expects one date string argument, but got %S" args))
      `(:type after :date ,(supertag-query--date-arg (car args))))
     ((eq op 'before)
      (unless (= (length args) 1)
        (error "'before' operator expects one date string argument, but got %S" args))
      `(:type before :date ,(supertag-query--date-arg (car args))))
     ((eq op 'between)
      (unless (= (length args) 2)
        (error "'between' operator expects two date string arguments, but got %S" args))
      `(:type between :start-date ,(supertag-query--date-arg (car args))
              :end-date ,(supertag-query--date-arg (cadr args))))
     ((eq op 'term)
      (unless (= (length args) 1)
        (error "'term' operator expects exactly one argument, but got %S" args))
      `(:type term :value ,(if (stringp (car args)) (car args) (symbol-name (car args)))))
     ((eq op 'link)
      (supertag-query-link--parse-binary
       'link args #'supertag-query--parse-sexp))
     ((eq op 'exists-link)
      (supertag-query-link--parse-binary
       'link args #'supertag-query--parse-sexp))
     ((eq op 'reverse-link)
      (supertag-query-link--parse-binary
       'reverse-link args #'supertag-query--parse-sexp))
     ((eq op 'has-link)
      (supertag-query-link--parse-unary
       'has-link args #'supertag-query--parse-sexp))
     ((eq op 'has-reverse-link)
      (supertag-query-link--parse-unary
       'has-reverse-link args #'supertag-query--parse-sexp))
     ;; Date sugar below: these desugar to `after'/`between' at parse time,
     ;; so the executor needs no knowledge of them. All match on :created-at
     ;; (the same timestamp the other date operators use).
     ((eq op 'recent-days)
      (let ((n (car args)))
        (when (and (stringp n) (string-match-p "\\`[0-9]+\\'" n))
          (setq n (string-to-number n)))
        (unless (and (= (length args) 1) (integerp n) (> n 0))
          (error "'recent-days' operator expects one positive integer, but got %S" args))
        `(:type after :date ,(format "-%dd" n))))
     ((eq op 'in-month)
      (unless (and (= (length args) 1) (stringp (car args))
                   (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)\\'" (car args)))
        (error "'in-month' operator expects one \"YYYY-MM\" string, but got %S" args))
      (let* ((year (string-to-number (match-string 1 (car args))))
             (month (string-to-number (match-string 2 (car args)))))
        (unless (<= 1 month 12)
          (error "'in-month': month out of range in %S" (car args)))
        `(:type between
                :start-date ,(format "%04d-%02d-01" year month)
                :end-date ,(if (= month 12)
                               (format "%04d-01-01" (1+ year))
                             (format "%04d-%02d-01" year (1+ month))))))
     ((eq op 'in-year)
      (let ((arg (car args)))
        (when (and (stringp arg) (string-match-p "\\`[0-9]\\{4\\}\\'" arg))
          (setq arg (string-to-number arg)))
        (unless (and (= (length args) 1) (integerp arg) (> arg 0))
          (error "'in-year' operator expects one \"YYYY\" argument, but got %S" args))
        `(:type between
                :start-date ,(format "%04d-01-01" arg)
                :end-date ,(format "%04d-01-01" (1+ arg)))))
     ;; Keep this last: built-ins (including malformed ones) never fall
     ;; through to a same-named Org property.  Explicit `property' is the
     ;; escape hatch for reserved names.
     ((and (symbolp op) op (not (keywordp op)))
      (unless (and (= (length args) 1) (stringp (car args)))
        (error "Property shorthand '%s' expects exactly one string argument, but got %S"
               op args))
      (supertag-query--parse-sexp
       (list 'property (symbol-name op) (car args))))
     (t
      (error "Invalid query operator: %S" op)))))

(defun supertag-query--execute-ast (ast)
  "Execute a query AST and return a list of matching node IDs.
This uses indexes for O(1) lookups instead of O(n) table scans."
  (let ((ast-type (plist-get ast :type)))
    (cond
     ((eq ast-type 'and)
      (let ((child-results (mapcar #'supertag-query--execute-ast (plist-get ast :children)))
            (all-node-ids (supertag-query--get-all-node-ids)))
        (cl-reduce (lambda (result next-list)
                     (cl-intersection result next-list :test #'equal))
                   child-results
                   :initial-value all-node-ids)))

     ((eq ast-type 'or)
      (let ((child-results (mapcar #'supertag-query--execute-ast (plist-get ast :children))))
        (cl-reduce #'cl-union child-results :initial-value '())))

     ((eq ast-type 'not)
      ;; (not a b ...) excludes the union of the children, i.e.
      ;; (not (or a b ...)).  A single child keeps the old behavior.
      (let ((all-node-ids (supertag-query--get-all-node-ids))
            (nodes-to-exclude
             (cl-reduce #'cl-union
                        (mapcar #'supertag-query--execute-ast
                                (plist-get ast :children))
                        :initial-value '())))
        (cl-set-difference (or all-node-ids '()) nodes-to-exclude :test #'equal)))

     ;; Fast index-based lookups below
     ((eq ast-type 'tag)
      (let ((tag-value (plist-get ast :value)))
        (let ((result (supertag-index-get-nodes-by-tag tag-value)))
          result)))

     ((eq ast-type 'task)
      ;; Case-sensitive match against the projected :todo state; a node
      ;; without a todo state never matches.
      (let ((states (plist-get ast :values))
            matches)
        (dolist (pair (supertag-query-nodes (lambda (_id data) data)))
          (let ((todo (plist-get (cdr pair) :todo)))
            (when (and todo (member todo states))
              (push (car pair) matches))))
        matches))

     ((eq ast-type 'priority)
      ;; Case-insensitive match against the projected :priority cookie;
      ;; the projection stores "#A" (with the leading #) while queries
      ;; spell it "A", so both sides strip the # before comparing.
      (let ((states
             (mapcar (lambda (state)
                       (upcase (replace-regexp-in-string "^#" "" state)))
                     (plist-get ast :values)))
            matches)
        (dolist (pair (supertag-query-nodes (lambda (_id data) data)))
          (let ((priority (plist-get (cdr pair) :priority)))
            (when (and priority
                       (member (upcase (replace-regexp-in-string
                                        "^#" "" priority))
                               states))
              (push (car pair) matches))))
        matches))


     ((eq ast-type 'property)
      (let ((key (plist-get ast :key))
            (value (plist-get ast :value))
            matches)
        (dolist (pair (supertag-query-nodes (lambda (_id data) data)))
          (let ((properties (plist-get (cdr pair) :properties)))
            (when (and (listp properties)
                       (plist-member properties key)
                       (equal (plist-get properties key) value))
              (push (car pair) matches))))
        (nreverse matches)))

     ((eq ast-type 'after)
      (let ((query-time (supertag-query--resolve-date-string (plist-get ast :date))))
        (unless query-time (error "Invalid date format for 'after': %s" (plist-get ast :date)))
        (supertag-index-get-nodes-by-date-range query-time nil)))

     ((eq ast-type 'before)
      (let ((query-time (supertag-query--resolve-date-string (plist-get ast :date))))
        (unless query-time (error "Invalid date format for 'before': %s" (plist-get ast :date)))
        (supertag-index-get-nodes-by-date-range nil query-time)))

     ((eq ast-type 'between)
      (let ((start-time (supertag-query--resolve-date-string (plist-get ast :start-date)))
            (end-time (supertag-query--resolve-date-string (plist-get ast :end-date))))
        (unless start-time (error "Invalid start date for 'between': %s" (plist-get ast :start-date)))
        (unless end-time (error "Invalid end date for 'between': %s" (plist-get ast :end-date)))
        (supertag-index-get-nodes-by-date-range start-time end-time)))

     ((eq ast-type 'term)
      (supertag-index-get-nodes-by-word (plist-get ast :value)))

     ((eq ast-type 'link)
      (supertag-query-link--execute-forward
       ast #'supertag-query--execute-ast))

     ((eq ast-type 'reverse-link)
      (supertag-query-link--execute-reverse
       ast #'supertag-query--execute-ast))

     ((eq ast-type 'has-link)
      (supertag-query-link--execute-has-out
       ast #'supertag-query--execute-ast))

     ((eq ast-type 'has-reverse-link)
      (supertag-query-link--execute-has-in
       ast #'supertag-query--execute-ast))

     ;; A bare modifier query (e.g. (sort-by "title" asc)) means
     ;; "all nodes, modified": modifiers are applied by the public entry
     ;; point after execution.
     ((eq ast-type 'sort-by)
      (supertag-query--get-all-node-ids))

     (t '()))))

(defun supertag-query--get-all-node-ids ()
  "Get all node IDs in the system."
  (let (all-ids)
    (maphash (lambda (id _data) (push id all-ids))
             (supertag-store-get-collection :nodes))
    all-ids))

(defun supertag-query--ast-modifiers (ast)
  "Return the result modifiers carried by AST, in order.
Modifiers live in an 'and' node's :modifiers slot; a bare modifier
query is itself a modifier."
  (if (supertag-query--modifier-ast-p ast)
      (list ast)
    (or (plist-get ast :modifiers) '())))

(defun supertag-query--numeric (value)
  "Return VALUE as a number if it is one, or a numeric-looking string. Else nil."
  (cond
   ((numberp value) value)
   ((and (stringp value)
         (string-match-p "\\`[ \t]*-?[0-9]+\\(\\.[0-9]+\\)?[ \t]*\\'" value))
    (string-to-number value))
   (t nil)))

(defun supertag-query--value< (a b)
  "Return non-nil if sort value A sorts before sort value B.
Numeric comparison when both parse as numbers; Emacs-time comparison when
both look like Emacs time values (as used by :created-at/:modified-at);
string comparison otherwise."
  (let ((na (supertag-query--numeric a))
        (nb (supertag-query--numeric b)))
    (cond
     ((and na nb) (< na nb))
     ((and (consp a) (consp b) (integerp (car a)) (integerp (car b)))
      (time-less-p a b))
     (t (string< (format "%s" a) (format "%s" b))))))

(defun supertag-query--sort-value (node-id node key)
  "Return the raw sort value for NODE-ID/NODE for normalized sort KEY."
  (cond
   ((string= key "title") (plist-get node :title))
   ((string= key "created") (plist-get node :created-at))
   ((string= key "modified") (plist-get node :modified-at))
   (t (supertag-query-property-value node-id key))))

(defun supertag-query--sort-node-ids (node-ids key order)
  "Sort NODE-IDS by KEY per ORDER.
Nodes missing the sort key are always placed last, regardless of ORDER."
  (let (with-key without-key)
    (dolist (id node-ids)
      (let* ((node (supertag-query-node id))
             (v (and node (supertag-query--sort-value id node key))))
        (if v (push (cons id v) with-key) (push id without-key))))
    (setq with-key (nreverse with-key)
          without-key (nreverse without-key))
    (setq with-key
          (sort with-key
                (lambda (a b) (supertag-query--value< (cdr a) (cdr b)))))
    (when (eq order 'desc) (setq with-key (nreverse with-key)))
    (append (mapcar #'car with-key) without-key)))

(defun supertag-query--aggregate-values (nodes type key)
  "Aggregate NODES (list of node plists) with TYPE over KEY.
count ignores KEY; sum/avg return nil for non-numeric value sets."
  (if (eq type 'count)
      (length nodes)
    (let ((values
           (cl-remove-if-not
            #'identity
            (mapcar (lambda (node)
                      (supertag-query--sort-value
                       (plist-get node :id) node key))
                    nodes))))
      (if (and (memq type '(sum avg))
               (not (cl-every #'numberp values)))
          nil
        (supertag-rollup-apply type values)))))

(defun supertag-query--group-values (node-ids group-key)
  "Group NODE-IDS by GROUP-KEY into a (group-key . node-plists) alist."
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (id node-ids)
      (let* ((node (supertag-query-node id))
             (key (and node
                       (supertag-query--sort-value id node group-key)))
             (bucket (or key "__ungrouped__")))
        (let ((existing (gethash bucket groups)))
          (puthash bucket (cons node existing) groups))))
    (let (result)
      (maphash (lambda (key value)
                 (push (cons key (nreverse value)) result))
               groups)
      (sort result
            (lambda (a b)
              (string< (format "%s" (car a))
                       (format "%s" (car b))))))))

(defun supertag-query--apply-modifiers (node-ids modifiers)
  "Apply result MODIFIERS to NODE-IDS.
Pipeline: sort-by (if any) -> group-by (if any) -> aggregate (if any).
Returns node IDs without aggregates, a scalar with an aggregate, or an
alist of (group-key . value) with group-by + aggregate."
  (let* ((sorts (cl-remove-if-not
                 (lambda (modifier) (eq (plist-get modifier :type) 'sort-by))
                 modifiers))
         (groups (cl-remove-if-not
                  (lambda (modifier) (eq (plist-get modifier :type) 'group-by))
                  modifiers))
         (aggregates
          (cl-remove-if-not
           (lambda (modifier)
             (memq (plist-get modifier :type)
                   '(sum count avg min max first last unique-count concat)))
           modifiers))
         (sorted node-ids))
    (dolist (sort modifiers)
      (pcase (plist-get sort :type)
        ('sort-by
         (setq sorted
               (supertag-query--sort-node-ids
                sorted (plist-get sort :key) (plist-get sort :order))))))
    (when (> (length groups) 1)
      (error "Only one group-by modifier is allowed"))
    (when (> (length aggregates) 1)
      (error "Only one aggregate modifier is allowed"))
    (when (and groups (null aggregates))
      (error "group-by requires an aggregate modifier"))
    (if (null aggregates)
        sorted
      (let* ((group-property (and groups (plist-get (car groups) :key)))
             (aggregate (car aggregates))
             (agg-type (plist-get aggregate :type))
             (agg-key (plist-get aggregate :key)))
        (if group-property
            (mapcar
             (lambda (entry)
               (cons (car entry)
                     (supertag-query--aggregate-values
                      (cdr entry) agg-type agg-key)))
             (supertag-query--group-values sorted group-property))
          (supertag-query--aggregate-values
           (mapcar #'supertag-query-node sorted) agg-type agg-key))))))

(defun supertag-query-modifiers (query-sexp)
  "Return the result modifiers of QUERY-SEXP, in order."
  (supertag-query--ast-modifiers
   (supertag-query--parse-sexp query-sexp)))

(defun supertag-query--resolve-date-string (date-str)
  "Resolve a date string into an absolute time value.
Handles absolute dates ('YYYY-MM-DD'), 'now', the day symbols
today/yesterday/tomorrow (resolved to local midnight), and relative
dates ('-7d', '+2w', '-4h', '+30min', etc.).
Compatible with the old query engine date format."
  (let ((now (current-time)))
    (cond
     ;; Case 1: "now"
     ((string= date-str "now") now)

     ;; Case 1b: day symbols, resolved to local midnight.
     ((member date-str '("today" "yesterday" "tomorrow"))
      (let* ((decoded (decode-time now))
             (day (nth 3 decoded))
             (month (nth 4 decoded))
             (year (nth 5 decoded))
             (delta (pcase date-str
                      ("today" 0)
                      ("yesterday" -1)
                      ("tomorrow" 1))))
        ;; encode-time normalizes day overflow (0, 32, ...) itself.
        (encode-time 0 0 0 (+ day delta) month year)))

     ;; Case 2: Relative date like "-7d", "+2w", "-4h", "+30min"
     ((string-match "^\\([+-]\\)?\\([0-9]+\\)\\(d\\|w\\|m\\|y\\|h\\|min\\)$" date-str)
      (let* ((sign (if (match-string 1 date-str) (match-string 1 date-str) "+"))
             (num (string-to-number (match-string 2 date-str)))
             (unit (match-string 3 date-str))
             (seconds-per-day 86400)
             (delta-seconds
              (* num
                 (pcase unit
                   ("d" seconds-per-day)
                   ("w" (* 7 seconds-per-day))
                   ;; Approximation: 30 days for a month
                   ("m" (* 30 seconds-per-day))
                   ;; Approximation: 365.25 days for a year
                   ("y" (* 365.25 seconds-per-day))
                   ("h" 3600)
                   ("min" 60)))))
        (if (string= sign "-")
            (time-subtract now (seconds-to-time delta-seconds))
          (time-add now (seconds-to-time delta-seconds)))))

     ;; Case 3: Absolute date "YYYY-MM-DD"
     ((string-match "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}$" date-str)
      ;; `parse-time-string' on a bare date returns a decoded-time list
      ;; with nil SEC/MIN/HOUR -- not a value `time-less-p' accepts.
      ;; Fill midnight and encode to a real time value.
      (let ((decoded (parse-time-string date-str)))
        (encode-time 0 0 0
                     (nth 3 decoded) (nth 4 decoded) (nth 5 decoded))))

     ;; Default: Invalid format
     (t nil))))

(defun supertag-query--get-properties-from-ast (ast)
  "Extract property keys from the query AST.
Used for generating table headers in Org Babel output."
  (let ((properties '()))
    (cl-labels ((walk (sub-ast)
                  (let ((type (plist-get sub-ast :type)))
                    (cond
                     ((member type '(and or))
                      (dolist (child (plist-get sub-ast :children)) (walk child)))
                     ((eq type 'not)
                      (dolist (child (plist-get sub-ast :children)) (walk child)))
                     ((eq type 'property)
                      (push (substring (symbol-name (plist-get sub-ast :key)) 1)
                            properties))
                     ((plist-get sub-ast :child)
                      (walk (plist-get sub-ast :child)))))))
      (walk ast))
    (cl-delete-duplicates properties :test #'string=)))

;; --- Canonical infix parser and evaluator ---

(defun supertag-formula-tokenize (input)
  "Tokenize INPUT string into list of tokens."
  (let ((tokens nil)
        (i 0)
        (len (length input)))
    (while (< i len)
      (let ((ch (aref input i)))
        (cond
         ((member ch '(?\s ?\t ?\n ?\r))
          (setq i (1+ i)))
         ((= ch ?+)
          (push '+ tokens)
          (setq i (1+ i)))
         ((= ch ?-)
          (push '- tokens)
          (setq i (1+ i)))
         ((= ch ?*)
          (push '* tokens)
          (setq i (1+ i)))
         ((= ch ?/)
          (push '/ tokens)
          (setq i (1+ i)))
         ((= ch ?\()
          (push '*lparen* tokens)
          (setq i (1+ i)))
         ((= ch ?\))
          (push '*rparen* tokens)
          (setq i (1+ i)))
         ((and (>= ch ?0) (<= ch ?9))
          (let ((start i))
            (while (and (< i len)
                        (let ((c (aref input i)))
                          (or (and (>= c ?0) (<= c ?9))
                              (= c ?.))))
              (setq i (1+ i)))
            (push (string-to-number (substring input start i)) tokens)))
         ((or (and (>= ch ?a) (<= ch ?z))
              (and (>= ch ?A) (<= ch ?Z))
              (= ch ?_))
          (let ((start i))
            (while (and (< i len)
                        (let ((c (aref input i)))
                          (or (and (>= c ?a) (<= c ?z))
                              (and (>= c ?A) (<= c ?Z))
                              (and (>= c ?0) (<= c ?9))
                              (= c ?_))))
              (setq i (1+ i)))
            (push (substring input start i) tokens)))
         (t
          (error "Invalid character at position %d: %c" i ch)))))
    (nreverse tokens)))

(defun supertag-formula-parse (tokens)
  "Parse TOKENS into AST using recursive descent."
  (let ((pos 0)
        (len (length tokens)))
    (cl-labels
        ((peek ()
           (when (< pos len) (nth pos tokens)))
         (consume ()
           (prog1 (peek) (setq pos (1+ pos))))
         (expect (token)
           (if (eq (peek) token)
               (consume)
             (error "Expected %s but got %s at position %d" token (peek) pos)))
         (parse-expr ()
           (parse-additive))
         (parse-additive ()
           (let ((left (parse-multiplicative)))
             (while (member (peek) '(+ -))
               (let ((op (consume))
                     (right (parse-multiplicative)))
                 (setq left (list op left right))))
             left))
         (parse-multiplicative ()
           (let ((left (parse-primary)))
             (while (member (peek) '(* /))
               (let ((op (consume))
                     (right (parse-primary)))
                 (setq left (list op left right))))
             left))
         (parse-primary ()
           (let ((token (peek)))
             (cond
              ((null token)
               (error "Unexpected end of input"))
              ((eq token '*lparen*)
               (consume)
               (let ((expr (parse-expr)))
                 (expect '*rparen*)
                 expr))
              ((numberp token)
               (consume)
               (list '*number* token))
              ((stringp token)
               (consume)
               (list '*var* token))
              ((eq token '-)
               (consume)
               (list '*neg* (parse-primary)))
              (t
               (error "Unexpected token: %s" token))))))
      (let ((result (parse-expr)))
        (when (< pos len)
          (error "Unexpected token at end: %s" (peek)))
        result))))

(defun supertag-formula-eval (ast node-id &optional resolver)
  "Evaluate AST for NODE-ID, resolving variables via RESOLVER.
RESOLVER is a function taking a property name and returning its value.
Without RESOLVER, variables read projected Org properties; missing keys return nil."
  (pcase ast
    ((pred numberp) ast)
    (`(*number* ,n) n)
    (`(*var* ,property-name)
     (let ((value (if resolver (funcall resolver property-name)
                    (plist-get (plist-get (supertag-store-get-entity :nodes node-id) :properties)
                               (intern (concat ":" (upcase property-name)))))))
       (if (and (stringp value)
                (string-match-p "\\`[+-]?[0-9]+\\(?:\\.[0-9]+\\)?\\'" value))
           (string-to-number value)
         value)))
    ((or `(+ ,a ,b) `(- ,a ,b) `(* ,a ,b) `(/ ,a ,b))
     (let ((left (supertag-formula-eval a node-id resolver))
           (right (supertag-formula-eval b node-id resolver)))
       (when (and (numberp left) (numberp right))
         (if (eq (car ast) '/)
             (if (zerop right) 0 (/ (float left) right))
           (funcall (car ast) left right)))))
    (`(*neg* ,a)
     (let ((value (supertag-formula-eval a node-id resolver)))
       (when (numberp value) (- value))))
    (_ (error "Unknown AST node: %s" ast))))

(defun supertag-formula-parse-string (input)
  "Parse INPUT string to AST."
  (let ((tokens (supertag-formula-tokenize input)))
    (supertag-formula-parse tokens)))

(defun supertag-formula-eval-string (input node-id &optional resolver)
  "Parse and evaluate INPUT string for NODE-ID.
RESOLVER is the variable resolver passed to `supertag-formula-eval'."
  (let ((ast (supertag-formula-parse-string input)))
    (supertag-formula-eval ast node-id resolver)))

;; --- Legacy syntax translation ---

(defun supertag-formula--translate-placeholders (formula-string)
  "Replace {{KEY}} placeholders in FORMULA-STRING with bare KEY names."
  (replace-regexp-in-string
   "{{\\s-*:?\\([^{}]*?\\)\\s-*}}"
   (lambda (placeholder)
     (string-trim
      (if (string-match "{{\\s-*:?\\([^{}]*?\\)\\s-*}}" placeholder)
          (match-string 1 placeholder)
        "")))
   formula-string t t))

(defun supertag-formula--prefix-to-infix (form)
  "Translate legacy prefix FORM to canonical infix text.
Only binary + - * / over numbers and symbols are supported."
  (cond
   ((numberp form) (number-to-string form))
   ((symbolp form) (symbol-name form))
   ((and (consp form)
         (memq (car form) '(+ - * /))
         (= (length form) 3))
    (format "(%s %s %s)"
            (supertag-formula--prefix-to-infix (nth 1 form))
            (symbol-name (car form))
            (supertag-formula--prefix-to-infix (nth 2 form))))
   (t (error
       (concat "Unsupported legacy formula form %S; rewrite using the "
               "infix grammar, e.g. \"(done / total) * 100\"")
       form))))

(defun supertag-formula--canonicalize (formula-string)
  "Return FORMULA-STRING in the canonical infix grammar.
Legacy {{placeholder}} prefix formulas are translated; strings already
in the infix grammar pass through unchanged."
  (let* ((translated (supertag-formula--translate-placeholders formula-string))
         (parsed (condition-case nil
                     (read-from-string translated)
                   (error nil))))
    (if (and parsed
             (string-match-p "\\`[[:space:]]*\\'"
                             (substring translated (cdr parsed))))
        (supertag-formula--prefix-to-infix (car parsed))
      translated)))

;; --- Unified evaluation entry point ---

(defun supertag-rollup-apply (function-name values)
  "Reduce VALUES with FUNCTION-NAME.
FUNCTION-NAME is one of count, sum, avg/average, min, max, first, last,
unique-count, concat, or a function object applied to VALUES.
This is the single rollup reduction shared by Table, Virtual Column and
Automation so identical inputs produce identical results."
  (pcase function-name
    ((or 'count :count) (length values))
    ((or 'sum :sum) (apply #'+ (or values '(0))))
    ((or 'avg 'average :avg :average)
     (if values (/ (apply #'+ values) (length values)) 0))
    ((or 'min :min) (when values (apply #'min values)))
    ((or 'max :max) (when values (apply #'max values)))
    ((or 'first :first) (car values))
    ((or 'last :last) (car (last values)))
    ('unique-count (length (cl-remove-duplicates values :test #'equal)))
    ('concat (mapconcat #'identity values ", "))
    ((pred functionp) (funcall function-name values))
    (_ (message "Unknown rollup function: %S" function-name))))

(defun supertag-formula-evaluate (formula-string entity-data &optional property-getter)
  "Evaluate FORMULA-STRING for ENTITY-DATA.
Canonical grammar: infix arithmetic with property references as variables,
e.g. \"(done / total) * 100\".  Legacy {{key}}-placeholder prefix forms
are translated first.  Variables resolve through PROPERTY-GETTER when
supplied, otherwise through projected Org properties."
  (unless (and (stringp formula-string) (not (string-empty-p formula-string)))
    (error "FORMULA-STRING must be a non-empty string"))
  (let* ((canonical (supertag-formula--canonicalize formula-string))
         (node-id (plist-get entity-data :id))
         (resolver
          (or property-getter
              (lambda (name)
                (plist-get (plist-get entity-data :properties)
                           (intern (concat ":" (upcase name))))))))
    (supertag-formula-eval
     (supertag-formula-parse-string canonical) node-id resolver)))

;;; Projection scan adapters

(defun supertag-index-get-nodes-by-tag (tag-name &optional include-descendants)
  "Return indexed node IDs for TAG-NAME.
When INCLUDE-DESCENDANTS is non-nil, include transitive descendants."
  (let* ((resolved (or (and (supertag-tag-get tag-name) tag-name)
                       (supertag-tag-resolve-occurrence tag-name)
                       tag-name))
         (matching-tags (cons resolved
                             (and include-descendants
                                  (supertag-find-tag-descendants resolved)))))
    (supertag-index-find-node-ids-by-tags matching-tags)))

(defun supertag-index-get-nodes-by-word (word)
  "Find all nodes containing WORD by scanning the store.
This is an O(N) operation and performs a simple substring search."
  (let ((nodes-ht (supertag-store-get-collection :nodes))
        (results '())
        (search-word (downcase word)))
    (when (hash-table-p nodes-ht)
      (maphash (lambda (node-id node-data)
                 (let ((title (plist-get node-data :title))
                       (content (plist-get node-data :content)))
                   (when (or (and title (string-match-p (regexp-quote search-word) (downcase title)))
                             (and content (string-match-p (regexp-quote search-word) (downcase content))))
                     (push node-id results))))
               nodes-ht))
    (nreverse (delete-dups results))))

(defun supertag-index-get-nodes-by-date-range (start-time end-time &optional date-field)
  "Find all nodes created/modified within a date range by scanning.
This is an O(N) operation.
DATE-FIELD can be :created-at or :modified-at (default :created-at)."
  (let* ((field (or date-field :created-at))
         (nodes-ht (supertag-store-get-collection :nodes))
         (matching-nodes '()))
    (when (hash-table-p nodes-ht)
      (maphash (lambda (node-id node-data)
                 (let ((node-time (plist-get node-data field)))
                   (when node-time
                     (let ((start-check (or (null start-time) (time-less-p start-time node-time)))
                           (end-check (or (null end-time) (time-less-p node-time end-time))))
                       (when (and start-check end-check)
                         (push node-id matching-nodes))))))
               nodes-ht))
    (nreverse matching-nodes)))

(defun supertag-find-nodes-by-tag (tag-name &optional include-descendants)
  "Return indexed nodes with TAG-NAME.
TAG-NAME is the name of the tag to search for.
When INCLUDE-DESCENDANTS is non-nil, tags that transitively extend
TAG-NAME also match.
Returns a list of (node-id . node-data) pairs."
  (let* ((resolved (or (and (supertag-tag-get tag-name) tag-name)
                       (supertag-tag-resolve-occurrence tag-name)
                       tag-name))
         (matching-tags (cons resolved
                             (and include-descendants
                                  (supertag-find-tag-descendants resolved))))
         (nodes-ht (supertag-store-get-collection :nodes))
         results)
    (dolist (node-id (supertag-index-find-node-ids-by-tags matching-tags)
                     (nreverse results))
      (when-let* ((node (gethash node-id nodes-ht)))
        (push (cons node-id node) results)))))

(defun supertag-find-nodes-by-file (file-path)
  "Find all nodes located in FILE-PATH.
Returns a list of (node-id . node-data) pairs."
  (let ((nodes-collection (supertag-store-get-collection :nodes))
        (found-nodes '()))
    (when (hash-table-p nodes-collection)
      (maphash
       (lambda (id node-data)
         ;; Safely extract :file and ensure it's a string
         (when-let* ((node-file (and node-data (plist-get node-data :file)))
                     ((stringp node-file)))
           ;; Direct string comparison without path normalization
           (when (equal node-file file-path)
             (push (cons id node-data) found-nodes))))
       nodes-collection))
    (nreverse found-nodes)))

(defun supertag-find-file-node (file-path)
  "Find the file node (level 0) for FILE-PATH.
Returns (node-id . node-data) or nil."
  (let ((nodes-collection (supertag-store-get-collection :nodes))
        (found nil))
    (when (hash-table-p nodes-collection)
      (maphash
       (lambda (id node-data)
         (when (and node-data
                    (eq (plist-get node-data :level) 0)
                    (equal (plist-get node-data :file) file-path)
                    (not found))
           (setq found (cons id node-data))))
       nodes-collection))
    found))

;;; Org query blocks and interactive construction

;; This file provides S-expression query block functionality for Org, in
;; two flavors that share a single "query string + params -> table string"
;; core:
;;
;; 1. Org Babel blocks (`org-babel-execute:supertag-query-block'):
;;
;;      #+BEGIN_SRC supertag-query-block :results raw :sort modified :order desc :limit 20 :columns "status priority"
;;      (and (tag "project") (after "-30d"))
;;      #+END_SRC
;;
;;    Re-run with the usual babel keys (\\[org-ctrl-c-ctrl-c] on the block).
;;
;; 2. Dataview-style dynamic blocks (`org-dblock-write:supertag-query'),
;;    which auto-refresh like any other Org dynamic block:
;;
;;      #+BEGIN: supertag-query :query "(and (tag \"project\") (after \"-30d\"))" :sort modified :order desc :limit 20 :columns ("status" "priority")
;;      #+END:
;;
;;    Refresh with \\[org-ctrl-c-ctrl-c] on the block, `org-dblock-update',
;;    or `org-update-all-dblocks' for existing dynamic blocks.
;;
;; Links rendered by either flavor are generated view content, not Document
;; Link assertions.  The sync extractor therefore ignores dynamic-block bodies
;; and persisted `#+RESULTS:' containers while continuing to display the links.
;;
;; Both flavors accept the same optional result-control params, all of
;; which are no-ops when omitted (existing babel blocks keep behaving
;; exactly as before):
;;
;;   :sort    title | created | modified | a property name.
;;            Property (and "created"/"modified") sorts compare numerically
;;            when both values parse as numbers, otherwise string-compare
;;            ("created"/"modified" compare as Emacs time values instead).
;;            Nodes missing the sort key sort last, regardless of :order.
;;   :order   asc (default) | desc.
;;   :limit   a positive integer, applied after sorting.
;;   :columns an explicit list of property names for extra table columns,
;;            overriding the properties auto-derived from the query's
;;            (property ...) clauses. The "Node" and "Tags" columns are
;;            always present regardless.
;;
;; Malformed queries and invalid params never signal into the org-babel or
;; org-dblock machinery: they render as a single-line "Error: ..." string
;; in place of the table.
;;
;; This module follows the "good taste" principle: single responsibility,
;; no special cases, clean data flow.

;;; --- Table Formatting ---

(defun supertag-query-block--format-table (headers data)
  "Format DATA into an Org table string with HEADERS and basic alignment."
  (with-temp-buffer
    (org-mode)
    ;; Ensure tab-width is 8 as required by org-current-text-column
    (setq-local tab-width 8)
    (insert "| " (mapconcat #'identity headers " | ") " |\n")
    (insert "|-" (mapconcat (lambda (h) (make-string (length h) ?-)) headers "-|-") "-|\n")
    (dolist (row data)
      (insert "| " (mapconcat #'identity row " | ") " |\n"))
    (org-table-align)
    (buffer-string)))

;;; --- Shared Core: query string + params -> table string ---

(defun supertag-query-block--parse-columns (columns)
  "Normalize the :columns param COLUMNS into a list of property-name strings.
Accepts a list of strings/symbols, a single symbol, a space/comma
separated string, or nil (meaning \"no override\")."
  (cond
   ((null columns) nil)
   ((stringp columns)
    (let ((trimmed (string-trim columns)))
      (unless (string-empty-p trimmed)
        (split-string trimmed "[, \f\t\n\r\v]+" t))))
   ((symbolp columns) (list (symbol-name columns)))
   ((listp columns)
    (mapcar (lambda (c)
              (cond ((stringp c) c)
                    ((symbolp c) (symbol-name c))
                    (t (format "%s" c))))
            columns))
   (t (error "Invalid :columns value: %S" columns))))

(defun supertag-query-block--normalize-sort-key (sort)
  "Normalize the :sort param SORT into a property-key string, or nil."
  (cond
   ((null sort) nil)
   ((stringp sort) (let ((trimmed (string-trim sort)))
                      (unless (string-empty-p trimmed) trimmed)))
   ((symbolp sort) (symbol-name sort))
   (t (error "Invalid :sort value: %S" sort))))

(defun supertag-query-block--normalize-order (order)
  "Normalize the :order param ORDER into the symbol `asc' or `desc'."
  (cond
   ((null order) 'asc)
   ((memq order '(asc desc)) order)
   ((and (stringp order) (member (downcase (string-trim order)) '("asc" "desc")))
    (intern (downcase (string-trim order))))
   (t (error "Invalid :order value: %S (expected asc or desc)" order))))

(defun supertag-query-block--normalize-limit (limit)
  "Normalize the :limit param LIMIT into a positive integer, or nil."
  (cond
   ((null limit) nil)
   ((and (integerp limit) (> limit 0)) limit)
   ((and (stringp limit)
         (string-match-p "\\`[ \t]*[0-9]+[ \t]*\\'" limit)
         (> (string-to-number limit) 0))
    (string-to-number limit))
   (t (error "Invalid :limit value: %S (expected a positive integer)" limit))))

(defun supertag-query-block--sort-value (node-id node key)
  "Return the raw sort value for NODE-ID/NODE for normalized sort KEY."
  (supertag-query--sort-value node-id node key))

(defun supertag-query-block--numeric (value)
  "Return VALUE as a number if it is one, or a numeric-looking string. Else nil."
  (supertag-query--numeric value))

(defun supertag-query-block--value< (a b)
  "Return non-nil if sort value A sorts before sort value B."
  (supertag-query--value< a b))

(defun supertag-query-block--apply-sort (nodes sort-key order)
  "Sort NODES (list of node plists) by SORT-KEY (string or nil) per ORDER.
Nodes missing the sort key are always placed last, regardless of ORDER."
  (if (null sort-key)
      nodes
    (let (with-key without-key)
      (dolist (n nodes)
        (let ((v (supertag-query-block--sort-value (plist-get n :id) n sort-key)))
          (if v (push (cons n v) with-key) (push n without-key))))
      (setq with-key (nreverse with-key)
            without-key (nreverse without-key))
      (setq with-key (sort with-key (lambda (a b) (supertag-query-block--value< (cdr a) (cdr b)))))
      (when (eq order 'desc) (setq with-key (nreverse with-key)))
      (append (mapcar #'car with-key) without-key))))

(defun supertag-query-block--row (node columns)
  "Build one Org table row (list of cell strings) for NODE and COLUMNS."
  (let* ((id (plist-get node :id))
         (title (or (plist-get node :title) "Untitled"))
         (tags (plist-get node :tags)))
    (append (list (supertag-node-format-link id title)
                  (if (and tags (listp tags))
                      (mapconcat #'identity tags ", ")
                    ""))
            (mapcar (lambda (key)
                      (let ((val (supertag-query-property-value id key)))
                        (if val (format "%s" val) "")))
                    columns))))

(defun supertag-query-block--aggregate-headers-and-rows (query-sexp)
  "Return (HEADERS . ROWS) for an aggregate QUERY-SEXP.
Scalar aggregates render as one row; grouped aggregates as one row per
group (group key first, then the aggregate value)."
  (let* ((result (supertag-query-evaluate query-sexp))
         (modifiers (supertag-query-modifiers query-sexp))
         (grouped-p (cl-some
                     (lambda (modifier)
                       (eq (plist-get modifier :type) 'group-by))
                     modifiers)))
    (if grouped-p
        (cons '("Group" "Aggregate")
              (mapcar (lambda (entry)
                        (list (format "%s" (car entry))
                              (format "%s" (cdr entry))))
                      result))
      (cons '("Aggregate")
            (list (list (format "%s" result)))))))

(defun supertag-query-block--headers-and-rows (query-str opts)
  "Execute QUERY-STR (an S-expression query string) with OPTS.
OPTS is a plist with optional :sort, :order, :limit, :columns keys, using
the same semantics documented at the top of this file.
Returns (HEADERS . ROWS). Signals an error on malformed input; callers
that must never signal should go through `supertag-query-block--render'."
  (let* ((query-sexp (car (read-from-string
                            (supertag-query-expand (string-trim query-str)))))
         (modifiers (supertag-query-modifiers query-sexp))
         (aggregate-p
          (cl-some
           (lambda (modifier)
             (memq (plist-get modifier :type)
                   '(sum count avg min max first last unique-count concat)))
           modifiers)))
    (if aggregate-p
        (supertag-query-block--aggregate-headers-and-rows query-sexp)
      (let* ((node-ids (supertag-query-node-ids query-sexp))
             (auto-properties (supertag-query-properties query-sexp))
             (columns (or (supertag-query-block--parse-columns (plist-get opts :columns))
                          auto-properties))
             (sort-key (supertag-query-block--normalize-sort-key (plist-get opts :sort)))
             (order (supertag-query-block--normalize-order (plist-get opts :order)))
             (limit (supertag-query-block--normalize-limit (plist-get opts :limit)))
             ;; In-query sort-by wins over the :sort header: the engine already
             ;; returned sorted IDs, so skip the header sort entirely.
             (syntax-sorts (cl-remove-if-not
                            (lambda (modifier) (eq (plist-get modifier :type) 'sort-by))
                            modifiers))
             (nodes (delq nil (mapcar #'supertag-node-get node-ids)))
             (nodes (if syntax-sorts
                        nodes
                      (supertag-query-block--apply-sort nodes sort-key order))))
        (when limit
          (setq nodes (cl-subseq nodes 0 (min limit (length nodes)))))
        (cons (append '("Node" "Tags") columns)
              (mapcar (lambda (node) (supertag-query-block--row node columns))
                      nodes))))))

(defun supertag-query-block--render (query-str opts)
  "Render QUERY-STR/OPTS to a table string, or a one-line \"Error: ...\" string.
Never signals: this is the entry point both the babel executor and the
dynamic-block writer call, so a malformed query s-expression or an
invalid param (unknown sort key, bad :order/:limit/:columns value, etc.)
must never propagate into org-babel or org-dblock machinery."
  (condition-case err
      (let* ((result (supertag-query-block--headers-and-rows query-str opts))
             (headers (car result))
             (rows (cdr result)))
        (if (null rows)
            "No results found."
          (supertag-query-block--format-table headers rows)))
    (error (format "Error: %s" (error-message-string err)))))

;;; --- S-expression Query Block Functions (Org Babel) ---

(defun supertag-add-query-block ()
  "Add an S-expression query block for Org Babel."
  (interactive)
  (let* ((query (read-string "Query S-expression: "))
         (block-template "#+BEGIN_SRC supertag-query-block :results raw\n%s\n#+END_SRC"))
    (unless (string-empty-p query)
      (insert (format block-template query)))))

(defun org-babel-execute:supertag-query-block (body params)
  "Execute an supertag-query-block and return results as an Org table.
BODY is the S-expression query string.
PARAMS are the babel header args. All are optional and, when omitted,
produce exactly the previous behavior:

  :sort NAME    title | created | modified | a property name. To pass a
                literal string instead of a bare symbol, quote it, e.g.
                :sort \"priority\".
  :order asc|desc
  :limit N      a positive integer.
  :columns \"f1 f2\"  or  :columns \\='(\"f1\" \"f2\")
                A space/comma separated string is the simplest form; a
                quoted Lisp list also works (header-arg values starting
                with \"(\" are `eval'd by Org, so an unquoted list would
                be evaluated as a function call).

See the file commentary for full semantics (missing sort keys sort
last, numeric vs. string vs. Emacs-time comparison, etc.). Malformed
queries or invalid params render as a one-line error string instead of
signaling."
  (supertag-query-block--render
   body
   (list :sort (cdr (assq :sort params))
         :order (cdr (assq :order params))
         :limit (cdr (assq :limit params))
         :columns (cdr (assq :columns params)))))

;;; --- Dataview-style Dynamic Block ---

(defun org-dblock-write:supertag-query (params)
  "Render a Supertag S-expression query as a refreshable Org dynamic block.
PARAMS is the plist Org parses from the #+BEGIN: line, e.g.:

  #+BEGIN: supertag-query :query \"(and (tag \\\"project\\\") (after \\\"-30d\\\"))\" \\
:sort modified :order desc :limit 20 :columns (\"status\" \"priority\")
  #+END:

Recognized keys (all but :query are optional):
  :query   (required) an S-expression query string, same syntax as the
           `supertag-query-block' babel language.
  :sort    title | created | modified | a property name (bare symbol or
           string).
  :order   asc (default) | desc.
  :limit   a positive integer, applied after sorting.
  :columns an explicit list of property names, e.g. (\"status\" \"priority\"),
           overriding the properties auto-derived from the query. \"Node\"
           and \"Tags\" columns are always present.

Refresh with \\[org-ctrl-c-ctrl-c] on the block, `org-dblock-update', or
`org-update-all-dblocks'. Never signals: a malformed :query or an
invalid param renders as a one-line error string instead of a table."
  (let* ((query-str (plist-get params :query))
         (text
          (if (not (and query-str (stringp query-str)
                        (not (string-empty-p (string-trim query-str)))))
              "Error: supertag-query dynamic block requires a :query string."
            (supertag-query-block--render
             query-str
             (list :sort (plist-get params :sort)
                   :order (plist-get params :order)
                   :limit (plist-get params :limit)
                   :columns (plist-get params :columns))))))
    ;; `org-prepare-dblock' already positioned point on a fresh blank line
    ;; immediately followed by the #+END: line's own newline, so the
    ;; inserted text must NOT end in a trailing newline of its own.
    (insert (string-remove-suffix "\n" text))))

;;; --- Initialization and Configuration ---

;; Per-language Babel defaults.  `org-babel-load-languages' is reserved for
;; libraries named ob-<language>, whereas this executor lives in this file.
(defvar org-babel-default-header-args:supertag-query-block
  '((:results . "raw")))

;;; --- Guided query builder and syntax reference ---

;;; --- Small helpers -----------------------------------------------------

;;; --- Rendering query results --------------------------------------------

(defun supertag-query-block--render-results (query-sexp)
  "Run QUERY-SEXP and return a read-only buffer showing the results.
Node titles are shown as Org links, alongside a Tags column and one
column per property mentioned in QUERY-SEXP.  This reuses the query
engine's own AST parser/executor/property-extractor; it does not
reimplement parsing or execution."
  (let* ((node-ids (supertag-query-node-ids query-sexp))
         (property-keys (supertag-query-properties query-sexp))
         (nodes (delq nil (mapcar #'supertag-node-get node-ids)))
         (buf (get-buffer-create "*Supertag Query Results*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (setq-local tab-width 8)
        (insert (format "#+TITLE: Supertag Query Results\n# Query: %S\n\n" query-sexp))
        (if (not nodes)
            (insert "No results found.\n")
          (let ((headers (append '("Node" "Tags") property-keys)))
            (insert "| " (mapconcat #'identity headers " | ") " |\n")
            (insert "|-" (mapconcat (lambda (h) (make-string (length h) ?-)) headers "-|-") "-|\n")
            (dolist (node nodes)
              (let* ((id (plist-get node :id))
                     (title (or (plist-get node :title) "Untitled"))
                     (tags (plist-get node :tags))
                     (row (append
                           (list (supertag-node-format-link id title)
                                 (if (and tags (listp tags)) (mapconcat #'identity tags ", ") ""))
                           (mapcar (lambda (key)
                                     (let ((val (supertag-query-property-value id key)))
                                       (if val (format "%s" val) "")))
                                   property-keys))))
                (insert "| " (mapconcat #'identity row " | ") " |\n")))
            (org-table-align)))
        (goto-char (point-min))
        (view-mode 1)))
    buf))

;;; --- Guided builder -------------------------------------------------------

(defconst supertag-query-block--operators
  '(("tag"     . "(tag NAME) -- nodes carrying tag NAME")
    ("property" . "(property KEY VALUE) -- nodes whose property KEY equals VALUE")
    ("term"    . "(term WORD) -- full-text search over title/content")
    ("after"   . "(after DATE) -- nodes dated after DATE")
    ("before"  . "(before DATE) -- nodes dated before DATE")
    ("between" . "(between START END) -- nodes dated between START and END")
    ("recent-days" . "(recent-days N) -- nodes created in the last N days")
    ("in-month" . "(in-month \"YYYY-MM\") -- nodes created in that month")
    ("in-year"  . "(in-year \"YYYY\") -- nodes created in that year")
    ("link" . "(link REF QUERY) -- source nodes linked to matching targets")
    ("reverse-link" . "(reverse-link REF QUERY) -- target nodes linked from matching sources")
    ("has-link" . "(has-link REF) -- source nodes with any outgoing Link")
    ("has-reverse-link" . "(has-reverse-link REF) -- target nodes with any incoming Link"))
  "Leaf query operators offered by `supertag-query-build', with descriptions.")

(defun supertag-query-block--completing-read-operator (prompt)
  "Read a leaf operator name with PROMPT, annotated with its meaning."
  (let ((collection
         (lambda (str pred action)
           (if (eq action 'metadata)
               '(metadata (annotation-function . supertag-query-block--annotate-operator))
             (complete-with-action action (mapcar #'car supertag-query-block--operators) str pred)))))
    (completing-read prompt collection nil t)))

(defun supertag-query-block--annotate-operator (op)
  "Return an annotation string describing operator OP."
  (let ((desc (cdr (assoc op supertag-query-block--operators))))
    (if desc (format "  --  %s" desc) "")))

(defun supertag-query-block--live-tag-names ()
  "Return known tag names from live data, or nil if unavailable."
  (ignore-errors (supertag-view-api-list-tag-ids)))

(defun supertag-query-block--live-property-names ()
  "Return property names present in node projections."
  (let (names)
    (maphash (lambda (_id node)
               (cl-loop for (key _value) on (plist-get node :properties) by #'cddr
                        do (push (string-remove-prefix ":" (format "%s" key)) names)))
             (supertag-store-get-collection :nodes))
    (sort (delete-dups names) #'string<)))

(defun supertag-query-block--read-tag-name ()
  "Read a tag name, completing against live tags when available."
  (let ((tags (supertag-query-block--live-tag-names)))
    (if tags
        (supertag-ui-read-tag "Tag: " tags t nil)
      (read-string "Tag: "))))

(defun supertag-query-block--read-property-name ()
  "Read a property name, completing against node properties when available."
  (let ((properties (supertag-query-block--live-property-names)))
    (if properties
        (completing-read "Property: " properties nil nil)
      (read-string "Property: "))))

(defun supertag-query-block--read-link-reference ()
  "Read a named Org link relation, completing against projected names."
  (let ((candidates
         (delete-dups
          (mapcar (lambda (relation) (plist-get relation :relation-name))
                  (supertag-query-relations #'supertag-relation-named-document-link-p)))))
    (completing-read "Relation name: " candidates nil nil)))

(defun supertag-query-block--read-date (prompt)
  "Read a date string for PROMPT, validated with the engine's own parser.
Accepts \"now\", an absolute \"YYYY-MM-DD\" date, or a relative offset
like \"-7d\", \"+2w\", \"-1m\", \"1y\" (an offset without a sign means
+, i.e. the future)."
  (let ((s (read-string (format "%s (now / YYYY-MM-DD / -7d / +2w): " prompt))))
    (unless (supertag-query-date-valid-p s)
      (user-error "Unrecognized date `%s' -- use now, YYYY-MM-DD, or [+-]Nd/w/m/y" s))
    s))

(defun supertag-query-block--make-condition (op &rest args)
  "Construct and validate a leaf condition sexp for operator OP and ARGS.
OP is a string or symbol naming one of the leaf operators in
`supertag-query-block--operators'.  The resulting sexp is passed
through `supertag-query-validate' so an arity mistake (e.g. the
wrong number of ARGS) surfaces the same error the query engine itself
would raise, instead of silently building a bad query.  This is the
pure assembly step used by both the interactive builder and its
tests."
  (let ((sexp (cons (if (stringp op) (intern op) op) args)))
    (supertag-query-validate sexp)
    sexp))

(defun supertag-query-block--combine-conditions (combinator expr next)
  "Return the sexp combining EXPR and NEXT with COMBINATOR.
COMBINATOR is \"and\"/\"or\" (a string) or the symbol `and'/`or'."
  (let ((sexp (list (if (stringp combinator) (intern combinator) combinator) expr next)))
    (supertag-query-validate sexp)
    sexp))

(defun supertag-query-block--build-condition ()
  "Interactively build one leaf query condition and return it as a sexp."
  (let ((op (supertag-query-block--completing-read-operator "Condition operator: ")))
    (pcase op
      ("tag" (supertag-query-block--make-condition op (supertag-query-block--read-tag-name)))
      ("property" (let ((key (supertag-query-block--read-property-name)))
                    (supertag-query-block--make-condition
                     op key (read-string (format "Value for property `%s': " key)))))
      ("term" (supertag-query-block--make-condition op (read-string "Search term: ")))
      ("after" (supertag-query-block--make-condition
                op (supertag-query-block--read-date "After date")))
      ("before" (supertag-query-block--make-condition
                 op (supertag-query-block--read-date "Before date")))
      ("between" (supertag-query-block--make-condition
                  op
                  (supertag-query-block--read-date "Start date")
                  (supertag-query-block--read-date "End date")))
      ("recent-days" (supertag-query-block--make-condition
                      op (read-number "Created within the last N days: " 7)))
      ("in-month" (supertag-query-block--make-condition
                   op (read-string "Month (YYYY-MM): "
                                   (format-time-string "%Y-%m"))))
      ("in-year" (supertag-query-block--make-condition
                  op (read-string "Year (YYYY): "
                                  (format-time-string "%Y"))))
      ((or "link" "reverse-link")
       (let ((reference (supertag-query-block--read-link-reference)))
         (message "Build the nested endpoint condition for %s" reference)
         (supertag-query-block--make-condition
          op reference (supertag-query-block--build-condition))))
      ((or "has-link" "has-reverse-link")
       (supertag-query-block--make-condition
        op (supertag-query-block--read-link-reference)))
      (_ (user-error "Unknown operator `%s'" op)))))

(defun supertag-query-block--present-built-query (expr)
  "Preview built query EXPR and offer copy/insert/run follow-up actions."
  (let* ((text (prin1-to-string expr))
         (action (completing-read
                  (format "Query: %s -- action: " text)
                  '("Copy to kill-ring" "Insert block" "Run now") nil t)))
    (pcase action
      ("Copy to kill-ring" (kill-new text) (message "Copied to kill-ring: %s" text))
      ("Insert block"
       (insert (format "#+BEGIN_SRC supertag-query-block :results raw\n%s\n#+END_SRC\n" text)))
      ("Run now" (pop-to-buffer (supertag-query-block--render-results expr))))
    expr))

;;;###autoload
(defun supertag-query-build ()
  "Interactively assemble an Supertag query S-expression.
Prompts for a leaf condition, including named Org link traversal,
then repeatedly offers to combine it with another condition using AND
or OR, and finally offers to wrap the whole thing in NOT.  Tag and
property names are completed from live data when possible.  When done,
previews the resulting S-expression and offers to copy it, insert it
as a block, or run it immediately."
  (interactive)
  (let ((expr (supertag-query-block--build-condition))
        (continue t))
    (while continue
      (let ((again (completing-read "Add another condition? "
                                     '("no" "and" "or") nil t nil nil "no")))
        (if (member again '("no" ""))
            (setq continue nil)
          (let ((next (supertag-query-block--build-condition)))
            (setq expr (supertag-query-block--combine-conditions again expr next))))))
    (when (y-or-n-p "Wrap the whole query in NOT? ")
      (setq expr (list 'not expr)))
    (supertag-query-block--present-built-query expr)))

;;; --- Quick reference -------------------------------------------------------

(defconst supertag-query-block--syntax-reference-text
  "Supertag Query Language -- Quick Reference
================================================

Combinators
  (and COND...)          all of COND... must match
  (or COND...)           any of COND... must match
  (not COND)             COND must not match

Leaf conditions
  (tag NAME)             nodes carrying tag NAME
  (PROPERTY VALUE)       custom Org property equals VALUE, e.g. (status \"doing\")
  (property KEY VALUE)   explicit property lookup, including reserved names
  (todo STATE...)        Org TODO state; multiple states match any (case-sensitive)
  (priority VALUE...)    Org priority, e.g. (priority \"A\")
  (term WORD)            substring search over node title/content
  (after DATE)           nodes dated after DATE
  (before DATE)          nodes dated before DATE
  (between START END)    nodes dated between START and END
  (recent-days N)        nodes created in the last N days
  (in-month \"YYYY-MM\")   nodes created in that calendar month
  (in-year \"YYYY\")       nodes created in that calendar year

Named Org link conditions
  (link REF QUERY)         source nodes linked to targets matching QUERY
  (exists-link REF QUERY)  alias of `link'
  (reverse-link REF QUERY) target nodes linked from sources matching QUERY
  (has-link REF)           source nodes with any Link instance
  (has-reverse-link REF)   target nodes with any incoming Link instance

REF is the relation name of a named Org text link, projected from Org.
`supertag-query-block--read-link-reference' completes these names from
projected relations.

Date formats (DATE / START / END above)
  \"now\"                 the current moment
  \"YYYY-MM-DD\"          an absolute date
  \"-7d\", \"+2w\", \"-1m\", \"1y\"
                        a relative offset: [+-]N followed by d/w/m/y
                        (day/week/month/year).  No sign means +
                        (the future); m is approximated as 30 days,
                        y as 365.25 days.

Use strings (double-quoted) for names and values: \"5\", not 5.
Property keys and values require strings.  Tag names and TODO states
also accept bare symbols.

Property shorthand takes exactly one string value; property names are
case-insensitive, values are exact matches.  Built-in operators take
precedence: (todo \"TODO\") reads the heading state, while
(property \"todo\" \"TODO\") reads the custom TODO property.
Unknown operator names are treated as property names, including typos.
Use explicit `property' for names that collide with any built-in operator.
`task' remains an alias of `todo'; `field' remains an alias of `property'.

Examples (simple to complex)
  (tag \"project\")
  (property \"status\" \"active\")
  (term \"meeting\")
  (and (tag \"task\") (not (property \"status\" \"done\")))
  (or (tag \"work\") (tag \"personal\"))
  (and (tag \"task\") (after \"-7d\"))
  (and (or (tag \"work\") (tag \"project\"))
       (not (property \"status\" \"completed\"))
       (after \"2025-01-01\"))

  (link work/tasks (property \"status\" \"blocked\"))
  (reverse-link work/tasks (tag \"project\"))
  (and (tag \"project\")
       (link work/tasks
             (and (tag \"task\") (property \"status\" \"blocked\"))))

See doc/query.md for the full reference, composition examples, where
queries can be used (babel blocks, dynamic blocks, the
guided builder), and troubleshooting."
  "Reference text shown by `supertag-query-describe-syntax'.
Kept in sync with doc/query.md by hand; doc/query.md is the fuller
version of this same content.")

;;;###autoload
(defun supertag-query-describe-syntax ()
  "Show a quick reference for the Supertag query language."
  (interactive)
  (let ((buf (get-buffer-create "*Supertag Query Syntax*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert supertag-query-block--syntax-reference-text)
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buf)))

;;; Dataset and entity read adapters

(defun supertag-view-api-list-entity-ids (query-spec)
  "Return entity IDs for QUERY-SPEC.

QUERY-SPEC is a plist describing the dataset, for example:
- (:type :tag :value \"foo\")
- (:type :tag :value \"foo\" :include-descendants t)
- (:type :nodes)
- (:type :tags)
- (:type :automations)

This function is UI-agnostic and read-only."
  (let ((type (plist-get query-spec :type)))
    (pcase type
      (:tag
       (let ((tag (plist-get query-spec :value)))
         (unless (and tag (stringp tag) (not (string-empty-p tag)))
           (error "Query :tag requires a non-empty :value string"))
         (supertag-query-node-ids-by-tag
          tag
          (plist-get query-spec :include-descendants))))
      ((or :nodes :tags :relations :embeds
           ;; Some query specs use singular names in UI layers; accept them here.
           :automation :automations
           :database :databases)
       (let ((type (pcase type
                     (:automation :automations)
                     (:database :databases)
                     (_ type))))
         (pcase type
           (:nodes (mapcar #'car (supertag-query-nodes)))
           (:tags (supertag-view-api-list-tag-ids))
           (:relations (mapcar (lambda (relation) (plist-get relation :id))
                               (supertag-query-relations)))
           (:automations (mapcar (lambda (automation) (plist-get automation :id))
                                 (supertag-query-automations)))
           ;; :embeds/:databases are legacy/non-canonical
           ;; collections; they contain no entities.
           (_ '()))))
      (_
       (error "Unsupported query type: %S" type)))))

(defun supertag-view-api-get-entity (type entity-id)
  "Return entity plist for TYPE and ENTITY-ID (read-only)."
  (unless (and entity-id (stringp entity-id) (not (string-empty-p entity-id)))
    (error "ENTITY-ID must be a non-empty string"))
  (let ((normalized
         (pcase type
           (:node :nodes)
           (:tag :tags)
           (:relation :relations)
           (:embed :embeds)
           (:automation :automations)
           (:database :databases)
           (_ type))))
    (pcase normalized
      (:nodes (supertag-query-node entity-id))
      (:tags (supertag-tag-get entity-id))
      (:relations (supertag-relation-get entity-id))
      (:automations
       (car (supertag-query-automations
             (lambda (automation)
               (equal (plist-get automation :id) entity-id)))))
      ;; :embeds/:databases are legacy/non-canonical collections.
      (_ nil))))

(defun supertag-view-api-get-entities (type entity-ids)
  "Return list of entities for TYPE and ENTITY-IDS.

This is a convenience function; callers can still batch on their own.
Entities that do not exist are skipped."
  (let (result)
    (dolist (entity-id entity-ids (nreverse result))
      (let ((entity (and entity-id (supertag-view-api-get-entity type entity-id))))
        (when entity
          (push entity result))))))

(defun supertag-view-api-node-property (node-id property-name)
  "Read PROPERTY-NAME for NODE-ID from its projected Org properties.

PROPERTY-NAME is a string (an Org property key)."
  (unless (and (stringp property-name) (not (string-empty-p property-name)))
    (error "PROPERTY-NAME must be a non-empty string"))
  (supertag-query-property-value node-id property-name))

(provide 'supertag-query)
;;; supertag-query.el ends here
