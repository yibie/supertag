;;; inline-tag-punctuation-test.el --- ASCII punctuation in tag names -*- lexical-binding: t; -*-
;; A tag name ends at whitespace, `#`/`＃`, full-width punctuation or an ASCII
;; delimiter, and drops trailing ASCII sentence punctuation; inner punctuation
;; stays, so `#seo,' is `seo' while `#v1.2', `#c++' and `#emacs/package' are
;; whole.  Highlighting and extraction must report the same names.
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-tag)

(defun supertag-inline-tag-punctuation-test--names (text)
  "Return the tag names TEXT yields through the inline tag regexp."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (names)
      (while (re-search-forward supertag-inline-tag-regexp nil t)
        (push (match-string-no-properties 2) names))
      (nreverse names))))

(ert-deftest supertag-inline-tag-punctuation-trailing-forms ()
  "Trailing ASCII punctuation is not part of a name."
  (dolist (case '(("#seo," . ("seo"))
                  ("#seo." . ("seo"))
                  ("#seo;" . ("seo"))
                  ("#seo!" . ("seo"))
                  ("#seo?" . ("seo"))
                  ("#seo)" . ("seo"))
                  ("#seo]" . ("seo"))
                  ("#seo,,," . ("seo"))
                  ("#seo.'\"" . ("seo"))
                  ("#seo at the end." . ("seo"))
                  ("mid #seo. more" . ("seo"))))
    (should (equal (cdr case)
                   (supertag-inline-tag-punctuation-test--names (car case)))))
  ;; A link puts a `]` right before the marker, which was never a boundary;
  ;; with a space before it, the paired `]` no longer joins the name.
  (should (equal '("seo") (supertag-inline-tag-punctuation-test--names "see #seo]] here")))
  (should (equal '("head")
                 (supertag-inline-tag-punctuation-test--names
                  "* Title #head [[id:x][#seo]]")))
  (should-not (supertag-inline-tag-punctuation-test--names "[[id:x][#seo]]")))

(ert-deftest supertag-inline-tag-punctuation-name-characters ()
  "Inner punctuation, path separators and underscore/dash stay in the name."
  (dolist (case '(("#emacs/package" . ("emacs/package"))
                  ("#c_maker" . ("c_maker"))
                  ("#tag-name" . ("tag-name"))
                  ("#v1.2" . ("v1.2"))
                  ("#c++" . ("c++"))
                  ("#x^2" . ("x^2"))
                  ("#don't" . ("don't"))
                  ("#a.b,c" . ("a.b,c"))
                  ("#a=" . ("a="))))
    (should (equal (cdr case)
                   (supertag-inline-tag-punctuation-test--names (car case)))))
  ;; Brackets and quotes never survive anywhere in a name.
  (dolist (case '(("#foo(bar)" . ("foo"))
                  ("#a]b" . ("a"))
                  ("#a)b" . ("a"))
                  ("#a>b" . ("a"))
                  ("#say\"hi\"" . ("say"))))
    (should (equal (cdr case)
                   (supertag-inline-tag-punctuation-test--names (car case)))))
  ;; A name of nothing but punctuation is not a name at all.
  (should-not (supertag-inline-tag-punctuation-test--names "#."))
  (should-not (supertag-inline-tag-punctuation-test--names "#..")))

(ert-deftest supertag-inline-tag-punctuation-cjk-and-emoji ()
  "Full-width punctuation still ends a name, and CJK/emoji names survive."
  (dolist (case '(("#标签，后面" . ("标签"))
                  ("＃标签" . ("标签"))
                  ("#标签。" . ("标签"))
                  ("#设计·计划" . ("设计·计划"))
                  ("#🎉tag" . ("🎉tag"))
                  ("#🎉" . ("🎉"))))
    (should (equal (cdr case)
                   (supertag-inline-tag-punctuation-test--names (car case)))))
  (should (equal "＃　，。；：！？、（）【】《》“”‘’"
                 supertag-inline-tag-terminator-chars)))

(ert-deftest supertag-inline-tag-punctuation-highlighting-matches-extraction ()
  "The name the highlighter paints is the name the extractor reports."
  (dolist (text '("prose #seo, tail"
                  "#emacs/package and #v1.2."
                  "标签 #标签，后面"
                  "#foo(bar) text"
                  "#c++ #x^2 #don't"
                  "* Head #tag-name #a.b,c"
                  "#seo\t#seo"))
    (let* ((extracted (supertag-transform-extract-inline-tags text))
           (ranges (with-temp-buffer
                     (insert text)
                     (org-mode)
                     (let (names)
                       (dolist (match (supertag-transform-inline-tag-matches-in-region
                                       (point-min) (point-max) nil 'paragraph))
                         (push (nth 2 match) names))
                       (nreverse names))))
           (painted (with-temp-buffer
                      (insert text)
                      (org-mode)
                      (goto-char (point-min))
                      (let (names)
                        (while (supertag-view-helper--font-lock-matcher (point-max))
                          (push (match-string-no-properties 0) names))
                        (nreverse names)))))
      (should (equal extracted ranges))
      ;; The font-lock match covers the `#' marker itself.
      (should (equal painted (mapcar (lambda (name) (concat "#" name)) extracted))))))

(ert-deftest supertag-inline-tag-punctuation-resolves-the-intended-tag ()
  "`#seo,' resolves to the `seo' entity, never to the old `seo,' token."
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "seo" :name "seo"))
    (supertag-tag-create '(:id "seo-punct" :name "seo,"))
    (should (equal "seo" (supertag-tag-resolve-occurrence
                          (car (supertag-inline-tag-punctuation-test--names "#seo,")))))
    ;; The old tokenisation cannot be produced from text any more, so a Tag
    ;; whose registered name ends in punctuation is text-unreachable.
    (should-not (member "seo," (supertag-inline-tag-punctuation-test--names "#seo,")))
    (should (equal "seo" (car (supertag-inline-tag-punctuation-test--names "#seo,"))))))

(ert-deftest supertag-inline-tag-punctuation-completion-mirrors-the-rule ()
  "Completion treats the same characters as name characters."
  (dolist (char '(?a ?/ ?_ ?- ?. ?+ ?^ ?' ))
    (should (supertag-completion--valid-tag-char-p char)))
  (dolist (char (list ?\) ?\] ?} ?> ?\" ?# ?\s))
    (should-not (supertag-completion--valid-tag-char-p char)))
  (with-temp-buffer
    (insert "text #seo")
    (should (equal (cons 7 10) (supertag-completion--get-prefix-bounds)))))

;;; inline-tag-punctuation-test.el ends here
