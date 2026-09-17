;;; delete-everywhere-text-test.el --- Org-text Tag deletion -*- lexical-binding: t; -*-
;; `supertag-delete-tag-everywhere' enumerates occurrences from Org text, so a
;; heading without `:ID:', a duplicate-ID copy and a FILETAGS entry are found,
;; while rejected `#name' text (src blocks, links, drawers, keyword lines,
;; commented headings) is reported as not-changed and never rewritten.
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-tag)
(require 'supertag-services-sync)
(require 'supertag-view-tags)

(defconst supertag-delete-everywhere-test--text
  (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
          "#+TITLE: File\n"
          "#+FILETAGS: :old:\n"
          "* Plain #old\n:PROPERTIES:\n:ID: hashed\n:END:\nbody #old here\n"
          "* No ID #old\nProse #old\n"
          "* Src block\n#+BEGIN_SRC css\n.a { color: #old; }\n#+END_SRC\n"
          "Link [[https://example.org][see #old]] and text\n"
          "* Drawer holder\n:PROPERTIES:\n:NOTE: #old\n:END:\n"
          "#+CAPTION: META #old\n"
          "* COMMENT hidden #old\n")
  "Fixture text carrying every accepted and rejected occurrence shape.")

(defmacro supertag-delete-everywhere-test--vault (text &rest body)
  "Run BODY on a temp vault whose node.org holds TEXT and whose Store has `old'."
  (declare (indent 1))
  `(supertag-document-test-with-vault
     (supertag-tag-create '(:id "old" :name "old"))
     (with-current-buffer (find-file-noselect file)
       (erase-buffer)
       (insert ,text)
       (save-buffer))
     (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
     (unwind-protect
         (progn ,@body)
       (dolist (name '("*Supertag Tag Change*" "*Supertag Orphan Tags*" "*Supertag Tags*"))
         (when (get-buffer name)
           (with-current-buffer (get-buffer name) (set-buffer-modified-p nil))
           (kill-buffer (get-buffer name)))))))

(defun supertag-delete-everywhere-test--preview-text ()
  "Return the current text preview buffer's contents."
  (with-current-buffer (get-buffer-create "*Supertag Tag Change*")
    (buffer-string)))

(defun supertag-delete-everywhere-test--confirm-capture (state &optional on-prompt)
  "Return a `yes-or-no-p' stub recording its prompt and the shown preview.
ON-PROMPT runs after the preview was captured, which is where text must
change to exercise the rescan guard."
  (lambda (prompt)
    (setcar state prompt)
    (setcdr state (supertag-delete-everywhere-test--preview-text))
    (when on-prompt (funcall on-prompt))
    t))

(defun supertag-delete-everywhere-test--report-text ()
  "Return the orphan report buffer's contents."
  (with-current-buffer (get-buffer-create "*Supertag Orphan Tags*")
    (buffer-string)))

(ert-deftest supertag-delete-everywhere-text-covers-no-id-headings-and-filetags ()
  "A no-`:ID:' heading and a FILETAGS entry are previewed and removed."
  (supertag-delete-everywhere-test--vault
      supertag-delete-everywhere-test--text
    (let ((state (cons nil nil)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (supertag-delete-everywhere-test--confirm-capture state)))
        (should (supertag-delete-tag-everywhere "old")))
      (should (string-match-p "rewrite 5 occurrence(s) in 1 file(s)" (car state)))
      (let ((shown (cdr state)))
        (should (string-match-p "WILL CHANGE: 5" shown))
        (should (string-match-p "NOT CHANGED: 5" shown))
        (dolist (part '("FILETAGS" "heading :ID: hashed" "heading without :ID:"))
          (should (string-match-p (regexp-quote part) shown)))
        (dolist (part '("not a Tag: src or example block"
                        "not a Tag: link path or description"
                        "not a Tag: property drawer"
                        "not a Tag: keyword line"
                        "not a Tag: commented heading"))
          (should (string-match-p (regexp-quote part) shown)))))
    (let ((disk (supertag-document-test-disk file)))
      (should-not (string-match-p ":old:" disk))
      (should-not (string-match-p "\\* Plain #old" disk))
      (should-not (string-match-p "\\* No ID #old" disk))
      (should-not (string-match-p "Prose #old" disk))
      (should-not (string-match-p "body #old here" disk))
      ;; The range edit removed the occurrence and nothing else.
      (should (string-match-p "body  here" disk))
      ;; Rejected text stays byte for byte.
      (should (string-match-p (regexp-quote ".a { color: #old; }") disk))
      (should (string-match-p (regexp-quote "[[https://example.org][see #old]]") disk))
      (should (string-match-p (regexp-quote ":NOTE: #old") disk))
      (should (string-match-p (regexp-quote "#+CAPTION: META #old") disk))
      (should (string-match-p (regexp-quote "* COMMENT hidden #old") disk)))
    (should-not (supertag-tag-get "old"))
    (should-not (supertag-find-nodes-by-tag "old"))
    (with-current-buffer (find-file-noselect file)
      (should-not (buffer-modified-p))
      (should (equal (buffer-string) (supertag-document-test-disk file))))))

