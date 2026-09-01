;;; supertag-ui-reference.el --- Roam-like create-or-link references -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides one low-friction reference workflow:
;; - type [[ and complete an existing Supertag node;
;; - explicitly select a create candidate for a new concept;
;; - replace the shorthand with a physical Org link;
;; - let the normal document projector derive the Backlink.
;;
;; This module owns prompts and Org edits only.  Reference facts remain owned by
;; the source Org document and its normal projection pipeline.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'supertag-concept)
(require 'supertag-ops-node)
(require 'supertag-services-reference)
(require 'supertag-ui-commands)

(defvar supertag-reference-history nil
  "Minibuffer history for create-or-link reference commands.")

(defcustom supertag-reference-shorthand-openers
  '(("[[" . "]]") ("【【" . "】】"))
  "Opener/closer pairs that start a create-or-link shorthand.

Each element is (OPENER . CLOSER).  Typing OPENER followed by a title
offers reference completion; committing a candidate rewrites the whole
shorthand, including OPENER and a CLOSER the user (or an input method)
already typed, to the canonical Org link `[[id:TARGET][Title]]'.

The full-width pair lets Chinese input methods trigger the workflow
without switching to ASCII brackets."
  :type '(repeat (cons (string :tag "Opener") (string :tag "Closer")))
  :group 'supertag)

(defun supertag-reference--opener-regexp ()
  "Return a regexp matching any configured shorthand opener."
  (regexp-opt (mapcar #'car supertag-reference-shorthand-openers)))

(defun supertag-reference--closer-regexp ()
  "Return a regexp matching any configured shorthand closer."
  (regexp-opt (mapcar #'cdr supertag-reference-shorthand-openers)))

(defun supertag-reference--opener-position (start)
  "Return the buffer position of the shorthand opener ending at START.
Return nil when no configured opener ends exactly at START."
  (save-excursion
    (goto-char start)
    (cl-loop for (opener . _closer) in supertag-reference-shorthand-openers
             for beg = (- start (length opener))
             when (and (>= beg (point-min))
                       (equal (buffer-substring-no-properties beg start)
                              opener))
             return beg)))

(defun supertag-reference--normalize-title (title)
  "Return TITLE as one trimmed line."
  (string-trim
   (replace-regexp-in-string "[ \t\n\r]+" " " (or title ""))))

(defun supertag-reference--completion-context-p ()
  "Return non-nil when point is prose that may own a reference shorthand."
  (let ((type (org-element-type (org-element-context))))
    (and (not (memq type '(link code verbatim comment comment-block keyword
                           node-property property-drawer drawer src-block
                           example-block table table-row table-cell
                           fixed-width)))
         (not (org-in-commented-heading-p)))))

(defun supertag-reference--get-prefix-bounds ()
  "Return bounds after an unmatched shorthand opener before point, or nil.

Openers come from `supertag-reference-shorthand-openers' (`[[' and `【【'
by default).  The bounds cover only the user-entered title.  Existing Org
links using a known link scheme are deliberately ignored."
  (when (and (derived-mode-p 'org-mode)
             (supertag-reference--completion-context-p))
    (save-excursion
      (let ((end (point)))
        (when (re-search-backward (supertag-reference--opener-regexp)
                                  (line-beginning-position) t)
          (let* ((start (match-end 0))
                 (prefix (buffer-substring-no-properties start end)))
            (when (and (not (string-match-p
                             (supertag-reference--closer-regexp) prefix))
                       (not (string-match-p
                             "\\`\\(?:id\\|denote\\|file\\|https?\\|ftp\\|mailto\\):"
                             prefix)))
              (cons start end))))))))

