;;; supertag-discovery.el --- Discovery: random reading, searching and reference insertion -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides the Discovery functionality for supertag.
;; It includes:
;; - Card-based Discovery display with navigation and marking
;; - Query history management
;; - Keyword-based search across nodes, tags, and content
;; - Main entry point: `supertag-discovery'

;; Commands: supertag-discovery, supertag-discovery-mode, supertag-discovery-next, supertag-discovery-previous, supertag-discovery-toggle-mark, supertag-discovery-open-node, supertag-discovery-quit, supertag-discovery-search, supertag-discovery-refresh, supertag-discovery-insert-references
;; Dependencies: cl-lib, org, seq, wid-edit, textui, supertag-link, supertag-core-store, supertag-node, supertag-tag, supertag-view-framework

;;; Code:

(require 'cl-lib)
(require 'supertag-link)
(require 'org)
(require 'seq)
(require 'wid-edit)
(require 'textui)
(require 'supertag-core-store) ; For data access
(require 'supertag-node)
(require 'supertag-tag)
(require 'supertag-query)
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
(declare-function supertag-semantic-scores "supertag-semantic" (text))
(defvar supertag-semantic-enabled)

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

(defcustom supertag-discovery-semantic-results 20
  "Most notes a search adds by meaning after the keyword matches.
They are ranked by similarity with no floor, highest first, and each shows
its score; the keyword matches are sorted by the same score."
  :type '(integer 0)
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
    (set-keymap-parent map widget-keymap)
    (define-key map (kbd "TAB") #'widget-forward)
    (define-key map (kbd "<backtab>") #'widget-backward)
    (define-key map (kbd "RET") #'supertag-discovery-open-node)
    (define-key map (kbd "s") #'supertag-discovery-search)
    (define-key map (kbd "g") #'supertag-discovery-refresh)
    (define-key map (kbd "A") #'supertag-view-toggle-archived)
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

(supertag-view-register-modal-state 'supertag-discovery-mode)

;;; --- Search Functions ---

(defun supertag-discovery-find-nodes (keywords)
  "Find nodes matching KEYWORDS, the tokens a search typed.
Plain words are found in the title, body, tags or property values;
tag:NAME, KEY:VALUE and a query expression read as in Stream find, by
`supertag-query-parse-words'."
  (let* ((condition (supertag-query-parse-words (string-join keywords " ")))
         (words (supertag-query-words-of condition)))
    (if (equal words keywords)
        (supertag-discovery--find-by-words keywords)
      (let ((context (and words
                          (mapcar (lambda (pair)
                                    (cons (plist-get (car pair) :id) (cdr pair)))
                                  (supertag-discovery--find-by-words words)))))
        (delq nil
              (mapcar (lambda (id)
                        (when-let* ((node (supertag-node-get id)))
                          (if words
                              (when-let* ((hit (assoc id context)))
                                (cons node (cdr hit)))
                            (cons node nil))))
                      (supertag-query-node-ids condition)))))))

