;;; supertag-view-orphan-tags.el --- Orphan Tag occurrence page -*- lexical-binding: t; -*-

;;; Commentary:

;; Orphan Tag occurrences: `#token' text no Tag entity owns.  This page is the
;; markable list of the Tag Manager family - every token starts marked, `D'
;; removes the marked occurrences through the one preview/confirmation path
;; built for deletion, and nothing here registers or renames anything.  It
;; follows design.md: masthead, manifesto, action row, field of card-per-token,
;; colophon; one font size with hierarchy by contrast, colour as filled area,
;; `NOUN / NOUN' labels, ornament from `+ . + . + .', and traditional
;; `[ BUTTON ]' actions on the warm paper palette.  Orphan text is metadata
;; blind: a token on an Org keyword line is not an occurrence at all.

;; Commands: supertag-view-orphan-tags, supertag-report-orphan-tag-occurrences,
;; supertag-view-orphan-tags-mark, supertag-view-orphan-tags-unmark,
;; supertag-view-orphan-tags-mark-all, supertag-view-orphan-tags-unmark-all,
;; supertag-view-orphan-tags-remove, supertag-view-orphan-tags-visit,
;; supertag-view-orphan-tags-quit.
;; Dependencies: cl-lib, subr-x, supertag-tag, supertag-view-framework.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-tag)
(require 'supertag-view-framework)

(defconst supertag-view-orphan-tags--buffer-name "*Supertag Orphan Tags*"
  "Buffer name of the Orphan Tags page.")

(defconst supertag-view-orphan-tags--manifesto
  '("METADATA / NOT GARBAGE." "TOKENS / NO TAG OWNS."
    "Orphan tokens are text no Tag entity owns.  Every token starts marked; unmark what to keep, then REMOVE.")
  "The page's manifesto: two uppercase lines, then one sentence-case line.")

(defvar-local supertag-view-orphan-tags--scan nil
  "The candidate scan this page was built from.")

(defvar-local supertag-view-orphan-tags--records nil
  "Orphan occurrence records shown on this page.")

(defvar-local supertag-view-orphan-tags--marked-tokens nil
  "Token names marked for the bulk removal.  Every token starts marked.")

(defvar-local supertag-view-orphan-tags--unmarked-occurrences nil
  "Occurrence keys individually unmarked inside a marked token.")

(defvar-local supertag-view-orphan-tags--marks-initialized nil
  "Non-nil once this page decided its initial marks.
A fresh page marks everything; reopening the page resets this so the
\"review, then confirm\" default comes back.")

(defvar-local supertag-view-orphan-tags--origin-window-configuration nil
  "Window configuration to restore when the page quits.")

;;; --- Occurrence records ---

(defun supertag-view-orphan-tags--occurrence-key (record)
  "Return RECORD's identity inside the page."
  (list (plist-get record :file) (plist-get record :begin)
        (plist-get record :end) (plist-get record :token)))

(defun supertag-view-orphan-tags--tokens ()
  "Return every token shown on this page."
  (delete-dups (mapcar (lambda (record) (plist-get record :token))
                       supertag-view-orphan-tags--records)))

(defun supertag-view-orphan-tags--records-for-token (token)
  "Return every reported occurrence of TOKEN, marked or not."
  (cl-remove-if-not (lambda (record) (equal token (plist-get record :token)))
                    supertag-view-orphan-tags--records))

(defun supertag-view-orphan-tags--select (records tokens skipped)
  "Return RECORDS whose token is in TOKENS and whose key is not in SKIPPED.
The selection rule itself lives with the removal path
(`supertag-tag--orphan-select-records'), so the page and the non-interactive
entry can never disagree about what is selected."
  (supertag-tag--orphan-select-records records tokens skipped))

(defun supertag-view-orphan-tags--marked-records ()
  "Return the occurrence records the bulk removal would touch."
  (supertag-view-orphan-tags--select supertag-view-orphan-tags--records
                                     supertag-view-orphan-tags--marked-tokens
                                     supertag-view-orphan-tags--unmarked-occurrences))

