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

(defvar-local supertag-view-node--current-file nil
  "Source filename of the currently rendered state.")

(defvar-local supertag-view-node--current-title nil
  "The title currently displayed in the Node View.")

(defvar-local supertag-view-node--rendered-width nil
  "Pane width the current Node View text was laid out for.")

(defvar supertag-view-node--resize-timer nil
  "Debounce timer for re-rendering Node View after a pane resize.")

(defconst supertag-view-node--section-entry-limit 8
  "Entries shown before a section collapses the rest behind `+ N more'.")

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

(defcustom supertag-view-node-follow-idle-delay 0.08
  "Idle seconds before Node View follows point into another node.
Deferring the render keeps heading-to-heading cursor motion responsive."
  :type 'number
  :group 'supertag)

(defvar-local supertag-view-node--follow-timer nil
  "Pending idle timer for following point in the current buffer.")

(defun supertag-view-node--cancel-follow-timer ()
  "Cancel this buffer's pending Node View follow operation."
  (when supertag-view-node--follow-timer
    (cancel-timer supertag-view-node--follow-timer)
    (setq supertag-view-node--follow-timer nil)))

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
  (setq-local supertag-view-helper-width-override
              (or (when-let* ((window (supertag-view-node--live-window)))
                    (window-body-width window))
                  (supertag-view-node--estimated-width)))
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
                (supertag-view-node--cancel-follow-timer)
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

(defun supertag-view-node--follow-at-idle (origin)
  "Make Node View follow point in ORIGIN after cursor motion settles."
  (when (buffer-live-p origin)
    (with-current-buffer origin
      (setq supertag-view-node--follow-timer nil)
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
                  (supertag-view-node--show-side eid))))))))))

(defun supertag-view-node--post-command ()
  "Schedule an idle Node View follow check after cursor motion."
  (when (or supertag-view-node--enabled supertag-view-node-auto-show)
    (supertag-view-node--cancel-follow-timer)
    (setq supertag-view-node--follow-timer
          (run-with-idle-timer
           supertag-view-node-follow-idle-delay nil
           #'supertag-view-node--follow-at-idle
           (current-buffer)))))

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
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (supertag-view-node--cancel-follow-timer)))
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

