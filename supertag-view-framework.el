;;; supertag-view-framework.el --- Framework for creating custom views -*- lexical-binding: t; -*-

;;; Commentary:
;; Commands: supertag-view-refresh
;; Business Tag selection (supertag-view--read-tag) is owned by supertag-tag.
;; Dependencies: cl-lib, button, subr-x, org, widget, wid-edit, supertag-query, supertag-tag, supertag-services-sync
;; Node arrives through Tag; its cache listener is prepared after Sync loads.

;; This module provides a framework for developers to create custom views
;; of supertag data.  It is NOT an end-user configuration tool - it is
;; a toolbox for Elisp developers.
;;
;; Quick start - register a view:
;;
;;   (supertag-view-register
;;    :id 'my-view
;;    :name "My View"
;;    :state-fn #'identity
;;    :render-fn #'my-render-function)

;;; Code:

(require 'cl-lib)
(require 'button)
(require 'subr-x)
(require 'org)
(require 'widget)
(require 'wid-edit)
(require 'supertag-query)
(require 'supertag-tag)
(require 'supertag-services-sync)
(supertag-node--prepare-cache-listener)

;;; --- Shared View Drawing ---

(defun supertag-view-helper-insert-action-button (label action data help &optional prop)
  "Insert LABEL with ACTION, HELP and DATA stored under PROP."
  (insert-text-button label 'action action 'follow-link t
                      'help-echo help (or prop 'supertag-action) data))

(defconst supertag-view-helper--section-separator "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  "Separator line for sections.")

(defconst supertag-view-helper--subsection-separator "┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"
  "Separator line for subsections.")

(defun supertag-view-helper-insert-section-header (title icon)
  "Insert a section header with ICON and TITLE."
  (insert (propertize (format "%s %s\n" icon title) 'face '(:weight bold :height 1.2)))
  (insert (propertize (format "%s\n" supertag-view-helper--section-separator) 'face '(:foreground "gray50")))
  (insert "\n"))

(defun supertag-view-helper-insert-subsection-header (title)
  "Insert a subsection header with TITLE."
  (insert (propertize (format "  %s\n" title) 'face '(:weight bold)))
  (insert (propertize (format "  %s\n" supertag-view-helper--subsection-separator) 'face '(:foreground "gray70")))
  (insert "\n"))

;;; --- Theme Adaptive Colors ---

(defun supertag-view-helper-get-theme-adaptive-color (light-color dark-color)
  "Get color that adapts to current theme."
  (if (eq (frame-parameter nil 'background-mode) 'dark)
      dark-color
    light-color))

(defun supertag-view-helper-get-accent-color ()
  "Get accent color that works well in both light and dark themes."
  (supertag-view-helper-get-theme-adaptive-color "#0066CC" "#66B3FF"))

(defun supertag-view-helper-get-emphasis-color ()
  "Get emphasis color that works well in both light and dark themes."
  (supertag-view-helper-get-theme-adaptive-color "#003D82" "#99D6FF"))

(defun supertag-view-helper-get-muted-color ()
  "Get muted color that works well in both light and dark themes."
  (supertag-view-helper-get-theme-adaptive-color "#666666" "#AAAAAA"))

(defun supertag-view-helper-get-success-color ()
  "Get success color that works well in both light and dark themes."
  (supertag-view-helper-get-theme-adaptive-color "#22C55E" "#4ADE80"))

(defun supertag-view-helper-get-warning-color ()
  "Get warning color that works well in both light and dark themes."
  (supertag-view-helper-get-theme-adaptive-color "#F59E0B" "#FCD34D"))

(defun supertag-view-helper-get-error-color ()
  "Get error color that works well in both light and dark themes."
  (supertag-view-helper-get-theme-adaptive-color "#EF4444" "#F87171"))

(defun supertag-view-helper-get-background-color ()
  "Get background color that works well in both light and dark themes."
  (supertag-view-helper-get-theme-adaptive-color "#F8FAFC" "#1E293B"))

(defun supertag-view-helper-get-border-color ()
  "Get border color that works well in both light and dark themes."
  (supertag-view-helper-get-theme-adaptive-color "#E2E8F0" "#334155"))

;;; --- Value Formatting ---

(defun supertag-view-helper-format-value (value)
  "Format VALUE for display. Handles lists and nil."
  (let ((formatted-value (if (listp value)
                              (mapconcat #'identity value " / ")
                            (format "%s" (or value "")))))
    (if (string-empty-p formatted-value)
        (propertize "[Empty]" 'face `(:foreground ,(supertag-view-helper-get-muted-color) :slant italic))
      (supertag-view-helper-render-org-links formatted-value))))

(defun supertag-view-helper-render-org-links (text)
  "Return TEXT with Org-style links rendered as clickable buttons.
TEXT can be any value convertible to string."
  (let ((string (cond
                 ((null text) "")
                 ((stringp text) (substring-no-properties text))
                 (t (format "%s" text)))))
    (if (string-empty-p string)
        string
      (with-temp-buffer
        (insert string)
        (goto-char (point-min))
        (while (re-search-forward "\\[\\[\\([^]\n]+\\)\\]\\(\\[\\([^]]+\\)\\]\\)?\\]" nil t)
          (let* ((match-start (match-beginning 0))
                 (link (match-string 1))
                 (desc (or (match-string 3) (match-string 1)))
                 (link-target link)
                 (keymap (let ((map (make-sparse-keymap)))
                           (define-key map (kbd "RET")
                             (lambda ()
                               (interactive)
                               (org-link-open-from-string (format "[[%s]]" link-target))))
                           (define-key map [mouse-1]
                             (lambda ()
                               (interactive)
                               (org-link-open-from-string (format "[[%s]]" link-target))))
                           map)))
            (delete-region match-start (match-end 0))
            (goto-char match-start)
            (insert desc)
            (add-text-properties match-start (+ match-start (length desc))
                                 `(face org-link
                                        help-echo ,link
                                        mouse-face highlight
                                        keymap ,keymap))
            (goto-char (+ match-start (length desc)))))
        (buffer-substring (point-min) (point-max))))))



(defun supertag-view-helper-format-boolean-value (value)
  "Format boolean VALUE with visual indicators."
  (let ((bool-val (cond
                   ((or (eq value t) (string= value "true") (string= value "yes") (string= value "1")) t)
                   ((or (eq value nil) (string= value "false") (string= value "no") (string= value "0")) nil)
                   (t nil))))
    (if bool-val
        (propertize "✓ True" 'face `(:foreground ,(supertag-view-helper-get-success-color) :weight bold))
      (propertize "✗ False" 'face `(:foreground ,(supertag-view-helper-get-muted-color))))))

(defun supertag-view-helper-format-number-value (value)
  "Format numeric VALUE with proper styling."
  (if (or (null value) (string-empty-p (format "%s" value)))
      (propertize "[No value]" 'face `(:foreground ,(supertag-view-helper-get-muted-color) :slant italic))
    (propertize (format "%s" value) 'face `(:foreground ,(supertag-view-helper-get-accent-color) :weight bold))))

(defun supertag-view-helper-format-date-value (value)
  "Format date VALUE with calendar icon."
  (if (or (null value) (string-empty-p (format "%s" value)))
      (propertize "[No date]" 'face `(:foreground ,(supertag-view-helper-get-muted-color) :slant italic))
    (propertize (concat "📅 " (format "%s" value))
                'face `(:foreground ,(supertag-view-helper-get-accent-color)))))

(defun supertag-view-helper-format-url-value (value)
  "Format URL VALUE as clickable link."
  (if (or (null value) (string-empty-p (format "%s" value)))
      (propertize "[No URL]" 'face `(:foreground ,(supertag-view-helper-get-muted-color) :slant italic))
    (propertize (concat "🔗 " (format "%s" value))
                'face `(:foreground ,(supertag-view-helper-get-accent-color) :underline t)
                'mouse-face 'highlight
                'help-echo "Click to open URL")))


;;; --- Simple and Clean Components ---

(defun supertag-view-helper-insert-simple-header (title &optional stats)
  "Insert a simple header with TITLE and optional STATS."
  (insert (propertize title 'face `(:weight bold :height 1.3 :foreground ,(supertag-view-helper-get-emphasis-color))))
  (when stats
    (insert (propertize (format "    %s" stats)
                        'face `(:foreground ,(supertag-view-helper-get-muted-color)))))
  (insert "\n")
  (insert (propertize (make-string 60 ?─) 'face `(:foreground ,(supertag-view-helper-get-border-color))))
  (insert "\n\n"))

(defun supertag-view-helper-insert-section-title (title &optional icon)
  "Insert a simple section title with optional ICON."
  (insert (propertize (if icon (format "%s %s" icon title) title)
                      'face `(:weight bold :foreground ,(supertag-view-helper-get-emphasis-color))))
  (insert "\n"))


(defun supertag-view-helper-insert-simple-footer (&rest help-lines)
  "Insert a simple footer with essential HELP-LINES."
  (insert "\n")
  (insert (propertize (make-string 60 ?─) 'face `(:foreground ,(supertag-view-helper-get-border-color))))
  (insert "\n")
  (dolist (line help-lines)
    (insert (propertize (format "%s\n" line)
                        'face `(:foreground ,(supertag-view-helper-get-muted-color) :height 0.9)))))

(defun supertag-view-helper-insert-simple-empty-state (message)
  "Insert a simple empty state MESSAGE."
  (insert (propertize (format "  %s\n" message)
                      'face `(:foreground ,(supertag-view-helper-get-muted-color) :slant italic))))


;;; --- Card-like Components ---

(defun supertag-view-helper-insert-card-start (title &optional icon color)
  "Start a card-like container with TITLE, optional ICON and COLOR."
  (let ((card-color (or color (supertag-view-helper-get-border-color)))
        (title-with-icon (if icon (format "%s %s" icon title) title)))
    (insert (propertize (format "┌─ %s " title-with-icon)
                        'face `(:weight bold :foreground ,(supertag-view-helper-get-emphasis-color))))
    (insert (propertize (make-string (max 0 (- 60 (length title-with-icon) 3)) ?─)
                        'face `(:foreground ,card-color)))
    (insert (propertize "┐\n" 'face `(:foreground ,card-color)))))

(defun supertag-view-helper-insert-card-content (content &optional padding)
  "Insert CONTENT inside a card with optional PADDING."
  (let ((pad (or padding "│ "))
        (border-color (supertag-view-helper-get-border-color)))
    (dolist (line (split-string content "\n"))
      (insert (propertize pad 'face `(:foreground ,border-color)))
      (insert line "\n"))))

(defun supertag-view-helper-insert-card-end ()
  "End a card-like container."
  (let ((border-color (supertag-view-helper-get-border-color)))
    (insert (propertize "└" 'face `(:foreground ,border-color)))
    (insert (propertize (make-string 58 ?─) 'face `(:foreground ,border-color)))
    (insert (propertize "┘\n" 'face `(:foreground ,border-color)))))


(defun supertag-view-helper-insert-separator-line (&optional style)
  "Insert a separator line with optional STYLE (:thin, :thick, :dotted)."
  (let ((char (pcase style
                (:thin "─")
                (:thick "━")
                (:dotted "┄")
                (_ "─")))
        (border-color (supertag-view-helper-get-border-color)))
    (insert (propertize "│" 'face `(:foreground ,border-color)))
    (insert (propertize (make-string 58 (string-to-char char)) 'face `(:foreground ,border-color)))
    (insert (propertize "│\n" 'face `(:foreground ,border-color)))))

;;; --- Interactive Line Highlighting ---

(defun supertag-view-helper-highlight-current-line ()
  "Highlight the current line for better visibility."
  (let ((inhibit-read-only t))
    (remove-overlays (point-min) (point-max) 'category 'current-line)
    (let ((overlay (make-overlay (line-beginning-position) (1+ (line-end-position)))))
      (overlay-put overlay 'category 'current-line)
      (overlay-put overlay 'face `(:background ,(supertag-view-helper-get-theme-adaptive-color "#F1F5F9" "#334155")
                                   :extend t
                                   :box (:line-width 1 :color ,(supertag-view-helper-get-accent-color))))
      ;; Add subtle animation effect
      (overlay-put overlay 'priority 100))))

(defun supertag-view-helper-unhighlight-all-lines ()
  "Remove all line highlighting."
  (remove-overlays (point-min) (point-max) 'category 'current-line))

(defun supertag-view-helper-enable-line-highlighting ()
  "Enable enhanced line highlighting for the current buffer."
  ;; Line highlighting disabled to prevent visual flickering during cursor movement
  ;; (supertag-view-helper-unhighlight-all-lines)
  ;; (add-hook 'post-command-hook #'supertag-view-helper-highlight-current-line nil t)
  )

;;; --- Status and Statistics Display ---

(defun supertag-view-helper-insert-status-badge (status &optional label)
  "Insert a status badge with STATUS and optional LABEL."
  (let* ((badge-text (or label (format "%s" status)))
         (badge-face (pcase status
                       ('active `(:background ,(supertag-view-helper-get-success-color)
                                  :foreground "white" :weight bold :box 2))
                       ('warning `(:background ,(supertag-view-helper-get-warning-color)
                                   :foreground "black" :weight bold :box 2))
                       ('error `(:background ,(supertag-view-helper-get-error-color)
                                 :foreground "white" :weight bold :box 2))
                       ('inactive `(:background ,(supertag-view-helper-get-muted-color)
                                    :foreground "white" :weight bold :box 2))
                       (_ `(:background ,(supertag-view-helper-get-accent-color)
                           :foreground "white" :weight bold :box 2)))))
    (insert " ")
    (insert (propertize (format " %s " badge-text) 'face badge-face))
    (insert " ")))

(defun supertag-view-helper-insert-stats-summary (stats)
  "Insert a statistics summary from STATS plist."
  (let ((total (or (plist-get stats :total) 0))
        (active (or (plist-get stats :active) 0))
        (modified (or (plist-get stats :modified) 0)))
    (insert (propertize "\n📊 Statistics: " 'face `(:weight bold :foreground ,(supertag-view-helper-get-emphasis-color))))
    (insert (propertize (format "Total: %d" total) 'face `(:weight bold :foreground ,(supertag-view-helper-get-accent-color))))
    (insert (propertize " • " 'face `(:foreground ,(supertag-view-helper-get-muted-color))))
    (insert (propertize (format "Active: %d" active) 'face `(:weight bold :foreground ,(supertag-view-helper-get-success-color))))
    (when (> modified 0)
      (insert (propertize " • " 'face `(:foreground ,(supertag-view-helper-get-muted-color))))
      (insert (propertize (format "Modified: %d" modified) 'face `(:weight bold :foreground ,(supertag-view-helper-get-warning-color)))))
    (insert "\n\n")))

;;; --- Help Text and Empty State ---

(defun supertag-view-helper-insert-help-text (text)
  "Insert help TEXT with consistent styling."
  (insert (propertize (format "    %s\n" text)
                      'face `(:foreground ,(supertag-view-helper-get-muted-color) :height 0.9))))

(defun supertag-view-helper-insert-empty-state (message)
  "Insert empty state MESSAGE with consistent styling."
  (insert (propertize (format "  %s\n" message)
                      'face `(:foreground ,(supertag-view-helper-get-muted-color) :slant italic))))


;;; --- Node and File Information Display ---

(defun supertag-view-helper-insert-node-info (title file)
  "Insert node information with TITLE and FILE in consistent format."
  (insert (propertize (format "    📄 %s\n" title) 'face '(:weight bold :foreground "default")))
  (when file
    (insert (propertize (format "    📁 %s\n" (file-name-nondirectory file))
                        'face `(:foreground ,(supertag-view-helper-get-muted-color) :slant italic)))))

;;; --- Footer and Navigation ---

(defun supertag-view-helper-insert-footer-start ()
  "Insert footer separator and navigation title."
  (insert (propertize (format "%s\n" supertag-view-helper--section-separator) 'face `(:foreground ,(supertag-view-helper-get-muted-color))))
  (insert (propertize "Navigation:\n" 'face '(:weight bold :foreground "default"))))

(defun supertag-view-helper-insert-footer-with-content (&rest help-lines)
  "Insert complete footer with custom HELP-LINES."
  (supertag-view-helper-insert-footer-start)
  (dolist (line help-lines)
    (supertag-view-helper-insert-help-text line)))

;;;----------------------------------------------------------------------
;;; Display Buffer Management
;;;----------------------------------------------------------------------

(defun supertag-view-helper-display-buffer-right (buffer)
  "Display BUFFER in a window to the right."
  (let ((window (display-buffer buffer '(display-buffer-in-side-window
                                          (side . right)
                                          (window-width . 0.4)))))
    (select-window window)
    (goto-char (point-min))))

;;; --- View Data Access and Subscriptions ---

(defun supertag-view-api-node-base-field (node key)
  "Read KEY from NODE plist."
  (plist-get node key))

(defun supertag-view-api-subscribe (event fn)
  "Subscribe FN to EVENT and return an unsubscribe function.

EVENT is a keyword (e.g. :node-updated) or a store path list.
FN is called with arguments determined by the event publisher."
  (unless (functionp fn)
    (error "FN must be a function"))
  (supertag-subscribe event fn))

;; ============================================================================
;; Core Registry
;; ============================================================================

(defvar supertag--view-registry (make-hash-table :test 'eq)
  "Registry of all views.
Key is view ID (symbol), value is view definition plist.

View definition plist structure:
  :id           - Symbol identifier
  :name         - Display name (string)
  :description  - Optional description (string)
  :category     - Optional category (symbol)
  :render-fn    - Function to render the view (required)
  :valid-for    - List of tag names this view applies to, or nil for all
  :selectable   - Nil hides an internal Adapter from the custom-view picker
  :buffer-name / :buffer-name-fn - Runtime buffer naming
  :mode-fn      - Runtime major-mode installer
  :state-fn     - Build refreshable state from the original input
  :display-action - Native `display-buffer' action
  :subscribe-fn - Return cleanup callbacks for Runtime-owned resources
  :capture-selection-fn / :restore-selection-fn - Refresh position hooks")

(defvar-local supertag-view--instance nil
  "Buffer-local View Runtime instance plist.")

;; ============================================================================
;; Core API
;; ============================================================================



(defun supertag-view-register (&rest props)
  "Register a new view with properties PROPS.

Required properties:
  :id        - Symbol identifier (for example, `progress-dashboard')
  :name      - Display name string
  :render-fn - Function to render the view

Optional properties:
  :description - Description string
  :category    - Category symbol (e.g., :project-management)
  :valid-for   - List of tag names, or nil for all tags
  :selectable  - Nil to hide an internal Adapter from the view picker
  :buffer-name or :buffer-name-fn - Runtime buffer naming
  :mode-fn, :state-fn, :display-action, :subscribe-fn
  :capture-selection-fn, :restore-selection-fn

Example:
  (supertag-view-register
   :id (quote progress-dashboard)
   :name \"Progress Dashboard\"
   :description \"Show project progress overview\"
   :category :project-management
   :render-fn (function supertag-view--render-progress)
   :valid-for (list \"project\"))

Returns the view definition plist."
  (let* ((id (plist-get props :id))
         (name (plist-get props :name))
         (render-fn (plist-get props :render-fn)))
    ;; Validate required fields
    (unless id
      (error "View must have an :id"))
    (unless (symbolp id)
      (error "View :id must be a symbol, got: %s" (type-of id)))
    (unless name
      (error "View must have a :name"))
    (unless (stringp name)
      (error "View :name must be a string, got: %s" (type-of name)))
    (unless render-fn
      (error "View must have a :render-fn"))
    (unless (functionp render-fn)
      (error "View :render-fn must be a function, got: %s" (type-of render-fn)))
    ;; Store in registry
    (puthash id props supertag--view-registry)
    (message "Registered view '%s' (%s)" name id)
    props))

(defun supertag-view-unregister (id)
  "Unregister view with ID.
Returns the removed view definition, or nil if not found."
  (let ((view (gethash id supertag--view-registry)))
    (when view
      (remhash id supertag--view-registry)
      (message "Unregistered view '%s'" id)
      view)))

(defun supertag-view-get (id)
  "Get view definition by ID.
Returns the view plist, or nil if not found."
  (gethash id supertag--view-registry))

(defun supertag-view--cleanup-instance ()
  "Clean the current buffer's View Runtime instance."
  (when supertag-view--instance
    (let ((cleanup-fns (plist-get supertag-view--instance :cleanup-fns))
          first-error)
      (setq supertag-view--instance nil)
      (dolist (cleanup cleanup-fns)
        (condition-case err
            (funcall cleanup)
          (error
           (unless first-error
             (setq first-error err)))))
      (when first-error
        (message "View cleanup failed: %s"
                 (error-message-string first-error))))))

(defun supertag-view-open (id input &optional display-action)
  "Open registered view ID with INPUT through the View Runtime.
DISPLAY-ACTION overrides the view's registered display action."
  (let ((view (supertag-view-get id)))
    (unless view
      (user-error "Unknown view: %s" id))
    (let* ((state-fn (plist-get view :state-fn))
           (state (if state-fn (funcall state-fn input) input))
           (buffer-name-fn (plist-get view :buffer-name-fn))
           (buffer-name
            (cond
             (buffer-name-fn (funcall buffer-name-fn input))
             ((plist-get view :buffer-name))
             (t (format "*View: %s*" (plist-get view :name)))))
           (buffer (get-buffer-create buffer-name))
           (mode-fn (or (plist-get view :mode-fn) #'special-mode))
           (subscribe-fn (plist-get view :subscribe-fn)))
      (condition-case err
          (progn
            (with-current-buffer buffer
              (supertag-view--cleanup-instance)
              (funcall mode-fn)
              (add-hook 'kill-buffer-hook #'supertag-view--cleanup-instance nil t)
              (let ((inhibit-read-only t))
                (funcall (plist-get view :render-fn) state))
              (setq-local supertag-view--instance
                          (list :view-id id :input input :state state
                                :cleanup-fns nil))
              (when subscribe-fn
                (let ((cleanup
                       (funcall subscribe-fn input state
                                (lambda (&rest _event)
                                  (when (buffer-live-p buffer)
                                    (with-current-buffer buffer
                                      (supertag-view-refresh)))))))
                  (setf (plist-get supertag-view--instance :cleanup-fns)
                        (if (functionp cleanup) (list cleanup) cleanup)))))
            (display-buffer buffer (or display-action
                                       (plist-get view :display-action)))
            buffer)
        (error
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (supertag-view--cleanup-instance)))
         (signal (car err) (cdr err)))))))



(defun supertag-view--header (title)
  "Insert a header with TITLE."
  (insert (format "%s\n" title))
  (insert (make-string (length title) ?=))
  (insert "\n\n"))

(defun supertag-view--subheader (title)
  "Insert a subheader with TITLE."
  (insert (format "%s\n" title))
  (insert (make-string (length title) ?-))
  (insert "\n\n"))

(defun supertag-view--progress-bar (percentage &optional width)
  "Insert a text progress bar for PERCENTAGE (0-100).
WIDTH is the bar width in characters (default 20)."
  (let* ((w (or width 20))
         (filled (round (* w (/ percentage 100.0))))
         (empty (- w filled)))
    (insert "[")
    (insert (make-string filled ?█))
    (insert (make-string empty ?░))
    (insert (format "] %d%%\n" percentage))))

(defun supertag-view--stat-row (stats)
  "Insert a row of statistics.
STATS is a list of (label . value) pairs."
  (dolist (stat stats)
    (insert (format "  %s: %s\n" (car stat) (cdr stat))))
  (insert "\n"))

(defun supertag-view--separator (&optional char)
  "Insert a separator line using CHAR (default ?-)."
  (let ((c (or char ?-)))
    (insert (make-string (window-width) c))
    (insert "\n\n")))

;; ============================================================================
;; Data Access Utilities
;; ============================================================================

;; ============================================================================
;; Interactive Commands
;; ============================================================================


(defun supertag-view--refresh-instance ()
  "Refresh the current buffer's View Runtime instance."
  (let* ((view-id (plist-get supertag-view--instance :view-id))
         (view (supertag-view-get view-id)))
    (unless view
      (user-error "Unknown view: %s" view-id))
    (let* ((input (plist-get supertag-view--instance :input))
           (state-fn (plist-get view :state-fn))
           (capture-fn (plist-get view :capture-selection-fn))
           (restore-fn (plist-get view :restore-selection-fn))
           (selection (when capture-fn (funcall capture-fn)))
           (state (if state-fn (funcall state-fn input) input)))
      (let ((inhibit-read-only t))
        (funcall (plist-get view :render-fn) state))
      (setf (plist-get supertag-view--instance :state) state)
      (when restore-fn
        (funcall restore-fn selection)))))

(defun supertag-view-refresh (&optional buffer)
  "Refresh BUFFER or the current view buffer."
  (interactive)
  (let ((target (or buffer (current-buffer))))
    (unless (buffer-live-p target)
      (user-error "View buffer is not live"))
    (with-current-buffer target
      (unless supertag-view--instance
        (user-error "Not in a view buffer"))
      (supertag-view--refresh-instance))))

;; ============================================================================
;; Configuration Persistence
;; ============================================================================

(defvar supertag--view-configs (make-hash-table :test 'eq)
  "Hash table storing view configurations (not the render functions).
Key is view ID, value is configuration plist without :render-fn.
This is used for saving/loading view definitions.")

(defun supertag-view-config-register (config)
  "Register a view CONFIG (plist) for persistence.
The render function should be provided by the view implementation."
  (let ((id (plist-get config :id)))
    (puthash id config supertag--view-configs)
    config))

(defun supertag-view-config-get (id)
  "Get stored configuration for view ID."
  (gethash id supertag--view-configs))

(defun supertag-view-config-list ()
  "List all stored view configurations."
  (let (result)
    (maphash (lambda (_id config) (push config result))
             supertag--view-configs)
    (sort result (lambda (a b)
                   (string< (plist-get a :name)
                            (plist-get b :name))))))

;; ============================================================================
;; Widget Rendering Helpers (DSL v2)
;; ============================================================================

(defconst supertag-view--literal-props '(:key :action :on-change)
  "Widget properties whose values are literals, not context bindings.")

(defvar supertag-view-widget-field-map
  (let ((map (copy-keymap widget-field-keymap)))
    map)
  "Keymap used by editable fields in Widget DSL views.")

(defface supertag-view-widget-field-face
  '((t :inherit widget-field :box nil :extend nil))
  "Face for editable fields that preserves fixed-width DSL layouts."
  :group 'supertag)

(defun supertag-view-widget--cleanup-fields ()
  "Remove native editable fields from the current Widget DSL buffer."
  (dolist (field (delete-dups (append widget-field-new widget-field-list)))
    (widget-leave-text field))
  (setq widget-field-new nil
        widget-field-list nil))



(defun supertag-view--resolve-prop (value context)
  "Resolve VALUE in CONTEXT.
If VALUE is a function, call it with CONTEXT."
  (if (functionp value)
      (condition-case err
          (funcall value context)
        (error
         (message "View DSL: prop binding failed: %s"
                  (error-message-string err))
         nil))
    value))

(defun supertag-view--resolve-props (widget context)
  "Resolve WIDGET properties using CONTEXT."
  (let (props)
    (cl-loop for (key value) on widget by #'cddr
             unless (eq key :type)
             do (setq props (plist-put props key
                                       (if (memq key supertag-view--literal-props)
                                           value
                                         (supertag-view--resolve-prop
                                          value context)))))
    props))

(defun supertag-view--add-widget-key (from to key)
  "Add KEY between FROM and TO without replacing nested widget keys."
  (let ((position from))
    (while (< position to)
      (let ((end (or (next-single-property-change
                      position 'supertag-widget-key nil to)
                     to)))
        (unless (get-text-property position 'supertag-widget-key)
          (put-text-property position end 'supertag-widget-key key))
        (setq position end)))))

(defun supertag-view--render-widget (widget context)
  "Render a single WIDGET definition with CONTEXT."
  (unless (listp widget)
    (error "Widget must be a plist, got: %S" widget))
  (let* ((type (plist-get widget :type))
         (props (supertag-view--resolve-props widget context))
         (key (plist-get props :key))
         (start (point)))
    (unless type
      (error "Widget missing :type: %S" widget))
    (supertag-widget-render type props context)
    (when key
      (supertag-view--add-widget-key start (point) key))))

(defun supertag-view--render-widgets (widgets context)
  "Render WIDGETS list with CONTEXT."
  (when widgets
    (unless (listp widgets)
      (error "Widgets must be a list, got: %S" widgets))
    (dolist (widget widgets)
      (supertag-view--render-widget widget context))))

(defun supertag-view--render-widgets-to-lines (widgets context)
  "Render WIDGETS into a list of lines using CONTEXT."
  (with-temp-buffer
    (supertag-view--render-widgets widgets context)
    (split-string (buffer-string) "\n" nil)))

(defun supertag-view-widget--clear ()
  "Clear rendered text and stale editable-field bookkeeping."
  (supertag-view-widget--cleanup-fields)
  (let ((inhibit-modification-hooks t))
    (erase-buffer)))

(defun supertag-view-widget--capture-selection ()
  "Capture point as a stable Widget DSL key and offset."
  (let* ((position (if (and (eobp) (> (point) (point-min)))
                       (1- (point))
                     (point)))
         (key (get-text-property position 'supertag-widget-key)))
    (when key
      (let ((start position))
        (while (and (> start (point-min))
                    (equal (get-text-property
                            (1- start) 'supertag-widget-key)
                           key))
          (setq start (1- start)))
        (list :key key :offset (- position start))))))

(defun supertag-view-widget--restore-selection (selection)
  "Restore keyed SELECTION, falling back to `point-min'."
  (goto-char (point-min))
  (when-let* ((key (plist-get selection :key)))
    (let ((position (point-min))
          found)
      (while (and (< position (point-max)) (not found))
        (if (equal (get-text-property position 'supertag-widget-key) key)
            (setq found position)
          (setq position
                (or (next-single-property-change
                     position 'supertag-widget-key nil (point-max))
                    (point-max)))))
      (when found
        (let ((end (or (next-single-property-change
                        found 'supertag-widget-key nil (point-max))
                       (point-max))))
          (goto-char (min (1- end)
                          (+ found (or (plist-get selection :offset) 0)))))))))

(defun supertag-view--pad-line (line width)
  "Pad or truncate LINE to WIDTH."
  (let ((cell (truncate-string-to-width (or line "") width 0 nil t)))
    (if (< (string-width cell) width)
        (concat cell (make-string (- width (string-width cell)) ?\s))
      cell)))

;; ============================================================================
;; Widget System
;; ============================================================================

(defvar supertag--widget-registry (make-hash-table :test 'eq)
  "Registry of widget types.
Key is widget type symbol, value is render function.
Widgets are reusable UI components for building views.")

(defun supertag-widget--normalize-type (type)
  "Normalize widget TYPE to a registry key symbol."
  (if (keywordp type)
      (intern (substring (symbol-name type) 1))
    type))

(defun supertag-widget--accepts-context-p (render-fn)
  "Return non-nil if RENDER-FN accepts a CONTEXT argument."
  (let* ((arity (ignore-errors (func-arity render-fn)))
         (min-args (car arity))
         (max-args (cdr arity)))
    (or (and (integerp min-args) (>= min-args 2))
        (eq max-args 'many)
        (and (integerp max-args) (>= max-args 2)))))

(defface supertag-view-widget-badge-face
  '((t :weight bold))
  "Face for badge widget content."
  :group 'supertag)

(defface supertag-view-widget-toolbar-label-face
  '((t :weight bold))
  "Face for toolbar label text."
  :group 'supertag)

(defun supertag-widget-register (type render-fn)
  "Register a widget TYPE with RENDER-FN.
TYPE is a symbol such as `header' or `progress-bar'.
RENDER-FN is a function that takes a plist of properties and renders the widget."
  (let ((key (supertag-widget--normalize-type type)))
    (puthash key render-fn supertag--widget-registry)
    key))

(defun supertag-widget-render (type props &optional context)
  "Render widget TYPE with PROPS.
TYPE is the widget type symbol.
PROPS is a plist of properties for the widget.
Optional CONTEXT is passed to renderers that accept it.
Example: (supertag-widget-render (quote header) (list :text \"Title\"))"
  (let* ((key (supertag-widget--normalize-type type))
         (render-fn (gethash key supertag--widget-registry)))
    (unless render-fn
      (error "Unknown widget type: %s" type))
    (if (and context (supertag-widget--accepts-context-p render-fn))
        (funcall render-fn props context)
      (funcall render-fn props))))

(defun supertag-view-widget--insert-placeholder (descriptor text)
  "Insert TEXT carrying interactive leaf DESCRIPTOR."
  (let ((start (point)))
    (insert text)
    (put-text-property start (point)
                       'supertag-widget-placeholder descriptor)))

(defun supertag-widget--render-action (props face)
  "Render PROPS as a deferred text button using FACE."
  (let ((label (plist-get props :label))
        (action (plist-get props :action)))
    (unless (stringp label)
      (error "Widget action :label must be a string, got: %S" label))
    (unless (functionp action)
      (error "Widget action :action must be a function, got: %S" action))
    (supertag-view-widget--insert-placeholder
     (list :kind 'button :action action :face face
           :help-echo (plist-get props :help-echo))
     label)
    (unless (and (plist-member props :newline)
                 (null (plist-get props :newline)))
      (insert "\n"))))

(defun supertag-widget--render-editable-field (props)
  "Render PROPS as a deferred built-in editable field."
  (let ((value (plist-get props :value))
        (width (plist-get props :width))
        (on-change (plist-get props :on-change)))
    (unless (stringp value)
      (error "Editable field :value must be a string, got: %S" value))
    (unless (and (integerp width) (> width 0))
      (error "Editable field :width must be positive, got: %S" width))
    (when (> (string-width value) width)
      (error "Editable field value is wider than :width %d: %S"
             width value))
    (unless (or (null on-change) (functionp on-change))
      (error "Editable field :on-change must be a function, got: %S"
             on-change))
    (supertag-view-widget--insert-placeholder
     (list :kind 'editable-field :value value :on-change on-change)
     (concat value (make-string (- width (string-width value)) ?\s)))
    (unless (and (plist-member props :newline)
                 (null (plist-get props :newline)))
      (insert "\n"))))

(defun supertag-view-widget--placeholder-ranges ()
  "Return deferred interactive ranges in reverse buffer order."
  (let ((position (point-min))
        ranges)
    (while (< position (point-max))
      (let* ((descriptor
              (get-text-property position 'supertag-widget-placeholder))
             (end (or (next-single-property-change
                       position 'supertag-widget-placeholder nil (point-max))
                      (point-max))))
        (when descriptor
          (push (list position end descriptor
                      (get-text-property position 'supertag-widget-key))
                ranges))
        (setq position end)))
    ranges))

(defun supertag-view-widget--materialize ()
  "Materialize deferred buttons and fields in the final buffer."
  (dolist (range (supertag-view-widget--placeholder-ranges))
    (pcase-let ((`(,from ,to ,descriptor ,key) range))
      (remove-text-properties
       from to '(supertag-widget-placeholder nil))
      (pcase (plist-get descriptor :kind)
        ('button
         (let ((action (plist-get descriptor :action)))
           (make-text-button
            from to
            'action (lambda (_button) (funcall action))
            'face (plist-get descriptor :face)
            'mouse-face 'highlight
            'follow-link t
            'help-echo (plist-get descriptor :help-echo))))
        ('editable-field
         (let ((on-change (plist-get descriptor :on-change))
               (value (plist-get descriptor :value))
               (width (string-width
                       (buffer-substring-no-properties from to))))
           (delete-region from to)
           (goto-char from)
           (let ((start (point)))
             (widget-create
              'editable-field
              :format "%v"
              :size (+ (length value) (- width (string-width value)))
              :keymap supertag-view-widget-field-map
              :value-face 'supertag-view-widget-field-face
              :value value
              :notify (lambda (widget &rest _ignore)
                        (let ((new-value (widget-value widget)))
                          (when (> (string-width new-value) width)
                            (user-error
                             "Editable field value exceeds width %d"
                             width))
                          (when on-change
                            (funcall on-change new-value)))))
             (remove-text-properties
              start (point) '(supertag-widget-placeholder nil))
             (when key
               (put-text-property start (point)
                                  'supertag-widget-key key)))))
        (_
         (error "Unknown Widget placeholder kind: %S"
                (plist-get descriptor :kind)))))))

(defun supertag-view-widget--render-tree (widgets context)
  "Render WIDGETS for CONTEXT and initialize native controls."
  (supertag-view-widget--clear)
  (supertag-view--render-widgets
   (if (functionp widgets) (funcall widgets context) widgets)
   context)
  (supertag-view-widget--materialize)
  (widget-setup)
  (goto-char (point-min)))

;; Built-in widgets

(supertag-widget-register 'button
  (lambda (props)
    (supertag-widget--render-action props 'button)))

(supertag-widget-register 'link
  (lambda (props)
    (supertag-widget--render-action props 'link)))

(supertag-widget-register 'editable-field
  #'supertag-widget--render-editable-field)

(supertag-widget-register 'header
  (lambda (props)
    (let ((text (plist-get props :text)))
      (insert (format "%s\n" text))
      (insert (make-string (length text) ?=))
      (insert "\n\n"))))

(supertag-widget-register 'subheader
  (lambda (props)
    (let ((text (plist-get props :text)))
      (insert (format "%s\n" text))
      (insert (make-string (length text) ?-))
      (insert "\n\n"))))

(supertag-widget-register 'text
  (lambda (props)
    (let ((content (plist-get props :content))
          (face (plist-get props :face))
          (start (point)))
      (insert (format "%s\n" content))
      (when face
        (add-text-properties start (point) (list 'face face))))))

(supertag-widget-register 'progress-bar
  (lambda (props)
    (let* ((value (plist-get props :value))
           (max (or (plist-get props :max) 100))
           (width (or (plist-get props :width) 20))
           (percentage (* 100.0 (/ (float value) max)))
           (filled (round (* width (/ percentage 100.0))))
           (empty (- width filled)))
      (insert "[")
      (insert (make-string filled ?█))
      (insert (make-string empty ?░))
      (insert (format "] %d%%\n" (round percentage))))))

(supertag-widget-register 'stats-row
  (lambda (props)
    (let ((stats (plist-get props :stats)))
      (dolist (stat stats)
        (insert (format "  %s: %s\n" (car stat) (cdr stat))))
      (insert "\n"))))

(supertag-widget-register 'separator
  (lambda (props)
    (let ((char (or (plist-get props :char) ?-)))
      (insert (make-string (window-width) char))
      (insert "\n\n"))))

(supertag-widget-register 'list
  (lambda (props)
    (let ((items (plist-get props :items)))
      (dotimes (i (length items))
        (let ((item (nth i items)))
          (insert (format "%d. %s\n" (1+ i) item))))
      (insert "\n"))))

(supertag-widget-register 'table
  (lambda (props)
    (let* ((headers (plist-get props :headers))
           (rows (plist-get props :rows))
           (widths (or (plist-get props :widths)
                      (make-list (length headers) 15))))
      ;; Header row
      (dotimes (i (length headers))
        (insert (supertag-view--pad-line
                 (format "%s" (nth i headers)) (nth i widths))
                " "))
      (insert "\n")
      ;; Separator
      (dotimes (i (length headers))
        (insert (make-string (nth i widths) ?-)))
      (insert "\n")
      ;; Data rows
      (dolist (row rows)
        (dotimes (i (length row))
          (insert (supertag-view--pad-line
                   (format "%s" (nth i row)) (nth i widths))
                  " "))
        (insert "\n"))
      (insert "\n"))))

;; Container widgets (DSL v2)

(supertag-widget-register 'section
  (lambda (props &optional context)
    (let ((title (plist-get props :title))
          (face (plist-get props :face))
          (children (plist-get props :children)))
      (when title
        (let ((start (point)))
          (supertag-view--subheader title)
          (when face
            (add-text-properties start (point) (list 'face face)))))
      (when children
        (unless (listp children)
          (error "Widget :children must be a list, got: %S" children))
        (supertag-view--render-widgets children context)))))

(supertag-widget-register 'stack
  (lambda (props &optional context)
    (let* ((children (plist-get props :children))
           (spacing (or (plist-get props :spacing) 1))
           (count 0)
           (index 0))
      (unless (listp children)
        (error "Widget :children must be a list, got: %S" children))
      (setq count (length children))
      (dolist (child children)
        (setq index (1+ index))
        (supertag-view--render-widget child context)
        (when (< index count)
          (dotimes (_ spacing)
            (insert "\n")))))))

(supertag-widget-register 'columns
  (lambda (props &optional context)
    (let ((columns (plist-get props :columns)))
      (unless (listp columns)
        (error "Widget :columns must be a list, got: %S" columns))
      (let* ((column-data
              (mapcar
               (lambda (column)
                 (let* ((width (supertag-view--resolve-prop
                                (plist-get column :width) context))
                        (width (if (and (integerp width) (> width 0)) width 30))
                        (children (plist-get column :children)))
                   (unless (listp children)
                     (error "Column :children must be a list, got: %S" children))
                   (list (supertag-view--render-widgets-to-lines children context)
                         width)))
               columns))
             (lines-per-col (mapcar #'car column-data))
             (widths (mapcar #'cadr column-data))
             (max-lines (if lines-per-col
                            (apply #'max (mapcar #'length lines-per-col))
                          0))
             (col-count (length columns)))
        (dotimes (line-idx max-lines)
          (dotimes (col-idx col-count)
            (let* ((col-lines (nth col-idx lines-per-col))
                   (width (nth col-idx widths))
                   (line (or (nth line-idx col-lines) "")))
              (insert (supertag-view--pad-line line width))
              (when (< col-idx (1- col-count))
                (insert " "))))
          (insert "\n"))))))

;; Layout and info widgets (DSL v2)

(defun supertag-widget--render-card (props context)
  "Render PROPS as a simple card using CONTEXT for child widgets."
  (let* ((title (plist-get props :title))
         (children (plist-get props :children))
         (width (plist-get props :width))
         (child-lines
          (when children
            (unless (listp children)
              (error "Widget :children must be a list, got: %S" children))
            (supertag-view--render-widgets-to-lines children context)))
         (lines (append (when title (list (format "%s" title))) child-lines))
         (content-width (if lines
                            (apply #'max (mapcar #'string-width lines))
                          0))
         (max-width (max 1 (- (window-width) 4)))
         (inner-width (cond
                       ((and (integerp width) (> width 0)) width)
                       ((> content-width 0) content-width)
                       (t 1))))
    (setq inner-width (min inner-width max-width))
    (when (null lines)
      (setq lines (list "")))
    (insert (format "┌%s┐\n" (make-string (+ inner-width 2) ?─)))
    (let ((is-title t))
      (dolist (line lines)
        (let ((padded (supertag-view--pad-line line inner-width)))
          (when (and is-title title)
            (setq padded (propertize padded 'face 'bold)))
          (insert "│ " padded " │\n"))
        (setq is-title nil)))
    (insert (format "└%s┘\n" (make-string (+ inner-width 2) ?─)))
    (insert "\n")))

(supertag-widget-register 'card #'supertag-widget--render-card)
(supertag-widget-register 'panel #'supertag-widget--render-card)

(defun supertag-widget--render-field-table (props)
  "Render field/value pairs from PROPS in a table style."
  (let* ((items (or (plist-get props :items) '()))
         (pairs
          (mapcar
           (lambda (item)
             (cond
              ((consp item) (cons (car item) (cdr item)))
              ((and (listp item) (= (length item) 2))
               (cons (nth 0 item) (nth 1 item)))
              (t (cons (format "%s" item) ""))))
           items))
         (label-texts (mapcar (lambda (pair) (format "%s" (car pair))) pairs))
         (value-texts (mapcar (lambda (pair) (format "%s" (cdr pair))) pairs))
         (label-width (apply #'max 5 (mapcar #'string-width (cons "Field" label-texts))))
         (value-width (apply #'max 5 (mapcar #'string-width (cons "Value" value-texts))))
         (max-width (max 10 (- (window-width) 7))))
    (when (> (+ label-width value-width) max-width)
      (let* ((spill (- (+ label-width value-width) max-width))
             (trim (min spill (max 0 (- value-width 5)))))
        (setq value-width (max 5 (- value-width trim)))))
    (let* ((label-seg (make-string (+ label-width 2) ?─))
           (value-seg (make-string (+ value-width 2) ?─))
           (top (format "┌%s┬%s┐" label-seg value-seg))
           (mid (format "├%s┼%s┤" label-seg value-seg))
           (bottom (format "└%s┴%s┘" label-seg value-seg)))
      (insert top "\n")
      (cl-loop for label in label-texts
               for value in value-texts
               for idx from 0
               do (progn
                    (when (> idx 0)
                      (insert mid "\n"))
                    (insert (format "│ %s │ %s │\n"
                                    (supertag-view--pad-line label label-width)
                                    (supertag-view--pad-line value value-width)))))
      (insert bottom "\n\n"))))

(supertag-widget-register 'field #'supertag-widget--render-field-table)
(supertag-widget-register 'kv #'supertag-widget--render-field-table)

(supertag-widget-register 'badge
  (lambda (props)
    (let* ((text (plist-get props :text))
           (items (or (plist-get props :items)
                      (when text (list text)))))
      (when items
        (insert (mapconcat
                 (lambda (item)
                   (propertize (format "[%s]" item)
                               'face 'supertag-view-widget-badge-face))
                 items
                 " ")))
      (insert "\n"))))

(supertag-widget-register 'empty
  (lambda (props)
    (let ((title (or (plist-get props :title) "No data"))
          (message (plist-get props :message)))
      (insert (format "%s\n" title))
      (when message
        (insert (format "%s\n" message)))
      (insert "\n"))))

(supertag-widget-register 'toolbar
  (lambda (props)
    (let* ((items (or (plist-get props :items) '()))
           (label (or (plist-get props :label) "Operations"))
           (formatted
            (mapcar
             (lambda (item)
               (cond
                ((consp item) (format "%s (%s)" (car item) (cdr item)))
                ((stringp item) item)
                (t (format "%s" item))))
             items)))
      (insert (propertize (format "%s:" label)
                          'face 'supertag-view-widget-toolbar-label-face))
      (insert (format " %s\n"
                      (mapconcat #'identity formatted " | ")))
      (insert "\n"))))

;; ============================================================================
;; DSL - Declarative View Definition
;; ============================================================================



(defun supertag-ui--sanitize-type-input (type-str)
  "Return a keyword type from TYPE-STR, stripping leading colons/whitespace."
  (when (and type-str (not (string-empty-p type-str)))
    (let* ((clean (string-trim type-str)))
      (when (string-prefix-p ":" clean)
        (setq clean (substring clean 1)))
      (when (not (string-empty-p clean))
        (intern (concat ":" clean))))))

(provide 'supertag-view-framework)

;;; supertag-view-framework.el ends here