(defun supertag-view-orphan-tags--stem (token)
  "Return TOKEN without its trailing ASCII punctuation.
A rare token may still end with a name character that reads as punctuation
(`tag-'), which is what the card's `STEM / …' overline is for."
  (if (string-match "[[:punct:]]+\\'" token)
      (substring token 0 (match-beginning 0))
    token))

(defun supertag-view-orphan-tags--sorted-tokens ()
  "Return the page's tokens sorted by stem, so variants stay adjacent."
  (sort (copy-sequence (supertag-view-orphan-tags--tokens))
        (lambda (a b)
          (let ((stem-a (supertag-view-orphan-tags--stem a))
                (stem-b (supertag-view-orphan-tags--stem b)))
            (if (equal stem-a stem-b) (string< a b) (string< stem-a stem-b))))))

;;; --- Page state ---

(defun supertag-view-orphan-tags--build-state (_input)
  "Return the orphan scan for the current sync scope.
Nothing is written; the scan reads live Org text, so the page and the removal
path agree on what an occurrence is."
  (let ((scan (supertag-tag--text-scan (supertag-tag--text-scope-files))))
    (list :scan scan
          :records (supertag-tag--text-orphan-records scan))))

;;; --- Rendering helpers (design.md bands) ---

(defun supertag-view-orphan-tags--cell (text face width)
  "Return TEXT as a FACE cell padded or clipped to WIDTH."
  (let* ((padded (concat " " text " "))
         (clipped (supertag-view-helper-clip padded width "…")))
    (propertize (concat clipped (make-string (max 0 (- width (string-width clipped))) ?\s))
                'face face)))

(defun supertag-view-orphan-tags--fill (text face width)
  "Return TEXT as a full-width FACE fill clipped to WIDTH.
Colour is area in this system: a fill is always a label or a title."
  (supertag-view-orphan-tags--cell text face width))

(defun supertag-view-orphan-tags--insert-masthead (width tokens occurrences marked selected)
  "Insert the three-cell masthead at WIDTH.
TOKENS and OCCURRENCES are whole-page measures; MARKED and SELECTED are the
live status on the right."
  (ignore selected)
  (let* ((available (max 3 (- width 4)))
         (base (/ available 3))
         (remainder (% available 3))
         (left (+ base (if (> remainder 0) 1 0)))
         (middle (+ base (if (> remainder 1) 1 0)))
         (right base))
    (insert (supertag-view-orphan-tags--fill "SUPERTAG / ORPHANS"
                                             'supertag-view-chip1 left)
            "  "
            (supertag-view-orphan-tags--cell
             (format "VOL. %d / %d OCCURRENCES" tokens occurrences)
             'supertag-view-mute middle)
            "  "
            (supertag-view-orphan-tags--fill
             (format "MARKED / %d TOKENS" marked)
             'supertag-view-chip3 right)
            "\n\n")))

(defun supertag-view-orphan-tags--insert-manifesto (width)
  "Insert the manifesto block at WIDTH."
  (insert (supertag-view-orphan-tags--fill (nth 0 supertag-view-orphan-tags--manifesto)
                                           'supertag-view-panel width)
          "\n"
          (supertag-view-orphan-tags--fill (nth 1 supertag-view-orphan-tags--manifesto)
                                           'supertag-view-panel width)
          "\n"
          (supertag-view-orphan-tags--fill (nth 2 supertag-view-orphan-tags--manifesto)
                                           'supertag-view-panel width)
          "\n\n"))

(defun supertag-view-orphan-tags--insert-action-row ()
  "Insert the traditional button row: every action is a `[ ]' button."
  (supertag-view-helper-insert-action-button
   "[ REMOVE ]" (lambda (&rest _) (call-interactively #'supertag-view-orphan-tags-remove))
   nil "Remove every marked orphan occurrence" 'supertag-view-orphan-tags-remove)
  (insert "  ")
  (supertag-view-helper-insert-action-button
   "[ MARK ALL ]" (lambda (&rest _) (call-interactively #'supertag-view-orphan-tags-mark-all))
   nil "Mark every token" 'supertag-view-orphan-tags-mark-all)
  (insert "  ")
  (supertag-view-helper-insert-action-button
   "[ UNMARK ALL ]" (lambda (&rest _) (call-interactively #'supertag-view-orphan-tags-unmark-all))
   nil "Clear every mark" 'supertag-view-orphan-tags-unmark-all)
  (insert "  ")
  (supertag-view-helper-insert-action-button
   "[ REFRESH ]" (lambda (&rest _) (call-interactively #'supertag-view-refresh))
   nil "Rescan the sync scope" 'supertag-view-refresh)
  (insert "\n\n"))

(defun supertag-view-orphan-tags--card-title (token count width face)
  "Insert TOKEN's card title as a fill with its COUNT cell, at WIDTH.
The mark prefix sits inside the fill, so a card shows its state without a
second column; the whole row carries the token, because a fill is a label,
not an action."
  (let* ((count-cell (format " %d " count))
         (count-width (string-width count-cell))
         (title-width (max 1 (- width count-width)))
         (mark (if (member token supertag-view-orphan-tags--marked-tokens) "* " "  "))
         (label (supertag-view-orphan-tags--cell (concat mark "#" token) face title-width))
         (start (point)))
    (insert label
            (propertize count-cell 'face 'supertag-view-chip3)
            "\n")
    (add-text-properties start (point)
                         (list 'supertag-view-orphan-tags--row-token token))))

(defun supertag-view-orphan-tags--insert-occurrence-row (record token width)
  "Insert RECORD's entry row for TOKEN, bounded by WIDTH.
The row is a bracket-free link button that visits the occurrence."
  (let* ((key (supertag-view-orphan-tags--occurrence-key record))
         (skipped (member key supertag-view-orphan-tags--unmarked-occurrences))
         (mark (if (and (member token supertag-view-orphan-tags--marked-tokens)
                        (not skipped))
                   "* "
                 "  "))
         (line (format "%s→ %d  %s  [%s]  %s"
                       mark
                       (plist-get record :line)
                       (file-name-nondirectory (plist-get record :file))
                       (supertag-tag--text-context-label record)
                       (string-trim (plist-get record :line-text))))
         (row (supertag-view-orphan-tags--cell line 'supertag-view-entry width)))
    (insert-text-button row
                        'action (lambda (&rest _) (supertag-view-orphan-tags--visit-record record))
                        'follow-link t
                        'face 'supertag-view-entry
                        'help-echo (format "%s:%d" (plist-get record :file) (plist-get record :line))
                        'supertag-view-orphan-tags--occurrence-key key
                        'supertag-view-orphan-tags--row-token token)
    (insert "\n")))

(defun supertag-view-orphan-tags--insert-card (token width)
  "Insert TOKEN's card at WIDTH: overline, filled title, entries."
  (let* ((records (supertag-view-orphan-tags--records-for-token token))
         (stem (supertag-view-orphan-tags--stem token))
         (files (length (supertag-tag--text-group-by-file records)))
         (face (nth (% (cl-position token (supertag-view-orphan-tags--sorted-tokens)
                                   :test #'equal)
                       3)
                    '(supertag-view-chip1 supertag-view-chip2 supertag-view-chip3))))
    (insert (supertag-view-orphan-tags--cell
             (if (equal stem token)
                 (format "FILES / %d" files)
               (format "STEM / %s" stem))
             'supertag-view-mute width)
            "\n")
    (supertag-view-orphan-tags--card-title token (length records) width face)
    (dolist (record records)
      (supertag-view-orphan-tags--insert-occurrence-row record token width))
    (insert "\n")))

(defun supertag-view-orphan-tags--insert-ambiguous (width)
  "Insert the muted list of ambiguous tokens at WIDTH, when there are any."
  (let* ((ambiguous (supertag-tag--text-ambiguous-records supertag-view-orphan-tags--scan))
         (tokens (sort (delete-dups
                        (mapcar (lambda (record) (plist-get record :token)) ambiguous))
                       #'string<)))
    (when ambiguous
      (insert (supertag-view-orphan-tags--fill
               (format "AMBIGUOUS / %d TOKENS, NOT ORPHANS" (length tokens))
               'supertag-view-chip2 width)
              "\n")
      (insert (supertag-view-orphan-tags--cell
               (string-join (mapcar (lambda (token) (concat "#" token)) tokens) "  ")
               'supertag-view-mute width)
              "\n\n"))))

(defun supertag-view-orphan-tags--insert-colophon (width tokens occurrences)
  "Insert the rule, the muted line and the brand line at WIDTH."
  (let ((end (point)))
    (skip-chars-backward "\n")
    (delete-region (point) end))
  (insert "\n"
          (propertize "+ . + . + ." 'face 'supertag-view-rule) "\n"
          (supertag-view-orphan-tags--cell
           (format "01 / ORPHAN FIELD  %d TOKEN(S)  %d OCCURRENCE(S)  LIVE TEXT SCAN"
                   tokens occurrences)
           'supertag-view-mute width)
          "\n"
          (propertize "SUPERTAG / ORPHANS" 'face 'supertag-view-mute) "\n"))

(defun supertag-view-orphan-tags--renderer (state)
  "Render STATE into the current page buffer (the view's render function)."
  (let* ((width (supertag-view-helper-width))
         (scan (plist-get state :scan))
         (records (plist-get state :records))
         (line (line-number-at-pos)))
    (setq supertag-view-orphan-tags--scan scan
          supertag-view-orphan-tags--records records)
    (let ((tokens (supertag-view-orphan-tags--tokens))
          (keys (mapcar #'supertag-view-orphan-tags--occurrence-key records)))
      (if supertag-view-orphan-tags--marks-initialized
          ;; A refresh keeps what the user marked, drops what vanished, and
          ;; never re-marks a token they unmarked on purpose.
          (setq supertag-view-orphan-tags--marked-tokens
                (cl-intersection supertag-view-orphan-tags--marked-tokens tokens
                                 :test #'equal)
                supertag-view-orphan-tags--unmarked-occurrences
                (cl-intersection supertag-view-orphan-tags--unmarked-occurrences keys
                                 :test #'equal))
        ;; A page just opened marks everything: review, then confirm.
        (setq supertag-view-orphan-tags--marked-tokens tokens
              supertag-view-orphan-tags--unmarked-occurrences nil
              supertag-view-orphan-tags--marks-initialized t)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (supertag-view-orphan-tags--insert-masthead
       width (length (supertag-view-orphan-tags--tokens)) (length records)
       (length supertag-view-orphan-tags--marked-tokens)
       (length (supertag-view-orphan-tags--marked-records)))
      (supertag-view-orphan-tags--insert-manifesto width)
      (supertag-view-orphan-tags--insert-action-row)
      (if records
          (dolist (token (supertag-view-orphan-tags--sorted-tokens))
            (supertag-view-orphan-tags--insert-card token width))
        (insert (supertag-view-orphan-tags--fill "NO ORPHAN OCCURRENCES"
                                                 'supertag-view-panel width)
                "\n\n"))
      (supertag-view-orphan-tags--insert-ambiguous width)
      (supertag-view-orphan-tags--insert-colophon
       width (length (supertag-view-orphan-tags--tokens)) (length records))
      (goto-char (point-min))
      (forward-line (1- (max 1 line)))
      (setq header-line-format
            (format " Orphan Tags   %d token(s) / %d occurrence(s)   %d token(s) marked, %d occurrence(s) selected "
                    (length (supertag-view-orphan-tags--tokens))
                    (length records)
                    (length supertag-view-orphan-tags--marked-tokens)
                    (length (supertag-view-orphan-tags--marked-records))))
      (font-lock-flush))))

;;; --- Row lookup and command helpers ---

(defun supertag-view-orphan-tags--at-point (property)
  "Return PROPERTY's value on the page row at point.
The row's own character carries it; the preceding character is consulted only
on a row's newline, so a token row never inherits the occurrence row above."
  (let* ((position (if (and (eobp) (> (point) (point-min)))
                       (1- (point))
                     (point)))
         (value (get-text-property position property)))
    (or value
        (when (and (> position (point-min))
                   (eq ?\n (char-after position)))
          (get-text-property (1- position) property)))))

(defun supertag-view-orphan-tags--visit-record (record)
  "Visit RECORD's file and line."
  (find-file (plist-get record :file))
  (goto-char (point-min))
  (forward-line (1- (plist-get record :line))))

(defun supertag-view-orphan-tags--redraw-keeping-line (&optional advance)
  "Redraw the page holding point's line, optionally moving ADVANCE lines."
  (let ((line (line-number-at-pos)))
    (supertag-view-refresh)
    (goto-char (point-min))
    (forward-line (1- (max 1 line)))
    (when advance (forward-line 1))
    (beginning-of-line)))

;;; --- Commands ---

(defun supertag-view-orphan-tags-mark ()
  "Toggle the mark on the token or occurrence at point, then move down."
  (interactive)
  (let ((key (supertag-view-orphan-tags--at-point 'supertag-view-orphan-tags--occurrence-key))
        (token (supertag-view-orphan-tags--at-point 'supertag-view-orphan-tags--row-token)))
    (cond
     (key
      (if (member key supertag-view-orphan-tags--unmarked-occurrences)
          (progn
            (setq supertag-view-orphan-tags--unmarked-occurrences
                  (delete key supertag-view-orphan-tags--unmarked-occurrences))
            ;; Marking one occurrence keeps its token selected.
            (cl-pushnew token supertag-view-orphan-tags--marked-tokens :test #'equal))
        (push key supertag-view-orphan-tags--unmarked-occurrences)))
     (token
      (if (member token supertag-view-orphan-tags--marked-tokens)
          (setq supertag-view-orphan-tags--marked-tokens
                (delete token supertag-view-orphan-tags--marked-tokens))
        (push token supertag-view-orphan-tags--marked-tokens)
        ;; Re-marking a token selects all of its occurrences again.
        (setq supertag-view-orphan-tags--unmarked-occurrences
              (cl-delete-if (lambda (skipped) (equal token (nth 3 skipped)))
                            supertag-view-orphan-tags--unmarked-occurrences))))
     (t (user-error "No orphan row at point")))
    (supertag-view-orphan-tags--redraw-keeping-line t)))

(defun supertag-view-orphan-tags-unmark ()
  "Unmark the token or occurrence at point, then move down."
  (interactive)
  (let ((key (supertag-view-orphan-tags--at-point 'supertag-view-orphan-tags--occurrence-key))
        (token (supertag-view-orphan-tags--at-point 'supertag-view-orphan-tags--row-token)))
    (cond
     (key
      (unless (member key supertag-view-orphan-tags--unmarked-occurrences)
        (push key supertag-view-orphan-tags--unmarked-occurrences)))
     (token
      (setq supertag-view-orphan-tags--marked-tokens
            (delete token supertag-view-orphan-tags--marked-tokens)
            supertag-view-orphan-tags--unmarked-occurrences
            (cl-delete-if (lambda (skipped) (equal token (nth 3 skipped)))
                          supertag-view-orphan-tags--unmarked-occurrences)))
     (t (user-error "No orphan row at point")))
    (supertag-view-orphan-tags--redraw-keeping-line t)))

(defun supertag-view-orphan-tags-mark-all ()
  "Mark every orphan token and clear the per-occurrence exceptions."
  (interactive)
  (setq supertag-view-orphan-tags--marked-tokens (supertag-view-orphan-tags--tokens)
        supertag-view-orphan-tags--unmarked-occurrences nil)
  (supertag-view-orphan-tags--redraw-keeping-line))

(defun supertag-view-orphan-tags-unmark-all ()
  "Clear every orphan mark."
  (interactive)
  (setq supertag-view-orphan-tags--marked-tokens nil
        supertag-view-orphan-tags--unmarked-occurrences nil)
  (supertag-view-orphan-tags--redraw-keeping-line))

(defun supertag-view-orphan-tags-visit ()
  "Visit the file and line of the orphan occurrence at point."
  (interactive)
  (let* ((key (supertag-view-orphan-tags--at-point 'supertag-view-orphan-tags--occurrence-key))
         (token (supertag-view-orphan-tags--at-point 'supertag-view-orphan-tags--row-token))
         (record (cond
                  (key (cl-find key supertag-view-orphan-tags--records
                                :key #'supertag-view-orphan-tags--occurrence-key
                                :test #'equal))
                  (token (car (supertag-view-orphan-tags--records-for-token token))))))
    (unless record (user-error "No orphan occurrence at point"))
    (supertag-view-orphan-tags--visit-record record)))

(defun supertag-view-orphan-tags-remove ()
  "Remove every marked orphan occurrence: one preview, one confirmation.
The removal itself is the shared text path: the same records, the same
NOT CHANGED section, the same per-file rescan guard and range writes."
  (interactive)
  (let ((page (current-buffer))
        (records (supertag-view-orphan-tags--marked-records)))
    (if (null records)
        (message "No orphan occurrence is marked.")
      (let* ((tokens (delete-dups (mapcar (lambda (record) (plist-get record :token))
                                         records)))
             (skipped (copy-sequence supertag-view-orphan-tags--unmarked-occurrences))
             (near (apply #'append
                          (mapcar (lambda (token)
                                    (supertag-tag--text-near-misses-for-token
                                     token supertag-view-orphan-tags--scan))
                                  tokens))))
        (when (supertag-tag--orphan-remove
               records near
               (lambda ()
                 (supertag-view-orphan-tags--select
                  (supertag-tag--text-orphan-records
                   (supertag-tag--text-scan-current-buffer))
                  tokens skipped))
               tokens nil)
          ;; The preview pops to its own buffer; reflect the result here.
          (with-current-buffer page
            (supertag-view-refresh)))))))

(defun supertag-view-orphan-tags-quit ()
  "Quit the page and restore its original window configuration."
  (interactive)
  (let ((window-config supertag-view-orphan-tags--origin-window-configuration))
    (kill-buffer (current-buffer))
    (when (window-configuration-p window-config)
      (set-window-configuration window-config))))

;;; --- Mode definition ---

(defvar supertag-view-orphan-tags-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "D") #'supertag-view-orphan-tags-remove)
    (define-key map (kbd "m") #'supertag-view-orphan-tags-mark)
    (define-key map (kbd "u") #'supertag-view-orphan-tags-unmark)
    (define-key map (kbd "M") #'supertag-view-orphan-tags-mark-all)
    (define-key map (kbd "U") #'supertag-view-orphan-tags-unmark-all)
    (define-key map (kbd "RET") #'supertag-view-orphan-tags-visit)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "g") #'supertag-view-refresh)
    (define-key map (kbd "q") #'supertag-view-orphan-tags-quit)
    (define-key map (kbd "h") #'describe-mode)
    (define-key map (kbd "?") #'describe-mode)
    map)
  "Keymap for `supertag-view-orphan-tags-mode'.")

(define-derived-mode supertag-view-orphan-tags-mode special-mode "Supertag-Orphans"
  "Major mode for the Supertag Orphan Tags page.

m toggles a mark, u unmarks, M marks every token, U clears the marks,
D removes the marked occurrences after one preview and one confirmation,
RET visits the occurrence's file and line, g rescans the scope,
n/p move, h and ? describe this mode, and q quits.

Modal editing is disabled locally: this page is a single-key action surface.

\\{supertag-view-orphan-tags-mode-map}"
  :keymap supertag-view-orphan-tags-mode-map
  (setq buffer-read-only t
        truncate-lines t)
  (supertag-view-apply-palette-locally 'paper)
  ;; Disabled outright, not switched to motion or emacs state.
  (when (bound-and-true-p meow-mode)
    (meow-mode -1))
  (when (fboundp 'evil-local-mode)
    (ignore-errors (evil-local-mode -1))))

(supertag-view-register-modal-state 'supertag-view-orphan-tags-mode)

;;; --- View registration and entry points ---

(defun supertag-view-orphan-tags--buffer-name (_input)
  "Return the single Orphan Tags buffer name."
  supertag-view-orphan-tags--buffer-name)

(defun supertag-view-orphan-tags--register-view ()
  "Register the Orphan Tags page when needed."
  (unless (supertag-view-get 'orphan-tags)
    (supertag-view-register
     :id 'orphan-tags
     :name "Orphan Tags"
     :selectable nil
     :buffer-name supertag-view-orphan-tags--buffer-name
     :mode-fn #'supertag-view-orphan-tags-mode
     :state-fn #'supertag-view-orphan-tags--build-state
     :render-fn #'supertag-view-orphan-tags--renderer
     :display-action '(display-buffer-same-window))))

;;;###autoload
(defun supertag-view-orphan-tags ()
  "Open the Orphan Tags page.
Every token starts marked, so reviewing then confirming is the default flow:
unmark what to keep and remove the rest with one `D' and one confirmation.
The page never registers, renames or adopts anything; it only removes text the
user marked through the shared delete path."
  (interactive)
  (supertag-view-orphan-tags--register-view)
  (let* ((origin (current-window-configuration))
         (existing (get-buffer supertag-view-orphan-tags--buffer-name)))
    ;; Reopening restores the "everything starts marked" default.
    (when (buffer-live-p existing)
      (with-current-buffer existing
        (setq-local supertag-view-orphan-tags--marks-initialized nil)))
    (let ((buffer (supertag-view-open 'orphan-tags nil)))
      (pop-to-buffer buffer)
      (with-current-buffer buffer
        (setq-local supertag-view-orphan-tags--origin-window-configuration origin))
      buffer)))

;;;###autoload
(defun supertag-report-orphan-tag-occurrences ()
  "Open the Orphan Tags page (see `supertag-view-orphan-tags').
Kept as the Tag command spelling of the same page."
  (interactive)
  (supertag-view-orphan-tags))

(provide 'supertag-view-orphan-tags)

;;; supertag-view-orphan-tags.el ends here
