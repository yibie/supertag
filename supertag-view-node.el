;;; supertag/supertag-view-node.el --- Node-centric view for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file provides the node-centric view for Supertag. It defines
;; a major mode and commands to display and interact with a single node's
;; metadata in a dedicated buffer.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-ops-node)
(require 'supertag-ops-tag)
(require 'supertag-ops-field)
(require 'supertag-ops-global-field)
(require 'supertag-ops-relation)
(require 'supertag-view-helper)
(require 'supertag-services-ui)
(require 'supertag-services-query)
(require 'supertag-view-api)
(require 'supertag-view-framework)
(require 'supertag-view-link)
(require 'supertag-view-reference)
(require 'supertag-view-mention)
(require 'supertag-ui-link)
(require 'supertag-ontology-function)
(require 'supertag-ontology-action)
(require 'supertag-ui-action)
(require 'supertag-ontology-policy)
(declare-function supertag-view--resolve-node-tags "supertag-services-ui" (node-id))

;;; --- Variables ---

(defvar-local supertag-view-node--current-node-id nil
  "The ID of the node currently displayed in the view buffer.")

;; Side-window presenter + follow support
(defconst supertag-view-node--buffer-name "*Supertag Node*")
(defvar supertag-view-node--enabled nil)
(defvar supertag-view-node--last-entity-id nil)

(defcustom supertag-view-node-side 'right
  "Side where the Node View side window appears.
One of 'right, 'left, 'bottom, or 'top."
  :type '(choice (const right) (const left) (const bottom) (const top))
  :group 'supertag)

(defcustom supertag-view-node-side-size 0.33
  "Default size of the Node View side window.
For 'left/'right, interpreted as a fraction of frame width (0.0–1.0).
For 'top/'bottom, interpreted as a number of lines (integer) or a fraction
if your Emacs accepts fractional heights for side windows."
  :type '(choice number integer)
  :group 'supertag)

(defcustom supertag-view-node-auto-show nil
  "Whether to automatically show the Node View side window and follow context."
  :type 'boolean
  :group 'supertag)

(defun supertag-view-node--buffer ()
  (let ((buf (get-buffer supertag-view-node--buffer-name)))
    (and buf (buffer-live-p buf) buf)))

(defun supertag-view-node--current-entity-id ()
  "Detect current node id from context (org/table/UI) safely.
Only query Org-specific helpers inside Org buffers to avoid errors like
Point must be at an Org heading. when invoked from other modes."
  (cond
   ;; Node View is read-only with respect to Org identity.
   ((derived-mode-p 'org-mode)
    (ignore-errors (org-entry-get (point) "ID")))
   ;; In table view mode, extract cell coords
   ((derived-mode-p 'supertag-view-table-mode)
    (when (fboundp 'supertag-view-table--get-cell-coords)
      (let* ((coords (ignore-errors (supertag-view-table--get-cell-coords))))
        (and coords (plist-get coords :entity-id)))))
   ;; Other modes: do not assume Org context; avoid calling Org-dependent helpers
   (t nil)))

(defun supertag-view-node--display-buffer (buffer _alist)
  "Display Node BUFFER using the configured side-window policy."
  (let ((size-key (if (memq supertag-view-node-side '(left right))
                      'window-width
                    'window-height)))
    (display-buffer-in-side-window
     buffer
     `((side . ,supertag-view-node-side)
       (slot . 0)
       (,size-key . ,supertag-view-node-side-size)))))

(defun supertag-view-node--build-view-state (input)
  "Build Node view state from Runtime INPUT."
  (let ((node-id (plist-get input :node-id)))
    (or (and node-id (supertag-view-build-node-state node-id))
        (list :id node-id :node nil))))

(defun supertag-view-node--render-view (state)
  "Render Node view STATE in the current buffer."
  (if (plist-get state :node)
      (supertag-view-node--render-from-state state)
    (let ((inhibit-read-only t)
          (node-id (plist-get state :id)))
      (erase-buffer)
      (setq supertag-view-node--current-node-id nil)
      (when node-id
        (insert (format "Node %s not found." node-id)))
      (goto-char (point-min)))))

(defun supertag-view-node--capture-selection ()
  "Return the current Node field selection."
  (supertag-view-node--get-context-at-point))

(defun supertag-view-node--restore-selection (selection)
  "Restore opaque Node field SELECTION."
  (let ((tag-id (plist-get selection :tag-id))
        (field-name (plist-get selection :field-name)))
    (unless (and tag-id field-name
                 (supertag-view-node--goto-field-in-buffer
                  (current-buffer) tag-id field-name))
      (supertag-view-node--goto-first-field))))

(defun supertag-view-node--subscribe-view (input _state refresh)
  "Subscribe Node view INPUT and return all cleanup callbacks."
  (let* ((origin (plist-get input :follow-buffer))
         (unsubscribe
          (supertag-view-api-subscribe
           :store-changed
           (lambda (path _old-value _new-value)
             (when (and (listp path)
                        (memq (car path)
                              '(:nodes :relations :field-values
                                :field-provenance)))
               (funcall refresh)))))
         (follow-local-p
          (and (buffer-live-p origin) (not supertag-view-node-auto-show))))
    (when follow-local-p
      (with-current-buffer origin
        (add-hook 'post-command-hook #'supertag-view-node--post-command nil t)))
    (list unsubscribe
          (lambda ()
            (when (and follow-local-p (buffer-live-p origin))
              (with-current-buffer origin
                (remove-hook 'post-command-hook
                             #'supertag-view-node--post-command t)))))))

(defun supertag-view-node--register-view ()
  "Register the Node Adapter when needed."
  (unless (supertag-view-get 'node)
    (supertag-view-register
     :id 'node
     :name "Node"
     :selectable nil
     :buffer-name supertag-view-node--buffer-name
     :mode-fn #'supertag-view-node-mode
     :state-fn #'supertag-view-node--build-view-state
     :render-fn #'supertag-view-node--render-view
     :subscribe-fn #'supertag-view-node--subscribe-view
     :capture-selection-fn #'supertag-view-node--capture-selection
     :restore-selection-fn #'supertag-view-node--restore-selection
     :display-action '(supertag-view-node--display-buffer))))

(defun supertag-view-node--show-side (&optional node-id)
  "Show node view as a side window and enable follow."
  (setq supertag-view-node--enabled t)
  (setq supertag-view-node--last-entity-id nil)
  (let ((target-id (or node-id (supertag-view-node--current-entity-id)))
        (origin (current-buffer)))
    (supertag-view-node--register-view)
    (supertag-view-open
     'node (list :node-id target-id :follow-buffer origin))))

(defun supertag-view-node--hide-side ()
  "Hide the side window and disable follow."
  (interactive)
  (setq supertag-view-node--enabled nil)
  (when-let ((buf (supertag-view-node--buffer)))
    (with-current-buffer buf
      (supertag-view--cleanup-instance))
    (dolist (win (get-buffer-window-list buf nil t))
      (when (window-live-p win) (delete-window win)))))

(defun supertag-view-node--post-command ()
  "Auto-refresh when current entity changes."
  (when (or supertag-view-node--enabled supertag-view-node-auto-show)
    (let ((eid (supertag-view-node--current-entity-id)))
      (unless (equal eid supertag-view-node--last-entity-id)
        (setq supertag-view-node--last-entity-id eid)
        (when eid
          (when-let ((buf (supertag-view-node--buffer)))
            (with-current-buffer buf
              (if supertag-view--instance
                  (progn
                    (setf (plist-get supertag-view--instance :input)
                          (plist-put
                           (copy-sequence
                            (plist-get supertag-view--instance :input))
                           :node-id eid))
                    (supertag-view-refresh buf))
                (supertag-view-node--render eid)))))))))

(defun supertag-view-node-ensure-shown ()
  "Ensure the Node View side window is visible and following."
  (when supertag-view-node-auto-show
    (unless (get-buffer-window (supertag-view-node--buffer))
      (let ((eid (supertag-view-node--current-entity-id)))
        (if eid
            (supertag-view-node--show-side eid)
          (supertag-view-node--show-side nil))))
    ;; Add global follow if not already
    (unless (member #'supertag-view-node--post-command post-command-hook)
      (add-hook 'post-command-hook #'supertag-view-node--post-command))))

(defun supertag-view-node-toggle-auto-show ()
  "Toggle automatic Node View side window following."
  (interactive)
  (setq supertag-view-node-auto-show (not supertag-view-node-auto-show))
  (if supertag-view-node-auto-show
      (progn
        (supertag-view-node-ensure-shown)
        (message "Node View auto-show: ON"))
    (remove-hook 'post-command-hook #'supertag-view-node--post-command)
    (supertag-view-node--hide-side)
    (message "Node View auto-show: OFF")))

(defcustom supertag-view-node-strip-todo-keywords t
  "Whether to strip TODO keywords from node titles in view buffers.
If non-nil, TODO keywords will be removed from titles.
If nil, titles will be displayed as-is with TODO keywords."
  :type 'boolean
  :group 'supertag)

(defcustom supertag-view-node-todo-keywords
  '("TODO" "DONE" "NEXT" "WAITING" "HOLD" "CANCELLED" "CANCELED"
    "STARTED" "DELEGATED" "DEFERRED" "SOMEDAY")
  "List of TODO keywords to strip from node titles.
Only used when `supertag-view-node-strip-todo-keywords' is non-nil.
You can customize this list to match your org-mode TODO keywords."
  :type '(repeat string)
  :group 'supertag)

;;; --- Visual Style Variables ---

;; These functions are now available in supertag-view-helper.el
;; Keeping these as convenience aliases for backward compatibility
(defun supertag-view-node--get-theme-adaptive-color (light-color dark-color)
  "Get color that adapts to current theme."
  (supertag-view-helper-get-theme-adaptive-color light-color dark-color))

(defun supertag-view-node--get-accent-color ()
  "Get accent color that works well in both light and dark themes."
  (supertag-view-helper-get-accent-color))

(defun supertag-view-node--get-emphasis-color ()
  "Get emphasis color that works well in both light and dark themes."
  (supertag-view-helper-get-emphasis-color))

;;; --- Mode Definition ---

(defvar supertag-view-node-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Navigation (snap cursor to Field value column when present)
    (define-key map (kbd "n") 'next-line)
    (define-key map (kbd "p") 'previous-line)
    (define-key map (kbd "j") 'next-line)
    (define-key map (kbd "k") 'previous-line)
    (define-key map (kbd "SPC") 'scroll-up-command)
    (define-key map (kbd "S-SPC") 'scroll-down-command)
    (define-key map (kbd "M-v") 'scroll-down-command)
    (define-key map (kbd "C-v") 'scroll-up-command)
    (define-key map (kbd "M-<") 'beginning-of-buffer)
    (define-key map (kbd "M->") 'end-of-buffer)

    ;; Field value editing
    (define-key map (kbd "RET") 'supertag-view-node-edit-at-point)
    (define-key map (kbd "c") #'supertag-view-node-confirm-field-at-point)
    (define-key map (kbd "x") #'supertag-view-node-reject-field-at-point)
    (define-key map (kbd "C") #'supertag-view-node-review-ai-fields)

    ;; Typed Links
    (let ((link-map (make-sparse-keymap "Link...")))
      (define-key link-map "a" #'supertag-link-add)
      (define-key link-map "d" #'supertag-link-remove)
      (define-key link-map "l" #'supertag-link-menu)
      (define-key map "l" link-map))

    ;; Ontology Action selected at point, or choose one for the node.
    (define-key map (kbd "A") #'supertag-action-run)

    ;; Utility
    (define-key map (kbd "g") 'supertag-view-node-refresh)
    (define-key map (kbd "q") #'supertag-view-node--hide-side)
    (define-key map (kbd "h") 'describe-mode)
    ;; Debug
    (define-key map (kbd "?") 'supertag-view-node-debug-field-at-point)
    map)
  "Keymap for `supertag-view-node-mode'.
Users can rebind keys in this map to avoid conflicts with modal editing.")

(define-derived-mode supertag-view-node-mode special-mode "Supertag Node"
  "A modern major mode for viewing and editing an Supertag node.

\{supertag-view-node-mode-map}

Key Bindings:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📝 Field Operations:
  RET     - Edit field value at point. All schema changes (adding, deleting,
            or reordering fields) should be done in the Schema View (M-x supertag-view-schema).
  c       - Confirm an agent-written value (⟨AI⟩ badge) as a fact
  x       - Reject an agent-written value, restoring its previous value or clearing it
  C       - Review all agent-written values on this node

🧭 Navigation:
  j/k     - Move up/down by line (also n/p)
  SPC     - Scroll down one page
  S-SPC   - Scroll up one page (also M-v)
  C-v     - Scroll down one page
  M-<     - Jump to beginning of buffer
  M->     - Jump to end of buffer

🔧 Actions:
  A       - Run or propose an Ontology Action
  g       - Refresh the view
  h       - Show this help (describe-mode)
  q       - Quit and close window

💡 Tips:
  - Click on any field value or name to edit it
  - ⟨AI⟩ means an agent wrote the value; ⟨AI · outdated⟩ means the node text changed afterwards
  - RET on a Reference or Backlink title opens its source node
  - Field types determine input validation and display format
  - Changes are saved automatically
  - Use Tab completion when available

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  :group 'supertag
  :keymap supertag-view-node-mode-map
  (setq-local buffer-read-only t)
  ;; Ensure cursor is visible in this special-mode buffer
  (setq-local cursor-type 'box)
  (setq-local mode-line-format
        '(" "
          (:propertize mode-name face (:weight bold :foreground "#0066CC"))
          " | 📄 "
          (:eval (let ((node-id (or supertag-view-node--current-node-id "None")))
                  (if (string= node-id "None")
                      (propertize node-id 'face '(:foreground "gray"))
                    (propertize (truncate-string-to-width node-id 20 nil nil "...")
                               'face '(:weight bold)))))
          " | 🏷️ "
          (:eval (let ((count (or (supertag-view-node--count-fields supertag-view-node--current-node-id) 0)))
                  (propertize (format "%d" count)
                              'face (if (> count 0) '(:foreground "#22C55E" :weight bold) '(:foreground "gray")))))
          " | 🔗 "
          (:eval (let ((refs (length (supertag-view-node--get-references supertag-view-node--current-node-id)))
                       (refd-by (length (supertag-view-node--get-referenced-by supertag-view-node--current-node-id))))
                  (propertize (format "%d→%d" refs refd-by)
                              'face (if (> (+ refs refd-by) 0) '(:foreground "#0066CC" :weight bold) '(:foreground "gray")))))
          " %[%p%] "))
  ;; Ensure Evil does not take over this buffer: disable Evil locally if available.
  (when (fboundp 'evil-local-mode)
    (ignore-errors (evil-local-mode -1)))
  ;; Line highlighting disabled to prevent cursor movement flickering.
  ;; Runtime owns Store subscriptions and cleanup.
  )

;;; --- Helper Functions ---

;; Line highlighting functions are now in supertag-view-helper.el
;; Keeping these as convenience aliases for backward compatibility
(defun supertag-view-node--highlight-current-line ()
  "Highlight the current line for better visibility."
  (supertag-view-helper-highlight-current-line))

(defun supertag-view-node--unhighlight-all-lines ()
  "Remove all line highlighting."
  (supertag-view-helper-unhighlight-all-lines))

(defun supertag-view-node--count-fields (node-id)
  "Count the total number of fields for NODE-ID."
  (when node-id
    (let* ((tag-ids (supertag-view--resolve-node-tags node-id))
           (seen (make-hash-table :test 'equal))
           (count 0))
      (dolist (tag-id tag-ids)
        (dolist (field (supertag-query-resolved-fields tag-id))
          (let* ((fid (or (plist-get field :id) (plist-get field :name)))
                 (slug (and fid (supertag-sanitize-field-id fid)))
                 (dedupe slug))
            (when (and dedupe (not (gethash dedupe seen)))
              (puthash dedupe t seen)
              (cl-incf count)))))
      count)))

(defun supertag-view-node--get-references (node-id)
  "Get references from NODE-ID to other nodes."
  (when node-id
    (let ((relations (supertag-query-relations-from node-id :reference)))
      (mapcar (lambda (rel) (plist-get rel :to)) relations))))

(defun supertag-view-node--get-referenced-by (node-id)
  "Get nodes that reference NODE-ID."
  (when node-id
    (mapcar (lambda (relation) (plist-get relation :from))
            (supertag-query-relations-to node-id :reference))))

(defun supertag-view-node--format-display-value (value field-def)
  "Format VALUE for display with enhanced styling based on FIELD-DEF."
  (supertag-view-helper-format-field-value field-def value))

(defun supertag-view-node--provenance-badge (node-id tag-id field-name)
  "Return a badge for an agent-written FIELD-NAME value of NODE-ID, or nil.
Values a person confirmed or wrote carry no badge; an agent value whose
source text changed since is marked outdated."
  (let ((provenance (supertag-field-provenance node-id tag-id field-name)))
    (when (eq (plist-get provenance :origin) :agent)
      (if (supertag-field-stale-p node-id tag-id field-name)
          (propertize "⟨AI · outdated⟩"
                      'face `(:foreground ,(supertag-view-helper-get-warning-color))
                      'help-echo "Written by an agent before the node text changed. c confirms, x rejects, C reviews all.")
        (propertize "⟨AI⟩"
                    'face `(:foreground ,(supertag-view-helper-get-muted-color))
                    'help-echo (format "Written by %s at %s. c confirms, x rejects, C reviews all."
                                       (or (plist-get provenance :model) "an agent")
                                       (or (plist-get provenance :at) "an unknown time")))))))

;;; --- Modern Rendering Functions ---

(defun supertag-view-node--strip-todo-keyword (title)
  "Remove TODO keywords from TITLE if configured to do so.
Removes org-mode TODO keywords based on `supertag-view-node-todo-keywords'.
Only strips keywords if `supertag-view-node-strip-todo-keywords' is non-nil."
  (if (not supertag-view-node-strip-todo-keywords)
      title
    (let ((keywords-regexp (concat "^\\("
                                   (mapconcat #'regexp-quote
                                             supertag-view-node-todo-keywords
                                             "\\|")
                                   "\\)\\s-+")))
      (if (string-match keywords-regexp title)
          (string-trim (substring title (match-end 0)))
        title))))

(defun supertag-view-node--insert-simple-header (node-data)
  "Insert a simple, clean header with NODE-DATA."
  (let* ((raw-title (or (plist-get node-data :title) "Untitled Node"))
         (title (supertag-view-node--strip-todo-keyword raw-title))
         (file (plist-get node-data :file))
         (node-id supertag-view-node--current-node-id)
         (field-count (supertag-view-node--count-fields node-id))
         (ref-count (+ (length (supertag-view-node--get-references node-id))
                       (length (supertag-view-node--get-referenced-by node-id))))
         (stats (format "⚡ %d fields | 🔗 %d refs" field-count ref-count))
         (start (point)))
    (supertag-view-helper-insert-simple-header
     (format "📄 %s" (supertag-view-helper-render-org-links title))
     stats)
    (when file
      (insert (propertize (format "📁 %s\n\n" (file-name-nondirectory file))
                          'face `(:foreground ,(supertag-view-helper-get-muted-color) :slant italic))))
    (add-text-properties start (point)
                         `(supertag-entity-id ,node-id))))

;;; --- Rendering Functions ---

(defun supertag-view-node--tag-display-name (tag-id)
  "Return the human-readable name for TAG-ID.
Prefer the canonical display path, then the stored `:name', and fall back
to TAG-ID itself only when no Tag record is available."
  (let ((tag-data (supertag-tag-get tag-id)))
    (or (and tag-data
             (let ((path (ignore-errors (supertag-tag-display-path tag-id))))
               (and (stringp path) (not (string-empty-p path)) path)))
        (and tag-data (plist-get tag-data :name))
        tag-id)))

(defun supertag-view-node--insert-tag-block (tag-id fields node-id)
  "Insert a tag block for TAG-ID with FIELDS for NODE-ID.
The header shows the Tag's display name while text properties keep the
stable TAG-ID so interactive commands still resolve the record."
  (insert (propertize (format "🏷️ %s\n"
                              (supertag-view-node--tag-display-name tag-id))
                      'face `(:weight bold :foreground ,(supertag-view-helper-get-accent-color))
                      'supertag-context t
                      'type :tag
                      'tag-id tag-id
                      'field-name nil
                      'id tag-id))
  (if (or (null fields) (zerop (length fields)))
      (supertag-view-helper-insert-simple-empty-state "No fields defined")
    (dolist (field-def fields)
      (let* ((field-name (plist-get field-def :name))
             (value (supertag-field-get-with-default node-id tag-id field-name))
             (badge (supertag-view-node--provenance-badge
                     node-id tag-id field-name))
             (line-start (point))
             (interactive-props `(field-name ,field-name
                                  tag-id ,tag-id
                                  field-def ,field-def
                                  supertag-context t
                                  type :field-value
                                  mouse-face highlight
                                  help-echo "Click to edit this field")))
        (supertag-view-helper-insert-field-line
         field-name value field-def interactive-props badge)
        ;; The helper applies row-level interactivity after inserting BADGE,
        ;; which overwrites the badge's own tooltip.  Restore that one
        ;; property locally so provenance remains discoverable on hover.
        (when badge
          (let ((badge-text (substring-no-properties badge))
                (tooltip (get-text-property 0 'help-echo badge)))
            (save-excursion
              (goto-char line-start)
              (when (search-forward badge-text (line-end-position) t)
                (put-text-property (- (point) (length badge-text)) (point)
                                   'help-echo tooltip))))))))
  (insert "\n"))

(defun supertag-view-node--insert-simple-metadata-section (node-id)
  "Insert a simple metadata section for NODE-ID."
  (let* ((tag-ids (sort (supertag-view--resolve-node-tags node-id) #'string<))
         (deleted-tags '())
         (valid-tags '()))

    ;; Separate valid and deleted tags
    (dolist (tag-id tag-ids)
      (let ((tag-data (supertag-tag-get tag-id)))
        (if tag-data
            (push tag-id valid-tags)
          (push tag-id deleted-tags))))

    ;; IMPORTANT: Do not mutate datastore from view rendering.
    ;; Previously, this section attempted to "clean up" relations to tags
    ;; considered deleted (missing in the current store). However, during
    ;; startup or file reloads, the store/tag cache may not be fully
    ;; materialized yet, causing valid tags to appear missing and leading to
    ;; unintended deletions. We keep a passive notice instead.
    ;; If cleanup is needed, it should be performed by an explicit ops/migration
    ;; command, not by a view.

    ;; Display content with simple styling
    (if (and (not valid-tags) (not deleted-tags))
        (progn
          (supertag-view-helper-insert-section-title "Metadata" "🏷️")
          (supertag-view-helper-insert-simple-empty-state "No metadata found."))

      ;; Display valid tags with simple blocks
      (supertag-view-helper-insert-section-title "Metadata" "🏷️")
      (let ((seen (make-hash-table :test 'equal)))
        (dolist (tag-id (sort valid-tags #'string<))
          (let* ((fields (supertag-query-resolved-fields tag-id))
                 (filtered (cl-loop for f in (or fields '())
                                    for fid = (or (plist-get f :id) (plist-get f :name))
                                    for slug = (and fid (supertag-sanitize-field-id fid))
                                    for dedupe = slug
                                    unless (and dedupe (gethash dedupe seen))
                                    do (when dedupe (puthash dedupe t seen))
                                    and collect f)))
            ;; Defensively ensure `fields` is a list to prevent rendering errors.
            (when filtered
              (supertag-view-node--insert-tag-block tag-id filtered node-id)))))

      ;; Show a passive warning for tags currently not found (no deletion here)
      (when deleted-tags
        (insert (propertize (format "⚠️ %d tag%s not found (skipped cleanup)\n\n"
                                    (length deleted-tags)
                                    (if (= (length deleted-tags) 1) "" "s"))
                            'face `(:foreground ,(supertag-view-helper-get-warning-color))))))))

(defun supertag-view-node--insert-node-link-line (node-id)
  "Insert a single clickable line for NODE-ID.
The line looks like `📄 Title' and is clickable with RET/mouse-1."
  (when-let* ((node (supertag-view-api-get-entity :nodes node-id)))
    (let* ((raw-title (or (plist-get node :raw-value)
                          (plist-get node :title)
                          "[Untitled]"))
           (display-title (if (fboundp 'org-link-display-format)
                              (org-link-display-format raw-title)
                            raw-title))
           (start (point))
           (map (make-sparse-keymap))
           (action `(lambda () (interactive) (supertag-goto-node ,node-id))))
      (insert (format "    📄 %s\n" (string-trim display-title)))
      (define-key map [mouse-1] action)
      (define-key map (kbd "RET") action)
      (add-text-properties
       start (point)
       `(supertag-node-id ,node-id
                          face (:foreground ,(supertag-view-helper-get-muted-color))
                          keymap ,map
                          mouse-face highlight
                          help-echo ,(format "Jump to node: %s" node-id))))))


(defun supertag-view-node--insert-semantic-relations-section (node-id)
  "Insert semantic relations section for NODE-ID.
Groups relations by type, showing outgoing and incoming with display names."
  (let ((semantic-types (supertag-relation-type-list-semantic)))
    (when semantic-types
      (let ((has-any nil))
        ;; First pass: check if there are any semantic relations
        (dolist (entry semantic-types)
          (let* ((rel-type (car entry))
                 (outgoing (supertag-query-relations-from node-id rel-type))
                 (incoming (supertag-query-relations-to node-id rel-type)))
            (when (or outgoing incoming)
              (setq has-any t))))
        (when has-any
          (supertag-view-helper-insert-section-title "Relations" "🔗")
          (dolist (entry semantic-types)
            (let* ((rel-type (car entry))
                   (meta (cdr entry))
                   (name (plist-get meta :name))
                   (inverse-name (or (plist-get meta :inverse-name) name))
                   (outgoing (supertag-query-relations-from node-id rel-type))
                   (incoming (supertag-query-relations-to node-id rel-type)))
              ;; Outgoing relations
              (when outgoing
                (insert (format "  %s (%d)\n" name (length outgoing)))
                (dolist (rel outgoing)
                  (supertag-view-node--insert-node-link-line (plist-get rel :to))
                  (let ((note (plist-get (plist-get rel :props) :context-note)))
                    (when (and note (not (string-empty-p note)))
                      (insert (format "      ╰ %s\n"
                                      (propertize note 'face 'font-lock-comment-face)))))))
              ;; Incoming relations
              (when incoming
                (insert (format "  %s (%d)\n" inverse-name (length incoming)))
                (dolist (rel incoming)
                  (supertag-view-node--insert-node-link-line (plist-get rel :from))
                  (let ((note (plist-get (plist-get rel :props) :context-note)))
                    (when (and note (not (string-empty-p note)))
                      (insert (format "      ╰ %s\n"
                                      (propertize note 'face 'font-lock-comment-face)))))))))
          (insert "\n"))))))

(defun supertag-view-node--insert-action-row (node-id definition)
  "Insert one Policy-aware Action row for NODE-ID and DEFINITION."
  (let* ((decision
          (supertag-ontology-policy-evaluate definition :interactive-user))
         (outcome (plist-get decision :decision))
         (start (point))
         (map (make-sparse-keymap))
         (action-id (plist-get definition :runtime-id))
         (button
          (pcase outcome
            ((or :allow :confirm) "Run")
            (:propose-only "Propose")
            (_ "Denied"))))
    (insert (format "  %s [%s]" (plist-get definition :label) button))
    (unless (eq outcome :deny)
      (let ((command
             `(lambda ()
                (interactive)
                (supertag-action-run ,node-id ,action-id))))
        (define-key map (kbd "RET") command)
        (define-key map [mouse-1] command)
        (add-text-properties
         start (point)
         `(face link mouse-face highlight keymap ,map
                supertag-action-id ,action-id
                help-echo ,(format "%s %s"
                                   button
                                   (plist-get definition :label))))))
    (when (eq outcome :deny)
      (add-face-text-property start (point) 'shadow t))
    (insert "\n")))

(defun supertag-view-node--insert-ontology-capabilities-section (node-id)
  "Insert applicable Ontology Functions and Policy-governed Actions.
Listing never evaluates Function results or Action preconditions."
  (let ((functions (supertag-ontology-function-applicable node-id))
        (actions (supertag-ontology-action-applicable node-id)))
    (when functions
      (supertag-view-helper-insert-section-title "Functions" "ƒ")
      (dolist (definition functions)
        (insert (format "  %s\n" (plist-get definition :label))))
      (insert "\n"))
    (when actions
      (supertag-view-helper-insert-section-title "Actions" "▶")
      (dolist (definition actions)
        (supertag-view-node--insert-action-row node-id definition))
      (insert "\n"))))

;; Add advanced editing functions
(defun supertag-view-node-debug-field-at-point ()
  "Debug function to show field information at point."
  (interactive)
  (let* ((pos (point))
         (fallback-pos (max (point-min) (1- pos)))
         (tag-id     (or (get-text-property pos 'tag-id)
                         (get-text-property fallback-pos 'tag-id)))
         (field-name (or (get-text-property pos 'field-name)
                         (get-text-property fallback-pos 'field-name)))
         (node-id supertag-view-node--current-node-id)
         (context (get-text-property pos 'supertag-context))
         (type (get-text-property pos 'type)))
    (message "Debug: pos=%d, tag-id=%s, field-name=%s, node-id=%s, context=%s, type=%s"
             pos tag-id field-name node-id context type)))



(defun supertag-view-node--disallow-definition-edit ()
  "Signal that field definition edits are not available in node view."
  (user-error "Field definitions are read-only here; use `supertag-view-schema' instead."))

(defun supertag-view-node-edit-field-definition-at-point ()
  "Edit the field definition at the current point."
  (interactive)
  (supertag-view-node--disallow-definition-edit))

(defun supertag-view-node-move-field-up ()
  "Move the field at point up in its tag's field list."
  (interactive)
  (supertag-view-node--disallow-definition-edit))

(defun supertag-view-node-move-field-down ()
  "Move the field at point down in its tag's field list."
  (interactive)
  (supertag-view-node--disallow-definition-edit))

(defun supertag-view-node--render-from-state (state)
  "Render a simple, clean view for NODE described by STATE.
STATE 应由 `supertag-view-build-node-state' 构造，只包含数据，不做任何 buffer 操作。"
  (let* ((node-id (plist-get state :id))
         (node-data (plist-get state :node))
         (inhibit-read-only t))
    (erase-buffer)
    (setq supertag-view-node--current-node-id node-id)
    (when node-data
      ;; Simple header
      (supertag-view-node--insert-simple-header node-data)

      ;; Simple metadata section
      (supertag-view-node--insert-simple-metadata-section node-id)

      ;; Applicable typed capabilities.  Listing is read-only and does not run
      ;; potentially expensive Function or Action preconditions.
      (supertag-view-node--insert-ontology-capabilities-section node-id)

      ;; Contextual outgoing references and incoming Backlinks.  This remains
      ;; a disposable projection, never a second reference store.
      (supertag-view-reference-insert-sections node-id)

      ;; Potential references discovered from source-owned plain text.
      ;; These are computed candidates, never persisted facts.
      (supertag-view-mention-insert-section node-id)
      (insert "\n")

      ;; Typed operational Links
      (supertag-view-link-insert-section node-id)

      ;; Semantic relations section
      (supertag-view-node--insert-semantic-relations-section node-id)

      ;; Complete footer with all available shortcuts
      (supertag-view-helper-insert-simple-footer
       "Field: [RET] Edit | [c] Confirm AI | [x] Reject AI | [C] Review AI"
       "📍 Navigation: [j/k] Move | [SPC] Page Down | [S-SPC] Page Up | [M-</>] Start/End"
       "🔧 Actions: [l a] Add Link | [A] Run | [g] Refresh | [h] Help | [q] Quit")

      ;; Activate links in the entire buffer
      (supertag-view-node--activate-links-in-buffer))
    (goto-char (point-min))))

(defun supertag-view-node--render (node-id)
  "Render a simple, clean view for NODE-ID."
  (supertag-view-node--render-view
   (supertag-view-node--build-view-state (list :node-id node-id))))

;;; --- Link Activation ---

(defun supertag-view-node--activate-links-in-buffer ()
  "Find all [[id:...]] links in the buffer and make them clickable."
  (goto-char (point-min))
  (let ((inhibit-read-only t))
    (while (re-search-forward "\[\[id:\([0-9A-Za-z-]+\)\]\[\(.*?\)\]\]" nil t)
      (let* ((id (match-string 1))
             (desc (match-string 2))
             (action `(lambda () (interactive) (supertag-goto-node ,id)))
             (map (make-sparse-keymap)))
        (define-key map [mouse-1] action)
        (define-key map (kbd "RET") action)

        (add-text-properties (match-beginning 0) (match-end 0)
                             `(display ,desc
                               face org-link
                               keymap ,map
                               help-echo ,(format "Jump to node ID: %s" id)))))))

;;; --- Interactive Functions ---

(defun supertag-view-node--get-context-at-point ()
  "Return a plist of supertag context at point, or nil."
  (let ((pos (point)))
    ;; Check current point first, then fallback to point before it.
    (unless (get-text-property pos 'supertag-context)
      (setq pos (max (point-min) (1- pos))))
    (when (get-text-property pos 'supertag-context)
      (list :type (get-text-property pos 'type)
            :tag-id (get-text-property pos 'tag-id)
            :field-name (get-text-property pos 'field-name)
            :id (get-text-property pos 'id)))))

(defun supertag-view-node-confirm-field-at-point ()
  "Confirm the field value at point as a fact a person stands behind.
The value stays as it is; its provenance becomes `:human', which removes
the ⟨AI⟩ badge and stops the value from being reported as outdated."
  (interactive)
  (let ((context (supertag-view-node--get-context-at-point)))
    (if (not (eq (plist-get context :type) :field-value))
        (message "No field value at point.")
      (let* ((node-id supertag-view-node--current-node-id)
             (tag-id (plist-get context :tag-id))
             (field-name (plist-get context :field-name))
             (provenance (supertag-field-provenance node-id tag-id field-name)))
        (if (eq (plist-get provenance :origin) :human)
            (message "Field '%s' is already confirmed." field-name)
          (condition-case err
              (progn
                (supertag-field-confirm node-id tag-id field-name)
                (supertag-view-node--refresh-view)
                (supertag-view-node--goto-field tag-id field-name)
                (message "✓ Field '%s' confirmed." field-name))
            (error
             (message "Cannot confirm: %s" (error-message-string err)))))))))

(defun supertag-view-node--tag-for-field (node-id field-id)
  "Return the first Tag of NODE-ID that exposes FIELD-ID, or nil."
  (cl-loop for tag-id in (supertag-view--resolve-node-tags node-id)
           when (cl-find field-id (supertag-query-resolved-fields tag-id)
                         :key (lambda (field)
                                (or (plist-get field :id)
                                    (and-let* ((name (plist-get field :name)))
                                      (supertag-sanitize-field-id name))))
                         :test #'equal)
           return tag-id))

(defun supertag-view-node--ai-provenance-fields (node-id)
  "Return sorted review entries for agent-written fields of NODE-ID.
Each entry carries the stable field id, display name, schema Tag, value,
and a copy of its provenance record."
  (let* ((root (supertag-store-get-collection :field-provenance))
         (bucket (and (hash-table-p root) (gethash node-id root)))
         entries)
    (when (hash-table-p bucket)
      (maphash
       (lambda (field-id provenance)
         (when (eq (plist-get provenance :origin) :agent)
           (let* ((definition (supertag-global-field-get field-id))
                  (field-name (or (plist-get definition :name) field-id))
                  (tag-id (supertag-view-node--tag-for-field node-id field-id)))
             (push (list :field-id field-id
                         :field-name field-name
                         :tag-id tag-id
                         :value (supertag-field-get
                                 node-id tag-id field-name)
                         :provenance (copy-tree provenance))
                   entries))))
       bucket))
    (sort entries
          (lambda (left right)
            (string-lessp (downcase (plist-get left :field-name))
                          (downcase (plist-get right :field-name)))))))

(defun supertag-view-node--review-entry-label (entry)
  "Return a compact minibuffer label for provenance review ENTRY."
  (let* ((tag-id (plist-get entry :tag-id))
         (field-name (plist-get entry :field-name))
         (value (format "%S" (plist-get entry :value)))
         (qualified-name
          (if tag-id
              (format "%s / %s"
                      (supertag-view-node--tag-display-name tag-id)
                      field-name)
            field-name)))
    (format "%s = %s" qualified-name
            (truncate-string-to-width value 60 nil nil "…"))))

(defun supertag-view-node--reject-ai-field (node-id tag-id field-name)
  "Reject NODE-ID's agent-written FIELD-NAME value.
Restore `:previous' when the current provenance record carries that key;
otherwise remove the value.  Return `:restored' or `:cleared'."
  (let ((provenance (supertag-field-provenance node-id tag-id field-name)))
    (unless (eq (plist-get provenance :origin) :agent)
      (error "Field '%s' is not agent-written" field-name))
    (if (plist-member provenance :previous)
        (progn
          ;; A person chose to restore this value, so the restored fact is
          ;; recorded through the normal Field writer as human-authored.
          (supertag-field-set node-id tag-id field-name
                              (plist-get provenance :previous)
                              '(:origin :human))
          :restored)
      (supertag-field-remove node-id tag-id field-name)
      :cleared)))

(defun supertag-view-node-reject-field-at-point ()
  "Reject the agent-written field value at point after confirmation.
The field's recorded `:previous' value is restored when present; otherwise
the value is cleared.  Refresh the Node View after a successful rejection."
  (interactive)
  (let ((context (supertag-view-node--get-context-at-point)))
    (if (not (eq (plist-get context :type) :field-value))
        (message "No field value at point.")
      (let* ((node-id supertag-view-node--current-node-id)
             (tag-id (plist-get context :tag-id))
             (field-name (plist-get context :field-name))
             (provenance (supertag-field-provenance node-id tag-id field-name)))
        (cond
         ((not (eq (plist-get provenance :origin) :agent))
          (message "Field '%s' is not agent-written." field-name))
         ((not (y-or-n-p (format "Reject AI value for field '%s'? " field-name)))
          (message "Rejection cancelled."))
         (t
          (condition-case err
              (let ((result (supertag-view-node--reject-ai-field
                             node-id tag-id field-name)))
                (supertag-view-node--refresh-view)
                (supertag-view-node--goto-field tag-id field-name)
                (message "✓ Field '%s' rejected; %s."
                         field-name
                         (if (eq result :restored)
                             "previous value restored"
                           "value cleared")))
            (error
             (message "Cannot reject: %s" (error-message-string err))))))))))

(defun supertag-view-node-review-ai-fields ()
  "Review every agent-written field value on the current node.
For each field, press `c' to confirm, `x' to reject after a y-or-n prompt,
`s' to skip, `a' to confirm all remaining fields, or `q' to stop.  The
Node View refreshes once after all selected mutations are complete."
  (interactive)
  (let* ((node-id supertag-view-node--current-node-id)
         (entries (and node-id
                       (supertag-view-node--ai-provenance-fields node-id)))
         (total (length entries))
         (index 0)
         (confirmed 0)
         (rejected 0)
         (skipped 0)
         (changed nil)
         (stopped nil)
         errors)
    (if (zerop total)
        (progn
          (message "No agent-written fields to review on this node.")
          (list :confirmed 0 :rejected 0 :skipped 0 :stopped nil :errors nil))
      (while entries
        (let* ((entry (car entries))
               (tag-id (plist-get entry :tag-id))
               (field-name (plist-get entry :field-name))
               (choice
                (read-char-choice
                 (format "AI field %d/%d: %s  [c]onfirm [x]reject [a]ll-confirm [s]kip [q]uit "
                         (1+ index) total
                         (supertag-view-node--review-entry-label entry))
                 '(?c ?x ?a ?s ?q))))
          (pcase choice
            (?c
             (condition-case err
                 (progn
                   (supertag-field-confirm node-id tag-id field-name)
                   (setq confirmed (1+ confirmed)
                         changed t))
               (error
                (push (format "%s: %s" field-name
                              (error-message-string err))
                      errors)))
             (setq entries (cdr entries)
                   index (1+ index)))
            (?x
             (if (y-or-n-p (format "Reject AI value for field '%s'? "
                                   field-name))
                 (condition-case err
                     (progn
                       (supertag-view-node--reject-ai-field
                        node-id tag-id field-name)
                       (setq rejected (1+ rejected)
                             changed t))
                   (error
                    (push (format "%s: %s" field-name
                                  (error-message-string err))
                          errors)))
               (setq skipped (1+ skipped)))
             (setq entries (cdr entries)
                   index (1+ index)))
            (?a
             (dolist (remaining entries)
               (let ((remaining-tag (plist-get remaining :tag-id))
                     (remaining-field (plist-get remaining :field-name)))
                 (condition-case err
                     (progn
                       (supertag-field-confirm
                        node-id remaining-tag remaining-field)
                       (setq confirmed (1+ confirmed)
                             changed t))
                   (error
                    (push (format "%s: %s" remaining-field
                                  (error-message-string err))
                          errors)))))
             (setq entries nil))
            (?s
             (setq skipped (1+ skipped)
                   entries (cdr entries)
                   index (1+ index)))
            (?q
             (setq stopped t
                   entries nil)))))
      (when changed
        (supertag-view-node--refresh-view))
      (message "AI review: %d confirmed, %d rejected, %d skipped%s%s."
               confirmed rejected skipped
               (if stopped ", stopped early" "")
               (if errors (format ", %d failed" (length errors)) ""))
      (list :confirmed confirmed
            :rejected rejected
            :skipped skipped
            :stopped stopped
            :errors (nreverse errors)))))

(defun supertag-view-node-edit-at-point ()
  "Dispatch edit action based on the context at point."
  (interactive)
  (let ((context (supertag-view-node--get-context-at-point)))
    (when context
      (pcase (plist-get context :type)
        (:field-value (supertag-view-node--edit-field-value context))
        ;; TODO: Add other cases for editing tag, field-key etc.
        (_ (message "No edit action defined for this context."))))))

(defun supertag-view-node--edit-field-value (context)
  "Handle the logic to edit a field's value with enhanced UI feedback.
Field-type-specific side effects (e.g., :node-reference) are handled by
`supertag-field-set'."
  (let* ((node-id supertag-view-node--current-node-id)
         (tag-id (plist-get context :tag-id))
         (field-name (plist-get context :field-name))
         (field-def (supertag-tag-get-field tag-id field-name))
         ;; Remember caret offset within the value column to restore after update
         (saved-offset (let* ((bol (line-beginning-position))
                              (eol (line-end-position))
                              (vstart (text-property-any bol eol 'supertag-value-column t)))
                         (when vstart
                           (max 0 (- (point) vstart))))))
    (when field-def
      (other-window 1)
      (condition-case err
          (let* ((current-value (supertag-query-field-value node-id tag-id field-name))
                 (new-value (supertag-ui-read-field-value field-def current-value)))

            ;; Set the field value.  :node-reference side effects (relations +
            ;; backlinks) are handled inside `supertag-field-set'.  A value
            ;; typed here is a fact the person stands behind.
            (supertag-field-set node-id tag-id field-name new-value
                                '(:origin :human))
            (supertag-view-node--refresh-view)
            (supertag-view-node--focus-view)
            (when (supertag-view-node--goto-field tag-id field-name)
              ;; Restore caret position relative to the start of the value column
              (let* ((bol (line-beginning-position))
                     (eol (line-end-position))
                     (vstart (text-property-any bol eol 'supertag-value-column t))
                     (vend (and vstart (or (next-single-property-change vstart 'supertag-value-column nil eol)
                                           eol))))
                (when (and vstart vend)
                  (let* ((vlen (max 0 (- vend vstart)))
                         (delta (min (max (or saved-offset 0) 0) vlen)))
                    (goto-char (min (+ vstart delta) vend))))))
            (message "✓ Field '%s' updated successfully!" field-name))
        (quit
         ;; User cancelled (C-g): restore focus and caret to original field value
         (supertag-view-node--focus-view)
         (when (supertag-view-node--goto-field tag-id field-name)
           (let* ((bol (line-beginning-position))
                  (eol (line-end-position))
                  (vstart (text-property-any bol eol 'supertag-value-column t))
                  (vend (and vstart (or (next-single-property-change vstart 'supertag-value-column nil eol)
                                        eol))))
             (when (and vstart vend)
               (let* ((vlen (max 0 (- vend vstart)))
                      (delta (min (max (or saved-offset 0) 0) vlen)))
                 (goto-char (min (+ vstart delta) vend))))))
         (message "Edit cancelled"))
        (error
         ;; On any error, return focus and attempt to restore caret
         (supertag-view-node--focus-view)
         (ignore-errors (supertag-view-node--goto-field tag-id field-name))
         (message "Edit failed: %s" (error-message-string err)))))))

(defun supertag-view-node-add-field ()
  "Add a new field definition to a tag on the current node."
  (interactive)
  (supertag-view-node--disallow-definition-edit))


(defun supertag-view-node-remove-field-at-point ()
  "Remove the field definition at the current point from its tag."
  (interactive)
  (supertag-view-node--disallow-definition-edit))

;;; --- Navigation Helpers ---

(defun supertag-view-node--goto-field-in-buffer (buffer &optional tag-id field-name)
  "Move point inside BUFFER to field identified by TAG-ID and FIELD-NAME.
When TAG-ID or FIELD-NAME are nil, match the first available field.
Return non-nil when the target field is located."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((start (point-min))
             (end   (point-max))
             (pos   (text-property-any start end 'type :field-value))
             match)
        (while (and pos (not match))
          (let ((p-tag (get-text-property pos 'tag-id))
                (p-field (get-text-property pos 'field-name)))
            (when (and (or (null tag-id) (equal p-tag tag-id))
                       (or (null field-name) (equal p-field field-name)))
              (setq match pos)))
          (unless match
            (let ((next (next-single-property-change pos 'type nil end)))
              (setq pos (and next (text-property-any next end 'type :field-value))))))
        (when match
          (goto-char match)
          (beginning-of-line)
          (let ((bol (point))
                (eol (line-end-position)))
            (if-let ((valpos (text-property-any bol eol 'supertag-value-column t)))
                (goto-char valpos)
              (goto-char bol)))
          (point))))))

(defun supertag-view-node--goto-field (&optional tag-id field-name)
  "Move point in the active node view to TAG-ID and FIELD-NAME.
When both arguments are nil, jump to the first field."
  (when-let ((buffer (supertag-view-node--buffer)))
    (supertag-view-node--goto-field-in-buffer buffer tag-id field-name)))

(defun supertag-view-node--goto-first-field ()
  "Move point in the active node view to the first field line.
Falls back to beginning of buffer when no field is found."
  (or (supertag-view-node--goto-field nil nil)
      (progn (goto-char (point-min)) (point))))

(defun supertag-view-node--focus-view ()
  "Focus the side-window buffer if visible."
  (when-let* ((buf (supertag-view-node--buffer))
              (win (get-buffer-window buf)))
    (select-window win)
    (when (featurep 'evil)
      (when (fboundp 'evil-local-mode) (ignore-errors (evil-local-mode -1)))
      (when (fboundp 'evil-emacs-state) (ignore-errors (evil-emacs-state))))))

(defun supertag-view-node--refresh-view ()
  "Refresh side-window content, preserving scroll position."
  (when-let ((buf (supertag-view-node--buffer)))
    (with-current-buffer buf
      (if supertag-view--instance
          (supertag-view-refresh buf)
        (let ((eid (or supertag-view-node--current-node-id
                       (supertag-view-node--current-entity-id))))
          (when eid
            (let* ((saved-context (supertag-view-node--get-context-at-point))
                   (saved-tag (plist-get saved-context :tag-id))
                   (saved-field (plist-get saved-context :field-name)))
              (supertag-view-node--render eid)
              (unless (and saved-tag saved-field
                           (supertag-view-node--goto-field-in-buffer
                            buf saved-tag saved-field))
                (supertag-view-node--goto-first-field)))))))))


;;; --- Commands ---

(defun supertag-view-node-refresh ()
  "Refresh the node view buffer (side-window)."
  (interactive)
  (if (supertag-view-node--buffer)
      (progn
        (supertag-view-node--refresh-view)
        (supertag-view-node--focus-view))
    (message "No active supertag node view.")))

;;;###autoload
(defun supertag-view-node-open (node-id)
  "Open Node View for NODE-ID and focus its first field."
  (unless (and (stringp node-id) (not (string-empty-p node-id)))
    (user-error "Node View requires a node ID"))
  (supertag-view-node--show-side node-id)
  (supertag-view-node--focus-view)
  (when-let* ((buffer (supertag-view-node--buffer)))
    (with-current-buffer buffer
      (supertag-view-node--goto-first-field)
      (when-let* ((window (get-buffer-window buffer t)))
        (with-selected-window window
          (recenter)))))
  (supertag-view-node--buffer))

(defun supertag-view-node ()
  "Toggle the Supertag node view as a side window that follows context."
  (interactive)
  (let ((node-id (supertag-view-node--current-entity-id)))
    (if supertag-view-node--enabled
        (supertag-view-node--hide-side)
      (if node-id
          (supertag-view-node-open node-id)
        (user-error "No node detected at point")))))

;; If Evil is installed, set an initial state that won't override this mode's keys.
(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'supertag-view-node-mode 'emacs))
  ;; Also register the mode as emacs-state to avoid normal/motion takeover
  (when (boundp 'evil-emacs-state-modes)
    (add-to-list 'evil-emacs-state-modes 'supertag-view-node-mode)))

(provide 'supertag-view-node)

;;; --- Window Selection Integration ---

;; When user switches focus into the node view window, place point directly on
;; the first Field value column to reduce extra cursor movement.
(defun supertag-view-node--on-window-selection-change (_frame)
  "When node view buffer becomes selected, jump to a Field value column."
  (when-let* ((win (selected-window))
              (buf (and (window-live-p win) (window-buffer win))))
    (with-current-buffer buf
      (when (derived-mode-p 'supertag-view-node-mode)
        (let* ((bol (line-beginning-position))
               (eol (line-end-position))
               (valpos (text-property-any bol eol 'supertag-value-column t)))
          (if valpos
              (goto-char valpos)
            (ignore-errors (supertag-view-node--goto-first-field))))))))

;; Register the hook if available (Emacs 27+)
(when (boundp 'window-selection-change-functions)
  (add-hook 'window-selection-change-functions #'supertag-view-node--on-window-selection-change))

;;; supertag-view-node.el ends here
