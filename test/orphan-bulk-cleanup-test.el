;;; orphan-bulk-cleanup-test.el --- Actionable orphan cleanup -*- lexical-binding: t; -*-
;; The orphan report is an actionable buffer: every token starts marked, `D'
;; removes the marked occurrences after one preview and one confirmation, and
;; the non-interactive entry takes a token list without any minibuffer.
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-tag)
(require 'supertag-services-sync)

(defconst supertag-orphan-tags-test--text
  (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
          "#+TITLE: File\n"
          "* Hashed #seo\n:PROPERTIES:\n:ID: hashed\n:END:\n"
          "Body #seo and #seo, and #old\n"
          "* No ID #seo\nProse #word\n"
          "* Rejected\n#+BEGIN_SRC css\n.x { color: #seo; }\n#+END_SRC\n"
          "Link [[https://example.org][see #seo]] and text\n"
          "#+CAPTION: META #seo\n"
          "* COMMENT hidden #seo\n")
  "Fixture with `#seo'/`#seo,'/`#word' orphans, `#old' resolved, and four
rejected `#seo' look-alikes that must never change.")

(defconst supertag-orphan-tags-test--plain
  "#+TITLE: Copy\n* Other #word\n:PROPERTIES:\n:ID: other\n:END:\nKeep\n"
  "Second file so multi-file cleanup and per-file aborts are real.")

(defmacro supertag-orphan-tags-test--vault (&rest body)
  "Run BODY on a temp vault holding the orphan fixtures."
  (declare (indent 0))
  `(supertag-document-test-with-vault
     (supertag-tag-create '(:id "old" :name "old"))
     (with-current-buffer (find-file-noselect file)
       (erase-buffer)
       (insert supertag-orphan-tags-test--text)
       (save-buffer))
     (with-current-buffer (find-file-noselect plain)
       (erase-buffer)
       (insert supertag-orphan-tags-test--plain)
       (save-buffer))
     (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
     (unwind-protect
         (progn ,@body)
       (dolist (name '("*Supertag Orphan Tags*" "*Supertag Tag Change*"))
         (when (get-buffer name)
           (with-current-buffer (get-buffer name) (set-buffer-modified-p nil))
           (kill-buffer (get-buffer name)))))))

(defun supertag-orphan-tags-test--preview-text ()
  "Return the current `*Supertag Tag Change*' preview text."
  (with-current-buffer (get-buffer-create "*Supertag Tag Change*")
    (buffer-string)))

(defun supertag-orphan-tags-test--confirm-capture (state &optional on-prompt)
  "Return a `yes-or-no-p' stub recording its prompt and the shown preview in STATE.
ON-PROMPT runs after the preview was captured, so text can change between the
preview and the write."
  (lambda (prompt)
    (setcar state prompt)
    (setcdr state (supertag-orphan-tags-test--preview-text))
    (when on-prompt (funcall on-prompt))
    t))

(ert-deftest supertag-orphan-tags-bulk-remove-all-in-one-confirmation ()
  "Every token starts marked; one D clears all orphans with one preview."
  (supertag-orphan-tags-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences))
          (confirmations 0)
          (state (cons nil nil)))
      (with-current-buffer buffer
        (should (eq 'supertag-view-orphan-tags-mode major-mode))
        (should (equal (sort (copy-sequence supertag-view-orphan-tags--marked-tokens)
                             #'string<)
                       '("seo" "word")))
        (should (= 6 (length supertag-view-orphan-tags--records)))
        (should (string-match-p "2 token(s) marked, 6 occurrence(s) selected"
                                header-line-format))
        (let ((report (buffer-string)))
          ;; `#seo,' is the sentence-final occurrence of `seo', not a token of
          ;; its own, so one card holds all four of its occurrences.
          (should (string-match-p "\\* #seo" report))
          (should (string-match-p "→ [0-9]+  node\\.org  \\[heading :ID: hashed\\]  Body #seo and #seo, and #old"
                                  report))))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (prompt) (cl-incf confirmations)
                   (funcall (supertag-orphan-tags-test--confirm-capture state)
                            prompt))))
        (with-current-buffer buffer
          (call-interactively #'supertag-view-orphan-tags-remove)))
      (should (= 1 confirmations))
      (should (string-match-p (regexp-quote "Remove 6 orphan occurrence(s) in 2 file(s)?")
                              (car state)))
      (should (string-match-p "6 orphan occurrence(s)" (car state)))
      (let ((shown (cdr state)))
        (should (string-match-p "WILL CHANGE: 6" shown))
        (dolist (part '("* Hashed #seo" "Body #seo and #seo, and #old"
                        "Prose #word" "* Other #word"))
          (should (string-match-p (regexp-quote part) shown)))
        (dolist (part '("not a Tag: src or example block"
                        "not a Tag: link path or description"
                        "not a Tag: keyword line"
                        "not a Tag: commented heading"))
          (should (string-match-p (regexp-quote part) shown))))
      ;; Every orphan is gone; the registered Tag keeps its own text.
      (let ((main (supertag-document-test-disk file))
            (copy (supertag-document-test-disk plain)))
        (should-not (string-match-p "\\* Hashed #seo" main))
        (should-not (string-match-p "\\* No ID #seo" main))
        (should-not (string-match-p "and #seo," main))
        (should-not (string-match-p "Prose #word" main))
        (should-not (string-match-p "\\* Other #word" copy))
        (should (string-match-p "#old" main))
        (should (string-match-p "Keep" copy))
        (dolist (part '(".x { color: #seo; }" "[[https://example.org][see #seo]]"
                        "#+CAPTION: META #seo" "* COMMENT hidden #seo"))
          (should (string-match-p (regexp-quote part) main))))
      (should (supertag-tag-get "old"))
      (should-not (supertag-tag-resolve-occurrence "seo"))
      ;; The report refreshes itself to what is left.
      (with-current-buffer buffer
        (should-not (supertag-view-orphan-tags--tokens))
        (should-not supertag-view-orphan-tags--records)
        (should (string-match-p "0 token(s) marked" header-line-format))))))

