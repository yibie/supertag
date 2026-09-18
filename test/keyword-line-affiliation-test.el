;;; keyword-line-affiliation-test.el --- keyword lines are metadata -*- lexical-binding: t; -*-
;; An occurrence on an Org keyword line is not prose and never a Tag, whether
;; or not Org affiliates the line to the element that follows.  Highlighting,
;; extraction, delete and rename all share the same acceptance function, so
;; what is highlighted is what a delete or rename would touch.
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-tag)
(require 'supertag-services-sync)

(defmacro supertag-keyword-line-test--vault (&rest body)
  "Run BODY in a temp vault holding tag `old'."
  (declare (indent 0))
  `(supertag-document-test-with-vault
     (supertag-tag-create '(:id "old" :name "old"))
     (unwind-protect
         (progn ,@body)
       (when (get-buffer "*Supertag Tag Change*") (kill-buffer "*Supertag Tag Change*")))))

(defun supertag-keyword-line-test--write (path text)
  "Replace PATH's contents with TEXT and reproject the vault."
  (with-current-buffer (find-file-noselect path)
    (erase-buffer)
    (insert text)
    (save-buffer))
  (should (eq 'complete (plist-get (supertag-reindex-org) :status))))

(defun supertag-keyword-line-test--accepted (path)
  "Return the tokens the shared acceptance rule accepts in PATH."
  (with-current-buffer (find-file-noselect path)
    (let (names)
      (goto-char (point-min))
      (while (re-search-forward "#old\\|#new" nil t)
        (let ((range (supertag-view-helper--inline-tag-range-at (match-beginning 0))))
          (when range (push (nth 2 range) names))))
      (nreverse names))))

(defun supertag-keyword-line-test--preview ()
  "Return the current text preview buffer's contents."
  (with-current-buffer (get-buffer-create "*Supertag Tag Change*")
    (buffer-string)))

(defconst supertag-keyword-line-test--head
  ":PROPERTIES:\n:ID: file-node\n:END:\n* H\n:PROPERTIES:\n:ID: h\n:END:\n"
  "Vault header with a file node and one identified heading.")

(ert-deftest supertag-keyword-line-standalone-caption-is-not-an-occurrence ()
  "A `#+CAPTION:' line with nothing after it stays rejected."
  (supertag-keyword-line-test--vault
    (supertag-keyword-line-test--write
     file (concat supertag-keyword-line-test--head
                  "prose\n#+CAPTION: META #old\n"))
    (should-not (supertag-keyword-line-test--accepted file))
    (should-not (supertag-tag-change--collect "old"))))

(ert-deftest supertag-keyword-line-affiliated-caption-is-not-an-occurrence ()
  "The same line followed by a paragraph is metadata too (the fix).
It is Org's affiliated keyword of that paragraph, so the element at the marker
is the paragraph; the position's own line is what decides."
  (supertag-keyword-line-test--vault
    (supertag-keyword-line-test--write
     file (concat supertag-keyword-line-test--head
                  "prose\n#+CAPTION: META #old\nPROSE #old\n"))
    ;; Only the paragraph's own occurrence is a Tag.
    (should (equal '("old") (supertag-keyword-line-test--accepted file)))
    (let ((records (supertag-tag-change--collect "old")))
      (should (= 1 (length records)))
      (should (string-match-p "PROSE #old" (plist-get (car records) :line-text))))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (search-forward "META #")
      (should (eq 'paragraph (org-element-type (org-element-context))))
      (should-not (supertag-view-helper--inline-tag-range-at (1- (point)))))))

(ert-deftest supertag-keyword-line-name-and-attr-keywords-are-metadata ()
  "`#+NAME:' and `#+ATTR_*:' lines behave exactly like `#+CAPTION:'."
  (supertag-keyword-line-test--vault
    (dolist (keyword '("NAME: tbl #old" "ATTR_HTML: :class #old"))
      (supertag-keyword-line-test--write
       file (concat supertag-keyword-line-test--head
                    "#+" keyword "\nPROSE #old\n"))
      (should (equal '("old") (supertag-keyword-line-test--accepted file))))))

(ert-deftest supertag-keyword-line-headline-and-prose-still-accept ()
  "Headline titles and ordinary prose keep accepting.
A paragraph directly under a keyword line is prose: only the keyword line is
metadata."
  (supertag-keyword-line-test--vault
    (supertag-keyword-line-test--write
     file (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
                  "* Head #old\nprose #old\n"
                  "#+CAPTION: META #old\nnext paragraph #old\n"))
    (should (equal '("old" "old" "old")
                   (supertag-keyword-line-test--accepted file)))))

(ert-deftest supertag-keyword-line-highlighting-paints-the-same-set ()
  "The highlighter paints exactly the tokens the enumerator accepts."
  (supertag-keyword-line-test--vault
    (supertag-keyword-line-test--write
     file (concat supertag-keyword-line-test--head
                  "#+CAPTION: META #old\nPROSE #old\n"))
    (let ((painted (with-current-buffer (find-file-noselect file)
                     (goto-char (point-min))
                     (let (names)
                       (while (supertag-view-helper--font-lock-matcher (point-max))
                         (push (match-string-no-properties 0) names))
                       (nreverse names)))))
      (should (equal '("#old") painted))
      (should (equal '("old") (supertag-keyword-line-test--accepted file))))))

(ert-deftest supertag-keyword-line-rename-leaves-the-line-byte-identical ()
  "Rename rewrites prose occurrences only and lists the keyword line as such."
  (supertag-keyword-line-test--vault
    (supertag-keyword-line-test--write
     file (concat supertag-keyword-line-test--head
                  "#+CAPTION: META #old\nPROSE #old\n"))
    (let* ((state (cons nil nil))
           (result
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt) (setcar state prompt)
                         (setcdr state (supertag-keyword-line-test--preview)) t)))
              (supertag-tag-rename "old" "new"))))
      (should result)
      (let* ((shown (cdr state))
             (split (string-match-p "NOT CHANGED:" shown)))
        (should split)
        (should-not (string-match-p "CAPTION" (substring shown 0 split)))
        (should (string-match-p "CAPTION" (substring shown split)))
        (should (string-match-p "not a Tag: keyword line" (substring shown split)))))
    (let ((disk (supertag-document-test-disk file)))
      (should (string-match-p (regexp-quote "#+CAPTION: META #old") disk))
      (should (string-match-p "PROSE #new" disk))
      (should-not (string-match-p "PROSE #old" disk)))))

(ert-deftest supertag-keyword-line-delete-leaves-the-line-byte-identical ()
  "Delete removes prose occurrences only; the metadata line survives."
  (supertag-keyword-line-test--vault
    (supertag-keyword-line-test--write
     file (concat supertag-keyword-line-test--head
                  "#+CAPTION: META #old\nPROSE #old\n"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (supertag-delete-tag-everywhere "old")))
    (let ((disk (supertag-document-test-disk file)))
      (should (string-match-p (regexp-quote "#+CAPTION: META #old") disk))
      (should (string-match-p "PROSE" disk))
      (should-not (string-match-p "PROSE #old" disk)))
    ;; The metadata text is not an occurrence, so nothing keeps the entity.
    (should-not (supertag-tag-get "old"))))

(ert-deftest supertag-keyword-line-filetags-keeps-its-own-behaviour ()
  "`#+FILETAGS:' is still rewritten by its own writer, not by the inline rule."
  (supertag-keyword-line-test--vault
    (supertag-keyword-line-test--write
     file (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
                  "#+FILETAGS: :old:\n* H\nprose #old\n"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (supertag-tag-rename "old" "new")))
    (let ((disk (supertag-document-test-disk file)))
      (should (string-match-p (regexp-quote "#+FILETAGS: :new:") disk))
      (should (string-match-p "prose #new" disk)))))

;;; keyword-line-affiliation-test.el ends here
