;;; supertag-migration-preflight.el --- Read-only migration inventory -*- lexical-binding: t; -*-

;; This internal module is deliberately not loaded by normal startup.
;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)

(defun supertag-migration-preflight--plist-p (value)
  "Whether VALUE is a proper, keyword-keyed plist."
  (and (proper-list-p value)
       (cl-evenp (length value))
       (cl-loop for tail on value by #'cddr always (keywordp (car tail)))))

(defun supertag-migration-preflight--entries (table)
  "Return TABLE entries sorted by printed key without mutating TABLE."
  (let (entries)
    (when (hash-table-p table)
      (maphash (lambda (key value) (push (cons key value) entries)) table))
    (sort entries (lambda (a b)
                    (string< (prin1-to-string (car a))
                             (prin1-to-string (car b)))))))

(defun supertag-migration-preflight--property-name (field)
  "Return the existing export spelling of FIELD, not a migration decision."
  ;; Same pure conversion as supertag-export--sanitize-symbol-component.
  ;; Do not load that service: it loads runtime Store/operation dependencies.
  (let ((name (replace-regexp-in-string "[^A-Z0-9_]" "_" (upcase field))))
    (if (string-empty-p name) "FIELD" name)))

(defun supertag-migration-preflight--source (file)
  "Read local absolute FILE, preferring existing unsaved buffer contents.
Return copied text.  Do not visit files or run their local variables/hooks."
  (unless (and (stringp file) (file-name-absolute-p file)
               (not (file-remote-p file)))
    (error "Source must be an explicit absolute local file"))
  (unless (file-regular-p file)
    (error "Source file is missing or not regular: %s" file))
  (let ((buffer (find-buffer-visiting file)))
    (if buffer
        (with-current-buffer buffer
          (save-restriction
            (widen)
            (buffer-substring-no-properties (point-min) (point-max))))
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(defun supertag-migration-preflight--properties (text id)
  "Read properties of the unique heading with ID in copied TEXT.
Do not use projected offsets, inherited properties or global ID locations."
  (with-temp-buffer
    (insert text)
    (let ((org-inhibit-startup t))
      (delay-mode-hooks (org-mode)))
    (let (matches)
      (org-map-entries
       (lambda ()
         (when (equal (org-entry-get nil "ID" nil) id)
           (push (org-entry-properties nil 'standard) matches)))
       nil nil)
      (unless (= (length matches) 1)
        (error "Expected one heading for ID %s, found %d" id (length matches)))
      (car matches))))

(defun supertag-migration-preflight--value (value definition)
  "Return (SUPPORTED . STRING) for a conservatively supported VALUE.
Complex/date/reference values require a migration policy and are not guessed."
  (let ((type (plist-get definition :type)))
    (cond
     ((eq type :boolean)
      (when (memq value '(nil t)) (cons t (if value "true" "false"))))
     ((not (memq type '(nil :string :text :number :integer :float))) nil)
     ((stringp value) (cons t value))
     ((numberp value) (cons t (number-to-string value)))
     ((null value) (cons t "")))))

(defun supertag-migration-preflight (store)
  "Inventory explicit in-memory STORE without applying any migration.
Return a deterministic plist with :fields, :tags, :automations,
:semantic-edges, :concept-markers and :issues.  Field :status is missing,
equal, conflicting, unsupported or unavailable.  Property names describe
the legacy export spelling only; collisions and reserved properties block
using that spelling.  Issues make partial/unsupported coverage explicit.

Only source paths and IDs explicitly present in STORE are inspected.  No
Store load, initialization, collection creation, buffer edit, save, global
ID lookup or network access is performed.  The result is an inventory,
not a validated write plan or permission to discard unreported data."
  (unless (hash-table-p store) (error "STORE must be an explicit hash table"))
  (let ((definitions (gethash :field-definitions store))
        (tags (gethash :tags store))
        (sources (make-hash-table :test 'equal))
        (node-properties (make-hash-table :test 'equal))
        fields tag-report rules edges concepts issues)
    (cl-labels
        ((issue (kind &rest details) (push (cons kind details) issues))
         (collection (key)
           (let ((value (gethash key store)))
             (when (and value (not (hash-table-p value)))
               (issue :malformed-collection key))
             (supertag-migration-preflight--entries value)))
         (tag-path (id seen)
           (when (member id seen) (error "Cyclic tag parent at %s" id))
           (let ((tag (and (hash-table-p tags) (gethash id tags))))
             (unless (and (supertag-migration-preflight--plist-p tag)
                          (stringp (plist-get tag :name)))
               (error "Missing/malformed tag %s" id))
             (if-let* ((parent (plist-get tag :extends)))
                 (concat (tag-path parent (cons id seen)) "/" (plist-get tag :name))
               (plist-get tag :name)))))
      ;; Read every known node, including nodes with only a concept marker.
      (dolist (entry (collection :nodes))
        (let ((id (car entry)) (node (cdr entry)))
          (condition-case err
              (progn
                (unless (and (stringp id)
                             (supertag-migration-preflight--plist-p node)
                             (or (not (plist-get node :id))
                                 (equal id (plist-get node :id))))
                  (error "Malformed node"))
                (let* ((file (plist-get node :file))
                       (text (or (gethash file sources)
                                 (let ((text (supertag-migration-preflight--source file)))
                                   (puthash file text sources) text)))
                       (props (supertag-migration-preflight--properties text id)))
                  (puthash id props node-properties)
                  (when-let* ((marker (assoc "SUPERTAG_CONCEPT" props)))
                    (push (list :node id :file file :value (cdr marker)) concepts))))
            (error (issue :source-unavailable id (error-message-string err))))))
      (dolist (entry (collection :field-values))
        (let ((id (car entry)) (values (cdr entry))
              (names (make-hash-table :test 'equal)))
          (unless (gethash id node-properties)
            (issue :field-source-unavailable id))
          (unless (hash-table-p values) (issue :malformed-field-values id))
          (dolist (field (supertag-migration-preflight--entries values))
            (let* ((fid (car field))
                   (definition (and (hash-table-p definitions) (gethash fid definitions)))
                   (name (and (stringp fid) (supertag-migration-preflight--property-name fid)))
                   (converted (and name
                                   (supertag-migration-preflight--plist-p definition)
                                   (supertag-migration-preflight--value (cdr field) definition)))
                   (props (gethash id node-properties))
                   (existing (and name (assoc name props)))
                   (status (cond ((not converted) 'unsupported)
                                 ((not props) 'unavailable)
                                 ((not existing) 'missing)
                                 ((equal (cdr existing) (cdr converted)) 'equal)
                                 (t 'conflicting))))
              (when name (puthash name (cons fid (gethash name names)) names))
              (when (and name (assoc (concat "ST_" name) props))
                (issue :unsupported-legacy-property id fid (concat "ST_" name)))
              (unless converted (issue :unsupported-field-value id fid))
              (when (member name '("ID" "CUSTOM_ID" "CATEGORY" "SUPERTAG_CONCEPT"))
                (issue :reserved-property id fid name))
              (when (and definitions definition
                         (not (supertag-migration-preflight--plist-p definition)))
                (issue :malformed-field-definition fid))
              (push (list :node id :field fid :property name :status status
                          :proposed (cdr converted) :existing (cdr existing)) fields)))
          (dolist (mapping (supertag-migration-preflight--entries names))
            (when (cdr (cdr mapping))
              (issue :property-name-collision id (car mapping)
                     (sort (copy-sequence (cdr mapping)) #'string<))))))
      (collection :field-definitions)
      (when (gethash :fields store)
        (let ((legacy (gethash :fields store)))
          (unless (and (hash-table-p legacy) (= (hash-table-count legacy) 0))
            (issue :unsupported-legacy-fields))))
      (dolist (entry (collection :tags))
        (condition-case err
            (let ((id (car entry)) (tag (cdr entry)))
              (unless (and (stringp id) (supertag-migration-preflight--plist-p tag))
                (error "Malformed tag"))
              (push (list :id id :name (plist-get tag :name)
                          :parent (plist-get tag :extends)
                          :path (tag-path id nil)
                          :aliases (copy-tree (plist-get tag :aliases))) tag-report))
          (error (issue :tag-mapping-unavailable (car entry) (error-message-string err)))))
      (dolist (entry (collection :automations))
        (push (list :id (car entry) :requires-durable-configuration t) rules)
        (unless (supertag-migration-preflight--plist-p (cdr entry))
          (issue :malformed-automation (car entry))))
      (dolist (entry (collection :relations))
        (let* ((relation (cdr entry))
               (valid (supertag-migration-preflight--plist-p relation))
               (kind (and valid (plist-get relation :kind)))
               (origin (and valid (plist-get relation :origin)))
               (type (and valid (plist-get relation :type))))
          (if (not (and (supertag-migration-preflight--plist-p relation)
                        (keywordp type)))
              (issue :malformed-relation (car entry))
            (cond
             ((not (cl-every (lambda (value) (and (stringp value) (not (string-empty-p value))))
                            (list (plist-get relation :from) (plist-get relation :to))))
              (issue :invalid-relation-endpoints (car entry)))
             ((not
               (pcase kind
                 (:semantic-edge (memq origin '(nil :semantic)))
                 (:document-link (and (memq origin '(nil :org)) (eq type :reference)))
                 (:tag-membership (and (memq origin '(nil :org)) (eq type :node-tag)))
                 ('nil (pcase origin
                         ((or 'nil :semantic) t)
                         (:org (memq type '(:reference :node-tag)))
                         (:field-value (eq type :reference))))))
              (issue :unsupported-relation-ownership (car entry)
                     kind origin))
             ((or (eq kind :semantic-edge)
                  (eq origin :semantic)
                  (and (not kind) (not origin)
                       (not (memq (plist-get relation :type) '(:reference :node-tag)))))
              (push (list :id (car entry) :from (plist-get relation :from)
                          :to (plist-get relation :to) :type (plist-get relation :type)) edges))
             ((and (not (plist-get relation :kind))
                   (not (plist-get relation :origin)))
              (issue :legacy-relation-ownership (car entry)))))))
      (list :coverage 'inventory-only
            :limitations '(explicit-store-nodes-only unsupported-legacy-fields
                           heading-only default-ST-prefix-only
                           reparses-file-per-node complex-values-require-policy no-write-plan)
            :fields (nreverse fields) :tags (nreverse tag-report)
            :automations (nreverse rules) :semantic-edges (nreverse edges)
            :concept-markers (nreverse concepts) :issues (nreverse issues)))))

(provide 'supertag-migration-preflight)
;;; supertag-migration-preflight.el ends here
