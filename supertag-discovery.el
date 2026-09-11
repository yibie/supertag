;;; supertag-discovery.el --- Discovery: random reading, searching and reference insertion -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides the Discovery functionality for supertag.
;; It includes:
;; - Card-based Discovery display with navigation and marking
;; - Query history management
;; - Keyword-based search across nodes, tags, and content
;; - Main entry point: `supertag-discovery'

;; Commands: supertag-discovery, supertag-discovery-mode, supertag-discovery-next, supertag-discovery-previous, supertag-discovery-toggle-mark, supertag-discovery-open-node, supertag-discovery-quit, supertag-discovery-search, supertag-discovery-refresh, supertag-discovery-insert-references
;; Dependencies: cl-lib, org, seq, supertag-link, supertag-core-store, supertag-node, supertag-tag, supertag-view-framework

;;; Code:

(require 'cl-lib)
(require 'supertag-link)
(require 'org)
(require 'seq)
(require 'supertag-core-store) ; For data access
(require 'supertag-node)
(require 'supertag-tag)
(require 'supertag-view-framework)

(declare-function supertag-reference-materialize-at-point
                  "supertag-link"
                  (target-id title))
(declare-function supertag-reference-recovery-complete-p
                  "supertag-link" (payload))
(declare-function supertag-reference--validate-source
                  "supertag-link" (marker))
(declare-function supertag-ui-navigate-with-recovery "supertag-node"
                  (node-id &optional other-window))
(declare-function supertag-node-location-find "supertag-service-org"
                  (node-id))

;;; --- Search History Management ---

(defcustom supertag-discovery-history-max-items 100
  "Maximum number of keywords to keep in history."
  :type 'integer
  :group 'supertag)

(defcustom supertag-discovery-history-file nil
  "File to store Discovery history.
The default filename search-history.el stays unchanged to read existing history."
  :type 'file
  :group 'supertag)

(defun supertag-discovery--history-path ()
  (or supertag-discovery-history-file
      (supertag-data-file "search-history.el")))

(defvar supertag-discovery--history nil
  "List of Discovery history items.")

(defcustom supertag-discovery-initial-sample-size 10
  "Number of notes shown when Discovery opens or refreshes its sample."
  :type '(integer 1)
  :group 'supertag)

(defvar-local supertag-discovery--marked-nodes nil
  "Node IDs explicitly marked in this Discovery buffer, newest first.")

(defvar-local supertag-discovery--origin-marker nil
  "Live marker for this Discovery invocation's insertion origin.")

(defvar-local supertag-discovery--origin-mark-marker nil
  "Live marker for the origin buffer's mark.")

(defvar-local supertag-discovery--origin-min-marker nil
  "Live marker for the origin buffer's narrowing start.")

(defvar-local supertag-discovery--origin-max-marker nil
  "Live marker for the origin buffer's narrowing end.")

(defvar-local supertag-discovery--origin-mark-active nil)
(defvar-local supertag-discovery--origin-window nil)
(defvar-local supertag-discovery--origin-window-configuration nil)
(defvar-local supertag-discovery--insert-progress nil)

(defconst supertag-discovery--buffer-name "*Supertag Discovery*"
  "Name of the Discovery buffer.")

(defun supertag-discovery--load-history ()
  "Load Discovery history from file."
  (if (file-exists-p (supertag-discovery--history-path))
      (with-temp-buffer
        (insert-file-contents (supertag-discovery--history-path))
        (setq supertag-discovery--history (read (current-buffer))))
    (setq supertag-discovery--history nil)))

(defun supertag-discovery--reset-runtime ()
  "Clear Discovery history before a vault boundary."
  (setq supertag-discovery--history nil))

(defun supertag-discovery--save-history ()
  "Save Discovery history to file."
  (with-temp-file (supertag-discovery--history-path)
    (let ((print-length nil)
          (print-level nil))
      (prin1 supertag-discovery--history (current-buffer)))))

(defun supertag-discovery--update-keyword-frequency (input)
  "Update frequency of search INPUT in history."
  (let* ((now (supertag-current-time))
         (query-str (if (stringp input) input (prin1-to-string input)))
         (existing-entry (cl-find query-str supertag-discovery--history
                                :key (lambda (x) (plist-get x :query))
                                :test #'equal)))

    (when existing-entry
      (setq supertag-discovery--history
            (cl-remove query-str supertag-discovery--history
                      :key (lambda (x) (plist-get x :query))
                      :test #'equal)))

    (let ((entry (or existing-entry
                    `(:query ,query-str :count 0 :last-used ,now))))
      (plist-put entry :count (1+ (plist-get entry :count)))
      (plist-put entry :last-used now)
      (push entry supertag-discovery--history)))

  (setq supertag-discovery--history
        (sort supertag-discovery--history
              (lambda (a b)
                (or (> (plist-get a :count) (plist-get b :count))
                    (and (= (plist-get a :count) (plist-get b :count))
                         (supertag-discovery--time-less-p (plist-get b :last-used)
                                (plist-get a :last-used)))))))

  (when (> (length supertag-discovery--history) supertag-discovery-history-max-items)
    (setq supertag-discovery--history
          (seq-take supertag-discovery--history supertag-discovery-history-max-items)))

  (supertag-discovery--save-history))

