;;; supertag-service-org.el --- Org Buffer Interaction Service -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides high-level functions that correctly synchronize
;; changes by using robust, ID-based node location instead of stale
;; character positions. Tag-only rules are provided by supertag-tag;
;; shared identity/location, buffer mutation, saving, projection and recovery remain here.
;; Promote-only candidate/target/guard stages are owned by supertag-concept.
;; Commands: none; Lisp entrypoints include supertag-node-location-find,
;; supertag-service-org-create-node, supertag-service-org-move-nodes,
;; supertag-service-org-set-property, supertag-service-org-save-and-project-current-node,
;; supertag-service-org-retry-node-projection and supertag-template-read.
;; Dependencies: cl-lib, org, org-id, org-element, subr-x, supertag-core-store,
;; supertag-vault (pure path selection); shared creation presets are defined here;
;; supertag-node and supertag-services-sync (ordinary providers, lazy).

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'org-id) ;; Required for org-id-goto
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-vault)

;;; Shared node creation presets

(defgroup supertag-template nil
  "Shared presets for creating Org nodes."
  :group 'supertag)

(defcustom supertag-creation-templates nil
  "Creation presets shared by Add Link, Find Node and Promote.

Each entry is a plist with :key, :name and :target-file, plus optional :tags,
:properties and :body.  Values are data, not executable forms.  When nil, a
default Concept preset targets `concepts.org' under the effective vault."
  :type '(repeat plist)
  :group 'supertag-template)

(defun supertag-template--default-file ()
  "Return the configured default concepts.org destination."
  (if (and (boundp 'supertag-concept-default-file)
           supertag-concept-default-file)
      (expand-file-name supertag-concept-default-file)
    (expand-file-name
     "concepts.org"
     (or (car-safe
          (supertag-vault-selection-effective-directories
           (and (boundp 'supertag-sync-directories-mode)
                supertag-sync-directories-mode)
           (and (boundp 'supertag-sync-directories)
                supertag-sync-directories)
           (and (boundp 'supertag-active-sync-directory)
                supertag-active-sync-directory)))
         (and (boundp 'org-directory) org-directory)
         default-directory))))

(defun supertag-template-list ()
  "Return configured creation presets, including the default when needed."
  (or supertag-creation-templates
      (list (list :key "c" :name "Concept"
                  :target-file (supertag-template--default-file)
                  :tags nil :properties nil :body ""))))

(defun supertag-template-normalize (template)
  "Validate TEMPLATE and return a normalized copy without evaluating values."
  (let ((key (plist-get template :key))
        (name (plist-get template :name))
        (file (plist-get template :target-file))
        (tags (or (plist-get template :tags) nil))
        (properties (or (plist-get template :properties) nil))
        (body (or (plist-get template :body) "")))
    (unless (and (stringp key) (not (string-empty-p key)))
      (user-error "Creation template requires a non-empty :key"))
    (unless (and (stringp name) (not (string-empty-p name)))
      (user-error "Creation template requires a non-empty :name"))
    (unless (and (stringp file) (file-name-absolute-p file)
                 (not (file-remote-p file)))
      (user-error "Creation template requires an absolute local :target-file"))
    (unless (and (listp tags)
                 (cl-every (lambda (tag)
                             (and (stringp tag) (not (string-empty-p tag))))
                           tags))
      (user-error "Creation template :tags must be a list of strings"))
    (unless (and (listp properties)
                 (cl-every (lambda (entry)
                             (and (consp entry) (stringp (car entry))
                                  (stringp (cdr entry))))
                           properties))
      (user-error "Creation template :properties must be string pairs"))
    (unless (stringp body)
      (user-error "Creation template :body must be text"))
    (list :key key :name name :target-file (expand-file-name file)
          :tags (copy-sequence tags) :properties (copy-tree properties)
          :body body)))

(defun supertag-template-read ()
  "Read and return one validated creation preset."
  (let* ((templates (mapcar #'supertag-template-normalize
                            (supertag-template-list)))
         (choices (mapcar (lambda (template)
                            (cons (format "%s  %s"
                                          (plist-get template :key)
                                          (plist-get template :name))
                                  template))
                          templates))
         (selected (completing-read "Creation template: " choices nil t)))
    (or (cdr (assoc selected choices))
        (user-error "No creation template selected"))))

(defun supertag-template-target-files ()
  "Return canonical targets of current presets, without changing any files."
  (delete-dups
   (mapcar (lambda (preset)
             (file-truename (plist-get (supertag-template-normalize preset) :target-file)))
           (supertag-template-list))))

(defun supertag-template-by-key (key)
  "Return the unique validated preset selected by KEY."
  (let ((matches (cl-remove-if-not
                  (lambda (preset) (equal key (plist-get preset :key)))
                  (mapcar #'supertag-template-normalize (supertag-template-list)))))
    (unless (= 1 (length matches))
      (user-error "Template key must select exactly one preset: %s" key))
    (car matches)))

(defun supertag-template-read-key ()
  "Select a preset using its capture-style key, without executing template data."
  (let* ((presets (mapcar #'supertag-template-normalize (supertag-template-list)))
         (keys (mapcar (lambda (preset) (plist-get preset :key)) presets))
         (key (completing-read
               (concat "Promote template ("
                       (mapconcat (lambda (preset)
                                    (format "%s %s" (plist-get preset :key)
                                            (plist-get preset :name))) presets ", ")
                       "): ") keys nil t)))
    (supertag-template-by-key key)))

;; Ordinary providers do not load Node or Sync at registration.
(autoload 'supertag-node-get "supertag-node")
(declare-function supertag-node-get "supertag-node" (id))
(autoload 'supertag-node-delete "supertag-node")
(declare-function supertag-node-delete "supertag-node" (node-id))
(autoload 'supertag-service-org-follow-id "supertag-node")
(declare-function supertag-service-org-follow-id "supertag-node" (node-id))
(autoload 'supertag--mark-internal-modification "supertag-services-sync")
(declare-function supertag--mark-internal-modification "supertag-services-sync"
                  (file))
(autoload 'supertag--clear-internal-modification "supertag-services-sync")
(declare-function supertag--clear-internal-modification "supertag-services-sync"
                  (file))
(autoload 'supertag--render-org-headline "supertag-services-sync")
(declare-function supertag--render-org-headline "supertag-services-sync"
                  (level title tags file node &optional style tag-position))
(autoload 'supertag-node-sync-current-buffer "supertag-services-sync")
(declare-function supertag-node-sync-current-buffer "supertag-services-sync"
                  (node-id))

;; Sync owns the default; repair callbacks dynamically bind this flag.
(defvar supertag-sync--is-full-rescan-p)



;;; Shared Org identity and Store-first location

(defgroup supertag-node-identity nil
  "Node identity and Store-first location lookup."
  :group 'supertag)

(defcustom supertag-node-location-org-id-fallback t
  "When non-nil, use `org-id-find' for nodes absent from the Store.

This fallback exists for nodes that have not yet been projected into the
Supertag Store.  Runtime callers should use this service instead of consulting
`org-id-locations' directly."
  :type 'boolean
  :group 'supertag-node-identity)

(defun supertag-node-identity-new ()
  "Return a new ID suitable for an Org node.

ID generation uses Org's configured ID method but does not register a global
file location."
  (org-id-new))

(defun supertag-node-identity-ensure-at-point (&optional explicit-id)
  "Return the containing heading's persisted ID, creating it when absent.

The ID property is a Document Fact and is therefore written to the Org buffer.
The caller decides when to save and project that buffer.  No
`org-id-locations' entry is created here.  When EXPLICIT-ID is non-nil, persist
that value and reject a conflicting existing ID."
  (save-excursion
    (unless (or (org-at-heading-p) (org-back-to-heading t))
      (user-error "Point must be inside an Org heading."))
    (let ((current-id (org-entry-get nil "ID" nil)))
      (when (and explicit-id current-id (not (equal explicit-id current-id)))
        (user-error "Heading already has a different ID: %s" current-id))
      (or current-id
          (let ((node-id (or explicit-id (supertag-node-identity-new))))
            (org-entry-put nil "ID" node-id)
            node-id)))))

(defun supertag-node-location--id-property-position (node-id)
  "Return NODE-ID's property position in the widened current buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward
             (concat "^[ \t]*:ID:[ \t]*"
                     (regexp-quote node-id)
                     "[ \t]*$")
             nil t)
        (point)))))

