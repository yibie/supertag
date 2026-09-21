;;; orphan-view-page-test.el --- Orphan Tags view page -*- lexical-binding: t; -*-
;; The orphan report is a Supertag view page, so it owes `design.md' the five
;; bands, one font size, colour as filled area, `NOUN / NOUN' labels, text
;; buttons and a text render that holds at 120 and 80 columns.  Behaviour
;; (one preview, one confirmation, rescan guard, marks) lives in
;; `orphan-bulk-cleanup-test.el'; this file checks the page itself.
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-tag)
(require 'supertag-view-orphan-tags)

(defconst supertag-orphan-page-test--text
  (concat ":PROPERTIES:\n:ID: page-file\n:END:\n"
          "#+TITLE: Page\n"
          "* Hashed #seo\n:PROPERTIES:\n:ID: page-hashed\n:END:\n"
          "Body #seo and #seo, and #old\n"
          "* No ID #seo\nProse #word\n")
  "Fixture: two orphan tokens (`seo', `word') and one resolved tag (`old').")

(defconst supertag-orphan-page-test--plain
  "#+TITLE: Page Copy\n* Other #word\n:PROPERTIES:\n:ID: page-other\n:END:\nKeep\n"
  "Second file so the page shows more than one file.")

(defmacro supertag-orphan-page-test--vault (&rest body)
  "Run BODY on a temp vault holding the page fixtures."
  (declare (indent 0))
  `(supertag-document-test-with-vault
     (supertag-tag-create '(:id "old" :name "old"))
     (with-current-buffer (find-file-noselect file)
       (erase-buffer)
       (insert supertag-orphan-page-test--text)
       (save-buffer))
     (with-current-buffer (find-file-noselect plain)
       (erase-buffer)
       (insert supertag-orphan-page-test--plain)
       (save-buffer))
     (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
     (unwind-protect
         (progn ,@body)
       (dolist (name (list supertag-view-orphan-tags--buffer-name
                           "*Supertag Tag Change*"))
         (when (get-buffer name)
           (with-current-buffer (get-buffer name) (set-buffer-modified-p nil))
           (kill-buffer (get-buffer name)))))))

(defun supertag-orphan-page-test--page-text ()
  "Return the live page's text."
  (with-current-buffer supertag-view-orphan-tags--buffer-name
    (buffer-string)))

(defun supertag-orphan-page-test--render-at (width)
  "Render a fresh page for a WIDTH column pane and return its text.
The buffer is built directly and never displayed, so `window-body-width'
cannot override WIDTH."
  (let ((supertag-view-helper-width-override width)
        (buffer (get-buffer-create supertag-view-orphan-tags--buffer-name)))
    (with-current-buffer buffer
      (supertag-view-orphan-tags-mode)
      (let ((inhibit-read-only t))
        (supertag-view-orphan-tags--renderer
         (supertag-view-orphan-tags--build-state nil)))
      (buffer-string))))

(defun supertag-orphan-page-test--line-widths (text)
  "Return TEXT's line widths."
  (mapcar #'string-width (split-string text "\n" nil)))

(defun supertag-orphan-page-test--face-at (text needle)
  "Return the `face' property on the first NEEDLE inside the current buffer.
TEXT is only used to make the failure message readable."
  (goto-char (point-min))
  (unless (search-forward needle nil t)
    (ert-fail (format "Missing %S in page:\n%s" needle text)))
  (get-text-property (match-beginning 0) 'face))

(ert-deftest supertag-orphan-page-opens-through-the-view-framework ()
  (supertag-orphan-page-test--vault
    (let ((buffer (supertag-view-open 'orphan-tags nil)))
      (should (equal supertag-view-orphan-tags--buffer-name (buffer-name buffer)))
      (with-current-buffer buffer
        (should (eq 'supertag-view-orphan-tags-mode major-mode))
        (should (equal "Orphan Tags" (plist-get (supertag-view-get 'orphan-tags) :name)))
        (should-not (plist-get (supertag-view-get 'orphan-tags) :selectable))))))

(ert-deftest supertag-orphan-page-shows-all-five-bands ()
  (supertag-orphan-page-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences)))
      (with-current-buffer buffer
        (let ((text (buffer-string)))
          ;; Band 1: masthead, `NOUN / NOUN' brand on the left.
          (should (string-match-p "^ SUPERTAG / ORPHANS " text))
          ;; Band 2: manifesto, uppercase label lines then one sentence.
          (should (string-match-p "METADATA / NOT GARBAGE\\." text))
          (should (string-match-p "TOKENS / NO TAG OWNS\\." text))
          (should (string-match-p "Orphan tokens are text no Tag entity owns\\." text))
          ;; Band 3: actions as text buttons.
          (should (string-match-p "\\[ REMOVE \\]" text))
          ;; Band 4: one card per token, each with its occurrence rows.
          (should (string-match-p "\\* #seo" text))
          (should (string-match-p "→ [0-9]+  " text))
          (should (string-match-p "Body #seo" text))
          ;; Band 5: colophon with the ornament rule and page numbering.
          (should (string-match-p "^\\+ \\. \\+ \\. \\+ \\.$" text))
          (should (string-match-p "^ 01 / ORPHAN FIELD" text))
          (should (string-match-p "LIVE TEXT SCAN" text))
          (should (string-match-p "^SUPERTAG / ORPHANS$" text)))))))

(ert-deftest supertag-orphan-page-actions-are-plain-text-buttons ()
  (supertag-orphan-page-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences)))
      (with-current-buffer buffer
        (dolist (label '("[ REMOVE ]" "[ MARK ALL ]" "[ UNMARK ALL ]" "[ REFRESH ]"))
          (let ((face (supertag-orphan-page-test--face-at (buffer-string) label)))
            (should (equal 'widget-button face))
            ;; A text button, not a coloured chip.
            (should-not (string-prefix-p "supertag-view-chip" (format "%s" face)))))
        (goto-char (point-min))
        (search-forward "[ REMOVE ]")
        (let* ((position (match-beginning 0))
               (button (button-at position)))
          (should button)
          (should (button-get button 'action))
          ;; RET and the mouse activate; `follow-link' carries mouse-1.
          (should (eq 'push-button
                      (lookup-key (get-text-property position 'keymap) (kbd "RET"))))
          (should (eq 'push-button
                      (lookup-key (get-text-property position 'keymap) [mouse-2])))
          (should (eq t (get-text-property position 'follow-link))))
        ;; The listed key runs the same command as the button.
        (should (eq #'supertag-view-orphan-tags-remove
                    (key-binding (kbd "D"))))))))

(ert-deftest supertag-orphan-page-uses-the-paper-palette-at-one-size ()
  (supertag-orphan-page-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences)))
      (with-current-buffer buffer
        (should (eq 'paper supertag-view--local-palette))
        ;; Colour is filled area on role faces, never a font size.
        (dolist (entry (cdr (assq 'paper supertag-view-palettes)))
          (should-not (plist-member (cadr entry) :height))
          (should-not (plist-member (cddr entry) :height)))))))

(ert-deftest supertag-orphan-page-buttons-and-fills-carry-no-ink-colour ()
  (supertag-orphan-page-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences)))
      (with-current-buffer buffer
        (let ((text (buffer-string)))
          (should (equal 'supertag-view-chip1
                         (supertag-orphan-page-test--face-at text "SUPERTAG / ORPHANS")))
          (should (equal 'supertag-view-panel
                         (supertag-orphan-page-test--face-at text "METADATA / NOT GARBAGE.")))
          ;; Card titles rotate through the three chip fills.
          (should (memq (supertag-orphan-page-test--face-at text "* #seo")
                        '(supertag-view-chip1 supertag-view-chip2 supertag-view-chip3)))
          ;; The occurrence row's link is a button on the line text.
          (should (equal 'supertag-view-entry
                         (supertag-orphan-page-test--face-at text "Body #seo"))))))))

(ert-deftest supertag-orphan-page-renders-at-120-and-80-columns ()
  (supertag-orphan-page-test--vault
    (let* ((wide (supertag-orphan-page-test--render-at 120))
           (narrow (supertag-orphan-page-test--render-at 80)))
      (dolist (case (list (cons 120 wide) (cons 80 narrow)))
        (let ((width (car case))
              (text (cdr case)))
          (should (cl-every (lambda (w) (<= w width))
                            (supertag-orphan-page-test--line-widths text)))
          (should (string-match-p "SUPERTAG / ORPHANS" text))
          (should (string-match-p "\\[ REMOVE \\]" text))
          (should (string-match-p "\\* #seo" text))
          (should (string-match-p "01 / ORPHAN FIELD" text))))
      ;; The narrow pane drops the manifesto's sentence instead of overflowing.
      (should (string-match-p "METADATA / NOT GARBAGE\\." (cdr (assq 80 (list (cons 80 narrow))))))
      (should (<= (apply #'max (supertag-orphan-page-test--line-widths wide)) 120))
      (should (<= (apply #'max (supertag-orphan-page-test--line-widths narrow)) 80)))))

(ert-deftest supertag-orphan-page-mark-keys-work-on-a-card-title ()
  (supertag-orphan-page-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences)))
      (with-current-buffer buffer
        ;; Every token starts marked.
        (should (equal '("seo" "word")
                       (sort (copy-sequence supertag-view-orphan-tags--marked-tokens) #'string<)))
        ;; Point on the card title (a fill, not a button) still names the token.
        (goto-char (point-min))
        (search-forward "* #seo")
        (beginning-of-line)
        (should (equal "seo" (supertag-view-orphan-tags--at-point 'supertag-view-orphan-tags--row-token)))
        (call-interactively #'supertag-view-orphan-tags-unmark)
        (should (equal '("word") supertag-view-orphan-tags--marked-tokens))
        ;; `g' re-reads the scope but never re-marks a deliberate unmark.
        (call-interactively #'supertag-view-refresh)
        (should (equal '("word") supertag-view-orphan-tags--marked-tokens))
        ;; Marking a card title marks the token and all its occurrences again.
        (goto-char (point-min))
        (re-search-forward "#seo" nil t)
        (beginning-of-line)
        (call-interactively #'supertag-view-orphan-tags-mark)
        (should (equal '("seo" "word")
                       (sort (copy-sequence supertag-view-orphan-tags--marked-tokens) #'string<)))
        (should-not supertag-view-orphan-tags--unmarked-occurrences)))))

(ert-deftest supertag-orphan-page-ambiguous-tokens-are-listed-and-refused ()
  (supertag-orphan-page-test--vault
    ;; The store refuses alias collisions, so a stub stands in for the
    ;; ambiguous case: resolution signals, so the token is not an orphan.
    (let ((real (symbol-function 'supertag-tag-resolve-occurrence)))
      (cl-letf (((symbol-function 'supertag-tag-resolve-occurrence)
                 (lambda (token &rest args)
                   (if (equal token "seo")
                       (error "Ambiguous Tag token")
                     (apply real token args)))))
        (let ((buffer (supertag-report-orphan-tag-occurrences)))
          (with-current-buffer buffer
            (let ((text (buffer-string)))
              (should (string-match-p "AMBIGUOUS / 1 TOKENS, NOT ORPHANS" text))
              (should (string-match-p "#seo" text))
              ;; An ambiguous token is not an orphan, so it is never removed.
              (should-error (supertag-cleanup-orphan-tag-occurrences "seo")
                            :type 'user-error)
              (should (equal '("word") supertag-view-orphan-tags--marked-tokens)))))))))

(ert-deftest supertag-orphan-page-mode-disables-meow-locally ()
  (unless (fboundp 'meow-mode)
    (define-minor-mode meow-mode
      "Dummy buffer-local Meow mode for Orphan Tags page tests."
      :init-value nil
      :lighter nil))
  (let ((old-default (default-value 'meow-mode)))
    (unwind-protect
        (progn
          ;; A major-mode transition clears buffer locals, so use the default
          ;; value to model a globally enabled buffer-local mode.
          (setq-default meow-mode t)
          (with-temp-buffer
            (supertag-view-orphan-tags-mode)
            (should-not meow-mode)))
      (setq-default meow-mode old-default))))

(defvar evil-emacs-state-modes)

(ert-deftest supertag-orphan-page-mode-registers-with-evil-as-emacs ()
  (let ((evil-emacs-state-modes nil)
        calls)
    (let ((real-featurep (symbol-function 'featurep)))
      (cl-letf (((symbol-function 'featurep)
                 (lambda (feature &optional subfeature)
                   (or (eq feature 'evil)
                       (funcall real-featurep feature subfeature))))
                ((symbol-function 'evil-set-initial-state)
                 (lambda (mode state) (push (cons mode state) calls))))
        (supertag-view-register-modal-state 'supertag-view-orphan-tags-mode)
        (supertag-view-register-modal-state 'supertag-view-orphan-tags-mode)))
    (should (equal evil-emacs-state-modes '(supertag-view-orphan-tags-mode)))
    ;; Each registration applies immediately and again through the already
    ;; loaded Evil callback.  Both paths must select the same state.
    (should (equal calls (make-list 4 '(supertag-view-orphan-tags-mode . emacs))))))

(ert-deftest supertag-orphan-page-quit-restores-the-windows ()
  (supertag-orphan-page-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences)))
      (with-current-buffer buffer
        (should (eq 'supertag-view-orphan-tags-quit
                    (key-binding (kbd "q"))))
        (call-interactively #'supertag-view-orphan-tags-quit))
      (should-not (buffer-live-p buffer)))))

(provide 'orphan-view-page-test)
;;; orphan-view-page-test.el ends here