(defcustom supertag-view-node-palette 'paper
  "Palette applied buffer-locally in the Node View."
  :type '(choice (const paper) (const neon) (const ink) (const ocean))
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
    (define-key map (kbd "TAB") #'supertag-view-node-next-button-or-fold)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "g") #'supertag-view-node-refresh)
    (define-key map (kbd "q") #'supertag-view-node--hide-side)
    (define-key map (kbd "h") #'describe-mode)
    map)
  "Keymap for `supertag-view-node-mode'.")

(define-derived-mode supertag-view-node-mode special-mode "Supertag Node"
  "Read-only magazine layout for one Supertag node.

\{supertag-view-node-mode-map}

TAB folds a chip or advances to a button; S-TAB goes back.
g refreshes, h describes this mode, and q closes the Node View.
RET and mouse-1 visit entry targets."
  :group 'supertag
  :keymap supertag-view-node-mode-map
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local word-wrap nil)
  (supertag-view-apply-palette-locally supertag-view-node-palette)
  (when (fboundp 'meow-mode) (meow-mode -1))
  (when (fboundp 'evil-local-mode) (evil-local-mode -1))
  (setq-local cursor-type 'box)
  (setq-local line-spacing 0.1)
  (setq-local mode-line-format
              '(" " (:eval (or supertag-view-node--current-title "Node"))
                "   palette: " (:eval (symbol-name supertag-view-node-palette)))))

(supertag-view-register-modal-state 'supertag-view-node-mode)

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
  "Insert the classic masthead: tag chips, file name and date."
  (let* ((node (plist-get state :node))
         (tags (sort (copy-sequence (or (plist-get state :tags) '())) #'string<))
         (file (plist-get node :file))
         (date (supertag-view-node--stored-date node))
         (chips (mapconcat
                 (lambda (tag-id)
                   (concat (propertize
                            (format " %s "
                                    (upcase (replace-regexp-in-string
                                             " *[›/] *" " / "
                                             (supertag-view-node--tag-display-name tag-id))))
                            'face 'supertag-view-chip1
                            'supertag-context t 'type :tag 'tag-id tag-id 'id tag-id)
                           " "))
                 tags
                 ""))
         (prefix (concat chips (if tags " " "")))
         (display-name (supertag-view-helper-file-display-name file))
         (file-part (and display-name (propertize display-name
                                                  'face 'supertag-view-accent)))
         (date-part (and date (propertize (format "  /  %s" date)
                                          'face 'supertag-view-mute)))
         (limit (max 8 (1- (supertag-view-helper-display-capacity))))
         (room (- limit
                  (supertag-view-helper-display-cost prefix)
                  (supertag-view-helper-display-cost (or date-part ""))))
         (line (concat prefix
                       (when file-part
                         (if (> (supertag-view-helper-display-cost file-part) room)
                             (supertag-view-helper-clip file-part (max 1 room))
                           file-part))
                       date-part)))
    ;; Keep the classic line inside the pane; the date survives longest.
    (when (> (supertag-view-helper-display-cost line) limit)
      (setq line (supertag-view-helper-clip line limit)))
    (insert "\n" line "\n\n")))

(defun supertag-view-node--wrap-title (title capacity)
  "Return TITLE split into lines that fit CAPACITY display units.
At least one line is returned and no text is ever dropped."
  (let ((words (split-string (string-trim title) "[[:space:]\n]+"))
        (lines nil)
        (current ""))
    (dolist (word words)
      (let ((candidate (if (string-empty-p current) word (concat current " " word))))
        (if (<= (supertag-view-helper-display-cost candidate) capacity)
            (setq current candidate)
          (unless (string-empty-p current)
            (push current lines))
          (setq current "")
          ;; A single word wider than the pane is split, never truncated.
          (dolist (char (string-to-list word))
            (let ((piece (concat current (char-to-string char))))
              (if (or (string-empty-p current)
                      (<= (supertag-view-helper-display-cost piece) capacity))
                  (setq current piece)
                (push current lines)
                (setq current (char-to-string char))))))))
    (unless (string-empty-p current)
      (push current lines))
    (nreverse (or lines (list "")))))

(defun supertag-view-node--insert-panel (state)
  "Insert STATE's full title on the panel, wrapped but never truncated."
  (let* ((node (plist-get state :node))
         (title (supertag-view-node--strip-todo-keyword
                 (or (plist-get node :title) "Untitled Node")))
         (capacity (max 8 (- (supertag-view-helper-display-capacity)
                             (supertag-view-helper-display-cost "  ")
                             1)))
         (start (point)))
    (setq supertag-view-node--current-title title)
    (insert "\n")
    (dolist (line (if (<= (supertag-view-helper-display-cost title) capacity)
                      (list title)
                    (supertag-view-node--wrap-title title capacity)))
      (insert "  " (propertize line 'face 'supertag-view-title) "\n"))
    (insert "\n")
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
    (insert "\n\n")))

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

(defun supertag-view-node--visible-char-before (position)
  "Return the last visible character before POSITION, or nil."
  (let ((index (1- position))
        result)
    (while (and (>= index (point-min)) (not result))
      (if (invisible-p index)
          (setq index (1- index))
        (setq result (char-after index))))
    result))

(defun supertag-view-node--insert-footer (node-id)
  "Insert NODE-ID's bounded magazine colophon."
  (let* ((file (file-name-nondirectory (or supertag-view-node--current-file "")))
         (width (supertag-view-helper-width))
         (prefix (upcase (substring (or node-id "") 0 (min 8 (length (or node-id "")))))))
    (let* ((end (point)))
      (skip-chars-backward "\n")
      (delete-region (point) end))
    (insert (if (eq (supertag-view-node--visible-char-before (point)) ?\n)
                "\n"
              "\n\n")
            (propertize "+ . + . + ." 'face 'supertag-view-rule
                        'supertag-view-colophon t) "\n"
            (propertize
             (supertag-view-helper-clip
              (concat "01 / NODE  "
                      (truncate-string-to-width file (max 1 (- width 17 (length prefix)))
                                                nil nil "…")
                      "  ·  " prefix))
             'face 'supertag-view-mute)
            "\n" (propertize "SUPERTAG / NODE" 'face 'supertag-view-mute) "\n")))

(defun supertag-view-node--insert-field-section (renderer node-id)
  "Insert RENDERER's output for NODE-ID, bounding entry rows.
Adapt feature-owned renderers locally without changing their interfaces."
  (let ((start (point)))
    (funcall renderer node-id)
    (if (string-empty-p (string-trim (buffer-substring-no-properties start (point))))
        (delete-region start (point))
      (save-excursion
        (goto-char start)
        (while (< (point) (point-max))
          (let* ((begin (line-beginning-position))
                 (end (line-end-position))
                 (entry (text-property-any begin end 'face 'supertag-view-entry)))
            (when entry
              ;; Feature renderers own the buttons; retain their action and
              ;; context properties while displaying Org link descriptions.
              (let* ((button (button-at entry))
                     (finish (if button (button-end button) end))
                     (properties (text-properties-at entry))
                     (title (org-link-display-format
                             (buffer-substring-no-properties entry finish))))
                (goto-char entry)
                (delete-region entry finish)
                (insert (apply #'propertize title properties)))
              (goto-char begin)
              (when (looking-at "  ")
                (delete-char 2)
                (insert "→ ")))
            (goto-char begin)
            (let ((line (buffer-substring begin (line-end-position))))
              (unless (<= (supertag-view-helper-display-cost line)
                          (1- (supertag-view-helper-display-capacity)))
                (delete-region begin (line-end-position))
                (insert (supertag-view-helper-clip line))))
            (forward-line 1)))))))

(defun supertag-view-node--space-sections ()
  "Put one blank line between each section band and its first entry."
  (save-excursion
    (goto-char (point-min))
    (while (< (point) (point-max))
      (when (get-text-property (point) 'supertag-view-section)
        (let ((next (save-excursion (forward-line 1) (point))))
          (when (and (< next (point-max))
                     (not (eq (char-after next) ?\n)))
            (goto-char next)
            (insert "\n"))))
      (forward-line 1))))

(defun supertag-view-node--section-spans ()
  "Return one (CONTENT-START . CONTENT-END) span per section band."
  (let (bands)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (when (get-text-property (point) 'supertag-view-section)
          (push (line-beginning-position) bands))
        (forward-line 1)))
    (let ((bands (nreverse bands)))
      (cl-loop for band in bands
               for next in (append (cdr bands) (list (point-max)))
               collect (cons (save-excursion
                               (goto-char band)
                               (forward-line 1)
                               (point))
                             next)))))

(defun supertag-view-node--cap-section (start end)
  "Hide entries past the limit in [START,END) behind a `+ N more' button."
  (let (entries)
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (when (text-property-any (line-beginning-position)
                                 (min (line-end-position) end)
                                 'face 'supertag-view-entry)
          (push (line-beginning-position) entries))
        (forward-line 1)))
    (setq entries (nreverse entries))
    (let ((hidden-count (- (length entries) supertag-view-node--section-entry-limit)))
      (when (> hidden-count 0)
        (goto-char (nth supertag-view-node--section-entry-limit entries))
        (let* (;; Keep the blank line in front of the next section band, so a
               ;; capped section still shows one empty line after `+ N more'.
               (end-marker (copy-marker
                            (if (and (> end (point-min))
                                     (eq (char-before end) ?\n))
                                (1- end)
                              end)))
               (from (copy-marker (point)))
               (button (insert-text-button
                        (format "+ %d more" hidden-count)
                        'face 'supertag-view-mute
                        'follow-link t
                        'help-echo (format "Expand %d more entries" hidden-count)))
               (to (progn (insert "\n") (copy-marker (point))))
               (overlay (make-overlay to end-marker)))
          (overlay-put overlay 'supertag-view-node-overflow t)
          (overlay-put overlay 'invisible t)
          (overlay-put overlay 'evaporate t)
          (button-put button 'action
                      (lambda (_button)
                        (let ((inhibit-read-only t))
                          (delete-overlay overlay)
                          (delete-region from to)))))))))

(defun supertag-view-node--cap-sections ()
  "Cap every section at the entry limit with an expandable `+ N more' line."
  (save-excursion
    (dolist (span (reverse (supertag-view-node--section-spans)))
      (supertag-view-node--cap-section (car span) (cdr span)))))

(defun supertag-view-node--next-section-start (from)
  "Return the next section-chip position after FROM, or `point-max'."
  (let ((position from) next)
    (while (and (< position (point-max)) (not next))
      (setq position (next-single-property-change position 'supertag-view-section nil (point-max)))
      (when (and (< position (point-max))
                 (get-text-property position 'supertag-view-section))
        (setq next position)))
    (or next
        (text-property-any from (point-max) 'supertag-view-colophon t)
        (point-max))))

(defun supertag-view-node-next-button-or-fold ()
  "Fold on a section chip; otherwise move to the next button."
  (interactive)
  (if (get-text-property (line-beginning-position) 'supertag-view-section)
      (supertag-view-node-toggle-section)
    (forward-button 1 t t)))

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
    (setq supertag-view-node--current-node-id node-id
          supertag-view-node--current-file (plist-get node-data :file))
    (setq-local line-spacing 0.1)
    (when node-data
      (supertag-view-node--insert-masthead state)
      (supertag-view-node--insert-panel state)
      (supertag-view-node--insert-actions state)
      (supertag-view-node--insert-field-section #'supertag-view-reference-insert-sections node-id)
      (supertag-view-node--insert-field-section #'supertag-ai-insert-section node-id)
      (when (supertag-concept-node-p node-data)
        (supertag-view-node--insert-field-section #'supertag-view-mention-insert-section node-id))
      (supertag-view-node--insert-field-section #'supertag-semantic-insert-section node-id)
      (supertag-view-node--insert-field-section #'supertag-view-node--insert-named-links-section node-id)
      (supertag-view-node--space-sections)
      (supertag-view-node--cap-sections)
      (supertag-view-node--insert-footer node-id)
      (supertag-view-node--activate-links-in-buffer))
    (setq-local supertag-view-node--rendered-width (supertag-view-helper-width))
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
                               face supertag-view-entry
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

;;; --- Pane Resize ---

(defun supertag-view-node--estimated-width ()
  "Return the pane width the configured Node View side window requests."
  (let ((frame-width (max 1 (frame-width))))
    (if (memq supertag-view-node-side '(left right))
        (let ((fraction (if (floatp supertag-view-node-side-size)
                            supertag-view-node-side-size
                          (/ (float (or supertag-view-node-side-size 0))
                             frame-width))))
          (max 12 (round (* frame-width (min 0.9 (max 0.1 fraction))))))
      (max 12 frame-width))))

(defun supertag-view-node--live-window ()
  "Return a live window showing the current buffer, if any."
  (let ((window (get-buffer-window (current-buffer) t)))
    (and (window-live-p window) window)))

(defun supertag-view-node--rerender-on-resize (buffer)
  "Refresh Node View BUFFER when its pane still exists."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (derived-mode-p 'supertag-view-node-mode)
                 supertag-view--instance
                 (supertag-view-node--live-window))
        (supertag-view-refresh buffer)))))

(defun supertag-view-node--schedule-rerender (buffer)
  "Debounce a resize refresh of Node View BUFFER."
  (when (timerp supertag-view-node--resize-timer)
    (cancel-timer supertag-view-node--resize-timer))
  (setq supertag-view-node--resize-timer
        (run-with-timer 0.1 nil #'supertag-view-node--rerender-on-resize buffer)))

(defun supertag-view-node--on-window-resize (&rest _)
  "Re-render Node View when its pane width no longer matches the render."
  (when-let* ((buffer (supertag-view-node--buffer)))
    (with-current-buffer buffer
      (when-let* ((window (supertag-view-node--live-window)))
        (unless (equal (window-body-width window)
                       supertag-view-node--rendered-width)
          (supertag-view-node--schedule-rerender buffer))))))

(add-hook 'window-size-change-functions #'supertag-view-node--on-window-resize)
(add-hook 'window-configuration-change-hook #'supertag-view-node--on-window-resize)

;;; supertag-view-node.el ends here