(ert-deftest supertag-orphan-tags-unmarked-token-survives ()
  "Unmarking one token leaves exactly that token's text untouched."
  (supertag-orphan-tags-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences)))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "#word")
        (beginning-of-line)
        (call-interactively #'supertag-view-orphan-tags-unmark)
        (should (equal (sort (copy-sequence supertag-view-orphan-tags--marked-tokens)
                             #'string<)
                       '("seo")))
        (should (= 4 (length (supertag-view-orphan-tags--marked-records))))
        ;; The unmarked token shows no mark prefix, and its occurrence rows are
        ;; still the exact lines the page lists.
        (should-not (string-match-p "\\* #word" (buffer-string)))
        (should (string-match-p "→ [0-9]+  node\\.org  \\[heading without :ID:\\]  Prose #word"
                                (buffer-string))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (with-current-buffer buffer
          (call-interactively #'supertag-view-orphan-tags-remove)))
      (let ((main (supertag-document-test-disk file))
            (copy (supertag-document-test-disk plain)))
        (should (string-match-p "Prose #word" main))
        (should (string-match-p "\\* Other #word" copy))
        (should-not (string-match-p "\\* Hashed #seo" main))
        (should-not (string-match-p "\\* No ID #seo" main))
        (should-not (string-match-p "and #seo," main)))
      (with-current-buffer buffer
        (should (equal (supertag-view-orphan-tags--tokens) '("word")))))))

(ert-deftest supertag-view-orphan-tags-mark-all-and-unmark-all ()
  "`M' and `U' drive the whole mark set."
  (supertag-orphan-tags-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences)))
      (with-current-buffer buffer
        (call-interactively #'supertag-view-orphan-tags-unmark-all)
        (should-not supertag-view-orphan-tags--marked-tokens)
        (should-not (supertag-view-orphan-tags--marked-records))
        (should (string-match-p "0 token(s) marked, 0 occurrence(s) selected"
                                header-line-format))
        (call-interactively #'supertag-view-orphan-tags-mark-all)
        (should (= 2 (length supertag-view-orphan-tags--marked-tokens)))
        (should (= 6 (length (supertag-view-orphan-tags--marked-records))))
        (should (string-match-p "2 token(s) marked, 6 occurrence(s) selected"
                                header-line-format))))))

(ert-deftest supertag-view-orphan-tags-visit-opens-the-occurrence-line ()
  "RET visits the file and line of the occurrence at point."
  (supertag-orphan-tags-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences))
          expected-file expected-line)
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "Body #seo and #seo, and #old")
        (beginning-of-line)
        (let* ((key (get-text-property (point) 'supertag-view-orphan-tags--occurrence-key))
               (record (and key (cl-find key supertag-view-orphan-tags--records
                                         :key #'supertag-view-orphan-tags--occurrence-key
                                         :test #'equal))))
          (should record)
          (setq expected-file (plist-get record :file)
                expected-line (plist-get record :line)))
        (call-interactively #'supertag-view-orphan-tags-visit)
        ;; Still inside the report's `with-current-buffer': the visit switched buffers.
        (should (equal (file-truename (buffer-file-name)) expected-file))
        (should (= expected-line (line-number-at-pos)))
        (should (equal (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position))
                       "Body #seo and #seo, and #old"))))))

(ert-deftest supertag-orphan-tags-cleanup-list-needs-no-minibuffer ()
  "The non-interactive entry clears a token list without any minibuffer."
  (supertag-orphan-tags-test--vault
    (let ((asked nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (setq asked t) (ert-fail "minibuffer used")))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (should (supertag-cleanup-orphan-tag-occurrences '("seo"))))
      (should-not asked)
      (let ((main (supertag-document-test-disk file)))
        ;; `seo' also owns `#seo,', so one name clears both spellings.
        (should-not (string-match-p "and #seo," main))
        (should-not (string-match-p "\\* Hashed #seo" main))
        (should (string-match-p "#old" main))
        (should (string-match-p "Prose #word" main)))))
  (supertag-orphan-tags-test--vault
    (let ((asked nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (setq asked t) (ert-fail "minibuffer used"))))
        (should-error (supertag-cleanup-orphan-tag-occurrences "old")
                      :type 'user-error))
      (should-not asked)
      ;; No argument clears every orphan token, still without a minibuffer.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (should (supertag-cleanup-orphan-tag-occurrences)))
      (let ((main (supertag-document-test-disk file))
            (copy (supertag-document-test-disk plain)))
        (should-not (string-match-p "\\* Hashed #seo" main))
        (should-not (string-match-p "Prose #word" main))
        (should-not (string-match-p "\\* Other #word" copy))
        (should (string-match-p (regexp-quote ".x { color: #seo; }") main))))))

(ert-deftest supertag-orphan-tags-rescan-aborts-only-the-changed-file ()
  "A file edited after the preview is skipped; the other file is still cleaned."
  (supertag-orphan-tags-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences))
          (state (cons nil nil)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (supertag-orphan-tags-test--confirm-capture
                  state
                  (lambda ()
                    ;; An accepted position: prose in the un-IDed heading.
                    (with-current-buffer (find-file-noselect file)
                      (goto-char (point-min))
                      (search-forward "Prose #word")
                      (end-of-line)
                      (insert "\nLate #seo"))))))
        (with-current-buffer buffer
          (call-interactively #'supertag-view-orphan-tags-remove)))
      ;; node.org changed after the preview: untouched, user's edit preserved.
      (with-current-buffer (find-file-noselect file)
        (should (buffer-modified-p))
        (should (string-match-p "Late #seo" (buffer-string)))
        (should (string-match-p "Prose #word" (buffer-string))))
      ;; plain.org did not change: its orphan is gone.
      (let ((copy (supertag-document-test-disk plain)))
        (should-not (string-match-p "#word" copy))
        (should (string-match-p "Keep" copy)))
      (let ((shown (cdr state)))
        (should (string-match-p "WILL CHANGE: 6" shown))
        (should (string-match-p "\\* Other #word" shown))))))

(ert-deftest supertag-view-orphan-tags-refresh-keeps-deliberate-unmarks ()
  "`g' re-reads the scope without undoing the marks the user set."
  (supertag-orphan-tags-test--vault
    (let ((buffer (supertag-report-orphan-tag-occurrences)))
      (with-current-buffer buffer
        (call-interactively #'supertag-view-orphan-tags-unmark-all)
        (goto-char (point-min))
        (re-search-forward "#seo" nil t)
        (beginning-of-line)
        (call-interactively #'supertag-view-orphan-tags-mark)
        (should (equal supertag-view-orphan-tags--marked-tokens '("seo")))
        (call-interactively #'supertag-view-refresh)
        (should (equal supertag-view-orphan-tags--marked-tokens '("seo")))
        (should (= 4 (length (supertag-view-orphan-tags--marked-records))))
        (should (= 6 (length supertag-view-orphan-tags--records)))))))

;;; orphan-bulk-cleanup-test.el ends here