(defun supertag-discovery--find-by-words (keywords)
  "Find nodes matching every one of the plain words KEYWORDS."
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

(defun supertag-discovery--mark-counts (nodes)
  "Return (TOTAL HIDDEN) mark counts relative to visible NODES."
  (let ((visible-ids (mapcar (lambda (pair) (plist-get (car pair) :id)) nodes)))
    (list (length supertag-discovery--marked-nodes)
          (cl-count-if-not (lambda (id) (member id visible-ids))
                           supertag-discovery--marked-nodes))))

(defun supertag-discovery--sample-nodes ()
  "Return a without-replacement random sample of projected nodes."
  (let* ((nodes (vconcat
                 (car (supertag-node-hide-archived
                       (mapcar (lambda (pair) (cons (cdr pair) nil))
                               (supertag-query-nodes
                                (lambda (_id data) data)))
                       #'car))))
         (length (length nodes)))
    (dotimes (index length)
      (let ((other (+ index (random (- length index)))))
        (cl-rotatef (aref nodes index) (aref nodes other))))
    (seq-take (append nodes nil)
              (min (max 1 supertag-discovery-initial-sample-size) length))))

(defun supertag-discovery--semantic-fill (keywords nodes)
  "Return (KEYWORD-PAIRS PAIRS SCORES NOTE) for a search of KEYWORDS.
KEYWORD-PAIRS are NODES, the keyword matches, sorted by similarity with
unscored ones last.  PAIRS are the closest notes NODES lack, highest first,
in the keyword result shape.  SCORES maps node IDs to similarity, and NOTE
says why nothing was scored when semantic search could not run."
  (let ((none (make-hash-table :test 'equal)))
    (cond
     ((<= supertag-discovery-semantic-results 0) (list nodes nil none nil))
     ((not (and (require 'supertag-semantic nil t) supertag-semantic-enabled))
      (list nodes nil none "Meaning search is off (supertag-semantic-enabled)."))
     (t
      (condition-case err
          (let* ((scores (supertag-semantic-scores (string-join keywords " ")))
                 (score-of (lambda (pair) (gethash (plist-get (car pair) :id) scores)))
                 (keyword-ids (mapcar (lambda (pair) (plist-get (car pair) :id)) nodes))
                 others)
            (maphash (lambda (id score)
                       (unless (or (member id keyword-ids)
                                   (and (not supertag-view-include-archived)
                                        (supertag-node-archived-p
                                         (supertag-node-get id))))
                         (push (cons id score) others)))
                     scores)
            (setq others (sort others (lambda (a b)
                                        (if (= (cdr a) (cdr b))
                                            (string-lessp (car a) (car b))
                                          (> (cdr a) (cdr b))))))
            (list (cl-stable-sort (copy-sequence nodes)
                                  (lambda (a b)
                                    (let ((x (funcall score-of a)) (y (funcall score-of b)))
                                      (and x (or (null y) (> x y))))))
                  (mapcar (lambda (entry) (cons (supertag-node-get (car entry)) nil))
                          (seq-take others supertag-discovery-semantic-results))
                  scores nil))
        (error (list nodes nil none
                     (format "Meaning search unavailable: %s"
                             (error-message-string err)))))))))

(defun supertag-discovery--build-view-state (input)
  "Build Discovery view state from INPUT.
A search lists keyword matches first, then notes close in meaning."
  (let* ((mode (or (plist-get input :mode) :sample))
         (keywords (plist-get input :keywords))
         ;; Org keeps archived entries out of daily views; a search says
         ;; how many it left out.
         (found (when (and (eq mode :search) (not (plist-member input :nodes)))
                  (supertag-node-hide-archived
                   (supertag-discovery-find-nodes keywords) #'car)))
         (nodes (cond
                 ((plist-member input :nodes) (plist-get input :nodes))
                 (found (car found))
                 (t (supertag-discovery--sample-nodes))))
         ;; Only plain words carry meaning; tag:NAME, KEY:VALUE and a
         ;; query expression have no sentence to embed.
         (words (and (eq mode :search) keywords
                     (not (plist-member input :nodes))
                     (supertag-query-words-of
                      (supertag-query-parse-words (string-join keywords " ")))))
         (fill (when words
                 (supertag-discovery--semantic-fill words nodes))))
    (list :mode mode :keywords keywords
          :nodes (if fill (append (nth 0 fill) (nth 1 fill)) nodes)
          :keyword-count (length nodes)
          :archived-hidden (or (cdr found) 0)
          :scores (or (nth 2 fill) (make-hash-table :test 'equal))
          :semantic-note (nth 3 fill))))

(defun supertag-discovery--view-mode ()
  "Install the Discovery buffer modes."
  (textui-mode)
  (setq-local textui--render-function #'supertag-discovery--textui-frame
              textui--last-width (max 1 (1- (window-body-width))))
  (add-hook 'change-major-mode-hook #'textui--dispose nil t)
  (supertag-discovery-mode 1)
  (supertag-view-apply-palette-locally 'neon)
  (setq-local supertag-discovery--marked-nodes nil)
  (add-hook 'kill-buffer-hook #'supertag-discovery--release-origin nil t)
  (add-hook 'change-major-mode-hook
            #'supertag-discovery--release-origin nil t))

(defun supertag-discovery--text (value &optional face)
  "Return a width-aware attributed TextUI paragraph for VALUE and FACE."
  (list :type :text :wrap 'greedy :align 'left
        :value (if face (propertize value 'face face) (copy-sequence value))))

(defun supertag-discovery--action (label command &optional node-id)
  "Return a native button for LABEL, COMMAND and optional NODE-ID."
  (list :type 'push-button :format "%[%v%]" :value label :node-id node-id
        :layout (list :focus-id (list command node-id))
        :action (lambda (&rest _)
                  (supertag-view--require-context 'discovery)
                  (when node-id
                    (supertag-discovery--restore-selection node-id)
                    (unless (equal node-id (get-text-property (point) 'node-id))
                      (user-error "Discovery card is no longer available")))
                  (call-interactively command))))

(defun supertag-discovery--textui-card (pair width &optional score)
  "Return a bordered TextUI reading card for PAIR at WIDTH.
SCORE, when given, is the card's similarity to a meaning search."
  (let* ((node (car pair))
         (id (plist-get node :id))
         (title (or (plist-get node :title) "No Title"))
         (body (or (plist-get node :content) ""))
         (marked (member id supertag-discovery--marked-nodes))
         (file (plist-get node :file))
         (tags (supertag-discovery--get-node-tags id))
         ;; TextUI owns wrapping and the outer border.  Rules divide the
         ;; familiar title / metadata / full-body sections inside that border.
         (rule (make-string (max 1 (- width 4)) ?─))
         (children
          (append
           (list (supertag-discovery--text
                  (format "%s %s" (if marked "[X]" "[ ]") title)
                  'supertag-discovery-title)
                 (supertag-discovery--text rule 'supertag-view-mute))
           (when score
             (list (supertag-discovery--text
                    (format "Similarity: %.2f" score) 'supertag-view-mute)))
           (when file
             (list (supertag-discovery--text
                    (concat "File: " (file-name-nondirectory file))
                    'supertag-view-mute)))
           (when tags
             (list (supertag-discovery--text
                    (concat "Tags: " (string-join tags " "))
                    'supertag-view-mute)))
           (list (supertag-discovery--text rule 'supertag-view-mute)
                 (supertag-discovery--text "Body:" 'supertag-view-mute)
                 (supertag-discovery--text
                  (if (string-empty-p (string-trim body)) "Empty body" body))
                 (list :type :flex :direction :row :gap 2 :children
                       (list (supertag-discovery--action " OPEN " #'supertag-discovery-open-node id)
                             (supertag-discovery--action
                              (if marked " UNMARK " " MARK ")
                              #'supertag-discovery-toggle-mark id)))))))
    (dolist (child children)
      (when (eq (plist-get child :type) :text)
        (let ((value (plist-get child :value)))
          (add-text-properties 0 (length value)
                               (list 'node-id id 'supertag-entity-id id
                                     'result-pair pair) value))))
    (list :type :flex :direction :column :border t :padding 1 :gap 0
          :children children)))

(defun supertag-discovery--textui-frame (width)
  "Render the compact Discovery reading page from cached state at WIDTH.
Layout refreshes never resample notes or rerun queries."
  (let* ((state textui-state)
         (nodes (plist-get state :nodes))
         (searchp (eq (plist-get state :mode) :search))
         (keyword-count (or (plist-get state :keyword-count) (length nodes)))
         (scores (plist-get state :scores))
         (note (plist-get state :semantic-note))
         (counts (supertag-discovery--mark-counts nodes))
         (index 0))
    (list
     (list :type :flex :direction :column :gap 1 :children
           (list
            (supertag-discovery--text "Supertag Discovery" 'supertag-discovery-title)
            (list :type :flex :direction :column :gap 0 :children
                  (append
                   (list
                    (supertag-discovery--text
                     (if searchp
                         (concat
                          (format "Found %d matching nodes" keyword-count)
                          (when (> (length nodes) keyword-count)
                            (format ", %d more close in meaning"
                                    (- (length nodes) keyword-count)))
                          (format ". Search: %s"
                                  (string-join (plist-get state :keywords) " ")))
                       (format "Showing %d random notes." (length nodes))))
                    (supertag-discovery--text
                     (format "Marked: %d (%d hidden)" (car counts) (cadr counts))
                     'supertag-view-mute))
                   (when (and searchp note)
                     (list (supertag-discovery--text note 'supertag-view-mute)))
                   (let ((hidden (or (plist-get state :archived-hidden) 0)))
                     (when (and searchp (> hidden 0))
                       (list (supertag-discovery--text
                              (format "%d archived hidden (A shows them)." hidden)
                              'supertag-view-mute))))))
            (list :type :flex :direction (if (< width 70) :column :row) :gap 2
                  :children
                  (list (supertag-discovery--action " SEARCH " #'supertag-discovery-search)
                        (supertag-discovery--action " REFRESH " #'supertag-discovery-refresh)
                        (supertag-discovery--action " INSERT REFERENCES " #'supertag-discovery-insert-references)
                        (supertag-discovery--action " QUIT " #'supertag-discovery-quit)))
            (list :type :flex :direction :column :gap 2
                  :children
                  (if nodes
                      (cl-mapcan
                       (lambda (pair)
                         (prog1
                             (append
                              (when (and searchp (= index keyword-count))
                                (list (supertag-discovery--text
                                       "Close in meaning, without the keywords:"
                                       'supertag-view-mute)))
                              (list (supertag-discovery--textui-card
                                     pair width
                                     (and scores (gethash (plist-get (car pair) :id)
                                                          scores)))))
                           (cl-incf index)))
                       nodes)
                    (list (supertag-discovery--text "No matching nodes found."))))
            (supertag-discovery--text
             "n/p Navigate   SPC Mark   RET Open   s Search   g Refresh   i Insert   q Quit"
             'supertag-view-mute))))))

(defun supertag-discovery--render-view (state)
  "Render STATE through TextUI without querying or resampling."
  (setq-local textui-state state)
  (textui-refresh (current-buffer))
  (goto-char (or (car (supertag-discovery--card-starts)) (point-min)))
  (supertag-discovery-highlight-current))

(defun supertag-discovery--current-node-id ()
  "Return the entity at point, including the card's left border or a button."
  (or (get-text-property (point) 'node-id)
      (when-let* ((widget (widget-at))) (widget-get widget :node-id))
      (let ((next (next-single-property-change (point) 'node-id nil
                                               (line-end-position))))
        (and (< next (line-end-position)) (get-text-property next 'node-id)))))

(defun supertag-discovery--capture-selection ()
  "Return the selected Discovery entity ID."
  (supertag-discovery--current-node-id))

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
  "Highlight the bordered card containing the selected entity."
  (remove-overlays (point-min) (point-max) 'supertag-discovery t)
  (when (get-text-property (point) 'node-id)
    (save-excursion
      (when (re-search-backward "^┌" nil t)
        (let ((start (point)))
          (when (re-search-forward "^└.*┘" nil t)
            (let ((overlay (make-overlay start (line-end-position))))
              (overlay-put overlay 'face 'supertag-discovery-current)
              (overlay-put overlay 'supertag-discovery t)
              (overlay-put overlay 'evaporate t))))))))

(defun supertag-discovery--card-starts ()
  "Return one position per rendered entity, in reading order."
  (let ((position (point-min)) seen starts)
    (while (< position (point-max))
      (let ((id (get-text-property position 'node-id)))
        (when (and id (not (member id seen)))
          (push id seen)
          (push position starts)))
      (setq position (next-single-property-change position 'node-id nil (point-max))))
    (nreverse starts)))

(defun supertag-discovery--move (direction)
  "Move DIRECTION cards, using entity properties rather than borders."
  (let* ((starts (supertag-discovery--card-starts))
         (id (supertag-discovery--current-node-id))
         (current (and id (seq-find (lambda (pos)
                                     (equal id (get-text-property pos 'node-id))) starts)))
         (target (if (> direction 0)
                     (seq-find (lambda (pos) (> pos (or current (point)))) starts)
                   (car (last (seq-filter (lambda (pos) (< pos (or current (point)))) starts))))))
    (when target (goto-char target) (supertag-discovery-highlight-current))))

(defun supertag-discovery-next ()
  "Jump to the next result card."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'discovery))))
  (interactive)
  (supertag-view--require-context 'discovery)
  (supertag-discovery--move 1))

(defun supertag-discovery-previous ()
  "Jump to the previous result card."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'discovery))))
  (interactive)
  (supertag-view--require-context 'discovery)
  (supertag-discovery--move -1))

(defun supertag-discovery-toggle-mark ()
  "Toggle the marked state of the current card and redraw it."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'discovery))))
  (interactive)
  (supertag-view--require-context 'discovery)
  (when-let* ((node-id (supertag-discovery--current-node-id)))
    (if (member node-id supertag-discovery--marked-nodes)
        (setq supertag-discovery--marked-nodes
              (remove node-id supertag-discovery--marked-nodes))
      (push node-id supertag-discovery--marked-nodes))
    ;; Repaint the cached result set: marking must never resample the page.
    (let ((inhibit-read-only t))
      (supertag-discovery--render-view (plist-get supertag-view--instance :state)))
    (supertag-discovery--restore-selection node-id)))

(defun supertag-discovery-open-node ()
  "Open the current node through the shared navigation authority."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'discovery))))
  (interactive)
  (supertag-view--require-context 'discovery)
  (if-let* ((button (widget-at)))
      (widget-apply-action button)
    (when-let* ((id (supertag-discovery--current-node-id)))
      (supertag-ui-navigate-with-recovery id))))

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
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'discovery))))
  (interactive)
  (supertag-view--require-context 'discovery)
  (let ((results-buffer (current-buffer)))
    (supertag-discovery--restore-origin)
    (when (buffer-live-p results-buffer)
      (kill-buffer results-buffer))))

(defun supertag-discovery-search ()
  "Search all nodes; every space-separated token must match.
A plain word is found in the title, body, tags or property values;
tag:NAME and KEY:VALUE ask for a tag or a property, and text starting
with a parenthesis is a query expression, as in Stream find."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'discovery))))
  (interactive)
  (supertag-view--require-context 'discovery)
  (let* ((history (delete-dups
                   (mapcar (lambda (item) (plist-get item :query))
                           supertag-discovery--history)))
         (input (read-string "Search notes (words, tag:NAME, KEY:VALUE or a query): "
                             nil 'history history))
         (keywords (split-string input " " t))
         (_valid (when keywords
                   (condition-case err
                       (supertag-query-validate
                        (supertag-query-parse-words input))
                     (user-error (signal (car err) (cdr err)))
                     (error (user-error "Not a query: %s"
                                        (error-message-string err))))))
         (view-input (if keywords
                         (list :mode :search :keywords keywords)
                       (list :mode :sample :keywords nil))))
    (when keywords (supertag-discovery--update-keyword-frequency input))
    (setf (plist-get supertag-view--instance :input) view-input)
    (supertag-view-refresh)))

(defun supertag-discovery-refresh ()
  "Refresh the current sample or complete search result set."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'discovery))))
  (interactive)
  (supertag-view--require-context 'discovery)
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
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'discovery))))
  (interactive)
  (supertag-view--require-context 'discovery)
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

;; Mode constructors do not open a Runtime-owned view.
(put 'supertag-discovery-mode 'completion-predicate #'ignore)

(provide 'supertag-discovery)

;;; supertag-discovery.el ends here
