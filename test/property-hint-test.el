;;; property-hint-test.el --- Property hints and completion -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'supertag-property)

(defvar supertag-property-hint-test-global
  '(("STATUS_ALL" . "todo doing done putoff"))
  "The `org-global-properties' the fixtures run under.")

(defun supertag-property-hint-test--nodes ()
  "Return a node collection: three book nodes, one of them also an idea."
  (let ((nodes (make-hash-table :test 'equal)))
    (puthash "b1" '(:tags ("book") :properties (:AUTHOR "Ann" :STATUS "read" :CREATED "x")) nodes)
    (puthash "b2" '(:tags ("book") :properties (:AUTHOR "Bob" :STATUS "reading" :ID "b2")) nodes)
    (puthash "b3" '(:tags ("book" "idea") :properties (:STATUS " reading " :RATING "4")) nodes)
    (puthash "i1" '(:tags ("idea") :properties (:COUNTRY "Japan" :EXPORT_FILE_NAME "n")) nodes)
    nodes))

(defmacro supertag-property-hint-test--at (text line &rest body)
  "Run BODY in an Org buffer holding TEXT, point at the end of LINE (1-based)."
  (declare (indent 2) (debug t))
  `(let ((org-global-properties supertag-property-hint-test-global))
     (with-temp-buffer
       (delay-mode-hooks (org-mode))
       (insert ,text)
       (org-set-regexps-and-options)
       (goto-char (point-min))
       (forward-line (1- ,line))
       (end-of-line)
       (cl-letf (((symbol-function 'supertag-property--nodes)
                  #'supertag-property-hint-test--nodes))
         ,@body))))

(ert-deftest supertag-property-hint-usage-skips-system-keys-and-counts-values ()
  "Keys programs maintain stay out; values are trimmed and counted."
  (cl-letf (((symbol-function 'supertag-property--nodes)
             #'supertag-property-hint-test--nodes))
    (let* ((usage (supertag-property-usage '("book")))
           (keys (supertag-property--by-count (plist-get usage :keys))))
      (should (equal (car keys) "STATUS"))
      (should (equal (sort (copy-sequence keys) #'string<)
                     '("AUTHOR" "COUNTRY" "RATING" "STATUS")))
      (should (= 2 (gethash "AUTHOR" (plist-get usage :tag-keys))))
      (should-not (gethash "COUNTRY" (plist-get usage :tag-keys)))
      (should (equal (supertag-property--by-count
                      (gethash "STATUS" (plist-get usage :values)))
                     '("reading" "read"))))
    ;; The plain name list keeps the keys programs maintain.
    (should (equal (supertag-property-names)
                   '("AUTHOR" "COUNTRY" "CREATED" "EXPORT_FILE_NAME" "ID"
                     "RATING" "STATUS")))))

(ert-deftest supertag-property-hint-usage-without-store ()
  "Without a Store there is no usage and nothing fails."
  (cl-letf (((symbol-function 'supertag-property--nodes) #'ignore))
    (should (= 0 (hash-table-count (plist-get (supertag-property-usage) :keys))))
    (should-not (supertag-property-names))))

(ert-deftest supertag-property-hint-key-info-reads-org-declarations ()
  "Closed comes from KEY_ALL only: global, overridden by the file, open with :ETC."
  (let ((drawer "* A book #book\n:PROPERTIES:\n:STATUS: reading\n:END:\n"))
    (supertag-property-hint-test--at drawer 3
      (let ((info (supertag-property-key-info "STATUS" (supertag-property-usage))))
        (should (eq (plist-get info :type) 'closed))
        (should (equal (plist-get info :options) '("todo" "doing" "done" "putoff")))
        (should (= 3 (plist-get info :count)))))
    (supertag-property-hint-test--at (concat "#+PROPERTY: STATUS_ALL a b\n" drawer) 4
      (should (equal (plist-get (supertag-property-key-info
                                 "STATUS" (supertag-property-usage))
                                :options)
                     '("a" "b"))))
    (supertag-property-hint-test--at (concat "#+PROPERTY: STATUS_ALL a b :ETC\n" drawer) 4
      (let ((info (supertag-property-key-info "STATUS" (supertag-property-usage))))
        (should (eq (plist-get info :type) 'open))
        ;; The hint lists repeated values; completion adds the declared ones.
        (should (equal (plist-get info :options) '("reading")))
        (should (equal (plist-get info :values) '("a" "b" "reading" "read")))))))

(ert-deftest supertag-property-hint-eldoc-names-type-and-options ()
  "A closed key lists options and flags an outside value; an open key lists repeats."
  (let ((text (concat "* A book #book\n:PROPERTIES:\n:ID: b9\n:STATUS: done\n"
                      ":AUTHOR: Cy\n:END:\nBody :STATUS: x\n")))
    (supertag-property-hint-test--at text 4
      (should (equal (supertag-property-eldoc)
                     "STATUS · closed · todo doing done putoff")))
    (supertag-property-hint-test--at (string-replace ": done" ": active" text) 4
      (should (equal (supertag-property-eldoc)
                     "STATUS · closed · todo doing done putoff · active is not an option")))
    (let ((supertag-property-hint-test-global nil))
      (supertag-property-hint-test--at text 4
        (should (equal (supertag-property-eldoc) "STATUS · open · reading"))))
    (supertag-property-hint-test--at text 5
      (should (equal (supertag-property-eldoc) "AUTHOR · open")))
    ;; Heading, drawer edges, a system key and a look-alike body line: no hint.
    (dolist (line '(1 2 3 6 7))
      (supertag-property-hint-test--at text line
        (should-not (supertag-property-eldoc))))))

(ert-deftest supertag-property-hint-value-completion-in-drawer-only ()
  "Values complete at a value position in a drawer, in declared or usage order."
  (let ((text (concat "* A book #book\n:PROPERTIES:\n:STATUS: do\n:AUTHOR: \n"
                      ":CREATED: \n:RATING:\n:END:\n:STATUS: do\n")))
    (supertag-property-hint-test--at text 3
      (pcase-let ((`(,beg ,end ,table . ,_)
                   (supertag-property-value-completion-at-point)))
        (should (equal (buffer-substring beg end) "do"))
        (should (equal (all-completions "do" table) '("doing" "done")))
        (should (eq (cdr (assq 'display-sort-function
                               (cdr (funcall table "" nil 'metadata))))
                    'identity))))
    (supertag-property-hint-test--at text 4
      (pcase-let ((`(,beg ,end ,table . ,plist)
                   (supertag-property-value-completion-at-point)))
        (should (= beg end))
        (should (equal (sort (all-completions "" table) #'string<) '("Ann" "Bob")))
        (should (equal (funcall (plist-get plist :annotation-function) "Ann") "  1"))))
    ;; A system key, no blank after the colon yet, a look-alike outside.
    (dolist (line '(1 5 6 8))
      (supertag-property-hint-test--at text line
        (should-not (supertag-property-value-completion-at-point))))))

(ert-deftest supertag-property-hint-key-completion-offers-unused-keys ()
  "Keys complete on an unfinished drawer line, annotated, and continue to the value."
  (let ((text "* A book #book\n:PROPERTIES:\n:AUTHOR: Cy\n:ST\n:END:\n:ST\n"))
    (supertag-property-hint-test--at text 4
      (pcase-let ((`(,beg ,end ,table . ,plist)
                   (supertag-property-key-completion-at-point)))
        (should (equal (buffer-substring beg end) "ST"))
        (should (equal (all-completions "" table)
                       '("STATUS" "RATING" "COUNTRY" "SUPERTAG_ALIASES")))
        (should (equal (funcall (plist-get plist :annotation-function) "STATUS")
                       "  closed · 3"))
        (should (equal (funcall (plist-get plist :annotation-function) "COUNTRY")
                       "  open · 1"))
        (insert "ATUS")
        (funcall (plist-get plist :exit-function) "STATUS" 'finished)
        (should (equal (buffer-substring (line-beginning-position) (point))
                       ":STATUS: "))
        (should (supertag-property--popup-wanted-p))))
    (dolist (line '(1 3 6))
      (supertag-property-hint-test--at text line
        (should-not (supertag-property-key-completion-at-point))))))

(ert-deftest supertag-property-hint-hand-written-supertag-keys-are-user-keys ()
  "SUPERTAG_ALIASES is offered before any node uses it; program keys stay out."
  (should (supertag-property--user-key-p "SUPERTAG_ALIASES"))
  (should-not (supertag-property--user-key-p "SUPERTAG_IGNORE_MENTIONS"))
  (let ((text "* A book #book\n:PROPERTIES:\n:SU\n:END:\n"))
    (supertag-property-hint-test--at text 3
      (pcase-let ((`(,_beg ,_end ,table . ,plist)
                   (supertag-property-key-completion-at-point)))
        (should (equal (all-completions "SU" table) '("SUPERTAG_ALIASES")))
        (should (equal (funcall (plist-get plist :annotation-function)
                                "SUPERTAG_ALIASES")
                       "  open · 0")))))
  (let ((text "* A book #book\n:PROPERTIES:\n:SUPERTAG_ALIASES: Ann\n:SU\n:END:\n"))
    (supertag-property-hint-test--at text 4
      (should-not (all-completions
                   "SU" (nth 2 (supertag-property-key-completion-at-point)))))))

(ert-deftest supertag-property-hint-hand-written-keys-match-their-readers ()
  "The alias key offered here is the one concept mentions and links read."
  (require 'supertag-concept)
  (should (member (substring (symbol-name supertag-concept--aliases-property) 1)
                  supertag-property-hand-written-keys)))

(ert-deftest supertag-property-hint-global-mode-offers-keys-to-org ()
  "Org's own key completion offers SUPERTAG_ALIASES while the global mode is on.
Turning it off takes out only what it added."
  (let ((org-default-properties (remove "SUPERTAG_ALIASES" org-default-properties))
        (supertag-property--org-keys-added nil)
        (global-supertag-property-mode nil))
    (with-temp-buffer
      (delay-mode-hooks (org-mode))
      (should-not (member "SUPERTAG_ALIASES" (org-buffer-property-keys nil t t)))
      (unwind-protect
          (progn
            (global-supertag-property-mode 1)
            (should (member "SUPERTAG_ALIASES" (org-buffer-property-keys nil t t)))
            (global-supertag-property-mode 1)
            (should (= 1 (cl-count "SUPERTAG_ALIASES" org-default-properties
                                   :test #'equal))))
        (global-supertag-property-mode -1))
      (should-not (member "SUPERTAG_ALIASES" (org-buffer-property-keys nil t t))))
    ;; A key the user had already added survives turning the mode off.
    (setq org-default-properties (append org-default-properties '("SUPERTAG_ALIASES")))
    (unwind-protect
        (global-supertag-property-mode 1)
      (global-supertag-property-mode -1))
    (should (member "SUPERTAG_ALIASES" org-default-properties))))

(ert-deftest supertag-property-hint-popup-only-for-empty-enumerable-values ()
  "Only an empty value whose key has more than one option asks for candidates."
  (let ((text (concat "* A book #book\n:PROPERTIES:\n:STATUS: \n:STATUS: done\n"
                      ":AUTHOR: \n:CREATED: \n:END:\n")))
    (supertag-property-hint-test--at text 3
      (should (supertag-property--popup-wanted-p))
      (backward-char)
      (should-not (supertag-property--popup-wanted-p)))
    (dolist (line '(1 4 5 6))
      (supertag-property-hint-test--at text line
        (should-not (supertag-property--popup-wanted-p))))))

(ert-deftest supertag-property-hint-mode-adds-and-removes-its-hooks ()
  "The mode installs its hooks in the buffer and takes all of them out again."
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (supertag-property-mode 1)
    (should (memq #'supertag-property-eldoc eldoc-documentation-functions))
    (should (memq #'supertag-property-value-completion-at-point
                  completion-at-point-functions))
    (should (memq #'supertag-property-key-completion-at-point
                  completion-at-point-functions))
    (should (memq #'supertag-property--popup post-command-hook))
    (supertag-property-mode -1)
    (should-not (memq #'supertag-property-eldoc eldoc-documentation-functions))
    (should-not (memq #'supertag-property-value-completion-at-point
                      completion-at-point-functions))
    (should-not (memq #'supertag-property-key-completion-at-point
                      completion-at-point-functions))
    (should-not (memq #'supertag-property--popup post-command-hook))
    (let ((supertag-property-hints nil))
      (supertag-property-enable)
      (should-not supertag-property-mode))))

(provide 'property-hint-test)
;;; property-hint-test.el ends here
