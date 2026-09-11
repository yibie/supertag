;;; supertag-view-tags.el --- Tag Manager: browse and edit the :extends tree -*- lexical-binding: t; -*-

;;; Commentary:

;; Tag Manager presents every Semantic Tag as one `:extends' indented tree,
;; each row showing its node count and any aliases beyond its own ID/name.
;; The buffer is a normal View Runtime instance rendered through the
;; existing Widget DSL, modeled on Stream View.  A Tag whose stored
;; `:extends' points at a Tag that no longer exists renders as a root and
;; is marked "[Orphan]"; Tag Manager never rewrites Org text itself, it
;; only calls the existing Tag commands, which own that responsibility.

;; Commands: supertag-view-tags-mode, supertag-view-tags,
;; supertag-view-tags-open-stream, supertag-view-tags-set-parent,
;; supertag-view-tags-rename, supertag-view-tags-delete,
;; supertag-view-tags-edit-aliases, supertag-view-tags-create-child,
;; supertag-view-tags-quit.
;; Dependencies: cl-lib, subr-x, supertag-tag, supertag-query,
;; supertag-view-framework, supertag-view-stream.
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-tag)
(require 'supertag-query)
(require 'supertag-view-framework)
(require 'supertag-view-stream)

(defgroup supertag-view-tags nil
  "The Tag Manager: an `:extends' tree of every Semantic Tag."
  :group 'supertag)

(defvar-local supertag-view-tags--origin-window-configuration nil
  "Window configuration to restore when the Tag Manager quits.")

;;; --- Rows: `:extends' tree construction ---

(defun supertag-view-tags--extra-aliases (tag id)
  "Return TAG's alias tokens beyond ID and its own `:name'."
  (let ((name (plist-get tag :name)))
    (cl-remove-if (lambda (token) (or (equal token id) (equal token name)))
                  (plist-get tag :aliases))))

(defun supertag-view-tags--build-rows ()
  "Return Tag Manager display rows: plists with :id, :depth and :orphan.
Rows are a depth-first walk of the `:extends' tree, every sibling group
sorted by its Tag `:name'.  A Tag whose `:extends' parent does not exist
is treated as a root and marked `:orphan'."
  (let* ((collection (supertag-store-get-collection :tags))
         (by-id (make-hash-table :test 'equal))
         (children (make-hash-table :test 'equal))
         roots)
    (maphash (lambda (id raw)
               (when raw (puthash id (supertag--ensure-plist raw) by-id)))
             collection)
    (maphash
     (lambda (id tag)
       (let ((parent (plist-get tag :extends)))
         (if (and parent (gethash parent by-id))
             (puthash parent (cons id (gethash parent children)) children)
           (push (cons id (and parent t)) roots))))
     by-id)
    (cl-labels
        ((tag-name (id) (or (plist-get (gethash id by-id) :name) id))
         (sort-ids (ids)
           (sort (copy-sequence ids)
                 (lambda (a b) (string< (tag-name a) (tag-name b)))))
         (walk (id depth orphan)
           (cons (list :id id :depth depth :orphan orphan)
                 (cl-mapcan (lambda (kid) (walk kid (1+ depth) nil))
                            (sort-ids (gethash id children))))))
      (cl-mapcan
       (lambda (entry) (walk (car entry) 0 (cdr entry)))
       (sort (copy-sequence roots)
             (lambda (a b) (string< (tag-name (car a)) (tag-name (car b)))))))))

(defun supertag-view-tags--build-state (_input)
  "Build Tag Manager state, ignoring INPUT: there is only one Tag Manager."
  (list :rows (supertag-view-tags--build-rows)))

;;; --- Rendering ---

(defun supertag-view-tags--row-text (row)
  "Return the display line for ROW."
  (let* ((id (plist-get row :id))
         (tag (supertag-tag-get id))
         (name (or (plist-get tag :name) id))
         (count (length (supertag-find-nodes-by-tag id)))
         (extra (supertag-view-tags--extra-aliases tag id)))
    (concat (make-string (* 2 (plist-get row :depth)) ?\s)
            name
            (format "  (%d 个节点)" count)
            (if extra (format "  别名: %s" (string-join extra ", ")) "")
            (if (plist-get row :orphan) "  [Orphan: missing parent]" ""))))

(defun supertag-view-tags--row-widget (row)
  "Return the Widget tree for ROW."
  (list :type :text :key (plist-get row :id)
        :content (supertag-view-tags--row-text row)))

(defun supertag-view-tags--widgets (state)
  "Return the Tag Manager Widget tree for STATE."
  (let ((rows (plist-get state :rows)))
    (if rows
        (list (list :type :stack :spacing 0
                    :children (mapcar #'supertag-view-tags--row-widget rows)))
      (list (list :type :text :content "No tags yet.")))))

(defun supertag-view-tags--render (state)
  "Render Tag Manager STATE in the current Runtime buffer."
  (supertag-view-widget--render-tree
   (supertag-view-tags--widgets state) state)
  (setq header-line-format
        (format " Tag Manager   %d tags "
                (length (plist-get state :rows))))
  (font-lock-flush))

;;; --- Row lookup and navigation ---

(defun supertag-view-tags--id-at-point ()
  "Return the Tag Manager row ID at point, or nil."
  (let ((position (if (and (eobp) (> (point) (point-min)))
                      (1- (point))
                    (point))))
    (or (get-text-property position 'supertag-widget-key)
        (when (> position (point-min))
          (get-text-property (1- position) 'supertag-widget-key)))))

(defun supertag-view-tags--current-id ()
  "Return the Tag ID at point, or signal `user-error'."
  (or (supertag-view-tags--id-at-point)
      (user-error "No tag at point")))

;;; --- Subscription and view registration ---

(defun supertag-view-tags--subscribe (_input _state refresh)
  "Subscribe the Tag Manager to relevant Store changes using REFRESH."
  (supertag-view-api-subscribe
   :store-changed
   (lambda (path _old-value _new-value)
     (when (and (listp path) (memq (car path) '(:tags :nodes)))
       (funcall refresh)))))

(defun supertag-view-tags--buffer-name (_input)
  "Return the single Tag Manager buffer name."
  "*Supertag Tags*")

(defun supertag-view-tags--register-view ()
  "Register the Tag Manager Adapter when needed."
  (unless (supertag-view-get 'tags)
    (supertag-view-register
     :id 'tags
     :name "Tag Manager"
     :selectable nil
     :buffer-name-fn #'supertag-view-tags--buffer-name
     :mode-fn #'supertag-view-tags-mode
     :state-fn #'supertag-view-tags--build-state
     :render-fn #'supertag-view-tags--render
     :subscribe-fn #'supertag-view-tags--subscribe
     :capture-selection-fn #'supertag-view-widget--capture-selection
     :restore-selection-fn #'supertag-view-widget--restore-selection
     :display-action '(display-buffer-same-window))))

;;; --- Commands ---

;;;###autoload
(defun supertag-view-tags ()
  "Open the Tag Manager: an `:extends' tree of every Semantic Tag."
  (interactive)
  (supertag-view-tags--register-view)
  (let* ((origin (current-window-configuration))
         (buffer (supertag-view-open 'tags nil)))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (setq-local supertag-view-tags--origin-window-configuration origin))
    buffer))

(defun supertag-view-tags-open-stream ()
  "Open Stream View for the Tag Manager row at point."
  (interactive)
  (supertag-view-stream (supertag-view-tags--current-id)))

(defun supertag-view-tags-set-parent ()
  "Set the `:extends' parent of the Tag Manager row at point."
  (interactive)
  (supertag-tag-set-parent (supertag-view-tags--current-id)))

(defun supertag-view-tags-rename ()
  "Rename the Tag Manager row at point throughout the managed documents."
  (interactive)
  (supertag-tag-rename (supertag-view-tags--current-id)))

(defun supertag-view-tags-delete ()
  "Delete the Tag Manager row at point everywhere."
  (interactive)
  (supertag-delete-tag-everywhere (supertag-view-tags--current-id)))

(defun supertag-view-tags-edit-aliases ()
  "Edit the alias list of the Tag Manager row at point."
  (interactive)
  (let* ((id (supertag-view-tags--current-id))
         (tag (supertag-tag-get id))
         (current (supertag-view-tags--extra-aliases tag id))
         (input (read-string
                 (format "Aliases for '%s' (comma-separated): "
                         (or (plist-get tag :name) id))
                 (string-join current ", ")))
         (new-aliases
          (mapcar #'supertag-sanitize-tag-name
                  (split-string input "," t "[ \t\n\r]+"))))
    (supertag-tag-update id (lambda (tag) (plist-put tag :aliases new-aliases)))))

(defun supertag-view-tags-create-child ()
  "Create a new child tag whose `:extends' parent is the row at point."
  (interactive)
  (let* ((parent-id (supertag-view-tags--current-id))
         (parent-name (plist-get (supertag-tag-get parent-id) :name))
         (name (read-string (format "New child tag of '%s': " parent-name))))
    (unless (and name (not (string-empty-p name)))
      (user-error "Tag name cannot be empty"))
    (supertag-tag-create (list :name name :extends parent-id))))

(defun supertag-view-tags-quit ()
  "Quit the Tag Manager and restore its original window configuration."
  (interactive)
  (let ((window-config supertag-view-tags--origin-window-configuration))
    (kill-buffer (current-buffer))
    (when (window-configuration-p window-config)
      (set-window-configuration window-config))))

;;; --- Mode definition ---

(defvar supertag-view-tags-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'supertag-view-tags-open-stream)
    (define-key map (kbd "P") #'supertag-view-tags-set-parent)
    (define-key map (kbd "r") #'supertag-view-tags-rename)
    (define-key map (kbd "D") #'supertag-view-tags-delete)
    (define-key map (kbd "a") #'supertag-view-tags-edit-aliases)
    (define-key map (kbd "c") #'supertag-view-tags-create-child)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "g") #'supertag-view-refresh)
    (define-key map (kbd "q") #'supertag-view-tags-quit)
    map)
  "Keymap for `supertag-view-tags-mode'.")

(define-derived-mode supertag-view-tags-mode special-mode "Supertag-Tags"
  "Major mode for the Supertag Tag Manager.

\\{supertag-view-tags-mode-map}"
  :keymap supertag-view-tags-mode-map
  (setq buffer-read-only t
        truncate-lines t))

(supertag-view-tags--register-view)

(provide 'supertag-view-tags)

;;; supertag-view-tags.el ends here
