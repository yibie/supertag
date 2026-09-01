;;; supertag-ui-act.el --- Context actions at point -*- lexical-binding: t; -*-

;;; Commentary:
;; Embark-style interaction for Supertag.  `supertag-act' recognizes the
;; object at point (or the active region) and offers only the actions
;; that apply to it, with the default action first.  `supertag-act-dwim'
;; runs the default action immediately without a menu.
;;
;; Recognition is read-only: detecting a target never creates Org IDs and
;; never mutates the buffer or the Store.  Targets are transient data of
;; the form (:kind KIND :origin ORIGIN ...); each detector contributes one
;; kind, and `supertag-act--actions' maps a kind to its action table.
;;
;; `supertag-act-mode' is an optional global minor mode that binds
;; `C-c s' to `supertag-act-dwim' and `C-c S' to `supertag-act'.
;;
;; This module replaces the old supertag-smart-key double command
;; (default action on `C-c s', action menu behind `C-u'), which was
;; removed together with its aliases.

;;; Code:

(require 'button)
(require 'org)
(require 'subr-x)
(require 'supertag-view-helper)

(declare-function supertag-add-reference "supertag-ui-commands" ())
(declare-function supertag-add-tag "supertag-ui-commands" (&optional beg end))
(declare-function supertag-delete-tag-everywhere "supertag-ui-commands" (&optional tag-id))
(declare-function supertag-edit-fields "supertag-ui-commands" (&optional node-id tag-id))
(declare-function supertag-goto-node "supertag-services-ui" (node-id &optional other-window))
(declare-function supertag-menu "supertag-menu" ())
(declare-function supertag-node-identity-ensure-at-point "supertag-service-node-identity" (&optional explicit-id))
(declare-function supertag-reference--commit-region "supertag-ui-reference" (beg-marker end-marker target-id title))
(declare-function supertag-reference-insert "supertag-ui-reference" (&optional choose-target))
(declare-function supertag-reference-link-region "supertag-ui-reference" (beg end &optional choose-target))
(declare-function supertag-remove-tag-from-node "supertag-ui-commands" ())
(declare-function supertag-rename-tag "supertag-ui-commands" (&optional tag-id))
(declare-function supertag-schema--edit-field-definition-at-point "supertag-view-schema" ())
(declare-function supertag-service-org-save-and-project-current-node "supertag-service-org" (node-id))
(declare-function supertag-service-org-remove-tag "supertag-service-org" (node-id tag-name))
(declare-function supertag-ui-quick-edit-field "supertag-ui-commands" ())
(declare-function supertag-view-node--focus-view "supertag-view-node" ())
(declare-function supertag-view-node--show-side "supertag-view-node" (&optional node-id))
(declare-function supertag-view-node-edit-at-point "supertag-view-node" ())
(declare-function supertag-view-schema "supertag-view-schema" ())
(declare-function supertag-view-table "supertag-view-table"
                  (data-source &optional columns view-config named-views))
(declare-function supertag-view-table-edit-cell "supertag-view-table" ())
(declare-function supertag-view-table-goto-node "supertag-view-table" ())

;;;----------------------------------------------------------------------
;;; Object recognition
;;;----------------------------------------------------------------------

(defconst supertag-act--supported-kinds
  '(:field-value :field :tag :concept :node-reference :table-cell
    :button :org-link :region :node :command)
  "Target kinds with a complete default action and action table.")

(defconst supertag-act--supported-context-kinds
  '(:field-value :field :tag)
  "View context kinds understood by `supertag-act'.")

(defun supertag-act--supported-target-p (target)
  "Return non-nil when TARGET has a complete action contract."
  (memq (plist-get target :kind) supertag-act--supported-kinds))

(defun supertag-act--context-target-at (position)
  "Return a supported `supertag-context' at POSITION as a target."
  (let* ((context (get-text-property position 'supertag-context))
         (kind (if (consp context)
                   (plist-get context :type)
                 (and context (get-text-property position 'type))))
         (bounds (and kind
                      (supertag-act--property-bounds
                       position 'supertag-context)))
         (current-node-id
          (and (eq kind :tag)
               (boundp 'supertag-view-node--current-node-id)
               (symbol-value 'supertag-view-node--current-node-id))))
    (when (memq kind supertag-act--supported-context-kinds)
      (append
       (if (consp context)
           (append (list :kind kind :origin :supertag-context) context)
         (list :kind kind
               :origin :supertag-context
               :tag-id (get-text-property position 'tag-id)
               :field-name (get-text-property position 'field-name)
               :id (get-text-property position 'id)))
       (when current-node-id (list :node-id current-node-id))
       (when bounds (list :begin (car bounds) :end (cdr bounds)))))))

(defun supertag-act--property-bounds (position property)
  "Return (BEGIN . END) of the PROPERTY run containing POSITION."
  (let ((value (get-text-property position property)))
    (when value
      (cons (if (and (> position (point-min))
                     (equal (get-text-property (1- position) property) value))
                (previous-single-property-change (1+ position) property
                                                 nil (point-min))
              position)
            (next-single-property-change position property nil (point-max))))))

(defun supertag-act--node-property-target (position property origin)
  "Return a node-reference target for PROPERTY at POSITION from ORIGIN."
  (when-let* ((node-id (get-text-property position property))
              (bounds (supertag-act--property-bounds position property)))
    (list :kind :node-reference :origin origin :node-id node-id
          :begin (car bounds) :end (cdr bounds))))

(defun supertag-act--node-target-at (position)
  "Return a target from a semantic node property at POSITION.
Stable identifiers emitted by projection views are recognized here without
requiring those views to duplicate an action keymap."
  (or
   (when-let* ((concept-id
                (get-text-property position 'supertag-concept-node-id))
               (bounds (supertag-act--property-bounds
                        position 'supertag-concept-node-id)))
     (list :kind :concept :origin :concept-mention :node-id concept-id
           :begin (car bounds) :end (cdr bounds)))
   (supertag-act--node-property-target
    position 'supertag-ref-id :table-reference)
   (supertag-act--node-property-target
    position 'supertag-node-id :node-link)
   ;; Table cells also carry `supertag-entity-id'.  Preserve their richer
   ;; edit/open dispatch instead of collapsing every cell to "open node".
   (unless (and (derived-mode-p 'supertag-view-table-mode)
                (get-text-property position 'entity-id)
                (get-text-property position 'col-key))
     (supertag-act--node-property-target
      position 'supertag-entity-id :view-entity))
   (supertag-act--node-property-target
    position 'supertag-reference-node-id :reference-card)
   (supertag-act--node-property-target
    position 'supertag-source-id :mention-source)))

(defun supertag-act--table-target-at (position)
  "Return the Table View cell at POSITION as a target."
  (when (derived-mode-p 'supertag-view-table-mode)
    (let ((entity-id (get-text-property position 'entity-id))
          (column (get-text-property position 'col-key)))
      (when (and entity-id column)
        (let ((bounds (supertag-act--property-bounds position 'entity-id)))
          (list :kind :table-cell :origin :table-view
                :node-id entity-id :column column
                :begin (car bounds) :end (cdr bounds)))))))

(defun supertag-act--button-target-at (position)
  "Return an Emacs button at POSITION as a target."
  (let ((button (button-at position)))
    (when button
      (list :kind :button :origin :emacs-button :button button
            :begin (button-start button) :end (button-end button)))))

(defun supertag-act--region-target ()
  "Return the active region in an Org buffer as a target."
  (when (and (derived-mode-p 'org-mode)
             (use-region-p)
             (< (region-beginning) (region-end)))
    (list :kind :region :origin :region
          :begin (region-beginning) :end (region-end))))

(defun supertag-act--org-link-target ()
  "Return the Org link at point as a target."
  (when (derived-mode-p 'org-mode)
    (let ((element (org-element-context)))
      (when (eq (org-element-type element) 'link)
        (let* ((begin (org-element-property :begin element))
               (end (- (org-element-property :end element)
                       (or (org-element-property :post-blank element) 0)))
               (contents-begin (org-element-property :contents-begin element))
               (contents-end (org-element-property :contents-end element)))
          (list :kind :org-link :origin :org-link
                :type (org-element-property :type element)
                :path (org-element-property :path element)
                :raw-link (org-element-property :raw-link element)
                :text (buffer-substring-no-properties begin end)
                :display-text
                (and contents-begin contents-end
                     (buffer-substring-no-properties
                      contents-begin contents-end))
                :begin begin :end end))))))

(defun supertag-act--org-containing-node-id ()
  "Return the containing Org heading's existing ID without creating one."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (when (org-back-to-heading t)
        (org-entry-get nil "ID")))))

(defun supertag-act--inline-tag-target ()
  "Return the valid inline tag at point as a target."
  (when-let* ((tag-id (supertag-view-helper-get-tag-at-point)))
    (list :kind :tag :origin :inline-tag :tag-id tag-id
          :node-id (supertag-act--org-containing-node-id))))

(defun supertag-act--heading-target ()
  "Return the Org heading at point as a target without creating an ID."
  (when (and (derived-mode-p 'org-mode) (org-at-heading-p))
    (list :kind :node :origin :org-heading :node-id (org-entry-get nil "ID"))))

(defun supertag-act--local-ret-target-at (position)
  "Return a legacy text-property RET command at POSITION as a target."
  (let* ((map (get-text-property position 'keymap))
         (command (and (keymapp map) (lookup-key map (kbd "RET")))))
    (when (commandp command)
      (list :kind :command :origin :local-ret :command command))))

(defun supertag-act--primary-target-at (position)
  "Return the first semantic property target at POSITION."
  (or (supertag-act--context-target-at position)
      (supertag-act--node-target-at position)
      (supertag-act--table-target-at position)
      (supertag-act--button-target-at position)))

(defun supertag-act--target-at-point ()
  "Return a transient semantic target for point, or nil.
This recognizer is read-only; it does not create Org IDs or mutate the
Store.  An active region wins over everything except a precise semantic
property at point."
  (let ((previous (and (> (point) (point-min)) (1- (point)))))
    (let ((target
           (or (supertag-act--primary-target-at (point))
               (supertag-act--region-target)
               (supertag-act--org-link-target)
               (supertag-act--inline-tag-target)
               (supertag-act--heading-target)
               (supertag-act--local-ret-target-at (point))
               (and previous (supertag-act--primary-target-at previous))
               (and previous (supertag-act--local-ret-target-at previous)))))
      (and (supertag-act--supported-target-p target) target))))

;;;----------------------------------------------------------------------
;;; Default actions
;;;----------------------------------------------------------------------

(defun supertag-act--run-default (target)
  "Execute the default action for TARGET."
  (pcase (plist-get target :kind)
    (:field-value
     (unless (fboundp 'supertag-view-node-edit-at-point)
       (require 'supertag-view-node))
     (call-interactively #'supertag-view-node-edit-at-point))
    (:field
     (unless (fboundp 'supertag-schema--edit-field-definition-at-point)
       (require 'supertag-view-schema))
     (call-interactively #'supertag-schema--edit-field-definition-at-point))
    (:tag
     (unless (fboundp 'supertag-view-table)
       (require 'supertag-view-table))
     (supertag-view-table
      (list :type :tag :value (plist-get target :tag-id))))
    ((or :concept :node-reference)
     (unless (fboundp 'supertag-goto-node)
       (require 'supertag-services-ui))
     (supertag-goto-node (plist-get target :node-id)))
    (:table-cell
     (if (eq (plist-get target :column) :title)
         (progn
           (unless (fboundp 'supertag-view-table-goto-node)
             (require 'supertag-view-table))
           (call-interactively #'supertag-view-table-goto-node))
       (unless (fboundp 'supertag-view-table-edit-cell)
         (require 'supertag-view-table))
       (call-interactively #'supertag-view-table-edit-cell)))
    (:button (button-activate (plist-get target :button)))
    (:org-link (org-open-at-point))
    (:region
     (unless (fboundp 'supertag-reference-insert)
       (require 'supertag-ui-reference))
     (call-interactively #'supertag-reference-insert))
    (:node
     (unless (plist-get target :node-id)
       (user-error "Heading has no ID; Node View does not create IDs"))
     (unless (fboundp 'supertag-view-node--show-side)
       (require 'supertag-view-node))
     (supertag-view-node--show-side (plist-get target :node-id))
     (supertag-view-node--focus-view))
    (:command (call-interactively (plist-get target :command)))
    (_ (user-error "No default action for target: %S" target))))

;;;----------------------------------------------------------------------
;;; Action tables
;;;----------------------------------------------------------------------

(defun supertag-act--call (feature command &rest args)
  "Load FEATURE and call COMMAND, passing ARGS when present."
  (unless (fboundp command)
    (require feature))
  (if args
      (apply command args)
    (call-interactively command)))

(defun supertag-act--open-main-menu ()
  "Open the complete Supertag command menu."
  (supertag-act--call 'supertag-menu 'supertag-menu))

(defun supertag-act--materialize (begin end target-id title)
  "Replace BEGIN..END with a physical link to TARGET-ID titled TITLE.
Delegates to the single physical-link writer in supertag-ui-reference."
  (unless (featurep 'supertag-ui-reference)
    (require 'supertag-ui-reference))
  (let ((beg-marker (copy-marker begin))
        (end-marker (copy-marker end t)))
    (unwind-protect
        (if (fboundp 'supertag-reference-materialize)
            (supertag-reference-materialize
             beg-marker end-marker target-id title)
          (supertag-reference--commit-region
           beg-marker end-marker target-id title))
      (set-marker beg-marker nil)
      (set-marker end-marker nil))))

(defun supertag-act--link-concept-occurrence (target)
  "Materialize the concept mention TARGET into a physical link."
  (let ((begin (plist-get target :begin))
        (end (plist-get target :end))
        (node-id (plist-get target :node-id)))
    (unless (and begin end node-id)
      (user-error "No linkable mention at point"))
    (supertag-act--materialize
     begin end node-id
     (buffer-substring-no-properties begin end))))

(defun supertag-act--copy-org-link (target)
  "Copy TARGET's complete Org link markup to the kill ring."
  (let ((text (plist-get target :text)))
    (unless (and (stringp text) (not (string-empty-p text)))
      (user-error "No Org link text is available to copy"))
    (kill-new text)
    (message "Copied Org link: %s" text)))

(defun supertag-act--unlink-org-link (target)
  "Replace bracket Org link TARGET with its displayed text."
  (let* ((begin (plist-get target :begin))
         (end (plist-get target :end))
         (original (plist-get target :text))
         (replacement (or (plist-get target :display-text)
                          (plist-get target :raw-link))))
    (unless (and begin end original replacement
                 (string-prefix-p "[[" original))
      (user-error "This Org link cannot be replaced with displayed text"))
    (unless (equal original
                   (buffer-substring-no-properties begin end))
      (user-error "The Org link changed; invoke the action again"))
    (goto-char begin)
    (delete-region begin end)
    (insert replacement)))

(defun supertag-act--remove-tag-from-current-node (target)
  "Remove TARGET's exact tag from its current source node."
  (let ((node-id (plist-get target :node-id))
        (tag-id (plist-get target :tag-id)))
    (unless (and node-id tag-id)
      (user-error "Cannot determine the current node for this tag"))
    (supertag-act--call 'supertag-service-org
                        'supertag-service-org-remove-tag
                        node-id tag-id)))

(defun supertag-act--create-node-from-heading ()
  "Give the heading at point an ID and project it into the Store."
  (unless (fboundp 'supertag-node-identity-ensure-at-point)
    (require 'supertag-service-node-identity))
  (unless (fboundp 'supertag-service-org-save-and-project-current-node)
    (require 'supertag-service-org))
  (let ((node-id (supertag-node-identity-ensure-at-point)))
    (supertag-service-org-save-and-project-current-node node-id)
    (message "Heading added to Supertag as node %s" node-id)))

(defun supertag-act--target-label (target)
  "Return a concise user-facing label for TARGET."
  (pcase (plist-get target :kind)
    (:tag (format "#%s" (plist-get target :tag-id)))
    ((or :field :field-value)
     (format "%s.%s"
             (or (plist-get target :tag-id) "field")
             (or (plist-get target :field-name) "value")))
    ((or :concept :node-reference)
     (format "node %s" (plist-get target :node-id)))
    (:node (if-let* ((node-id (plist-get target :node-id)))
               (format "node %s" node-id)
             "current heading"))
    (:region "selected text")
    (:table-cell (format "table cell %s" (plist-get target :column)))
    (:org-link (format "%s:%s"
                       (plist-get target :type)
                       (plist-get target :path)))
    (:button "button")
    (:command "command")
    (_ "object")))

(defun supertag-act--actions (target)
  "Return context-relevant action choices for TARGET.
The first action is the default; every label states its consequence."
  (let* ((kind (plist-get target :kind))
         (node-id (plist-get target :node-id))
         (default-label
          (pcase kind
            (:tag "Open tagged nodes")
            (:field-value "Edit field value")
            (:field "Edit field definition")
            (:concept "Open concept node")
            (:node-reference "Open node")
            (:region "Create or link reference (replace selection)...")
            (:table-cell (if (eq (plist-get target :column) :title)
                             "Open source node"
                           "Edit cell"))
            (:button "Activate button")
            (:org-link "Open Org link")
            (:node (if node-id
                       "Open node view"
                     "Add heading to Supertag (create ID)"))
            (:command "Run command")
            (_ "Run default action")))
         (default-action
          (cons (format "%s (default)" default-label)
                (cond
                 ((and (eq kind :node) (not node-id))
                  #'supertag-act--create-node-from-heading)
                 ((eq kind :region)
                  (lambda ()
                    (supertag-act--call 'supertag-ui-reference
                                        'supertag-reference-insert)))
                 (t (apply-partially #'supertag-act--run-default target)))))
         (specific-actions
          (pcase kind
            (:tag
             (let ((tag-id (plist-get target :tag-id)))
               (append
                (when node-id
                  (list
                   (cons "Remove this tag from current node"
                         (apply-partially
                          #'supertag-act--remove-tag-from-current-node
                          target))))
                (list
                 (cons "Open schema"
                       (apply-partially #'supertag-act--call
                                        'supertag-view-schema 'supertag-view-schema))
                 (cons "Rename tag..."
                       (apply-partially #'supertag-act--call
                                        'supertag-ui-commands 'supertag-rename-tag tag-id))
                 (cons "Delete tag everywhere..."
                       (apply-partially #'supertag-act--call
                                        'supertag-ui-commands
                                        'supertag-delete-tag-everywhere tag-id))))))
            (:field-value
             (list
              (cons "Open schema"
                    (apply-partially #'supertag-act--call
                                     'supertag-view-schema 'supertag-view-schema))))
            (:region
             (list
              (cons "Create node and replace selection with its link (no prompt)"
                    (lambda ()
                      (supertag-act--call 'supertag-ui-reference
                                          'supertag-reference-link-region
                                          (plist-get target :begin)
                                          (plist-get target :end))))
              (cons "Add tag to node..."
                    (apply-partially #'supertag-act--call
                                     'supertag-ui-commands 'supertag-add-tag))))
            (:org-link
             (append
              (list
               (cons "Copy Org link markup"
                     (apply-partially #'supertag-act--copy-org-link target)))
              (when (string-prefix-p "[[" (or (plist-get target :text) ""))
                (list
                 (cons "Remove link, keep displayed text"
                       (apply-partially #'supertag-act--unlink-org-link
                                        target))))))
            (:node
             (if (not node-id)
                 ;; An unregistered heading offers only entry points that
                 ;; make sense before the node exists.
                 (when (derived-mode-p 'org-mode)
                   (list
                    (cons "Create or link reference..."
                          (apply-partially #'supertag-act--call
                                           'supertag-ui-reference
                                           'supertag-reference-insert))))
               (append
                (when (fboundp 'supertag-edit-fields)
                  (list
                   (cons "Edit fields (whole page)..."
                         (apply-partially #'supertag-edit-fields node-id))))
                (list
                 (cons "Add tag..."
                       (apply-partially #'supertag-act--call
                                        'supertag-ui-commands 'supertag-add-tag))
                 (cons "Remove tag..."
                       (apply-partially #'supertag-act--call
                                        'supertag-ui-commands 'supertag-remove-tag-from-node))
                 (cons "Quick edit field..."
                       (apply-partially #'supertag-act--call
                                        'supertag-ui-commands 'supertag-ui-quick-edit-field))
                 (cons "Add typed Link..."
                       (apply-partially #'supertag-act--call
                                        'supertag-ui-link 'supertag-link-add))
                 (cons "Remove typed Link..."
                       (apply-partially #'supertag-act--call
                                        'supertag-ui-link 'supertag-link-remove)))
                ;; Physical reference insertion requires an editable Org
                ;; source, so do not offer it from projection buffers.
                (when (derived-mode-p 'org-mode)
                  (list
                   (cons "Create or link reference..."
                         (apply-partially #'supertag-act--call
                                          'supertag-ui-reference
                                          'supertag-reference-insert)))))))
            (:concept
             (append
              ;; Turning a dynamic mention into a physical link needs an
              ;; editable Org buffer and the mention's bounds.
              (when (and (derived-mode-p 'org-mode)
                         (not buffer-read-only)
                         (plist-get target :begin))
                (list
                 (cons "Link this occurrence (write physical link)"
                       (apply-partially #'supertag-act--link-concept-occurrence
                                        target))))
              (list
               (cons "Open node in other window"
                     (apply-partially #'supertag-act--call
                                      'supertag-services-ui 'supertag-goto-node
                                      node-id t)))))
            (:node-reference
             (list
              (cons "Open node in other window"
                    (apply-partially #'supertag-act--call
                                     'supertag-services-ui 'supertag-goto-node
                                     node-id t))))
            (:table-cell
             (unless (eq (plist-get target :column) :title)
               (list
                (cons "Open source node"
                      (apply-partially #'supertag-act--call
                                       'supertag-services-ui 'supertag-goto-node
                                       (plist-get target :node-id)))))))))
    (append (list default-action)
            specific-actions
            (list (cons "All Supertag commands..."
                        #'supertag-act--open-main-menu)))))

;;;----------------------------------------------------------------------
;;; Commands
;;;----------------------------------------------------------------------

(defun supertag-act--act-on-target (target)
  "Read and execute one action for the already recognized TARGET."
  (unless (supertag-act--supported-target-p target)
    (user-error "Unsupported Supertag target: %S" target))
  (let* ((actions (supertag-act--actions target))
         (choice (completing-read
                  (format "Action for %s: "
                          (supertag-act--target-label target))
                  actions nil t nil nil (caar actions)))
         (action (cdr (assoc choice actions))))
    (funcall action)))

;;;###autoload
(defun supertag-act ()
  "Offer the actions that apply to the Supertag object at point.
The default action is listed first; committing the empty selection runs
it.  When point has no recognizable object, open the complete
`supertag-menu' instead of failing."
  (interactive)
  (if-let* ((target (supertag-act--target-at-point)))
      (supertag-act--act-on-target target)
    (supertag-act--open-main-menu)))

;;;###autoload
(defun supertag-act-dwim ()
  "Run the default action for the Supertag object at point immediately.
Signal a `user-error' when point has no recognizable object; use
`supertag-act' for the full action menu and the no-target fallback."
  (interactive)
  (if-let* ((target (supertag-act--target-at-point)))
      (supertag-act--run-default target)
    (user-error "No Supertag target at point")))

(defvar supertag-act-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c s") #'supertag-act-dwim)
    (define-key map (kbd "C-c S") #'supertag-act)
    map)
  "Keymap for `supertag-act-mode'.")

;;;###autoload
(define-minor-mode supertag-act-mode
  "Global minor mode for Supertag actions at point.
`C-c s' runs the default action immediately; `C-c S' opens the context
action menu.  The full command catalog remains available through
`M-x supertag-menu' and from each context action list."
  :global t
  :group 'supertag
  :keymap supertag-act-mode-map)

(provide 'supertag-ui-act)
;;; supertag-ui-act.el ends here
