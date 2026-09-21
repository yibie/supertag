;;; supertag-embark.el --- Embark contextual actions -*- lexical-binding: t; -*-

;; Commands: none; integration entrypoint: supertag-embark-setup; optional Embark's embark-act
;; and embark-dwim invoke the registered target finders and action adapters.
;; Dependencies: cl-lib, org, org-element, subr-x, supertag-node,
;; supertag-service-org, supertag-link,
;; supertag-view-node, supertag-view-stream, supertag-concept,
;; supertag-ai; optional embark registration via with-eval-after-load.
;; Tag member writes use supertag-tag through the loaded feature closure.

;;; Commentary:
;; Optional contextual actions.  Discovery is read-only; adapters re-read
;; the object at point and reuse the existing commands and Org writers.

;;; Code:
(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'supertag-node)
(require 'supertag-service-org)
(require 'supertag-link)
(require 'supertag-view-node)
(require 'supertag-view-stream)
(require 'supertag-concept)
(require 'supertag-ai)

(declare-function supertag-service-org-remove-tag "supertag-tag"
                  (node-id tag-name &optional repair-projection))
(defvar embark-target-finders)
(defvar embark-keymap-alist)

;;; 配置
(defcustom supertag-embark-integration t
  "Register Supertag contextual actions when optional Embark is loaded.
Set this to nil before loading Supertag (or restart Emacs).
An already registered integration stays active for the current session."
  :type 'boolean :group 'supertag)

;;; 对象识别（WHERE）
(defun supertag-embark--property-bounds (position property)
  "Return (BEGIN . END) of the PROPERTY run containing POSITION."
  (let ((value (get-text-property position property)))
    (when value
      (cons (if (and (> position (point-min))
                     (equal (get-text-property (1- position) property) value))
                (previous-single-property-change (1+ position) property
                                                 nil (point-min))
              position)
            (next-single-property-change position property nil (point-max))))))

(defun supertag-embark--node-property-target (position property origin)
  "Return a node-reference target for PROPERTY at POSITION from ORIGIN."
  (when-let* ((node-id (get-text-property position property))
              (bounds (supertag-embark--property-bounds position property)))
    (list :kind :node-reference :origin origin :node-id node-id
          :begin (car bounds) :end (cdr bounds))))

(defun supertag-embark--node-target-at (position)
  "Return a target from a semantic node property at POSITION.
Stable identifiers emitted by projection views are recognized here without
requiring those views to duplicate an action keymap.
The properties are checked most-specific-first.  A reference card's title
button carries both `supertag-reference-node-id' (the whole card) and
`supertag-node-id' (its jump link); the card is the context the actions act
on, so it must win there, independent of whether the card's leading ornament
kept its properties.  `:node-link' still covers the view buttons that never
carry the card property (OPEN, relation lines, semantic hits)."
  (or
   (when-let* ((concept-id
                (get-text-property position 'supertag-concept-node-id))
               (bounds (supertag-embark--property-bounds
                        position 'supertag-concept-node-id)))
     (list :kind :concept :origin :concept-mention :node-id concept-id
           :begin (car bounds) :end (cdr bounds)))
   (supertag-embark--node-property-target
    position 'supertag-reference-node-id :reference-card)
   (supertag-embark--node-property-target
    position 'supertag-node-id :node-link)
   (supertag-embark--node-property-target
    position 'supertag-entity-id :view-entity)
   (supertag-embark--node-property-target
    position 'supertag-source-id :mention-source)))

(defun supertag-embark--region-target ()
  "Return the active region in an Org buffer as a target."
  (when (and (derived-mode-p 'org-mode)
             (not buffer-read-only)
             (use-region-p)
             (< (region-beginning) (region-end)))
    (list :kind :region :origin :region
          :begin (region-beginning) :end (region-end))))

(defun supertag-embark--org-link-target ()
  "Return the physical id link at point, or nil for other Org links."
  (when (derived-mode-p 'org-mode)
    (let ((link (org-element-context)))
      (when (and (eq (org-element-type link) 'link)
                 (equal (org-element-property :type link) "id"))
        (list :kind :link :element link
              :raw-link (org-element-property :raw-link link)
              :begin (org-element-property :begin link)
              :end (org-element-property :end link))))))

(defun supertag-embark--org-containing-node-id ()
  "Return the containing heading's existing ID without creating one."
  (when (and (derived-mode-p 'org-mode) (not (org-before-first-heading-p)))
    (save-excursion
      (org-back-to-heading t)
      (org-entry-get nil "ID"))))

(defun supertag-embark--inline-tag-target ()
  "Return the inline tag at point and its exact token bounds."
  (when-let* ((tag (supertag-view-helper-tag-at-point-bounds)))
    (list :kind :tag :tag-id (car tag)
          :node-id (supertag-embark--org-containing-node-id)
          :begin (cadr tag) :end (cddr tag))))

(defun supertag-embark--heading-target ()
  "Return the heading at point without creating an ID."
  (when (and (derived-mode-p 'org-mode) (org-at-heading-p))
    (list :kind :node :node-id (org-entry-get nil "ID")
          :title (let ((title (org-get-heading t t t t)))
                   (if (string-empty-p title) "heading" title))
          :begin (line-beginning-position) :end (line-end-position))))

(defun supertag-embark--view-tag-target ()
  "Return a Node View tag object without writing its projection."
  (when (and (derived-mode-p 'supertag-view-node-mode)
             (eq (get-text-property (point) 'type) :tag))
    (when-let* ((id (get-text-property (point) 'tag-id))
                (bounds (supertag-embark--property-bounds (point) 'tag-id)))
      (list :kind :tag :origin :view-tag :tag-id id
            :node-id (bound-and-true-p supertag-view-node--current-node-id)
            :begin (car bounds) :end (cdr bounds)))))

(defun supertag-embark--require-saved-node (node-id)
  "Reject remote writes when NODE-ID's other visiting buffer has drafts."
  (let ((file (plist-get (supertag-node-get node-id) :file)))
    (unless (and file (file-readable-p file))
      (user-error "Node %s has no readable source file" node-id))
    (when-let* ((buffer (and file (find-buffer-visiting file))))
      (when (and (buffer-modified-p buffer) (not (eq buffer (current-buffer))))
        (user-error "Save %s first; contextual actions do not save unrelated edits"
                    (buffer-name buffer))))))

(defun supertag-embark--stream-tag-target ()
  "Return the Stream tag token object at point."
  (when (derived-mode-p 'supertag-view-stream-mode)
    (when-let* ((bounds (supertag-view-helper-tag-at-point-bounds))
                (id (get-text-property (point) 'supertag-entity-id)))
      (list :kind :tag :origin :stream-tag :tag-id (car bounds)
            :node-id id :begin (cadr bounds) :end (cddr bounds)))))

(defun supertag-embark--containing-node-target ()
  "Return the containing heading without creating an ID or moving point."
  (when (and (derived-mode-p 'org-mode) (not buffer-read-only)
             (not (org-before-first-heading-p)))
    (save-excursion
      (org-back-to-heading t)
      (plist-put (supertag-embark--heading-target) :origin :containing-node))))

(defun supertag-embark--target-at-point ()
  "Return the first supported object at point without writing anything."
  (or (supertag-embark--stream-tag-target)
      (supertag-embark--node-target-at (point))
      (supertag-embark--view-tag-target)
      (supertag-embark--region-target)
      (supertag-embark--org-link-target)
      (supertag-embark--inline-tag-target)
      (supertag-embark--heading-target)
      (supertag-embark--containing-node-target)))

(defun supertag-embark-target-finder ()
  "Return (TYPE STRING BEG . END) for the Supertag object at point."
  (when-let* ((target (supertag-embark--target-at-point)))
    (let* ((kind (plist-get target :kind))
           (id (plist-get target :node-id))
           (label (pcase kind
                    (:node (plist-get target :title))
                    (:tag (concat "#" (plist-get target :tag-id)))
                    (:link (plist-get target :raw-link))
                    (:region (buffer-substring-no-properties
                              (plist-get target :begin) (plist-get target :end)))
                    (_ (or (plist-get (supertag-node-get id) :title) id)))))
      (cl-list* (intern (concat "supertag-" (substring (symbol-name kind) 1)))
             label (plist-get target :begin) (plist-get target :end)))))

;;; 动作适配器（WHAT）
(defun supertag-embark--require-target (kind)
  "Re-read the object at point and require its KIND."
  (let ((target (supertag-embark--target-at-point)))
    (unless (eq (plist-get target :kind) kind)
      (user-error "No Supertag %s at point" kind))
    target))

(defun supertag-embark--materialize (begin end target-id title)
  "Replace BEGIN..END with a physical link to TARGET-ID titled TITLE.
Delegates to the single physical-link writer in supertag-link."

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

(defun supertag-embark--link-concept-occurrence (target)
  "Materialize the concept mention TARGET into a physical link."
  (let ((begin (plist-get target :begin))
        (end (plist-get target :end))
        (node-id (plist-get target :node-id)))
    (unless (and begin end node-id)
      (user-error "No linkable mention at point"))
    (supertag-embark--materialize
     begin end node-id
     (buffer-substring-no-properties begin end))))

(defun supertag-embark-node-view (&optional _target)
  "Run `supertag-view-node' for the node containing point."
  (supertag-embark--require-target :node)
  (call-interactively #'supertag-view-node))

(defun supertag-embark-node-add-tag (&optional _target)
  "Run `supertag-add-tag' for the node containing point."
  (supertag-embark--require-target :node)
  (call-interactively #'supertag-add-tag))

(defun supertag-embark-node-remove-tag (&optional _target)
  "Run `supertag-remove-tag-from-node' for the node containing point."
  (supertag-embark--require-target :node)
  (call-interactively #'supertag-remove-tag-from-node))

(defun supertag-embark-node-add-link (&optional _target)
  "Run `supertag-add-link' for the node containing point."
  (supertag-embark--require-target :node)
  (call-interactively #'supertag-add-link))

(defun supertag-embark-node-delete-link (&optional _target)
  "Run `supertag-delete-link' for the node containing point."
  (supertag-embark--require-target :node)
  (call-interactively #'supertag-delete-link))

(defun supertag-embark-node-move (&optional _target)
  "Run `supertag-move-node' for the node containing point."
  (supertag-embark--require-target :node)
  (call-interactively #'supertag-move-node))

(defun supertag-embark-node-move-and-link (&optional _target)
  "Run `supertag-move-node-and-link' for the node containing point."
  (supertag-embark--require-target :node)
  (call-interactively #'supertag-move-node-and-link))

(defun supertag-embark-node-extract-properties (&optional _target)
  "Propose properties for the node containing point."
  (supertag-embark--require-target :node)
  (supertag-ai-extract-properties))

(defun supertag-embark-node-promote (&optional _target)
  "Run `supertag-promote' for the node containing point."
  (supertag-embark--require-target :node)
  (call-interactively #'supertag-promote))

(defun supertag-embark-tag-view (&optional _target)
  "Show the stream for the tag at point."
  (supertag-view-stream
   (plist-get (supertag-embark--require-target :tag) :tag-id)))

(defun supertag-embark-tag-remove (&optional _target)
  "Remove this tag from its current node through the Org writer."
  (let* ((target (supertag-embark--require-target :tag))
         (id (plist-get target :node-id)))
    (unless id (user-error "No identified node contains this tag"))
    (supertag-embark--require-saved-node id)
    (supertag-service-org-remove-tag id (plist-get target :tag-id))))

(defun supertag-embark-tag-change (&optional _target)
  "Replace this tag in its current node, allowing a new tag name."
  (let* ((target (supertag-embark--require-target :tag))
         (id (plist-get target :node-id)))
    (unless id (user-error "No identified node contains this tag"))
    (supertag-embark--require-saved-node id)
    (let ((new (supertag-ui-read-tag "Change current tag to: "
                                   (supertag-view-api-list-tag-ids) t t)))
      (when (and new (not (string-empty-p new)))
        ;; Re-check after the prompt: the user may have edited meanwhile.
        (supertag-embark--require-saved-node id)
        (supertag-capture-replace-tag-on-node
         id (plist-get target :tag-id) (string-remove-prefix "=" new))))))

(defun supertag-embark-tag-rename (&optional _target)
  "Preview and rename this tag throughout the managed documents."
  (supertag-tag-rename
   (plist-get (supertag-embark--require-target :tag) :tag-id)))

(defun supertag-embark-tag-set-parents (&optional _target)
  "Set the `:extends' parents of this tag."
  (supertag-tag-set-parent
   (plist-get (supertag-embark--require-target :tag) :tag-id)))

(defun supertag-embark-tag-delete (&optional _target)
  "Preview and delete this tag throughout the managed documents."
  (supertag-delete-tag-everywhere
   (plist-get (supertag-embark--require-target :tag) :tag-id)))

(defun supertag-embark-link-open (&optional _target)
  "Open the id link at point."
  (supertag-embark--require-target :link)
  (org-open-at-point))

(defun supertag-embark-link-delete (&optional _target)
  "Delete this complete id link, save, and reproject its source node."
  (let ((target (supertag-embark--require-target :link))
        (id (supertag-embark--org-containing-node-id)))
    (unless id (user-error "No identified node contains this link"))
    (supertag-link--delete-link-element id (plist-get target :element))))

(defun supertag-embark-concept-open (&optional _target)
  "Open the concept mention at point."
  (supertag-embark--require-target :concept)
  (supertag-concept-open-at-point))

(defun supertag-embark-concept-link (&optional _target)
  "Turn this concept mention into a physical link."
  (supertag-embark--link-concept-occurrence
   (supertag-embark--require-target :concept)))

(defun supertag-embark-node-reference-open (&optional _target)
  "Visit the referenced node at point."
  (supertag-goto-node
   (plist-get (supertag-embark--require-target :node-reference) :node-id)))

(defun supertag-embark-region-add-link (&optional _target)
  "Add a link for the active region."
  (supertag-embark--require-target :region)
  (call-interactively #'supertag-add-link))

(defun supertag-embark-node-reference-view (&optional _target)
  "Open Node View for the referenced node at point."
  (supertag-view-node-open
   (plist-get (supertag-embark--require-target :node-reference) :node-id)))

(defun supertag-embark-node-reference-add-tag (&optional _target)
  "Add a tag to the referenced node, creating it after confirmation if needed."
  (let ((id (plist-get (supertag-embark--require-target :node-reference) :node-id)))
    (supertag-embark--require-saved-node id)
    (let ((name (supertag-ui-read-tag "Add tag: " (supertag-view-api-list-tag-ids) t t)))
      (when (and name (not (string-empty-p name)))
        (let* ((token (supertag-sanitize-tag-name (string-remove-prefix "=" name)))
               (path-p (and (string-match-p supertag-tag-path-separator-regexp
                                            token)
                            t))
               (tag-id (and (not path-p)
                            (or (and (supertag-tag-get token) token)
                                (supertag-tag-resolve-occurrence token)))))
          (when (or tag-id
                    (yes-or-no-p (format "Tag '%s' does not exist. Create and add it? " token)))
            ;; Re-check after the prompts, before creating anything or writing.
            (supertag-embark--require-saved-node id)
            (unless tag-id
              (setq tag-id (supertag-tag-ensure token))
              ;; A path writes its leaf token, the only name a node carries.
              (when path-p (setq token (supertag-tag--name tag-id))))
            (supertag-service-org-add-tag id token)))))))

(defun supertag-embark-node-reference-remove-tag (&optional _target)
  "Remove a tag from the referenced node through the Org writer."
  (let* ((id (plist-get (supertag-embark--require-target :node-reference) :node-id)))
    (supertag-embark--require-saved-node id)
    (let ((tag (supertag-ui-select-tag-on-node id)))
      (when tag
        ;; Re-check after the prompt, before the writer runs.
        (supertag-embark--require-saved-node id)
        (supertag-service-org-remove-tag id tag)))))

(defun supertag-embark-region-add-tag (&optional _target)
  "Add a tag to all nodes in the active region using the existing command."
  (supertag-embark--require-target :region)
  (call-interactively #'supertag-add-tag))

(defun supertag-embark-region-promote (&optional _target)
  "Promote the active selection using the existing command's validation."
  (supertag-embark--require-target :region)
  (call-interactively #'supertag-promote))

;;; Embark 注册
(defvar-keymap supertag-embark-node-map
  "RET" #'supertag-embark-node-view
  "v" #'supertag-embark-node-view
  "t" #'supertag-embark-node-add-tag
  "r" #'supertag-embark-node-remove-tag
  "l" #'supertag-embark-node-add-link
  "d" #'supertag-embark-node-delete-link
  "m" #'supertag-embark-node-move
  "M" #'supertag-embark-node-move-and-link
  "p" #'supertag-embark-node-promote
  "x" #'supertag-embark-node-extract-properties)

(defvar-keymap supertag-embark-tag-map
  "RET" #'supertag-embark-tag-view
  "r" #'supertag-embark-tag-remove
  "c" #'supertag-embark-tag-change
  "R" #'supertag-embark-tag-rename
  "D" #'supertag-embark-tag-delete
  "P" #'supertag-embark-tag-set-parents)

(defvar-keymap supertag-embark-link-map
  "RET" #'supertag-embark-link-open
  "d" #'supertag-embark-link-delete)

(defvar-keymap supertag-embark-concept-map
  "RET" #'supertag-embark-concept-open
  "l" #'supertag-embark-concept-link)

(defvar-keymap supertag-embark-node-reference-map
  "RET" #'supertag-embark-node-reference-open
  "v" #'supertag-embark-node-reference-view
  "t" #'supertag-embark-node-reference-add-tag
  "r" #'supertag-embark-node-reference-remove-tag)

(defvar-keymap supertag-embark-region-map
  "RET" #'supertag-embark-region-add-link
  "l" #'supertag-embark-region-add-link
  "t" #'supertag-embark-region-add-tag
  "p" #'supertag-embark-region-promote)

(defun supertag-embark-setup ()
  "Register the optional integration when enabled.
Set `supertag-embark-integration' to nil before loading Supertag
(or restart Emacs).  An already registered integration stays active
for the current session."
  (when supertag-embark-integration
    (add-to-list 'embark-target-finders #'supertag-embark-target-finder)
    (dolist (entry '((supertag-node . supertag-embark-node-map)
                     (supertag-tag . supertag-embark-tag-map)
                     (supertag-link . supertag-embark-link-map)
                     (supertag-concept . supertag-embark-concept-map)
                     (supertag-node-reference . supertag-embark-node-reference-map)
                     (supertag-region . supertag-embark-region-map)))
      (add-to-list 'embark-keymap-alist entry))))

(with-eval-after-load 'embark (supertag-embark-setup))

(provide 'supertag-embark)
;;; supertag-embark.el ends here
