;;; rename-merge-text-test.el --- Rename/merge over Org text -*- lexical-binding: t; -*-
;; Rename uses the same text enumerator as delete, so a heading without
;; `:ID:', its body prose, a duplicate-`:ID:' copy and a FILETAGS entry are
;; rewritten; the preview is shown and confirmed first, and the write runs
;; back to front so replacements that change the byte length cannot corrupt
;; later positions.
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-tag)
(require 'supertag-services-sync)

(defconst supertag-rename-merge-text--text
  (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
          "#+TITLE: File\n"
          "#+FILETAGS: :old:\n"
          "* Hashed #old\n:PROPERTIES:\n:ID: hashed\n:END:\nbody #old here\n"
          "* No ID #old\nProse #old\n"
          "* Shapes\n#+BEGIN_SRC css\n.a { color: #old; }\n#+END_SRC\n"
          "Link [[https://example.org][see #old]] and text\n"
          "* Drawer holder\n:PROPERTIES:\n:NOTE: #old\n:END:\n")
  "Fixture text: FILETAGS, a projected heading, a no-ID heading and rejected shapes.")

(defconst supertag-rename-merge-text--plain
  "#+TITLE: Copy\n* Stale copy #old\n:PROPERTIES:\n:ID: hashed\n:END:\nKeep\n"
  "Duplicate-`:ID:' copy of node.org's `hashed' heading.")

(defmacro supertag-rename-merge-text--vault (&rest body)
  "Run BODY on a temp vault with tag `old' written over both fixture files."
  (declare (indent 0))
  `(supertag-document-test-with-vault
     (supertag-tag-create '(:id "old" :name "old"))
     (with-current-buffer (find-file-noselect file)
       (erase-buffer)
       (insert supertag-rename-merge-text--text)
       (save-buffer))
     (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
     ;; Written after the reindex: the Store still points `hashed' at node.org.
     (with-temp-file plain (insert supertag-rename-merge-text--plain))
     (unwind-protect
         (progn ,@body)
       (when (get-buffer "*Supertag Tag Change*") (kill-buffer "*Supertag Tag Change*")))))

(defun supertag-rename-merge-text--preview-text ()
  "Return the current preview buffer's contents."
  (with-current-buffer (get-buffer-create "*Supertag Tag Change*")
    (buffer-string)))

(defun supertag-rename-merge-text--confirm (state &optional on-prompt)
  "Return a `yes-or-no-p' stub recording the prompt and shown preview in STATE.
ON-PROMPT runs after the preview was captured."
  (lambda (prompt)
    (setcar state prompt)
    (setcdr state (supertag-rename-merge-text--preview-text))
    (when on-prompt (funcall on-prompt))
    t))

(defun supertag-rename-merge-text--rename (old new state &optional on-prompt)
  "Rename OLD to NEW through a captured confirmation, returning the new id."
  (cl-letf (((symbol-function 'yes-or-no-p)
             (supertag-rename-merge-text--confirm state on-prompt)))
    (supertag-tag-rename old new)))

(ert-deftest supertag-rename-merge-text-renames-no-id-and-duplicate-copy ()
  "A no-`:ID:' heading, its prose, a duplicate copy and FILETAGS all rename."
  (supertag-rename-merge-text--vault
    (let ((state (cons nil nil)))
      (should (supertag-rename-merge-text--rename "old" "new" state))
      (let ((shown (cdr state)))
        (should (string-match-p "WILL CHANGE: 6" shown))
        (should (string-match-p "FILETAGS" shown))
        (should (string-match-p "heading without :ID:" shown))
        (should (string-match-p "duplicate :ID: (Store points at another file)" shown))
        (should (string-match-p "heading :ID: hashed" shown))
        (should (string-match-p "NOT CHANGED: 3" shown))
        (dolist (part '("not a Tag: src or example block"
                        "not a Tag: link path or description"
                        "not a Tag: property drawer"))
          (should (string-match-p (regexp-quote part) shown))))
    (let ((main (supertag-document-test-disk file))
          (copy (supertag-document-test-disk plain)))
      ;; Every occurrence is renamed, including the no-ID heading and the copy.
      (should (string-match-p "\\* Hashed #new" main))
      (should (string-match-p "body #new here" main))
      (should (string-match-p "\\* No ID #new" main))
      (should (string-match-p "Prose #new" main))
      (should (string-match-p ":new:" main))
      (should (string-match-p "\\* Stale copy #new" copy))
      (should-not (string-match-p "#old" copy))
      ;; Rejected shapes are byte-identical.
      (dolist (part '(".a { color: #old; }" "[[https://example.org][see #old]]" ":NOTE: #old"))
        (should (string-match-p (regexp-quote part) main))))
    (should-not (supertag-tag-get "old"))
    (let* ((new-id (supertag-tag-resolve-occurrence "new"))
           (hashed (plist-get (supertag-node-get "hashed") :tags)))
      (should new-id)
      (should (equal (list new-id) hashed))
      (should (= 1 (length hashed)))))))

(ert-deftest supertag-rename-merge-text-renames-sentence-final-token ()
  "`#old,' is the token `old' after 81b8b95, and renaming keeps the comma."
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "old" :name "old"))
    (with-current-buffer (find-file-noselect file)
      (erase-buffer)
      (insert ":PROPERTIES:\n:ID: file-node\n:END:\n* Sentence #old, tail\nProse ends #old.\n")
      (save-buffer))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (let ((state (cons nil nil)))
      (should (supertag-rename-merge-text--rename "old" "new" state))
      (should (string-match-p "WILL CHANGE: 2" (cdr state))))
    (let ((disk (supertag-document-test-disk file)))
      (should (string-match-p "\\* Sentence #new, tail" disk))
      (should (string-match-p "Prose ends #new\\." disk))
      (should-not (string-match-p "#old" disk)))
    (should-not (supertag-tag-get "old"))))

