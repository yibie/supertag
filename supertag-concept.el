;;; supertag-concept.el --- Concept mentions for supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; CJK-friendly concept mentions:
;; - promote selected text into a concept node
;; - create one explicit reference from the current node to that concept
;; - render other exact title/alias occurrences as dynamic mentions


;; Commands: supertag-promote, supertag-concept-open-at-point, supertag-concept-open-at-mouse, supertag-concept-link-mode.
;; Dependencies: cl-lib, org, subr-x, supertag-core-store, supertag-node, supertag-service-org,
;; supertag-query, supertag-tag, supertag-services-sync, supertag-link, supertag-mention.
;; Shared Link retry/materializer, nine ServiceOrg helpers and two Sync readers retain their
;; owners. Node cache listener preparation runs after Sync loads.
;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-service-org)
(require 'supertag-query)
(require 'supertag-tag)
(require 'supertag-services-sync)
(supertag-node--prepare-cache-listener)
(require 'supertag-link)
(require 'supertag-mention)


(autoload 'supertag-service-org--move-root "supertag-service-org")
(declare-function supertag-service-org--move-root "supertag-service-org" (source))
(autoload 'supertag-service-org--move-snapshot "supertag-service-org")
(declare-function supertag-service-org--move-snapshot "supertag-service-org" (buffer))
(autoload 'supertag-service-org--move-disk-text "supertag-service-org")
(declare-function supertag-service-org--move-disk-text "supertag-service-org" (file))
(autoload 'supertag-service-org--move-save "supertag-service-org")
(declare-function supertag-service-org--move-save "supertag-service-org" (snapshot))
(autoload 'supertag-service-org--retry-move-projection "supertag-service-org")
(declare-function supertag-service-org--retry-move-projection "supertag-service-org" (source-file target-file &rest other-files))
(autoload 'supertag-service-org--move-notify-git "supertag-service-org")
(declare-function supertag-service-org--move-notify-git "supertag-service-org" (source target &rest other-buffers))
(autoload 'supertag-service-org--adjust-subtree-level "supertag-service-org")
(declare-function supertag-service-org--adjust-subtree-level "supertag-service-org" (content from-level to-level))
(autoload 'supertag-service-org--validate-create-content "supertag-service-org")
(declare-function supertag-service-org--validate-create-content "supertag-service-org" (content))
(autoload 'supertag-service-org--preflight-create "supertag-service-org")
(declare-function supertag-service-org--preflight-create "supertag-service-org" (headline content))
(autoload 'supertag--strip-inline-tags "supertag-services-sync")
(declare-function supertag--strip-inline-tags "supertag-services-sync" (headline))
(autoload 'supertag--render-org-headline "supertag-services-sync")
(declare-function supertag--render-org-headline "supertag-services-sync" (level title tags file node &optional style tag-position))

(declare-function supertag-reference-materialize "supertag-link"
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

(defconst supertag-concept--aliases-property :SUPERTAG_ALIASES)

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

(defun supertag-concept-node-p (node)
  "Return non-nil when heading NODE belongs to a current template target."
  (let ((file (supertag-concept--node-prop node :file)))
    (and (let ((id (supertag-concept--node-prop node :id)))
           (and (stringp id) (not (string-empty-p id))))
         (stringp file) (> (or (supertag-concept--node-prop node :level) 0) 0)
         (member (file-truename file) (supertag-template-target-files)))))

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
  "Return current template-file terms mapped only to projected Org IDs."
  (let ((index (make-hash-table :test 'equal)))
    (dolist (pair (supertag-query-nodes
                  (lambda (_ node) (supertag-concept-node-p node))))
      (let* ((node (cdr pair))
             (id (supertag-concept--node-prop node :id)))
        (dolist (term (cons (supertag-concept--node-prop node :title)
                           (supertag-concept-node-aliases node)))
          (when (supertag-concept--valid-term-p term)
            (cl-pushnew id (gethash term index) :test #'equal)))))
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
          (org-in-commented-heading-p)
          (save-restriction
            ;; Font-lock can narrow to one line, hiding an enclosing Embed.
            (widen)
            (supertag-mention-service--inside-range-p
             (- pos (point-min)) (1+ (- pos (point-min)))
             (supertag-mention-service--protected-ranges
              (buffer-substring-no-properties (point-min) (point-max)))))))))

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

(defun supertag-concept-refresh ()
  "Refresh concept mentions in the current buffer."
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

(defun supertag-concept--preview-choice (title candidates)
  "Show actual CANDIDATES and explicitly choose reuse or fresh TITLE."
  (if (null candidates)
      nil
    (let ((preview (generate-new-buffer "*Promote candidates*"))
          (choices (list (cons "n  Create new" nil))))
      (unwind-protect
          (save-window-excursion
            (with-current-buffer preview
              (insert (format "Promote %s: choose explicitly; no title-based merge.\n\n" title))
              (cl-loop for candidate in candidates for i from 1 do
                       (let ((label (format "%d  Reuse %s (%s)" i
                                            (plist-get candidate :title)
                                            (plist-get candidate :file))))
                         (push (cons label candidate) choices)
                         (insert label "\n" (plist-get candidate :text) "\n")))
              (special-mode))
            (display-buffer preview)
            (cdr (assoc (completing-read "Promote: reuse previewed node or create new: "
                                        choices nil t)
                        choices)))
        (kill-buffer preview)))))

;;; Promote candidate, target and retained-source stages

(define-error 'supertag-promote-error
  "Promote retained document state; retry the reported stage")

(defun supertag-service-org-promote-candidate (source)
  "Read one explicit SOURCE heading, an ID or live marker, without writing.
Reuse the accepted Move location authority; this does not search ID-less files."
  (let* ((root (supertag-service-org--move-root source))
         (buffer (plist-get root :buffer)))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen) (goto-char (plist-get root :begin))
          (unless (derived-mode-p 'org-mode) (user-error "Promote requires Org"))
          (list :node-id (plist-get root :id) :file (file-truename buffer-file-name)
                :tick (buffer-chars-modified-tick) :marker (copy-marker (point))
                :title (supertag--strip-inline-tags (org-element-at-point))
                :text (buffer-substring-no-properties (point) (plist-get root :end))))))))

(defun supertag-service-org--promote-validate-candidate (candidate)
  "Return CANDIDATE's live marker only if its original heading is unchanged."
  (let ((marker (plist-get candidate :marker)))
    (unless (and (markerp marker) (buffer-live-p (marker-buffer marker)))
      (user-error "Heading candidate is no longer live; select it again"))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char marker)
          (unless (and (derived-mode-p 'org-mode) buffer-file-name
                       (equal (file-truename buffer-file-name) (plist-get candidate :file))
                       (org-at-heading-p)
                       (or (plist-get candidate :node-id)
                           (equal (plist-get candidate :tick) (buffer-chars-modified-tick)))
                       (equal (org-entry-get nil "ID") (plist-get candidate :node-id))
                       (equal (plist-get candidate :text)
                              (buffer-substring-no-properties
                               (point) (save-excursion (org-end-of-subtree t t) (point)))))
            (user-error "Heading changed during selection; select it again")))))
    marker))

(defun supertag-service-org--promote-release-candidates (candidates)
  "Release transient location markers owned by CANDIDATES."
  (dolist (candidate candidates)
    (when-let* ((marker (plist-get candidate :marker))) (set-marker marker nil))))

(defun supertag-service-org--promote-text (text id tags properties)
  "Prepare retained subtree TEXT with ID, additive TAGS and missing PROPERTIES."
  (with-temp-buffer
    (insert text)
    (delay-mode-hooks (org-mode))
    (goto-char (point-min))
    (supertag-node-identity-ensure-at-point id)
    (org-set-tags (delete-dups (append (org-get-tags nil t) tags)))
    (dolist (property properties)
      (unless (org-entry-get nil (upcase (car property)) nil)
        (org-entry-put nil (upcase (car property)) (cdr property))))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun supertag-service-org-promote-target (candidate template)
  "Apply TEMPLATE to explicit reuse CANDIDATE and return its stable ID.
Only this Promote path retains a durable target after later source failure.
Public Move and its compensation contract are unchanged.  Existing body and
properties survive; only missing properties and additive tags are applied."
  (let* ((preset (supertag-template-normalize template))
         (content (supertag-service-org--validate-create-content
                   (list :properties (plist-get preset :properties)
                         :body (plist-get preset :body))))
         (tags (plist-get preset :tags))
         (file (plist-get preset :target-file))
         (marker (supertag-service-org--promote-validate-candidate candidate))
         (source (marker-buffer marker))
         (target (find-file-noselect file))
         (same (eq source target))
         (source-snapshot (supertag-service-org--move-snapshot source))
         (target-snapshot (if same source-snapshot
                            (supertag-service-org--move-snapshot target)))
         (text (plist-get candidate :text))
         (id (plist-get candidate :node-id))
         start end level prepared target-start target-end state)
    (unless (cl-every (lambda (tag) (not (string-match-p "[[:space:]#:]" tag))) tags)
      (user-error "Template tags must be safe Org tags"))
    (supertag-service-org--preflight-create
     (supertag--render-org-headline 1 "Preflight" tags file nil) content)
    (with-current-buffer source
      (save-excursion
        (save-restriction
          (widen) (goto-char marker)
          (setq start (copy-marker (point))
                end (copy-marker (save-excursion (org-end-of-subtree t t) (point)))
                level (org-outline-level)))))
    ;; Validate identities before allocating a new one or changing either file.
    (let (ids)
      (with-temp-buffer
        (insert text) (delay-mode-hooks (org-mode))
        (org-map-entries
         (lambda ()
           (when-let* ((value (org-entry-get nil "ID")))
             (when (member value ids) (user-error "Duplicate ID in reused subtree"))
             (push value ids)))))
      (dolist (buffer (delete-dups (list source target)))
        (with-current-buffer buffer
          (save-excursion (save-restriction
            (widen)
            (org-map-entries
             (lambda ()
               (when (and (member (org-entry-get nil "ID") ids)
                          (not (and (eq buffer source)
                                    (>= (point) start) (< (point) end))))
                 (user-error "Reused subtree identity also exists outside its source")))))))))
    (setq id (or id (supertag-node-identity-new))
          prepared (supertag-service-org--promote-text
                    text id tags (plist-get content :properties)))
    (with-current-buffer target
      (save-excursion
        (save-restriction
          (widen)
          (if same
              (progn
                (goto-char start)
                (setq target-start (copy-marker (point)))
                ;; Keep body and context markers attached to unchanged text.
                (supertag-node-identity-ensure-at-point id)
                (org-set-tags (delete-dups (append (org-get-tags nil t) tags)))
                (dolist (property (plist-get content :properties))
                  (unless (org-entry-get nil (upcase (car property)) nil)
                    (org-entry-put nil (upcase (car property)) (cdr property))))
                (org-end-of-subtree t t))
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (setq target-start (copy-marker (point)))
            (insert (supertag-service-org--adjust-subtree-level prepared level 1))
            (unless (bolp) (insert "\n")))
          (setq target-end (copy-marker (point))
                prepared (buffer-substring-no-properties target-start target-end)))))
    (setq state (list :stage :target-save :node-id id :target target-snapshot
                      :source source-snapshot :same same :begin start :end end
                      :original text :title (plist-get candidate :title)
                      :target-begin target-start :target-end target-end :retained prepared))
    (setf (plist-get state :target-text)
          (with-current-buffer target
            (save-restriction (widen)
              (buffer-substring-no-properties (point-min) (point-max)))))
    (supertag-service-org-retry-promote-target state)))

(defun supertag-service-org--promote-retained-text (id)
  "Read the unique ID subtree in the current Org buffer, without writing."
  (save-excursion
    (save-restriction
      (widen)
      (let (locations)
        (org-map-entries
         (lambda ()
           (when (equal (org-entry-get nil "ID") id) (push (point) locations))))
        (unless (= 1 (length locations))
          (user-error "Retained Promote target is missing or duplicated; reconcile before retry"))
        (goto-char (car locations))
        (buffer-substring-no-properties
         (point) (save-excursion (org-end-of-subtree t t) (point)))))))

(defun supertag-service-org--promote-check-saved-buffer (snapshot)
  "Require SNAPSHOT's whole live buffer to match its durable file."
  (with-current-buffer (plist-get snapshot :buffer)
    (save-restriction
      (widen)
      (unless (and (verify-visited-file-modtime (current-buffer))
                   (not (buffer-modified-p))
                   (equal (encode-coding-string
                           (buffer-substring-no-properties (point-min) (point-max))
                           buffer-file-coding-system)
                          (supertag-service-org--move-disk-text (plist-get snapshot :file))))
        (user-error "Promote file has unsaved or changed text; reconcile before retry: %s"
                    (plist-get snapshot :file))))))

(defun supertag-service-org--promote-check-retained-target (state)
  "Reject retry if STATE's retained target changed or is no longer durable."
  (with-current-buffer (plist-get (plist-get state :target) :buffer)
    (save-restriction
      (widen)
      (unless (and (verify-visited-file-modtime (current-buffer))
                   (equal (plist-get state :retained)
                          (supertag-service-org--promote-retained-text
                           (plist-get state :node-id))))
        (user-error "Retained Promote target changed; reconcile it before retry"))
      (if (eq (plist-get state :stage) :target-save)
          (unless (equal (plist-get state :target-text)
                         (buffer-substring-no-properties (point-min) (point-max)))
            (user-error "Promote target draft changed; reconcile it before retry"))
        (supertag-service-org--promote-check-saved-buffer (plist-get state :target))))))

(defun supertag-service-org--promote-check-old-location (state)
  "Reject new user edits to STATE's pending old-location replacement."
  (with-current-buffer (plist-get (plist-get state :source) :buffer)
    (save-restriction
      (widen)
      (unless (and (verify-visited-file-modtime (current-buffer))
                   (equal (plist-get state :source-text)
                          (buffer-substring-no-properties (point-min) (point-max))))
        (user-error "Old location changed; reconcile it before retry")))))

(defun supertag-service-org-promote-target-guard (id &optional file)
  "Capture ID's retained target for the remaining Promote source stages.
FILE can identify a newly created target whose projection is still pending.
This transient read state owns no document or persistent recovery registry."
  (let ((marker (if file
                    (with-current-buffer (find-file-noselect file) (point-marker))
                  (supertag-node-location-find id))))
    (unless marker (user-error "Promote target cannot be located"))
    (unwind-protect
        (with-current-buffer (marker-buffer marker)
          (list :node-id id :target (list :buffer (current-buffer) :file buffer-file-name)
                :target-text (save-restriction (widen)
                               (buffer-substring-no-properties (point-min) (point-max)))
                :retained (supertag-service-org--promote-retained-text id)))
      (set-marker marker nil))))

(defun supertag-service-org-promote-source-state (marker)
  "Read the complete live source at MARKER for exact Promote retry checking."
  (with-current-buffer (marker-buffer marker)
    (save-restriction
      (widen)
      (list :buffer (current-buffer) :file buffer-file-name
            :text (buffer-substring-no-properties (point-min) (point-max))))))

(defun supertag-service-org-promote-check-source-stage (guard source &optional saved)
  "Validate retained GUARD and SOURCE before a Promote source stage.
SOURCE is an exact allowed draft snapshot; SAVED also requires it on disk.
An operation's own pending source draft may share the target file, but the
retained target subtree must still match both live text and durable Org."
  (let* ((target (plist-get guard :target))
         (id (plist-get guard :node-id))
         (retained (plist-get guard :retained)))
    (with-current-buffer (plist-get target :buffer)
      (unless (and (verify-visited-file-modtime (current-buffer))
                   (equal retained (supertag-service-org--promote-retained-text id)))
        (user-error "Retained Promote target changed; reconcile before retry")))
    (with-temp-buffer
      (insert-file-contents (plist-get target :file))
      (delay-mode-hooks (org-mode))
      (unless (equal retained (supertag-service-org--promote-retained-text id))
        (user-error "Retained Promote target is not durable; reconcile before retry")))
    (unless (eq (plist-get target :buffer) (plist-get source :buffer))
      (supertag-service-org--promote-check-saved-buffer target))
    (when source
      (with-current-buffer (plist-get source :buffer)
        (save-restriction
          (widen)
          (unless (and (verify-visited-file-modtime (current-buffer))
                       (equal (plist-get source :text)
                              (buffer-substring-no-properties (point-min) (point-max))))
            (user-error "Promote source draft changed; reconcile before retry"))))
      (when saved (supertag-service-org--promote-check-saved-buffer source)))))

(defun supertag-service-org-promote-call-source (guard source function arguments)
  "Call the existing source FUNCTION with ARGUMENTS under Promote GUARD.
Check after all source save hooks, before the writer can project live text.
This scope adds validation only; FUNCTION remains the document writer."
  (with-current-buffer (plist-get source :buffer)
    (let ((after-save-hook
           (append (if (memq t after-save-hook)
                       (append (remove t after-save-hook) (default-value 'after-save-hook))
                     after-save-hook)
                   (list (lambda ()
                           (supertag-service-org-promote-check-source-stage
                            guard (supertag-service-org-promote-source-state (point-marker)) t))))))
      (apply function arguments))))

(defun supertag-service-org-retry-promote-target (state)
  "Resume exact Promote STATE without replaying completed document edits.
Save failures retain drafts.  Once target save succeeds it is never rolled
back due to a later old-location or projection failure."
  (condition-case cause
      (progn
        (when (eq (plist-get state :stage) :target-save)
          (supertag-service-org--promote-check-retained-target state)
          (supertag-service-org--move-save (plist-get state :target))
          (setf (plist-get state :stage)
                (if (plist-get state :same) :target-project :old-location-edit)))
        (when (eq (plist-get state :stage) :old-location-edit)
          (supertag-service-org--promote-check-retained-target state)
          (with-current-buffer (plist-get (plist-get state :source) :buffer)
            (save-excursion
              (save-restriction
                (widen)
                (unless (and (verify-visited-file-modtime (current-buffer))
                             (equal (plist-get state :original)
                                    (buffer-substring-no-properties
                                     (plist-get state :begin) (plist-get state :end))))
                  (user-error "Old location changed; retained target is safe, reconcile before retry"))
                (goto-char (plist-get state :begin))
                (delete-region (point) (plist-get state :end))
                (insert (org-link-make-string
                         (concat "id:" (plist-get state :node-id))
                         (plist-get state :title)) "\n")
                (setf (plist-get state :source-text)
                      (buffer-substring-no-properties (point-min) (point-max))))))
          (setf (plist-get state :stage) :old-location-save))
        (when (eq (plist-get state :stage) :old-location-save)
          (supertag-service-org--promote-check-retained-target state)
          (supertag-service-org--promote-check-old-location state)
          (supertag-service-org--move-save (plist-get state :source))
          (setf (plist-get state :stage) :target-project))
        (when (eq (plist-get state :stage) :target-project)
          (supertag-service-org--promote-check-retained-target state)
          (unless (plist-get state :same)
            (supertag-service-org--promote-check-old-location state))
          (supertag-service-org--promote-check-saved-buffer (plist-get state :source))
          (supertag-service-org--retry-move-projection
           (plist-get (plist-get state :source) :file)
           (plist-get (plist-get state :target) :file))
          (setf (plist-get state :stage) :done)
          (dolist (key '(:begin :end :target-begin :target-end))
            (set-marker (plist-get state key) nil))
          (supertag-service-org--move-notify-git
           (plist-get (plist-get state :source) :buffer)
           (plist-get (plist-get state :target) :buffer)))
        (plist-get state :node-id))
    ((error quit)
     (signal 'supertag-promote-error
             (list :stage (plist-get state :stage) :node-id (plist-get state :node-id)
                   :file (plist-get (plist-get state
                                              (if (memq (plist-get state :stage)
                                                        '(:old-location-edit :old-location-save))
                                                  :source :target)) :file)
                   :retry #'supertag-service-org-retry-promote-target
                   :retry-args (list state) :cause cause)))))

;;; Promote continuation and transient recovery

(defun supertag-reference-promote--failure (state payload phase cause)
  "Expose PHASE of STATE through the existing transient reference recovery."
  (when (and (eq phase :target) (not (plist-get state :candidate))
             (not (plist-get state :fresh-target-guard)) (plist-get payload :node-id))
    (setf (plist-get state :fresh-target-guard)
          (supertag-service-org-promote-target-guard
           (plist-get payload :node-id) (plist-get payload :file))))
  (setf (plist-get state :pending-retry) (list payload phase))
  (supertag-reference-signal-retryable-error
   (or (plist-get payload :stage) phase)
   (or (plist-get payload :source-id) (plist-get state :source-id))
   (or (plist-get state :target-id) (plist-get payload :node-id))
   (plist-get payload :file)
   #'supertag-reference-promote--retry (list state payload phase) cause))

(defun supertag-reference-promote--retry (state payload phase)
  "Resume STATE's latest failed stage, including from an earlier payload."
  (if (plist-get state :done)
      (plist-get state :target-id)
    (let ((pending (plist-get state :pending-retry)) id)
      (when pending
        (setq payload (car pending) phase (cadr pending)))
      (condition-case cause
          (progn
            (when (and (eq phase :target) (plist-get state :fresh-target-guard))
              (setf (plist-get (plist-get state :fresh-target-guard) :stage)
                    (plist-get payload :stage))
              (supertag-service-org--promote-check-retained-target
               (plist-get state :fresh-target-guard)))
            (when (plist-get state :target-guard)
              (supertag-service-org-promote-check-source-stage
               (plist-get state :target-guard) (plist-get state :source-state)
               (eq (plist-get payload :stage) :source-project)))
            (setq id (cond
                      ((and (eq phase :target) (plist-get state :fresh-target-guard))
                       (let ((guard (plist-get state :fresh-target-guard)))
                         (supertag-service-org-promote-call-source
                          guard (plist-get guard :target)
                          (plist-get payload :retry) (plist-get payload :retry-args))))
                      ((and (eq phase :source) (plist-get state :source-state))
                       (supertag-service-org-promote-call-source
                        (plist-get state :target-guard) (plist-get state :source-state)
                        (plist-get payload :retry) (plist-get payload :retry-args)))
                      (t (apply (plist-get payload :retry) (plist-get payload :retry-args))))))
        ((error quit)
         ;; A nested continue already published its newer failed stage.
         (when (not (eq pending (plist-get state :pending-retry)))
           (signal (car cause) (cdr cause)))
         ;; Save/projection retries do not edit the link.  Keep their allowed
         ;; draft unchanged.  Actual source-edit progress is captured by
         ;; `supertag-reference-promote-continue' before publishing its new stage.
         (supertag-reference-promote--failure
          state (cond
                 ((eq (car cause) 'supertag-projection-error)
                  (append (list :stage (if (eq phase :target) :target-project :source-project))
                          (cdr cause)))
                 ((memq (car cause) '(supertag-promote-error supertag-link-error
                                      supertag-document-save-error))
                  (cdr cause))
                 (t payload))
          phase cause)))
      (if (eq phase :target)
          ;; A projection retry returns node data; its payload owns the ID.
          (setf (plist-get state :target-id) (or (plist-get payload :node-id) id))
        (setf (plist-get state :done) t))
      (supertag-reference-promote-continue state))))

(defun supertag-reference-promote-continue (state)
  "Complete explicit Promote STATE using the shared target and link writers.
STATE is transient, retained only by actionable errors; no Store receipt or
global retry registry is created.  Completed stages are never replayed."
  (unless (plist-get state :target-id)
    (condition-case cause
        (setf (plist-get state :target-id)
              (if (plist-get state :candidate)
                  (supertag-service-org-promote-target
                   (plist-get state :candidate) (plist-get state :template))
                (supertag-reference--create-target
                 (plist-get state :title) (plist-get state :template))))
      ((supertag-promote-error supertag-link-error supertag-document-save-error supertag-projection-error)
       (supertag-reference-promote--failure state (cdr cause) :target cause))))
  (unless (plist-get state :done)
    (unless (plist-get state :target-guard)
      (setf (plist-get state :target-guard)
            (or (plist-get state :fresh-target-guard)
                (supertag-service-org-promote-target-guard (plist-get state :target-id)))))
    (if (not (plist-get state :begin))
        (setf (plist-get state :done) t)
      (let ((begin (plist-get state :begin)) (end (plist-get state :end)))
        (condition-case cause
            (progn
              (supertag-service-org-promote-check-source-stage
               (plist-get state :target-guard) (plist-get state :source-state))
              (supertag-reference--validate-source begin)
              (with-current-buffer (marker-buffer begin)
                (unless (equal (plist-get state :description)
                               (buffer-substring-no-properties begin end))
                  (user-error "Promote source selection changed; retained target is safe")))
              (unless (plist-get state :source-state)
                (setf (plist-get state :source-state)
                      (supertag-service-org-promote-source-state begin)))
              (supertag-service-org-promote-call-source
               (plist-get state :target-guard) (plist-get state :source-state)
               #'supertag-reference-materialize
               (list begin end (plist-get state :target-id) (plist-get state :description)))
              (setf (plist-get state :done) t))
          (supertag-link-error
           (setf (plist-get state :source-state)
                 (supertag-service-org-promote-source-state begin))
           (supertag-reference-promote--failure state (cdr cause) :source cause))
          ((error quit)
           (supertag-reference-promote--failure
            state (list :stage :source-edit
                        :file (and (marker-buffer begin) (buffer-file-name (marker-buffer begin)))
                        :retry #'supertag-reference-promote-continue :retry-args (list state))
            :source-edit cause))))))
  (when (plist-get state :done)
    (setf (plist-get state :target-guard) nil
          (plist-get state :fresh-target-guard) nil
          (plist-get state :source-state) nil
          (plist-get state :pending-retry) nil)
    (dolist (key '(:begin :end))
      (when-let* ((marker (plist-get state key))) (set-marker marker nil))))
  (plist-get state :target-id))

;;;###autoload
(defun supertag-promote (&optional template-key selected-node)
  "Promote the active region or current heading through a complete template.
TEMPLATE-KEY skips template selection for user-defined shortcut commands.
SELECTED-NODE may be an explicitly selected heading candidate.
Reuse preserves identity/body/properties and relocates into the template file;
fresh creation alone applies initial body.  All choices precede document writes.
Whole affected files, including existing drafts, are saved at each stage."
  (interactive)
  (unless (and buffer-file-name (derived-mode-p 'org-mode))
    (user-error "Promote requires a file-backed Org source"))
  (let* ((region (use-region-p))
         (begin (and region (copy-marker (region-beginning))))
         (end (and region (copy-marker (region-end) t)))
         (description (and region (buffer-substring-no-properties begin end)))
         (source-heading (save-excursion
                           (when region (goto-char begin))
                           (when (ignore-errors (org-back-to-heading t) t) (point))))
         (source-id (and source-heading (save-excursion
                                          (goto-char source-heading)
                                          (org-entry-get nil "ID"))))
         (title (if region (supertag-reference--normalize-title description)
                  (org-get-heading t t t t)))
         candidates state handed-off)
    (unwind-protect
        (save-mark-and-excursion
          (save-restriction
            (when (string-empty-p (string-trim title))
              (user-error "Select non-empty text to promote"))
            (when region
              (supertag-reference--validate-source begin)
              (unless (equal source-heading
                             (save-excursion (goto-char (1- end))
                                             (when (ignore-errors (org-back-to-heading t) t)
                                               (point))))
                (user-error "Promote selection cannot cross source headings")))
            (let ((template (if template-key (supertag-template-by-key template-key)
                              (supertag-template-read-key))))
              (unless selected-node
                (setq candidates
                      (if region
                          (mapcar
                           (lambda (candidate)
                             (supertag-service-org-promote-candidate (plist-get candidate :node-id)))
                           (cl-remove-if-not
                            (lambda (candidate)
                              (and (> (or (plist-get (plist-get candidate :node) :level) 0) 0)
                                   (member title (plist-get candidate :terms))))
                            (supertag-reference-service-candidates)))
                        (list (supertag-service-org-promote-candidate
                               (copy-marker source-heading))))))
              (let* ((selected
                      (or selected-node
                          (if region
                              (supertag-concept--preview-choice title candidates)
                            (car candidates)))))
                (when selected
                  (let ((marker (supertag-service-org--promote-validate-candidate selected)))
                    (when (and region (eq (current-buffer) (marker-buffer marker))
                               (<= marker begin)
                               (< begin (+ marker (length (plist-get selected :text)))))
                      (user-error "Promote cannot move its containing heading or link to itself"))))
                (unless (yes-or-no-p "Promote saves whole affected files, including existing drafts. Continue? ")
                  (user-error "Promote cancelled"))
                (when (and region
                           (not (equal description (buffer-substring-no-properties begin end))))
                  (user-error "Source selection changed during preview"))
                (setq state (list :candidate selected :template template :title title
                                  :source-id source-id :begin begin :end end
                                  :description description :target-id nil :done nil)
                      handed-off t)
                (prog1 (supertag-reference-promote-continue state)
                  (supertag-concept--refresh-all-buffers))))))
      (supertag-service-org--promote-release-candidates candidates)
      (unless handed-off
        (when begin (set-marker begin nil))
        (when end (set-marker end nil))))))

(defmacro supertag-define-promote-command (name key &optional doc)
  "Define interactive NAME to promote using template KEY.
KEY is a template key string.  DOC is the optional command documentation.
Template lookup happens when the command runs, not when it is defined."
  (declare (indent defun) (doc-string 3))
  `(defun ,name ()
     ,(or doc (format "Promote using template %s." key))
     (interactive)
     (supertag-promote ,key)))


(provide 'supertag-concept)
;;; supertag-concept.el ends here
