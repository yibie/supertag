;;; supertag-service-org.el --- Org Buffer Interaction Service -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides high-level functions that correctly synchronize
;; changes by using robust, ID-based node location instead of stale
;; character positions.

(require 'cl-lib)
(require 'org)
(require 'org-id) ;; Required for org-id-goto
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-ops-node)
(require 'supertag-service-node-identity)
(require 'supertag-services-sync)
(require 'supertag-ops-tag)
(require 'supertag-ops-relation)
(require 'supertag-ops-field)
(require 'supertag-ops-global-field)
(require 'supertag-view-helper)
(require 'supertag-core-scan)

(declare-function supertag-reference-materialize-at-point
                  "supertag-ui-reference"
                  (target-id title))

(defgroup supertag-org-link nil
  "Org link integration for Supertag."
  :group 'supertag)

(define-error 'supertag-projection-error
  "Document saved, but its Supertag projection could not be reconciled")

(defcustom supertag-org-id-open-link-auto-enable t
  "When non-nil, let `org-id-open-link` resolve IDs via Supertag first.

This avoids depending on `org-id-locations` when the target node exists in the
Supertag store. The fallback remains the original Org behavior when the node is
unknown to Supertag or the recorded file is missing."
  :type 'boolean
  :group 'supertag-org-link)

(defun supertag-service-org-follow-id (node-id)
  "Open NODE-ID using Supertag's node location and a robust `:ID:` search.

Returns non-nil when NODE-ID was handled, nil otherwise."
  (let* ((marker (and (stringp node-id)
                      (supertag-node-location-find node-id)))
         (file (and marker
                    (buffer-file-name (marker-buffer marker)))))
    (when (and (stringp file)
               (file-exists-p file)
               ;; Only apply to files in sync scope.
               (or (not (fboundp 'supertag-sync--in-sync-scope-p))
                   (supertag-sync--in-sync-scope-p file)))
      (let ((buffer (marker-buffer marker)))
        (pop-to-buffer buffer)
        ;; Navigating to a node the user asked for outranks whatever the
        ;; buffer happened to be narrowed to, the same way `org-id-goto' does.
        (widen)
        (goto-char marker)
        (org-show-context)
        (recenter)
        t))))

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

(defun supertag-service-org-move-node-to-file (node-id target-file &optional leave-link target-level)
  "Move NODE-ID's subtree to TARGET-FILE without prompting.

This does not trust stored character positions. It locates the subtree via
an in-buffer `:ID:` search, moves the full subtree text (including all child headings), and
updates Supertag store location for all Org IDs found in that subtree.

When LEAVE-LINK is non-nil, replace the original subtree with a stub headline
whose body contains an `id:` link to the moved node.

When TARGET-LEVEL is non-nil, adjust the subtree so the top headline becomes
that outline level in TARGET-FILE.

This implementation uses `org-element-at-point' for precise range extraction,
preventing data loss from incorrect position calculations."
  (unless (and (stringp node-id) (not (string-empty-p node-id)))
    (error "node-id must be a non-empty string"))
  (unless (and (stringp target-file) (not (string-empty-p target-file)))
    (error "target-file must be a non-empty string"))

  (let* ((marker (supertag-node-location-find node-id))
         (source-file (when marker (buffer-file-name (marker-buffer marker)))))

    (unless marker
      (error "Node %s not found" node-id))
    (unless (and source-file (file-exists-p source-file))
      (error "Source file missing for node %s" node-id))

    ;; Security check: don't move to same file
    (when (string= source-file target-file)
      (error "Cannot move node to the same file"))

    ;; Step 1: Collect node data using org-element for precise range
    (let ((node-info nil)
          (node-start-pos nil))

      (with-current-buffer (marker-buffer marker)
        (save-restriction
          (widen)
          (save-excursion
            (goto-char (marker-position marker))

            ;; Navigate to heading and verify position
            (org-back-to-heading t)
            (unless (org-at-heading-p)
              (error "Cannot locate heading for node %s" node-id))

            ;; Use org-element-at-point for precise range extraction
            (when (fboundp 'org-element-at-point)
              (let* ((element (org-element-at-point))
                     (begin (org-element-property :begin element))
                     (end (org-element-property :end element))
                     (level (org-element-property :level element))
                     (title (org-get-heading t t t t))
                     (content (buffer-substring-no-properties begin end)))

                ;; Safety checks
                (unless (string-match-p "^\\*+ " content)
                  (error "Invalid content extraction for node %s" node-id))
                (when (<= end begin)
                  (error "Invalid range for node %s" node-id))

                ;; Check if moving would delete entire file
                (save-excursion
                  (goto-char (point-min))
                  (let ((first-heading (when (re-search-forward "^\\*+ " nil t)
                                         (match-beginning 0))))
                    (when (and first-heading (= begin first-heading)
                               (save-excursion (goto-char end) (eobp)))
                      (error "Refusing to move: would delete entire file"))))

                (setq node-info (list :id node-id
                                      :file source-file
                                      :begin begin
                                      :end end
                                      :level level
                                      :title title
                                      :content content)))))))

      (unless node-info
        (error "Failed to collect node data for %s" node-id))

      ;; Step 2: Insert into target file
      (let* ((content (plist-get node-info :content))
             (original-level (plist-get node-info :level))
             (adjusted-content (if (integerp target-level)
                                   (supertag-service-org--adjust-subtree-level
                                    content original-level target-level)
                                 content)))

        (with-current-buffer (find-file-noselect target-file)
          (save-restriction
            (widen)
            (goto-char (point-max))
            (unless (or (bobp) (looking-back "\n" 1)) (insert "\n"))
            (setq node-start-pos (point))
            (insert adjusted-content)
            (unless (looking-back "\n" 1) (insert "\n")))
          (when (buffer-file-name)
            (supertag--mark-internal-modification (buffer-file-name)))
          (save-buffer)))

      ;; Step 3: Remove from source (or leave link)
      (let* ((begin (plist-get node-info :begin))
             (end (plist-get node-info :end))
             (title (plist-get node-info :title))
             (level (plist-get node-info :level)))

        (with-current-buffer (find-file-noselect source-file)
          (save-restriction
            (widen)
            (delete-region begin end)
            (when leave-link
              ;; Keep the backlink in content: headline titles are labels, not
              ;; source-owned Document Link assertions for the extractor.
              (insert (make-string level ?*) " " (or title "MOVED") "\n\n")
              (backward-char 1)
              (require 'supertag-ui-reference)
              (let ((inhibit-message t))
                (supertag-reference-materialize-at-point
                 node-id (or title "MOVED"))))
            (when (buffer-file-name)
              (supertag--mark-internal-modification (buffer-file-name)))
            (save-buffer))))

      ;; Step 4: Update database
      (supertag-node-set-location node-id target-file node-start-pos)

      (message "[supertag] moved node %s -> %s"
               node-id (abbreviate-file-name target-file))
      t)))

(defun supertag-service-org-move-node-to-file-action (node-id _context target-file &optional leave-link target-level)
  "Automation adapter for `supertag-service-org-move-node-to-file`."
  (supertag-service-org-move-node-to-file node-id target-file leave-link target-level))

(defun supertag-enable-org-id-open-link-integration ()
  "Enable Supertag integration for `org-id-open-link`."
  (interactive)
  (setq supertag-org-id-open-link-auto-enable t)
  (when (fboundp 'org-id-open-link)
    (advice-add 'org-id-open-link :around #'supertag-service-org--org-id-open-link-advice))
  (message "[supertag] org-id-open-link integration enabled"))

(defun supertag-disable-org-id-open-link-integration ()
  "Disable Supertag integration for `org-id-open-link`."
  (interactive)
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

(defun supertag-service-org--semantic-tag-id (tag)
  "Return TAG as a Semantic Tag ID, or nil when it is unknown."
  (and (stringp tag)
       (or (and (supertag-tag-get tag) tag)
           (supertag-tag-resolve-occurrence tag))))

(defun supertag-service-org--tag-token (tag)
  "Return the canonical Org occurrence token for TAG."
  (let* ((id (or (supertag-service-org--semantic-tag-id tag)
                 (user-error "Unknown Tag '%s'" tag)))
         (entity (supertag-tag-get id)))
    (supertag-sanitize-tag-name (plist-get entity :name))))

(defun supertag-service-org--token-identifies-p (token tag-id)
  "Return non-nil when occurrence TOKEN resolves to TAG-ID."
  (equal tag-id (ignore-errors (supertag-tag-resolve-occurrence token))))

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
            (funcall func)))))))

(defun supertag-service-org--parent-title (node-id)
  "Return the direct parent's title for NODE-ID, or nil.
If NODE-ID is already a top-level heading, return nil."
  (let* ((node-info (supertag-node-get node-id))
         (file-path (plist-get node-info :file))
         (result nil))
    (when (and file-path (file-exists-p file-path))
      (save-window-excursion
        (let ((buffer (find-file-noselect file-path)))
          (with-current-buffer buffer
            (save-excursion
              (unless (supertag-node-location-goto-current-buffer node-id)
                (user-error "Node '%s' was not found in %s" node-id file-path))
              (when (org-at-heading-p)
                (when (org-up-heading-safe)
                  (setq result (org-get-heading t t t t)))))))))
    result))

(defun supertag-service-org--update-buffer-and-resync
    (node-id buffer-update-func &optional repair-projection)
  "Edit NODE-ID with BUFFER-UPDATE-FUNC, save Org, then reproject it.
When REPAIR-PROJECTION is non-nil, reproject already-saved Org even when the
buffer text does not change."
  (supertag-service-org--with-node-buffer
   node-id
   (lambda ()
     (let ((before-tick (buffer-chars-modified-tick)))
       (funcall buffer-update-func)
       (if (not (eq before-tick (buffer-chars-modified-tick)))
           ;; Mark internal modification BEFORE save so after-save hook can skip.
           (supertag-service-org-save-and-project-current-node node-id)
         (when repair-projection
           ;; The Org Fact is already durable; only its derived Store state is
           ;; missing, so do not manufacture a text edit or noisy save.  Force
           ;; reconciliation because a stale Projection can retain the source
           ;; hash and would otherwise look unchanged to the sync service.
           (condition-case cause
               (let ((supertag-sync--is-full-rescan-p t))
                 (supertag-service-org--project-current-node node-id))
             (error
              (supertag-service-org--signal-projection-error
               node-id (buffer-file-name)
               'supertag-service-org-retry-node-projection
               (list node-id (buffer-file-name)) cause)))))))))

(defun supertag-service-org--tag-membership-present-p (node-id tag-id)
  "Return non-nil when TAG-ID is fully projected on NODE-ID."
  (and (member tag-id (supertag-service-org--node-tags node-id))
       (supertag-relation-find-between node-id tag-id :node-tag)))

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
  "Rebuild NODE-ID from the current buffer and maintain tag field lifecycle."
  (supertag-with-transaction
    (let* ((before-tags (copy-sequence
                         (plist-get (supertag-node-get node-id) :tags)))
           (result (supertag-node-sync-current-buffer node-id))
           (after-tags (plist-get (supertag-node-get node-id) :tags)))
      (dolist (tag-id (cl-set-difference after-tags before-tags :test #'equal))
        (supertag-node-initialize-tag-fields node-id tag-id))
      (dolist (tag-id (cl-set-difference before-tags after-tags :test #'equal))
        (supertag-node-clear-tag-fields node-id tag-id))
      result)))

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

(defun supertag-service-org--filetags ()
  "Return the current buffer's file-level tag tokens."
  (plist-get (supertag-sync--parse-file-header) :file-tags))

(defun supertag-service-org--set-filetags (tags)
  "Replace the current buffer's #+FILETAGS value with TAGS."
  (goto-char (point-min))
  (let ((value (mapconcat (lambda (tag) (concat ":" tag)) tags "")))
    (if (re-search-forward "^#\\+FILETAGS:\\s-*.*$" nil t)
        (if tags
            (replace-match (concat "#+FILETAGS: " value ":") t t)
          (delete-region (line-beginning-position)
                         (min (point-max) (1+ (line-end-position)))))
      (when tags
        (insert (concat "#+FILETAGS: " value ":\n"))))))

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

(defun supertag-service-org-add-tag (node-id tag-name &optional position)
  "Add TAG-NAME to NODE-ID's Org source, save, then reproject.
POSITION may be `beginning', `end', or a marker in the node buffer."
  (let* ((tag-id (or (supertag-service-org--semantic-tag-id tag-name)
                     (user-error "Unknown Tag '%s'" tag-name)))
         (token (supertag-service-org--tag-token tag-id))
         (repair-projection
          (not (supertag-service-org--tag-membership-present-p
                node-id tag-id))))
    (supertag-service-org--update-buffer-and-resync
     node-id
     (lambda ()
       (if (zerop (or (plist-get (supertag-node-get node-id) :level) 1))
           (let ((tags (supertag-service-org--filetags)))
             (unless (member token tags)
               (supertag-service-org--set-filetags (append tags (list token)))))
         (unless (member token (supertag-node-tag-occurrences-at-point))
           (pcase position
             ('beginning
              (org-back-to-heading t)
              (forward-word)
              (when (org-get-todo-state) (forward-word)))
             ((pred markerp)
              (when (eq (marker-buffer position) (current-buffer))
                (goto-char position)
                (when (org-at-heading-p)
                  (end-of-line))))
             (_ (end-of-line)))
           (supertag-view-helper-insert-tag-text token))))
     repair-projection)))

(defun supertag-service-org-remove-tag (node-id tag-name)
  "Remove TAG-NAME from NODE-ID's Org source, save, then reproject."
  (let ((tag-id (or (supertag-service-org--semantic-tag-id tag-name)
                    (user-error "Unknown Tag '%s'" tag-name))))
    (supertag-service-org--update-buffer-and-resync
     node-id
     (lambda ()
       (if (zerop (or (plist-get (supertag-node-get node-id) :level) 1))
           (supertag-service-org--set-filetags
            (cl-remove-if
             (lambda (token)
               (supertag-service-org--token-identifies-p token tag-id))
             (supertag-service-org--filetags)))
         (dolist (token (supertag-node-tag-occurrences-at-point))
           (when (supertag-service-org--token-identifies-p token tag-id)
             (supertag-view-helper-remove-tag-text token))))))))

(defun supertag-service-org-replace-tag (node-id old-tag-name new-tag-name)
  "Replace OLD-TAG-NAME with NEW-TAG-NAME in Org, then reproject NODE-ID."
  (let ((old-id (or (supertag-service-org--semantic-tag-id old-tag-name)
                    (user-error "Unknown Tag '%s'" old-tag-name)))
        (new-token (supertag-service-org--tag-token new-tag-name)))
    (supertag-service-org--update-buffer-and-resync
     node-id
     (lambda ()
       (if (zerop (or (plist-get (supertag-node-get node-id) :level) 1))
           (supertag-service-org--set-filetags
            (mapcar (lambda (tag)
                      (if (supertag-service-org--token-identifies-p tag old-id)
                          new-token
                        tag))
                    (supertag-service-org--filetags)))
         (dolist (token (supertag-node-tag-occurrences-at-point))
           (when (supertag-service-org--token-identifies-p token old-id)
             (supertag-view-helper-rename-tag-text-in-node
              token new-token))))))))

;; ---------------------------------------------------------------------------
;; Field export helpers (DB -> Org properties)
;; ---------------------------------------------------------------------------

(defcustom supertag-export-field-property-prefix "ST_"
  "Legacy prefix used for Org properties created when exporting fields.
New exports no longer use this prefix in property names, but the prefix
is still used to recognize and clean up older exported properties."
  :type 'string
  :group 'supertag)

(defcustom supertag-debug-export-fields nil
  "When non-nil, log detailed information during field export."
  :type 'boolean
  :group 'supertag)

(defconst supertag-export--missing (make-symbol "supertag-export-missing")
  "Sentinel used to detect missing field values during export.")

(defun supertag-export--sanitize-symbol-component (name)
  "Return NAME uppercased and sanitized for use in property names."
  (let* ((s (upcase (format "%s" (or name ""))))
         (s (replace-regexp-in-string "[^A-Z0-9_]" "_" s)))
    (if (string-empty-p s) "FIELD" s)))

(defun supertag-export--field-property-name (tag-id field-name)
  "Build an Org property name for global FIELD-NAME.
TAG-ID is retained for call-site compatibility."
  (ignore tag-id)
  (supertag-export--sanitize-symbol-component field-name))

(defun supertag-export--legacy-field-property-names (_tag-id field-name)
  "Return legacy property names for FIELD-NAME without the tag prefix.
Includes both plain and `supertag-export-field-property-prefix' variants
to support imports from older exports."
  (let* ((field-part (supertag-export--sanitize-symbol-component field-name))
         (prefixed (concat (upcase supertag-export-field-property-prefix) field-part)))
    (list field-part prefixed)))

(defun supertag-export--format-date (value)
  "Best-effort formatting of VALUE as a date string."
  (cond
   ((null value) "")
   ((stringp value) value)
   ;; Emacs time list (high low micro pico)
   ((and (listp value) (= (length value) 4))
    (format-time-string "%Y-%m-%d" value))
   ;; Fallback
   (t (format "%s" value))))

(defun supertag-export--format-timestamp (value)
  "Best-effort formatting of VALUE as a timestamp string."
  (cond
   ((null value) "")
   ((stringp value) value)
   ;; Emacs time list (high low micro pico)
   ((and (listp value) (= (length value) 4))
    (format-time-string "%Y-%m-%d %H:%M" value))
   (t (format "%s" value))))

(defun supertag-export--field-value-to-string (tag-id field-name value)
  "Convert field VALUE for TAG-ID/FIELD-NAME into a string for properties."
  (ignore tag-id)
  (let* ((field-def
          (supertag-global-field-get
           (supertag-sanitize-field-id field-name)))
         (type (plist-get field-def :type)))
    (pcase type
      (:boolean (if value "true" "false"))
      (:date (supertag-export--format-date value))
      (:timestamp (supertag-export--format-timestamp value))
      ;; For list-like types, serialize as readable Lisp.
      (:options (prin1-to-string value))
      (:tag (prin1-to-string value))
      (:node-reference
       ;; Resolve node IDs to their titles for human-friendly export.
       (let* ((ids (cond
                    ((null value) nil)
                    ((and (listp value) (not (stringp value))) value)
                    (t (list value))))
              (titles
               (delq nil
                     (mapcar
                      (lambda (id)
                        (let* ((id-str (format "%s" id))
                               (node (supertag-node-get id-str))
                               (title (plist-get node :title)))
                          (or title id-str)))
                      ids))))
         (mapconcat #'identity titles ", ")))
      ;; Default: stringify.
      (_ (format "%s" (or value ""))))))

(defun supertag-export--global-field-order (node-id)
  "Return ordered, deduped field ids for NODE-ID using tag associations.
Falls back to any values already stored on the node to avoid data loss."
  (let ((tags (supertag-service-org--node-tags node-id))
        (seen (make-hash-table :test 'equal))
        (ordered '()))
    (dolist (tag-id tags)
      (dolist (field (supertag-tag-get-all-fields tag-id))
        (let* ((fid (or (plist-get field :id) (plist-get field :name)))
               (slug (and fid (supertag-sanitize-field-id fid))))
          (when (and slug (not (gethash slug seen)))
            (puthash slug t seen)
            (push slug ordered)))))
    ;; Append any field ids that already have values on the node (defensive).
    (let* ((vals (supertag-store-get-collection :field-values))
           (node-table (and (hash-table-p vals) (gethash node-id vals))))
      (when (hash-table-p node-table)
        (maphash
         (lambda (fid _)
           (unless (gethash fid seen)
             (puthash fid t seen)
             (push fid ordered)))
         node-table)))
    (nreverse ordered)))

(defun supertag-export--collect-node-field-properties (node-id)
  "Collect all field values for NODE-ID as an alist of (PROP . STRING)."
  (let* ((values (supertag-store-get-collection :field-values))
         (node-table (and (hash-table-p values) (gethash node-id values)))
         (field-ids (supertag-export--global-field-order node-id)))
    (when (hash-table-p node-table)
      (let (result)
        (dolist (field-id field-ids (nreverse result))
          (let ((value (gethash field-id node-table supertag-export--missing)))
            (unless (eq value supertag-export--missing)
              (push
               (cons (supertag-export--field-property-name nil field-id)
                     (supertag-export--field-value-to-string
                      nil field-id value))
               result))))))))

(defun supertag-export--apply-properties-at-point (props-alist)
  "Apply PROPS-ALIST as ST_* properties at current heading.
Returns non-nil when any property was changed."
  (let ((existing (org-entry-properties nil 'standard))
        (changed nil))
    ;; Set or update properties
    (dolist (pair props-alist)
      (let* ((key (car pair))
             (new (or (cdr pair) ""))
             (old (cdr (assoc key existing))))
        (unless (string= (or old "") new)
          (org-entry-put (point) key new)
          (setq changed t))))
    changed))

(defun supertag-export-all-fields-to-properties (&optional save-buffers)
  "Export all field values from the database into Org properties.
This scans the global :field-values collection and updates Org properties
on each node heading.  When SAVE-BUFFERS is non-nil
(or when called interactively with a prefix argument), modified buffers
are saved automatically."
  (interactive "P")
  (let* ((fields-root (supertag-store-get-collection :field-values))
         (node-ids (when (hash-table-p fields-root)
                     (let (ids)
                       (maphash (lambda (id _value)
                                  (push id ids))
                                fields-root)
                       (nreverse ids)))))
    (cond
     ((not (hash-table-p fields-root))
      (message "Supertag export: :field-values collection is not initialized."))
     ((null node-ids)
      (message "Supertag export: no nodes with field values found."))
     (t
      (let* ((total (length node-ids))
             (reporter (make-progress-reporter
                        "Supertag: exporting fields to Org properties..."
                        0 total))
             (modified-files (make-hash-table :test 'equal))
             (index 0))
        (dolist (node-id node-ids)
          (cl-incf index)
          (let ((props (supertag-export--collect-node-field-properties node-id)))
            (when props
              (supertag-service-org--with-node-buffer
               node-id
               (lambda ()
                 (when (org-at-heading-p)
                   (let ((changed (supertag-export--apply-properties-at-point props)))
                     (when changed
                       (let ((file (buffer-file-name)))
                         (when file
                           (puthash file t modified-files)
                           (when save-buffers
                             (save-buffer)
                             (supertag--mark-internal-modification file)))))))))))
          (progress-reporter-update reporter index))
        (progress-reporter-done reporter)
        (let ((file-count (hash-table-count modified-files)))
          (message "Supertag export: processed %d nodes, modified %d files%s."
                   total
                   file-count
                   (if save-buffers ", saved buffers" ""))))))))


(provide 'supertag-service-org)
;;; supertag-service-org.el ends here