(defun supertag-node-location--heading-position (node-id)
  "Return NODE-ID's heading position in the widened current buffer."
  (when-let* ((property-position
               (supertag-node-location--id-property-position node-id)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char property-position)
        (org-back-to-heading t)
        (point)))))

(defun supertag-node-location--file-drawer-end ()
  "Return the end of the file-level property drawer, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (skip-chars-forward " \t\r\n")
      (when (looking-at "^:PROPERTIES:[ \t]*$")
        (re-search-forward "^:END:[ \t]*$" nil t)))))

(defun supertag-node-location--file-org-id ()
  "Return the ID in the current buffer's file-level drawer, or nil."
  (when-let* ((drawer-end (supertag-node-location--file-drawer-end)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (when (re-search-forward "^:ID:[ \t]*\\(.+?\\)[ \t]*$"
                                 drawer-end t)
          (string-trim (match-string-no-properties 1)))))))

(defun supertag-node-location--file-denote-id ()
  "Return the current buffer's Denote identifier, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward "^#\\+IDENTIFIER:[ \t]*\\(.+?\\)[ \t]*$"
                               (min 2000 (point-max)) t)
        (string-trim (match-string-no-properties 1))))))

(defun supertag-node-location--file-identity-matches-p (node-id link-type)
  "Return non-nil when NODE-ID matches the file identity for LINK-TYPE."
  (pcase link-type
    ('id (equal node-id (supertag-node-location--file-org-id)))
    ('denote (equal node-id (supertag-node-location--file-denote-id)))
    (_ (or (equal node-id (supertag-node-location--file-org-id))
           (equal node-id (supertag-node-location--file-denote-id))))))

(defun supertag-node-location--position (node-id level link-type)
  "Return NODE-ID's current-buffer position for LEVEL and LINK-TYPE."
  (if (zerop (or level 1))
      (when (supertag-node-location--file-identity-matches-p
             node-id link-type)
        (save-restriction
          (widen)
          (point-min)))
    (supertag-node-location--heading-position node-id)))

(defun supertag-node-location-goto-current-buffer (node-id)
  "Move point to NODE-ID's heading in the current Org buffer.

Searches the widened buffer directly and does not consult
`org-id-locations'.  Return non-nil on success, leaving point unchanged on
failure."
  (when (and (stringp node-id) (not (string-empty-p node-id)))
    (let* ((node (supertag-store-get-entity :nodes node-id))
           (level (and (listp node) (plist-get node :level)))
           (link-type (and (listp node) (plist-get node :link-type)))
           (position (supertag-node-location--position
                      node-id level link-type)))
      (when (and position
                 (<= (point-min) position)
                 (<= position (point-max)))
        (goto-char position)
        t))))

(defun supertag-node-location--store-marker (node-id)
  "Return NODE-ID's marker using its projected Store location."
  (let* ((node (supertag-store-get-entity :nodes node-id))
         (file (and (listp node) (plist-get node :file)))
         (level (and (listp node) (plist-get node :level)))
         (link-type (and (listp node) (plist-get node :link-type)))
         (buffer (and (stringp file)
                      (file-exists-p file)
                      (find-file-noselect file)))
         (position (and buffer
                        (with-current-buffer buffer
                          (supertag-node-location--position
                           node-id level link-type)))))
    (when position
      (with-current-buffer buffer
        (copy-marker position)))))

(defun supertag-node-location-find (node-id)
  "Return a marker for NODE-ID using Store-first location lookup.

When the Store cannot resolve NODE-ID and
`supertag-node-location-org-id-fallback' is non-nil, use `org-id-find' as a
confined compatibility fallback.  A projected node that has a missing file or
missing in-file ID fails closed; it never falls back to a stale cache entry."
  (let ((node (supertag-store-get-entity :nodes node-id)))
    (if node
        (supertag-node-location--store-marker node-id)
      (when supertag-node-location-org-id-fallback
        (org-id-find node-id 'marker)))))

(defun supertag-node-location-file (node-id)
  "Return NODE-ID's verified source file using Store-first location lookup."
  (let ((node (supertag-store-get-entity :nodes node-id)))
    (if node
        (when-let* ((marker (supertag-node-location--store-marker node-id))
                    (buffer (marker-buffer marker)))
          (buffer-file-name buffer))
      (when-let* ((marker (and supertag-node-location-org-id-fallback
                              (org-id-find node-id 'marker)))
                  (buffer (marker-buffer marker)))
        (buffer-file-name buffer)))))

;;; Org buffer services and link integration

(defgroup supertag-org-link nil
  "Org link integration for Supertag."
  :group 'supertag)

(define-error 'supertag-projection-error
  "Document saved, but its Supertag projection could not be reconciled")
(define-error 'supertag-document-save-error
  "Document edit is retained in memory, but could not be saved")
(defcustom supertag-org-id-open-link-auto-enable t
  "When non-nil, let `org-id-open-link` resolve IDs via Supertag first.

This avoids depending on `org-id-locations` when the target node exists in the
Supertag store. The fallback remains the original Org behavior when the node is
unknown to Supertag or the recorded file is missing."
  :type 'boolean
  :group 'supertag-org-link)



(defun supertag-service-org--org-id-open-link-advice (orig-fn &rest args)
  "Advice for `org-id-open-link` that prefers Supertag lookup when available."
  (let ((node-id (car args)))
    (if (and supertag-org-id-open-link-auto-enable
             (bound-and-true-p supertag--initialized)
             (stringp node-id)
             (supertag-service-org-follow-id node-id))
        t
      (apply orig-fn args))))

(defun supertag-service-org--adjust-subtree-level (content from-level to-level)
  "Adjust Org subtree CONTENT from FROM-LEVEL to TO-LEVEL.

Only headline lines are adjusted (lines starting with `*`)."
  (let ((delta (- to-level from-level)))
    (if (or (not (stringp content)) (= delta 0))
        content
      (with-temp-buffer
        (insert content)
        (goto-char (point-min))
        (while (re-search-forward "^\\(\\*+\\)\\(\\s-\\)" nil t)
          (let* ((stars (match-string 1))
                 (sep (match-string 2))
                 (new-count (max 1 (+ (length stars) delta)))
                 (new-stars (make-string new-count ?*)))
            (replace-match (concat new-stars sep) t t)))
        (buffer-string)))))

(defun supertag-service-org--extract-ids-from-content (content)
  "Return a de-duplicated list of Org IDs found in CONTENT."
  (let ((ids '()))
    (when (stringp content)
      (with-temp-buffer
        (insert content)
        (goto-char (point-min))
        (while (re-search-forward "^[ \t]*:ID:[ \t]*\\(.+\\)$" nil t)
          (let ((id (string-trim (match-string 1))))
            (when (and (stringp id) (not (string-empty-p id)))
              (push id ids))))))
    (cl-delete-duplicates (nreverse ids) :test #'string=)))

(define-error 'supertag-move-recovery-error
  "Move failed; automatic recovery is incomplete")

(defun supertag-service-org--move-disk-text (file)
  "Read FILE as literal bytes, or nil when it does not exist."
  (when (file-exists-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (buffer-string))))

(defun supertag-service-org--move-snapshot (buffer)
  "Validate BUFFER and snapshot its live text and durable bytes."
  (with-current-buffer buffer
    (unless (and (derived-mode-p 'org-mode) buffer-file-name
                 (not buffer-read-only)
                 (file-writable-p buffer-file-name)
                 (verify-visited-file-modtime buffer))
      (user-error "Move requires a writable, current Org buffer: %s"
                  (buffer-name)))
    (let ((minimum (point-min)) (maximum (point-max)))
      (save-restriction
        (widen)
        (list :buffer buffer :file buffer-file-name
            :text (buffer-substring (point-min) (point-max))
            :minimum minimum :maximum maximum
            :modified (buffer-modified-p) :point (point)
            :undo buffer-undo-list
            :disk (supertag-service-org--move-disk-text buffer-file-name)
            :staged nil :edited nil :attempted nil :written nil)))))

(defun supertag-service-org--move-save (snapshot)
  "Save SNAPSHOT's buffer, recording even partial writes for compensation.
Suppress known Supertag hooks that publish intermediate sync state, propagate
embeds into other files, or schedule Git commits.  Other save hooks still run;
their external side effects are outside this two-file compensation boundary."
  (with-current-buffer (plist-get snapshot :buffer)
    (let ((after-save-hook
           (cl-remove-if
            (lambda (hook)
              (memq hook '(supertag-sync--run-on-save
                           supertag-embed-sync-modified-blocks
                           supertag-services-embed-on-source-save
                           supertag-git-sync--on-file-saved)))
            (if (memq t after-save-hook)
                (append (remove t after-save-hook)
                        (default-value 'after-save-hook))
              after-save-hook)))
          (file (plist-get snapshot :file))
          (expected (save-restriction
                      (widen)
                      (buffer-substring-no-properties (point-min) (point-max)))))
      (setf (plist-get snapshot :attempted) t)
      (supertag--mark-internal-modification file)
      (unwind-protect
          (progn
            (save-buffer)
            (when (buffer-modified-p)
              (error "Move save did not finish: %s" file))
            (save-restriction
              (widen)
              (unless (equal expected
                             (buffer-substring-no-properties (point-min) (point-max)))
                (error "Save hook changed move text; refusing source loss: %s" file))
              (unless (equal (encode-coding-string
                              (buffer-substring-no-properties (point-min) (point-max))
                              buffer-file-coding-system)
                             (supertag-service-org--move-disk-text file))
                (error "Move save readback differs from buffer: %s" file))))
        (setf (plist-get snapshot :written)
              (condition-case nil
                  (supertag-service-org--move-disk-text file)
                (error :unreadable)))
        (supertag--clear-internal-modification file)))))

(defun supertag-service-org--move-restore (snapshot)
  "Restore SNAPSHOT's buffer and, if attempted, its durable file.
Refuse to overwrite a file changed since the save attempt.  Recovery errors
are reported to the caller, which retains SNAPSHOT in the error data."
  (let ((file (plist-get snapshot :file))
        disk-error)
    (condition-case err
        (when (plist-get snapshot :attempted)
          (unless (equal (plist-get snapshot :written)
                         (supertag-service-org--move-disk-text file))
            (error "File changed after move save; refusing recovery overwrite: %s" file))
          (if (plist-get snapshot :disk)
              (let ((coding-system-for-write 'no-conversion))
                (write-region (plist-get snapshot :disk) nil file nil 'silent))
            (when (file-exists-p file) (delete-file file))))
      (error (setq disk-error err)))
    (when (plist-get snapshot :edited)
      (with-current-buffer (plist-get snapshot :buffer)
        (let ((inhibit-read-only t)
              (inhibit-modification-hooks t)
              (buffer-undo-list t))
          (save-restriction
            (widen)
            (erase-buffer)
            (insert (plist-get snapshot :text))
            (when (fboundp 'org-element-cache-reset)
              (org-element-cache-reset))
            (goto-char (plist-get snapshot :point))))
        (setq buffer-undo-list (plist-get snapshot :undo))
        (widen)
        (narrow-to-region (plist-get snapshot :minimum)
                          (plist-get snapshot :maximum))
        (goto-char (plist-get snapshot :point))
        (when (and (not disk-error) (plist-get snapshot :attempted))
          (set-visited-file-modtime))
        (set-buffer-modified-p (or disk-error (plist-get snapshot :modified)))))
    (when disk-error (signal (car disk-error) (cdr disk-error)))))

(defun supertag-service-org--retry-move-projection (source-file target-file &rest other-files)
  "Reproject identified headings in saved SOURCE-FILE and TARGET-FILE.
One Store transaction covers all files, including OTHER-FILES and child IDs."
  (supertag-with-transaction
    (dolist (file (delete-dups (append (list target-file source-file) other-files)))
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (save-restriction
            (widen)
            (org-map-entries
             (lambda ()
               (when-let* ((id (org-entry-get nil "ID")))
                 (supertag-service-org-retry-node-projection id file))))))))))

(defun supertag-service-org--move-notify-git (source target &rest other-buffers)
  "Notify existing Git integration after SOURCE and TARGET are durable.
Include OTHER-BUFFERS once each. Git owns mode/vault guards and debouncing."
  (when (fboundp 'supertag-git-sync--on-file-saved)
    (dolist (buffer (delete-dups (append (list source target) other-buffers)))
      (with-current-buffer buffer
        (condition-case err
            (supertag-git-sync--on-file-saved)
          (error
           (message "Move saved; Git sync notification failed: %s"
                    (error-message-string err))))))))

(defun supertag-service-org--move-root (source)
  "Resolve SOURCE, an ID or heading marker, without modifying its document."
  (let* ((marker (if (stringp source) (supertag-node-location-find source) source))
         (marker-buffer (and (markerp marker) (marker-buffer marker)))
         (position (and marker-buffer (marker-position marker)))
         (buffer (and marker-buffer
                      (or (buffer-base-buffer marker-buffer) marker-buffer))))
    (unless (and buffer (buffer-file-name buffer)
                 (file-regular-p (buffer-file-name buffer)))
      (user-error "Move source is not a live file-backed heading"))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (goto-char position)
          (unless (org-at-heading-p)
            (user-error "Move marker no longer points at a heading"))
          (when (and (stringp source) (not (equal source (org-entry-get nil "ID"))))
            (user-error "Source identity changed: %s" source))
          (list :buffer buffer :begin (point)
                :end (save-excursion (org-end-of-subtree t t) (point))
                :id (org-entry-get nil "ID") :content nil
                :level (org-outline-level) :title (org-get-heading t t t t)))))))

(defun supertag-service-org--move-normalize-roots (roots)
  "Remove duplicate and contained ROOTS while preserving retained root order."
  (let ((unique
         (cl-delete-duplicates
          roots :test (lambda (a b)
                        (and (eq (plist-get a :buffer) (plist-get b :buffer))
                             (= (plist-get a :begin) (plist-get b :begin))))
          :from-end t)))
    (cl-remove-if
     (lambda (root)
       (cl-some (lambda (other)
                  (and (not (eq root other))
                       (eq (plist-get root :buffer) (plist-get other :buffer))
                       (< (plist-get other :begin) (plist-get root :begin))
                       (<= (plist-get root :end) (plist-get other :end))))
                unique))
     unique)))

(defun supertag-service-org--move-restore-source-markers (contexts snapshots)
  "Restore caller marker CONTEXTS when SNAPSHOTS restored identical text."
  (dolist (context contexts)
    (let* ((marker (nth 0 context))
           (buffer (nth 1 context))
           (position (nth 2 context))
           (base (and (buffer-live-p buffer)
                      (or (buffer-base-buffer buffer) buffer)))
           (snapshot (and base
                          (cl-find base snapshots
                                   :key (lambda (item)
                                          (plist-get item :buffer))))))
      (when (and (markerp marker) (buffer-live-p buffer) snapshot
                 (with-current-buffer base
                   (save-restriction
                     (widen)
                     (equal (plist-get snapshot :text)
                            (buffer-substring (point-min) (point-max))))))
        (set-marker marker position buffer)))))

(defun supertag-service-org--move-closing-boundary-p (element position)
  "Return non-nil when POSITION ends ELEMENT's closing delimiter line."
  (let* ((type (org-element-type element))
         (regexp (if (memq type '(drawer property-drawer node-property))
                     "^[ \t]*:END:[ \t]*$"
                   "^[ \t]*#\\+end_[[:alnum:]_-]+[ \t]*$"))
         (case-fold-search t))
    (save-excursion
      (goto-char (org-element-property :end element))
      (when (> (point) (org-element-property :begin element))
        (backward-char))
      (and (re-search-backward regexp (org-element-property :begin element) t)
           (= position (line-end-position))))))

(defun supertag-service-org--move-structural-container-at (position)
  "Return an Org drawer or block unsafely containing POSITION.
The end of that element's real closing delimiter line is a safe boundary."
  (save-excursion
    (goto-char position)
    (let ((element (org-element-context)) found)
      (while (and element (not found))
        (let ((type (org-element-type element)))
          (when (and (< (org-element-property :begin element) position)
                     (< position (org-element-property :end element))
                     (or (memq type '(drawer property-drawer node-property))
                         (string-suffix-p "-block" (symbol-name type)))
                     (not (supertag-service-org--move-closing-boundary-p
                           element position)))
            (setq found element)))
        (setq element (org-element-property :parent element)))
      found)))

(defun supertag-service-org--move-remove-roots (roots buffer leave-link)
  "Remove ROOTS belonging to BUFFER, optionally inserting independent stubs."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (dolist (root (sort (cl-remove-if-not
                            (lambda (root) (eq buffer (plist-get root :buffer)))
                            (copy-sequence roots))
                           (lambda (a b) (> (plist-get a :begin) (plist-get b :begin)))))
          (goto-char (plist-get root :begin))
          (delete-region (point) (plist-get root :end))
          (when leave-link
            (let ((start (point)) (title (plist-get root :title)))
              (insert (make-string (plist-get root :level) ?*) " " title "\n\n"
                      (org-link-make-string (concat "id:" (plist-get root :id)) title)
                      "\n\n")
              (goto-char start)
              (supertag-node-identity-ensure-at-point))))))))

(defun supertag-service-org-move-nodes
    (sources target-file &optional target-position target-level leave-link)
  "Move ordered SOURCES to TARGET-FILE and return normalized root IDs.
SOURCES contains IDs or live heading markers.  TARGET-POSITION is a pre-edit
position or marker; nil appends.  Positions in ordinary text and at Org
structure boundaries are accepted; positions inside drawers or blocks are
rejected before editing.  TARGET-LEVEL adjusts roots when non-nil.
LEAVE-LINK creates independently identified stubs pointing at moved roots.

One invocation saves each affected whole buffer once, target first, including
pre-existing drafts. Their modified flags remain set for visibility, not as
an indication that drafts remain only in memory. Source identities are ensured
only inside the recoverable edit boundary; carried descendants gain no new IDs.
Ordinary failure and quit restore snapshots where safe, not crash-atomically.
Incomplete recovery retains snapshots in `supertag-move-recovery-error';
post-save Projection failure retains documents with structured retry data."
  (unless (and (consp sources) (proper-list-p sources)
               (stringp target-file) (not (string-empty-p target-file)))
    (user-error "Move requires sources and a target file"))
  (unless (or (null target-level)
              (and (integerp target-level) (> target-level 0)))
    (user-error "Target level must be a positive integer"))
  (setq target-file (expand-file-name target-file))
  (unless (and (file-directory-p (file-name-directory target-file))
               (or (not (file-exists-p target-file)) (file-regular-p target-file)))
    (user-error "Invalid move target: %s" target-file))
  (let* ((source-marker-contexts
          (delq nil
                (mapcar (lambda (source)
                          (when (and (markerp source) (marker-buffer source))
                            (list source (marker-buffer source)
                                  (marker-position source))))
                        sources)))
         (roots (supertag-service-org--move-normalize-roots
                 (mapcar #'supertag-service-org--move-root sources)))
         (target (find-file-noselect target-file))
         (buffers (delete-dups (cons target (mapcar (lambda (r) (plist-get r :buffer)) roots))))
         (snapshots (mapcar #'supertag-service-org--move-snapshot buffers))
         (target-snapshot (car snapshots))
         (anchor (with-current-buffer target
                   (save-restriction
                     (widen)
                     (when (and (markerp target-position)
                                (not (eq (marker-buffer target-position) target)))
                       (user-error "Target marker belongs to another buffer"))
                     (let ((pos (if (markerp target-position)
                                    (marker-position target-position)
                                  (or target-position (point-max)))))
                       (unless (and (integerp pos) (<= (point-min) pos (point-max)))
                         (user-error "Invalid target position"))
                       (when (supertag-service-org--move-structural-container-at pos)
                         (user-error "Cannot insert inside an Org drawer or block"))
                       pos))))
         (source-file (buffer-file-name (plist-get (car roots) :buffer)))
         (files (mapcar #'buffer-file-name buffers))
         (retry-args (append (list source-file (buffer-file-name target))
                             (cl-remove source-file (cdr files) :test #'equal)))
         cause committed recovery-errors ids)
    ;; Distinct live buffers for one physical file cannot form a safe batch.
    (cl-loop for tail on buffers do
             (dolist (other (cdr tail))
               (when (file-equal-p (buffer-file-name (car tail)) (buffer-file-name other))
                 (user-error "Move has multiple buffers for one physical file"))))
    (dolist (root roots)
      (when (and (eq target (plist-get root :buffer))
                 (or (and (<= (plist-get root :begin) anchor)
                          (< anchor (plist-get root :end)))
                     (and (= anchor (plist-get root :end)) target-level
                          (> target-level (plist-get root :level)))))
        (user-error "Cannot insert inside a moved subtree")))
    ;; Fail closed on duplicate identities before generating IDs or moving text.
    (let ((seen (make-hash-table :test 'equal)))
      (dolist (buffer buffers)
        (with-current-buffer buffer
          (save-excursion
            (save-restriction
              (widen)
              (org-map-entries
               (lambda ()
                 (when-let* ((id (org-entry-get nil "ID")))
                   (when (gethash id seen)
                     (user-error "Duplicate ID in affected files: %s" id))
                   (puthash id t seen)))))))))
    (unwind-protect
        (condition-case err
            (progn
              ;; Validation uses plain positions, so early errors retain no
              ;; private markers.  Install live markers only inside cleanup.
              (setq anchor (with-current-buffer target
                             (copy-marker anchor t)))
              (dolist (root roots)
                (setf (plist-get root :begin)
                      (with-current-buffer (plist-get root :buffer)
                        (copy-marker (plist-get root :begin))))
                (setf (plist-get root :end)
                      (with-current-buffer (plist-get root :buffer)
                        (copy-marker (plist-get root :end)))))
              ;; Snapshots precede even identity creation.
              (dolist (root roots)
                (with-current-buffer (plist-get root :buffer)
                  (save-excursion
                    (save-restriction
                      (widen)
                      (goto-char (plist-get root :begin))
                      (unless (plist-get root :id)
                        (setf (plist-get (cl-find (current-buffer) snapshots
                                                 :key (lambda (s) (plist-get s :buffer))) :edited) t)
                        (setf (plist-get root :id) (supertag-node-identity-ensure-at-point)))
                      (setf (plist-get root :content)
                            (buffer-substring-no-properties
                             (plist-get root :begin) (plist-get root :end)))))))
              (setq ids (mapcar (lambda (r) (plist-get r :id)) roots))
              (dolist (snapshot snapshots)
                (with-current-buffer (plist-get snapshot :buffer)
                  (save-restriction
                    (widen)
                    (setf (plist-get snapshot :staged)
                          (buffer-substring (point-min) (point-max))))))
              (setf (plist-get target-snapshot :edited) t)
              (supertag-service-org--move-remove-roots roots target leave-link)
              (with-current-buffer target
                (save-excursion
                  (save-restriction
                    (widen)
                    (goto-char anchor)
                    (unless (bolp) (insert "\n"))
                    (dolist (root roots)
                      (insert (supertag-service-org--adjust-subtree-level
                               (plist-get root :content) (plist-get root :level)
                               (or target-level (plist-get root :level))))
                      (unless (bolp) (insert "\n"))))))
              (supertag-service-org--move-save target-snapshot)
              (dolist (snapshot (cdr snapshots))
                (let ((buffer (plist-get snapshot :buffer)))
                  (with-current-buffer buffer
                    (save-restriction
                      (widen)
                      (unless (and (verify-visited-file-modtime buffer)
                                   (equal (plist-get snapshot :staged)
                                          (buffer-substring (point-min) (point-max))))
                        (error "Source changed during target save; retry move"))))
                  (setf (plist-get snapshot :edited) t)
                  (supertag-service-org--move-remove-roots roots buffer leave-link)
                  (supertag-service-org--move-save snapshot)))
              (setq committed t))
          ((error quit) (setq cause err)))
      (when (markerp anchor) (set-marker anchor nil))
      (unless committed
        (let ((inhibit-quit t))
          (dolist (snapshot snapshots)
            (condition-case err
                (supertag-service-org--move-restore snapshot)
              (error (push err recovery-errors))))
          (supertag-service-org--move-restore-source-markers
           source-marker-contexts snapshots)))
      (dolist (root roots)
        (when (markerp (plist-get root :begin))
          (set-marker (plist-get root :begin) nil))
        (when (markerp (plist-get root :end))
          (set-marker (plist-get root :end) nil))))
    (when recovery-errors
      (signal 'supertag-move-recovery-error
              (list :cause cause :recovery-errors recovery-errors :snapshots snapshots)))
    (when cause (signal (car cause) (cdr cause)))
    (dolist (snapshot snapshots)
      (when (plist-get snapshot :modified)
        (with-current-buffer (plist-get snapshot :buffer) (set-buffer-modified-p t))))
    (condition-case err
        (apply #'supertag-service-org--retry-move-projection retry-args)
      ((error quit)
       (supertag-service-org--signal-projection-error
        (car ids) target-file 'supertag-service-org--retry-move-projection retry-args err)))
    (apply #'supertag-service-org--move-notify-git
           (plist-get (car roots) :buffer) target (cdr buffers))
    ids))

(defun supertag-service-org-move-node-to-file (node-id target-file &optional leave-link target-level)
  "Move NODE-ID to a different TARGET-FILE and return t.
This compatibility adapter retains same-physical-file rejection and delegates
to `supertag-service-org-move-nodes'. See that service for whole-buffer save,
LEAVE-LINK, TARGET-LEVEL and recovery semantics."
  (unless (and (stringp node-id) (not (string-empty-p node-id))
               (stringp target-file) (not (string-empty-p target-file)))
    (user-error "Move requires a node ID and target file"))
  (let* ((marker (supertag-node-location-find node-id))
         (source-file (and (markerp marker) (marker-buffer marker)
                           (buffer-file-name (marker-buffer marker)))))
    (unless source-file (user-error "Node not found: %s" node-id))
    (when (or (equal (file-truename source-file) (file-truename target-file))
              (and (file-exists-p target-file) (file-equal-p source-file target-file)))
      (user-error "Cannot move a node to the same physical file"))
    (supertag-service-org-move-nodes (list node-id) target-file nil target-level leave-link)
    t))

(defun supertag-service-org-move-node-to-file-action (node-id _context target-file &optional leave-link target-level)
  "Automation adapter for `supertag-service-org-move-node-to-file`."
  (supertag-service-org-move-node-to-file node-id target-file leave-link target-level))

(defun supertag-enable-org-id-open-link-integration ()
  "Enable Supertag integration for `org-id-open-link`."
  (setq supertag-org-id-open-link-auto-enable t)
  (when (fboundp 'org-id-open-link)
    (advice-add 'org-id-open-link :around #'supertag-service-org--org-id-open-link-advice))
  (message "[supertag] org-id-open-link integration enabled"))

(defun supertag-disable-org-id-open-link-integration ()
  "Disable Supertag integration for `org-id-open-link`."
  (setq supertag-org-id-open-link-auto-enable nil)
  (when (fboundp 'org-id-open-link)
    (advice-remove 'org-id-open-link #'supertag-service-org--org-id-open-link-advice))
  (message "[supertag] org-id-open-link integration disabled"))

(when supertag-org-id-open-link-auto-enable
  (supertag-enable-org-id-open-link-integration))

(defun supertag-service-org--normalize-plist (data)
  "Return DATA as a plist. Convert hash tables into plists."
  (if (hash-table-p data)
      (let (plist)
        (maphash (lambda (k v)
                   (setq plist (plist-put plist k v)))
                 data)
        plist)
    data))

(defun supertag-service-org--node-tags (node-id)
  "Return the :tags list for NODE-ID, normalized from stored data."
  (let* ((node (supertag-service-org--normalize-plist (supertag-node-get node-id)))
         (tags (plist-get node :tags)))
    (when (listp tags) tags)))

(defun supertag-service-org--with-node-buffer (node-id func)
  "Find NODE-ID's Org buffer and execute FUNC at its source position."
  (let* ((node-info (supertag-node-get node-id))
         (file-path (plist-get node-info :file)))
    (unless (and file-path (file-exists-p file-path))
      (user-error "Node '%s' has no readable Org source" node-id))
    (save-window-excursion
      (with-current-buffer (find-file-noselect file-path)
        (save-excursion
          (save-restriction
            ;; Edits are addressed by node, not by whatever the user left the
            ;; buffer narrowed to, so reach the whole file and restore the
            ;; restriction afterwards.
            (widen)
            (if (zerop (or (plist-get node-info :level) 1))
                (goto-char (point-min))
              (unless (supertag-node-location-goto-current-buffer node-id)
                (user-error "Node '%s' was not found in %s" node-id file-path)))
            ;; Resolve Sync before the callback can edit or bind rescan state.
            (let ((definition
                   (symbol-function 'supertag-node-sync-current-buffer)))
              (when (autoloadp definition)
                (autoload-do-load definition 'supertag-node-sync-current-buffer)))
            (funcall func)))))))



(defun supertag-service-org--update-buffer-and-resync
    (node-id buffer-update-func &optional repair-projection)
  "Edit NODE-ID with BUFFER-UPDATE-FUNC, save Org, then reproject it.
When REPAIR-PROJECTION is non-nil and the edit is unchanged, save a modified
buffer before projecting it; otherwise repair its already-saved Projection."
  (supertag-service-org--with-node-buffer
   node-id
   (lambda ()
     (let ((before-tick (buffer-chars-modified-tick)))
       (funcall buffer-update-func)
       (if (not (eq before-tick (buffer-chars-modified-tick)))
           ;; Mark internal modification BEFORE save so after-save hook can skip.
           (supertag-service-org-save-and-project-current-node node-id)
         (when repair-projection
           (if (buffer-modified-p)
               (let ((supertag-sync--is-full-rescan-p t))
                 (supertag-service-org-save-and-project-current-node node-id))
             ;; The Org Fact is already durable; only its derived Store state
             ;; is missing, so do not manufacture a text edit or noisy save.
             ;; Force reconciliation because a stale Projection can retain the
             ;; source hash and would otherwise look unchanged to the service.
             (condition-case cause
                 (let ((supertag-sync--is-full-rescan-p t))
                   (supertag-service-org--project-current-node node-id))
               (error
                (supertag-service-org--signal-projection-error
                 node-id (buffer-file-name)
                 'supertag-service-org-retry-node-projection
                 (list node-id (buffer-file-name)) cause))))))))))

(defconst supertag-service-org--writable-special-properties
  '("TODO" "PRIORITY" "SCHEDULED" "DEADLINE")
  "Org special properties that `org-entry-put' may mutate natively.")

(defun supertag-service-org--property-name (property)
  "Return PROPERTY as a validated uppercase Org property name."
  (let* ((raw (cond
               ((keywordp property) (substring (symbol-name property) 1))
               ((stringp property) property)
               (t (user-error "Property name must be a keyword or string"))))
         (name (upcase raw)))
    (unless (and (not (string-empty-p name))
                 (org--valid-property-p name))
      (user-error "Invalid Org property name: %S" property))
    (when (equal name "ID")
      (user-error "Automation cannot change node identity"))
    (when (and (member name org-special-properties)
               (not (member name supertag-service-org--writable-special-properties)))
      (user-error "Org special property %s is read-only" name))
    name))

(defun supertag-service-org--property-value (value)
  "Return VALUE's deterministic Org text, or nil for deletion."
  (let ((text (cond
               ((null value) nil)
               ((stringp value)
                (when (string-match-p "[\n\r]" value)
                  (user-error "Org property values must be single-line text"))
                (string-trim value))
               ((numberp value) (number-to-string value))
               ((eq value t) "true")
               ((symbolp value) (symbol-name value))
               (t (user-error "Unsupported structured Org property value: %S" value)))))
    text))

(defun supertag-service-org--property-value-equal-p (name live requested)
  "Return non-nil when live Org NAME already represents REQUESTED."
  (or (equal live requested)
      (and live requested
           (member name '("SCHEDULED" "DEADLINE"))
           ;; Org adds brackets and a weekday to a bare ISO date.  Limit the
           ;; relaxed comparison to precisely that input shape: timestamp
           ;; syntax may also carry time ranges, repeaters and warning delays,
           ;; all of which are semantically significant.
           (string-match-p
            "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" requested)
           (string-match-p
            "\\`<[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [^ >\n]+>\\'"
            live)
           (condition-case nil
               (equal (org-read-date nil t live)
                      (org-read-date nil t requested))
             (error nil)))))

(defun supertag-service-org--absolute-planning-timestamp-p (value)
  "Return non-nil when VALUE is one complete, non-range Org timestamp."
  (and (stringp value)
       (with-temp-buffer
         (insert value)
         (goto-char (point-min))
         (when-let* ((timestamp (org-element-timestamp-parser)))
           (and (null (org-element-property :range-type timestamp))
                (equal value (org-element-property :raw-value timestamp)))))))

(defun supertag-service-org-set-property (node-id property value)
  "Set PROPERTY to scalar VALUE in NODE-ID's authoritative Org heading.

PROPERTY accepts the existing keyword form or an Org property-name string and
is normalized to uppercase.  Strings, numbers, t and symbols have deterministic
single-line text representations; nil deletes the property.  Node identity,
read-only Org special properties, multiline text and structured values are
rejected before editing.  Writable special properties use Org's native
handling.  Save succeeds before Projection, and Projection failure uses the
existing structured retry error.  Return the normalized text value, or nil for
deletion."
  (let* ((name (supertag-service-org--property-name property))
         (text (supertag-service-org--property-value value))
         (node (supertag-node-get node-id)))
    (unless node
      (user-error "Node not found: %s" node-id))
    (when (zerop (or (plist-get node :level) 1))
      (user-error "Automation properties require an identified Org heading"))
    (supertag-service-org--update-buffer-and-resync
     node-id
     (lambda ()
       (barf-if-buffer-read-only)
       (let ((live (org-entry-get nil name nil)))
         (unless (supertag-service-org--property-value-equal-p name live text)
           (if text
               (progn
                 ;; `org-schedule' preserves an existing repeater or warning
                 ;; when given another absolute date.  Here VALUE is
                 ;; replacement semantics, so clear first.  Relative
                 ;; "earlier"/"later" operations retain native behavior.
                 (when (and live
                            (member name '("SCHEDULED" "DEADLINE"))
                            (or (string-match-p
                                 "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'"
                                 text)
                                (supertag-service-org--absolute-planning-timestamp-p
                                 text))
                            (not (supertag-service-org--property-value-equal-p
                                  name live text)))
                   (org-entry-put nil name ""))
                 (org-entry-put nil name text))
             (if (member name supertag-service-org--writable-special-properties)
                 (org-entry-put nil name "")
               (org-entry-delete nil name)))))))
    text))



(defun supertag-service-org-create-node-at-point ()
  "Persist the heading at point, project it as a node, and return its ID.

The Org heading and its ID are authoritative.  No node Projection is written
until `save-buffer' succeeds."
  (unless (org-at-heading-p)
    (user-error "Point must be at an Org heading to create a node"))
  (unless (buffer-file-name)
    (user-error "Node must belong to a file-backed Org buffer"))
  (let ((node-id (supertag-node-identity-ensure-at-point)))
    (supertag-service-org-save-and-project-current-node node-id)
    node-id))

(defun supertag-service-org--validate-create-content (content)
  "Validate optional complete node CONTENT and return its normalized plist."
  (let ((properties (or (plist-get content :properties) nil))
        (body (or (plist-get content :body) "")))
    (unless (and (listp properties)
                 (cl-every
                  (lambda (entry)
                    (and (consp entry)
                         (stringp (car entry))
                         (string-match-p "\\`[A-Za-z][A-Za-z0-9_-]*\\'" (car entry))
                         (not (member (upcase (car entry))
                                      '("ID" "CUSTOM_ID" "END")))
                         (stringp (cdr entry))
                         (not (string-match-p "[\n\r]" (cdr entry)))))
                  properties))
      (user-error "Creation properties must be safe string pairs excluding identity"))
    (unless (stringp body)
      (user-error "Creation body must be Org text"))
    (list :properties properties :body body
          :create-file (and (plist-get content :create-file) t))))

(defun supertag-service-org--insert-create-content (headline node-id content)
  "Insert HEADLINE with NODE-ID and validated CONTENT at point.
Return a marker at the new root heading."
  (let ((heading-marker (copy-marker (point))))
    (insert headline)
    (goto-char heading-marker)
    (supertag-node-identity-ensure-at-point node-id)
    (dolist (entry (plist-get content :properties))
      (org-entry-put nil (upcase (car entry)) (cdr entry)))
    (let ((body (plist-get content :body)))
      (unless (string-empty-p body)
        (org-end-of-meta-data t)
        (unless (bolp) (insert "\n"))
        (insert body)
        (unless (bolp) (insert "\n"))))
    heading-marker))

(defun supertag-service-org--preflight-create (headline content)
  "Validate that HEADLINE and CONTENT form one safe new Org node."
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (let ((marker (supertag-service-org--insert-create-content
                   headline "supertag-preflight-id" content)))
      (unwind-protect
          (progn
            (goto-char marker)
            (unless (and (org-at-heading-p)
                         (= 1 (org-outline-level)))
              (user-error "Creation template must produce a level-1 Org node"))
            (org-map-entries
             (lambda ()
               (unless (= (point) marker)
                 (when (or (org-entry-get nil "ID" nil)
                           (org-entry-get nil "CUSTOM_ID" nil))
                   (user-error
                    "Creation template body cannot inject another identity"))))
             nil nil))
        (set-marker marker nil)))))

(defun supertag-service-org-create-node (target-file title &optional tags content)
  "Append one identified level-1 Org node to TARGET-FILE.

TARGET-FILE must be an absolute local writable Org file.  Existing Automation
calls require it to exist.  CONTENT may contain :properties, :body and an
explicit :create-file flag for validated interactive templates.
TITLE is non-empty single-line text.  TAGS is nil or a list of safe non-empty
tag strings.  Save the live target buffer once before projecting and return the
new node ID."
  (unless (and (stringp target-file) (file-name-absolute-p target-file))
    (user-error "Automation create target must be an absolute file path"))
  (when (file-remote-p target-file)
    (user-error "Automation create target must be a local file"))
  (unless (and (stringp title)
               (not (string-empty-p (string-trim title)))
               (not (string-match-p "[\n\r]" title)))
    (user-error "Automation node title must be non-empty single-line text"))
  (unless (and (listp tags)
               (cl-every
                (lambda (tag)
                  (and (stringp tag)
                       (not (string-empty-p tag))
                       (not (string-match-p "[[:space:]#:]" tag))))
                tags))
    (user-error "Automation node tags must be safe non-empty strings"))
  (let* ((normalized-content
          (supertag-service-org--validate-create-content content))
         (create-file (plist-get normalized-content :create-file))
         (parent (file-name-directory target-file))
         (headline (supertag--render-org-headline
                    1 title tags target-file nil)))
    (unless (or (and (file-exists-p target-file)
                     (file-regular-p target-file))
                (and create-file parent (file-directory-p parent)
                     (file-writable-p parent)))
      (user-error "Automation create target does not exist: %s" target-file))
    (when (and (file-exists-p target-file) (not (file-writable-p target-file)))
      (user-error "Automation create target is not writable: %s" target-file))
    (supertag-service-org--preflight-create headline normalized-content)
  (let ((buffer (find-file-noselect target-file)))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (unless (derived-mode-p 'org-mode)
            (user-error "Automation create target must be an Org file"))
          (barf-if-buffer-read-only)
          (goto-char (point-max))
            (let ((node-id (supertag-node-identity-new)))
              (unless (or (bobp) (eq (char-before) ?\n))
                (insert "\n"))
              (let ((heading-marker
                     (supertag-service-org--insert-create-content
                      headline node-id normalized-content)))
                (unwind-protect
                    (progn
                      (goto-char heading-marker)
                      (condition-case cause
                          (supertag-service-org-create-node-at-point)
                        (supertag-projection-error
                         (signal (car cause) (cdr cause)))
                        (error
                         (signal
                          'supertag-document-save-error
                          (list :node-id node-id
                                :file target-file
                                :retry 'supertag-service-org-retry-created-node
                                :retry-args (list node-id target-file)
                                :cause cause)))))
                  (set-marker heading-marker nil))))))))))

(defun supertag-service-org-retry-created-node (node-id file)
  "Save and project the retained live creation of NODE-ID in FILE."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (unless (re-search-forward
                 (concat "^[ \t]*:ID:[ \t]*" (regexp-quote node-id)
                         "[ \t]*$") nil t)
          (user-error "Retained node '%s' is no longer present in %s"
                      node-id file))
        (org-back-to-heading t)
        (supertag-service-org-save-and-project-current-node node-id)
        node-id))))

(defun supertag-service-org--save-current-buffer ()
  "Save the current Org buffer while suppressing its external sync hook."
  (unless (buffer-file-name)
    (user-error "Document command requires a file-backed Org buffer"))
  (let ((file (buffer-file-name)))
    (supertag--mark-internal-modification file)
    (unwind-protect
        (let ((inhibit-message t))
          (save-buffer))
      (supertag--clear-internal-modification file))))

(defun supertag-service-org--signal-projection-error
    (node-id file retry retry-args cause)
  "Signal a retryable Projection error for NODE-ID in FILE.
RETRY and RETRY-ARGS describe the service-level recovery call; CAUSE is the
original error."
  (signal 'supertag-projection-error
          (list :node-id node-id
                :file file
                :retry retry
                :retry-args retry-args
                :cause cause)))

(defun supertag-service-org--project-current-node (node-id)
  "Rebuild NODE-ID from the current Org buffer."
  (supertag-with-transaction
    (supertag-node-sync-current-buffer node-id)))

(defun supertag-service-org-retry-node-projection (node-id file)
  "Rebuild NODE-ID's Projection from its already-saved Org FILE."
  (unless (and (stringp file) (file-readable-p file))
    (user-error "Node '%s' has no readable Org source" node-id))
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (save-restriction
        (widen)
        (let ((node (supertag-node-get node-id)))
          (if (zerop (or (plist-get node :level) 1))
              (goto-char (point-min))
            (goto-char (point-min))
            (unless (re-search-forward
                     (concat "^[ \t]*:ID:[ \t]*"
                             (regexp-quote node-id) "[ \t]*$") nil t)
              (user-error "Node '%s' was not found in %s" node-id file))
            (org-back-to-heading t)))
        (supertag-service-org--project-current-node node-id)))))

(defun supertag-service-org-retry-delete-node-projection (node-id)
  "Idempotently remove NODE-ID's Projection after its Org Fact was deleted."
  (supertag-node-delete node-id))

(defun supertag-service-org--delete-node-projection (node-id file)
  "Remove NODE-ID's Projection or signal a structured error for FILE."
  (condition-case cause
      (supertag-service-org-retry-delete-node-projection node-id)
    (error
     (supertag-service-org--signal-projection-error
      node-id file 'supertag-service-org-retry-delete-node-projection
      (list node-id) cause))))

(defun supertag-service-org--edit-save-delete-projection (node-id edit)
  "Run Document EDIT, save, then remove NODE-ID's Projection.

The change group restores the in-memory Org edit when saving fails.  Once the
save succeeds, Projection failure is reported without undoing durable text."
  (unless (buffer-file-name)
    (user-error "Document command requires a file-backed Org buffer"))
  (let ((file (buffer-file-name)))
    (atomic-change-group
      (funcall edit)
      (supertag-service-org--save-current-buffer))
    (supertag-service-org--delete-node-projection node-id file)
    node-id))

(defun supertag-service-org-delete-node-at-point (node-id)
  "Delete NODE-ID's Org subtree, save it, then remove its Projection."
  (unless (and (org-at-heading-p)
               (equal node-id (org-id-get)))
    (user-error "Point does not identify node '%s'" node-id))
  (supertag-service-org--edit-save-delete-projection
   node-id
   (lambda ()
     (org-back-to-heading t)
     (let* ((element (org-element-at-point))
            (begin (org-element-property :begin element))
            (end (org-element-property :end element)))
       (unless (and begin end (< begin end))
         (error "Cannot determine subtree bounds for node '%s'" node-id))
       (delete-region begin end)
       (when (looking-at "\n")
         (delete-char 1))))))

(defun supertag-service-org-demote-node-at-point (node-id)
  "Remove NODE-ID's Org identity, save, then remove its Projection."
  (unless (and (org-at-heading-p)
               (equal node-id (org-id-get)))
    (user-error "Point does not identify node '%s'" node-id))
  (supertag-service-org--edit-save-delete-projection
   node-id
   (lambda ()
     (org-entry-delete (point) "ID"))))

(defun supertag-service-org-save-and-project-current-node (node-id)
  "Save the current Org buffer, then rebuild NODE-ID's projection once."
  (unless (buffer-file-name)
    (user-error "NODE-ID must belong to a file-backed Org buffer"))
  (let ((file (buffer-file-name)))
    (supertag-service-org--save-current-buffer)
    (condition-case cause
        (supertag-service-org--project-current-node node-id)
      (error
       (supertag-service-org--signal-projection-error
        node-id file 'supertag-service-org-retry-node-projection
        (list node-id file) cause)))))

(defun supertag-service-org-set-todo-state (node-id state)
  "Set the TODO STATE for NODE-ID in the buffer and trigger a resync."
  (supertag-service-org--update-buffer-and-resync
   node-id
   (lambda ()
     (let ((inhibit-message t)
           (current (when (fboundp 'org-get-todo-state)
                      (org-get-todo-state))))
       (unless (equal current state)
         (org-todo state))))))

(defun supertag-ui--adjust-content-level (content from-level to-level)
  "Adjust all heading levels in CONTENT string.
Moves the top-level heading from FROM-LEVEL to TO-LEVEL, and adjusts
all subheadings proportionally."
  (if (or (not from-level) (not to-level) (= from-level to-level))
      content ; No adjustment needed
    (with-temp-buffer
      (insert content)
      (goto-char (point-min))
      (let ((level-diff (- to-level from-level)))
        ;; Use while to adjust all headlines in the content block.
        (while (re-search-forward "^\\(\\*+\\)\\s-+\\(.*\\)" nil t)
          (let* ((current-stars-str (match-string 1))
                 (title-text (match-string 2))
                 (current-level (length current-stars-str))
                 (new-level (+ current-level level-diff)))
            ;; Ensure we don't create a level 0 or negative heading.
            (when (> new-level 0)
              ;; Replace the entire matched line (stars + space + title)
              ;; with a correctly formatted new one.
              (replace-match (concat (make-string new-level ?*) " " title-text)
                             t ; fixedcase
                             t ; literal
                             )))))
      (buffer-string))))

(provide 'supertag-service-org)
;;; supertag-service-org.el ends here
