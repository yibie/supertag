;;; supertag-view-stream.el --- Read nodes as a tag stream -*- lexical-binding: t; -*-

;;; Commentary:

;; Stream View presents every node carrying a tag (or one of its transitive
;; `:extends` descendants) as a chronological title list.  The buffer is a
;; normal View Runtime instance rendered through the existing Widget DSL.


;; Commands: supertag-view-stream-mode, supertag-view-stream-edit-mode, supertag-view-stream,
;; supertag-view-stream-next-node, supertag-view-stream-previous-node,
;; supertag-view-stream-open-node-view, supertag-view-stream-edit,
;; supertag-view-stream-edit-finish, supertag-view-stream-edit-abort, supertag-view-stream-quit.
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

(defgroup supertag-view-stream nil
  "Chronological title views for tagged nodes."
  :group 'supertag)

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
    (define-key map (kbd "g") #'supertag-view-refresh)
    (define-key map (kbd "q") #'supertag-view-stream-quit)
    map)
  "Keymap for `supertag-view-stream-mode'.")

(define-derived-mode supertag-view-stream-mode org-mode "Supertag-Stream"
  "Major mode for browsing tagged nodes as a title stream."
  :keymap supertag-view-stream-mode-map
  (setq buffer-read-only t
        truncate-lines nil))

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

(defun supertag-view-stream--build-state (input)
  "Build data-only Stream state from Runtime INPUT."
  (let ((tag (plist-get input :tag)))
    (unless (and (stringp tag) (not (string-empty-p tag)))
      (user-error "Stream View requires a tag"))
    (let* ((node-ids (supertag-view-api-nodes-by-tag tag t))
           (nodes (supertag-view-api-get-entities :nodes node-ids)))
      (list :tag tag
            :nodes (cl-stable-sort (copy-sequence nodes)
                                   #'supertag-view-stream--node-before-p)))))

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

(defun supertag-view-stream--node-tags (node)
  "Return NODE tags as one display string."
  (mapconcat (lambda (tag) (concat "#" tag))
             (cl-remove-if-not #'stringp (plist-get node :tags))
             " "))

(defun supertag-view-stream--node-widget (node)
  "Return the Widget tree for NODE."
  (let ((tags (supertag-view-stream--node-tags node)))
    (list :type :text
          :key (plist-get node :id)
          :content
          (concat (propertize (supertag-view-stream--node-title node)
                              'font-lock-face
                              'supertag-view-stream-title-face)
                  (if (string-empty-p tags) "" (concat "  " tags))))))

(defun supertag-view-stream--group-nodes-by-date (nodes)
  "Return chronological date groups for sorted NODES."
  (let (groups)
    (dolist (node nodes)
      (let ((date (or (supertag-view-stream--node-date node) "No date")))
        (if (and groups (equal date (caar groups)))
            (setcdr (car groups) (cons node (cdar groups)))
          (push (list date node) groups))))
    (mapcar (lambda (group)
              (cons (car group) (nreverse (cdr group))))
            (nreverse groups))))

(defun supertag-view-stream--date-group-widget (group)
  "Return the Widget tree for date GROUP."
  (list :type :stack
        :spacing 0
        :children
        (cons (list :type :text
                    :content (propertize (car group)
                                         'font-lock-face 'org-level-3))
              (mapcar #'supertag-view-stream--node-widget (cdr group)))))

(defun supertag-view-stream--widgets (state)
  "Return the Stream Widget tree for STATE."
  (let ((nodes (plist-get state :nodes)))
    (if nodes
        (list (list :type :stack :spacing 1
                    :children
                    (mapcar #'supertag-view-stream--date-group-widget
                            (supertag-view-stream--group-nodes-by-date nodes))))
      (list (list :type :text
                  :content (format "No nodes for #%s."
                                   (plist-get state :tag)))))))

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
  (setq header-line-format
        (format " #%s   %d nodes "
                (plist-get state :tag)
                (length (plist-get state :nodes))))
  (font-lock-flush))

(defun supertag-view-stream--buffer-name (input)
  "Return a Stream buffer name for INPUT."
  (format "*Supertag Stream: %s*" (plist-get input :tag)))

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

;;;###autoload
(defun supertag-view-stream (&optional tag)
  "Open a title Stream for TAG and all `:extends` descendants."
  (interactive
   (list (plist-get (supertag-view--read-tag) :value)))
  (unless (and (stringp tag) (not (string-empty-p tag)))
    (user-error "Stream View requires a tag"))
  (supertag-view-stream--register-view)
  (let* ((origin (current-window-configuration))
         (buffer (supertag-view-open
                  'stream (list :tag tag))))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (setq-local supertag-view-stream--origin-window-configuration origin))
    (let ((id (car (supertag-view-stream--node-ids buffer))))
      (when id
        (supertag-view-stream--select-node buffer id)))
    buffer))

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
  (interactive)
  (supertag-view-stream--move 1))

(defun supertag-view-stream-previous-node ()
  "Move to the previous Stream node."
  (interactive)
  (supertag-view-stream--move -1))

(defun supertag-view-stream-open-node-view ()
  "Open Node View for the current Stream node."
  (interactive)
  (let ((id (or (supertag-view-stream--current-node-id)
                (user-error "No Stream node at point"))))
    (supertag-view-node-open id)))

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
  (interactive)
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
    (when (and refresh (buffer-live-p main))
      (supertag-view-refresh main))
    main))

(defun supertag-view-stream-edit-finish ()
  "Save the whole source file, project this node and return to its Stream.
This also saves existing drafts elsewhere in that file.  Failure retains
the edit for retry; a projection failure preserves the saved document."
  (interactive)
  (unless supertag-view-stream-edit-mode
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
  (interactive)
  (unless supertag-view-stream-edit-mode
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
  (interactive)
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

(provide 'supertag-view-stream)

;;; supertag-view-stream.el ends here
