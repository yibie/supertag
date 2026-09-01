;;; supertag-concept.el --- Concept mentions for supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; CJK-friendly concept mentions:
;; - promote selected text into a concept node
;; - create one explicit reference from the current node to that concept
;; - render other exact title/alias occurrences as dynamic mentions

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-ops-node)
(require 'supertag-service-node-identity)
(require 'supertag-services-ui)
(require 'supertag-ui-commands)
(require 'supertag-view-helper)

(declare-function supertag-reference-materialize "supertag-ui-reference"
                  (beg-marker end-marker target-id title))

(defgroup supertag-concept nil
  "Concept mention support for Supertag."
  :group 'supertag)

(defcustom supertag-concept-min-term-length 2
  "Minimum character length for a concept title or alias mention."
  :type 'integer
  :group 'supertag-concept)

(defcustom supertag-concept-alias-separator-regexp "[,，;；]"
  "Regexp used to split concept aliases stored in SUPERTAG_ALIASES."
  :type 'regexp
  :group 'supertag-concept)

(defcustom supertag-concept-default-file nil
  "Default Org file used for newly created concept nodes.

When nil, Supertag uses `concepts.org' under the effective sync directory,
then `org-directory', then the current Org file's directory."
  :type '(choice (const :tag "Automatic" nil) file)
  :group 'supertag-concept)

(defcustom supertag-concept-default-level 1
  "Heading level used by the default concept creation policy."
  :type 'integer
  :group 'supertag-concept)

(defcustom supertag-concept-create-target-function
  #'supertag-concept-default-create-target
  "Function that chooses where a new concept node is created.

The function receives TITLE and returns a plist containing `:file', optional
`:position', and optional `:level'.  A nil position means append at end of
file.  The default policy never prompts; users can replace it with an adapter
for Org-roam, Denote, or another capture system."
  :type 'function
  :group 'supertag-concept)

(defconst supertag-concept--marker-property :SUPERTAG_CONCEPT)
(defconst supertag-concept--aliases-property :SUPERTAG_ALIASES)
(defconst supertag-concept--org-marker-property "SUPERTAG_CONCEPT")
(defconst supertag-concept--org-aliases-property "SUPERTAG_ALIASES")

(defface supertag-concept-mention-face
  '((((class color) (background light))
     :foreground "#4A3100"
     :background "#FFF3B0")
    (((class color) (background dark))
     :foreground "#FFE6A3"
     :background "#3A2F0B")
    (t
     :weight bold))
  "Face for dynamic concept mentions.
This intentionally does not inherit from `org-link'."
  :group 'supertag-concept)

(defvar-local supertag-concept--entries nil
  "Buffer-local concept entries used by font-lock.
Each entry is (TERM . NODE-ID).")

(defvar-local supertag-concept--font-lock-keywords nil
  "Buffer-local font-lock keywords for concept mentions.")

(defvar supertag-concept-mention-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'supertag-concept-open-at-point)
    (define-key map [mouse-1] #'supertag-concept-open-at-mouse)
    map)
  "Keymap used on concept mention text.")

(defun supertag-concept--node-prop (node prop)
  "Return PROP from NODE, accepting plist or hash-table NODE data."
  (cond
   ((hash-table-p node) (gethash prop node))
   ((listp node) (plist-get node prop))
   (t nil)))

(defun supertag-concept--node-properties (node)
  "Return NODE user properties as a plist."
  (let ((props (supertag-concept--node-prop node :properties)))
    (cond
     ((hash-table-p props)
      (let (plist)
        (maphash (lambda (k v) (setq plist (plist-put plist k v))) props)
        plist))
     ((listp props) props)
     (t nil))))

(defun supertag-concept--truthy-p (value)
  "Return non-nil when VALUE marks a node as a concept."
  (member (downcase (format "%s" value)) '("t" "true" "yes" "1" "concept")))

(defun supertag-concept-node-p (node)
  "Return non-nil when NODE is marked as a concept node."
  (or (supertag-concept--truthy-p (supertag-concept--node-prop node :concept))
      (supertag-concept--truthy-p
       (plist-get (supertag-concept--node-properties node)
                  supertag-concept--marker-property))))

(defun supertag-concept--split-aliases (value)
  "Split alias VALUE into a clean alias list."
  (cond
   ((null value) nil)
   ((listp value)
    (cl-remove-if #'string-empty-p
                  (mapcar (lambda (v) (string-trim (format "%s" v))) value)))
   ((stringp value)
    (cl-remove-if #'string-empty-p
                  (mapcar #'string-trim
                          (split-string value supertag-concept-alias-separator-regexp t))))
   (t nil)))

(defun supertag-concept-node-aliases (node)
  "Return aliases for concept NODE."
  (supertag-concept--split-aliases
   (plist-get (supertag-concept--node-properties node)
              supertag-concept--aliases-property)))

(defun supertag-concept--valid-term-p (term)
  "Return non-nil when TERM is worth matching as a mention."
  (and (stringp term)
       (not (string-empty-p (string-trim term)))
       (>= (length (string-trim term)) supertag-concept-min-term-length)))

(defun supertag-concept--term-index ()
  "Return a hash table mapping each concept term to all matching node IDs."
  (let ((index (make-hash-table :test 'equal)))
    (dolist (pair (supertag-query-nodes
                   (lambda (_id node) (supertag-concept-node-p node))))
      (let ((node (cdr pair)))
        (dolist (term (cons (or (supertag-concept--node-prop node :title)
                                (supertag-concept--node-prop node :raw-value))
                            (supertag-concept-node-aliases node)))
          (let ((clean (and term (string-trim (format "%s" term)))))
            (when (supertag-concept--valid-term-p clean)
              (cl-pushnew (car pair) (gethash clean index) :test #'equal))))))
    index))

(defun supertag-concept-entries ()
  "Return unambiguous concept entries as (TERM . NODE-ID), longest first."
  (let ((index (supertag-concept--term-index))
        entries)
    (maphash
     (lambda (term ids)
       (when (null (cdr ids))
         (push (cons term (car ids)) entries)))
     index)
    (sort entries
          (lambda (a b)
            (> (length (car a)) (length (car b)))))))

(defun supertag-concept--regexp (entries)
  "Build a longest-first exact phrase regexp from ENTRIES."
  (when entries
    (regexp-opt (mapcar #'car entries))))

(defun supertag-concept--ignored-org-context-p (pos)
  "Return non-nil when POS is not prose suitable for a concept mention."
  (save-excursion
    (goto-char pos)
    (let ((type (org-element-type (org-element-context))))
      (or (memq type '(link code verbatim comment comment-block keyword
                       node-property property-drawer drawer src-block
                       example-block table table-row table-cell fixed-width))
          (org-in-commented-heading-p)))))

(defun supertag-concept--valid-match-p ()
  "Return non-nil when the current concept match should be rendered."
  (let ((pos (max (point-min) (or (match-beginning 0) (point-min)))))
    (and (derived-mode-p 'org-mode)
         (not (supertag-concept--ignored-org-context-p pos)))))

(defun supertag-concept--match-handler ()
  "Font-lock handler for concept mention matches."
  (let ((start (match-beginning 0))
        (end (match-end 0)))
    (when (and start end
               (<= (point-min) start)
               (<= end (point-max))
               (save-match-data
                 (supertag-concept--valid-match-p)))
      (let* ((term (buffer-substring-no-properties start end))
             (node-id (cdr (assoc term supertag-concept--entries))))
        (when node-id
          (add-text-properties
           start end
           `(supertag-concept-node-id ,node-id
             mouse-face highlight
             help-echo ,(format "Mention: %s -> RET jump" term)
             keymap ,supertag-concept-mention-map))
          'supertag-concept-mention-face)))))

(defun supertag-concept--refresh-font-lock-keywords ()
  "Rebuild concept font-lock keywords in the current buffer."
  (when supertag-concept--font-lock-keywords
    (font-lock-remove-keywords nil supertag-concept--font-lock-keywords))
  (setq supertag-concept--entries (supertag-concept-entries))
  (let ((regexp (supertag-concept--regexp supertag-concept--entries)))
    (setq supertag-concept--font-lock-keywords
          (when regexp
            `((,regexp (0 (supertag-concept--match-handler) t)))))
    (when supertag-concept--font-lock-keywords
      (font-lock-add-keywords nil supertag-concept--font-lock-keywords t))))

;;;###autoload
(define-minor-mode supertag-concept-link-mode
  "Highlight known concept titles and aliases as dynamic mentions."
  :lighter " ST-Concept"
  :group 'supertag-concept
  (if supertag-concept-link-mode
      (progn
        (make-local-variable 'font-lock-extra-managed-props)
        (dolist (prop '(keymap help-echo mouse-face supertag-concept-node-id))
          (cl-pushnew prop font-lock-extra-managed-props))
        (supertag-concept--refresh-font-lock-keywords)
        (supertag-view-helper--refresh-fontification))
    (when supertag-concept--font-lock-keywords
      (font-lock-remove-keywords nil supertag-concept--font-lock-keywords))
    (setq supertag-concept--font-lock-keywords nil
          supertag-concept--entries nil)
    (supertag-view-helper--refresh-fontification)))

;;;###autoload
(defun supertag-concept-refresh ()
  "Refresh concept mentions in the current buffer."
  (interactive)
  (when supertag-concept-link-mode
    (supertag-concept--refresh-font-lock-keywords)
    (supertag-view-helper--refresh-fontification)))

(defun supertag-concept--refresh-all-buffers ()
  "Refresh concept mention highlighting in all enabled buffers."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when supertag-concept-link-mode
        (supertag-concept-refresh)))))

(defun supertag-concept--node-id-at-point ()
  "Return concept node id at point, checking point and previous char."
  (or (get-text-property (point) 'supertag-concept-node-id)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'supertag-concept-node-id))))

;;;###autoload
(defun supertag-concept-open-at-point ()
  "Open the concept mention at point."
  (interactive)
  (let ((node-id (supertag-concept--node-id-at-point)))
    (unless node-id
      (user-error "No concept mention at point"))
    (supertag-goto-node node-id)))

;;;###autoload
(defun supertag-concept-open-at-mouse (event)
  "Open the concept mention clicked by mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (supertag-concept-open-at-point))

(defun supertag-concept--find-concept-id-by-term (term)
  "Return the unique concept node ID whose title or alias is TERM."
  (let ((ids (gethash term (supertag-concept--term-index))))
    (cond
     ((null ids) nil)
     ((null (cdr ids)) (car ids))
     (t (user-error "Concept term is ambiguous: %s" term)))))

(defun supertag-concept-find-by-term (term)
  "Return the unique concept node ID whose title or alias is TERM."
  (supertag-concept--find-concept-id-by-term term))

(defun supertag-concept--find-node-id-by-title (title)
  "Return the unique heading node ID whose title exactly equals TITLE."
  (let (matches)
    (dolist (pair (supertag-query-nodes
                   (lambda (id node)
                     (let ((level (supertag-concept--node-prop node :level)))
                       (and (integerp level) (> level 0)
                            (member title
                                    (delq nil (list (supertag-concept--node-prop node :title)
                                                    (supertag-concept--node-prop node :raw-value)))))))))
      (push (car pair) matches))
    (cond
     ((null matches) nil)
     ((null (cdr matches)) (car matches))
     (t (user-error "Multiple heading nodes share title: %s" title)))))

(defun supertag-concept--mark-node (node-id)
  "Persistently mark heading NODE-ID as a concept and re-sync it."
  (let ((node (supertag-node-get node-id))
        (marker (supertag-ui--find-node-marker node-id)))
    (unless (and node (> (or (plist-get node :level) 0) 0))
      (user-error "Concept target is not a heading node: %s" node-id))
    (unless marker
      (user-error "Cannot locate concept target: %s" node-id))
    (with-current-buffer (marker-buffer marker)
      (unless (derived-mode-p 'org-mode)
        (org-mode))
      (save-excursion
        (goto-char marker)
        (unless (org-at-heading-p)
          (user-error "Concept target is not an Org heading: %s" node-id))
        (org-entry-put nil supertag-concept--org-marker-property "t")
        (save-buffer)
        (unless (supertag-node-sync-at-point)
          (user-error "Failed to sync concept target: %s" node-id)))))
  node-id)

(defun supertag-concept--automatic-base-directory ()
  "Return the best default directory for new concept nodes."
  (let ((sync-directory (car (supertag-sync--effective-directories))))
    (file-name-as-directory
     (expand-file-name
      (or sync-directory
          (and (boundp 'org-directory)
               (stringp org-directory)
               org-directory)
          (and buffer-file-name (file-name-directory buffer-file-name))
          default-directory)))))

(defun supertag-concept-default-create-target (_title)
  "Return the non-interactive default target for a new concept node."
  (list :file
        (if supertag-concept-default-file
            (expand-file-name supertag-concept-default-file)
          (expand-file-name "concepts.org"
                            (supertag-concept--automatic-base-directory)))
        :position nil
        :level supertag-concept-default-level))

(defun supertag-concept-read-create-target (_title)
  "Interactively choose a target for a new concept node."
  (let* ((file (expand-file-name
                (read-file-name "Create concept in file: "
                                (supertag-concept--automatic-base-directory)
                                nil nil "concepts.org")))
         (insert-info (and (file-exists-p file)
                           (supertag-ui-select-insert-position file))))
    (if insert-info
        (list :file file
              :position (plist-get insert-info :position)
              :level (plist-get insert-info :level))
      (list :file file :position nil :level supertag-concept-default-level))))

(defun supertag-concept--normalize-create-target (title target)
  "Validate and normalize creation TARGET for TITLE."
  (let* ((resolved (or target
                       (funcall supertag-concept-create-target-function title)))
         (file (plist-get resolved :file))
         (position (plist-get resolved :position))
         (level (or (plist-get resolved :level)
                    supertag-concept-default-level)))
    (unless (and (stringp file) (not (string-empty-p file)))
      (user-error "Concept target must provide a file"))
    (unless (and (integerp level) (> level 0))
      (user-error "Concept target level must be a positive integer"))
    (unless (or (null position) (integer-or-marker-p position))
      (user-error "Concept target position must be nil, an integer, or a marker"))
    (list :file (expand-file-name file)
          :position position
          :level level)))

(defun supertag-concept--create-node (title &optional target)
  "Create a new concept node titled TITLE at optional TARGET.
Return the new node ID."
  (let* ((resolved (supertag-concept--normalize-create-target title target))
         (target-file (plist-get resolved :file))
         (insert-pos (plist-get resolved :position))
         (insert-level (plist-get resolved :level))
         (node-id (supertag-node-identity-new)))
    (make-directory (file-name-directory target-file) t)
    (with-current-buffer (find-file-noselect target-file)
      (unless (derived-mode-p 'org-mode)
        (org-mode))
      (org-with-wide-buffer
       (goto-char (if insert-pos
                      (min (point-max) (max (point-min) insert-pos))
                    (point-max)))
       (unless (or (bobp) (looking-back "\n" 1))
         (insert "\n"))
       (let ((heading-pos (point)))
         (insert (format "%s %s\n"
                         (make-string insert-level ?*) title))
         (goto-char heading-pos)
         (supertag-node-identity-ensure-at-point node-id)
         (org-entry-put nil supertag-concept--org-marker-property "t")
         (save-buffer)
         (unless (supertag-node-sync-at-point)
           (user-error "Failed to sync new concept: %s" title)))))
    node-id))

(defun supertag-concept--ensure-node (title &optional target)
  "Return a concept node ID for TITLE, using optional creation TARGET."
  (or (supertag-concept--find-concept-id-by-term title)
      (when-let* ((existing (supertag-concept--find-node-id-by-title title)))
        (supertag-concept--mark-node existing))
      (supertag-concept--create-node title target)))

(defun supertag-concept-ensure-node (title &optional target)
  "Return a concept node ID for TITLE, creating it at optional TARGET."
  (supertag-concept--ensure-node title target))

;;;###autoload
(defun supertag-promote-concept (beg end)
  "Promote selected text from BEG to END into a concept mention.
Creates or reuses a concept node, then materializes the selected text as a
physical Org ID link so the normal document projector derives the reference."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (user-error "Select text to promote as a concept")))
  (unless (and beg end (< beg end))
    (user-error "Select text to promote as a concept"))
  (unless (derived-mode-p 'org-mode)
    (user-error "Concept promotion only works in Org buffers"))
  (let* ((title (string-trim
                 (replace-regexp-in-string
                  "[ \t\n\r]+" " "
                  (buffer-substring-no-properties beg end)))))
    (when (string-empty-p title)
      (user-error "Selected text is empty"))
    (unless (fboundp 'supertag-reference-materialize)
      (require 'supertag-ui-reference))
    (let ((beg-marker (copy-marker beg))
          (end-marker (copy-marker end t)))
      (unwind-protect
          (let ((source-id
                 (save-excursion
                   (goto-char beg-marker)
                   (supertag-ui--get-containing-node-at-point))))
            ;; Validate the source before creating a concept, while markers keep
            ;; the selected region stable if synchronization inserts an ID.
            (supertag-ui--ensure-node-synced source-id)
            (let ((concept-id (supertag-concept--ensure-node title)))
              (if (equal source-id concept-id)
                  (message "Already inside concept '%s'; no link added" title)
                (supertag-reference-materialize
                 beg-marker end-marker concept-id title))
              (supertag-concept--refresh-all-buffers)
              (unless (equal source-id concept-id)
                (message "Promoted concept link: %s" title))
              concept-id))
        (set-marker beg-marker nil)
        (set-marker end-marker nil)))))

(provide 'supertag-concept)
;;; supertag-concept.el ends here
