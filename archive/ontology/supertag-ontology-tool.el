;;; supertag-ontology-tool.el --- Policy-aware LLM Tool generation -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Generates a transient, provider-neutral tool catalog from deployed Ontology
;; Function, Action, and Policy contracts.  No arbitrary `defun' is scanned and
;; no tool descriptor, proposal, or catalog is persisted.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-ontology-action)
(require 'supertag-ontology-contract)
(require 'supertag-ontology-function)
(require 'supertag-ontology-policy)

(define-error 'supertag-ontology-tool-error
  "Ontology LLM Tool operation failed")
(define-error 'supertag-ontology-tool-stale
  "Ontology LLM Tool is stale" 'supertag-ontology-tool-error)
(define-error 'supertag-ontology-tool-confirmation-required
  "Ontology LLM Tool requires confirmation" 'supertag-ontology-tool-error)

(defgroup supertag-ontology-tool nil
  "Provider-neutral tools generated from deployed Ontology contracts."
  :group 'supertag)

(defcustom supertag-ontology-tool-name-max-length 64
  "Maximum generated tool name length."
  :type 'integer
  :group 'supertag-ontology-tool)

(defconst supertag-ontology-tool--absent
  (make-symbol "supertag-ontology-tool-absent"))

(defun supertag-ontology-tool--llm-actor (actor)
  "Normalize ACTOR and require the closed `:llm' actor class."
  (let ((record (supertag-ontology-policy-normalize-actor actor)))
    (unless (eq (plist-get record :kind) :llm)
      (signal 'supertag-ontology-tool-error
              (list "LLM Tool catalogs require actor kind :llm")))
    record))

(defun supertag-ontology-tool--slug (value)
  "Return a conservative ASCII tool-name slug for VALUE."
  (let* ((text (downcase (format "%s" (or value "tool"))))
         (slug (replace-regexp-in-string "[^a-z0-9_-]+" "_" text)))
    (setq slug (replace-regexp-in-string "_+" "_" slug))
    (setq slug (replace-regexp-in-string "\\`[_-]+\\|[_-]+\\'" "" slug))
    (unless (string-match-p "\\`[a-z]" slug)
      (setq slug (concat "tool_" slug)))
    (if (string-empty-p slug) "tool" slug)))

(defun supertag-ontology-tool--base-name (definition)
  "Return the requested base name for deployed DEFINITION."
  (or (plist-get definition :tool-name)
      (format "%s_%s"
              (or (plist-get definition :module) "ontology")
              (or (plist-get definition :key)
                  (plist-get definition :runtime-id)))))

(defconst supertag-ontology-tool--base-name-regexp
  "\\`[A-Za-z][A-Za-z0-9_-]*\\'"
  "Valid explicit base-name syntax for generated tools.")

(defun supertag-ontology-tool--definition-error (definition)
  "Return fail-closed exposure error for deployed DEFINITION, or nil."
  (let ((runtime-id (plist-get definition :runtime-id))
        (logical-id (plist-get definition :logical-id))
        (contract-hash (plist-get definition :contract-hash))
        (name (plist-get definition :tool-name))
        (description (plist-get definition :tool-description)))
    (cond
     ((not (and (stringp runtime-id) (not (string-empty-p runtime-id))))
      :invalid-runtime-id)
     ((not (and (stringp logical-id) (not (string-empty-p logical-id))))
      :invalid-logical-id)
     ((not (and (stringp contract-hash)
                (not (string-empty-p contract-hash))))
      :invalid-contract-hash)
     ((and name
           (not (and (stringp name)
                     (> (length name) 0)
                     (<= (length name) 48)
                     (string-match-p
                      supertag-ontology-tool--base-name-regexp name))))
      :invalid-tool-name)
     ((and description (not (stringp description)))
      :invalid-tool-description)
     (t nil))))

(defun supertag-ontology-tool--fingerprint
    (kind definition &optional decision)
  "Return a stable tool fingerprint for KIND, DEFINITION, and DECISION."
  (secure-hash
   'sha256
   (prin1-to-string
    (list :kind kind
          :runtime-id (plist-get definition :runtime-id)
          :logical-id (plist-get definition :logical-id)
          :contract-hash (plist-get definition :contract-hash)
          :llm-tool (and (plist-get definition :llm-tool) t)
          :tool-name (plist-get definition :tool-name)
          :tool-description (plist-get definition :tool-description)
          :decision (and decision (plist-get decision :decision))
          :policy-id (and decision (plist-get decision :policy-id))
          :policy-contract-hash
          (and decision (plist-get decision :policy-contract-hash))))))

