;;; supertag-ontology-model.el --- Pure ontology model normalization and identity helpers. -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Pure ontology model normalization and identity helpers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-ontology-contract)

(defconst supertag-ontology-model-version 6)

(defconst supertag-ontology-model-field-keywords
  '(:id :runtime-id :label :description :type :options :required :default))
(defconst supertag-ontology-model-type-keywords
  '(:id :runtime-id :label :description :extends :fields :aliases))
(defconst supertag-ontology-model-link-keywords
  '(:id :runtime-id :label :description :inverse-label :from :to
    :from-cardinality :to-cardinality))
(defconst supertag-ontology-model-function-keywords
  '(:id :runtime-id :label :description :subject :parameters :returns
    :implementation :llm-tool :tool-name :tool-description))
(defconst supertag-ontology-model-action-keywords
  '(:id :runtime-id :label :description :subject :parameters :preconditions
    :effects :confirmation :llm-tool :tool-name :tool-description))
(defconst supertag-ontology-model-policy-keywords
  '(:id :runtime-id :label :description :action :actors))

(defun supertag-ontology-model-logical-id (module kind key)
  "Return stable logical identity for MODULE, KIND and KEY.
KIND is rendered without a keyword colon so identities remain readable and
portable, for example `work/type/project'."
  (let ((kind-name (if (keywordp kind)
                       (substring (symbol-name kind) 1)
                     (format "%s" kind))))
    (format "%s/%s/%s" module kind-name key)))

(defun supertag-ontology-model--plist-keys (plist)
  (let (keys)
    (while plist
      (push (pop plist) keys)
      (pop plist))
    (nreverse keys)))

(defun supertag-ontology-model--normalize-key (value)
  (cond ((symbolp value) value)
        ((stringp value) (intern value))
        (t value)))


(defun supertag-ontology-model--normalize-field-type (value)
  "Return VALUE as one canonical Supertag field-type keyword."
  (let ((name (cond ((keywordp value) (substring (symbol-name value) 1))
                    ((symbolp value) (symbol-name value))
                    ((stringp value) value)
                    (t nil))))
    (when name
      (pcase (downcase name)
        ((or "text" "string") :string)
        ("number" :number)
        ("integer" :integer)
        ((or "bool" "boolean") :boolean)
        ("date" :date)
        ("timestamp" :timestamp)
        ((or "option" "options" "enum") :options)
        ("url" :url)
        ("email" :email)
        ("tag" :tag)
        ((or "reference" "node-reference" "node_reference")
         :node-reference)
        (_ (intern (concat ":" (downcase name))))))))

(defun supertag-ontology-model--normalize-option (value)
  "Return one field option VALUE in the runtime string representation."
  (cond ((stringp value) value)
        ((symbolp value) (symbol-name value))
        (t value)))

(defun supertag-ontology-model--alias-token (value)
  "Return Type alias VALUE as the occurrence token the Tag layer stores.
Symbols become their names.  Strings mirror `supertag-sanitize-tag-name':
surrounding whitespace and one leading `#' are dropped and inner whitespace
runs become `_'.  Other values are returned unchanged so validation can
report them; an empty result stays \"\" for the same reason."
  (cond
   ((stringp value)
    (let* ((trimmed (string-trim value))
           (no-hash (if (string-prefix-p "#" trimmed)
                        (substring trimmed 1)
                      trimmed)))
      (replace-regexp-in-string "[[:space:]]+" "_" no-hash)))
   ((and value (symbolp value))
    (supertag-ontology-model--alias-token (symbol-name value)))
   (t value)))

(defun supertag-ontology-model--normalize-aliases (raw)
  "Normalize declared Type aliases RAW without hiding malformed input.
Well-formed aliases become sorted, deduplicated token strings."
  (if (proper-list-p raw)
      (let ((tokens (mapcar #'supertag-ontology-model--alias-token raw)))
        (if (cl-every (lambda (token)
                        (and (stringp token) (not (string-empty-p token))))
                      tokens)
            (sort (delete-dups tokens) #'string<)
          tokens))
    raw))

(defun supertag-ontology-model-type-aliases (entity)
  "Return the occurrence tokens the ontology manages for TYPE ENTITY.
These are the type key (so `#project' resolves to a type declared as
`(type project :label \"Project\")') plus every well-formed declared
`:aliases' token, sorted and deduplicated.  The Tag layer adds the id, name
and display path on its own; they are not ontology-managed."
  (let* ((key (plist-get entity :key))
         (key-token (and key (or (symbolp key) (stringp key))
                         (supertag-ontology-model--alias-token key)))
         (declared (plist-get entity :aliases))
         (tokens (append (and (stringp key-token)
                              (not (string-empty-p key-token))
                              (list key-token))
                         (and (proper-list-p declared)
                              (cl-remove-if-not
                               (lambda (token)
                                 (and (stringp token)
                                      (not (string-empty-p token))))
                               declared)))))
    (sort (delete-dups (copy-sequence tokens)) #'string<)))

(defun supertag-ontology-model--normalize-cardinality (value)
  (pcase value
    ((or 'one :one 1) :one)
    ((or 'many :many '* 'nil) :many)
    (_ value)))

(defun supertag-ontology-model--normalize-keyword (value)
  "Normalize VALUE to a keyword when it is a symbol or string."
  (cond
   ((keywordp value) value)
   ((symbolp value) (intern (concat ":" (symbol-name value))))
   ((stringp value) (intern (concat ":" value)))
   (t value)))

(defun supertag-ontology-model--normalize-policy-actor (value)
  "Return canonical Policy actor keyword for VALUE."
  (pcase (supertag-ontology-model--normalize-keyword value)
    ((or :user :interactive :interactive-user) :interactive-user)
    (:automation :automation)
    (:llm :llm)
    (:external :external)
    (other other)))

(defun supertag-ontology-model--normalize-policy-decision (value)
  "Return canonical Policy decision keyword for VALUE."
  (pcase (supertag-ontology-model--normalize-keyword value)
    ((or :propose :propose-only) :propose-only)
    (:allow :allow)
    (:deny :deny)
    (:confirm :confirm)
    (other other)))

(defun supertag-ontology-model--normalize-policy-rule (raw)
  "Normalize one Policy actor rule RAW."
  (cond
   ((and (proper-list-p raw)
         (keywordp (car raw))
         (plist-member raw :actor))
    (let ((copy (copy-tree raw)))
      (setq copy
            (plist-put copy :actor
                       (supertag-ontology-model--normalize-policy-actor
                        (plist-get copy :actor))))
      (plist-put copy :decision
                 (supertag-ontology-model--normalize-policy-decision
                  (plist-get copy :decision)))))
   ((and (proper-list-p raw) (>= (length raw) 2))
    (append
     (list :actor (supertag-ontology-model--normalize-policy-actor
                   (nth 0 raw))
           :decision (supertag-ontology-model--normalize-policy-decision
                      (nth 1 raw)))
     (copy-tree (nthcdr 2 raw))))
   (t raw)))

(defun supertag-ontology-model--normalize-policy-actors (raw)
  "Normalize Policy actor rules RAW without hiding malformed input."
  (if (proper-list-p raw)
      (let ((normalized
             (mapcar #'supertag-ontology-model--normalize-policy-rule raw)))
        (if (cl-every #'proper-list-p normalized)
            (sort normalized
                  (lambda (left right)
                    (string< (format "%s" (plist-get left :actor))
                             (format "%s" (plist-get right :actor)))))
          normalized))
    raw))

(defun supertag-ontology-model--normalize-precondition (raw)
  "Normalize one Action precondition RAW."
  (cond
   ((and (proper-list-p raw) (keywordp (car raw))) (copy-tree raw))
   ((and (proper-list-p raw) (memq (car raw) '(function call)))
    (append (list :function
                  (supertag-ontology-model--normalize-key (cadr raw)))
            (copy-tree (cddr raw))))
   (t raw)))

(defun supertag-ontology-model--subject-expression-p (expression)
  "Return non-nil when EXPRESSION denotes the Action subject."
  (equal expression '(:subject)))

(defun supertag-ontology-model--normalize-link-effect-plist (copy)
  "Normalize one keyword-form Link effect COPY around the Action subject."
  (let* ((kind (plist-get copy :kind))
         (link (supertag-ontology-model--normalize-key
                (plist-get copy :link)))
         (direction (or (plist-get copy :direction) :forward))
         (target (plist-get copy :target))
         (from-present (plist-member copy :from))
         (to-present (plist-member copy :to))
         (from (plist-get copy :from))
         (to (plist-get copy :to)))
    (unless target
      (cond
       ((and from-present to-present
             (supertag-ontology-model--subject-expression-p from)
             (not (supertag-ontology-model--subject-expression-p to)))
        (setq direction :forward target to))
       ((and from-present to-present
             (supertag-ontology-model--subject-expression-p to)
             (not (supertag-ontology-model--subject-expression-p from)))
        (setq direction :reverse target from))
       ((and (not from-present) to-present)
        (setq direction :forward target to))
       ((and from-present (not to-present))
        (setq direction :reverse target from))))
    (list :kind kind
          :link link
          :direction direction
          :target (copy-tree target)
          :replace (and (plist-get copy :replace) t)
          :unanchored (null target))))

(defun supertag-ontology-model--normalize-effect (raw)
  "Normalize one declarative Action effect RAW.

Typed Link effects are always anchored to the Action subject.  The effect
stores only the other endpoint as `:target' plus a `:forward' or `:reverse'
direction.  Legacy keyword forms with `:from' and `:to' remain readable only
when exactly one endpoint is `(:subject)'."
  (cond
   ((and (proper-list-p raw) (keywordp (car raw)))
    (let* ((copy (copy-tree raw))
           (kind (plist-get copy :kind)))
      (if (memq kind '(:add-link :remove-link))
          (supertag-ontology-model--normalize-link-effect-plist copy)
        copy)))
   ((and (proper-list-p raw) (symbolp (car raw)))
    (pcase (car raw)
      ('set-field
       (append (list :kind :set-field
                     :field (supertag-ontology-model--normalize-key (cadr raw)))
               (copy-tree (cddr raw))))
      ('clear-field
       (append (list :kind :clear-field
                     :field (supertag-ontology-model--normalize-key (cadr raw)))
               (copy-tree (cddr raw))))
      ((or 'add-link 'remove-link 'add-reverse-link 'remove-reverse-link)
       (let* ((operation (car raw))
              (kind (if (memq operation '(add-link add-reverse-link))
                        :add-link :remove-link))
              (direction (if (memq operation
                                   '(add-reverse-link remove-reverse-link))
                             :reverse :forward))
              (tail (copy-tree (cdddr raw))))
         (append (list :kind kind
                       :link (supertag-ontology-model--normalize-key (cadr raw))
                       :direction direction
                       :target (copy-tree (nth 2 raw)))
                 tail)))
      (_ raw)))
   (t raw)))

(defun supertag-ontology-model--entity (module kind key plist source)
  (let* ((allowed (pcase kind
                    (:field supertag-ontology-model-field-keywords)
                    (:type supertag-ontology-model-type-keywords)
                    (:link supertag-ontology-model-link-keywords)
                    (:function supertag-ontology-model-function-keywords)
                    (:action supertag-ontology-model-action-keywords)
                    (:policy supertag-ontology-model-policy-keywords)))
         (unknown (cl-set-difference
                   (supertag-ontology-model--plist-keys plist)
                   allowed :test #'eq))
         (runtime-id (or (plist-get plist :runtime-id)
                         ;; :id was used by the v3 prototype as a runtime binding.
                         ;; Keep it as a compatibility alias, but normalize it here.
                         (plist-get plist :id)))
         (label (or (plist-get plist :label)
                    (and (symbolp key) (symbol-name key))
                    (format "%s" key)))
         (base (list :module module
                     :kind kind
                     :key (supertag-ontology-model--normalize-key key)
                     :logical-id (supertag-ontology-model-logical-id module kind key)
                     :runtime-id runtime-id
                     :label label
                     :description (plist-get plist :description)
                     :unknown-keywords unknown
                     :source source)))
    (pcase kind
      (:field
       (append base
               (list :type (supertag-ontology-model--normalize-field-type
                            (plist-get plist :type))
                     :options (mapcar
                               #'supertag-ontology-model--normalize-option
                               (copy-sequence
                                (or (plist-get plist :options) nil)))
                     :required (and (plist-member plist :required)
                                    (plist-get plist :required))
                     :default (plist-get plist :default))))
      (:type
       (append base
               (list :extends (supertag-ontology-model--normalize-key
                               (plist-get plist :extends))
                     :fields (mapcar #'supertag-ontology-model--normalize-key
                                     (copy-sequence (or (plist-get plist :fields) nil)))
                     :aliases (supertag-ontology-model--normalize-aliases
                               (plist-get plist :aliases)))))
      (:link
       (append base
               (list :inverse-label (plist-get plist :inverse-label)
                     :from (supertag-ontology-model--normalize-key
                            (plist-get plist :from))
                     :to (supertag-ontology-model--normalize-key
                          (plist-get plist :to))
                     :from-cardinality
                     (supertag-ontology-model--normalize-cardinality
                      (plist-get plist :from-cardinality))
                     :to-cardinality
                     (supertag-ontology-model--normalize-cardinality
                      (plist-get plist :to-cardinality)))))
      (:function
       (append base
               (list :subject
                     (supertag-ontology-model--normalize-key
                      (plist-get plist :subject))
                     :parameters
                     (supertag-ontology-contract-normalize-parameters
                      (or (plist-get plist :parameters) nil))
                     :returns
                     (supertag-ontology-contract-normalize-type
                      (plist-get plist :returns))
                     :implementation
                     (supertag-ontology-contract-normalize-callable-symbol
                      (plist-get plist :implementation))
                     :llm-tool (and (plist-get plist :llm-tool) t)
                     :llm-tool-valid-p
                     (or (not (plist-member plist :llm-tool))
                         (memq (plist-get plist :llm-tool) '(nil t)))
                     :tool-name (plist-get plist :tool-name)
                     :tool-description (plist-get plist :tool-description))))
      (:action
       (append base
               (list :subject
                     (supertag-ontology-model--normalize-key
                      (plist-get plist :subject))
                     :parameters
                     (supertag-ontology-contract-normalize-parameters
                      (or (plist-get plist :parameters) nil))
                     :preconditions
                     (mapcar #'supertag-ontology-model--normalize-precondition
                             (copy-tree
                              (or (plist-get plist :preconditions) nil)))
                     :effects
                     (mapcar #'supertag-ontology-model--normalize-effect
                             (copy-tree (or (plist-get plist :effects) nil)))
                     :confirmation (or (plist-get plist :confirmation)
                                       :never)
                     :llm-tool (and (plist-get plist :llm-tool) t)
                     :llm-tool-valid-p
                     (or (not (plist-member plist :llm-tool))
                         (memq (plist-get plist :llm-tool) '(nil t)))
                     :tool-name (plist-get plist :tool-name)
                     :tool-description (plist-get plist :tool-description))))
      (:policy
       (append base
               (list :action
                     (supertag-ontology-model--normalize-key
                      (plist-get plist :action))
                     :actors
                     (supertag-ontology-model--normalize-policy-actors
                      (plist-get plist :actors))))))))

(defun supertag-ontology-model-normalize (module raw-body source)
  "Normalize MODULE RAW-BODY into a pure desired ontology model.
SOURCE is a plist containing source-file and source-line metadata."
  (let ((version 1)
        (description nil)
        fields types links functions actions policies unknown-forms)
    (while (keywordp (car raw-body))
      (pcase (pop raw-body)
        (:version (setq version (pop raw-body)))
        (:description (setq description (pop raw-body)))
        (key
         (push (list key (pop raw-body)) unknown-forms))))
    (dolist (form raw-body)
      (if (not (and (listp form) (symbolp (car form))))
          (push form unknown-forms)
        (pcase (car form)
          ('field
           (push (supertag-ontology-model--entity
                  module :field (nth 1 form) (nthcdr 2 form) source)
                 fields))
          ('type
           (push (supertag-ontology-model--entity
                  module :type (nth 1 form) (nthcdr 2 form) source)
                 types))
          ('link
           (push (supertag-ontology-model--entity
                  module :link (nth 1 form) (nthcdr 2 form) source)
                 links))
          ('function
           (push (supertag-ontology-model--entity
                  module :function (nth 1 form) (nthcdr 2 form) source)
                 functions))
          ('action
           (push (supertag-ontology-model--entity
                  module :action (nth 1 form) (nthcdr 2 form) source)
                 actions))
          ('policy
           (push (supertag-ontology-model--entity
                  module :policy (nth 1 form) (nthcdr 2 form) source)
                 policies))
          (_ (push form unknown-forms)))))
    (list :model-version supertag-ontology-model-version
          :module module
          :version version
          :description description
          :source source
          :fields (nreverse fields)
          :types (nreverse types)
          :links (nreverse links)
          :functions (nreverse functions)
          :actions (nreverse actions)
          :policies (nreverse policies)
          :unknown-forms (nreverse unknown-forms))))

(defun supertag-ontology-model-entities (model)
  "Return all entities in MODEL in dependency order."
  (append (plist-get model :fields)
          (plist-get model :types)
          (plist-get model :links)
          (plist-get model :functions)
          (plist-get model :actions)
          (plist-get model :policies)))

(defun supertag-ontology-model-find (model kind key)
  "Find KIND entity named KEY in MODEL."
  (cl-find-if (lambda (entity)
                (and (eq (plist-get entity :kind) kind)
                     (equal (plist-get entity :key) key)))
              (supertag-ontology-model-entities model)))

(defun supertag-ontology-model--canonical-entity (entity)
  (pcase (plist-get entity :kind)
    (:field
     (list :kind :field :key (plist-get entity :key)
           :runtime-id (plist-get entity :runtime-id)
           :label (plist-get entity :label)
           :type (plist-get entity :type)
           :options (sort (copy-sequence (plist-get entity :options))
                          (lambda (a b) (string< (format "%s" a)
                                                (format "%s" b))))
           :required (plist-get entity :required)
           :default (plist-get entity :default)))
    (:type
     (append
      (list :kind :type :key (plist-get entity :key)
            :runtime-id (plist-get entity :runtime-id)
            :label (plist-get entity :label)
            :extends (plist-get entity :extends)
            :fields (sort (copy-sequence (plist-get entity :fields))
                          (lambda (a b) (string< (format "%s" a)
                                                (format "%s" b)))))
      ;; Declared aliases are part of the semantic identity, but the slot is
      ;; only emitted when present so hashes of already deployed modules
      ;; that declare no aliases stay stable.
      (let ((aliases (plist-get entity :aliases)))
        (and aliases (list :aliases (copy-tree aliases))))))
    (:link
     (list :kind :link :key (plist-get entity :key)
           :runtime-id (plist-get entity :runtime-id)
           :label (plist-get entity :label)
           :inverse-label (plist-get entity :inverse-label)
           :from (plist-get entity :from)
           :to (plist-get entity :to)
           :from-cardinality (plist-get entity :from-cardinality)
           :to-cardinality (plist-get entity :to-cardinality)))
    (:function
     (list :kind :function :key (plist-get entity :key)
           :runtime-id (plist-get entity :runtime-id)
           :label (plist-get entity :label)
           :description (plist-get entity :description)
           :subject (plist-get entity :subject)
           ;; Parameter order is part of the public contract.
           :parameters (copy-tree (plist-get entity :parameters))
           :returns (copy-tree (plist-get entity :returns))
           :implementation (plist-get entity :implementation)
           :llm-tool (and (plist-get entity :llm-tool) t)
           :tool-name (plist-get entity :tool-name)
           :tool-description (plist-get entity :tool-description)))
    (:action
     (list :kind :action :key (plist-get entity :key)
           :runtime-id (plist-get entity :runtime-id)
           :label (plist-get entity :label)
           :description (plist-get entity :description)
           :subject (plist-get entity :subject)
           :parameters (copy-tree (plist-get entity :parameters))
           :preconditions (copy-tree (plist-get entity :preconditions))
           :effects (copy-tree (plist-get entity :effects))
           :confirmation (plist-get entity :confirmation)
           :llm-tool (and (plist-get entity :llm-tool) t)
           :tool-name (plist-get entity :tool-name)
           :tool-description (plist-get entity :tool-description)))
    (:policy
     (list :kind :policy :key (plist-get entity :key)
           :runtime-id (plist-get entity :runtime-id)
           :label (plist-get entity :label)
           :description (plist-get entity :description)
           :action (plist-get entity :action)
           :actors
           (let ((actors (plist-get entity :actors)))
             (if (proper-list-p actors)
                 (sort (copy-tree actors)
                       (lambda (left right)
                         (string<
                          (format "%s" (and (proper-list-p left)
                                             (plist-get left :actor)))
                          (format "%s" (and (proper-list-p right)
                                             (plist-get right :actor))))))
               (copy-tree actors)))))))

(defun supertag-ontology-model-semantic-data (model)
  "Return canonical semantic data for MODEL.
Source positions, declaration order and deployment timestamps are excluded."
  (let ((entities (mapcar #'supertag-ontology-model--canonical-entity
                          (supertag-ontology-model-entities model))))
    (list :model-version (plist-get model :model-version)
          :module (plist-get model :module)
          :version (plist-get model :version)
          :entities
          (sort entities
                (lambda (a b)
                  (string< (format "%s/%s" (plist-get a :kind)
                                   (plist-get a :key))
                           (format "%s/%s" (plist-get b :kind)
                                   (plist-get b :key))))))))

(defun supertag-ontology-model-hash (model)
  "Return semantic SHA-256 hash for MODEL."
  (secure-hash 'sha256
               (prin1-to-string
                (supertag-ontology-model-semantic-data model))))

(provide 'supertag-ontology-model)
;;; supertag-ontology-model.el ends here
