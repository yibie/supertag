;;; supertag-view-stream.el --- Read nodes as a tag stream -*- lexical-binding: t; -*-

;;; Commentary:

;; Stream View presents every node carrying a tag (or one of its transitive
;; `:extends` descendants) as a chronological title list.  The buffer is a
;; normal View Runtime instance rendered through the existing Widget DSL.


;; Commands: supertag-view-stream-mode, supertag-view-stream-edit-mode, supertag-view-stream,
;; supertag-view-stream-next-node, supertag-view-stream-previous-node,
;; supertag-view-stream-open-node-view, supertag-view-stream-edit,
;; supertag-view-stream-edit-finish, supertag-view-stream-edit-abort, supertag-view-stream-quit,
;; supertag-view-stream-all, supertag-view-stream-find, supertag-view-stream-up,
;; supertag-view-stream-more.
;; Dependencies: cl-lib, org, subr-x, time-date, supertag-node, supertag-services-sync,
;; supertag-service-org, supertag-view-framework, supertag-view-node.
;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'time-date)
(require 'supertag-node)
(require 'supertag-services-sync)
(require 'supertag-service-org)
(require 'supertag-view-framework)
(require 'supertag-view-node)

;; Tag rows print a Tag's name, never its opaque stable ID.
(declare-function supertag-tag--name "supertag-tag" (tag-id))
(declare-function supertag-query-node-ids "supertag-query" (query-sexp))
(declare-function supertag-query-block--build-condition "supertag-query" ())
(declare-function supertag-query-parse-words "supertag-query" (text))

(defgroup supertag-view-stream nil
  "Chronological title views for tagged nodes."
  :group 'supertag)

(defcustom supertag-view-stream-body-max-lines 6
  "Maximum node body lines shown per Stream row.
The body is the node's stored `:content'; no source file is opened.  A
truncated body ends its last line with `…'.  nil means no limit."
  :type '(choice (const :tag "No limit" nil) (integer :tag "Lines"))
  :group 'supertag-view-stream)

(defcustom supertag-view-stream-max-nodes 200
  "Maximum nodes a Stream shows; the newest are kept.
Drawing a Stream costs time for each node, and a Stream is drawn again
whenever the Store changes.  The header line says how many nodes were left
out, and `supertag-view-stream-more' doubles the number for one Stream.
nil means no limit."
  :type '(choice (const :tag "No limit" nil) (integer :tag "Nodes"))
  :group 'supertag-view-stream)

(defvar supertag-view-stream-arrange-function nil
  "Function that may arrange a Stream in place of the date groups, or nil.
It is called with the INPUT and the STATE a Stream was built from, and
returns STATE, either unchanged or with an `:arrangement':

  (:header WIDGETS :groups ((LABEL (NODE . LINE) ...) ...) :keymap MAP)

WIDGETS are drawn above the groups.  Each group is drawn under LABEL; each
node with its title, LINE after the title when LINE is a string, and its
body, as Stream draws it.  MAP, when non-nil, is the buffer's keymap; it
should have `supertag-view-stream-mode-map' as its parent.  The `:nodes' of
the returned state must be the nodes of the groups in their order, so
moving through the Stream follows what is drawn.")

(defcustom supertag-view-stream-order 'newest-first
  "Order of the nodes in a Stream, by creation time.
`newest-first' puts the latest node at the top, `oldest-first' at the
bottom.  Nodes without a creation time come last either way."
  :type '(choice (const :tag "Newest first" newest-first)
                 (const :tag "Oldest first" oldest-first))
  :group 'supertag-view-stream)

(defface supertag-view-stream-date-face
  '((t :inherit supertag-view-chip2))
  "Face for the creation-day label above a Stream's nodes."
  :group 'supertag-view-stream)

(defface supertag-view-stream-title-face
  '((t :inherit org-level-2 :height 1.15 :weight semi-bold))
  "Face for node titles in Stream View."
  :group 'supertag-view-stream)

(defface supertag-view-stream-current-face
  '((((class color) (background light))
     :background "#F1F5F9" :extend t)
    (((class color) (background dark))
     :background "#334155" :extend t)
    (t :inherit region :extend t))
  "Background face for the selected Stream node."
  :group 'supertag-view-stream)

(defvar-local supertag-view-stream--origin-window-configuration nil
  "Window configuration to restore when the Stream quits.")

(defun supertag-view-stream--group-label (label)
  "Return LABEL as a group's filled label, marked as the start of a group."
  (propertize (concat " " label " ")
              'font-lock-face 'supertag-view-stream-date-face
              'supertag-view-stream-group t))

(defun supertag-view-stream--add-group-surfaces ()
  "Put every group of the current Stream on the surface, `design.md' 1.

A group runs from its label to its last non-blank line.  The surface is an
overlay because Org's fontification would replace a `face' property, and it
starts after the label so the label keeps its fill.  Its priority is below
the selected node's, which stays visible inside it."
  (remove-overlays (point-min) (point-max) 'supertag-view-stream-surface t)
  (let ((labels nil)
        (position (point-min)))
    (while (setq position (text-property-any position (point-max)
                                             'supertag-view-stream-group t))
      (push position labels)
      (setq position (or (next-single-property-change
                          position 'supertag-view-stream-group)
                         (point-max))))
    (setq labels (nreverse labels))
    (cl-loop for (label next) on labels
             do (save-excursion
                  (goto-char (or next (point-max)))
                  (skip-chars-backward " \t\n")
                  (let ((start (progn (save-excursion
                                        (goto-char label)
                                        (line-end-position))))
                        (end (min (point-max) (1+ (line-end-position)))))
                    (when (< start end)
                      (let ((overlay (make-overlay start end)))
                        (overlay-put overlay 'supertag-view-stream-surface t)
                        (overlay-put overlay 'priority -10)
                        (overlay-put overlay 'face
                                     '(:inherit supertag-view-surface
                                       :extend t)))))))))

(defvar-local supertag-view-stream--selection-overlay nil
  "Selection overlay in a Stream buffer.")

(defvar-local supertag-view-stream-edit--return-buffer nil
  "Stream buffer to refresh after an indirect edit finishes.")

(defvar-local supertag-view-stream-edit--node-id nil
  "Node ID being edited in the current indirect buffer.")

(defvar-local supertag-view-stream-edit--session nil
  "Transient source context, rollback baseline and save hook for this edit.")

(defvar supertag-view-stream-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map org-mode-map)
    (define-key map (kbd "n") #'supertag-view-stream-next-node)
    (define-key map (kbd "p") #'supertag-view-stream-previous-node)
    (define-key map (kbd "e") #'supertag-view-stream-edit)
    (define-key map (kbd "v") #'supertag-view-stream-open-node-view)
    (define-key map (kbd "f") #'supertag-view-stream-find)
    (define-key map (kbd "u") #'supertag-view-stream-up)
    (define-key map (kbd "m") #'supertag-view-stream-more)
    (define-key map (kbd "g") #'supertag-view-refresh)
    (define-key map (kbd "A") #'supertag-view-toggle-archived)
    (define-key map (kbd "q") #'supertag-view-stream-quit)
    map)
  "Keymap for `supertag-view-stream-mode'.")

(define-derived-mode supertag-view-stream-mode org-mode "Supertag-Stream"
  "Major mode for browsing tagged nodes as a title stream."
  :keymap supertag-view-stream-mode-map
  (setq buffer-read-only t
        truncate-lines nil))

(supertag-view-register-modal-state 'supertag-view-stream-mode)

(defvar supertag-view-stream-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'supertag-view-stream-edit-finish)
    (define-key map (kbd "C-c C-k") #'supertag-view-stream-edit-abort)
    map)
  "Keymap for `supertag-view-stream-edit-mode'.")

(define-minor-mode supertag-view-stream-edit-mode
  "Minor mode used while editing a narrowed Stream node."
  :lighter " Stream-Edit"
  :keymap supertag-view-stream-edit-mode-map)

(defun supertag-view-stream--created-time (node)
  "Return NODE's creation value as an Emacs time, or nil."
  (let ((value (plist-get node :created-at)))
    (cond
     ((stringp value) (ignore-errors (date-to-time value)))
     ((or (listp value) (integerp value) (floatp value)) value))))

(defun supertag-view-stream--node-before-p (left right)
  "Return non-nil when LEFT should appear before RIGHT."
  (let ((left-time (supertag-view-stream--created-time left))
        (right-time (supertag-view-stream--created-time right))
        (left-id (or (plist-get left :id) ""))
        (right-id (or (plist-get right :id) "")))
    (cond
     ((and left-time right-time)
      (cond
       ((time-less-p left-time right-time) t)
       ((time-less-p right-time left-time) nil)
       (t (string< left-id right-id))))
     (left-time t)
     (right-time nil)
     (t (string< left-id right-id)))))

(defun supertag-view-stream--node-newer-p (left right)
  "Return non-nil when LEFT should appear before RIGHT, newest first.
Nodes without a creation time still come after every dated node."
  (let ((left-time (supertag-view-stream--created-time left))
        (right-time (supertag-view-stream--created-time right)))
    (if (and left-time right-time
             (not (time-equal-p left-time right-time)))
        (time-less-p right-time left-time)
      (supertag-view-stream--node-before-p left right))))

(defun supertag-view-stream--input-ids (input)
  "Return the IDs of the nodes INPUT selects, in no particular order.
INPUT carries `:tag', `:query', both or neither.  A tag selects its nodes
and those of every tag that extends it; a query narrows that set; an INPUT
with neither selects every node."
  (let ((tag (plist-get input :tag))
        (query (plist-get input :query)))
    (cond
     ((and tag query)
      (let ((wanted (make-hash-table :test 'equal)))
        (dolist (id (supertag-query-node-ids query))
          (puthash id t wanted))
        (cl-remove-if-not (lambda (id) (gethash id wanted))
                          (supertag-view-api-nodes-by-tag tag t))))
     (tag (supertag-view-api-nodes-by-tag tag t))
     (query (supertag-query-node-ids query))
     ;; A Store can hold a record under an empty key; it is no node.
     (t (cl-remove-if-not
         (lambda (id) (and (stringp id) (not (string-empty-p id))))
         (supertag-view-api-list-entity-ids '(:type :nodes)))))))

(defun supertag-view-stream--build-state (input)
  "Build data-only Stream state from Runtime INPUT."
  (let ((tag (plist-get input :tag)))
    (when (and (plist-member input :tag)
               (not (and (stringp tag) (not (string-empty-p tag)))))
      (user-error "Stream View requires a tag"))
    (let* ((newest-first (eq supertag-view-stream-order 'newest-first))
           ;; Org keeps archived entries out of daily views.
           (visible (supertag-node-hide-archived
                     (supertag-view-api-get-entities
                      :nodes (supertag-view-stream--input-ids input))))
           (nodes (cl-stable-sort
                   (copy-sequence (car visible))
                   (if newest-first
                       #'supertag-view-stream--node-newer-p
                     #'supertag-view-stream--node-before-p)))
           (total (length nodes))
           (limit (if (plist-member input :limit)
                      (plist-get input :limit)
                    supertag-view-stream-max-nodes)))
      (let ((state
             (list :tag tag
                   :query (plist-get input :query)
                   :total total
                   :archived-hidden (cdr visible)
                   :nodes (cond
                           ((not (and (integerp limit) (> total limit))) nodes)
                           (newest-first (cl-subseq nodes 0 (max limit 0)))
                           (t (last nodes (max limit 0)))))))
        (if supertag-view-stream-arrange-function
            (funcall supertag-view-stream-arrange-function input state)
          state)))))

(defun supertag-view-stream--node-title (node)
  "Return the display title for NODE."
  (let ((title (or (plist-get node :title)
                   (plist-get node :raw-value))))
    (if (and (stringp title) (not (string-empty-p title)))
        title
      "Untitled")))

(defun supertag-view-stream--node-date (node)
  "Return NODE's creation day as one display string, or nil."
  (when-let* ((time (supertag-view-stream--created-time node)))
    (ignore-errors
      (format-time-string "%Y-%m-%d %a" time))))

(defun supertag-view-stream--tag-label (tag)
  "Return TAG's display name, or TAG when it has no Tag record.
TAG is a Tag ID, name or alias; an unresolved token is returned unchanged,
which is the same fallback `supertag-tag--name' uses."
  (if (and (stringp tag) (not (string-empty-p tag)))
      (let ((id (or (and (supertag-tag-get tag) tag)
                    (ignore-errors (supertag-tag-resolve-occurrence tag)))))
        (or (and id (supertag-tag--name id)) tag))
    tag))

(defun supertag-view-stream--node-tags (node)
  "Return NODE tags as one display string, using each Tag's name."
  (mapconcat (lambda (tag) (concat "#" (supertag-view-stream--tag-label tag)))
             (cl-remove-if-not #'stringp (plist-get node :tags))
             " "))

(defun supertag-view-stream--content-lines (content)
  "Return CONTENT's display lines without Org scaffolding.
A property drawer and planning lines are dropped, runs of blank lines
collapse to one, and leading and trailing blank lines are removed.  Return
nil when nothing is left.  CONTENT is the stored `:content'; no file is read."
  (when (and (stringp content) (not (string-empty-p content)))
    (let (lines
          (in-drawer nil))
      (dolist (line (split-string content "\n"))
        (cond
         ((string-match-p "\\`[ \t]*:PROPERTIES:[ \t]*\\'" line)
          (setq in-drawer t))
         (in-drawer
          (when (string-match-p "\\`[ \t]*:END:[ \t]*\\'" line)
            (setq in-drawer nil)))
         ((string-match-p "\\`[ \t]*\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):" line))
         ((string-match-p "\\`[ \t]*\\'" line)
          (unless (equal (car lines) "") (push "" lines)))
         (t (push line lines))))
      (setq lines (nreverse lines))
      (while (and lines (equal (car lines) "")) (pop lines))
      (while (and lines (equal (car (last lines)) "")) (setq lines (butlast lines)))
      lines)))

(defun supertag-view-stream--node-body-lines (node)
  "Return NODE's display body lines, capped by the body defcustom.
Return nil when there is no body; a truncated body ends with `…'."
  (let ((lines (supertag-view-stream--content-lines (plist-get node :content)))
        (max supertag-view-stream-body-max-lines))
    (when (and lines (integerp max) (>= max 0) (> (length lines) max))
      (let ((kept (cl-subseq lines 0 max)))
        (setq lines (if kept
                        (append (butlast kept)
                                (list (concat (car (last kept)) "…")))
                      (list "…")))))
    lines))

(defface supertag-view-stream-line-face
  '((t :inherit supertag-view-excerpt :slant normal))
  "Face of the line an arrangement adds after a node's title."
  :group 'supertag-view-stream)

(defun supertag-view-stream--node-widget (node &optional line)
  "Return the Widget tree for NODE: its title line and its body lines.
LINE, when a string, follows the title and tags.  The whole block carries
one Widget key, so the entity ID, the selection overlay and every row
command cover the title and the body together."
  (let* ((tags (supertag-view-stream--node-tags node))
         (title (concat (propertize (supertag-view-stream--node-title node)
                                    'font-lock-face
                                    'supertag-view-stream-title-face)
                        (if (string-empty-p tags) "" (concat "  " tags))
                        (if (stringp line)
                            (concat "  " (propertize line 'font-lock-face
                                                     'supertag-view-stream-line-face))
                          "")))
         (body (mapcar (lambda (line)
                         (if (string-empty-p line)
                             ""
                           (concat "  " (propertize line 'font-lock-face
                                                     'supertag-view-excerpt))))
                       (supertag-view-stream--node-body-lines node))))
    (list :type :text
          :key (plist-get node :id)
          :content (string-join (cons title body) "\n"))))

(defun supertag-view-stream--group-nodes-by-date (nodes)
  "Return date groups for sorted NODES, in the order NODES are in."
  (let (groups)
    (dolist (node nodes)
      (let ((date (or (supertag-view-stream--node-date node) "No date")))
        (if (and groups (equal date (caar groups)))
            (setcdr (car groups) (cons node (cdar groups)))
          (push (list date node) groups))))
    (mapcar (lambda (group)
              (cons (car group) (nreverse (cdr group))))
            (nreverse groups))))

(defun supertag-view-stream--label (input)
  "Return the text that names the stream INPUT selects.
INPUT is a Runtime input or a state; both carry `:tag' and `:query'."
  (let ((tag (plist-get input :tag))
        (query (plist-get input :query)))
    (cond
     ((and tag query)
      (format "#%s  %S" (supertag-view-stream--tag-label tag) query))
     (tag (concat "#" (supertag-view-stream--tag-label tag)))
     (query (format "%S" query))
     (t "all"))))

(defun supertag-view-stream--date-group-widget (group)
  "Return the Widget tree for date GROUP."
  (list :type :stack
        :spacing 0
        :children
        (cons (list :type :text
                    :content (supertag-view-stream--group-label
                              (upcase (car group))))
              (mapcar #'supertag-view-stream--node-widget (cdr group)))))

(defun supertag-view-stream--arranged-widgets (arrangement)
  "Return the Widget tree of ARRANGEMENT.
See `supertag-view-stream-arrange-function'."
  (list (list :type :stack :spacing 1
              :children
              (append
               (plist-get arrangement :header)
               (mapcar
                (lambda (group)
                  (list :type :stack :spacing 0
                        :children
                        (cons (list :type :text
                                    :content (supertag-view-stream--group-label
                                              (car group)))
                              (mapcar (lambda (row)
                                        (supertag-view-stream--node-widget
                                         (car row) (cdr row)))
                                      (cdr group)))))
                (plist-get arrangement :groups))))))

(defun supertag-view-stream--widgets (state)
  "Return the Stream Widget tree for STATE."
  (let ((nodes (plist-get state :nodes))
        (arrangement (plist-get state :arrangement)))
    (cond
     (arrangement (supertag-view-stream--arranged-widgets arrangement))
     (nodes
        (list (list :type :stack :spacing 1
                    :children
                    (mapcar #'supertag-view-stream--date-group-widget
                            (supertag-view-stream--group-nodes-by-date nodes)))))
     (t
      (list (list :type :text
                  :content (format "No nodes for %s."
                                   (supertag-view-stream--label state))))))))

(defun supertag-view-stream--add-entity-properties ()
  "Copy stable Widget keys to the shared entity ID property."
  (let ((position (point-min)))
    (while (< position (point-max))
      (let* ((key (get-text-property position 'supertag-widget-key))
             (end (or (next-single-property-change
                       position 'supertag-widget-key nil (point-max))
                      (point-max))))
        (when (stringp key)
          (put-text-property position end 'supertag-entity-id key))
        (setq position end)))))

(defun supertag-view-stream--render (state)
  "Render Stream STATE in the current Runtime buffer."
  (when (overlayp supertag-view-stream--selection-overlay)
    (delete-overlay supertag-view-stream--selection-overlay)
    (setq supertag-view-stream--selection-overlay nil))
  (supertag-view-widget--render-tree
   (supertag-view-stream--widgets state) state)
  (supertag-view-stream--add-entity-properties)
  (supertag-view-update-surface)
  (supertag-view-stream--add-group-surfaces)
  ;; From STATE, not the instance: the framework stores STATE on the
  ;; instance only after rendering.
  (use-local-map (or (plist-get (plist-get state :arrangement) :keymap)
                     supertag-view-stream-mode-map))
  (setq header-line-format
        (let ((shown (length (plist-get state :nodes)))
              (total (or (plist-get state :total) 0))
              (hidden (or (plist-get state :archived-hidden) 0)))
          (concat
           (if (> total shown)
               (format " %s   newest %d of %d nodes "
                       (supertag-view-stream--label state) shown total)
             (format " %s   %d %s "
                     (supertag-view-stream--label state) shown
                     (if (= shown 1) "node" "nodes")))
           (when (> hidden 0)
             (format "  %d archived hidden (A) " hidden)))))
  (font-lock-flush))

(defun supertag-view-stream--buffer-name (input)
  "Return a Stream buffer name for INPUT."
  (let ((tag (and (plist-get input :tag)
                  (supertag-view-stream--tag-label (plist-get input :tag))))
        (query (plist-get input :query)))
    (cond
     ((and tag query) (format "*Supertag Stream: %s %S*" tag query))
     (tag (format "*Supertag Stream: %s*" tag))
     (query (format "*Supertag Stream: %S*" query))
     (t "*Supertag Stream*"))))

(defun supertag-view-stream--resolve-main-buffer ()
  "Return the current Stream buffer, or nil outside Stream View."
  (when (derived-mode-p 'supertag-view-stream-mode)
    (current-buffer)))

(defun supertag-view-stream--node-ids (main)
  "Return ordered node IDs from MAIN's current Runtime state."
  (with-current-buffer main
    (mapcar (lambda (node) (plist-get node :id))
            (plist-get (plist-get supertag-view--instance :state) :nodes))))

(defun supertag-view-stream--current-node-id ()
  "Return the stable Stream node ID at point, or nil."
  (let ((position (if (and (eobp) (> (point) (point-min)))
                      (1- (point))
                    (point))))
    (or (get-text-property position 'supertag-entity-id)
        (get-text-property position 'supertag-widget-key)
        (when (> position (point-min))
          (or (get-text-property (1- position) 'supertag-entity-id)
              (get-text-property (1- position) 'supertag-widget-key)))
        (let ((next (next-single-property-change
                     position 'supertag-entity-id nil (point-max))))
          (when (< next (point-max))
            (get-text-property next 'supertag-entity-id))))))

(defun supertag-view-stream--find-entity (id)
  "Return the first position carrying entity ID."
  (let ((position (point-min))
        found)
    (while (and (< position (point-max)) (not found))
      (if (equal (get-text-property position 'supertag-entity-id) id)
          (setq found position)
        (setq position
              (or (next-single-property-change
                   position 'supertag-entity-id nil (point-max))
                  (point-max)))))
    found))

(defun supertag-view-stream--entity-range (id)
  "Return the current buffer range carrying entity ID."
  (when-let* ((start (supertag-view-stream--find-entity id)))
    (cons start
          (or (next-single-property-change
               start 'supertag-entity-id nil (point-max))
              (point-max)))))

(defun supertag-view-stream--highlight (id)
  "Highlight entity ID in the current Stream buffer."
  (when (overlayp supertag-view-stream--selection-overlay)
    (delete-overlay supertag-view-stream--selection-overlay)
    (setq supertag-view-stream--selection-overlay nil))
  (when-let* ((range (and id (supertag-view-stream--entity-range id))))
    (setq supertag-view-stream--selection-overlay
          (make-overlay (car range) (cdr range)))
    (overlay-put supertag-view-stream--selection-overlay
                 'face 'supertag-view-stream-current-face)))

(defun supertag-view-stream--select-node (main id)
  "Select node ID in MAIN and reveal its title."
  (unless (buffer-live-p main)
    (user-error "Stream buffer is not live"))
  (let ((position
         (with-current-buffer main
           (if-let* ((position (supertag-view-stream--find-entity id)))
               (progn
                 (goto-char position)
                 (supertag-view-stream--highlight id)
                 position)
             (user-error "Node %s is no longer in this Stream" id)))))
    (when-let* ((window (get-buffer-window main t)))
      (set-window-point window position)))
  id)

(defun supertag-view-stream--restore-selection (selection)
  "Restore Widget SELECTION in the Stream title list."
  (supertag-view-widget--restore-selection selection)
  (let* ((main (current-buffer))
         (id (or (supertag-view-stream--current-node-id)
                 (car (supertag-view-stream--node-ids main)))))
    (when id
      (supertag-view-stream--select-node main id))))

(defun supertag-view-stream--subscribe (_input _state refresh)
  "Subscribe the Stream to relevant Store changes using REFRESH."
  (supertag-view-api-subscribe
   :store-changed
   (lambda (path _old-value _new-value)
     (when (and (listp path) (memq (car path) '(:nodes :tags)))
       (funcall refresh)))))

(defun supertag-view-stream--register-view ()
  "Register the Stream Adapter when needed."
  (unless (supertag-view-get 'stream)
    (supertag-view-register
     :id 'stream
     :name "Stream"
     :selectable nil
     :buffer-name-fn #'supertag-view-stream--buffer-name
     :mode-fn #'supertag-view-stream-mode
     :state-fn #'supertag-view-stream--build-state
     :render-fn #'supertag-view-stream--render
     :subscribe-fn #'supertag-view-stream--subscribe
     :capture-selection-fn #'supertag-view-widget--capture-selection
     :restore-selection-fn #'supertag-view-stream--restore-selection
     :display-action '(display-buffer-same-window))))

;;; Opening a stream and its substreams

(defun supertag-view-stream--open (input &optional origin)
  "Open the stream INPUT selects and return its buffer.
ORIGIN is the window configuration `supertag-view-stream-quit' restores;
it defaults to the current one."
  (supertag-view-stream--register-view)
  (let* ((origin (or origin (current-window-configuration)))
         (buffer (supertag-view-open 'stream input)))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (setq-local supertag-view-stream--origin-window-configuration origin))
    (let ((id (car (supertag-view-stream--node-ids buffer))))
      (when id
        (supertag-view-stream--select-node buffer id)))
    buffer))

;;;###autoload
(defun supertag-view-stream (&optional tag)
  "Open the stream of every node, newest first.
Narrow it with `supertag-view-stream-find'.  Called from Lisp with TAG,
open the stream of TAG and every tag that extends it."
  (interactive)
  (when (and tag (or (not (stringp tag)) (string-empty-p tag)))
    (user-error "Stream View requires a tag"))
  (supertag-view-stream--open (and tag (list :tag tag))))

(define-obsolete-function-alias 'supertag-view-stream-all
  #'supertag-view-stream "0.3.1")

(defun supertag-view-stream--narrowed (input condition)
  "Return INPUT narrowed by query CONDITION.
Conditions accumulate in one top-level `and', so each narrowing adds one
and `supertag-view-stream-up' removes the last.  One tag asked of the
stream of every node opens that tag's own stream."
  (if (and (null (plist-get input :tag))
           (null (plist-get input :query))
           (eq (car-safe condition) 'tag)
           (stringp (cadr condition))
           (null (cddr condition)))
      (list :tag (cadr condition))
    (let* ((query (plist-get input :query))
           (query (cond
                   ((null query) condition)
                   ((eq (car-safe query) 'and) (append query (list condition)))
                   (t (list 'and query condition))))
           (tag (plist-get input :tag)))
      (append (and tag (list :tag tag)) (list :query query)))))

(defun supertag-view-stream--widened (input)
  "Return the input of the stream INPUT was narrowed from, or `none'.
Dropping the last condition gives the parent; a stream of one tag came
from the stream of every node, which has no parent."
  (let ((tag (plist-get input :tag))
        (query (plist-get input :query)))
    (cond
     ((and (eq (car-safe query) 'and) (cddr query))
      (let ((kept (butlast (cdr query))))
        (append (and tag (list :tag tag))
                (list :query (if (cdr kept) (cons 'and kept) (car kept))))))
     (query (and tag (list :tag tag)))
     (tag nil)
     (t 'none))))

(defun supertag-view-stream--read-condition (guided)
  "Read one query condition.
Typed words, tag:NAME, KEY:VALUE or a query expression by default, as
`supertag-query-parse-words' reads them; GUIDED non-nil builds the
condition step by step from prompts instead."
  (if guided
      (supertag-query-block--build-condition)
    (supertag-query-parse-words
     (read-string "Find (words, tag:NAME, KEY:VALUE or a query): "))))

(defun supertag-view-stream-more ()
  "Show twice as many nodes in the current Stream."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'stream))))
  (interactive)
  (supertag-view--require-context 'stream)
  (let* ((main (or (supertag-view-stream--resolve-main-buffer)
                   (user-error "Not in a Stream View")))
         (instance (buffer-local-value 'supertag-view--instance main))
         (state (plist-get instance :state))
         (shown (length (plist-get state :nodes))))
    (unless (> (or (plist-get state :total) 0) shown)
      (user-error "Every node of this stream is shown"))
    (supertag-view-stream--open
     (plist-put (copy-sequence (plist-get instance :input))
                :limit (* 2 (max shown 1)))
     (buffer-local-value 'supertag-view-stream--origin-window-configuration
                         main))))

;;;###autoload
(defun supertag-view-stream-find (&optional guided)
  "Narrow to the nodes that also match one more query condition.
In a Stream this opens a substream of the stream at hand; elsewhere it
opens a substream of every node.  Type words, each found in the title,
body, tags or property values; tag:NAME or KEY:VALUE to ask for a tag or
a property; or a query expression such as (tag \"prj\").  With prefix
argument GUIDED the condition is built step by step from prompts."
  (interactive "P")
  (let* ((main (supertag-view-stream--resolve-main-buffer))
         (input (and main
                     (plist-get (buffer-local-value 'supertag-view--instance
                                                    main)
                                :input)))
         (origin (and main
                      (buffer-local-value
                       'supertag-view-stream--origin-window-configuration
                       main)))
         (condition (supertag-view-stream--read-condition guided)))
    (supertag-view-stream--open
     (supertag-view-stream--narrowed input condition) origin)))

(defun supertag-view-stream-up ()
  "Open the stream the current one was narrowed from."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'stream))))
  (interactive)
  (supertag-view--require-context 'stream)
  (let* ((main (or (supertag-view-stream--resolve-main-buffer)
                   (user-error "Not in a Stream View")))
         (parent (supertag-view-stream--widened
                  (plist-get (buffer-local-value 'supertag-view--instance main)
                             :input))))
    (when (eq parent 'none)
      (user-error "This is the stream of every node"))
    (supertag-view-stream--open
     parent
     (buffer-local-value 'supertag-view-stream--origin-window-configuration
                         main))))

(defun supertag-view-stream--move (delta)
  "Move DELTA nodes in the current Stream."
  (let* ((main (or (supertag-view-stream--resolve-main-buffer)
                   (user-error "Not in a Stream View")))
         (ids (supertag-view-stream--node-ids main))
         (current (supertag-view-stream--current-node-id))
         (index (or (cl-position current ids :test #'equal) 0)))
    (unless ids
      (user-error "This Stream has no nodes"))
    (supertag-view-stream--select-node
     main (nth (max 0 (min (1- (length ids)) (+ index delta))) ids))))

(defun supertag-view-stream-next-node ()
  "Move to the next Stream node."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'stream))))
  (interactive)
  (supertag-view--require-context 'stream)
  (supertag-view-stream--move 1))

(defun supertag-view-stream-previous-node ()
  "Move to the previous Stream node."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'stream))))
  (interactive)
  (supertag-view--require-context 'stream)
  (supertag-view-stream--move -1))

(defun supertag-view-stream-open-node-view ()
  "Show Node View for the current Stream node, staying in the Stream.
Unlike the other `supertag-view-node-open' callers, this command does not
select the Node View window: `v' updates the side window while the selected
window and point remain in the Stream.  Node View does not follow point in
the Stream; only this command updates it."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'stream))))
  (interactive)
  (supertag-view--require-context 'stream)
  (let ((window (selected-window))
        (id (or (supertag-view-stream--current-node-id)
                (user-error "No Stream node at point"))))
    (supertag-view-node-open id t)
    ;; The side display must not steal focus or point, even when a user
    ;; display policy would select it.
    (when (window-live-p window)
      (select-window window))
    id))

(defun supertag-view-stream--edit-range (node-id level)
  "Return the source range for NODE-ID at LEVEL in the current Org buffer."
  (widen)
  (if (zerop level)
      (cons (point-min) (point-max))
    (unless (supertag-node--goto-location node-id)
      (user-error "Could not locate node %s in its source file" node-id))
    (org-back-to-heading t)
    (let ((start (point))
          (end (save-excursion
                 (outline-next-heading)
                 (point))))
      (cons start end))))

(defun supertag-view-stream-edit ()
  "Edit the current Stream node in an indirect narrowed Org buffer."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'stream))))
  (interactive)
  (supertag-view--require-context 'stream)
  (let* ((main (or (supertag-view-stream--resolve-main-buffer)
                   (user-error "Not in a Stream View")))
         (node-id (or (supertag-view-stream--current-node-id)
                      (user-error "No Stream node at point")))
         (node (supertag-view-api-get-entity :nodes node-id))
         (file (plist-get node :file))
         (level (or (plist-get node :level) 1)))
    (unless (and (stringp file) (file-exists-p file))
      (user-error "Source file for node %s is unavailable" node-id))
    (let* ((base (find-file-noselect file))
           session
           range
           edit)
      (with-current-buffer base
        (unless (derived-mode-p 'org-mode)
          (org-mode))
        (setq session
              (list :base base
                    :save-hook nil
                    :change-hook nil
                    :point (copy-marker (point))
                    :mark (when (mark t) (copy-marker (mark t)))
                    :active mark-active
                    :min (copy-marker (point-min))
                    :max (copy-marker (point-max) t)
                    :dirty (buffer-modified-p)))
        (save-excursion
          (save-restriction
            (setq range (supertag-view-stream--edit-range node-id level))
            (setq session
                  (append session
                          (list :start (copy-marker (car range))
                                :end (copy-marker (cdr range))
                                :text (buffer-substring-no-properties
                                       (car range) (cdr range))
                                :file-text (buffer-substring-no-properties
                                            (point-min) (point-max)))))
            (goto-char (car range))
            (setq edit
                  (clone-indirect-buffer
                   (generate-new-buffer-name
                    (format "*Supertag Edit: %s*"
                            (supertag-view-stream--node-title node)))
                   nil)))))
      (with-current-buffer edit
        (widen)
        (narrow-to-region (car range) (cdr range))
        (goto-char (point-min))
        (org-fold-show-all)
        (setq-local supertag-view-stream-edit--return-buffer main
                    supertag-view-stream-edit--node-id node-id
                    supertag-view-stream-edit--session session)
        (supertag-view-stream-edit-mode 1)
        (add-hook 'after-change-functions
                  #'supertag-view-stream-edit--track-end nil t)
        (add-hook 'kill-buffer-hook #'supertag-view-stream-edit--cleanup nil t))
      ;; Native save-buffer on an indirect buffer saves its base and runs
      ;; the base's after-save-hook.  Install after cloning, so the edit
      ;; does not inherit an extra copy of this session's callback.
      (let ((changed (lambda (&rest _)
                       (when (buffer-live-p edit)
                         ;; Base insertions at the next heading belong outside
                         ;; this edit, including the indirect narrowing boundary.
                         (with-current-buffer edit
                           (narrow-to-region (plist-get session :start)
                                             (plist-get session :end))))))
            (saved (lambda ()
                     (when (buffer-live-p edit)
                       (supertag-view-stream-edit--saved session)))))
        (setf (plist-get session :save-hook) saved
              (plist-get session :change-hook) changed)
        (with-current-buffer base
          (add-hook 'after-save-hook saved nil t)
          (add-hook 'after-change-functions changed nil t)))
      (pop-to-buffer edit)
      edit)))

(defun supertag-view-stream-edit--track-end (beg end _old-length)
  "Include edits made at this edit buffer's end, but not base insertions."
  (let ((boundary (plist-get supertag-view-stream-edit--session :end)))
    (when (and (<= beg boundary) (>= end boundary))
      (set-marker boundary end))))

(defun supertag-view-stream-edit--saved (session)
  "Advance SESSION's cancellation baseline after a successful base save."
  (save-restriction
    (widen)
    (setf (plist-get session :text)
          (buffer-substring-no-properties (plist-get session :start)
                                          (plist-get session :end))
          (plist-get session :file-text)
          (buffer-substring-no-properties (point-min) (point-max))
          (plist-get session :dirty) nil)))

(defun supertag-view-stream-edit--cleanup ()
  "Release this edit's hook and markers, restoring its base context."
  (when-let* ((session supertag-view-stream-edit--session))
    (let ((base (plist-get session :base)))
      (when (buffer-live-p base)
        (with-current-buffer base
          (remove-hook 'after-save-hook (plist-get session :save-hook) t)
          (remove-hook 'after-change-functions (plist-get session :change-hook) t)
          (widen)
          (narrow-to-region (plist-get session :min) (plist-get session :max))
          (goto-char (plist-get session :point))
          (if (plist-get session :mark)
              (set-mark (marker-position (plist-get session :mark)))
            (set-marker (mark-marker) nil))
          (setq mark-active (plist-get session :active)))))
    (dolist (key '(:point :mark :min :max :start :end))
      (when-let* ((marker (plist-get session key)))
        (set-marker marker nil)))
    (setq supertag-view-stream-edit--session nil)))

(defun supertag-view-stream-edit--close (refresh)
  "Close the current Stream edit, refreshing its Stream when REFRESH."
  (let ((edit (current-buffer))
        (main supertag-view-stream-edit--return-buffer)
        (window (get-buffer-window (current-buffer) t)))
    ;; Replace only this edit's display.  Restoring an old window configuration
    ;; would delete unrelated windows the user opened during the session.
    (when (buffer-live-p main)
      (dolist (edit-window (get-buffer-window-list edit nil t))
        (set-window-buffer edit-window main)))
    (kill-buffer edit)
    (when (buffer-live-p main)
      (if (window-live-p window)
          (select-window window)
        (pop-to-buffer main)))
    (when (and refresh (supertag-view--context-p main 'stream))
      (supertag-view-refresh main))
    main))

(defun supertag-view-stream-edit--context-p (buffer)
  "Whether BUFFER is a live indirect Stream editing session."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and supertag-view-stream-edit-mode
              supertag-view-stream-edit--session
              supertag-view-stream-edit--node-id
              (buffer-live-p (buffer-base-buffer))))))

(defun supertag-view-stream-edit-finish ()
  "Save the whole source file, project this node and return to its Stream.
This also saves existing drafts elsewhere in that file.  Failure retains
the edit for retry; a projection failure preserves the saved document."
  (declare (completion (lambda (_command buffer)
                         (supertag-view-stream-edit--context-p buffer))))
  (interactive nil supertag-view-stream-edit-mode)
  (unless (supertag-view-stream-edit--context-p (current-buffer))
    (user-error "Not editing a Stream node"))
  (let ((node-id supertag-view-stream-edit--node-id)
        (base (buffer-base-buffer)))
    (unless (buffer-live-p base)
      (user-error "Stream source buffer is no longer available"))
    (with-current-buffer base
      (save-excursion
        (save-restriction
          (widen)
          (unless (supertag-node--goto-location node-id)
            (user-error "Could not locate node %s in its source file" node-id))
          (supertag-service-org-save-and-project-current-node node-id))))
    (supertag-view-stream-edit--close t)))

(defun supertag-view-stream-edit-abort ()
  "Cancel unsaved session edits, retaining the latest successful native save.
Other changes outside the edit range are preserved.  This command never saves."
  (declare (completion (lambda (_command buffer)
                         (supertag-view-stream-edit--context-p buffer))))
  (interactive nil supertag-view-stream-edit-mode)
  (unless (supertag-view-stream-edit--context-p (current-buffer))
    (user-error "Not editing a Stream node"))
  (let* ((session supertag-view-stream-edit--session)
         (text (plist-get session :text))
         (inhibit-read-only t))
    (save-restriction
      (widen)
      ;; A minimal text replacement retains markers in unchanged text,
      ;; including the base point, mark and restriction boundaries.
      (replace-region-contents (plist-get session :start)
                               (plist-get session :end)
                               (lambda () text))
      (set-buffer-modified-p
       (or (plist-get session :dirty)
           (not (equal (buffer-substring-no-properties (point-min) (point-max))
                       (plist-get session :file-text)))))))
  (supertag-view-stream-edit--close nil))

(defun supertag-view-stream-quit ()
  "Quit the current Stream and restore its original window configuration."
  (declare (completion (lambda (_command buffer)
                         (supertag-view--context-p buffer 'stream))))
  (interactive)
  (supertag-view--require-context 'stream)
  (let* ((main (or (supertag-view-stream--resolve-main-buffer)
                   (user-error "Not in a Stream View")))
         (window-config
          (buffer-local-value
           'supertag-view-stream--origin-window-configuration main)))
    (when (buffer-live-p main)
      (kill-buffer main))
    (when (window-configuration-p window-config)
      (set-window-configuration window-config))))

(supertag-view-stream--register-view)

;; Mode constructors do not open a Runtime-owned view.
(put 'supertag-view-stream-mode 'completion-predicate #'ignore)
(put 'supertag-view-stream-edit-mode 'completion-predicate #'ignore)

(provide 'supertag-view-stream)

;;; supertag-view-stream.el ends here