(defun supertag-ontology-tool--name (kind definition fingerprint)
  "Return a versioned tool name for KIND and DEFINITION using FINGERPRINT."
  (let* ((prefix (pcase kind
                   (:function "st_fn_")
                   (:action "st_act_")
                   (_ (signal 'supertag-ontology-tool-error
                              (list (format "Unsupported tool kind %S" kind))))))
         (suffix (concat "_" (substring fingerprint 0 10)))
         (minimum (+ (length prefix) 1 (length suffix))))
    (when (< supertag-ontology-tool-name-max-length minimum)
      (signal 'supertag-ontology-tool-error
              (list (format
                     "Tool name limit %d is too small; %s tools need at least %d characters"
                     supertag-ontology-tool-name-max-length kind minimum))))
    (let* ((base (supertag-ontology-tool--slug
                  (supertag-ontology-tool--base-name definition)))
           (available (- supertag-ontology-tool-name-max-length
                         (length prefix) (length suffix))))
      (concat prefix (substring base 0 (min available (length base))) suffix))))

(defun supertag-ontology-tool--json-object (&rest pairs)
  "Return a JSON object alist from non-nil PAIRS.
Each element of PAIRS is a `(KEY . VALUE)' cell."
  (cl-remove-if (lambda (pair) (eq (cdr pair) supertag-ontology-tool--absent))
                pairs))

(defun supertag-ontology-tool--type-schema (type &optional options)
  "Return provider-neutral JSON Schema for contract TYPE and OPTIONS."
  (pcase type
    (:any '(("description" . "Any JSON-compatible value")))
    (:string '(("type" . "string")))
    (:number '(("type" . "number")))
    (:integer '(("type" . "integer")))
    (:boolean '(("type" . "boolean")))
    (:date '(("type" . "string") ("format" . "date")))
    (:timestamp '(("type" . "string") ("format" . "date-time")))
    (:url '(("type" . "string") ("format" . "uri")))
    (:email '(("type" . "string") ("format" . "email")))
    (:tag '(("type" . "string")
            ("x-supertag-kind" . "tag-id")))
    (:options
     (supertag-ontology-tool--json-object
      '("type" . "string")
      (cons "enum" (if options
                       (vconcat (copy-sequence options))
                     supertag-ontology-tool--absent))))
    (:node-reference
     (supertag-ontology-tool--json-object
      (cons "oneOf"
            (vector
             '(("type" . "string")
               ("x-supertag-kind" . "node-id"))
             '(("type" . "array")
               ("items" . (("type" . "string")
                            ("x-supertag-kind" . "node-id")))
               ("uniqueItems" . t))))))
    (`(:maybe ,inner)
     (supertag-ontology-tool--json-object
      (cons "anyOf"
            (vector (supertag-ontology-tool--type-schema inner options)
                    '(("type" . "null"))))))
    (`(:list ,inner)
     (supertag-ontology-tool--json-object
      '("type" . "array")
      (cons "items" (supertag-ontology-tool--type-schema inner options))))
    (`(:type ,key)
     (supertag-ontology-tool--json-object
      '("type" . "string")
      '("x-supertag-kind" . "node-id")
      (cons "x-supertag-node-type" (format "%s" key))))
    (_
     (signal 'supertag-ontology-tool-error
             (list (format "Cannot generate JSON Schema for type %S" type))))))

(defun supertag-ontology-tool--parameter-schema (parameter)
  "Return JSON Schema for normalized contract PARAMETER."
  (let* ((schema
          (copy-tree
           (supertag-ontology-tool--type-schema
            (plist-get parameter :type)
            (plist-get parameter :options))))
         (description (plist-get parameter :description))
         (sensitive (plist-get parameter :sensitive)))
    (when description
      (setq schema (append schema (list (cons "description" description)))))
    (when sensitive
      (setq schema
            (append schema
                    (list '("writeOnly" . t)
                          '("x-supertag-sensitive" . t)))))
    (when (and (plist-get parameter :has-default) (not sensitive))
      (setq schema
            (append schema
                    (list
                     (cons "default"
                           (supertag-ontology-tool--typed-json-value
                            (plist-get parameter :default)
                            (plist-get parameter :type)))))))
    schema))

(defun supertag-ontology-tool--arguments-schema (parameters)
  "Return JSON Schema for ordered contract PARAMETERS."
  (let (properties required)
    (dolist (parameter parameters)
      (let ((name (symbol-name (plist-get parameter :name))))
        (push (cons name
                    (supertag-ontology-tool--parameter-schema parameter))
              properties)
        (when (plist-get parameter :required)
          (push name required))))
    (supertag-ontology-tool--json-object
     '("type" . "object")
     '("additionalProperties" . :json-false)
     (cons "properties" (nreverse properties))
     (cons "required" (if required
                           (vconcat (nreverse required))
                         supertag-ontology-tool--absent)))))

(defun supertag-ontology-tool--subject-schema (definition)
  "Return subject node schema for deployed DEFINITION."
  (let* ((type-id (plist-get definition :subject-type-id))
         (tag (and type-id (supertag-store-get-entity :tags type-id)))
         (label (or (plist-get tag :name) type-id "required Type")))
    (supertag-ontology-tool--json-object
     '("type" . "string")
     (cons "description" (format "Supertag node ID satisfying Type %s" label))
     '("x-supertag-kind" . "node-id")
     (cons "x-supertag-runtime-type" type-id))))

(defun supertag-ontology-tool--input-schema (definition)
  "Return complete input JSON Schema for deployed DEFINITION."
  (let* ((parameters (or (plist-get definition :parameters) nil))
         (properties
          (list (cons "subject_id"
                      (supertag-ontology-tool--subject-schema definition))))
         (required (list "subject_id")))
    (when parameters
      (setq properties
            (append properties
                    (list (cons "arguments"
                                (supertag-ontology-tool--arguments-schema
                                 parameters)))))
      ;; Omission is a valid request when every parameter is optional or has a
      ;; default.  Keep the published schema aligned with the contract binder.
      (when (cl-some (lambda (parameter)
                       (plist-get parameter :required))
                     parameters)
        (setq required (append required (list "arguments")))))
    (supertag-ontology-tool--json-object
     '("type" . "object")
     '("additionalProperties" . :json-false)
     (cons "properties" properties)
     (cons "required" (vconcat required)))))

(defun supertag-ontology-tool--join-sentences (sentences)
  "Join non-empty SENTENCES into one description string.
A sentence that does not already end with terminal punctuation receives a
period before the next sentence is appended, so a user-authored label such
as \"Complete Project\" reads naturally ahead of the generated suffix."
  (let (result)
    (dolist (sentence sentences)
      (when (and (stringp sentence) (not (string-empty-p sentence)))
        (let ((trimmed (string-trim sentence)))
          (unless (string-empty-p trimmed)
            (push (if (string-match-p "[.!?]\\'" trimmed)
                      trimmed
                    (concat trimmed "."))
                  result)))))
    (string-join (nreverse result) " ")))

(defun supertag-ontology-tool--description (kind definition mode)
  "Return generated description for KIND DEFINITION in MODE."
  (let ((base (or (plist-get definition :tool-description)
                  (plist-get definition :description)
                  (plist-get definition :label)
                  (plist-get definition :logical-id))))
    (supertag-ontology-tool--join-sentences
     (list base
           (pcase kind
             (:function
              "Read-only Ontology Function; it does not persist a result.")
             (:action
              (pcase mode
                (:execute "Policy permits this LLM actor to execute the Action.")
                (:confirm "Execution requires an out-of-band one-use confirmation capability.")
                (:proposal "Policy permits proposal generation only; this tool never executes the Action."))))))))

(defun supertag-ontology-tool--function-descriptor (definition actor)
  "Return Function tool descriptor for DEFINITION and ACTOR."
  (let* ((fingerprint
          (supertag-ontology-tool--fingerprint :function definition))
         (name (supertag-ontology-tool--name
                :function definition fingerprint)))
    (list :name name :kind :function :mode :read
          :description
          (supertag-ontology-tool--description :function definition :read)
          :input-schema (supertag-ontology-tool--input-schema definition)
          :output-schema
          (supertag-ontology-tool--type-schema
           (plist-get definition :returns))
          :runtime-id (plist-get definition :runtime-id)
          :logical-id (plist-get definition :logical-id)
          :contract-hash (plist-get definition :contract-hash)
          :tool-fingerprint fingerprint
          :actor (supertag-ontology-contract-copy actor))))

(defun supertag-ontology-tool--action-mode (decision)
  "Return tool mode for Policy DECISION, or nil when hidden."
  (pcase (plist-get decision :decision)
    (:allow :execute)
    (:confirm :confirm)
    (:propose-only :proposal)
    (_ nil)))

(defun supertag-ontology-tool--action-descriptor (definition actor)
  "Return Policy-filtered Action descriptor for DEFINITION and ACTOR."
  (let* ((decision (supertag-ontology-policy-evaluate definition actor))
         (mode (supertag-ontology-tool--action-mode decision)))
    (when mode
      (let* ((fingerprint
              (supertag-ontology-tool--fingerprint
               :action definition decision))
             (name (supertag-ontology-tool--name
                    :action definition fingerprint)))
        (list :name name :kind :action :mode mode
              :description
              (supertag-ontology-tool--description :action definition mode)
              :input-schema (supertag-ontology-tool--input-schema definition)
              :output-schema
              '(("type" . "object")
                ("description" . "Policy-aware Action result envelope"))
              :runtime-id (plist-get definition :runtime-id)
              :logical-id (plist-get definition :logical-id)
              :contract-hash (plist-get definition :contract-hash)
              :policy-id (plist-get decision :policy-id)
              :policy-contract-hash
              (plist-get decision :policy-contract-hash)
              :policy-decision (plist-get decision :decision)
              :policy-reason (plist-get decision :reason)
              :tool-fingerprint fingerprint
              :actor (supertag-ontology-contract-copy actor))))))

(defun supertag-ontology-tool--descriptor-semantic-data (descriptor)
  "Return stable semantic data for DESCRIPTOR."
  (list :name (plist-get descriptor :name)
        :kind (plist-get descriptor :kind)
        :mode (plist-get descriptor :mode)
        :description (plist-get descriptor :description)
        :input-schema (copy-tree (plist-get descriptor :input-schema))
        :output-schema (copy-tree (plist-get descriptor :output-schema))
        :runtime-id (plist-get descriptor :runtime-id)
        :logical-id (plist-get descriptor :logical-id)
        :contract-hash (plist-get descriptor :contract-hash)
        :policy-id (plist-get descriptor :policy-id)
        :policy-contract-hash (plist-get descriptor :policy-contract-hash)
        :tool-fingerprint (plist-get descriptor :tool-fingerprint)))

(defun supertag-ontology-tool-catalog (&optional actor)
  "Return a transient LLM tool catalog for explicit ACTOR.
Only deployed Function and Action contracts with `:llm-tool' enabled are
considered.  Denied Actions are omitted and recorded in `:omitted'."
  (let* ((actor (supertag-ontology-tool--llm-actor (or actor :llm)))
         (seen (make-hash-table :test #'equal))
         tools omitted)
    (dolist (definition (supertag-ontology-function-list))
      (when (eq (plist-get definition :llm-tool) t)
        (if-let ((reason (supertag-ontology-tool--definition-error definition)))
            (push (list :kind :function
                        :runtime-id (plist-get definition :runtime-id)
                        :logical-id (plist-get definition :logical-id)
                        :reason reason)
                  omitted)
          (push (supertag-ontology-tool--function-descriptor
                 definition actor)
                tools))))
    (dolist (definition (supertag-ontology-action-list))
      (when (eq (plist-get definition :llm-tool) t)
        (let* ((definition-error
                (supertag-ontology-tool--definition-error definition))
               (decision
                (supertag-ontology-policy-evaluate definition actor))
               (descriptor
                (and (null definition-error)
                     (supertag-ontology-tool--action-descriptor
                      definition actor))))
          (if descriptor
              (push descriptor tools)
            (push (list :kind :action
                        :runtime-id (plist-get definition :runtime-id)
                        :logical-id (plist-get definition :logical-id)
                        :decision (plist-get decision :decision)
                        :reason (or definition-error
                                    (plist-get decision :reason)))
                  omitted)))))
    (setq tools
          (sort tools
                (lambda (left right)
                  (string< (plist-get left :name)
                           (plist-get right :name)))))
    (dolist (tool tools)
      (when (gethash (plist-get tool :name) seen)
        (signal 'supertag-ontology-tool-error
                (list (format "Generated tool name collision: %s"
                              (plist-get tool :name)))))
      (puthash (plist-get tool :name) t seen))
    (let ((catalog-hash
           (secure-hash
            'sha256
            (prin1-to-string
             (mapcar #'supertag-ontology-tool--descriptor-semantic-data
                     tools)))))
      (list :actor (supertag-ontology-contract-copy actor)
            :catalog-hash catalog-hash
            :generated-at (float-time)
            :tools tools
            :omitted (nreverse omitted)))))

(defun supertag-ontology-tool-list (&optional actor)
  "Return defensive copies of generated tools for ACTOR."
  (supertag-ontology-contract-copy
   (plist-get (supertag-ontology-tool-catalog actor) :tools)))

(defun supertag-ontology-tool-resolve (name &optional actor noerror)
  "Resolve current generated tool NAME for ACTOR.
Stale versioned names are not mapped to newer contracts."
  (let ((tool
         (cl-find name (supertag-ontology-tool-list actor)
                  :key (lambda (descriptor) (plist-get descriptor :name))
                  :test #'equal)))
    (cond
     (tool tool)
     (noerror nil)
     (t
      (signal 'supertag-ontology-tool-stale
              (list (format "Unknown or stale generated tool %S" name)))))))

(defun supertag-ontology-tool--key-string (key)
  "Return normalized JSON-style key string for KEY."
  (let ((text (format "%s" key)))
    (if (string-prefix-p ":" text) (substring text 1) text)))

(defun supertag-ontology-tool--object-pairs (object)
  "Return string-keyed pairs from OBJECT, preserving explicit nil values."
  (cond
   ((null object) nil)
   ((hash-table-p object)
    (let (pairs)
      (maphash (lambda (key value)
                 (push (cons (supertag-ontology-tool--key-string key) value) pairs))
               object)
      (nreverse pairs)))
   ((and (proper-list-p object) (cl-every #'consp object))
    (mapcar (lambda (pair)
              (cons (supertag-ontology-tool--key-string (car pair)) (cdr pair)))
            object))
   ((and (proper-list-p object) (zerop (% (length object) 2)))
    (let ((cursor object) pairs)
      (while cursor
        (let ((key (pop cursor)) (value (pop cursor)))
          (push (cons (supertag-ontology-tool--key-string key) value) pairs)))
      (nreverse pairs)))
   (t
    (signal 'supertag-ontology-tool-error
            (list (format "Expected object input, got %S" object))))))

(defun supertag-ontology-tool--object-value (pairs key)
  "Return `(PRESENT . VALUE)' for string KEY in PAIRS."
  (let ((pair (assoc-string key pairs t)))
    (if pair (cons t (cdr pair)) (cons nil supertag-ontology-tool--absent))))

(defun supertag-ontology-tool--assert-unique-object-keys (pairs label)
  "Reject duplicate string keys in PAIRS for LABEL."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (pair pairs)
      (let ((key (downcase (car pair))))
        (when (gethash key seen)
          (signal 'supertag-ontology-tool-error
                  (list (format "Duplicate %s key %S" label (car pair)))))
        (puthash key t seen)))))

(defun supertag-ontology-tool--arguments (object)
  "Return symbol-keyed argument alist from OBJECT."
  (mapcar
   (lambda (pair)
     (cons (intern (car pair))
           (supertag-ontology-tool--normalize-json-input (cdr pair))))
   (supertag-ontology-tool--object-pairs object)))

(defun supertag-ontology-tool--normalize-input (input)
  "Return normalized `(:subject-id ... :arguments ...)' from INPUT."
  (let* ((pairs (supertag-ontology-tool--object-pairs input))
         (allowed '("subject_id" "arguments")))
    (supertag-ontology-tool--assert-unique-object-keys pairs "top-level input")
    (dolist (pair pairs)
      (unless (member (car pair) allowed)
        (signal 'supertag-ontology-tool-error
                (list (format "Unknown top-level tool input key %S"
                              (car pair))))))
    (pcase-let* ((`(,subject-present . ,subject)
                  (supertag-ontology-tool--object-value pairs "subject_id"))
                 (`(,arguments-present . ,arguments)
                  (supertag-ontology-tool--object-value pairs "arguments")))
      (unless (and subject-present (stringp subject)
                   (not (string-empty-p subject)))
        (signal 'supertag-ontology-tool-error
                (list "Tool input requires non-empty string subject_id")))
      (list :subject-id subject
            :arguments
            (if arguments-present
                (supertag-ontology-tool--arguments arguments)
              nil)))))

(defun supertag-ontology-tool--normalize-json-input (value)
  "Copy JSON VALUE while preserving false and null sentinels."
  (cond
   ((hash-table-p value)
    (let ((copy (make-hash-table :test (hash-table-test value))))
      (maphash
       (lambda (key item)
         (puthash key (supertag-ontology-tool--normalize-json-input item) copy))
       value)
      copy))
   ((consp value)
    (cons (supertag-ontology-tool--normalize-json-input (car value))
          (supertag-ontology-tool--normalize-json-input (cdr value))))
   ((vectorp value)
    (apply #'vector
           (mapcar #'supertag-ontology-tool--normalize-json-input
                   (append value nil))))
   (t value)))

(defun supertag-ontology-tool--parameter (definition name)
  "Return parameter NAME from deployed DEFINITION."
  (cl-find name (plist-get definition :parameters)
           :key (lambda (parameter) (plist-get parameter :name))
           :test #'eq))

(defun supertag-ontology-tool--json-input-value (value type)
  "Convert parsed JSON VALUE according to contract TYPE."
  (pcase type
    (`(:maybe ,inner)
     (if (eq value :json-null)
         nil
       (supertag-ontology-tool--json-input-value value inner)))
    (`(:list ,inner)
     (let ((items
            (cond ((vectorp value) (append value nil))
                  ((proper-list-p value) value)
                  (t
                   (signal 'supertag-ontology-tool-error
                           (list (format "Expected JSON array for %S"
                                         type)))))))
       (mapcar (lambda (item)
                 (supertag-ontology-tool--json-input-value item inner))
               items)))
    (:node-reference
     (cond
      ((vectorp value)
       (mapcar (lambda (item)
                 (supertag-ontology-tool--json-input-value item :string))
               (append value nil)))
      ((proper-list-p value)
       (mapcar (lambda (item)
                 (supertag-ontology-tool--json-input-value item :string))
               value))
      ((or (eq value :json-null) (eq value :json-false))
       (signal 'supertag-ontology-tool-error
               (list "JSON null/false is not a node reference")))
      (t value)))
    (:any
     (cond
      ;; `:any' preserves explicit JSON null/false sentinels.  A typed
      ;; boolean or maybe contract converts them to ordinary domain values;
      ;; an unconstrained implementation receives the JSON distinction.
      ((eq value :json-null) :json-null)
      ((eq value :json-false) :json-false)
      ((hash-table-p value)
       (let ((copy (make-hash-table :test (hash-table-test value))))
         (maphash
          (lambda (key item)
            (puthash key
                     (supertag-ontology-tool--json-input-value item :any)
                     copy))
          value)
         copy))
      ((vectorp value)
       (apply #'vector
              (mapcar (lambda (item)
                        (supertag-ontology-tool--json-input-value item :any))
                      (append value nil))))
      ((supertag-ontology-tool--alist-object-p value)
       (mapcar
        (lambda (pair)
          (cons (car pair)
                (supertag-ontology-tool--json-input-value (cdr pair) :any)))
        value))
      ((proper-list-p value)
       (mapcar (lambda (item)
                 (supertag-ontology-tool--json-input-value item :any))
               value))
      (t value)))
    (:boolean
     (cond ((eq value :json-false) nil)
           ((eq value :json-null)
            (signal 'supertag-ontology-tool-error
                    (list "JSON null is not a boolean")))
           (t value)))
    (_
     (when (eq value :json-null)
       (signal 'supertag-ontology-tool-error
               (list (format "JSON null does not satisfy %S" type))))
     (when (eq value :json-false)
       (signal 'supertag-ontology-tool-error
               (list (format "JSON false does not satisfy %S" type))))
     value)))

(defun supertag-ontology-tool--prepare-arguments (definition arguments)
  "Convert parsed ARGUMENTS according to deployed DEFINITION."
  (mapcar
   (lambda (pair)
     (let ((parameter
            (supertag-ontology-tool--parameter definition (car pair))))
       (cons (car pair)
             (if parameter
                 (supertag-ontology-tool--json-input-value
                  (cdr pair) (plist-get parameter :type))
               (cdr pair)))))
   arguments))

(defun supertag-ontology-tool--plist-p (value)
  "Return non-nil when VALUE looks like a keyword/symbol/string plist."
  (and (proper-list-p value)
       (zerop (% (length value) 2))
       (let ((cursor value) valid)
         (setq valid t)
         (while (and cursor valid)
           (let ((key (pop cursor)))
             (pop cursor)
             (unless (or (symbolp key) (stringp key))
               (setq valid nil))))
         valid)))

(defun supertag-ontology-tool--alist-object-p (value)
  "Return non-nil when VALUE is an object-like alist."
  (and (proper-list-p value)
       value
       (cl-every
        (lambda (item)
          (and (consp item)
               (or (symbolp (car item)) (stringp (car item)))))
        value)))

(defun supertag-ontology-tool--generic-json-value (value depth)
  "Return JSON-safe representation of VALUE at recursion DEPTH."
  (when (> depth 64)
    (signal 'supertag-ontology-tool-error
            (list "Tool result nesting exceeds 64 levels")))
  (cond
   ((eq value :json-false) :json-false)
   ((eq value :json-null) :json-null)
   ((null value) :json-null)
   ((eq value t) t)
   ((or (stringp value) (numberp value)) value)
   ((hash-table-p value)
    (let (pairs)
      (maphash
       (lambda (key item)
         (push (cons (supertag-ontology-tool--key-string key)
                     (supertag-ontology-tool--generic-json-value
                      item (1+ depth)))
               pairs))
       value)
      (sort pairs (lambda (left right) (string< (car left) (car right))))))
   ((supertag-ontology-tool--alist-object-p value)
    (mapcar
     (lambda (pair)
       (cons (supertag-ontology-tool--key-string (car pair))
             (supertag-ontology-tool--generic-json-value
              (cdr pair) (1+ depth))))
     value))
   ((supertag-ontology-tool--plist-p value)
    (let ((cursor value) pairs)
      (while cursor
        (let ((key (pop cursor)) (item (pop cursor)))
          (push (cons (supertag-ontology-tool--key-string key)
                      (supertag-ontology-tool--generic-json-value
                       item (1+ depth)))
                pairs)))
      (nreverse pairs)))
   ((proper-list-p value)
    (vconcat
     (mapcar (lambda (item)
               (supertag-ontology-tool--generic-json-value
                item (1+ depth)))
             value)))
   ((vectorp value)
    (apply #'vector
           (mapcar (lambda (item)
                     (supertag-ontology-tool--generic-json-value
                      item (1+ depth)))
                   (append value nil))))
   ((keywordp value) (substring (symbol-name value) 1))
   ((symbolp value) (symbol-name value))
   (t (format "%S" value))))

(defun supertag-ontology-tool--typed-json-value (value type)
  "Return JSON-safe VALUE according to contract TYPE."
  (pcase type
    (:boolean (if value t :json-false))
    (:timestamp
     (cond ((stringp value) value)
           ((or (consp value) (integerp value) (floatp value))
            (format-time-string "%Y-%m-%dT%H:%M:%SZ" value t))
           (t (supertag-ontology-tool--generic-json-value value 0))))
    (:options (if (symbolp value) (symbol-name value) value))
    (:node-reference
     (if (proper-list-p value) (vconcat value) value))
    (`(:maybe ,inner)
     (if (null value) :json-null
       (supertag-ontology-tool--typed-json-value value inner)))
    (`(:list ,inner)
     (vconcat
      (mapcar (lambda (item)
                (supertag-ontology-tool--typed-json-value item inner))
              value)))
    (_ (supertag-ontology-tool--generic-json-value value 0))))

(defun supertag-ontology-tool--envelope (&rest pairs)
  "Return JSON-ready envelope from PAIRS."
  (apply #'supertag-ontology-tool--json-object pairs))

(defun supertag-ontology-tool--function-call (tool input)
  "Invoke Function TOOL with normalized INPUT."
  (let* ((definition
          (supertag-ontology-function-resolve (plist-get tool :runtime-id)))
         (arguments
          (supertag-ontology-tool--prepare-arguments
           definition (plist-get input :arguments)))
         (result
          (supertag-ontology-function-call
           (plist-get definition :runtime-id)
           (plist-get input :subject-id)
           arguments)))
    (supertag-ontology-tool--envelope
     '("status" . "ok")
     '("kind" . "function")
     (cons "tool" (plist-get tool :name))
     (cons "logical_id" (plist-get tool :logical-id))
     (cons "result"
           (supertag-ontology-tool--typed-json-value
            result (plist-get definition :returns))))))

(defun supertag-ontology-tool--proposal-envelope (tool proposal status)
  "Return Action TOOL proposal envelope for PROPOSAL and STATUS."
  (supertag-ontology-tool--envelope
   (cons "status" status)
   '("kind" . "action")
   (cons "mode" (substring (symbol-name (plist-get tool :mode)) 1))
   (cons "tool" (plist-get tool :name))
   (cons "logical_id" (plist-get tool :logical-id))
   (cons "proposal"
         (supertag-ontology-tool--generic-json-value proposal 0))))

(defun supertag-ontology-tool--action-call
    (tool input actor confirmation-token)
  "Invoke or propose Action TOOL for INPUT, ACTOR, and CONFIRMATION-TOKEN."
  (let* ((runtime-id (plist-get tool :runtime-id))
         (definition (supertag-ontology-action-resolve runtime-id))
         (subject-id (plist-get input :subject-id))
         (arguments
          (supertag-ontology-tool--prepare-arguments
           definition (plist-get input :arguments))))
    (pcase (plist-get tool :mode)
      (:proposal
       (when confirmation-token
         (signal 'supertag-ontology-tool-error
                 (list "A propose-only tool cannot consume confirmation")))
       (supertag-ontology-tool--proposal-envelope
        tool
        (supertag-ontology-action-propose
         runtime-id subject-id arguments actor)
        "proposal"))
      (:confirm
       (if confirmation-token
           (supertag-ontology-tool--envelope
            '("status" . "executed")
            '("kind" . "action")
            (cons "mode" "confirm")
            (cons "tool" (plist-get tool :name))
            (cons "logical_id" (plist-get tool :logical-id))
            (cons "execution"
                  (supertag-ontology-tool--generic-json-value
                   (supertag-ontology-action-execute
                    runtime-id subject-id arguments actor confirmation-token)
                   0)))
         (supertag-ontology-tool--proposal-envelope
          tool
          (supertag-ontology-action-propose
           runtime-id subject-id arguments actor)
          "confirmation_required")))
      (:execute
       (when confirmation-token
         (signal 'supertag-ontology-tool-error
                 (list "An allow tool does not accept a confirmation token")))
       (supertag-ontology-tool--envelope
        '("status" . "executed")
        '("kind" . "action")
        (cons "mode" "execute")
        (cons "tool" (plist-get tool :name))
        (cons "logical_id" (plist-get tool :logical-id))
        (cons "execution"
              (supertag-ontology-tool--generic-json-value
               (supertag-ontology-action-execute
                runtime-id subject-id arguments actor)
               0))))
      (_
       (signal 'supertag-ontology-tool-error
               (list (format "Unsupported Action tool mode %S"
                             (plist-get tool :mode))))))))

(defun supertag-ontology-tool-invoke
    (name input &optional confirmation-token actor)
  "Invoke current generated tool NAME with INPUT.

CONFIRMATION-TOKEN is an out-of-band Policy capability accepted only by
`:confirm' Action tools. ACTOR must normalize to the `:llm' actor class."
  (let* ((actor (supertag-ontology-tool--llm-actor (or actor :llm)))
         (tool (supertag-ontology-tool-resolve name actor))
         (input (supertag-ontology-tool--normalize-input input)))
    (pcase (plist-get tool :kind)
      (:function
       (when confirmation-token
         (signal 'supertag-ontology-tool-error
                 (list "Function tools do not accept confirmation tokens")))
       (supertag-ontology-tool--function-call tool input))
      (:action
       (supertag-ontology-tool--action-call
        tool input actor confirmation-token))
      (_
       (signal 'supertag-ontology-tool-error
               (list (format "Unsupported generated tool kind %S"
                             (plist-get tool :kind))))))))

(defun supertag-ontology-tool-request-confirmation (name input &optional actor)
  "Interactively request a one-use confirmation token for tool NAME and INPUT."
  (let* ((actor (supertag-ontology-tool--llm-actor (or actor :llm)))
         (tool (supertag-ontology-tool-resolve name actor))
         (input (supertag-ontology-tool--normalize-input input)))
    (unless (and (eq (plist-get tool :kind) :action)
                 (eq (plist-get tool :mode) :confirm))
      (signal 'supertag-ontology-tool-error
              (list "Only :confirm Action tools can request confirmation")))
    (let* ((definition
            (supertag-ontology-action-resolve
             (plist-get tool :runtime-id)))
           (arguments
            (supertag-ontology-tool--prepare-arguments
             definition (plist-get input :arguments)))
           (plan
            (supertag-ontology-action-preview
             (plist-get tool :runtime-id)
             (plist-get input :subject-id)
             arguments)))
      ;; The confirmation capability is bound to the same typed argument
      ;; semantics used by the eventual invocation.  JSON false/null sentinels
      ;; cannot produce one plan during confirmation and another at execution.
      (supertag-ontology-policy-request-confirmation plan actor))))

(defun supertag-ontology-tool--parse-json (json)
  "Parse JSON into alists/lists with explicit false and null sentinels."
  ;; `json-parse-string' (Emacs 27+) only accepts `array' or `list' for
  ;; :array-type; `vector' is a json.el `json-array-type' value and is
  ;; rejected by the native parser.  `array' yields Lisp vectors, so `[]'
  ;; stays distinguishable from null/false and from a missing key.  The
  ;; `alist' object type keeps every member of an object, including
  ;; duplicate keys, which lets input normalization reject them.
  (if (fboundp 'json-parse-string)
      (json-parse-string json
                         :object-type 'alist
                         :array-type 'array
                         :null-object :json-null
                         :false-object :json-false)
    (let ((json-object-type 'alist)
          (json-array-type 'vector)
          (json-null :json-null)
          (json-false :json-false))
      (json-read-from-string json))))

(defun supertag-ontology-tool--encode-json (value &optional pretty)
  "Encode JSON-safe VALUE, optionally PRETTY printed."
  (let ((json-encoding-pretty-print (and pretty t))
        (json-null :json-null)
        (json-false :json-false))
    (json-encode value)))

(defun supertag-ontology-tool-invoke-json
    (name json &optional confirmation-token actor)
  "Invoke NAME with JSON input and return a JSON response string."
  (supertag-ontology-tool--encode-json
   (supertag-ontology-tool-invoke
    name (supertag-ontology-tool--parse-json json)
    confirmation-token actor)))

(defun supertag-ontology-tool--json-descriptor (descriptor)
  "Return provider-neutral JSON object for internal DESCRIPTOR."
  (supertag-ontology-tool--json-object
   '("type" . "function")
   (cons "name" (plist-get descriptor :name))
   (cons "description" (plist-get descriptor :description))
   (cons "parameters" (plist-get descriptor :input-schema))
   (cons "x-supertag"
         (supertag-ontology-tool--json-object
          (cons "kind" (substring
                         (symbol-name (plist-get descriptor :kind)) 1))
          (cons "mode" (substring
                         (symbol-name (plist-get descriptor :mode)) 1))
          (cons "logical_id" (plist-get descriptor :logical-id))
          (cons "tool_fingerprint"
                (plist-get descriptor :tool-fingerprint))
          (cons "output_schema"
                (plist-get descriptor :output-schema))))))

(defun supertag-ontology-tool-catalog-json (&optional actor pretty)
  "Return generated catalog as JSON for ACTOR.
When PRETTY is non-nil, indent the output."
  (let* ((catalog (supertag-ontology-tool-catalog actor))
         (payload
          (supertag-ontology-tool--json-object
           (cons "catalog_hash" (plist-get catalog :catalog-hash))
           (cons "actor"
                 (supertag-ontology-tool--generic-json-value
                  (plist-get catalog :actor) 0))
           (cons "tools"
                 (vconcat
                  (mapcar #'supertag-ontology-tool--json-descriptor
                          (plist-get catalog :tools)))))))
    (supertag-ontology-tool--encode-json payload pretty)))

(provide 'supertag-ontology-tool)
;;; supertag-ontology-tool.el ends here
