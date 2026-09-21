;;; supertag/ops/field.el --- Field operations for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file provides standardized operations for managing field values
;; associated with nodes and tags in the Supertag data-centric architecture.

;;; Code:

(require 'cl-lib)
(require 'ht)
(require 'subr-x)
(require 'supertag-core-state) ; For supertag--transaction-record-old-value
(require 'supertag-core-store)
(require 'supertag-core-schema)
(require 'supertag-core-transform)
(require 'supertag-core-scan)
(require 'supertag-ops-tag)
(require 'supertag-ops-relation)

(declare-function supertag-ui-select-node "supertag-services-ui"
                  (&optional prompt use-cache with-preview))
(declare-function supertag-ui-select-multiple-nodes "supertag-services-ui"
                  (&optional prompt use-cache initial with-preview))

(defcustom supertag-debug-log-field-events nil
  "When non-nil, log detailed field mutation events and automation processing.
Useful for diagnosing field value loss or unexpected overwrites."
  :type 'boolean
  :group 'supertag)

(defconst supertag-field--missing (list :supertag-field-missing)
  "Sentinel used to detect missing field values.")

(defun supertag-field-resolve-id (tag-id field-name)
  "Resolve FIELD-NAME to its stable global field id.
Prefer TAG-ID's resolved schema, then the global definition registry."
  (let* ((slug (supertag-sanitize-field-id field-name))
         (tag-fields (and tag-id (supertag-tag-get-all-fields tag-id)))
         (field
          (or (cl-find slug tag-fields
                       :key (lambda (definition)
                              (plist-get definition :id))
                       :test #'equal)
              (cl-find field-name tag-fields
                       :key (lambda (definition)
                              (plist-get definition :name))
                       :test #'equal)
              (and slug (supertag-store-get-field-definition slug)))))
    (unless field
      (maphash
       (lambda (_field-id definition)
         (when (and (not field)
                    (equal field-name (plist-get definition :name)))
           (setq field definition)))
       (supertag-store-get-collection :field-definitions)))
    (or (plist-get field :id) slug)))

;; Note: Change notifications are now handled by the unified commit system
;; (supertag-ops-commit). No need for separate notification handling.

;;; --- Field Operations ---

;; 4.1 Field Value Operations

(defconst supertag-field-provenance-origins '(:agent :human)
  "Valid `:origin' values of a field-value provenance record.")

(defconst supertag-field-provenance-keys
  '(:origin :at :model :source-hash :note :previous)
  "Keys a field-value provenance record may carry.")

(defun supertag-field-provenance-timestamp (&optional time)
  "Return TIME (default: now) as an ISO 8601 UTC string."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))

(defun supertag-field-normalize-provenance (provenance)
  "Validate PROVENANCE and return a fresh normalized record.

PROVENANCE is a plist with a required `:origin' (`:agent' or `:human')
and optional string-valued `:at' (ISO 8601 UTC), `:model', `:source-hash'
(the subject node's `:hash' the value was derived from) and `:note'.
`:previous', when present, carries the field value that an agent
overwrote; unlike the descriptive fields it may have any field-value
shape, including nil.  A missing `:at' becomes the current time.
Unknown keys signal."
  (unless (and (consp provenance) (keywordp (car provenance)))
    (error "Provenance must be a plist with an :origin, got %S" provenance))
  (let ((origin (plist-get provenance :origin))
        (rest provenance)
        record)
    (unless (memq origin supertag-field-provenance-origins)
      (error "Provenance :origin must be one of %S, got %S"
             supertag-field-provenance-origins origin))
    (while rest
      (let ((key (pop rest))
            (value (pop rest)))
        (unless (memq key supertag-field-provenance-keys)
          (error "Unknown provenance key %S" key))
        (unless (or (memq key '(:origin :previous))
                    (null value)
                    (stringp value))
          (error "Provenance %s must be a string, got %S" key value))))
    (setq record (list :origin origin
                       :at (or (plist-get provenance :at)
                               (supertag-field-provenance-timestamp))))
    (dolist (key '(:model :source-hash :note))
      (when-let* ((value (plist-get provenance key)))
        (setq record (append record (list key value)))))
    (when (plist-member provenance :previous)
      (setq record
            (append record
                    (list :previous
                          (copy-tree (plist-get provenance :previous))))))
    record))

(defun supertag-field--definition (tag-id field-name)
  "Return FIELD-NAME's schema definition in TAG-ID's context."
  (or (supertag-tag-get-field tag-id field-name)
      (when-let* ((field-id (supertag-field-resolve-id tag-id field-name)))
        (supertag-global-field-get field-id))))

(defun supertag-field--normalize-date-value (value)
  "Return VALUE as a canonical YYYY-MM-DD date string.

String values use `org-read-date', so the same inputs accepted by the
interactive field editor (for example, \"today\" and \"+3d\") are valid.
Numeric day counts and the decoded-time lists produced by older writers
remain readable during normalization."
  (require 'org)
  (let ((time
         (cond
          ((stringp value)
           (let* ((text (string-trim value))
                  (lower (downcase text))
                  (org-input
                   (cond
                    ((string= lower "today") "+0d")
                    ((string= lower "tomorrow") "+1d")
                    ((string= lower "yesterday") "-1d")
                    ((string-match
                      "\\`\\([+-][0-9]+\\)\\s-*\\(day\\|week\\|month\\|year\\)s?\\'"
                      lower)
                     (format "%s%s"
                             (match-string 1 lower)
                             (pcase (match-string 2 lower)
                               ("day" "d")
                               ("week" "w")
                               ("month" "m")
                               ("year" "y"))))
                    (t text))))
             (org-read-date nil t org-input)))
          ((numberp value) (seconds-to-time (* value 24 3600)))
          ((and (listp value) (>= (length value) 6))
           (apply #'encode-time value))
          ;; Emacs time values are commonly two- or four-element lists.
          ((consp value) value)
          (t (error "Cannot convert to date: %S" value)))))
    (format-time-string "%Y-%m-%d" time)))

(defun supertag-field--convert-schema-value (value type)
  "Convert VALUE according to field TYPE, including Supertag-only types."
  (pcase type
    (:date (supertag-field--normalize-date-value value))
    (:node-reference (supertag-field-pack-node-reference-value value))
    (_ (supertag--convert-type value type))))

(defun supertag-field--expected-value-description (field-def)
  "Return a user-facing description of values accepted by FIELD-DEF."
  (let ((type (or (plist-get field-def :type) :string)))
    (pcase type
      (:options
       (format "options from %S" (plist-get field-def :options)))
      (:node-reference "a node ID or a list of node IDs")
      (_ (substring (symbol-name type) 1)))))

(defun supertag-field--normalize-for-write
    (tag-id field-name value field-def)
  "Normalize and validate VALUE for FIELD-NAME, or signal a clear user error."
  (condition-case cause
      (let ((normalized (supertag-field-normalize tag-id field-name value)))
        (unless (supertag-field-validate tag-id field-name normalized)
          (error "the schema rejected this value"))
        normalized)
    (error
     (user-error "Field '%s' expects %s; you supplied %S (%s)"
                 (or (plist-get field-def :name) field-name)
                 (supertag-field--expected-value-description field-def)
                 value
                 (error-message-string cause)))))

(defun supertag-field-set (node-id tag-id field-name value &optional provenance)
  "Set a global field value for NODE-ID.
NODE-ID is the unique identifier of the node.
TAG-ID supplies schema context and remains in the public signature.
FIELD-NAME is resolved to the canonical global field id.

PROVENANCE, when non-nil, records who asserted VALUE (see
`supertag-field-normalize-provenance'); it is stored beside the value in
the `:field-provenance' sidecar and never changes the value itself.  A
writer that passes no PROVENANCE makes no claim: when it changes the value
any earlier provenance record is dropped, when the value is unchanged the
record is kept.  A literal nil VALUE means remove the stored value and its
provenance; schema defaults remain a read-time fallback supplied by
`supertag-field-get-with-default'."
  (let* ((fid (supertag-field-resolve-id tag-id field-name))
         (field-def (and fid (supertag-global-field-get fid))))
    (unless fid
      (error "Field name is required"))
    (unless field-def
      (error "Global field '%s' not defined" fid))
    (if (null value)
        (progn
          (supertag-field-remove node-id tag-id field-name)
          nil)
      (let* ((normalized (supertag-field--normalize-for-write
                          tag-id field-name value field-def))
             (record (and provenance
                          (supertag-field-normalize-provenance provenance)))
             (old-raw (supertag-node-get-global-field
                       node-id fid supertag-field--missing))
             (exists (not (eq old-raw supertag-field--missing)))
             (old (and exists old-raw))
             (same (and exists (equal old normalized)))
             (old-record (supertag-store-get-field-provenance node-id fid)))
        (if (and same (or (null record) (equal record old-record)))
            old
          (supertag-with-transaction
            (unless same
              ;; The field value is authoritative; its relation is only a
              ;; rebuildable query projection.
              (supertag-node-set-global-field node-id fid normalized)
              (when (eq (plist-get field-def :type) :node-reference)
                (supertag-relation-reconcile-field-reference node-id fid))
              (when (and (boundp 'supertag-automation-sync--enabled)
                         supertag-automation-sync--enabled)
                (require 'supertag-automation-sync)
                (when (fboundp
                       'supertag-automation-sync--process-global-field-change)
                  (supertag-automation-sync--process-global-field-change
                   node-id fid old normalized))))
            (cond
             (record (supertag-store-put-field-provenance node-id fid record))
             (old-record (supertag-store-remove-field-provenance node-id fid)))
            (when supertag-debug-log-field-events
              (message "supertag-field-set node=%s tag=%s field=%s old=%S new=%S provenance=%S"
                       node-id tag-id fid old normalized record))
            normalized))))))

(defun supertag-field-set-many (node-id specs)
  "Set global field SPECS for NODE-ID.
Each spec contains :tag, :field, :value and an optional :provenance."
  (supertag-with-transaction
    (dolist (spec specs)
      (supertag-field-set node-id
                          (plist-get spec :tag)
                          (plist-get spec :field)
                          (plist-get spec :value)
                          (plist-get spec :provenance))))
  specs)

(defun supertag-field-provenance (node-id tag-id field-name)
  "Return the provenance record of NODE-ID's FIELD-NAME value, or nil.
TAG-ID supplies schema context.  A value written without provenance has
no record and is treated as a plain fact.  The record is a fresh copy."
  (when-let* ((fid (supertag-field-resolve-id tag-id field-name))
              (record (supertag-store-get-field-provenance node-id fid)))
    (copy-sequence record)))

(defun supertag-field-confirm (node-id tag-id field-name)
  "Record that a person confirmed NODE-ID's current FIELD-NAME value.
The value is untouched; its provenance becomes `:human', so an agent
projection turns into a fact.  Signal when the field has no stored value.
Return the new provenance record."
  (let* ((fid (supertag-field-resolve-id tag-id field-name))
         (current (and fid (supertag-node-get-global-field
                            node-id fid supertag-field--missing))))
    (when (or (null fid) (eq current supertag-field--missing))
      (error "Field '%s' has no value on node %s to confirm"
             field-name node-id))
    (supertag-with-transaction
      (supertag-store-put-field-provenance
       node-id fid (supertag-field-normalize-provenance '(:origin :human))))))

(defun supertag-field-stale-p (node-id tag-id field-name)
  "Return non-nil when NODE-ID's FIELD-NAME value is an outdated agent projection.
A value is stale when its provenance is `:agent' with a `:source-hash'
that no longer matches the node's current `:hash' (maintained by sync).
Human-confirmed values, values without provenance, and values whose
hashes are unknown are never stale."
  (let* ((record (supertag-field-provenance node-id tag-id field-name))
         (source-hash (plist-get record :source-hash))
         (node-hash (and source-hash
                         (plist-get (supertag-store-get-entity :nodes node-id)
                                    :hash))))
    (and (eq (plist-get record :origin) :agent)
         (stringp source-hash)
         (stringp node-hash)
         (not (string= source-hash node-hash)))))

(defun supertag-field-get (node-id tag-id field-name &optional default)
  "Return NODE-ID's global FIELD-NAME value, or DEFAULT.
TAG-ID remains as schema context for API compatibility."
  (if-let* ((field-id (supertag-field-resolve-id tag-id field-name)))
      (supertag-node-get-global-field node-id field-id default)
    default))

(cl-defun supertag-field-rename (tag-id old-name new-name)
  "Rename a field on TAG-ID from OLD-NAME to NEW-NAME.
Signals an error if the source field is missing or the target already exists.
The stable field id and all node values remain unchanged."
  (unless (and (stringp tag-id) (not (string-empty-p tag-id)))
    (error "Invalid tag id: %S" tag-id))
  (unless (and (stringp old-name) (not (string-empty-p old-name)))
    (error "Invalid old field name: %S" old-name))
  (unless (and (stringp new-name) (not (string-empty-p new-name)))
    (error "Invalid new field name: %S" new-name))
  (when (string= old-name new-name)
    (cl-return-from supertag-field-rename
      (list :status :skipped :reason "Names are identical")))
  (let ((existing (supertag-tag-get-field tag-id old-name))
        (target (supertag-tag-get-field tag-id new-name)))
    (unless existing
      (error "Field '%s' not found on tag '%s'" old-name tag-id))
    (when target
      (error "Field '%s' already exists on tag '%s'" new-name tag-id)))
  (cl-labels
      ((rewrite-field-name (value)
         (cond
          ((and (stringp value) (string= value old-name)) new-name)
          ((keywordp value)
           (let ((name (substring (symbol-name value) 1)))
             (if (string= name old-name)
                 (intern (concat ":" new-name))
               value)))
          ((symbolp value)
           (let ((name (symbol-name value)))
             (if (string= name old-name)
                 (intern new-name)
               value)))
          (t value)))
       (ensure-plist (data)
         (cond
          ((hash-table-p data)
           (let (plist)
             (maphash (lambda (k v)
                        (setq plist (plist-put plist k v)))
                      data)
             plist))
          ((listp data) (copy-tree data))
          (t data))))
    (supertag-with-transaction
      ;; Rename the shared definition in place; the stable field id and all
      ;; node values remain unchanged.
      (supertag-tag-rename-field tag-id old-name new-name)
      ;; Update relation metadata that references this field.
      (let ((relations (supertag-store-get-collection :relations)))
        (maphash
         (lambda (rel-id rel-data)
           (let* ((rel-plist (ensure-plist rel-data))
                  (updated nil))
             ;; Update :sync-fields list.
             (when-let ((fields (plist-get rel-plist :sync-fields)))
               (let ((new-fields (mapcar #'rewrite-field-name fields)))
                 (unless (equal new-fields fields)
                   (setq rel-plist (plist-put rel-plist :sync-fields new-fields))
                   (setq updated t))))
             ;; Update :rollup-field if present.
             (when-let ((rollup (plist-get rel-plist :rollup-field)))
               (let ((new-rollup (rewrite-field-name rollup)))
                 (unless (equal new-rollup rollup)
                   (setq rel-plist (plist-put rel-plist :rollup-field new-rollup))
                   (setq updated t))))
             ;; Update nested :props keys that may reference field names.
             (when-let ((props (plist-get rel-plist :props)))
               (let* ((props-plist (ensure-plist props))
                      (props-updated nil))
                 (dolist (key '(:from-property :to-property :rollup-field))
                   (when (plist-member props-plist key)
                     (let* ((val (plist-get props-plist key))
                            (new-val (rewrite-field-name val)))
                       (unless (equal new-val val)
                         (setq props-plist (plist-put props-plist key new-val))
                         (setq props-updated t)))))
                 (when props-updated
                   (setq rel-plist (plist-put rel-plist :props props-plist))
                   (setq updated t))))
             (when updated
               (supertag-store-put-entity :relations rel-id rel-plist t))))
         relations))
      (list :status :renamed :tag-id tag-id :from old-name :to new-name))))

(defun supertag-field-get-with-default (node-id tag-id field-name)
  "Get field value for NODE-ID/TAG-ID/FIELD-NAME, falling back to schema default.
Uses the global field Store exclusively."
  (let* ((fid (supertag-field-resolve-id tag-id field-name))
         (value (and fid (supertag-node-get-global-field
                          node-id fid supertag-field--missing))))
    (if (eq value supertag-field--missing)
        (when-let* ((field-def (supertag-tag-get-field tag-id field-name)))
          (let ((default (plist-get field-def :default)))
            (if (functionp default) (funcall default) default)))
      value)))

(cl-defun supertag-field-remove (node-id tag-id field-name)
  "Remove NODE-ID's global FIELD-NAME value.
NODE-ID is the unique identifier of the node.
TAG-ID supplies schema context.  Return the removed value, or nil."
  (let* ((fid (supertag-field-resolve-id tag-id field-name))
         (field-def (and fid (supertag-global-field-get fid)))
         (old (and fid (supertag-node-get-global-field
                        node-id fid supertag-field--missing))))
    (unless (or (not fid) (eq old supertag-field--missing))
      (supertag-with-transaction
        (supertag-store-remove-field-value node-id fid)
        (supertag-store-remove-field-provenance node-id fid)
        (when (eq (plist-get field-def :type) :node-reference)
          (supertag-relation-reconcile-field-reference node-id fid))
        (when supertag-debug-log-field-events
          (message "supertag-field-remove %s/%s/%s" node-id tag-id fid))
        old))))

;; 4.2 Field Validation and Normalization

(defun supertag-field-validate (tag-id field-name value)
  "Validate a field value against the tag's field definition.
TAG-ID is the unique identifier of the tag.
FIELD-NAME is the name of the field.
VALUE is the value to validate.
Returns t if validation passes, otherwise nil."
  (let ((field-def (supertag-field--definition tag-id field-name)))
    (unless field-def
      (error "Field '%s' not defined for tag '%s'." field-name tag-id))

    (let ((type (plist-get field-def :type))
          (options (plist-get field-def :options))
          (validator (plist-get field-def :validator)))
      (and
       ;; Type check.  `supertag--convert-type' signals when VALUE cannot
       ;; be coerced to TYPE; a successful conversion may legitimately
       ;; yield nil (a :boolean false, an empty :tag list), so test for the
       ;; signal, not for the truthiness of the converted value.
       (progn (supertag-field--convert-schema-value value type) t)
       ;; Options check.  VALUE is either a single option (scalar string)
       ;; or a list of options (multi select); every selection must be
       ;; one of the declared :options.
       (or (null options)
           (if (and (consp value) (proper-list-p value))
               (cl-every (lambda (item) (member item options)) value)
             (member value options)))
       ;; Custom validator
       (or (null validator) (funcall validator value))))))

(defun supertag-field-normalize (tag-id field-name value)
  "Normalize a field value according to the tag's field definition.
TAG-ID is the unique identifier of the tag.
FIELD-NAME is the name of the field.
VALUE is the value to normalize.  Literal nil remains nil: schema defaults
are applied only when a missing value is read, never during an explicit write.
Returns the normalized value."
  (let ((field-def (supertag-field--definition tag-id field-name)))
    (unless field-def
      (error "Field '%s' not defined for tag '%s'." field-name tag-id))

    (let ((type (plist-get field-def :type)))
      (cond
       ;; Preserve explicit nil so write paths can interpret it as removal.
       ((null value) nil)
       ;; Convert type
       (type (supertag-field--convert-schema-value value type))
       ;; Otherwise, return as is
       (t value)))))

;; 4.3 Interactive Field Definition Utilities

(defun supertag-field-read-date-value (&optional prompt)
  "Interactive helper to read a date value with user-friendly options.
PROMPT is the optional prompt string to display.
Returns a date string in a format supported by supertag--convert-to-timestamp."
  (let* ((prompt (or prompt "Enter date: "))
         (choices '("today" "tomorrow" "yesterday"
                   "+1 day" "+3 days" "+7 days" "+1 week" "+1 month"
                   "-1 day" "-3 days" "-7 days" "-1 week" "-1 month"
                   "Use org-read-date (calendar picker)"
                   "Enter custom format"))
         (choice (completing-read
                 (concat prompt "(choose option or type directly): ")
                 choices nil nil)))
    (cond
     ;; User selected a predefined option
     ((member choice choices)
      (cond
       ((string= choice "Use org-read-date (calendar picker)")
        ;; Use org-mode's built-in date picker
        (require 'org)
        (format-time-string "%Y-%m-%d" (org-read-date t t)))
       ((string= choice "Enter custom format")
        ;; Let user enter custom format with help
        (read-string
         "Enter date (formats: 2024-01-15, today, +3 days): "))
       (t choice))) ; Return the predefined choice directly
     ;; User typed something directly
     (t choice))))

(defun supertag-field-read-timestamp-value (&optional prompt)
  "Interactive helper to read a timestamp value (usually auto-generated).
PROMPT is the optional prompt string to display.
For timestamp fields, usually auto-generation is preferred."
  (let* ((prompt (or prompt "Set timestamp: "))
         (choices '("now (current time)"
                   "Use org-read-date (specific date & time)"
                   "Enter ISO format (2024-01-15 14:30)"
                   "Enter custom format"))
         (choice (completing-read
                 (concat prompt "(choose option): ")
                 choices nil t)))
    (cond
     ((string= choice "now (current time)")
      "now")
     ((string= choice "Use org-read-date (specific date & time)")
      ;; Use org-mode's built-in date picker with time
      (require 'org)
      (org-read-date t t nil "Select date and time: "))
     ((string= choice "Enter ISO format (2024-01-15 14:30)")
      (read-string "Enter timestamp (YYYY-MM-DD HH:MM): "))
     ((string= choice "Enter custom format")
      (read-string "Enter timestamp (formats: now, 2024-01-15 14:30): "))
     (t choice))))

(defun supertag-field-normalize-node-reference-list (value)
  "Return VALUE as a list of node reference IDs.
VALUE can be nil, a string, or a list of strings. Filters out empty entries."
  (let* ((candidates (cond
                      ((null value) '())
                      ((and (listp value) (not (stringp value))) value)
                      ((stringp value) (list value))
                      (t (list (format "%s" value)))))
         (cleaned (cl-remove-if
                   (lambda (item)
                     (or (null item)
                         (and (stringp item) (string-empty-p item))))
                   (mapcar (lambda (item)
                             (cond
                              ((null item) nil)
                              ((stringp item) item)
                              (t (format "%s" item))))
                           candidates))))
    cleaned))

(defun supertag-field-pack-node-reference-value (values)
  "Pack VALUES (list of node IDs) back into stored field form.
Returns nil for empty list, the single element when only one node is present,
or the original list when multiple nodes are selected."
  (let ((normalized (supertag-field-normalize-node-reference-list values)))
    (pcase normalized
      ('() nil)
      (`(,single) single)
      (_ normalized))))

(defun supertag-field-read-type-with-options (current-type)
  "Interactively read a field type and options when needed.
CURRENT-TYPE is used to preselect the existing type.
Returns a cons cell (TYPE . OPTIONS) where OPTIONS is a list for
:options type, or nil for other types."
  (let* ((builtin-descriptions '((:string . "string - Plain text")
                                 (:number . "number - Numeric value")
                                 (:integer . "integer - Whole number")
                                 (:boolean . "boolean - True/False")
                                 (:date . "date - User-input date (supports: 2024-01-15, today, +3 days)")
                                 (:timestamp . "timestamp - Auto-generated timestamp (created/modified time)")
                                 (:options . "options - Multiple choice")
                                 (:url . "url - Web address")
                                 (:email . "email - Email address")
                                 (:tag . "tag - Tag reference(s)")
                                 (:node-reference . "node - Reference to another node")))
         (type-pairs (mapcar (lambda (type)
                               (cons type (or (alist-get type builtin-descriptions)
                                              (symbol-name type))))
                             supertag-field-types))
         (current-desc (or (alist-get current-type type-pairs)
                           (symbol-name (or current-type :string))))
         (selection (completing-read "Field type: "
                                     (mapcar #'cdr type-pairs)
                                     nil t current-desc))
         (new-type (car (cl-find-if (lambda (pair)
                                      (string= (cdr pair) selection))
                                    type-pairs))))
    (setq new-type (or new-type current-type :string))
    (if (eq new-type :options)
        (let* ((options-input (read-string "Options (comma separated): "))
               (options-list (split-string options-input "," t "[ \t\n\r]+")))
          (cons new-type options-list))
      (cons new-type nil))))

(defun supertag-field-read-value-with-type-assistance (field-type &optional prompt current-value)
  "Read a field value with type-specific assistance.
FIELD-TYPE is the field type (e.g., :timestamp, :boolean, :options).
PROMPT is the optional prompt string.
CURRENT-VALUE is the current value (for editing).
Returns the user input appropriate for the field type."
  (let ((prompt (or prompt (format "Enter %s value: " (substring (symbol-name field-type) 1)))))
    (pcase field-type
      (:timestamp (supertag-field-read-timestamp-value prompt))
      (:boolean (if (y-or-n-p (or prompt "Enable this option? ")) "true" "false"))
      (:date (supertag-field-read-date-value prompt))
      (:node-reference
       (let* ((initial (supertag-field-normalize-node-reference-list current-value))
              (selected (supertag-ui-select-multiple-nodes
                         (or prompt "Select node (RET to finish): ")
                         t
                         initial)))
         (supertag-field-pack-node-reference-value selected)))
      (:options (read-string prompt current-value)) ; Could be enhanced further
      (:integer (read-string prompt (if current-value (format "%s" current-value) "")))
      (:number (read-string prompt (if current-value (format "%s" current-value) "")))
      (_ (read-string prompt current-value)))))

(provide 'supertag-ops-field)
