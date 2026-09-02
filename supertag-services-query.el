;;; supertag/services/query.el --- Query system for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This module is the read boundary for composed Supertag data.  Concrete
;; queries hide Store/index joins from UI consumers.

;;; Code:

(require 'cl-lib)
(require 'supertag-core-scan)
(require 'supertag-core-store)
(require 'supertag-board-ops)
(require 'supertag-ops-link-definition)
(require 'supertag-ops-relation)
(require 'supertag-ops-node)
(require 'supertag-ops-tag)
(require 'supertag-ops-field)
(require 'supertag-services-formula)

;;; --- Typed Link operators ---

(defun supertag-query-link--parse-binary (type args recursive-parser)
  "Parse a typed-Link operator with TYPE and two ARGS.
RECURSIVE-PARSER parses the nested query."
  (unless (= (length args) 2)
    (error "'%s' expects a Link reference and one nested query, got %S"
           type args))
  (list :type type :reference (car args)
        :child (funcall recursive-parser (cadr args))))

(defun supertag-query-link--parse-unary (type args _recursive-parser)
  "Parse a typed-Link operator with TYPE and one Link reference in ARGS."
  (unless (= (length args) 1)
    (error "'%s' expects exactly one Link reference, got %S" type args))
  (list :type type :reference (car args)))

(defun supertag-query-link--definition-id (ast)
  "Resolve the Link definition ID referenced by AST."
  (plist-get
   (supertag-link-definition-resolve (plist-get ast :reference))
   :id))

(defun supertag-query-link--unique (ids)
  "Return IDS without nil values or duplicates."
  (cl-delete-duplicates (delq nil ids) :test #'equal))

(defun supertag-query-link--execute-forward (ast recursive-executor)
  "Execute forward Link query AST using RECURSIVE-EXECUTOR."
  (let ((definition-id (supertag-query-link--definition-id ast)) result)
    (dolist (target-id (funcall recursive-executor (plist-get ast :child)))
      (setq result
            (nconc (supertag-link-sources definition-id target-id) result)))
    (supertag-query-link--unique result)))

(defun supertag-query-link--execute-reverse (ast recursive-executor)
  "Execute reverse Link query AST using RECURSIVE-EXECUTOR."
  (let ((definition-id (supertag-query-link--definition-id ast)) result)
    (dolist (source-id (funcall recursive-executor (plist-get ast :child)))
      (setq result
            (nconc (supertag-link-targets definition-id source-id) result)))
    (supertag-query-link--unique result)))

(defun supertag-query-link--execute-has-out (ast _recursive-executor)
  "Return nodes with an outgoing Link described by AST."
  (supertag-query-link--unique
   (mapcar (lambda (relation) (plist-get relation :from))
           (supertag-link-find (supertag-query-link--definition-id ast)))))

(defun supertag-query-link--execute-has-in (ast _recursive-executor)
  "Return nodes with an incoming Link described by AST."
  (supertag-query-link--unique
   (mapcar (lambda (relation) (plist-get relation :to))
           (supertag-link-find (supertag-query-link--definition-id ast)))))

;;; --- Query System ---

(defun supertag-query-node (node-id)
  "Return the Document Projection node for NODE-ID, or nil."
  (supertag-node-get node-id))

(defun supertag-query-tag-paths ()
  "Return sorted Semantic Tag path descriptors.
Each descriptor contains :id, :name, and :display-path."
  (let (result)
    (maphash
     (lambda (tag-id tag)
       (let ((tag (supertag--ensure-plist tag)))
         (push (list :id tag-id
                     :name (or (plist-get tag :name) tag-id)
                     :display-path (supertag-tag-display-path tag-id))
               result)))
     (supertag-store-get-collection :tags))
    (sort result
          (lambda (left right)
            (let ((left-path (plist-get left :display-path))
                  (right-path (plist-get right :display-path)))
              (if (equal left-path right-path)
                  (string< (plist-get left :id) (plist-get right :id))
                (string< left-path right-path)))))))

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
When INCLUDE-DESCENDANTS is non-nil, include transitive `:extends' children."
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

(defun supertag-query-tag-children (tag-id)
  "Return Semantic Tag IDs whose explicit parent is TAG-ID."
  (let (result)
    (maphash
     (lambda (id tag)
       (when (string= (plist-get (supertag--ensure-plist tag) :extends) tag-id)
         (push id result)))
     (supertag-store-get-collection :tags))
    result))

(defun supertag-query-field-definition-ids ()
  "Return sorted global field definition IDs."
  (let (ids)
    (maphash
     (lambda (fid _def) (push fid ids))
     (supertag-store-get-collection :field-definitions))
    (sort ids #'string<)))

(defun supertag-query-field-definitions ()
  "Return global field definitions as (id . definition) pairs."
  (let (result)
    (maphash
     (lambda (fid def)
       (push (cons fid def) result))
     (supertag-store-get-collection :field-definitions))
    result))

(defun supertag-query-tag-field-associations (tag-id)
  "Return TAG-ID's global field association entries."
  (gethash tag-id (supertag-store-get-collection :tag-field-associations)))

(defun supertag-query-relations (&optional filter)
  "Return all relations, optionally filtered by FILTER predicate."
  (let (result)
    (maphash
     (lambda (_id relation)
       (when (or (null filter) (funcall filter relation))
         (push relation result)))
     (supertag-store-get-collection :relations))
    result))

(defun supertag-query-resolved-fields (tag-id)
  "Return inherited field definitions resolved for TAG-ID."
  (supertag-tag-get-all-fields tag-id))

(defun supertag-query-field-value (node-id tag-id field-name &optional raw-p)
  "Return NODE-ID's FIELD-NAME value in TAG-ID's resolved schema.
When RAW-P is non-nil, return the stored value without schema default."
  (if raw-p
      (supertag-field-get node-id tag-id field-name)
    (supertag-field-get-with-default node-id tag-id field-name)))

(defun supertag-query-relations-from (entity-id &optional type kind)
  "Return relations from ENTITY-ID, optionally filtered by TYPE and KIND."
  (supertag-relation-find-by-from entity-id type kind))

(defun supertag-query-relations-to (entity-id &optional type kind)
  "Return relations to ENTITY-ID, optionally filtered by TYPE and KIND."
  (supertag-relation-find-by-to entity-id type kind))

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
  (let* ((relations (supertag-query-relations-from node-id :node-tag))
         (relation-tags (mapcar (lambda (relation) (plist-get relation :to))
                                relations))
         (node (supertag-query-node node-id))
         (node-tags (and node (plist-get node :tags))))
    (cl-remove-if-not
     #'stringp
     (cl-delete-duplicates (append relation-tags (or node-tags '()))
                           :test #'equal))))

(defun supertag-query-node-detail (node-id)
  "Return the composed node detail needed by node-oriented views."
  (when-let* ((node (supertag-query-node node-id)))
    (let ((tag-ids (supertag-query-node-tags node-id))
          fields)
      (dolist (tag-id tag-ids)
        (dolist (field-def (ignore-errors
                             (supertag-query-resolved-fields tag-id)))
          (when-let* ((field-name (plist-get field-def :name)))
            (push (list :tag-id tag-id
                        :field-def field-def
                        :value (supertag-query-field-value
                                node-id tag-id field-name))
                  fields))))
      (setq fields (nreverse fields))
      (let* ((refs-to (mapcar (lambda (relation) (plist-get relation :to))
                              (supertag-query-relations-from
                               node-id :reference)))
             (refs-from (mapcar (lambda (relation) (plist-get relation :from))
                                (supertag-query-relations-to
                                 node-id :reference))))
        (list :id node-id
              :node node
              :tags tag-ids
              :fields fields
              :refs-to refs-to
              :refs-from refs-from
              :field-count (length fields)
              :ref-count (+ (length refs-to) (length refs-from)))))))

(defun supertag-query-board-detail (board-id)
  "Return BOARD-ID with placed node details and their induced relations."
  (when-let* ((board (supertag-board-get board-id)))
    (let ((placements (plist-get board :node-placements))
          nodes)
      (dolist (placement placements)
        (push (list :id (car placement)
                    :placement (cdr placement)
                    :detail (supertag-query-node-detail (car placement)))
              nodes))
      (list :board board
            :nodes (nreverse nodes)
            :relations (supertag-query-relations-among
                        (mapcar #'car placements))))))

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

;;; --- S-expression Query Engine (User-facing) ---
;; All simple API queries have been moved to supertag-store.el index functions

(defun supertag-query-nodes (&optional filter)
  "Query all nodes in the store with an optional filter.
FILTER is an optional function that receives (id node-data) and returns t if the node should be included.
Returns a list of (id . node-data) pairs."
  (supertag-query '(:nodes) filter))



;;; --- S-expression Query Engine ---
;; This is the new high-performance query engine that replaces the old supertag-query.el
;; It uses indexes for O(1) lookups instead of O(n) table scans

(require 'cl-lib)

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

(defun supertag-query-fields (query-sexp)
  "Return field keys referenced by QUERY-SEXP, for table headers."
  (supertag-query--get-fields-from-ast
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
        (error "'sort-by' operator expects a field key and an optional asc/desc order, but got %S" args))
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
        (error "'%s' operator expects exactly one field key, but got %S" op args))
      `(:type ,op :key ,(if (stringp (car args)) (car args)
                          (symbol-name (car args)))))
     ((eq op 'count)
      (unless (null args)
        (error "'count' operator takes no arguments, but got %S" args))
      '(:type count :key nil))
     ((eq op 'group-by)
      (unless (= (length args) 1)
        (error "'group-by' operator expects exactly one field key, but got %S" args))
      `(:type group-by :key ,(if (stringp (car args)) (car args)
                                 (symbol-name (car args)))))
     ((eq op 'task)
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
     ((eq op 'field)
      (unless (= (length args) 2)
        (error "'field' operator expects exactly two arguments, but got %S" args))
      `(:type field :key ,(if (stringp (car args)) (car args) (symbol-name (car args)))
              :value ,(if (stringp (cadr args)) (cadr args) (symbol-name (cadr args)))))
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

     ((eq ast-type 'field)
      (supertag-query--find-nodes-by-field-indexed (plist-get ast :key) (plist-get ast :value)))

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
   (t (supertag-query-field-value node-id nil key t))))

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
      (let* ((group-field (and groups (plist-get (car groups) :key)))
             (aggregate (car aggregates))
             (agg-type (plist-get aggregate :type))
             (agg-key (plist-get aggregate :key)))
        (if group-field
            (mapcar
             (lambda (entry)
               (cons (car entry)
                     (supertag-query--aggregate-values
                      (cdr entry) agg-type agg-key)))
             (supertag-query--group-values sorted group-field))
          (supertag-query--aggregate-values
           (mapcar #'supertag-query-node sorted) agg-type agg-key))))))

(defun supertag-query-modifiers (query-sexp)
  "Return the result modifiers of QUERY-SEXP, in order."
  (supertag-query--ast-modifiers
   (supertag-query--parse-sexp query-sexp)))

(defun supertag-query--find-nodes-by-field-indexed (field-name value)
  "Find nodes by field using indexed lookup.
This is much faster than the old approach that scanned the entire link table."
  (let ((matching-nodes nil)
        (fid (supertag-field-resolve-id nil field-name))
        (values (supertag-store-get-collection :field-values)))
    (when (and fid (hash-table-p values))
      (maphash
       (lambda (node-id table)
         (when (and (hash-table-p table)
                    (equal (gethash fid table) value))
           (push node-id matching-nodes)))
       values))
    (nreverse matching-nodes)))

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

(defun supertag-query--get-fields-from-ast (ast)
  "Extract field keys from the query AST.
Used for generating table headers in Org Babel output."
  (let ((fields '()))
    (cl-labels ((walk (sub-ast)
                  (let ((type (plist-get sub-ast :type)))
                    (cond
                     ((member type '(and or))
                      (dolist (child (plist-get sub-ast :children)) (walk child)))
                     ((eq type 'not)
                      (dolist (child (plist-get sub-ast :children)) (walk child)))
                     ((eq type 'field)
                      (push (plist-get sub-ast :key) fields))
                     ((plist-get sub-ast :child)
                      (walk (plist-get sub-ast :child)))))))
      (walk ast))
    (cl-delete-duplicates fields :test #'string=)))

(provide 'supertag-services-query)