(ert-deftest supertag-delete-everywhere-text-labels-a-duplicate-id-copy ()
  "A second file holding the same `:ID:' is scanned and labelled duplicate."
  (supertag-delete-everywhere-test--vault
      (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
              "* Plain #old\n:PROPERTIES:\n:ID: hashed\n:END:\nBody\n")
    ;; Written after the reindex: the Store still points `hashed' at node.org.
    (with-temp-file plain
      (insert "#+TITLE: Copy\n* Stale copy #old\n:PROPERTIES:\n:ID: hashed\n:END:\nKeep\n"))
    (let ((state (cons nil nil)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (supertag-delete-everywhere-test--confirm-capture state)))
        (should (supertag-delete-tag-everywhere "old")))
      (should (string-match-p "duplicate :ID: (Store points at another file)"
                              (cdr state))))
    (let ((main (supertag-document-test-disk file))
          (copy (supertag-document-test-disk plain)))
      (should-not (string-match-p "#old" main))
      (should-not (string-match-p "#old" copy))
      (should (string-match-p "Keep" copy)))
    (should-not (supertag-tag-get "old"))))

(ert-deftest supertag-delete-everywhere-text-keeps-the-entity-when-text-remains ()
  "Text that changed since the preview aborts the file and keeps the entity."
  (supertag-delete-everywhere-test--vault
      ":PROPERTIES:\n:ID: file-node\n:END:\n* Plain #old\n:PROPERTIES:\n:ID: hashed\n:END:\nBody\n"
    (let ((disk-before (supertag-document-test-disk file))
          (state (cons nil nil)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (supertag-delete-everywhere-test--confirm-capture
                  state
                  (lambda ()
                    (with-current-buffer (find-file-noselect file)
                      (goto-char (point-max))
                      (insert "Late #old\n"))))))
        (should (supertag-delete-tag-everywhere "old")))
      ;; The file is left untouched on disk; nothing the user typed is reverted.
      (should (equal disk-before (supertag-document-test-disk file)))
      (with-current-buffer (find-file-noselect file)
        (should (buffer-modified-p))
        (should (= 2 (how-many "#old" (point-min) (point-max)))))
      (should (supertag-tag-get "old"))
      (should (supertag-find-nodes-by-tag "old"))
      (let ((shown (supertag-delete-everywhere-test--preview-text)))
        (should (string-match-p "NOT REMOVED: 2" shown))
        (should (string-match-p "Tag kept" shown)))
      (message nil))))

(ert-deftest supertag-delete-everywhere-text-aborts-only-the-changed-file ()
  "A changed file aborts while an untouched file still loses the tag."
  (supertag-delete-everywhere-test--vault
      (concat ":PROPERTIES:\n:ID: file-node\n:END:\n* Plain #old\n"
              ":PROPERTIES:\n:ID: hashed\n:END:\nBody\n")
    (with-temp-file plain
      (insert "#+TITLE: Other\n* Other #old\n:PROPERTIES:\n:ID: other\n:END:\nKeep\n"))
    (let ((plain-before (supertag-document-test-disk plain))
          (state (cons nil nil)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (supertag-delete-everywhere-test--confirm-capture
                  state
                  (lambda ()
                    (with-current-buffer (find-file-noselect file)
                      (goto-char (point-max))
                      (insert "Late #old\n"))))))
        (should (supertag-delete-tag-everywhere "old")))
      ;; file.org changed after the preview: untouched.  plain.org did not.
      (with-current-buffer (find-file-noselect file)
        (should (buffer-modified-p))
        (should (= 2 (how-many "#old" (point-min) (point-max)))))
      (let ((plain-after (supertag-document-test-disk plain)))
        (should-not (string-match-p "#old" plain-after))
        (should (string-match-p "Keep" plain-after)))
      (should (supertag-tag-get "old")))))

(ert-deftest supertag-delete-everywhere-text-orphan-report-and-cleanup ()
  "Orphans are reported read-only and only the chosen token is removed."
  (supertag-delete-everywhere-test--vault
      (concat "* Kept #old\n:PROPERTIES:\n:ID: kept\n:END:\nBody\n"
              "* Never #never\nProse #never again\n"
              "* Broken\n#+BEGIN_SRC css\n.a { color: #never; }\n#+END_SRC\n"
              "Link [[https://example.org][see #never]]\n")
    (let ((before (list (supertag-document-test-disk file)
                        (prin1-to-string supertag--store))))
      (should (equal (supertag-report-orphan-tag-occurrences)
                     (get-buffer "*Supertag Orphan Tags*")))
      (let ((report (supertag-delete-everywhere-test--report-text)))
        (should (string-match-p "#never: 2" report))
        (should (string-match-p "nothing is cleaned by default" report)))
      ;; The report writes nothing at all.
      (should (equal before (list (supertag-document-test-disk file)
                                  (prin1-to-string supertag--store)))))
    (should-error (supertag-cleanup-orphan-tag-occurrences "old") :type 'user-error)
    (let ((before (list (supertag-document-test-disk file)
                        (prin1-to-string supertag--store))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-not (supertag-cleanup-orphan-tag-occurrences "never")))
      (should (equal before (list (supertag-document-test-disk file)
                                  (prin1-to-string supertag--store)))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (supertag-cleanup-orphan-tag-occurrences "never")))
    (let ((disk (supertag-document-test-disk file)))
      (should-not (string-match-p "\\* Never #never" disk))
      (should-not (string-match-p "Prose #never again" disk))
      ;; Rejected text and the registered tag's own text are untouched.
      (should (string-match-p (regexp-quote ".a { color: #never; }") disk))
      (should (string-match-p (regexp-quote "[[https://example.org][see #never]]") disk))
      (should (string-match-p "\\* Kept #old" disk)))
    (should (supertag-tag-get "old"))))

(ert-deftest supertag-delete-everywhere-text-bulk-tag-manager-shows-preview ()
  "The bulk Tag Manager path previews Org text before its single confirmation."
  (supertag-delete-everywhere-test--vault
      (concat "* Alpha #alpha\n:PROPERTIES:\n:ID: alpha-node\n:END:\nBody\n"
              "* Beta #beta\n:PROPERTIES:\n:ID: beta-node\n:END:\nBody\n")
    (supertag-tag-create '(:id "alpha" :name "alpha"))
    (supertag-tag-create '(:id "beta" :name "beta"))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (supertag-view-tags--register-view)
    (let ((buffer (supertag-view-tags))
          (state (cons nil nil))
          (confirmations 0))
      (unwind-protect
          (with-current-buffer buffer
            (setq supertag-view-tags--marked-ids '("alpha" "beta"))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt)
                         (cl-incf confirmations)
                         (funcall (supertag-delete-everywhere-test--confirm-capture state)
                                  prompt))))
              (supertag-view-tags-delete))
            (should (= 1 confirmations))
            (should (string-match-p "Delete 2 tags (alpha, beta) everywhere?"
                                    (car state)))
            (should (string-match-p (regexp-quote
                                     "everywhere? 2 occurrence(s) in 1 file(s)")
                                    (car state)))
            (let ((shown (cdr state)))
              (should (string-match-p "WILL CHANGE: 2" shown))
              (should (string-match-p "\\* Alpha #alpha" shown))
              (should (string-match-p "\\* Beta #beta" shown)))
            (should-not supertag-view-tags--marked-ids))
        (when (buffer-live-p buffer) (kill-buffer buffer))))
    (let ((disk (supertag-document-test-disk file)))
      (should-not (string-match-p "#alpha\\|#beta" disk)))
    (should-not (supertag-tag-get "alpha"))
    (should-not (supertag-tag-get "beta"))))

;;; delete-everywhere-text-test.el ends here
