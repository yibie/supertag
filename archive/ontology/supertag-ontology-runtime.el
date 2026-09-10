;;; supertag-ontology-runtime.el --- Live Store snapshots and ontology bindings. -*- lexical-binding: t; -*-

;;; Commentary:
;; The runtime boundary reads the live Supertag Store and owns only control
;; metadata: logical/runtime bindings and module provenance.  Runtime Schema
;; remains in the existing Tag, Field and Link Definition collections.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-schema-authority)
(require 'supertag-ontology-model)

(defcustom supertag-ontology-runtime-tags-provider nil
  "Optional function returning live runtime Tag definitions."
  :type '(choice (const nil) function))
(defcustom supertag-ontology-runtime-fields-provider nil
  "Optional function returning live runtime Field definitions."
  :type '(choice (const nil) function))
(defcustom supertag-ontology-runtime-associations-provider nil
  "Optional function returning live Tag/Field associations."
  :type '(choice (const nil) function))
(defcustom supertag-ontology-runtime-links-provider nil
  "Optional function returning live runtime Link Definitions."
  :type '(choice (const nil) function))

(defconst supertag-ontology-runtime--legacy-state-key :ontology-control-plane)

(defun supertag-ontology-runtime--legacy-table (slot)
  "Return v4 control-plane table SLOT, when present."
  (let ((state (and (boundp 'supertag--store)
                    (hash-table-p supertag--store)
                    (gethash supertag-ontology-runtime--legacy-state-key
                             supertag--store))))
    (and (listp state) (plist-get state slot))))


(defun supertag-ontology-runtime--mark-storage (record storage)
  "Return copied RECORD annotated with STORAGE origin."
  (when record
    (plist-put (copy-tree record) :control-storage storage)))

(defun supertag-ontology-runtime--legacy-binding-get (module kind key)
  (when-let ((table (supertag-ontology-runtime--legacy-table :bindings)))
    (supertag-ontology-runtime--mark-storage
     (gethash (supertag-ontology-runtime-binding-key module kind key) table)
     :legacy)))

(defun supertag-ontology-runtime-binding-key (module kind key)
  "Return the durable identifier for MODULE KIND KEY."
  (format "%s|%s|%s" module kind key))

(defun supertag-ontology-runtime-binding-get (module kind key)
  "Return the Store-owned binding for MODULE KIND KEY."
  (or
   (supertag-ontology-runtime--mark-storage
    (supertag-store-get-entity
     :ontology-bindings
     (supertag-ontology-runtime-binding-key module kind key))
    :canonical)
   (supertag-ontology-runtime--legacy-binding-get module kind key)))

(defun supertag-ontology-runtime-binding-put (record)
  "Persist binding RECORD through the Store transaction seam."
  (let ((id (supertag-ontology-runtime-binding-key
             (plist-get record :module)
             (plist-get record :kind)
             (plist-get record :key))))
    (supertag-store-put-entity :ontology-bindings id (copy-tree record))))

(defun supertag-ontology-runtime-binding-delete (module kind key)
  "Delete the binding for MODULE KIND KEY."
  (supertag-store-remove-entity
   :ontology-bindings
   (supertag-ontology-runtime-binding-key module kind key)))

(defun supertag-ontology-runtime-bindings (&optional module)
  "Return all bindings, optionally restricted to MODULE.
New canonical bindings override compatible v4 control-plane records."
  (let ((seen (make-hash-table :test #'equal)) records)
    (maphash
     (lambda (id record)
       (when (or (null module) (equal module (plist-get record :module)))
         (puthash id t seen)
         (push (supertag-ontology-runtime--mark-storage record :canonical) records)))
     (supertag-store-get-collection :ontology-bindings))
    (when-let ((legacy (supertag-ontology-runtime--legacy-table :bindings)))
      (maphash
       (lambda (id record)
         (when (and (not (gethash id seen))
                    (or (null module)
                        (equal module (plist-get record :module))))
           (push (supertag-ontology-runtime--mark-storage record :legacy) records)))
       legacy))
    (sort records
          (lambda (a b)
            (string< (or (plist-get a :logical-id) "")
                     (or (plist-get b :logical-id) ""))))))

(defun supertag-ontology-runtime-module-get (module)
  "Return deployment provenance for MODULE."
  (or
   (supertag-ontology-runtime--mark-storage
    (supertag-store-get-entity :ontology-modules (format "%s" module))
    :canonical)
   (when-let ((legacy (supertag-ontology-runtime--legacy-table :modules)))
     (supertag-ontology-runtime--mark-storage
      (gethash module legacy) :legacy))))

(defun supertag-ontology-runtime-module-put (record)
  "Persist module provenance RECORD through the Store transaction seam."
  (supertag-store-put-entity
   :ontology-modules (format "%s" (plist-get record :module))
   (copy-tree record)))

(defun supertag-ontology-runtime-modules ()
  "Return all deployed module provenance records."
  (let ((seen (make-hash-table :test #'equal)) records)
    (maphash
     (lambda (id record)
       (puthash id t seen)
       (push (supertag-ontology-runtime--mark-storage record :canonical)
             records))
     (supertag-store-get-collection :ontology-modules))
    (when-let ((legacy (supertag-ontology-runtime--legacy-table :modules)))
      (maphash
       (lambda (module record)
         (unless (gethash (format "%s" module) seen)
           (push (supertag-ontology-runtime--mark-storage record :legacy)
                 records)))
       legacy))
    (sort records
          (lambda (a b)
            (string< (format "%s" (plist-get a :module))
                     (format "%s" (plist-get b :module)))))))

(defun supertag-ontology-runtime-authority (kind runtime-id)
  "Return ontology authority metadata for KIND and RUNTIME-ID."
  (cl-find-if
   (lambda (record)
     (and (eq kind (plist-get record :kind))
          (equal runtime-id (plist-get record :runtime-id))))
   (supertag-ontology-runtime-bindings)))

(setq supertag-schema-authority-provider-function
      #'supertag-ontology-runtime-authority)

(defun supertag-ontology-runtime--collection-values (collection)
  "Return COLLECTION as (id . value) pairs."
  (cond
   ((hash-table-p collection)
    (let (values)
      (maphash (lambda (key value) (push (cons key value) values)) collection)
      (nreverse values)))
   ((listp collection)
    (mapcar (lambda (value)
              (cons (or (plist-get value :id)
                        (plist-get value :tag-id)
                        (plist-get value :field-id)
                        (plist-get value :link-definition-id))
                    value))
            collection))
   (t nil)))

(defun supertag-ontology-runtime--provided (provider collection)
  "Return PROVIDER output, or live Store COLLECTION."
  (if (functionp provider)
      (funcall provider)
    (supertag-store-get-collection collection)))

(defun supertag-ontology-runtime--id (key value)
  (or (and (stringp key) key)
      (plist-get value :id)
      (plist-get value :tag-id)
      (plist-get value :field-id)
      (plist-get value :link-definition-id)))

(defun supertag-ontology-runtime--label (value)
  (or (plist-get value :label)
      (plist-get value :name)
      (plist-get value :title)))

(defun supertag-ontology-runtime--association-field-ids (entries)
  "Return ordered Field IDs from association ENTRIES."
  (delq nil
        (mapcar (lambda (entry)
                  (cond
                   ((stringp entry) entry)
                   ((listp entry) (plist-get entry :field-id))))
                (or entries '()))))

(defun supertag-ontology-runtime--association-map (raw)
  "Normalize RAW Tag/Field associations into tag-id -> field-id list."
  (let ((table (make-hash-table :test #'equal)))
    (cond
     ((hash-table-p raw)
      (maphash
       (lambda (tag-id entries)
         (puthash tag-id
                  (supertag-ontology-runtime--association-field-ids entries)
                  table))
       raw))
     ((listp raw)
      (dolist (pair raw)
        (when (consp pair)
          (puthash (car pair)
                   (supertag-ontology-runtime--association-field-ids (cdr pair))
                   table)))))
    table))

(defun supertag-ontology-runtime--normalize-field (pair)
  (let ((value (cdr pair)))
    (list :kind :field
          :runtime-id (supertag-ontology-runtime--id (car pair) value)
          :label (supertag-ontology-runtime--label value)
          ;; Stored types are canonical keywords, but adopted or hand-written
          ;; records may carry symbol spellings such as `text'.  Normalize so
          ;; the planner compares like with like: an identical redeploy is
          ;; empty, and a real type change is visible.
          :type (supertag-ontology-model--normalize-field-type
                 (or (plist-get value :type) (plist-get value :field-type)))
          :options (copy-sequence (or (plist-get value :options) nil))
          :required (and (plist-get value :required) t)
          :default (plist-get value :default)
          :raw value)))

(defun supertag-ontology-runtime--string-tokens (value)
  "Return the string members of VALUE as a sorted, deduplicated list."
  (and (proper-list-p value)
       (sort (delete-dups (cl-remove-if-not #'stringp (copy-sequence value)))
             #'string<)))

(defun supertag-ontology-runtime--normalize-type (pair association-map)
  (let* ((value (cdr pair))
         (runtime-id (supertag-ontology-runtime--id (car pair) value)))
    (list :kind :type
          :runtime-id runtime-id
          :label (supertag-ontology-runtime--label value)
          :extends (or (plist-get value :extends)
                       (plist-get value :parent-tag-id))
          :fields (copy-sequence (gethash runtime-id association-map))
          ;; Occurrence tokens.  `:aliases' is the Tag's full alias slot,
          ;; which the Tag ops layer owns (it adds id, name and display
          ;; path itself, and users may add tokens by hand).
          ;; `:managed-aliases' are the tokens the ontology adapter recorded
          ;; as its own, so the planner can tell a dropped declaration from
          ;; a user-added alias.  Every record the Tag ops layer or the
          ;; stable-id migration has written carries an alias slot;
          ;; `:aliases-known-p' is nil only for records that were never
          ;; normalized by that layer, whose token set is not reconciled.
          :aliases (supertag-ontology-runtime--string-tokens
                    (plist-get value :aliases))
          :aliases-known-p (and (plist-member value :aliases) t)
          :managed-aliases (supertag-ontology-runtime--string-tokens
                            (plist-get value :ontology-aliases))
          :raw value)))

(defun supertag-ontology-runtime--normalize-link (pair)
  (let ((value (cdr pair)))
    (list :kind :link
          :runtime-id (supertag-ontology-runtime--id (car pair) value)
          :label (supertag-ontology-runtime--label value)
          :inverse-label (or (plist-get value :inverse-label)
                             (plist-get value :inverse-name))
          :from-runtime-id (or (plist-get value :from-tag-id)
                               (plist-get value :from-type-id))
          :to-runtime-id (or (plist-get value :to-tag-id)
                             (plist-get value :to-type-id))
          :from-cardinality (or (plist-get value :from-cardinality) :many)
          :to-cardinality (or (plist-get value :to-cardinality) :many)
          :raw value)))

(defun supertag-ontology-runtime--normalize-behavior (kind pair)
  "Normalize stored Function, Action or Policy PAIR of KIND."
  (let ((value (copy-tree (cdr pair))))
    (setq value (plist-put value :kind kind))
    (setq value (plist-put value :runtime-id
                           (or (plist-get value :runtime-id) (car pair))))
    (setq value (plist-put value :raw (copy-tree (cdr pair))))
    value))

(defun supertag-ontology-runtime-snapshot ()
  "Build a normalized snapshot directly from the live Supertag Store."
  (let* ((fields-raw
          (supertag-ontology-runtime--provided
           supertag-ontology-runtime-fields-provider :field-definitions))
         (types-raw
          (supertag-ontology-runtime--provided
           supertag-ontology-runtime-tags-provider :tags))
         (associations-raw
          (supertag-ontology-runtime--provided
           supertag-ontology-runtime-associations-provider
           :tag-field-associations))
         (links-raw
          (supertag-ontology-runtime--provided
           supertag-ontology-runtime-links-provider :link-definitions))
         (functions-raw
          (supertag-store-get-collection :ontology-functions))
         (actions-raw
          (supertag-store-get-collection :ontology-actions))
         (policies-raw
          (supertag-store-get-collection :ontology-policies))
         (association-map
          (supertag-ontology-runtime--association-map associations-raw)))
    (list :fields
          (mapcar #'supertag-ontology-runtime--normalize-field
                  (supertag-ontology-runtime--collection-values fields-raw))
          :types
          (mapcar (lambda (pair)
                    (supertag-ontology-runtime--normalize-type
                     pair association-map))
                  (supertag-ontology-runtime--collection-values types-raw))
          :links
          (mapcar #'supertag-ontology-runtime--normalize-link
                  (supertag-ontology-runtime--collection-values links-raw))
          :functions
          (mapcar (lambda (pair)
                    (supertag-ontology-runtime--normalize-behavior
                     :function pair))
                  (supertag-ontology-runtime--collection-values functions-raw))
          :actions
          (mapcar (lambda (pair)
                    (supertag-ontology-runtime--normalize-behavior
                     :action pair))
                  (supertag-ontology-runtime--collection-values actions-raw))
          :policies
          (mapcar (lambda (pair)
                    (supertag-ontology-runtime--normalize-behavior
                     :policy pair))
                  (supertag-ontology-runtime--collection-values policies-raw))
          :bindings (supertag-ontology-runtime-bindings)
          :modules (supertag-ontology-runtime-modules))))

(defun supertag-ontology-runtime-find (snapshot kind runtime-id)
  "Find KIND entity identified by RUNTIME-ID in SNAPSHOT."
  (cl-find runtime-id
           (plist-get snapshot
                      (pcase kind
                        (:field :fields) (:type :types) (:link :links)
                        (:function :functions) (:action :actions)
                        (:policy :policies)))
           :key (lambda (x) (plist-get x :runtime-id)) :test #'equal))

(defun supertag-ontology-runtime-find-label (snapshot kind label)
  "Return runtime entities of KIND whose label equals LABEL."
  (cl-remove-if-not
   (lambda (x) (equal label (plist-get x :label)))
   (plist-get snapshot
              (pcase kind
                (:field :fields) (:type :types) (:link :links)
                (:function :functions) (:action :actions)
                (:policy :policies)))))

(defun supertag-ontology-runtime--canonical-entity (entity)
  "Return semantic runtime data for ENTITY."
  (pcase (plist-get entity :kind)
    (:field
     (list :kind :field :runtime-id (plist-get entity :runtime-id)
           :label (plist-get entity :label) :type (plist-get entity :type)
           :options (sort (copy-sequence (or (plist-get entity :options) '()))
                          (lambda (a b) (string< (format "%s" a)
                                                (format "%s" b))))
           :required (and (plist-get entity :required) t)
           :default (plist-get entity :default)))
    (:type
     (list :kind :type :runtime-id (plist-get entity :runtime-id)
           :label (plist-get entity :label) :extends (plist-get entity :extends)
           :fields (sort (copy-sequence (or (plist-get entity :fields) '()))
                         #'string<)
           :aliases (copy-sequence (or (plist-get entity :aliases) '()))
           :managed-aliases (copy-sequence
                             (or (plist-get entity :managed-aliases) '()))))
    (:link
     (list :kind :link :runtime-id (plist-get entity :runtime-id)
           :label (plist-get entity :label)
           :inverse-label (plist-get entity :inverse-label)
           :from-runtime-id (plist-get entity :from-runtime-id)
           :to-runtime-id (plist-get entity :to-runtime-id)
           :from-cardinality (plist-get entity :from-cardinality)
           :to-cardinality (plist-get entity :to-cardinality)))
    (:function
     (list :kind :function :runtime-id (plist-get entity :runtime-id)
           :module (plist-get entity :module) :key (plist-get entity :key)
           :label (plist-get entity :label)
           :description (plist-get entity :description)
           :subject-type-id (plist-get entity :subject-type-id)
           :parameters (copy-tree (plist-get entity :parameters))
           :returns (copy-tree (plist-get entity :returns))
           :implementation (plist-get entity :implementation)
           :llm-tool (and (plist-get entity :llm-tool) t)
           :tool-name (plist-get entity :tool-name)
           :tool-description (plist-get entity :tool-description)))
    (:action
     (list :kind :action :runtime-id (plist-get entity :runtime-id)
           :module (plist-get entity :module) :key (plist-get entity :key)
           :label (plist-get entity :label)
           :description (plist-get entity :description)
           :subject-type-id (plist-get entity :subject-type-id)
           :parameters (copy-tree (plist-get entity :parameters))
           :preconditions (copy-tree (plist-get entity :preconditions))
           :effects (copy-tree (plist-get entity :effects))
           :confirmation (plist-get entity :confirmation)
           :llm-tool (and (plist-get entity :llm-tool) t)
           :tool-name (plist-get entity :tool-name)
           :tool-description (plist-get entity :tool-description)))
    (:policy
     (list :kind :policy :runtime-id (plist-get entity :runtime-id)
           :module (plist-get entity :module) :key (plist-get entity :key)
           :label (plist-get entity :label)
           :description (plist-get entity :description)
           :action-id (plist-get entity :action-id)
           :actors (copy-tree (plist-get entity :actors))))))

(defun supertag-ontology-runtime-hash (&optional snapshot)
  "Return a semantic hash for SNAPSHOT or the current live Store."
  (let* ((snapshot (or snapshot (supertag-ontology-runtime-snapshot)))
         (entities
          (append (plist-get snapshot :fields)
                  (plist-get snapshot :types)
                  (plist-get snapshot :links)
                  (plist-get snapshot :functions)
                  (plist-get snapshot :actions)
                  (plist-get snapshot :policies)))
         (canonical
          (sort (mapcar #'supertag-ontology-runtime--canonical-entity entities)
                (lambda (a b)
                  (string< (format "%s/%s" (plist-get a :kind)
                                   (plist-get a :runtime-id))
                           (format "%s/%s" (plist-get b :kind)
                                   (plist-get b :runtime-id))))))
         (bindings
          (sort
           (mapcar (lambda (binding)
                     (list :logical-id (plist-get binding :logical-id)
                           :runtime-id (plist-get binding :runtime-id)))
                   (plist-get snapshot :bindings))
           (lambda (a b)
             (string< (or (plist-get a :logical-id) "")
                      (or (plist-get b :logical-id) "")))))
         (modules
          (sort
           (mapcar (lambda (record)
                     (list :module (plist-get record :module)
                           :version (plist-get record :version)
                           :model-hash (plist-get record :model-hash)
                           :source-file (plist-get record :source-file)))
                   (plist-get snapshot :modules))
           (lambda (a b)
             (string< (format "%s" (plist-get a :module))
                      (format "%s" (plist-get b :module)))))))
    (secure-hash 'sha256
                 (prin1-to-string (list canonical bindings modules)))))

(provide 'supertag-ontology-runtime)
;;; supertag-ontology-runtime.el ends here
