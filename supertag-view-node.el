;;; supertag-view-node.el --- Node-centric view for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file provides the node-centric view for Supertag. It defines
;; a major mode and commands to display and interact with a single node's
;; metadata in a dedicated buffer.


;; Commands: supertag-view-node, supertag-view-node-refresh, supertag-view-node-mode; local key
;; command: supertag-view-node--hide-side.
;; Dependencies: cl-lib, org, subr-x, supertag-core-store, supertag-node, supertag-tag,
;; supertag-query, supertag-services-sync, supertag-view-framework, supertag-link,
;; supertag-mention, supertag-concept, supertag-ai, supertag-semantic. Node cache listener
;; preparation runs after Sync loads; Evil is optional and only disabled locally when available.
;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-tag)
(require 'supertag-query)
(require 'supertag-services-sync)
(supertag-node--prepare-cache-listener)
(require 'supertag-view-framework)
(require 'supertag-link)
(require 'supertag-mention)
(require 'supertag-concept)
(require 'supertag-ai)
(require 'supertag-semantic)
(declare-function supertag-view--resolve-node-tags "supertag-tag" (node-id))

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

;;; --- Node View State ---

(defun supertag-view-build-node-state (node-id)
  "Build a reusable view state plist for NODE-ID.

The returned plist is data-only (no buffer operations) and is intended
to be consumed by different UI layouts (node detail view, table-based
detail panes, previews, etc.).

Node View is read-only with respect to Org properties: it shows only
discovered context, never the node's saved properties.

Returned keys (current contract):
- :id           — NODE-ID
- :node         — Isolated node projection from `supertag-note-query-read-node'
- :tags         — List of tag IDs attached to this node
- :refs-to      — List of node IDs this node references (:reference)
- :refs-from    — List of node IDs that reference this node (:reference)
- :ref-count    — Total number of references (:refs-to + :refs-from)"
  (when (and node-id (stringp node-id))
    (when-let* ((detail (supertag-note-query-read-node node-id)))
      (let ((refs-to (mapcar (lambda (relation) (plist-get relation :to))
                            (supertag-query-ordinary-references-from node-id)))
            (refs-from (mapcar (lambda (relation) (plist-get relation :from))
                              (supertag-query-ordinary-references-to node-id))))
        (cl-remf detail :properties)
        (cl-remf detail :property-count)
        (append detail
                (list :tags (supertag-query-node-tags node-id)
                      :refs-to refs-to :refs-from refs-from
                      :ref-count (+ (length refs-to) (length refs-from))))))))

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
  "Return the current Node context selection."
  (supertag-view-node--get-context-at-point))

(defun supertag-view-node--restore-selection (selection)
  "Restore opaque Node context SELECTION, or fall back to buffer start."
  (goto-char (point-min))
  (when-let* ((id (plist-get selection :id)))
    (let ((pos (point-min)) found)
      (while (and (< pos (point-max)) (not found))
        (if (equal (get-text-property pos 'id) id)
            (setq found pos)
          (setq pos (or (next-single-property-change pos 'id nil (point-max))
                        (point-max)))))
      (when found (goto-char found)))))

(defun supertag-view-node--subscribe-view (input _state refresh)
  "Subscribe Node view INPUT and return all cleanup callbacks."
  (let* ((origin (plist-get input :follow-buffer))
         (unsubscribe
          (supertag-view-api-subscribe
           :store-changed
           (lambda (path _old-value _new-value)
             (when (and (listp path)
                        (memq (car path)
                              '(:nodes :relations :tags)))
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
          (when-let* ((buf (supertag-view-node--buffer)))
            (if (buffer-local-value 'supertag-view--instance buf)
                (with-current-buffer buf
                  (setf (plist-get supertag-view--instance :input)
                        (plist-put
                         (copy-sequence
                          (plist-get supertag-view--instance :input))
                         :node-id eid))
                  (supertag-view-refresh buf))
              (supertag-view-node--show-side eid))))))))

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

;; Shared color functions are owned by supertag-view-framework.el
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
    ;; Navigation
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

    ;; Utility
    (define-key map (kbd "g") 'supertag-view-node-refresh)
    (define-key map (kbd "q") #'supertag-view-node--hide-side)
    (define-key map (kbd "h") 'describe-mode)
    map)
  "Keymap for `supertag-view-node-mode'.
Users can rebind keys in this map to avoid conflicts with modal editing.")

(define-derived-mode supertag-view-node-mode special-mode "Supertag Node"
  "A modern major mode for viewing a Supertag node.

\{supertag-view-node-mode-map}

Key Bindings:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🧭 Navigation:
  j/k     - Move up/down by line (also n/p)
  SPC     - Scroll down one page
  S-SPC   - Scroll up one page (also M-v)
  C-v     - Scroll down one page
  M-<     - Jump to beginning of buffer
  M->     - Jump to end of buffer

🔧 Actions:
  g       - Refresh the view
  h       - Show this help (describe-mode)
  q       - Quit and close window

💡 Tips:
  - Node View shows only discovered context (Tags, Relations, References,
    Unlinked mentions, Similar notes); edit Org properties in the source file
  - RET on a Reference or Backlink title opens its source node
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

;; Shared line highlighting is owned by supertag-view-framework.el
;; Keeping these as convenience aliases for backward compatibility
(defun supertag-view-node--highlight-current-line ()
  "Highlight the current line for better visibility."
  (supertag-view-helper-highlight-current-line))

(defun supertag-view-node--unhighlight-all-lines ()
  "Remove all line highlighting."
  (supertag-view-helper-unhighlight-all-lines))

(defun supertag-view-node--get-references (node-id)
  "Get references from NODE-ID to other nodes."
  (when node-id
    (let ((relations (supertag-query-ordinary-references-from node-id)))
      (mapcar (lambda (rel) (plist-get rel :to)) relations))))

(defun supertag-view-node--get-referenced-by (node-id)
  "Get nodes that reference NODE-ID."
  (when node-id
    (mapcar (lambda (relation) (plist-get relation :from))
            (supertag-query-ordinary-references-to node-id))))

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

(defun supertag-view-node--insert-simple-header (state)
  "Insert a simple, clean header from Node view STATE."
  (let* ((node-data (plist-get state :node))
         (raw-title (or (plist-get node-data :title) "Untitled Node"))
         (title (supertag-view-node--strip-todo-keyword raw-title))
         (file (plist-get node-data :file))
         (node-id supertag-view-node--current-node-id)
         (ref-count (or (plist-get state :ref-count) 0))
         (stats (format "🔗 %d refs" ref-count))
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
Prefer the canonical hierarchy display name, then the stored `:name', and fall back
to TAG-ID itself only when no Tag record is available."
  (let ((tag-data (supertag-tag-get tag-id)))
    (or (and tag-data
             (let ((name (ignore-errors (supertag-tag-display-name tag-id))))
               (and (stringp name) (not (string-empty-p name)) name)))
        (and tag-data (plist-get tag-data :name))
        tag-id)))

(defun supertag-view-node--insert-tags-section (state)
  "Insert read-only tags from STATE."
  (supertag-view-helper-insert-section-title "Tags" "🏷️")
  (if-let ((tag-ids (plist-get state :tags)))
      (dolist (tag-id (sort (copy-sequence tag-ids) #'string<))
        (insert (propertize (format "  %s\n"
                                    (supertag-view-node--tag-display-name tag-id))
                            'supertag-context t
                            'type :tag
                            'tag-id tag-id
                            'id tag-id)))
    (supertag-view-helper-insert-simple-empty-state "No tags found."))
  (insert "\n"))

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


(defun supertag-view-node--insert-named-links-section (node-id)
  "Insert configured text-link relations touching NODE-ID."
  (let ((outgoing (supertag-query-named-links-from node-id))
        (incoming (supertag-query-named-links-to node-id)))
    (when (or outgoing incoming)
      (supertag-view-helper-insert-section-title "Relations" "🔗")
      (dolist (relation outgoing)
        (insert (format "  %s →\n" (plist-get relation :relation-name)))
        (supertag-view-node--insert-node-link-line (plist-get relation :to)))
      (dolist (relation incoming)
        (insert (format "  ← %s\n" (plist-get relation :relation-name)))
        (supertag-view-node--insert-node-link-line (plist-get relation :from)))
      (insert "\n"))))

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
      (supertag-view-node--insert-simple-header state)

      ;; Tags section
      (supertag-view-node--insert-tags-section state)

      ;; Contextual outgoing references and incoming Backlinks.  This remains
      ;; a disposable projection, never a second reference store.
      (supertag-view-reference-insert-sections node-id)

      (supertag-ai-insert-section node-id)

      ;; Potential references discovered from source-owned plain text.
      ;; These are computed candidates, never persisted facts.
      (when (supertag-concept-node-p node-data)
        (supertag-view-mention-insert-section node-id))
      (supertag-semantic-insert-section node-id)
      (insert "\n")

      (supertag-view-node--insert-named-links-section node-id)

      ;; Complete footer with available shortcuts
      (supertag-view-helper-insert-simple-footer
       "📍 Navigation: [j/k] Move | [SPC] Page Down | [S-SPC] Page Up | [M-</>] Start/End"
       "🔧 Actions: [g] Refresh | [h] Help | [q] Quit")

      ;; Activate links in the entire buffer
      (supertag-view-node--activate-links-in-buffer))
    (goto-char (point-min))))

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
            :id (get-text-property pos 'id)))))

(defun supertag-view-node--focus-view ()
  "Focus the side-window buffer if visible."
  (when-let* ((buf (supertag-view-node--buffer))
              (win (get-buffer-window buf)))
    (select-window win)
    (when (featurep 'evil)
      (when (fboundp 'evil-local-mode) (ignore-errors (evil-local-mode -1)))
      (when (fboundp 'evil-emacs-state) (ignore-errors (evil-emacs-state))))))

(defun supertag-view-node--refresh-view ()
  "Refresh Runtime-owned side-window content and preserve selection."
  (when-let* ((buf (supertag-view-node--buffer)))
    (with-current-buffer buf
      (unless supertag-view--instance
        (user-error "Node View is not Runtime-managed; reopen it before refreshing"))
      (if (and supertag-view-node--current-node-id
               (not (supertag-node-get supertag-view-node--current-node-id)))
          (let ((inhibit-read-only t))
            (erase-buffer)
            (supertag-view-helper-insert-simple-header
             "Node View" "The node is not available in this vault.")
            (supertag-view-helper-insert-simple-empty-state
             (format "Node %s is not available in this vault."
                     supertag-view-node--current-node-id)))
        (supertag-view-refresh buf)))))


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
  "Open Node View for NODE-ID and focus the window."
  (unless (and (stringp node-id) (not (string-empty-p node-id)))
    (user-error "Node View requires a node ID"))
  (supertag-view-node--show-side node-id)
  (supertag-view-node--focus-view)
  (when-let* ((buffer (supertag-view-node--buffer)))
    (with-current-buffer buffer
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

;; When user switches focus into the Node View window, reset point to the
;; top when it is not already on a discovered context row.
(defun supertag-view-node--on-window-selection-change (_frame)
  "When Node View becomes selected, retain or reset the context selection."
  (when-let* ((win (selected-window))
              (buf (and (window-live-p win) (window-buffer win))))
    (with-current-buffer buf
      (when (and (derived-mode-p 'supertag-view-node-mode)
                 (not (get-text-property (point) 'supertag-context)))
        (goto-char (point-min))))))

;; Register the hook if available (Emacs 27+)
(when (boundp 'window-selection-change-functions)
  (add-hook 'window-selection-change-functions #'supertag-view-node--on-window-selection-change))

;;; supertag-view-node.el ends here
