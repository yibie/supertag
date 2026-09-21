;;; supertag-ontology-validator.el --- Total validation for normalized ontology models. -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Total validation for normalized ontology models.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-ontology-model)
(require 'supertag-ontology-contract)
(require 'supertag-core-schema)

(defun supertag-ontology-validator--issue (severity code path format-string &rest args)
  (list :severity severity :code code :path path
        :message (apply #'format format-string args)))

(defun supertag-ontology-validator--safe-list-p (value)
  (or (null value) (proper-list-p value)))

(defconst supertag-ontology-validator--tool-name-regexp
  "\\`[A-Za-z][A-Za-z0-9_-]*\\'"
  "Safe base-name syntax for generated LLM tools.")

(defun supertag-ontology-validator--tool-metadata-issues (entity)
  "Return LLM tool exposure issues for Function or Action ENTITY."
  (let ((path (list (plist-get entity :kind) (plist-get entity :key)))
        (name (plist-get entity :tool-name))
        (description (plist-get entity :tool-description))
        issues)
    (unless (plist-get entity :llm-tool-valid-p)
      (push (supertag-ontology-validator--issue
             :error :invalid-llm-tool path
             ":llm-tool must be boolean")
            issues))
    (when name
      (unless (and (stringp name)
                   (> (length name) 0)
                   (<= (length name) 48)
                   (string-match-p
                    supertag-ontology-validator--tool-name-regexp name))
        (push (supertag-ontology-validator--issue
               :error :invalid-tool-name path
               ":tool-name must be 1-48 ASCII letters, digits, _ or -, beginning with a letter")
              issues)))
    (when (and description (not (stringp description)))
      (push (supertag-ontology-validator--issue
             :error :invalid-tool-description path
             ":tool-description must be a string")
            issues))
    (nreverse issues)))

(defun supertag-ontology-validator--duplicates (items keyfn)
  (let ((seen (make-hash-table :test #'equal)) duplicates)
    (dolist (item items)
      (let ((key (funcall keyfn item)))
        (if (gethash key seen)
            (push key duplicates)
          (puthash key t seen))))
    (delete-dups duplicates)))

(defun supertag-ontology-validator--inheritance-cycle (types)
  (let ((parents (make-hash-table :test #'equal))
        cycle)
    (dolist (type types)
      (puthash (plist-get type :key) (plist-get type :extends) parents))
    (catch 'done
      (maphash
       (lambda (start _)
         (let ((seen (make-hash-table :test #'equal)) (cursor start) path)
           (while cursor
             (when (gethash cursor seen)
               (setq cycle (nreverse (cons cursor path)))
               (throw 'done cycle))
             (puthash cursor t seen)
             (push cursor path)
             (setq cursor (gethash cursor parents)))))
       parents))
    cycle))

(defun supertag-ontology-validator--validate-parameters
    (parameters type-keys path)
  "Return issues for ordered PARAMETERS at PATH."
  (let (issues)
    (unless (proper-list-p parameters)
      (push (supertag-ontology-validator--issue
             :error :invalid-parameters path
             "Parameters must be a proper ordered list") issues))
    (when (proper-list-p parameters)
      (dolist (duplicate
               (supertag-ontology-validator--duplicates
                parameters (lambda (parameter) (plist-get parameter :name))))
        (push (supertag-ontology-validator--issue
               :error :duplicate-parameter path
               "Duplicate parameter %S" duplicate) issues))
      (dolist (parameter parameters)
        (let ((parameter-path
               (append path (list :parameter (plist-get parameter :name))))
              (type (plist-get parameter :type))
              (options (plist-get parameter :options)))
          (unless (symbolp (plist-get parameter :name))
            (push (supertag-ontology-validator--issue
                   :error :invalid-parameter-name parameter-path
                   "Parameter name must be a symbol") issues))
          (unless (supertag-ontology-contract-type-valid-p type type-keys)
            (push (supertag-ontology-validator--issue
                   :error :invalid-parameter-type parameter-path
                   "Unsupported parameter type %S" type) issues))
          (when (and (eq type :options) (null options))
            (push (supertag-ontology-validator--issue
                   :error :missing-parameter-options parameter-path
                   "Options parameter needs a non-empty :options list") issues))
          (when (and options (not (eq type :options)))
            (push (supertag-ontology-validator--issue
                   :error :unexpected-parameter-options parameter-path
                   "Only an :options parameter may declare :options") issues))
          (when (cl-some (lambda (option) (not (stringp option))) options)
            (push (supertag-ontology-validator--issue
                   :error :invalid-parameter-option parameter-path
                   "Parameter options must normalize to strings") issues))
          (unless (memq (plist-get parameter :required) '(nil t))
            (push (supertag-ontology-validator--issue
                   :error :invalid-parameter-required parameter-path
                   "Parameter :required must be boolean") issues))
          (unless (memq (plist-get parameter :sensitive) '(nil t))
            (push (supertag-ontology-validator--issue
                   :error :invalid-parameter-sensitive parameter-path
                   "Parameter :sensitive must be boolean") issues))
          (unless (or (null (plist-get parameter :description))
                      (stringp (plist-get parameter :description)))
            (push (supertag-ontology-validator--issue
                   :error :invalid-parameter-description parameter-path
                   "Parameter :description must be a string") issues))
          (dolist (keyword (plist-get parameter :unknown-keywords))
            (push (supertag-ontology-validator--issue
                   :error :unknown-parameter-keyword parameter-path
                   "Unknown parameter keyword %S" keyword) issues))
          (when (and (plist-get parameter :has-default)
                     (not (supertag-ontology-contract-value-valid-p
                           (plist-get parameter :default) type
                           (lambda (value _key)
                             (and (stringp value)
                                  (not (string-empty-p value))))
                           options)))
            (push (supertag-ontology-validator--issue
                   :error :invalid-parameter-default parameter-path
                   "Default value does not satisfy %S" type) issues)))))
    (nreverse issues)))

(defun supertag-ontology-validator--effect-key (effect)
  "Return conflict identity for declarative EFFECT."
  (pcase (plist-get effect :kind)
    ((or :set-field :clear-field)
     (list :field (plist-get effect :field)))
    ((or :add-link :remove-link)
     ;; One Action may define only one transition per Link Definition.  That
     ;; avoids order-dependent create/remove or forward/reverse semantics.
     (list :link (plist-get effect :link)))
    (_ (list :invalid effect))))

(defun supertag-ontology-validator--find-function (functions reference)
  "Resolve local Function REFERENCE in FUNCTIONS."
  (let ((key (cond ((symbolp reference) reference)
                   ((stringp reference)
                    (car (last (split-string reference "/" t)))))))
    (when (stringp key) (setq key (intern key)))
    (cl-find key functions
             :key (lambda (function) (plist-get function :key))
             :test #'eq)))

(defun supertag-ontology-validator--type-descends-p
    (model candidate required)
  "Return non-nil when CANDIDATE equals or extends REQUIRED in MODEL."
  (let ((cursor candidate)
        (seen (make-hash-table :test #'eq))
        found)
    (while (and cursor (not found) (not (gethash cursor seen)))
      (puthash cursor t seen)
      (if (eq cursor required)
          (setq found t)
        (setq cursor
              (plist-get
               (supertag-ontology-model-find model :type cursor)
               :extends))))
    found))

(defun supertag-ontology-validator--parameter (action key)
  "Return Action parameter KEY."
  (cl-find key (plist-get action :parameters)
           :key (lambda (parameter) (plist-get parameter :name))
           :test #'eq))

(defun supertag-ontology-validator--argument-pairs (arguments path)
  "Parse declarative Function ARGUMENTS and return (:pairs ... :issues ...)."
  (let (pairs issues)
    (cond
     ((null arguments))
     ((and (proper-list-p arguments) (keywordp (car arguments)))
      (if (not (zerop (% (length arguments) 2)))
          (push (supertag-ontology-validator--issue
                 :error :invalid-expression-arguments path
                 "Function expression argument plist has odd length") issues)
        (let ((cursor arguments))
          (while cursor
            (let* ((keyword (pop cursor))
                   (value (pop cursor))
                   (name (intern (substring (symbol-name keyword) 1))))
              (push (cons name value) pairs))))))
     ((and (proper-list-p arguments) (cl-every #'consp arguments))
      (dolist (pair arguments)
        (push (cons (supertag-ontology-contract-normalize-name (car pair))
                    (if (and (consp (cdr pair)) (null (cddr pair)))
                        (cadr pair)
                      (cdr pair)))
              pairs)))
     (t
      (push (supertag-ontology-validator--issue
             :error :invalid-expression-arguments path
             "Function expression arguments must be a plist or alist") issues)))
    (setq pairs (nreverse pairs))
    (dolist (duplicate
             (supertag-ontology-validator--duplicates pairs #'car))
      (push (supertag-ontology-validator--issue
             :error :duplicate-expression-argument path
             "Function expression argument %S is repeated" duplicate) issues))
    (list :pairs pairs :issues (nreverse issues))))

(defun supertag-ontology-validator--literal-p (expression)
  "Return non-nil when EXPRESSION is a literal expression."
  (or (and (proper-list-p expression) (eq (car expression) :literal))
      (not (and (proper-list-p expression)
                (memq (car expression) '(:arg :subject :now :function))))))

(defun supertag-ontology-validator--literal-value (expression)
  "Return literal value represented by EXPRESSION."
  (if (and (proper-list-p expression) (eq (car expression) :literal))
      (cadr expression)
    expression))

(defun supertag-ontology-validator--expression-info
    (expression action model functions path &optional depth)
  "Return static type information and issues for EXPRESSION."
  (let ((depth (or depth 0)) issues)
    (if (> depth 16)
        (list :issues
              (list (supertag-ontology-validator--issue
                     :error :expression-depth path
                     "Action expression nesting exceeds 16 levels")))
      (pcase expression
        (`(:arg ,name)
         (let ((parameter
                (supertag-ontology-validator--parameter action name)))
           (unless parameter
             (push (supertag-ontology-validator--issue
                    :error :unknown-effect-argument path
                    "Expression references unknown Action argument %S" name)
                   issues))
           (when (and parameter
                      (not (or (plist-get parameter :required)
                               (plist-get parameter :has-default))))
             (push (supertag-ontology-validator--issue
                    :error :optional-expression-argument path
                    "Expression argument %S must be required or defaulted"
                    name) issues))
           (list :type (and parameter (plist-get parameter :type))
                 :options (and parameter (plist-get parameter :options))
                 :parameter parameter :issues (nreverse issues))))
        (`(:subject)
         (list :type (list :type (plist-get action :subject))
               :issues nil))
        (`(:now) (list :type :timestamp :issues nil))
        (`(:function ,reference . ,tail)
         (let* ((function
                 (supertag-ontology-validator--find-function
                  functions reference))
                (argument-form (plist-get tail :arguments))
                (parsed
                 (supertag-ontology-validator--argument-pairs
                  argument-form path))
                (pairs (plist-get parsed :pairs)))
           (setq issues (nconc (plist-get parsed :issues) issues))
           (unless function
             (push (supertag-ontology-validator--issue
                    :error :unknown-expression-function path
                    "Expression references unknown Function %S" reference)
                   issues))
           (when function
             (dolist (pair pairs)
               (unless (cl-find (car pair) (plist-get function :parameters)
                                :key (lambda (parameter)
                                       (plist-get parameter :name))
                                :test #'eq)
                 (push (supertag-ontology-validator--issue
                        :error :unknown-function-argument path
                        "Function %S has no parameter %S"
                        reference (car pair)) issues)))
             (dolist (parameter (plist-get function :parameters))
               (let* ((name (plist-get parameter :name))
                      (pair (assq name pairs)))
                 (cond
                  (pair
                   (let* ((info
                           (supertag-ontology-validator--expression-info
                            (cdr pair) action model functions path (1+ depth)))
                          (compatible
                           (supertag-ontology-validator--expression-compatible-p
                            info parameter model)))
                     (setq issues (nconc (plist-get info :issues) issues))
                     (unless compatible
                       (push (supertag-ontology-validator--issue
                              :error :incompatible-function-argument path
                              "Expression for Function %S parameter %S cannot satisfy %S"
                              reference name (plist-get parameter :type))
                             issues))))
                  ((and (plist-get parameter :required)
                        (not (plist-get parameter :has-default)))
                   (push (supertag-ontology-validator--issue
                          :error :missing-function-argument path
                          "Function %S requires argument %S"
                          reference name) issues))))))
           (list :type (and function (plist-get function :returns))
                 :function function :issues (nreverse issues))))
        (_
         (if (supertag-ontology-validator--literal-p expression)
             (list :literal-p t
                   :value (supertag-ontology-validator--literal-value expression)
                   :issues nil)
           (list :issues
                 (list (supertag-ontology-validator--issue
                        :error :invalid-action-expression path
                        "Unsupported Action expression %S" expression)))))))))

(defun supertag-ontology-validator--expression-compatible-p
    (info required model)
  "Return non-nil when expression INFO can satisfy REQUIRED parameter/field."
  (let ((required-type (plist-get required :type))
        (required-options (plist-get required :options)))
    (cond
     ((plist-get info :literal-p)
      (supertag-ontology-contract-value-valid-p
       (plist-get info :value) required-type
       (lambda (value _key)
         (and (stringp value) (not (string-empty-p value))))
       required-options))
     ((null (plist-get info :type)) nil)
     ((not
       (supertag-ontology-contract-type-compatible-p
        (plist-get info :type) required-type
        (lambda (candidate expected)
          (supertag-ontology-validator--type-descends-p
           model candidate expected))))
      nil)
     ((eq required-type :options)
      (let ((provided-options (plist-get info :options)))
        (and provided-options
             (cl-every (lambda (option)
                         (member option required-options))
                       provided-options))))
     (t t))))


(defun supertag-ontology-validator--type-fields (model type-key)
  "Return inherited Field keys for TYPE-KEY in MODEL."
  (let ((seen nil) fields cursor)
    (setq cursor (supertag-ontology-model-find model :type type-key))
    (while (and cursor (not (memq (plist-get cursor :key) seen)))
      (push (plist-get cursor :key) seen)
      (setq fields (append (plist-get cursor :fields) fields))
      (setq cursor
            (and (plist-get cursor :extends)
                 (supertag-ontology-model-find
                  model :type (plist-get cursor :extends)))))
    (delete-dups fields)))

(defun supertag-ontology-validator--type-tokens (type)
  "Return every occurrence token TYPE will answer to once deployed."
  (let ((label (plist-get type :label)))
    (delete-dups
     (append (supertag-ontology-model-type-aliases type)
             (and (stringp label) (not (string-empty-p label))
                  (list (supertag-ontology-model--alias-token label)))))))

(defun supertag-ontology-validator-validate (model)
  "Return validation issues for MODEL; never signal for malformed input."
  (condition-case err
      (let* ((module (plist-get model :module))
             (fields (or (plist-get model :fields) nil))
             (types (or (plist-get model :types) nil))
             (links (or (plist-get model :links) nil))
             (functions (or (plist-get model :functions) nil))
             (actions (or (plist-get model :actions) nil))
             (policies (or (plist-get model :policies) nil))
             (field-keys (mapcar (lambda (x) (plist-get x :key)) fields))
             (type-keys (mapcar (lambda (x) (plist-get x :key)) types))
             (link-keys (mapcar (lambda (x) (plist-get x :key)) links))
             (function-keys
              (mapcar (lambda (x) (plist-get x :key)) functions))
             (action-keys
              (mapcar (lambda (x) (plist-get x :key)) actions))
             issues)
        (unless (symbolp module)
          (push (supertag-ontology-validator--issue
                 :error :invalid-module '(module) "Module must be a symbol") issues))
        (unless (integerp (plist-get model :version))
          (push (supertag-ontology-validator--issue
                 :error :invalid-version '(version) "Version must be an integer") issues))
        (dolist (form (plist-get model :unknown-forms))
          (push (supertag-ontology-validator--issue
                 :error :unknown-form '(module) "Unknown ontology form: %S" form) issues))
        (dolist (entity (supertag-ontology-model-entities model))
          (let ((path (list (plist-get entity :kind) (plist-get entity :key))))
            (unless (symbolp (plist-get entity :key))
              (push (supertag-ontology-validator--issue
                     :error :invalid-key path "Entity key must be a symbol") issues))
            (unless (stringp (plist-get entity :label))
              (push (supertag-ontology-validator--issue
                     :error :invalid-label path "Label must be a string") issues))
            (when (and (plist-get entity :runtime-id)
                       (not (stringp (plist-get entity :runtime-id))))
              (push (supertag-ontology-validator--issue
                     :error :invalid-runtime-id path "Runtime ID must be a string") issues))
            (dolist (keyword (plist-get entity :unknown-keywords))
              (push (supertag-ontology-validator--issue
                     :error :unknown-keyword path "Unknown keyword %S" keyword) issues))))
        (dolist (dup (supertag-ontology-validator--duplicates
                      (supertag-ontology-model-entities model)
                      (lambda (x) (cons (plist-get x :kind)
                                        (plist-get x :key)))))
          (push (supertag-ontology-validator--issue
                 :error :duplicate-entity (list (car dup) (cdr dup))
                 "Duplicate ontology entity %S/%S" (car dup) (cdr dup)) issues))
        (dolist (dup (supertag-ontology-validator--duplicates
                      (cl-remove-if-not
                       (lambda (entity) (plist-get entity :runtime-id))
                       (supertag-ontology-model-entities model))
                      (lambda (entity)
                        (cons (plist-get entity :kind)
                              (plist-get entity :runtime-id)))))
          (push (supertag-ontology-validator--issue
                 :error :duplicate-runtime-id (list (car dup) (cdr dup))
                 "Runtime ID %S is assigned to multiple %S entities"
                 (cdr dup) (car dup)) issues))
        (dolist (dup (supertag-ontology-validator--duplicates
                      (supertag-ontology-model-entities model)
                      (lambda (entity)
                        (cons (plist-get entity :kind)
                              (plist-get entity :label)))))
          (push (supertag-ontology-validator--issue
                 :error :duplicate-label (list (car dup) (cdr dup))
                 "Display label %S is used by multiple %S entities"
                 (cdr dup) (car dup)) issues))
        (dolist (field fields)
          (let ((path (list :field (plist-get field :key)))
                (field-type (plist-get field :type))
                (options (plist-get field :options)))
            (unless (memq field-type supertag-field-types)
              (push (supertag-ontology-validator--issue
                     :error :invalid-field-type path
                     "Unsupported field type %S" field-type)
                    issues))
            (unless (supertag-ontology-validator--safe-list-p options)
              (push (supertag-ontology-validator--issue
                     :error :invalid-options path
                     "Field options must be a proper list")
                    issues))
            (when (and (eq field-type :options) (null options))
              (push (supertag-ontology-validator--issue
                     :error :missing-field-options path
                     "Options field needs a non-empty :options list")
                    issues))
            (when (and (proper-list-p options)
                       (cl-some (lambda (option) (not (stringp option)))
                                options))
              (push (supertag-ontology-validator--issue
                     :error :invalid-field-option path
                     "Field options must be strings or symbols")
                    issues))
            (unless (memq (plist-get field :required) '(nil t))
              (push (supertag-ontology-validator--issue
                     :error :invalid-required path
                     "Field :required must be boolean")
                    issues))))
        (dolist (type types)
          (let ((path (list :type (plist-get type :key)))
                (extends (plist-get type :extends))
                (declared-fields (plist-get type :fields)))
            (unless (supertag-ontology-validator--safe-list-p declared-fields)
              (push (supertag-ontology-validator--issue
                     :error :invalid-fields path "Type fields must be a proper list") issues))
            (when (and (proper-list-p declared-fields)
                       (cl-some (lambda (field-key) (not (symbolp field-key)))
                                declared-fields))
              (push (supertag-ontology-validator--issue
                     :error :invalid-fields path
                     "Type :fields must be a list of field key symbols") issues))
            (when (and extends (not (symbolp extends)))
              (push (supertag-ontology-validator--issue
                     :error :invalid-extends path "Type :extends must reference a type key") issues))
            (when (and extends (symbolp extends) (not (memq extends type-keys)))
              (push (supertag-ontology-validator--issue
                     :error :missing-parent path "Unknown parent type %S" extends) issues))
            (when (proper-list-p declared-fields)
              (dolist (field-key declared-fields)
                (when (and (symbolp field-key) (not (memq field-key field-keys)))
                  (push (supertag-ontology-validator--issue
                         :error :missing-field path "Unknown field %S" field-key) issues))))
            (let ((aliases (plist-get type :aliases)))
              (cond
               ((not (supertag-ontology-validator--safe-list-p aliases))
                (push (supertag-ontology-validator--issue
                       :error :invalid-aliases path
                       "Type :aliases must be a list of non-empty strings or symbols")
                      issues))
               ((cl-some (lambda (alias)
                           (or (not (stringp alias)) (string-empty-p alias)))
                         aliases)
                (push (supertag-ontology-validator--issue
                       :error :invalid-alias path
                       "Type :aliases entries must be non-empty strings or symbols")
                      issues))))))
        ;; Occurrence tokens are unique across Tags, so every token a Type
        ;; will answer to (key, label, declared aliases) must be unique
        ;; across the module's Types.  Duplicate keys and labels are reported
        ;; above; this catches an ontology-managed alias (key or declared
        ;; alias) that another Type already claims.
        (let ((claims (make-hash-table :test #'equal)))
          (dolist (type types)
            (dolist (token (supertag-ontology-validator--type-tokens type))
              (puthash token (cons (plist-get type :key) (gethash token claims))
                       claims)))
          (dolist (type types)
            (dolist (alias (supertag-ontology-model-type-aliases type))
              (let ((others (delete-dups
                             (remove (plist-get type :key)
                                     (gethash alias claims)))))
                (when others
                  (push (supertag-ontology-validator--issue
                         :error :alias-collision
                         (list :type (plist-get type :key))
                         "Type alias %S collides with type %S" alias (car others))
                        issues))))))
        (when-let ((cycle (supertag-ontology-validator--inheritance-cycle types)))
          (push (supertag-ontology-validator--issue
                 :error :inheritance-cycle '(:types)
                 "Inheritance cycle: %S" cycle) issues))
        (dolist (link links)
          (let ((path (list :link (plist-get link :key))))
            (unless (memq (plist-get link :from) type-keys)
              (push (supertag-ontology-validator--issue
                     :error :missing-link-source path "Unknown source type %S"
                     (plist-get link :from)) issues))
            (unless (memq (plist-get link :to) type-keys)
              (push (supertag-ontology-validator--issue
                     :error :missing-link-target path "Unknown target type %S"
                     (plist-get link :to)) issues))
            (dolist (slot '(:from-cardinality :to-cardinality))
              (unless (memq (plist-get link slot) '(:one :many))
                (push (supertag-ontology-validator--issue
                       :error :invalid-cardinality path "%S must be one or many" slot)
                      issues)))))
        (dolist (function functions)
          (let ((path (list :function (plist-get function :key))))
            (unless (memq (plist-get function :subject) type-keys)
              (push (supertag-ontology-validator--issue
                     :error :missing-function-subject path
                     "Unknown Function subject Type %S"
                     (plist-get function :subject)) issues))
            (setq issues
                  (nconc issues
                         (supertag-ontology-validator--validate-parameters
                          (plist-get function :parameters) type-keys path)))
            (unless (supertag-ontology-contract-type-valid-p
                     (plist-get function :returns) type-keys)
              (push (supertag-ontology-validator--issue
                     :error :invalid-function-return path
                     "Unsupported Function return type %S"
                     (plist-get function :returns)) issues))
            (unless (and (symbolp (plist-get function :implementation))
                         (fboundp (plist-get function :implementation)))
              (push (supertag-ontology-validator--issue
                     :error :invalid-function-implementation path
                     "Function implementation %S is not defined"
                     (plist-get function :implementation)) issues))
            (setq issues
                  (nconc issues
                         (supertag-ontology-validator--tool-metadata-issues
                          function)))))
        (dolist (action actions)
          (let* ((path (list :action (plist-get action :key)))
                 (parameters (plist-get action :parameters))
                 (effects (plist-get action :effects))
                 (subject (plist-get action :subject))
                 (subject-fields
                  (supertag-ontology-validator--type-fields model subject)))
            (unless (memq subject type-keys)
              (push (supertag-ontology-validator--issue
                     :error :missing-action-subject path
                     "Unknown Action subject Type %S" subject) issues))
            (setq issues
                  (nconc issues
                         (supertag-ontology-validator--validate-parameters
                          parameters type-keys path)))
            (unless (memq (plist-get action :confirmation)
                          '(:never :always :llm :external))
              (push (supertag-ontology-validator--issue
                     :error :invalid-action-confirmation path
                     "Unsupported confirmation mode %S"
                     (plist-get action :confirmation)) issues))
            (setq issues
                  (nconc issues
                         (supertag-ontology-validator--tool-metadata-issues
                          action)))
            (dolist (precondition (plist-get action :preconditions))
              (let* ((reference (plist-get precondition :function))
                     (function
                      (supertag-ontology-validator--find-function
                       functions reference))
                     (operator (or (plist-get precondition :operator) :truthy))
                     (parsed
                      (supertag-ontology-validator--argument-pairs
                       (plist-get precondition :arguments) path))
                     (pairs (plist-get parsed :pairs)))
                (setq issues (nconc (plist-get parsed :issues) issues))
                (unless (and (proper-list-p precondition) function)
                  (push (supertag-ontology-validator--issue
                         :error :invalid-action-precondition path
                         "Precondition references unknown Function %S"
                         reference) issues))
                (unless (memq operator
                              '(:truthy :falsey :equal :not-equal
                                :greater :greater-equal :less :less-equal))
                  (push (supertag-ontology-validator--issue
                         :error :invalid-precondition-operator path
                         "Unsupported precondition operator %S" operator)
                        issues))
                (when function
                  (unless (supertag-ontology-validator--type-descends-p
                           model subject (plist-get function :subject))
                    (push (supertag-ontology-validator--issue
                           :error :incompatible-precondition-subject path
                           "Action subject %S does not satisfy Function subject %S"
                           subject (plist-get function :subject)) issues))
                  (dolist (pair pairs)
                    (unless (cl-find (car pair)
                                     (plist-get function :parameters)
                                     :key (lambda (parameter)
                                            (plist-get parameter :name))
                                     :test #'eq)
                      (push (supertag-ontology-validator--issue
                             :error :unknown-precondition-argument path
                             "Function %S has no parameter %S"
                             reference (car pair)) issues)))
                  (dolist (function-parameter (plist-get function :parameters))
                    (let* ((name (plist-get function-parameter :name))
                           (pair (assq name pairs)))
                      (cond
                       (pair
                        (let ((info
                               (supertag-ontology-validator--expression-info
                                (cdr pair) action model functions path)))
                          (setq issues (nconc (plist-get info :issues) issues))
                          (unless
                              (supertag-ontology-validator--expression-compatible-p
                               info function-parameter model)
                            (push (supertag-ontology-validator--issue
                                   :error :incompatible-precondition-argument path
                                   "Precondition argument %S cannot satisfy Function contract"
                                   name) issues))))
                       ((and (plist-get function-parameter :required)
                             (not (plist-get function-parameter :has-default)))
                        (push (supertag-ontology-validator--issue
                               :error :missing-precondition-argument path
                               "Precondition Function %S requires argument %S"
                               reference name) issues)))))
                  (pcase operator
                    ((or :truthy :falsey)
                     (unless (eq (plist-get function :returns) :boolean)
                       (push (supertag-ontology-validator--issue
                              :error :nonboolean-truth-precondition path
                              "Operator %S requires a boolean Function result"
                              operator) issues)))
                    ((or :greater :greater-equal :less :less-equal)
                     (unless (memq (plist-get function :returns)
                                   '(:integer :number))
                       (push (supertag-ontology-validator--issue
                              :error :nonnumeric-precondition path
                              "Operator %S requires a numeric Function result"
                              operator) issues))
                     (unless (plist-member precondition :value)
                       (push (supertag-ontology-validator--issue
                              :error :missing-precondition-value path
                              "Operator %S requires :value" operator) issues)))
                    ((or :equal :not-equal)
                     (unless (plist-member precondition :value)
                       (push (supertag-ontology-validator--issue
                              :error :missing-precondition-value path
                              "Operator %S requires :value" operator) issues)))
                    (_ nil))
                  (when (and (plist-member precondition :value)
                             (memq operator
                                   '(:equal :not-equal :greater :greater-equal
                                     :less :less-equal)))
                    (let* ((expected-info
                            (supertag-ontology-validator--expression-info
                             (plist-get precondition :value)
                             action model functions path))
                           (return-contract
                            (list :type (plist-get function :returns))))
                      (setq issues
                            (nconc (plist-get expected-info :issues) issues))
                      (unless
                          (supertag-ontology-validator--expression-compatible-p
                           expected-info return-contract model)
                        (push (supertag-ontology-validator--issue
                               :error :incompatible-precondition-value path
                               "Precondition comparison value cannot satisfy Function return type %S"
                               (plist-get function :returns)) issues)))))))
            (unless (and (proper-list-p effects) effects)
              (push (supertag-ontology-validator--issue
                     :error :missing-action-effects path
                     "Action needs a non-empty declarative :effects list") issues))
            (when (proper-list-p effects)
              (dolist (duplicate
                       (supertag-ontology-validator--duplicates
                        effects #'supertag-ontology-validator--effect-key))
                (push (supertag-ontology-validator--issue
                       :error :conflicting-action-effects path
                       "Multiple effects target %S" duplicate) issues))
              (dolist (effect effects)
                (pcase (plist-get effect :kind)
                  ((or :set-field :clear-field)
                   (let* ((field-key (plist-get effect :field))
                          (field
                           (supertag-ontology-model-find
                            model :field field-key)))
                     (unless field
                       (push (supertag-ontology-validator--issue
                              :error :missing-action-field path
                              "Effect references unknown Field %S"
                              field-key) issues))
                     (when (and field (not (memq field-key subject-fields)))
                       (push (supertag-ontology-validator--issue
                              :error :action-field-not-on-subject path
                              "Field %S is not associated with Action subject Type %S"
                              field-key subject) issues))
                     (when (and field
                                (eq (plist-get field :type) :node-reference))
                       (push (supertag-ontology-validator--issue
                              :error :node-reference-field-effect path
                              "Action field effects cannot mutate node-reference Field %S; use a typed Link"
                              field-key) issues))
                     (pcase (plist-get effect :kind)
                       (:set-field
                        (if (not (plist-member effect :value))
                            (push (supertag-ontology-validator--issue
                                   :error :missing-action-value path
                                   "set-field effect requires :value") issues)
                          (let ((info
                                 (supertag-ontology-validator--expression-info
                                  (plist-get effect :value)
                                  action model functions path)))
                            (setq issues
                                  (nconc (plist-get info :issues) issues))
                            (when (and field
                                       (not
                                        (supertag-ontology-validator--expression-compatible-p
                                         info
                                         (list :type (plist-get field :type)
                                               :options (plist-get field :options))
                                         model)))
                              (push (supertag-ontology-validator--issue
                                     :error :incompatible-field-expression path
                                     "set-field value cannot satisfy Field %S type %S"
                                     field-key (plist-get field :type))
                                    issues)))))
                       (:clear-field
                        (when (and field (plist-get field :required))
                          (push (supertag-ontology-validator--issue
                                 :error :clear-required-field path
                                 "Required Field %S cannot be cleared"
                                 field-key) issues))))))
                  ((or :add-link :remove-link)
                   (let* ((link-key (plist-get effect :link))
                          (link
                           (supertag-ontology-model-find model :link link-key))
                          (direction (plist-get effect :direction))
                          (target (plist-get effect :target))
                          (required-subject
                           (and link
                                (plist-get link
                                           (if (eq direction :reverse)
                                               :to :from))))
                          (required-target
                           (and link
                                (plist-get link
                                           (if (eq direction :reverse)
                                               :from :to)))))
                     (unless link
                       (push (supertag-ontology-validator--issue
                              :error :missing-action-link path
                              "Effect references unknown Link %S" link-key)
                             issues))
                     (unless (memq direction '(:forward :reverse))
                       (push (supertag-ontology-validator--issue
                              :error :invalid-action-link-direction path
                              "Link effect direction must be :forward or :reverse")
                             issues))
                     (when (plist-get effect :unanchored)
                       (push (supertag-ontology-validator--issue
                              :error :unanchored-action-link path
                              "Link effect must anchor one endpoint to the Action subject")
                             issues))
                     (when (and link required-subject
                                (not
                                 (supertag-ontology-validator--type-descends-p
                                  model subject required-subject)))
                       (push (supertag-ontology-validator--issue
                              :error :incompatible-action-link-subject path
                              "Action subject %S cannot occupy %S endpoint of Link %S"
                              subject direction link-key) issues))
                     (if (null target)
                         (push (supertag-ontology-validator--issue
                                :error :missing-action-link-target path
                                "Link effect requires a target expression") issues)
                       (let ((info
                              (supertag-ontology-validator--expression-info
                               target action model functions path)))
                         (setq issues (nconc (plist-get info :issues) issues))
                         (unless
                             (or
                              (and (plist-get info :literal-p)
                                   (stringp (plist-get info :value))
                                   (not (string-empty-p
                                         (plist-get info :value))))
                              (eq (plist-get info :type) :node-reference)
                              (and required-target
                                   (supertag-ontology-contract-type-compatible-p
                                    (plist-get info :type)
                                    (list :type required-target)
                                    (lambda (candidate expected)
                                      (supertag-ontology-validator--type-descends-p
                                       model candidate expected)))))
                           (push (supertag-ontology-validator--issue
                                  :error :invalid-action-link-target path
                                  "Link target must be a node-reference or node of Type %S"
                                  required-target) issues))))))
                  (_
                   (push (supertag-ontology-validator--issue
                          :error :invalid-action-effect path
                          "Unsupported Action effect %S" effect) issues)))))))
        (let ((tool-entities
               (cl-remove-if-not
                (lambda (entity)
                  (and (plist-get entity :llm-tool)
                       (stringp (plist-get entity :tool-name))))
                (append functions actions))))
          (dolist (duplicate
                   (supertag-ontology-validator--duplicates
                    tool-entities
                    (lambda (entity) (plist-get entity :tool-name))))
            (push (supertag-ontology-validator--issue
                   :error :duplicate-tool-name '(:tools)
                   "Explicit LLM tool base name %S is used more than once"
                   duplicate)
                  issues)))
        (dolist (duplicate
                 (supertag-ontology-validator--duplicates
                  policies (lambda (policy) (plist-get policy :action))))
          (push (supertag-ontology-validator--issue
                 :error :duplicate-action-policy '(:policies)
                 "Multiple Policies govern Action %S" duplicate)
                issues))
        (dolist (policy policies)
          (let* ((path (list :policy (plist-get policy :key)))
                 (action-key (plist-get policy :action))
                 (actors (plist-get policy :actors)))
            (unless (memq action-key action-keys)
              (push (supertag-ontology-validator--issue
                     :error :missing-policy-action path
                     "Policy references unknown Action %S" action-key)
                    issues))
            (unless (proper-list-p actors)
              (push (supertag-ontology-validator--issue
                     :error :invalid-policy-actors path
                     "Policy :actors must be a proper list") issues))
            (when (proper-list-p actors)
              (dolist (duplicate
                       (supertag-ontology-validator--duplicates
                        actors (lambda (rule)
                                 (and (proper-list-p rule)
                                      (plist-get rule :actor)))))
                (push (supertag-ontology-validator--issue
                       :error :duplicate-policy-actor path
                       "Policy declares actor %S more than once" duplicate)
                      issues))
              (dolist (required
                       '(:interactive-user :automation :llm :external))
                (unless (cl-find required actors
                                 :key (lambda (rule)
                                        (and (proper-list-p rule)
                                             (plist-get rule :actor)))
                                 :test #'eq)
                  (push (supertag-ontology-validator--issue
                         :error :missing-policy-actor path
                         "Policy must declare actor %S" required)
                        issues)))
              (dolist (rule actors)
                (let ((rule-list-p (proper-list-p rule)))
                  (when (and rule-list-p
                             (not (zerop (% (length rule) 2))))
                    (push (supertag-ontology-validator--issue
                           :error :invalid-policy-rule path
                           "Policy actor rule must be an even plist")
                          issues))
                  (when rule-list-p
                    (let ((cursor rule))
                      (while cursor
                        (let ((keyword (pop cursor)))
                          (pop cursor)
                          (unless (memq keyword '(:actor :decision :reason))
                            (push (supertag-ontology-validator--issue
                                   :error :unknown-policy-rule-keyword path
                                   "Unknown Policy rule keyword %S" keyword)
                                  issues))))))
                  (unless (and rule-list-p
                               (memq (plist-get rule :actor)
                                     '(:interactive-user :automation
                                       :llm :external)))
                    (push (supertag-ontology-validator--issue
                           :error :invalid-policy-actor path
                           "Unsupported Policy actor %S"
                           (and rule-list-p (plist-get rule :actor)))
                          issues))
                  (unless (and rule-list-p
                               (memq (plist-get rule :decision)
                                     '(:allow :deny :confirm :propose-only)))
                    (push (supertag-ontology-validator--issue
                           :error :invalid-policy-decision path
                           "Unsupported Policy decision %S"
                           (and rule-list-p (plist-get rule :decision)))
                          issues))
                  (when (and rule-list-p
                             (plist-member rule :reason)
                             (not (stringp (plist-get rule :reason))))
                    (push (supertag-ontology-validator--issue
                           :error :invalid-policy-reason path
                           "Policy rule :reason must be a string")
                          issues)))))))
        (dolist (action actions)
          (unless (cl-find (plist-get action :key) policies
                           :key (lambda (policy)
                                  (plist-get policy :action))
                           :test #'eq)
            (push (supertag-ontology-validator--issue
                   :error :missing-action-policy
                   (list :action (plist-get action :key))
                   "Action %S requires exactly one Policy"
                   (plist-get action :key))
                  issues)))
        (nreverse issues))
    (error
     (list (supertag-ontology-validator--issue
            :error :validator-failure '(:model)
            "Validator could not inspect model: %s" (error-message-string err))))))

(defun supertag-ontology-validator-errors-p (issues)
  "Return non-nil when ISSUES contain an error."
  (cl-some (lambda (issue) (eq (plist-get issue :severity) :error)) issues))

(provide 'supertag-ontology-validator)
;;; supertag-ontology-validator.el ends here
