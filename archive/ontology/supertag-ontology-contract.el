;;; supertag-ontology-contract.el --- Shared Function and Action contracts -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Pure helpers shared by Ontology Function and Ontology Action.  This module
;; normalizes parameter/type contracts and validates ordinary Elisp values.  It
;; does not read or mutate the Supertag Store.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst supertag-ontology-contract-primitive-types
  '(:any :string :number :integer :boolean :date :timestamp :url :email
    :tag :node-reference :options)
  "Primitive values accepted by Function and Action contracts.")

(defconst supertag-ontology-contract--missing
  (make-symbol "supertag-ontology-contract-missing"))

(defun supertag-ontology-contract-normalize-callable-symbol (value)
  "Return VALUE as a named callable symbol when reader syntax wrapped it."
  (cond
   ((symbolp value) value)
   ((and (proper-list-p value)
         (= (length value) 2)
         (eq (car value) 'function)
         (symbolp (cadr value)))
    (cadr value))
   (t value)))

(defun supertag-ontology-contract-copy (value)
  "Return a recursive defensive copy of mutable VALUE.

Unlike `copy-tree', this also copies strings, vectors, hash-table keys and
hash-table values.  Function and Action implementations must not receive
references shared with the canonical Store."
  (cond
   ((hash-table-p value)
    (let ((copy (make-hash-table :test (hash-table-test value)
                                 :size (max 1 (hash-table-size value)))))
      (maphash (lambda (key item)
                 (puthash (supertag-ontology-contract-copy key)
                          (supertag-ontology-contract-copy item)
                          copy))
               value)
      copy))
   ((consp value)
    (cons (supertag-ontology-contract-copy (car value))
          (supertag-ontology-contract-copy (cdr value))))
   ((vectorp value)
    (apply #'vector
           (mapcar #'supertag-ontology-contract-copy (append value nil))))
   ((stringp value) (copy-sequence value))
   (t value)))

(defun supertag-ontology-contract-normalize-name (value)
  "Normalize parameter or entity name VALUE to a symbol when possible."
  (cond ((symbolp value) value)
        ((stringp value) (intern value))
        (t value)))

(defun supertag-ontology-contract-normalize-type (value)
  "Return canonical contract type for VALUE.

Supported compound forms are `(:maybe TYPE)', `(:list TYPE)' and
`(:type TYPE-KEY)'.  A non-keyword symbol names an Ontology Type and is
normalized to `(:type SYMBOL)'."
  (cond
   ((null value) :any)
   ((memq value '(string text :string :text)) :string)
   ((memq value '(number :number)) :number)
   ((memq value '(integer :integer)) :integer)
   ((memq value '(boolean bool :boolean :bool)) :boolean)
   ((memq value '(date :date)) :date)
   ((memq value '(timestamp :timestamp)) :timestamp)
   ((memq value '(url :url)) :url)
   ((memq value '(email :email)) :email)
   ((memq value '(tag :tag)) :tag)
   ((memq value '(node-reference reference :node-reference :reference))
    :node-reference)
   ((memq value '(any :any)) :any)
   ((memq value '(options :options)) :options)
   ((and (proper-list-p value)
         (= (length value) 2)
         (memq (car value) '(:maybe maybe)))
    (list :maybe
          (supertag-ontology-contract-normalize-type (cadr value))))
   ((and (proper-list-p value)
         (= (length value) 2)
         (memq (car value) '(:list list)))
    (list :list
          (supertag-ontology-contract-normalize-type (cadr value))))
   ((and (proper-list-p value)
         (= (length value) 2)
         (memq (car value) '(:type type)))
    (list :type
          (supertag-ontology-contract-normalize-name (cadr value))))
   ((and (symbolp value) (not (keywordp value)))
    (list :type value))
   (t value)))

(defun supertag-ontology-contract-normalize-parameter (raw index)
  "Normalize RAW parameter declared at INDEX without reordering it."
  (let* ((name (and (consp raw)
                    (supertag-ontology-contract-normalize-name (car raw))))
         (plist (and (consp raw) (cdr raw)))
         (known '(:type :options :required :default :sensitive :description))
         unknown)
    (when (proper-list-p plist)
      (let ((cursor plist))
        (while cursor
          (let ((key (pop cursor)))
            (pop cursor)
            (unless (memq key known) (push key unknown))))))
    (list :name name
          :index index
          :type (supertag-ontology-contract-normalize-type
                 (plist-get plist :type))
          :options
          (mapcar (lambda (option)
                    (cond ((stringp option) option)
                          ((symbolp option) (symbol-name option))
                          (t option)))
                  (copy-sequence (or (plist-get plist :options) nil)))
          :required (if (plist-member plist :required)
                        (and (plist-get plist :required) t)
                      (not (plist-member plist :default)))
          :has-default (and (plist-member plist :default) t)
          :default (supertag-ontology-contract-copy
                    (plist-get plist :default))
          :sensitive (and (plist-get plist :sensitive) t)
          :description (plist-get plist :description)
          :unknown-keywords (nreverse unknown)
          :raw raw)))

(defun supertag-ontology-contract-normalize-parameters (raw)
  "Normalize ordered RAW parameter declarations."
  (if (proper-list-p raw)
      (cl-loop for parameter in raw
               for index from 0
               collect (supertag-ontology-contract-normalize-parameter
                        parameter index))
    raw))

(defun supertag-ontology-contract-type-key (type)
  "Return Ontology Type key named by contract TYPE, or nil."
  (when (and (proper-list-p type)
             (= (length type) 2)
             (eq (car type) :type))
    (cadr type)))

(defun supertag-ontology-contract-type-valid-p (type type-keys)
  "Return non-nil when TYPE is supported and references TYPE-KEYS only."
  (cond
   ((memq type supertag-ontology-contract-primitive-types) t)
   ((and (proper-list-p type)
         (= (length type) 2)
         (memq (car type) '(:maybe :list)))
    (supertag-ontology-contract-type-valid-p (cadr type) type-keys))
   ((supertag-ontology-contract-type-key type)
    (memq (supertag-ontology-contract-type-key type) type-keys))
   (t nil)))

(defun supertag-ontology-contract--date-p (value)
  "Return non-nil when VALUE is a conservative ISO date string."
  (and (stringp value)
       (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'"
                       value)))

(defun supertag-ontology-contract--timestamp-p (value)
  "Return non-nil when VALUE is an Emacs time or timestamp string."
  (or (and (consp value) (ignore-errors (time-convert value) t))
      (and (stringp value)
           (or (string-match-p
                "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[T ]" value)
               (string-match-p "\\`[<[][0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}"
                               value)))))

(defun supertag-ontology-contract-value-valid-p
    (value type &optional type-predicate options)
  "Return non-nil when VALUE satisfies TYPE.

TYPE-PREDICATE, when non-nil, receives VALUE and the key from a `(:type KEY)'
contract and must decide whether VALUE identifies a node of that type.
OPTIONS constrains a primitive `:options' parameter."
  (pcase type
    (:any t)
    (:string (stringp value))
    (:number (numberp value))
    (:integer (integerp value))
    (:boolean (memq value '(nil t)))
    (:date (supertag-ontology-contract--date-p value))
    (:timestamp (supertag-ontology-contract--timestamp-p value))
    (:url (and (stringp value)
               (string-match-p "\\`[A-Za-z][A-Za-z0-9+.-]*:" value)))
    (:email (and (stringp value)
                 (string-match-p "\\`[^@[:space:]]+@[^@[:space:]]+\\'" value)))
    (:tag (and (stringp value) (not (string-empty-p value))))
    (:options
     (let ((normalized
            (cond ((stringp value) value)
                  ((symbolp value) (symbol-name value))
                  (t value))))
       (member normalized options)))
    (:node-reference
     (or (and (stringp value) (not (string-empty-p value)))
         (and (proper-list-p value)
              (cl-every (lambda (item)
                          (and (stringp item) (not (string-empty-p item))))
                        value))))
    (`(:maybe ,inner)
     (or (null value)
         (supertag-ontology-contract-value-valid-p
          value inner type-predicate options)))
    (`(:list ,inner)
     (and (proper-list-p value)
          (cl-every
           (lambda (item)
             (supertag-ontology-contract-value-valid-p
              item inner type-predicate options))
           value)))
    (`(:type ,key)
     (and (functionp type-predicate)
          (funcall type-predicate value key)))
    (_ nil)))

(defun supertag-ontology-contract-type-compatible-p
    (provided required &optional type-descends-p)
  "Return non-nil when PROVIDED can safely satisfy REQUIRED.
TYPE-DESCENDS-P receives two Ontology Type keys for `(:type KEY)' contracts."
  (cond
   ((eq required :any) t)
   ((equal provided required) t)
   ((and (eq provided :integer) (eq required :number)) t)
   ((and (proper-list-p required) (eq (car required) :maybe))
    (let ((inner (cadr required)))
      (or (supertag-ontology-contract-type-compatible-p
           provided inner type-descends-p)
          (and (proper-list-p provided)
               (eq (car provided) :maybe)
               (supertag-ontology-contract-type-compatible-p
                (cadr provided) inner type-descends-p)))))
   ((and (proper-list-p provided) (eq (car provided) :maybe)) nil)
   ((and (proper-list-p provided) (eq (car provided) :list)
         (proper-list-p required) (eq (car required) :list))
    (supertag-ontology-contract-type-compatible-p
     (cadr provided) (cadr required) type-descends-p))
   ((and (supertag-ontology-contract-type-key provided)
         (supertag-ontology-contract-type-key required)
         (functionp type-descends-p))
    (funcall type-descends-p
             (supertag-ontology-contract-type-key provided)
             (supertag-ontology-contract-type-key required)))
   (t nil)))

(defun supertag-ontology-contract-parameter-compatible-p
    (provided required &optional type-descends-p)
  "Return non-nil when PROVIDED parameter can satisfy REQUIRED parameter."
  (and (supertag-ontology-contract-type-compatible-p
        (plist-get provided :type) (plist-get required :type) type-descends-p)
       (or (not (eq (plist-get required :type) :options))
           (let ((provided-options (plist-get provided :options))
                 (required-options (plist-get required :options)))
             (and provided-options
                  (cl-every (lambda (option)
                              (member option required-options))
                            provided-options))))))

(defun supertag-ontology-contract--argument-pairs (arguments)
  "Return normalized ordered pairs from ARGUMENTS.

ARGUMENTS may be a plist or an alist.  Explicit nil values remain present."
  (cond
   ((null arguments) nil)
   ((and (proper-list-p arguments) (keywordp (car arguments)))
    (let ((cursor arguments) pairs)
      (unless (zerop (% (length cursor) 2))
        (error "Argument plist has odd length"))
      (while cursor
        (let* ((key (pop cursor))
               (value (pop cursor))
               (name (intern (substring (symbol-name key) 1))))
          (push (cons name value) pairs)))
      (nreverse pairs)))
   ((and (proper-list-p arguments)
         (cl-every #'consp arguments))
    (mapcar
     (lambda (pair)
       (cons (supertag-ontology-contract-normalize-name (car pair))
             (if (and (consp (cdr pair)) (null (cddr pair)))
                 (cadr pair)
               (cdr pair))))
     arguments))
   (t (error "Arguments must be a plist or alist"))))

(defun supertag-ontology-contract-bind-arguments
    (parameters arguments &optional type-predicate)
  "Bind ARGUMENTS to ordered PARAMETERS and validate every supplied value.

Return a plist with:

- `:ordered' — one value per declared parameter; an omitted optional parameter
  without a default is represented by `supertag-ontology-contract--missing';
- `:alist' — only parameters that were supplied or defaulted;
- `:redacted' — the same bounded audit alist with sensitive values redacted.

Explicit nil, false, and empty-list values remain present and are never confused
with omission.  Unknown and duplicate arguments are rejected."
  (let ((pairs (supertag-ontology-contract--argument-pairs arguments))
        (seen (make-hash-table :test #'eq))
        ordered alist redacted)
    (dolist (pair pairs)
      (when (gethash (car pair) seen)
        (error "Duplicate argument %s" (car pair)))
      (puthash (car pair) t seen)
      (unless (cl-find (car pair) parameters
                       :key (lambda (parameter) (plist-get parameter :name))
                       :test #'eq)
        (error "Unknown argument %s" (car pair))))
    (dolist (parameter parameters)
      (let* ((name (plist-get parameter :name))
             (provided (assq name pairs))
             (present-p (and provided t))
             (default-p (plist-get parameter :has-default))
             (value (cond
                     (present-p (cdr provided))
                     (default-p
                      (supertag-ontology-contract-copy
                       (plist-get parameter :default)))
                     ((plist-get parameter :required)
                      (error "Missing required argument %s" name))
                     (t supertag-ontology-contract--missing))))
        (if (eq value supertag-ontology-contract--missing)
            (push value ordered)
          (unless (supertag-ontology-contract-value-valid-p
                   value (plist-get parameter :type) type-predicate
                   (plist-get parameter :options))
            (error "Argument %s does not satisfy %S"
                   name (plist-get parameter :type)))
          (let ((copy (supertag-ontology-contract-copy value)))
            (push copy ordered)
            (push (cons name (supertag-ontology-contract-copy copy)) alist)
            (push (cons name
                        (if (plist-get parameter :sensitive)
                            :redacted
                          (supertag-ontology-contract-copy copy)))
                  redacted)))))
    (list :ordered (nreverse ordered)
          :alist (nreverse alist)
          :redacted (nreverse redacted))))

(defun supertag-ontology-contract-argument-present-p (name bound)
  "Return non-nil when NAME is present in normalized BOUND arguments."
  (and (assq (supertag-ontology-contract-normalize-name name)
             (plist-get bound :alist))
       t))

(defun supertag-ontology-contract-argument (name bound &optional default)
  "Return NAME from BOUND arguments, preserving an explicitly supplied nil."
  (let ((pair (assq (supertag-ontology-contract-normalize-name name)
                    (plist-get bound :alist))))
    (if pair
        (supertag-ontology-contract-copy (cdr pair))
      default)))

(provide 'supertag-ontology-contract)
;;; supertag-ontology-contract.el ends here