(ert-deftest supertag-rename-merge-text-rewrites-every-occurrence-back-to-front ()
  "A longer replacement cannot corrupt later recorded positions."
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "old" :name "old"))
    (let ((text (concat "* First #old\n:PROPERTIES:\n:ID: first\n:END:\nbody #old tail\n"
                        "* Second #old\n:PROPERTIES:\n:ID: second\n:END:\nmore #old here\n")))
      (with-current-buffer (find-file-noselect file)
        (erase-buffer)
        (insert text)
        (save-buffer))
      (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
      (let ((state (cons nil nil)))
        (should (supertag-rename-merge-text--rename "old" "much-longer-name" state))
        (should (string-match-p "WILL CHANGE: 4" (cdr state))))
      (let ((expected (replace-regexp-in-string
                       "#old" "#much-longer-name" text t t)))
        (should (equal expected (supertag-document-test-disk file))))
      (dolist (id '("first" "second"))
        (should (equal (list (supertag-tag-resolve-occurrence "much-longer-name"))
                       (plist-get (supertag-node-get id) :tags)))))))

(ert-deftest supertag-rename-merge-text-preview-decline-writes-nothing ()
  "Declining the confirmation leaves Org and the Store untouched."
  (supertag-rename-merge-text--vault
    (let ((before (list (supertag-document-test-disk file)
                        (supertag-document-test-disk plain)
                        (prin1-to-string supertag--store)))
          (state (cons nil nil)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (prompt)
                   (setcar state prompt)
                   (setcdr state (supertag-rename-merge-text--preview-text))
                   nil)))
        (should-not (supertag-tag-rename "old" "new")))
      ;; The exact lines were shown before the question was asked.
      (should (string-match-p "WILL CHANGE: 6" (cdr state)))
      (should (string-match-p "\\* No ID #old" (cdr state)))
      (should (equal before (list (supertag-document-test-disk file)
                                  (supertag-document-test-disk plain)
                                  (prin1-to-string supertag--store))))
      (should (supertag-tag-get "old"))
      (should-not (supertag-tag-resolve-occurrence "new")))))

(ert-deftest supertag-rename-merge-text-rescan-aborts-only-changed-file ()
  "A file edited after the preview is left alone and keeps the old entity."
  (supertag-rename-merge-text--vault
    (let ((state (cons nil nil)))
      (should (supertag-rename-merge-text--rename
               "old" "new" state
               (lambda ()
                 ;; An accepted position: prose in the no-ID heading.
                 (with-current-buffer (find-file-noselect file)
                   (goto-char (point-min))
                   (search-forward "Prose #old")
                   (end-of-line)
                   (insert "\nLate #old")))))
      (with-current-buffer (find-file-noselect file)
        (should (buffer-modified-p))
        (should (string-match-p "Late #old" (buffer-string)))
        (should (string-match-p "\\* No ID #old" (buffer-string))))
      (let ((copy (supertag-document-test-disk plain)))
        (should (string-match-p "\\* Stale copy #new" copy))
        (should-not (string-match-p "#old" copy)))
      (should (supertag-tag-get "old"))
      (should (string-match-p "NOT RENAMED" (supertag-rename-merge-text--preview-text)))
      (should (string-match-p "still name it" (supertag-rename-merge-text--preview-text))))))

(ert-deftest supertag-rename-merge-text-merge-deduplicates-membership ()
  "Merging onto an existing tag leaves one membership, never a duplicate."
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "old" :name "old"))
    (supertag-tag-create '(:id "target" :name "new"))
    (with-current-buffer (find-file-noselect file)
      (erase-buffer)
      (insert (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
                      "* Both #old #new\n:PROPERTIES:\n:ID: both\n:END:\nBody\n"
                      "* Only old #old\n:PROPERTIES:\n:ID: only-old\n:END:\nBody\n"))
      (save-buffer))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (let ((state (cons nil nil)))
      (should (equal "target" (supertag-rename-merge-text--rename "old" "new" state)))
      (should (string-match-p "Merge 'old' into existing Tag 'target' (token 'new')"
                              (car state)))
      (should (string-match-p "^\\s-*Merge" (cdr state))))
    (let ((disk (supertag-document-test-disk file)))
      (should (string-match-p "\\* Both #new #new" disk))
      (should (string-match-p "\\* Only old #new" disk))
      (should-not (string-match-p "#old" disk)))
    (should-not (supertag-tag-get "old"))
    (should (supertag-tag-get "target"))
    ;; Both nodes end up with the target exactly once.
    (should (equal '("target") (plist-get (supertag-node-get "both") :tags)))
    (should (equal '("target") (plist-get (supertag-node-get "only-old") :tags)))
    ;; The file node has no FILETAGS, so the merge invents no membership there.
    (should-not (plist-get (supertag-node-get "file-node") :tags))))

;;; rename-merge-text-test.el ends here