(defun supertag-discovery--time-less-p (time-a time-b)
  "Compare two time values that may be in different formats.
Handles both time stamps (list) and date strings."
  (let ((time-converter (lambda (time-val)
                          (if (stringp time-val)
                              ;; If it's a string, parse it, replacing nils with 0 for encode-time.
                              (apply #'encode-time
                                     (mapcar (lambda (x) (or x 0))
                                             (parse-time-string time-val)))
                            ;; Otherwise, assume it's a valid time list.
                            time-val))))
    (time-less-p (funcall time-converter time-b) (funcall time-converter time-a))))

;;; --- Search Window UI ---

(defgroup supertag-discovery nil
  "Customization for supertag search."
  :group 'supertag)

(defface supertag-discovery-current
  '((t :inherit region))
  "Face for current selected item."
  :group 'supertag-discovery)

(defface supertag-discovery-title
  '((t :weight bold))
  "Face for titles in Discovery results."
  :group 'supertag-discovery)

(defface supertag-discovery-tag
  '((t :box t))
  "Face for tags in Discovery results."
  :group 'supertag-discovery)

(defface supertag-discovery-file
  '((t :inherit fixed-pitch))
  "Face for file names in Discovery results."
  :group 'supertag-discovery)

(defvar-local supertag-discovery-mode-map nil
  "Keymap for `supertag-discovery-mode'.")

(defun supertag-discovery-mode-init-map ()
  "Initialize the keymap for `supertag-discovery-mode'."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'supertag-discovery-next)
    (define-key map (kbd "p") #'supertag-discovery-previous)
    (define-key map (kbd "SPC") #'supertag-discovery-toggle-mark)
    (define-key map (kbd "RET") #'supertag-discovery-open-node)
    (define-key map (kbd "s") #'supertag-discovery-search)
    (define-key map (kbd "g") #'supertag-discovery-refresh)
    (define-key map (kbd "q") #'supertag-discovery-quit)
    (define-key map (kbd "i") #'supertag-discovery-insert-references)
    map))

(define-minor-mode supertag-discovery-mode
  "Minor mode for browsing and searching Discovery notes."
  :lighter " Discovery"
  (when supertag-discovery-mode
    (unless supertag-discovery-mode-map
      (setq supertag-discovery-mode-map (supertag-discovery-mode-init-map)))
    (setq buffer-read-only t)
    (use-local-map supertag-discovery-mode-map)))

;;; --- Search Functions ---

(defun supertag-discovery-find-nodes (keywords)
  "Find nodes matching KEYWORDS."
  (let ((patterns (mapcar #'regexp-quote keywords))
        results)
    (dolist (pair (supertag-query-nodes (lambda (_id data) data)))
      (let* ((node-data (cdr pair))
             (title (plist-get node-data :title))
             (content (plist-get node-data :content))
             (tags (plist-get node-data :tags))
             (tag-texts (supertag-discovery--tag-texts tags))
             (properties (plist-get node-data :properties))
             (match-context nil)
             (all-match t))
        (catch 'node-does-not-match
          (dolist (keyword-re patterns)
            (let ((content-searched-p nil)
                  (content-match nil))
              ;; Preserve the old "first matching content keyword" snippet,
              ;; but once a snippet exists do not scan content when an earlier
              ;; title/tag field already proves the keyword matches.
              (when (and content (not match-context))
                (setq content-searched-p t
                      content-match (string-match keyword-re content))
                (when content-match
                  (let* ((match-start (match-beginning 0))
                         (context-start (max 0 (- match-start 40)))
                         (context-end
                          (min (length content) (+ (match-end 0) 40)))
                         (prefix (if (> context-start 0) "..." ""))
                         (suffix
                          (if (< context-end (length content)) "..." "")))
                    (setq match-context
                          (concat prefix
                                  (substring content context-start context-end)
                                  suffix)))))
              (unless
                  (or (and title (string-match-p keyword-re title))
                      (and tag-texts
                           (cl-some
                            (lambda (tag)
                              (string-match-p keyword-re tag))
                            tag-texts))
                      content-match
                      (and content
                           (not content-searched-p)
                           (string-match-p keyword-re content))
                      (and properties
                           (cl-loop for (_key value) on properties by #'cddr
                                    thereis
                                    (and (stringp value)
                                         (string-match-p keyword-re value)))))
                (setq all-match nil)
                (throw 'node-does-not-match nil)))))
        (when all-match
          (push (cons node-data match-context) results))))
    (nreverse results)))

;;; --- Card Formatting ---

(defun supertag-discovery--strict-pad-line (line target-width)
  "Strictly pad LINE to exactly TARGET-WIDTH characters."
  (let* ((current-width (string-width line))
         (padding-needed (- target-width current-width)))
    (if (<= padding-needed 0)
        (truncate-string-to-width line target-width)
      (concat line (make-string padding-needed ?\ )))))

(defun supertag-discovery--wrap-text (text width)
  "Wrap TEXT to display WIDTH without dropping any source characters."
  (let ((remaining text)
        lines)
    (while (> (string-width remaining) width)
      (let ((prefix (truncate-string-to-width remaining width)))
        (when (string-empty-p prefix)
          (setq prefix (substring remaining 0 1)))
        (push prefix lines)
        (setq remaining (substring remaining (length prefix)))))
    (push remaining lines)
    (nreverse lines)))

(defun supertag-discovery--tag-texts (tag-ids)
  "Return searchable display text for TAG-IDS without changing identity."
  (delete-dups
   (delq nil
         (cl-mapcan
          (lambda (tag-id)
            (let ((name (plist-get (supertag-tag-get tag-id) :name)))
              (if (and name (not (equal name tag-id)))
                  (list tag-id name)
                (list tag-id))))
          tag-ids))))

(defun supertag-discovery--get-node-tags (node-id)
  "Get readable tag text for NODE-ID's Discovery card."
  (when-let* ((node-data (supertag-node-get node-id)))
    (let ((tag-ids (plist-get node-data :tags)))
      (mapcar (lambda (tag-id)
                (or (plist-get (supertag-tag-get tag-id) :name) tag-id))
              tag-ids))))

(defun supertag-discovery--format-card (node-props _context-snippet width marked-p)
  "Format a node into a bordered card of fixed WIDTH."
  (let* ((title (or (plist-get node-props :title) "No Title"))
         (node-id (plist-get node-props :id))
         (file-path (plist-get node-props :file))
         (tags (supertag-discovery--get-node-tags node-id))
         (content (or (plist-get node-props :content) ""))
         (inner-width (- width 4))
         (checkbox (if marked-p "[X]" "[ ]"))
         (title-with-checkbox (format "%s %s" checkbox title))
         (card-lines '()))
    ;; Top border
    (push (format "┌%s┐" (make-string (- width 2) ?─)) card-lines)
    ;; Title with checkbox
    (dolist (line (supertag-discovery--wrap-text title-with-checkbox inner-width))
      (push (format "│ %s │" (supertag-discovery--strict-pad-line line inner-width)) card-lines))
    ;; Separator
    (push (format "├%s┤" (make-string (- width 2) ?─)) card-lines)
    ;; File Path
    (when file-path
      (let ((file-str (format "File: %s" (file-name-nondirectory file-path))))
        (dolist (line (supertag-discovery--wrap-text file-str inner-width))
          (push (format "│ %s │" (supertag-discovery--strict-pad-line line inner-width)) card-lines))))
    ;; Tags
    (when tags
      (let ((tag-str (format "Tags: %s" (string-join tags " "))))
        (dolist (line (supertag-discovery--wrap-text tag-str inner-width))
          (push (format "│ %s │" (supertag-discovery--strict-pad-line line inner-width)) card-lines))))
    ;; Complete projected body, rather than a keyword-only snippet.
    (push (format "├%s┤" (make-string (- width 2) ?─)) card-lines)
    (push (format "│ %s │"
                  (supertag-discovery--strict-pad-line "Body:" inner-width))
          card-lines)
    (if (string-empty-p (string-trim content))
        (push (format "│ %s │"
                      (supertag-discovery--strict-pad-line "Empty body" inner-width))
              card-lines)
      (dolist (line (split-string content "\n" nil))
        (if (string-empty-p line)
            (push (format "│ %s │"
                          (supertag-discovery--strict-pad-line "" inner-width))
                  card-lines)
          (dolist (wrapped-line (supertag-discovery--wrap-text line inner-width))
            (push (format "│ %s │"
                          (supertag-discovery--strict-pad-line
                           wrapped-line inner-width))
                  card-lines)))))
    ;; Bottom border
    (push (format "└%s┘" (make-string (- width 2) ?─)) card-lines)
    ;; Propertize and return
    (mapcar (lambda (line) (propertize line 'node-id node-id))
            (nreverse card-lines))))

(defun supertag-discovery--mark-counts (nodes)
  "Return (TOTAL HIDDEN) mark counts relative to visible NODES."
  (let ((visible-ids (mapcar (lambda (pair) (plist-get (car pair) :id)) nodes)))
    (list (length supertag-discovery--marked-nodes)
          (cl-count-if-not (lambda (id) (member id visible-ids))
                           supertag-discovery--marked-nodes))))

(defun supertag-discovery--insert-header (mode keyword-list nodes)
  "Insert a Discovery header for MODE, KEYWORD-LIST and NODES."
  (pcase-let ((`(,marked ,hidden) (supertag-discovery--mark-counts nodes)))
    (insert (propertize (if (eq mode :search)
                           (format "Supertag Discovery Search results: '%s'"
                                   (string-join keyword-list " "))
                         "Supertag Discovery")
                      'face '(:height 1.5 :weight bold)))
    (insert (if (eq mode :search)
                (format "\nFound %d matching nodes.\n" (length nodes))
              (format "\nShowing %d random notes.\n" (length nodes))))
    (insert (format "Marked: %d (%d hidden)\n\n" marked hidden))
    (insert (propertize "Operations:\n" 'face '(:weight bold)))
    (insert " [n/p] Navigate [SPC] Mark [RET] Open [s] Search [g] Refresh\n")
    (insert " [i] Insert references [q] Quit\n\n")))

(defun supertag-discovery--sample-nodes ()
  "Return a without-replacement random sample of projected nodes."
  (let* ((nodes (vconcat
                 (mapcar (lambda (pair) (cons (cdr pair) nil))
                         (supertag-query-nodes
                          (lambda (_id data) data)))))
         (length (length nodes)))
    (dotimes (index length)
      (let ((other (+ index (random (- length index)))))
        (cl-rotatef (aref nodes index) (aref nodes other))))
    (seq-take (append nodes nil)
              (min (max 1 supertag-discovery-initial-sample-size) length))))

(defun supertag-discovery--build-view-state (input)
  "Build Discovery view state from INPUT."
  (let ((mode (or (plist-get input :mode) :sample))
        (keywords (plist-get input :keywords)))
    (list :mode mode :keywords keywords
          :nodes (cond
                  ((plist-member input :nodes) (plist-get input :nodes))
                  ((eq mode :search) (supertag-discovery-find-nodes keywords))
                  (t (supertag-discovery--sample-nodes))))))

(defun supertag-discovery--view-mode ()
  "Install the Discovery buffer modes."
  (fundamental-mode)
  (supertag-discovery-mode 1)
  (setq-local supertag-discovery--marked-nodes nil)
  (add-hook 'kill-buffer-hook #'supertag-discovery--release-origin nil t)
  (add-hook 'change-major-mode-hook
            #'supertag-discovery--release-origin nil t))

(defun supertag-discovery--render-view (state)
  "Render Search view STATE in the current buffer."
  (let ((keyword-list (plist-get state :keywords))
        (nodes (plist-get state :nodes))
        (card-width 80))
    (erase-buffer)
    (supertag-discovery--insert-header (plist-get state :mode)
                                       keyword-list nodes)
    (if (not nodes)
        (insert "  No matching nodes found.\n")
      (dolist (result-pair nodes)
        (let* ((node (car result-pair))
               (context (cdr result-pair))
               (node-id (plist-get node :id))
               (card-lines (supertag-discovery--format-card
                            node context card-width
                            (member node-id supertag-discovery--marked-nodes)))
               (start (point)))
          (dolist (line card-lines)
            (insert line "\n"))
          (add-text-properties start (point)
                               `(result-pair ,result-pair
                                             node-id ,node-id
                                             supertag-entity-id ,node-id))
          (insert "\n"))))
    (when nodes
      (goto-char (point-min))
      (re-search-forward "^┌" nil t)
      (beginning-of-line)
      (supertag-discovery-highlight-current))))

(defun supertag-discovery--capture-selection ()
  "Return the selected Discovery entity ID."
  (get-text-property (point) 'supertag-entity-id))

(defun supertag-discovery--restore-selection (entity-id)
  "Restore Discovery selection to ENTITY-ID when it still exists."
  (when entity-id
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward
                        'supertag-entity-id entity-id t)))
      (goto-char (prop-match-beginning match))
      (supertag-discovery-highlight-current))))

(defun supertag-discovery--register-view ()
  "Register the Discovery Adapter when needed."
  (unless (supertag-view-get 'discovery)
    (supertag-view-register
     :id 'discovery
     :name "Discovery"
     :selectable nil
     :buffer-name supertag-discovery--buffer-name
     :mode-fn #'supertag-discovery--view-mode
     :state-fn #'supertag-discovery--build-view-state
     :render-fn #'supertag-discovery--render-view
     :capture-selection-fn #'supertag-discovery--capture-selection
     :restore-selection-fn #'supertag-discovery--restore-selection
     :display-action '(display-buffer-same-window))))

(defun supertag-discovery--show-results (mode keyword-list nodes)
  "Display MODE results for KEYWORD-LIST and optional NODES."
  (supertag-discovery--register-view)
  (supertag-view-open 'discovery
                      (list :mode mode :keywords keyword-list :nodes nodes)))

;;; --- Navigation Functions ---

(defun supertag-discovery-highlight-current ()
  "Highlight the current result card."
  (remove-overlays (point-min) (point-max) 'supertag-discovery t)
  (save-excursion
    (beginning-of-line)
    (when (looking-at "┌")
      (let ((beg (point))
            (end (save-excursion
                   (re-search-forward "^└" nil t)
                   (line-end-position))))
        (when end
          (let ((ov (make-overlay beg end)))
            (overlay-put ov 'face 'supertag-discovery-current)
            (overlay-put ov 'supertag-discovery t)))))))

(defun supertag-discovery-next ()
  "Jump to the next result card."
  (interactive)
  (let ((p (point)))
    (let ((search-start-point
           (save-excursion
             (beginning-of-line)
             (unless (looking-at "┌")
               (re-search-backward "^┌" nil t))
             (when (re-search-forward "^└" nil t)
               (point)))))
      (if (and search-start-point
               (save-excursion (goto-char search-start-point)
                               (re-search-forward "^┌" nil t)))
          (progn
            (goto-char (match-beginning 0))
            (supertag-discovery-highlight-current))
        (goto-char p)))))

(defun supertag-discovery-previous ()
  "Jump to the previous result card."
  (interactive)
  (let ((p (point)))
    (let ((current-card-start
           (save-excursion
             (beginning-of-line)
             (if (looking-at "┌")
                 (point)
               (re-search-backward "^┌" nil t)))))
      (if (and current-card-start (> current-card-start (point-min)))
          (if (save-excursion
                (goto-char (1- current-card-start))
                (re-search-backward "^┌" nil t))
              (progn
                (goto-char (match-beginning 0))
                (supertag-discovery-highlight-current))
            (goto-char p))
        (goto-char p)))))

(defun supertag-discovery-toggle-mark ()
  "Toggle the marked state of the current card and redraw it."
  (interactive)
  (when-let* ((node-id (get-text-property (point) 'node-id))
              (result-pair (get-text-property (point) 'result-pair)))
    (if (member node-id supertag-discovery--marked-nodes)
        (setq supertag-discovery--marked-nodes
              (remove node-id supertag-discovery--marked-nodes))
      (push node-id supertag-discovery--marked-nodes))
    (let ((inhibit-read-only t) (p (point)) (card-width 80))
      (save-excursion
        (let* ((beg (save-excursion (beginning-of-line) (if (looking-at "┌")
                                                             (point) (re-search-backward "^┌" nil t))))
               (end (when beg (save-excursion (goto-char beg) (when
                                                                 (re-search-forward "^└" nil t) (end-of-line) (forward-char 1) (point))))))
          (when (and beg end)
            (delete-region beg end)
            (goto-char beg)
            (let* ((node (car result-pair)) (context (cdr result-pair))
                   (card-lines (supertag-discovery--format-card node context
                                                                card-width (member node-id supertag-discovery--marked-nodes))))
              (dolist (line card-lines) (insert line "\n"))
              (add-text-properties
               beg (- (point) 1)
               `(result-pair ,result-pair node-id ,node-id
                             supertag-entity-id ,node-id))))))
      (goto-char p)
      (supertag-discovery-highlight-current))
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward "^Marked:.*$" nil t)
        (pcase-let ((`(,marked ,hidden)
                     (supertag-discovery--mark-counts
                      (plist-get (plist-get supertag-view--instance :state)
                                 :nodes))))
          (let ((inhibit-read-only t))
            (replace-match (format "Marked: %d (%d hidden)" marked hidden)
                           t t)))))))

(defun supertag-discovery-open-node ()
  "Open the current node through the shared navigation authority."
  (interactive)
  (when-let* ((id (get-text-property (point) 'node-id)))
    (supertag-ui-navigate-with-recovery id)))

(defun supertag-discovery--release-origin ()
  "Release live markers owned by the current Discovery invocation."
  (dolist (marker (list supertag-discovery--origin-marker
                        supertag-discovery--origin-mark-marker
                        supertag-discovery--origin-min-marker
                        supertag-discovery--origin-max-marker))
    (when (markerp marker) (set-marker marker nil)))
  (setq supertag-discovery--origin-marker nil
        supertag-discovery--origin-mark-marker nil
        supertag-discovery--origin-min-marker nil
        supertag-discovery--origin-max-marker nil))

(defun supertag-discovery--origin-live-p ()
  "Return non-nil when this invocation still has a usable origin."
  (and (markerp supertag-discovery--origin-marker)
       (marker-buffer supertag-discovery--origin-marker)
       (buffer-live-p (marker-buffer supertag-discovery--origin-marker))))

(defun supertag-discovery--restore-origin ()
  "Restore this invocation's live origin buffer and editing context."
  (unless (supertag-discovery--origin-live-p)
    (user-error "Discovery origin is no longer available"))
  (let ((origin-marker supertag-discovery--origin-marker)
        (mark-marker supertag-discovery--origin-mark-marker)
        (minimum-marker supertag-discovery--origin-min-marker)
        (maximum-marker supertag-discovery--origin-max-marker)
        (active supertag-discovery--origin-mark-active)
        (origin-window supertag-discovery--origin-window)
        (configuration supertag-discovery--origin-window-configuration))
    (let ((origin-buffer (marker-buffer origin-marker)))
      (when (window-configuration-p configuration)
        (set-window-configuration configuration))
      (if (window-live-p origin-window)
          (select-window origin-window)
        (switch-to-buffer origin-buffer))
      (unless (eq (current-buffer) origin-buffer)
        (switch-to-buffer origin-buffer))
      (with-current-buffer origin-buffer
        (widen)
        (when (and (markerp minimum-marker) (marker-position minimum-marker)
                   (markerp maximum-marker) (marker-position maximum-marker))
          (narrow-to-region minimum-marker maximum-marker))
        (goto-char origin-marker)
        (if (and (markerp mark-marker) (marker-position mark-marker))
            (set-mark mark-marker)
          (set-marker (mark-marker) nil))
        (setq mark-active active))
      origin-buffer)))

(defun supertag-discovery-quit ()
  "Quit Discovery and return to this invocation's live origin."
  (interactive)
  (let ((results-buffer (current-buffer)))
    (supertag-discovery--restore-origin)
    (when (buffer-live-p results-buffer)
      (kill-buffer results-buffer))))

(defun supertag-discovery-search ()
  "Search all nodes using space-separated keywords; every keyword must match."
  (interactive)
  (let* ((history (delete-dups
                   (mapcar (lambda (item) (plist-get item :query))
                           supertag-discovery--history)))
         (input (read-string "Search notes (all keywords): " nil 'history history))
         (keywords (split-string input " " t))
         (view-input (if keywords
                         (list :mode :search :keywords keywords)
                       (list :mode :sample :keywords nil))))
    (when keywords (supertag-discovery--update-keyword-frequency input))
    (setf (plist-get supertag-view--instance :input) view-input)
    (supertag-view-refresh)))

(defun supertag-discovery-refresh ()
  "Refresh the current sample or complete search result set."
  (interactive)
  (supertag-view-refresh))

;;; --- Export Functions ---

(defun supertag-discovery--insert-node-link-line (node-id title)
  "Insert one bullet link to NODE-ID titled TITLE through the materializer."
  (insert "- \n")
  (backward-char 1)
  (let ((inhibit-message t))
    (supertag-reference-materialize-at-point node-id title))
  (forward-char 1))

(defun supertag-discovery--selected-nodes ()
  "Return marked node IDs in the order in which they were selected."
  (let ((selected-ids (cl-copy-list supertag-discovery--marked-nodes)))
      (when selected-ids
        (message "Found %d selected nodes" (length selected-ids)))
      (nreverse selected-ids)))

(defun supertag-discovery--prevalidate-targets (node-ids)
  "Require every NODE-ID to have a current projected source location."
  (dolist (node-id node-ids)
    (unless (supertag-node-get node-id)
      (user-error "Selected node %s is no longer projected" node-id))
    (let ((location (supertag-node-location-find node-id)))
      (unless location
        (user-error "Selected node %s has no valid source location" node-id))
      (set-marker location nil))))

(defun supertag-discovery--failed-link-recovered-p (failed)
  "Return non-nil only when FAILED's shared recovery operation completed."
  (supertag-reference-recovery-complete-p
   (cdr (plist-get failed :error))))

(defun supertag-discovery-insert-references ()
  "Insert marked ordinary references at this invocation's live origin.

Each link uses the shared reference materializer.  On a staged failure, retry
the structured service error first and invoke this command again to continue;
already projected links are not inserted twice."
  (interactive)
  (let* ((results-buffer (current-buffer))
         (selected-nodes (supertag-discovery--selected-nodes)))
    (unless selected-nodes (user-error "No nodes selected"))
    (unless (supertag-discovery--origin-live-p)
      (user-error "Discovery origin is no longer available"))
    (supertag-reference--validate-source supertag-discovery--origin-marker)
    (supertag-discovery--prevalidate-targets selected-nodes)
    (let ((previous (plist-get supertag-discovery--insert-progress :selected)))
      (cond
       ((null previous)
        (setq supertag-discovery--insert-progress
              (list :selected selected-nodes :completed nil :failed nil)))
       ((not (equal selected-nodes previous))
        (user-error "Discovery selection changed during reference recovery"))))
    (let ((failed (plist-get supertag-discovery--insert-progress :failed)))
      (when failed
        (if (supertag-discovery--failed-link-recovered-p failed)
            (progn
              (push (plist-get failed :target-id)
                    (plist-get supertag-discovery--insert-progress :completed))
              (setf (plist-get supertag-discovery--insert-progress :failed) nil))
          (let ((error-data (plist-get failed :error)))
            (signal (car error-data) (cdr error-data))))))
    (let ((origin-marker supertag-discovery--origin-marker)
          (progress supertag-discovery--insert-progress))
      (supertag-discovery--restore-origin)
      (let ((origin-buffer (current-buffer)))
        (dolist (node-id selected-nodes)
          (unless (member node-id (plist-get progress :completed))
            (let* ((node-data (supertag-node-get node-id))
                   (title (plist-get node-data :title))
                   (clean-title (substring-no-properties
                                 (if (stringp title) title
                                   (prin1-to-string title)))))
              (condition-case error-data
                  (with-current-buffer origin-buffer
                    (goto-char origin-marker)
                    (supertag-discovery--insert-node-link-line node-id clean-title)
                    (push node-id (plist-get progress :completed)))
                (supertag-link-error
                 (setf (plist-get progress :failed)
                       (list :target-id node-id :error error-data))
                 (signal (car error-data) (cdr error-data)))
                ((error quit)
                 (signal (car error-data) (cdr error-data)))))))
        (message "Inserted %d node references" (length selected-nodes))
        (when (buffer-live-p results-buffer) (kill-buffer results-buffer))
        selected-nodes))))

(defun supertag-discovery-get-history (&optional limit)
  "Get Discovery history, optionally limited to LIMIT entries."
  (if limit
      (seq-take supertag-discovery--history limit)
    supertag-discovery--history))

;;; --- Initialization ---

;; Hook to load history on startup
(add-hook 'after-init-hook #'supertag-discovery--load-history)

;;; --- Main Discovery Function ---

(defun supertag-discovery ()
  "Open a readable random sample of projected notes in Discovery."
  (interactive)
  (unless supertag--store
    (message "Supertag store not initialized. Please run supertag sync first.")
    (user-error "Supertag store not initialized"))
  (supertag-discovery--load-history)
  (let* ((origin-point (copy-marker (point) t))
         (origin-mark (when-let* ((position (mark t)))
                        (copy-marker position t)))
         (origin-min (copy-marker (point-min)))
         (origin-max (copy-marker (point-max) t))
         (origin-mark-active mark-active)
         (origin-window (selected-window))
         (origin-configuration (current-window-configuration))
         (buffer (progn
                   (supertag-discovery--register-view)
                   (supertag-view-open 'discovery '(:mode :sample)))))
    (with-current-buffer buffer
      (setq-local supertag-discovery--origin-marker origin-point
                  supertag-discovery--origin-mark-marker origin-mark
                  supertag-discovery--origin-min-marker origin-min
                  supertag-discovery--origin-max-marker origin-max
                  supertag-discovery--origin-mark-active origin-mark-active
                  supertag-discovery--origin-window origin-window
                  supertag-discovery--origin-window-configuration
                  origin-configuration))
    buffer))

(provide 'supertag-discovery)

;;; supertag-discovery.el ends here
