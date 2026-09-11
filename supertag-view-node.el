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
(require 'wid-edit)
(autoload 'supertag-view-stream "supertag-view-stream")
(declare-function supertag-view-stream "supertag-view-stream" (&optional tag))
(autoload 'supertag-view-tags "supertag-view-tags")
(declare-function supertag-view-tags "supertag-view-tags" ())
(declare-function supertag-view--resolve-node-tags "supertag-tag" (node-id))

;;; --- Variables ---

(defvar-local supertag-view-node--current-node-id nil
  "The ID of the node currently displayed in the view buffer.")

(defvar-local supertag-view-node--current-title nil
  "The title currently displayed in the Node View.")

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

;;; --- Mode Definition ---

(defvar supertag-view-node-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "SPC") #'scroll-up-command)
    (define-key map (kbd "S-SPC") #'scroll-down-command)
    (define-key map (kbd "M-v") #'scroll-down-command)
    (define-key map (kbd "C-v") #'scroll-up-command)
    (define-key map (kbd "M-<") #'beginning-of-buffer)
    (define-key map (kbd "M->") #'end-of-buffer)
    (define-key map (kbd "TAB") #'supertag-view-node-toggle-section)
    (define-key map (kbd "g") #'supertag-view-node-refresh)
    (define-key map (kbd "q") #'supertag-view-node--hide-side)
    (define-key map (kbd "h") #'describe-mode)
    map)
  "Keymap for `supertag-view-node-mode'.")

(define-derived-mode supertag-view-node-mode special-mode "Supertag Node"
  "Read-only magazine layout for one Supertag node.

\{supertag-view-node-mode-map}

TAB folds the section at point.  g refreshes, h describes this mode, and q
closes the Node View.  RET and mouse-1 visit entry targets."
  :group 'supertag
  :keymap supertag-view-node-mode-map
  (setq-local buffer-read-only t)
  (setq-local cursor-type 'box)
  (setq-local line-spacing 0.1)
  (setq-local mode-line-format
              '(" " (:eval (or supertag-view-node--current-title "Node"))
                "   palette: " (:eval (symbol-name supertag-view-palette))))
  (when (fboundp 'evil-local-mode)
    (ignore-errors (evil-local-mode -1))))

;;; --- Rendering helpers ---

(defun supertag-view-node--get-references (node-id)
  "Return ordinary reference targets from NODE-ID."
  (when node-id
    (mapcar (lambda (relation) (plist-get relation :to))
            (supertag-query-ordinary-references-from node-id))))

(defun supertag-view-node--get-referenced-by (node-id)
  "Return ordinary reference sources that point to NODE-ID."
  (when node-id
    (mapcar (lambda (relation) (plist-get relation :from))
            (supertag-query-ordinary-references-to node-id))))

(defun supertag-view-node--strip-todo-keyword (title)
  "Remove configured TODO keywords from TITLE when requested."
  (if (not supertag-view-node-strip-todo-keywords)
      title
    (let ((keywords-regexp (concat "^\\("
                                   (mapconcat #'regexp-quote
                                              supertag-view-node-todo-keywords "\\|")
                                   "\\)\\s-+")))
      (if (string-match keywords-regexp title)
          (string-trim (substring title (match-end 0)))
        title))))

(defun supertag-view-node--tag-display-name (tag-id)
  "Return a human-readable display name for TAG-ID."
  (let ((tag-data (supertag-tag-get tag-id)))
    (or (and tag-data
             (let ((name (ignore-errors (supertag-tag-display-name tag-id))))
               (and (stringp name) (not (string-empty-p name)) name)))
        (and tag-data (plist-get tag-data :name)) tag-id)))

(defun supertag-view-node--stored-date (node)
  "Return NODE's stored creation or modification date, or nil."
  (when-let ((timestamp (or (plist-get node :created-at)
                            (plist-get node :modified-at))))
    (condition-case nil
        (format-time-string "%Y-%m-%d" timestamp)
      (error nil))))

(defun supertag-view-node--insert-masthead (state)
  "Insert the masthead from Node view STATE."
  (let* ((node (plist-get state :node))
         (tags (sort (copy-sequence (or (plist-get state :tags) '())) #'string<))
         (file (plist-get node :file))
         (date (supertag-view-node--stored-date node)))
    (insert "\n")
    (dolist (tag-id tags)
      (insert (propertize (format " %s " (upcase (supertag-view-node--tag-display-name tag-id)))
                          'face 'supertag-view-chip1
                          'supertag-context t 'type :tag 'tag-id tag-id 'id tag-id)
              " "))
    (when tags (insert " "))
    (when file
      (insert (propertize (file-name-nondirectory file) 'face 'supertag-view-accent)))
    (when date
      (insert (propertize (format "  /  %s" date) 'face 'supertag-view-mute)))
    (insert "\n\n")))

(defun supertag-view-node--insert-panel (state)
  "Insert STATE's title in a panel."
  (let* ((node (plist-get state :node))
         (title (supertag-view-node--strip-todo-keyword
                 (or (plist-get node :title) "Untitled Node")))
         (start (point)))
    (setq supertag-view-node--current-title title)
    (insert "\n  " (propertize title 'face 'supertag-view-title) "\n\n")
    (add-face-text-property start (point) 'supertag-view-panel t)))

(defun supertag-view-node--action-open (button)
  "Open the node stored on BUTTON."
  (supertag-goto-node (button-get button 'supertag-node-id)))

(defun supertag-view-node--action-stream (button)
  "Open a stream for BUTTON's first node tag, if it has one."
  (let ((tag (car (button-get button 'supertag-node-tags))))
    (if tag (supertag-view-stream tag) (supertag-view-stream))))

(defun supertag-view-node--action-tags (_button)
  "Open the tag manager."
  (supertag-view-tags))

(defun supertag-view-node--insert-actions (state)
  "Insert the action row for STATE."
  (let ((node-id (plist-get state :id)) (tags (plist-get state :tags)))
    (insert "\n")
    (insert-text-button "[OPEN]" 'face 'widget-button 'follow-link t
                        'action #'supertag-view-node--action-open
                        'supertag-node-id node-id)
    (insert "  ")
    (insert-text-button "[STREAM]" 'face 'widget-button 'follow-link t
                        'action #'supertag-view-node--action-stream
                        'supertag-node-tags tags)
    (insert "  ")
    (insert-text-button "[TAG MANAGER]" 'face 'widget-button 'follow-link t
                        'action #'supertag-view-node--action-tags)
    (insert "\n")))

(defun supertag-view-node--insert-node-link-line (node-id &optional relation)
  "Insert a clickable relation entry for NODE-ID and optional RELATION."
  (when-let* ((node (supertag-view-api-get-entity :nodes node-id)))
    (let* ((raw-title (or (plist-get node :raw-value) (plist-get node :title) "[Untitled]"))
           (title (if (fboundp 'org-link-display-format)
                      (org-link-display-format raw-title) raw-title))
           (start (point)))
      (insert "  ")
      (insert-text-button (string-trim title) 'face 'supertag-view-entry 'follow-link t
                          'action (lambda (&optional _button)
                                    (interactive)
                                    (supertag-goto-node node-id))
                          'supertag-node-id node-id
                          'help-echo (format "Jump to node: %s" node-id))
      (insert "\n")
      (supertag-view-helper-insert-excerpt relation)
      (add-text-properties start (point) '(line-spacing 0.15)))))

(defun supertag-view-node--insert-named-links-section (node-id)
  "Insert configured text-link relations touching NODE-ID."
  (let ((outgoing (supertag-query-named-links-from node-id))
        (incoming (supertag-query-named-links-to node-id)))
    (when (or outgoing incoming)
      (insert "\n")
      (supertag-view-helper-insert-section-chip "Relations" (+ (length outgoing) (length incoming))
                                                   'supertag-view-chip2)
      (dolist (relation outgoing)
        (supertag-view-node--insert-node-link-line
         (plist-get relation :to) (format "%s →" (plist-get relation :relation-name))))
      (dolist (relation incoming)
        (supertag-view-node--insert-node-link-line
         (plist-get relation :from) (format "← %s" (plist-get relation :relation-name)))))))

(defun supertag-view-node--insert-footer (node-id)
  "Insert NODE-ID's magazine footer."
  (insert "\n"
          (propertize (string-join (make-list 11 "+ .") " ") 'face 'supertag-view-rule)
          "\n"
          (propertize (format "SUPERTAG / NODE  /  %s"
                              (upcase (substring (or node-id "") 0 (min 8 (length (or node-id ""))))))
                      'face 'supertag-view-mute)
          "\n"))

(defun supertag-view-node--next-section-start (from)
  "Return the next section-chip position after FROM, or `point-max'."
  (let ((position from) next)
    (while (and (< position (point-max)) (not next))
      (setq position (next-single-property-change position 'supertag-view-section nil (point-max)))
      (when (and (< position (point-max))
                 (get-text-property position 'supertag-view-section))
        (setq next position)))
    (or next (point-max))))

(defun supertag-view-node-toggle-section ()
  "Fold or unfold the section whose chip is at point."
  (interactive)
  (save-excursion
    (unless (get-text-property (line-beginning-position) 'supertag-view-section)
      (let ((previous (previous-single-property-change (point) 'supertag-view-section)))
        (when (and previous (get-text-property (1- previous) 'supertag-view-section))
          (goto-char (1- previous)))))
    (when (get-text-property (line-beginning-position) 'supertag-view-section)
      (let* ((start (line-end-position))
             (next (supertag-view-node--next-section-start (1+ start)))
             (end (save-excursion (goto-char next) (line-beginning-position)))
             (overlay (seq-find (lambda (item) (overlay-get item 'supertag-view-node-fold))
                                (overlays-in start end))))
        (if overlay
            (delete-overlay overlay)
          (let ((fold (make-overlay start end)))
            (overlay-put fold 'supertag-view-node-fold t)
            (overlay-put fold 'invisible t)
            (overlay-put fold 'after-string
                         (propertize "  …" 'face 'supertag-view-mute))))))))

(defun supertag-view-node--render-from-state (state)
  "Render the magazine Node View from data-only STATE."
  (let* ((node-id (plist-get state :id))
         (node-data (plist-get state :node))
         (inhibit-read-only t))
    (erase-buffer)
    (setq supertag-view-node--current-node-id node-id)
    (setq-local line-spacing 0.1)
    (when node-data
      (supertag-view-node--insert-masthead state)
      (supertag-view-node--insert-panel state)
      (supertag-view-node--insert-actions state)
      (supertag-view-reference-insert-sections node-id)
      (supertag-ai-insert-section node-id)
      (when (supertag-concept-node-p node-data)
        (supertag-view-mention-insert-section node-id))
      (supertag-semantic-insert-section node-id)
      (supertag-view-node--insert-named-links-section node-id)
      (supertag-view-node--insert-footer node-id)
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
            (insert (propertize "Node View

" 'face 'supertag-view-title))
            (insert (propertize
                     (format "Node %s is not available in this vault.
"
                             supertag-view-node--current-node-id)
                     'face 'supertag-view-mute)))
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
