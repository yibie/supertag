;;; supertag-ui-completion.el --- Universal and robust completion for supertag -*- lexical-binding: t; -*-

;; This file provides a completion-at-point function (CAPF) for supertag.
;; It uses the classic, most compatible CAPF design pattern to ensure it works
;; correctly across all completion UIs, including company-mode and corfu.
;;
;; The core principle is to return a list of PURE, PROPERTIZED STRINGS,
;; and use a SINGLE :exit-function that inspects the properties of the
;; selected string to decide on the action. This is the "lowest common
;; denominator" approach that all completion frameworks understand.
;;
;; ── Corfu Setup ──
;; For corfu, you need corfu-auto enabled. To trigger completion after #, use:
;;
;;   (setq corfu-auto t
;;         corfu-auto-delay 0.3
;;         corfu-auto-prefix 1)      ; trigger after 1 char
;;
;; Or manually trigger with M-TAB / C-M-i after typing #:
;;   (define-key org-mode-map (kbd "TAB") #'completion-at-point)
;;
;; ── Company Setup ──
;; Company should work out of the box if company-capf is in company-backends.
;; To ensure #tag completion takes priority over other backends:
;;
;;   (setq company-backends '((company-capf :with company-dabbrev-code)))
;;
;; Or add company-capf to your existing backends:
;;   (add-to-list 'company-backends 'company-capf)

(require 'org)
(require 'org-id)
(require 'cl-lib)

;; Required dependencies for supertag architecture
;; These MUST be loaded for completion to work correctly
(require 'supertag-core-store)
(require 'supertag-core-scan)
(require 'supertag-core-tag-path)
(require 'supertag-core-transform)
(require 'supertag-ops-tag)
(require 'supertag-ops-node)
(require 'supertag-services-query)
(require 'supertag-service-org)
(require 'supertag-service-node-identity)
(require 'supertag-ui-reference)

(declare-function supertag-ui-read-tag "supertag-services-ui"
                  (prompt &optional tag-ids allow-new allow-empty allow-namespace))

;;;----------------------------------------------------------------------
;;; Customization
;;;----------------------------------------------------------------------

(defgroup supertag-completion nil
  "Completion settings for supertag."
  :group 'supertag
  :prefix "supertag-completion-")

(defcustom supertag-completion-auto-enable t
  "Whether to automatically enable tag completion in org-mode buffers.
When non-nil, `global-supertag-ui-completion-mode' will be enabled by default."
  :type 'boolean
  :group 'supertag-completion)

;;;----------------------------------------------------------------------
;;; Helper Functions
;;;----------------------------------------------------------------------

(defvar-local supertag-completion--last-unregistered-hint nil
  "Last unregistered tag token already hinted about in this buffer.
Prevents repeating the \"not registered\" echo message on every
boundary character typed after the same token.")

(defun supertag-completion--get-all-tags ()
  "Get all available tag names from the supertag store."
  (condition-case err
      (cl-remove-if-not #'supertag-transform-inline-tag-name-p
                        (mapcar (lambda (entry) (plist-get entry :id))
                                (supertag-query-tag-paths)))
    (error
     (message "supertag-completion: Failed to get tags: %S" err)
     '())))

(defun supertag-completion--get-node-tags (node-id)
  "Get resolved Semantic Tags currently applied to NODE-ID."
  (supertag-query-node-tags node-id))

(defun supertag-completion--get-all-tag-occurrences ()
  "Return sorted unique Org Tag Occurrences from projected nodes."
  (cl-remove-if-not #'supertag-transform-inline-tag-name-p
                    (supertag-query-tag-occurrences)))

(defun supertag-completion--valid-tag-char-p (char)
  "Return non-nil if CHAR should be considered part of a tag name.
Anything except whitespace/control characters, the (full-width) hash,
and full-width punctuation counts as valid.  This keeps completion
flexible enough for emoji while letting CJK punctuation end a tag the
way ASCII whitespace does."
  (and char
       (not (memq char '(?\s ?\t ?\n ?\r ?#)))
       (not (seq-position supertag-inline-tag-terminator-chars char))))

(defun supertag-completion--get-prefix-bounds ()
  "Find the bounds of a tag prefix at point, if any.
Returns (START . END) where START is right after the # character.
Handles edge cases: cursor right after # (empty prefix), mid-word, etc."
  (save-excursion
    (let* ((end (point))
           (start nil))

      ;; Walk backwards over valid tag characters
      (while (and (> (point) (point-min))
                  (supertag-completion--valid-tag-char-p
                   (char-before (point))))
        (backward-char))

      ;; Check if we're right after a (full-width) # character
      (when (and (> (point) (point-min))
                 (memq (char-before (point)) '(?# ?＃)))
        ;; start = right after # (where tag name begins or would begin)
        (setq start (point)))

      ;; Only return bounds if we found a # before the prefix
      (when start
        (cons start end)))))

(defun supertag-completion--decorate-candidate (candidate)
  "Attach Tag identity to CANDIDATE."
  (let* ((tag (supertag--ensure-plist (supertag-tag-get candidate)))
         (name (supertag-sanitize-tag-name
                (or (plist-get tag :name) candidate))))
    (propertize name 'supertag-tag-id candidate)))

(defun supertag-completion--restore-display-path (path)
  "Replace the current completion token with PATH."
  (when-let* ((bounds (and path (supertag-completion--get-prefix-bounds))))
    (delete-region (car bounds) (cdr bounds))
    (goto-char (car bounds))
    (insert path)))

(defun supertag-completion--display-sort (candidates)
  "Place `[New]' after the first existing item in CANDIDATES."
  (let ((new (cl-find-if
              (lambda (candidate)
                (get-text-property 0 'is-new-tag candidate))
              candidates)))
    (if (not new)
        candidates
      (let ((existing (delq new (copy-sequence candidates))))
        (if existing
            (cons (car existing) (cons new (cdr existing)))
          (list new))))))

(defun supertag-completion--get-completion-table (prefix)
  "Return the candidate list for PREFIX.
The list contains every real Tag so users can search directly by leaf.
Parent chains affect display only; selecting a candidate keeps its real
Tag ID.  A valid PREFIX that is not stored is included as a new-Tag
candidate carrying `is-new-tag' and `new-tag-name' properties.  The
last `/` may create one leaf under an existing parent display path; it
never becomes part of the stored Tag ID.  Parent conflicts are shown as
non-writing action candidates.  Action candidates have a hidden final
marker so completion UIs cannot treat unfinished input as an exact match."
  (let* ((safe-prefix (or prefix ""))
         (node-id (org-id-get))
         (current-tags (when node-id (supertag-completion--get-node-tags node-id)))
         (semantic-tags (supertag-completion--get-all-tags))
         (unresolved-occurrences
          (seq-remove #'supertag-tag-resolve-occurrence
                      (supertag-completion--get-all-tag-occurrences)))
         (path-aliases
          (unless (string-empty-p safe-prefix)
            (delq nil
                  (mapcar
                   (lambda (tag-id)
                     (let* ((path (supertag-tag-display-path tag-id))
                            (name (substring-no-properties
                                   (supertag-completion--decorate-candidate
                                    tag-id))))
                       (when (and (not (equal path name))
                                  (string-prefix-p safe-prefix path))
                         (propertize path 'supertag-tag-id tag-id))))
                   semantic-tags))))
         (all-candidates
          (append
           (mapcar #'supertag-completion--decorate-candidate semantic-tags)
           path-aliases
           (mapcar (lambda (token)
                     (propertize token 'supertag-tag-occurrence token))
                   unresolved-occurrences)))
         (available-tags (if current-tags
                             (seq-remove
                              (lambda (tag)
                                (let ((tag-key
                                       (or (get-text-property
                                            0 'supertag-tag-id tag)
                                           (get-text-property
                                            0 'supertag-tag-occurrence tag))))
                                  (and tag-key (member tag-key current-tags))))
                              all-candidates)
                           all-candidates))
         (parent-path (supertag-tag-path-parent safe-prefix))
         (parent-id (and parent-path
                         (supertag-tag-resolve-display-path
                          parent-path semantic-tags)))
         (new-name (if parent-id
                       (supertag-tag-path-leaf safe-prefix)
                     safe-prefix))
         (new-name-valid-p (supertag-transform-inline-tag-name-p new-name))
         (existing-new-id
          (and new-name-valid-p
               (supertag-tag-resolve-occurrence new-name semantic-tags)))
         (existing-new-tag (and existing-new-id
                                (supertag-tag-get existing-new-id)))
         (should-add-new
          (and (not (string-empty-p safe-prefix))
               (supertag-tag-path-valid-p safe-prefix)
               new-name-valid-p
               (or (not (string-match-p "/" safe-prefix)) parent-id)
               (not (supertag-tag-resolve-occurrence
                     safe-prefix semantic-tags))
               (not existing-new-id)))
         (parent-conflict
          (and new-name-valid-p parent-id existing-new-tag
               (not (supertag-tag-resolve-occurrence
                     safe-prefix semantic-tags))
               (not (equal parent-id
                           (plist-get (supertag--ensure-plist existing-new-tag)
                                      :extends))))))
    (cond
     (should-add-new
      (let ((new-cand (concat safe-prefix "\u200b")))
          (add-text-properties
           0 (length new-cand)
           (list 'is-new-tag t
                 'new-tag-name new-name
                 'new-tag-parent parent-id
                 'new-tag-display-path safe-prefix)
           new-cand)
          (put-text-property (1- (length new-cand)) (length new-cand)
                             'display "" new-cand)
          ;; Creation is an explicit fallback, never the default match.
          (append available-tags (list new-cand))))
     (parent-conflict
      (let ((conflict (concat safe-prefix "\u200b")))
        (add-text-properties
         0 (length conflict)
         (list 'supertag-tag-conflict t
               'new-tag-name new-name
               'new-tag-display-path safe-prefix)
         conflict)
        (put-text-property (1- (length conflict)) (length conflict)
                           'display "" conflict)
        (append available-tags (list conflict))))
     (t available-tags))))

(defun supertag-completion--post-completion-action (selected-string)
  "Post-completion action invoked after the UI inserts SELECTED-STRING.
Display aliases are replaced with their canonical Org token before writing."
  (let* ((is-new (get-text-property 0 'is-new-tag selected-string))
         (conflict (get-text-property 0 'supertag-tag-conflict selected-string))
         (parent-id (get-text-property 0 'new-tag-parent selected-string))
         (display-path (get-text-property 0 'new-tag-display-path selected-string))
         (selected-name
          (replace-regexp-in-string
           "\u200b\\'" "" (substring-no-properties selected-string)))
         (selected-id (get-text-property 0 'supertag-tag-id selected-string))
         (new-name (get-text-property 0 'new-tag-name selected-string))
         (original-node-id (org-id-get))
         (normalized-token-p nil)
         (heading-position
          (save-excursion
            (when (ignore-errors (org-back-to-heading t) t)
              (copy-marker (point))))))
    (when conflict
      (supertag-completion--restore-display-path display-path)
      (user-error "Tag '%s' already exists under a different parent" new-name))
    (condition-case err
        (when-let* ((node-id (and (supertag-tag-path-valid-p selected-name)
                                  (or original-node-id
                                      (supertag-node-identity-ensure-at-point)))))
          ;; Semantic Tag creation may precede the write, but membership never does.
          (let* ((tag-id
                 (or selected-id
                     (and is-new
                          (plist-get
                           (supertag-tag-create
                            `(:name ,new-name :extends ,parent-id))
                           :id))))
                 (tag (supertag--ensure-plist (supertag-tag-get tag-id)))
                 (occurrence-token
                  (supertag-sanitize-tag-name (plist-get tag :name))))
            (unless (supertag-tag-get tag-id)
              (user-error "Tag '%s' does not exist" selected-name))
            (when-let* ((bounds (supertag-completion--get-prefix-bounds)))
              (delete-region (car bounds) (cdr bounds))
              (goto-char (car bounds))
              ;; A full-width trigger commits as the canonical half-width
              ;; token; scanners treat `#' as the canonical marker.
              (when (eq (char-before) ?＃)
                (delete-char -1)
                (insert "#"))
              (insert occurrence-token))
            (setq normalized-token-p t)
            (insert " ")
            (supertag-service-org-save-and-project-current-node node-id)
            (if is-new
                (message "New tag '%s' created and added to node %s"
                         occurrence-token node-id)
              (message "Tag '%s' added to node %s" occurrence-token node-id))))
      (error
       (unless normalized-token-p
         (supertag-completion--restore-display-path display-path))
       (when (and (not original-node-id) heading-position
                  (not normalized-token-p))
         (save-excursion
           (goto-char heading-position)
           (org-entry-delete (point) "ID")))
       (signal (car err) (cdr err))))))

;;;----------------------------------------------------------------------
;;; Main CAPF Entry Point
;;;----------------------------------------------------------------------

(defun supertag-completion-at-point ()
  "Main `completion-at-point` function using the classic, compatible API."
  (when-let ((bounds (supertag-completion--get-prefix-bounds)))
    (let* ((start (car bounds))
           (end (cdr bounds))
           (prefix (buffer-substring-no-properties start end)))

      (list start end
            ;; 1. The completion table. Returns a custom completion function
            ;;    that always includes [Create New Tag] in results.
            ;;    Built to handle all completion actions for corfu/company compatibility.
            (lambda (str pred action)
              (let* ((live-bounds
                      (and (not (minibufferp))
                           (supertag-completion--get-prefix-bounds)))
                     (live-prefix
                      (if live-bounds
                          (buffer-substring-no-properties
                           (car live-bounds) (cdr live-bounds))
                        prefix))
                     (candidates
                      (supertag-completion--get-completion-table live-prefix))
                     (existing-candidates
                      (seq-remove
                       (lambda (candidate)
                         (or (get-text-property 0 'is-new-tag candidate)
                             (get-text-property 0 'supertag-tag-conflict
                                                candidate)
                             (get-text-property 0 'supertag-tag-occurrence
                                                candidate)))
                       candidates)))
                (cond
                 ;; Handle boundaries (corfu/company compatibility)
                 ((eq (car-safe action) 'boundaries) nil)
                 ;; Return metadata (both corfu and company use this for display)
                 ((eq action 'metadata)
                  '(metadata
                    (category . supertag-tag)
                    (display-sort-function . supertag-completion--display-sort)
                    (cycle-sort-function . identity)
                    (affixation-function . supertag-tag-affixate-candidates)
                    (company-kind
                     . (lambda (cand)
                         (cond
                          ((get-text-property 0 'is-new-tag cand) 'snippet)
                          ((get-text-property 0 'supertag-tag-conflict cand)
                           'text)
                          ((get-text-property 0 'supertag-tag-occurrence cand)
                           'text)
                          (t 'keyword))))
                    (annotation-function
                     . (lambda (cand)
                         (cond
                          ((get-text-property 0 'supertag-tag-conflict cand)
                           (propertize "  [Conflict]" 'face 'error))
                          ((get-text-property 0 'is-new-tag cand)
                           (propertize "  [New]" 'face 'warning))
                          ((get-text-property 0 'supertag-tag-occurrence cand)
                           (propertize "  [Unresolved]" 'face 'shadow)))))))
               ;; Return all candidates (for display).
               ;; Two gotchas to handle here:
               ;;
               ;; 1. orderless enumerates by calling TABLE with STR=""
               ;;    and filters with its own regexp. Gating the
               ;;    new-tag candidate on STR being non-empty makes it
               ;;    invisible to orderless.
               ;; 2. corfu caches CAPF data for the duration of the
               ;;    popup session and re-calls only the TABLE function
               ;;    on subsequent keystrokes — not the outer
               ;;    `supertag-completion-at-point'. A closure over
               ;;    `prefix' therefore freezes at popup-open time, so
               ;;    "#zz" expanded to "#zzzfr" still shows the
               ;;    "zz  [Create New Tag]" candidate instead of
               ;;    "zzzfr  [Create New Tag]".
               ;;
               ;; Solution: re-read the prefix from the live buffer on
               ;; every TABLE call. `get-prefix-bounds' walks backward
               ;; from point to the leading `#', so the value is always
               ;; current. Fall back to the captured PREFIX (mainly for
               ;; non-interactive callers and tests).
                 ((eq action t)
                  (complete-with-action t candidates str pred))
               ;; Test for exact match. NEVER report the user input as an
               ;; exact match against the "[Create New Tag]" candidate
               ;; — that would convince the UI that completion is done
               ;; and it would auto-commit the labeled candidate.
                 ((eq action 'lambda)
                  (test-completion str existing-candidates pred))
               ;; Try completion (return common prefix or t if unique).
               ;; CRITICAL: if the only matching candidate is our
               ;; new-tag entry, returning t (or the bare prefix as a
               ;; "complete" match) lets corfu commit it silently
               ;; without showing the popup. Force the popup by
               ;; pretending the completion has not finished.
                 ((null action)
                  (or (try-completion str existing-candidates pred)
                      ;; No existing Tag matches. Keep the popup open so
                      ;; the user can explicitly select the [New] row.
                      str))
                 ;; Boundaries and other actions.
                 (t
                  (complete-with-action action candidates str pred)))))

            ;; 2. The leading # already identifies this completion context.
            ;;    Bypass generic UI prefix thresholds so completion can start
            ;;    before the user has typed two or three tag characters.
            :company-prefix-length t

            ;; 3. EXCLUSIVE: tell completion-at-point that once we are
            ;;    inside a #tag context, no other CAPF should run.
            ;;    Without this, cape-dabbrev / cape-keyword / pcomplete
            ;;    get appended to our candidate list, their candidates
            ;;    can override our annotation/metadata, and the
            ;;    "[Create New Tag]" entry gets hidden or stripped of
            ;;    its label by the cape merging layer.
            :exclusive 'yes

            ;; 4. A SINGLE, UNIFIED :exit-function. This is also
            ;;    universally understood by all completion frameworks.
            :exit-function
            (lambda (selected-string status)
              ;; Only an explicit completion commits. A nil status is a
              ;; cancelled/incremental exit, never permission to create.
              (when (and (memq status '(finished exact sole))
                         (or (get-text-property 0 'supertag-tag-id
                                                selected-string)
                             (get-text-property 0 'is-new-tag selected-string)
                             (get-text-property 0 'supertag-tag-conflict
                                                selected-string)))
                (supertag-completion--post-completion-action selected-string)))))))

;;;----------------------------------------------------------------------
;;; Auto-record on tag boundary
;;;----------------------------------------------------------------------

(defun supertag-completion--auto-record-on-boundary ()
  "Record an existing `#tag' right behind point after its delimiter.
Unknown text is never registered here; new Tags require selecting the
CAPF `[New]' candidate."
  (when (and (derived-mode-p 'org-mode)
             (not (supertag-completion--valid-tag-char-p (char-before)))
             (> (point) 2)
             ;; The char just before the separator must be a valid tag
             ;; char — otherwise we are not on a tag boundary.
             (supertag-completion--valid-tag-char-p (char-before (1- (point)))))
    (save-excursion
      (backward-char) ; step over the separator we just typed
      (when-let* ((bounds (supertag-completion--get-prefix-bounds))
                  (prefix (buffer-substring-no-properties
                           (car bounds) (cdr bounds)))
                  (_ (supertag-tag-path-valid-p prefix)))
        (let ((tag-id (ignore-errors
                        (supertag-tag-resolve-occurrence prefix))))
          (if (null tag-id)
              ;; The token looks like a tag but is not registered.  Say so
              ;; once per token: silently leaving it unstyled and unrecorded
              ;; reads as success to the user.
              (unless (equal prefix
                             supertag-completion--last-unregistered-hint)
                (setq supertag-completion--last-unregistered-hint prefix)
                (message
                 "Tag '%s' is not registered — select [New] in completion or M-x supertag-tag-insert to create it"
                 prefix))
            (condition-case err
                (let ((node-id (supertag-node-identity-ensure-at-point)))
                  (when node-id
                    (let ((node-tags
                           (supertag-completion--get-node-tags node-id)))
                      (unless (member tag-id node-tags)
                        (supertag-service-org-save-and-project-current-node
                         node-id)))))
              (error
               (message "supertag-completion: auto-record failed: %S"
                        err)))))))))

;;;----------------------------------------------------------------------
;;; Setup
;;;----------------------------------------------------------------------

;;;###autoload
(defun supertag-completion-setup ()
  "Set up tag and create-or-link completion for Supertag."
  (add-hook 'completion-at-point-functions
            #'supertag-completion-at-point nil t)
  ;; Added after the Tag CAPF so this reference CAPF is checked first.  Each
  ;; function is exclusive only inside its own explicit syntax (# or [[).
  (add-hook 'completion-at-point-functions
            #'supertag-reference-completion-at-point nil t)
  (add-hook 'post-self-insert-hook
            #'supertag-completion--auto-record-on-boundary nil t))

;;;###autoload
(define-minor-mode supertag-ui-completion-mode
  "Enhanced tag completion for supertag."
  :lighter " ST-C"
  (if supertag-ui-completion-mode
      (supertag-completion-setup)
    (remove-hook 'completion-at-point-functions
                 #'supertag-completion-at-point t)
    (remove-hook 'completion-at-point-functions
                 #'supertag-reference-completion-at-point t)
    (remove-hook 'post-self-insert-hook
                 #'supertag-completion--auto-record-on-boundary t)))

;;;###autoload
(defun supertag-ui-completion-enable ()
  "Enable tag completion in org-mode buffers."
  (when (derived-mode-p 'org-mode)
    (supertag-ui-completion-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-supertag-ui-completion-mode
  supertag-ui-completion-mode
  supertag-ui-completion-enable)

(provide 'supertag-ui-completion)

;;;----------------------------------------------------------------------
;;; Fallback: bypass corfu entirely
;;;----------------------------------------------------------------------

;;;###autoload
(defun supertag-tag-insert ()
  "Pick or create a #tag via minibuffer, bypassing corfu/company.
Use when the popup completion does not show the \"[Create New Tag]\"
option in your UI stack. Prompts for a tag name with completion
against existing tags. Typing a brand-new name and confirming with
RET creates and records the tag immediately."
  (interactive)
  (require 'supertag-services-ui)
  (let* ((all (supertag-completion--get-all-tags))
         (node-id (supertag-node-identity-ensure-at-point))
         (current (when node-id (supertag-completion--get-node-tags node-id)))
         (available (if current
                        (seq-remove (lambda (tag) (member tag current)) all)
                      all))
         (input (supertag-ui-read-tag
                 "Tag (RET on a typed name creates it): "
                 available t t)))
    (when (and input (not (string-empty-p input)))
      (unless (supertag-tag-path-valid-p input)
        (user-error "Tag paths cannot contain empty segments"))
      (let* ((existing-id
              (or (and (supertag-tag-get input) input)
                  (supertag-tag-resolve-occurrence input)))
             (is-new (not existing-id))
             (tag (and existing-id (supertag-tag-get existing-id)))
             (token (if tag
                        (supertag-sanitize-tag-name (plist-get tag :name))
                      input)))
        (when (looking-back "[^#＃]" 1)
          (insert "#"))
        (insert token " ")
        (when is-new
          (supertag-tag-create `(:name ,input)))
        (supertag-service-org-save-and-project-current-node node-id)
        (message "%s tag '%s' added to node %s"
                 (if is-new "New" "Existing") token node-id)))))

;;;###autoload
(defun supertag-completion-debug ()
  "Dump the full completion pipeline for the `#prefix' at point.
Run this with the cursor sitting just after a `#typedprefix' (do not
delete or move anything) and paste the contents of *Messages* back to
the maintainer. The output shows: the detected bounds, the live prefix,
the full candidate list our CAPF returns, and what
`completion-all-completions' under your active `completion-styles' keeps
after filtering — i.e. exactly what the popup should display."
  (interactive)
  (let ((bounds (supertag-completion--get-prefix-bounds)))
    (if (not bounds)
        (message "[supertag-debug] No #prefix bounds at point (no leading #?).")
      (let* ((start (car bounds))
             (end (cdr bounds))
             (prefix (buffer-substring-no-properties start end))
             (table (supertag-completion--get-completion-table prefix))
             (first (car table))
             (styles completion-styles)
             (md (let ((capf (supertag-completion-at-point)))
                   (when capf
                     (funcall (nth 2 capf) prefix nil 'metadata))))
             (filtered (completion-all-completions
                        prefix table nil (length prefix) md)))
        ;; completion-all-completions returns a partial list with the
        ;; final cdr possibly set to a base-size integer; normalize.
        (let ((flat (let (acc (c filtered))
                      (while (consp c)
                        (push (car c) acc)
                        (setq c (cdr c)))
                      (nreverse acc))))
          (message "[supertag-debug] ─────────────────────────────")
          (message "[supertag-debug] prefix bounds : %S..%S" start end)
          (message "[supertag-debug] live prefix   : %S" prefix)
          (message "[supertag-debug] completion-styles: %S" styles)
          (message "[supertag-debug] raw candidates  : %d total" (length table))
          (message "[supertag-debug]   [0] %S  is-new-tag=%S name=%S"
                   (substring-no-properties (or first ""))
                   (and first (get-text-property 0 'is-new-tag first))
                   (and first (get-text-property 0 'new-tag-name first)))
          (message "[supertag-debug]   first 5 raw  : %S"
                   (mapcar #'substring-no-properties (cl-subseq table 0 (min 5 (length table)))))
          (message "[supertag-debug] after-filter   : %d candidates"
                   (length flat))
          (message "[supertag-debug]   first 5 kept : %S"
                   (mapcar #'substring-no-properties (cl-subseq flat 0 (min 5 (length flat)))))
          (message "[supertag-debug] new-tag in raw? : %s"
                   (if (cl-some (lambda (c)
                                  (get-text-property 0 'is-new-tag c))
                                table)
                       "YES" "no"))
          (message "[supertag-debug] new-tag in kept?: %s"
                   (if (cl-some (lambda (c)
                                  (get-text-property 0 'is-new-tag c))
                                flat)
                       "YES" "NO  ← filter dropped it"))
          (message "[supertag-debug] candidate width : %d chars (corfu-max-width may truncate)"
                   (length (substring-no-properties (or first ""))))
          (message "[supertag-debug] corfu installed?: %s%s"
                   (if (featurep 'corfu) "yes" "no")
                   (if (boundp 'corfu-max-width)
                       (format ", corfu-max-width=%S" corfu-max-width)
                     ""))
          (message "[supertag-debug] cape installed? : %s" (if (featurep 'cape) "yes" "no"))
          (message "[supertag-debug] marginalia?     : %s" (if (and (boundp 'marginalia-mode) marginalia-mode) "ON" "off"))
          (message "[supertag-debug] capf-functions  : %S"
                   (mapcar (lambda (f) (if (symbolp f) f 'lambda))
                           completion-at-point-functions))
          (message "[supertag-debug] ─────────────────────────────"))))))

;;;###autoload
(defun supertag-complete-tag ()
  "Manually trigger #tag completion at point.
Bind this to TAB in org-mode if you want explicit trigger instead of auto-popup.

  (define-key org-mode-map (kbd \"TAB\") #'supertag-complete-tag)

Works with corfu, company, and default completion."
  (interactive)
  (if-let ((bounds (supertag-completion--get-prefix-bounds)))
      (completion-at-point)
    ;; No #tag prefix found, fall through to default completion or indent
    (if (and (eq last-command-event ?\t)
             (fboundp 'org-cycle))
        (call-interactively #'org-cycle)
      (call-interactively #'completion-at-point))))

;;; supertag-ui-completion.el ends here