(defun supertag-reference--candidate-strings (&optional exclude-id)
  "Return completion strings for reference targets excluding EXCLUDE-ID."
  (let (result)
    (dolist (candidate (supertag-reference-service-candidates exclude-id))
      (let* ((node-id (plist-get candidate :node-id))
             (title (plist-get candidate :title)))
        (dolist (term (plist-get candidate :terms))
          (let ((display
                 (if (string-equal term title)
                     (plist-get candidate :display)
                   (format "%s  -> %s"
                           term (plist-get candidate :display)))))
            (push (propertize display
                              'supertag-reference-node-id node-id
                              'supertag-reference-title title
                              'supertag-reference-term term)
                  result)))))
    (sort result
          (lambda (left right)
            (string< (substring-no-properties left)
                     (substring-no-properties right))))))

(defun supertag-reference--exact-term-p (term candidates)
  "Return non-nil when TERM exactly identifies an existing CANDIDATE term."
  (let ((folded (downcase term)))
    (cl-some
     (lambda (candidate)
       (string-equal
        folded
        (downcase
         (or (get-text-property 0 'supertag-reference-term candidate) ""))))
     candidates)))

(defun supertag-reference--node-has-term-p (node-id term)
  "Return non-nil when NODE-ID already owns TERM as a title or alias."
  (when-let* ((node (and node-id
                         (supertag-store-get-entity :nodes node-id))))
    (let ((folded (downcase term)))
      (cl-some (lambda (candidate-term)
                 (string-equal folded (downcase candidate-term)))
               (supertag-reference-service-node-terms node)))))

(defun supertag-reference--completion-table (captured-prefix exclude-id)
  "Return a dynamic completion table for CAPTURED-PREFIX and EXCLUDE-ID."
  (lambda (string predicate action)
    (let* ((live-bounds (and (not (minibufferp))
                             (supertag-reference--get-prefix-bounds)))
           (live-prefix
            (if live-bounds
                (buffer-substring-no-properties
                 (car live-bounds) (cdr live-bounds))
              captured-prefix))
           (clean-prefix (supertag-reference--normalize-title live-prefix))
           (existing (supertag-reference--candidate-strings exclude-id))
           (create
            (when (and (not (string-empty-p clean-prefix))
                       (not (supertag-reference--exact-term-p
                             clean-prefix existing))
                       (not (supertag-reference--node-has-term-p
                             exclude-id clean-prefix)))
              (list
               (propertize
                (format "%s  [Create new concept]" clean-prefix)
                'supertag-reference-create-title clean-prefix))))
           (candidates (append existing create)))
      (cond
       ((eq (car-safe action) 'boundaries) nil)
       ((eq action 'metadata)
        '(metadata
          (category . supertag-reference)
          (cycle-sort-function . identity)
          (company-kind
           . (lambda (candidate)
               (if (get-text-property
                    0 'supertag-reference-create-title candidate)
                   'snippet
                 'reference)))))
       ((eq action t)
        (complete-with-action t candidates string predicate))
       ((eq action 'lambda)
        ;; A create row is an explicit action, never an exact completion.
        (test-completion string existing predicate))
       ((null action)
        (or (try-completion string existing predicate) string))
       (t
        (complete-with-action action candidates string predicate))))))

(defun supertag-reference--source-id-at-marker (marker)
  "Return and synchronize the source node containing MARKER."
  (unless (and (marker-buffer marker) (buffer-live-p (marker-buffer marker)))
    (user-error "Reference source is no longer available"))
  (with-current-buffer (marker-buffer marker)
    (unless buffer-file-name
      (user-error "References require an Org buffer visiting a file"))
    (save-excursion
      (goto-char marker)
      (let ((source-id (supertag-ui--get-containing-node-at-point)))
        (unless source-id
          (user-error "The current location cannot own a reference"))
        (supertag-ui--ensure-node-synced source-id)
        (unless (supertag-node-get source-id)
          (user-error "The source node could not be synchronized"))
        source-id))))

(defun supertag-reference--existing-source-id-at-marker (marker)
  "Return MARKER's already persisted heading ID without creating one."
  (when (and (marker-buffer marker) (buffer-live-p (marker-buffer marker)))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (ignore-errors
          (org-back-to-heading t)
          (org-entry-get nil "ID"))))))

(defun supertag-reference-materialize (beg-marker end-marker target-id title)
  "Materialize BEG-MARKER..END-MARKER as a link to TARGET-ID titled TITLE.

This is the system's sole production gateway for reference commands that
commit a source-owned physical `[[id:]]' node link to an Org buffer.  Callers
that replace a region pass its boundary markers.  Pure display renderers and
explicitly marked machine-generated view regions may still emit link-shaped
strings because the projector excludes those regions from Document Links."
  (let ((source-buffer (marker-buffer beg-marker)))
    (unless (and source-buffer (eq source-buffer (marker-buffer end-marker)))
      (user-error "Reference region is no longer valid"))
    (with-current-buffer source-buffer
      (let ((source-id (supertag-reference--source-id-at-marker beg-marker)))
        (when (equal source-id target-id)
          (user-error "A node cannot reference itself through this workflow"))
        (supertag-ui--replace-region-with-reference
         beg-marker end-marker source-id target-id title)
        (message "Linked to %s" title)
        target-id))))

(defun supertag-reference-materialize-at-point (target-id title)
  "Materialize an empty region at point as a link to TARGET-ID titled TITLE.

This is the at-point adapter for `supertag-reference-materialize'.  It owns and
releases the temporary markers required when source synchronization inserts an
Org ID or property drawer before point."
  (let ((beg-marker (copy-marker (point)))
        (end-marker (copy-marker (point) t)))
    (unwind-protect
        (supertag-reference-materialize
         beg-marker end-marker target-id title)
      (set-marker beg-marker nil)
      (set-marker end-marker nil))))

(defalias 'supertag-reference--commit-region
  #'supertag-reference-materialize)

(defun supertag-reference--resolve-or-create (input selected &optional choose-target)
  "Resolve INPUT or SELECTED candidate, creating when necessary.
When CHOOSE-TARGET is non-nil, prompt for the creation target."
  (let* ((selected-id
          (and selected
               (get-text-property 0 'supertag-reference-node-id selected)))
         (selected-title
          (and selected
               (get-text-property 0 'supertag-reference-title selected)))
         (clean (supertag-reference--normalize-title
                 (or selected-title input)))
         (existing (and (not selected-id)
                        (supertag-reference-service-find-by-term clean)))
         (target-id (or selected-id (plist-get existing :node-id)))
         (title (or selected-title (plist-get existing :title) clean)))
    (when (string-empty-p title)
      (user-error "Reference title cannot be empty"))
    (unless target-id
      (setq target-id
            (supertag-concept-ensure-node
             title
             (when choose-target
               (supertag-concept-read-create-target title))))
      (supertag-concept--refresh-all-buffers))
    (cons target-id title)))

(defun supertag-reference--post-completion (selected status open-marker)
  "Commit SELECTED completion with STATUS beginning at OPEN-MARKER."
  (unwind-protect
      (when (and (memq status '(finished exact sole))
                 (marker-buffer open-marker))
        (let* ((target-id
                (get-text-property 0 'supertag-reference-node-id selected))
               (create-title
                (get-text-property 0 'supertag-reference-create-title selected))
               (title
                (or (get-text-property 0 'supertag-reference-title selected)
                    create-title)))
          (when (or target-id create-title)
            (let* ((resolved
                    (if target-id
                        (cons target-id title)
                      (supertag-reference--resolve-or-create
                       create-title selected nil)))
                   (end-marker (copy-marker (point) t)))
              ;; Consume a closing pair the user (or an input method that
              ;; auto-pairs brackets) typed before completion.
              (when (looking-at (supertag-reference--closer-regexp))
                (set-marker end-marker (match-end 0)))
              (unwind-protect
                  (supertag-reference-materialize
                   open-marker end-marker (car resolved) (cdr resolved))
                (set-marker end-marker nil))))))
    (set-marker open-marker nil)))

;;;###autoload
(defun supertag-reference-completion-at-point ()
  "Complete a Supertag reference after an unmatched shorthand opener.
See `supertag-reference-shorthand-openers' for the recognised openers."
  (when-let* ((bounds (supertag-reference--get-prefix-bounds)))
    (let* ((start (car bounds))
           (end (cdr bounds))
           (prefix (buffer-substring-no-properties start end))
           (source-id
            (save-excursion
              (ignore-errors
                (org-back-to-heading t)
                (org-entry-get nil "ID"))))
           (open-marker
            (copy-marker (or (supertag-reference--opener-position start)
                             (- start 2)))))
      (list start end
            (supertag-reference--completion-table prefix source-id)
            :company-prefix-length t
            :exclusive 'yes
            :exit-function
            (lambda (selected status)
              (supertag-reference--post-completion
               selected status open-marker))))))

(defun supertag-reference--read-candidate (initial exclude-id)
  "Read a reference target with INITIAL input, excluding EXCLUDE-ID."
  (let* ((candidates (supertag-reference--candidate-strings exclude-id))
         (plain (mapcar (lambda (candidate)
                          (cons (substring-no-properties candidate) candidate))
                        candidates))
         (input (completing-read
                 "Reference (type a new title to create): "
                 plain nil nil initial 'supertag-reference-history))
         (selected (cdr (assoc input plain))))
    (cons input selected)))

;;;###autoload
(defun supertag-reference-link-region (beg end &optional choose-target)
  "Create or reuse a node for BEG..END and replace the region with its link.

With optional CHOOSE-TARGET, ask where a newly created concept should live."
  (interactive "r\nP")
  (unless (and (derived-mode-p 'org-mode) (< beg end))
    (user-error "Select non-empty text in an Org buffer"))
  (let* ((title (supertag-reference--normalize-title
                 (buffer-substring-no-properties beg end)))
         (beg-marker (copy-marker beg))
         (end-marker (copy-marker end t)))
    (unwind-protect
        (let* ((source-id (supertag-reference--source-id-at-marker beg-marker))
               (existing
                (supertag-reference-service-find-by-term title source-id))
               (target-id
                (or (plist-get existing :node-id)
                    (supertag-concept-ensure-node
                     title
                     (when choose-target
                       (supertag-concept-read-create-target title)))))
               (canonical-title
                (or (plist-get existing :title) title)))
          (supertag-reference-materialize
           beg-marker end-marker target-id canonical-title))
      (set-marker beg-marker nil)
      (set-marker end-marker nil))))

;; Compatibility name from the earlier prompt-heavy workflow.  Ownership now
;; lives here because create-or-link, concept targeting, and the physical Org
;; replacement form one UI action.
(defalias 'supertag-add-reference-and-create
  #'supertag-reference-link-region)

;;;###autoload
(defun supertag-reference-insert (&optional choose-target)
  "Insert or replace text with a reference to an existing or new node.

With active region, its text is the initial title and the region is replaced.
Without a region, the link is inserted at point.  With prefix argument
CHOOSE-TARGET, ask where a newly created concept should be stored."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "Create-or-link works only in Org buffers"))
  (let* ((beg (if (use-region-p) (region-beginning) (point)))
         (end (if (use-region-p) (region-end) (point)))
         (initial (and (< beg end)
                       (supertag-reference--normalize-title
                        (buffer-substring-no-properties beg end))))
         (beg-marker (copy-marker beg))
         (end-marker (copy-marker end t)))
    (unwind-protect
        (let* ((exclude-id
                (supertag-reference--existing-source-id-at-marker beg-marker))
               (read-result
                (supertag-reference--read-candidate initial exclude-id))
               ;; Validate and synchronize the source only after the user has
               ;; committed to a target.  Cancelling completion leaves the Org
               ;; document untouched.
               (_source-id (supertag-reference--source-id-at-marker beg-marker))
               (resolved
                (supertag-reference--resolve-or-create
                 (car read-result) (cdr read-result) choose-target)))
          (supertag-reference-materialize
           beg-marker end-marker (car resolved) (cdr resolved)))
      (set-marker beg-marker nil)
      (set-marker end-marker nil))))

(defalias 'supertag-reference-create-or-link #'supertag-reference-insert)

;;;###autoload
(defun supertag-reference-complete ()
  "Trigger create-or-link completion when point follows `[[' or `【【'."
  (interactive)
  (if (supertag-reference--get-prefix-bounds)
      (completion-at-point)
    (call-interactively #'supertag-reference-insert)))

(provide 'supertag-ui-reference)
;;; supertag-ui-reference.el ends here
