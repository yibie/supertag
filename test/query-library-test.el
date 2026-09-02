;;; query-library-test.el --- ERT tests for supertag-query-library.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Regression tests for the query learnability/reusability layer added in
;; supertag-query-library.el:
;;   1. The builder's pure S-expression assembly helpers
;;      (`supertag-query-library--make-condition' and
;;      `supertag-query-library--combine-conditions'), validated against the
;;      real parser (`supertag-query--parse-sexp').
;;   2. Saved-query alist round-trip through a temporary custom-file.
;;   3. The `*Supertag Query Syntax*' quick-reference buffer renders.
;;   4. Running a saved query renders node links/tags via the real query
;;      engine (`supertag-query--parse-sexp' / `supertag-query--execute-ast'),
;;      against an isolated in-memory store.
;;
;; None of these tests touch the user's real init file or `~/.emacs.d'.
;;
;; Run:
;;   ./test/run-tests.sh query-library
;;   emacs -batch -L . --eval "(package-initialize)" \
;;     -l test/query-library-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(when load-file-name
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-services-query)
(require 'supertag-query-library)

;;; --- 1. Builder assembly helpers -----------------------------------------

(ert-deftest supertag-query-library-test-make-condition-builds-valid-leaf-sexps ()
  "`supertag-query-library--make-condition' builds sexps the parser accepts."
  (should (equal (supertag-query-library--make-condition "tag" "project")
                 '(tag "project")))
  (should (equal (supertag-query-library--make-condition "field" "status" "active")
                 '(field "status" "active")))
  (should (equal (supertag-query-library--make-condition "term" "meeting")
                 '(term "meeting")))
  (should (equal (supertag-query-library--make-condition "after" "-7d")
                 '(after "-7d")))
  (should (equal (supertag-query-library--make-condition "between" "-7d" "now")
                 '(between "-7d" "now")))
  ;; Every produced sexp must also be independently accepted by the real
  ;; parser (this is implicit in --make-condition, but assert it explicitly
  ;; so a future refactor can't silently skip validation).
  (dolist (sexp (list '(tag "project") '(field "status" "active")
                       '(term "meeting") '(after "-7d") '(between "-7d" "now")))
    (should (supertag-query--parse-sexp sexp))))

(ert-deftest supertag-query-library-test-make-condition-rejects-bad-arity ()
  "Wrong argument counts surface the parser's own error, not a silent build."
  (should-error (supertag-query-library--make-condition "tag" "a" "b"))
  (should-error (supertag-query-library--make-condition "field" "only-one-arg"))
  (should-error (supertag-query-library--make-condition "between" "-7d")))

(ert-deftest supertag-query-library-test-date-sugar-operators-desugar ()
  "recent-days / in-month / in-year desugar to after/between at parse time."
  ;; recent-days N -> (after "-Nd"); integer and numeric-string accepted.
  (should (equal (supertag-query--parse-sexp '(recent-days 7))
                 '(:type after :date "-7d")))
  (should (equal (supertag-query--parse-sexp '(recent-days "30"))
                 '(:type after :date "-30d")))
  ;; in-month -> between [first of month, first of next month).
  (should (equal (supertag-query--parse-sexp '(in-month "2025-06"))
                 '(:type between :start-date "2025-06-01" :end-date "2025-07-01")))
  ;; December rolls over the year.
  (should (equal (supertag-query--parse-sexp '(in-month "2025-12"))
                 '(:type between :start-date "2025-12-01" :end-date "2026-01-01")))
  ;; in-year -> between [Jan 1, next Jan 1); string and integer accepted.
  (should (equal (supertag-query--parse-sexp '(in-year "2025"))
                 '(:type between :start-date "2025-01-01" :end-date "2026-01-01")))
  (should (equal (supertag-query--parse-sexp '(in-year 2025))
                 '(:type between :start-date "2025-01-01" :end-date "2026-01-01")))
  ;; The desugared date strings must resolve to real time values.
  (should (supertag-query--resolve-date-string "2025-06-01")))

(ert-deftest supertag-query-library-test-date-sugar-rejects-bad-arguments ()
  "Date-sugar operators validate their arguments at parse time."
  (should-error (supertag-query--parse-sexp '(recent-days 0)))
  (should-error (supertag-query--parse-sexp '(recent-days -3)))
  (should-error (supertag-query--parse-sexp '(recent-days "x")))
  (should-error (supertag-query--parse-sexp '(in-month "2025-13")))
  (should-error (supertag-query--parse-sexp '(in-month "2025-6")))
  (should-error (supertag-query--parse-sexp '(in-month 202506)))
  (should-error (supertag-query--parse-sexp '(in-year "25")))
  (should-error (supertag-query--parse-sexp '(in-year "20256"))))

(ert-deftest supertag-query-library-test-combine-conditions-wraps-and-validates ()
  "`supertag-query-library--combine-conditions' nests conditions under and/or."
  (let* ((c1 (supertag-query-library--make-condition "tag" "task"))
         (c2 (supertag-query-library--make-condition "tag" "work"))
         (and-sexp (supertag-query-library--combine-conditions "and" c1 c2))
         (or-sexp (supertag-query-library--combine-conditions "or" c1 c2)))
    (should (equal and-sexp '(and (tag "task") (tag "work"))))
    (should (equal or-sexp '(or (tag "task") (tag "work"))))
    ;; Combinator can also be a symbol, not just a string.
    (should (equal (supertag-query-library--combine-conditions 'and c1 c2) and-sexp))
    ;; Nesting multiple combine steps (left-associative, as the interactive
    ;; loop in `supertag-query-build' does) still parses.
    (let ((nested (supertag-query-library--combine-conditions
                   "or" and-sexp (supertag-query-library--make-condition "term" "x"))))
      (should (equal nested '(or (and (tag "task") (tag "work")) (term "x"))))
      (should (supertag-query--parse-sexp nested)))))

;;; --- 2. Saved-query round trip through the `:queries' Store ---------------

(defmacro supertag-query-library-test--with-store (&rest body)
  "Run BODY with an isolated Store and legacy defcustom state.
This never touches the user's real database or init file."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-query-library-test" t))
          (supertag-data-directory (expand-file-name "data" tmp))
          (supertag-db-file (expand-file-name "supertag-db.el"
                                               supertag-data-directory))
          (supertag-db-backup-directory (expand-file-name "backups"
                                                           supertag-data-directory))
          (custom-file (expand-file-name "custom.el" tmp))
          (user-init-file custom-file)
          (supertag--store nil)
          (supertag-query-saved nil))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-query-library-test-save-persists-to-store ()
  "Saving a query writes the `:queries' collection and updates in place."
  (supertag-query-library-test--with-store
    (supertag-query-save "(tag \"project\")" "my-projects")
    (should (equal (cdr (assoc "my-projects" (supertag-query-saved-list)))
                   "(tag \"project\")"))
    (should (supertag-store-get-entity :queries "my-projects"))
    ;; Saving again under the same name updates rather than duplicates.
    (supertag-query-save "(tag \"projects-v2\")" "my-projects")
    (should (= 1 (length (supertag-query-saved-list))))
    (should (equal (cdr (assoc "my-projects" (supertag-query-saved-list)))
                   "(tag \"projects-v2\")"))))

(ert-deftest supertag-query-library-test-save-rejects-empty-name-and-bad-query ()
  "Saving validates both the name and that the query actually parses."
  (supertag-query-library-test--with-store
    (should-error (supertag-query-save "(tag \"x\")" ""))
    (should-error (supertag-query-save "(tag \"x\")" "   "))
    (should-error (supertag-query-save "(bogus-operator \"x\")" "broken"))
    (should-not (supertag-query-saved-list))))

(ert-deftest supertag-query-library-test-imports-legacy-defcustom-once ()
  "The legacy defcustom imports once and only when the Store is empty."
  (supertag-query-library-test--with-store
    (setq supertag-query-saved '(("legacy-a" . "(tag \"x\")")))
    (cl-letf (((symbol-function 'supertag-save-store) (lambda (&rest _) t)))
      (should (supertag-query-saved--maybe-import-legacy))
      (should (null supertag-query-saved))
      (should (equal '("legacy-a")
                     (mapcar #'car (supertag-query-saved-list))))
      ;; Second call: Store non-empty, no re-import.
      (should-not (supertag-query-saved--maybe-import-legacy)))))

(ert-deftest supertag-query-library-test-insert-saved-calls-dblock-directly ()
  "Dynamic insertion calls the query-block command without symbol probing."
  (let (choices default copied invoked)
    (cl-letf (((symbol-function 'supertag-query-library--saved-query-string)
               (lambda (_name) "(tag \"project\")"))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest args)
                 (setq choices collection
                       default (nth 4 args))
                 "Dynamic block"))
              ((symbol-function 'kill-new)
               (lambda (text &rest _)
                 (setq copied text)))
              ((symbol-function 'call-interactively)
               (lambda (command &rest _)
                 (setq invoked command)))
              ((symbol-function 'message) (lambda (&rest _))))
      (supertag-query-insert-saved "projects"))
    (should (equal choices '("Babel block" "Dynamic block")))
    (should (equal default "Babel block"))
    (should (equal copied "(tag \"project\")"))
    (should (eq invoked 'supertag-insert-query-dblock))))

;;; --- 3. Quick-reference buffer --------------------------------------------

(ert-deftest supertag-query-library-test-describe-syntax-renders-buffer ()
  "`supertag-query-describe-syntax' renders a read-only reference buffer."
  (unwind-protect
      (progn
        (let ((noninteractive nil))
          (cl-letf (((symbol-function 'pop-to-buffer) #'identity))
            (supertag-query-describe-syntax)))
        (let ((buf (get-buffer "*Supertag Query Syntax*")))
          (should buf)
          (with-current-buffer buf
            (should (derived-mode-p 'special-mode))
            (should buffer-read-only)
            (let ((text (buffer-string)))
              (should (string-match-p "(tag NAME)" text))
              (should (string-match-p "(field KEY VALUE)" text))
              (should (string-match-p "(between START END)" text))
              (should (string-match-p "doc/QUERY.md" text))))))
    (ignore-errors (kill-buffer "*Supertag Query Syntax*"))))

;;; --- 4. Running a saved query against an isolated store ------------------

(defmacro supertag-query-library-test--with-isolated-store (&rest body)
  "Run BODY with `supertag--store' rebound to a fresh, empty store."
  (declare (indent 0))
  `(let ((supertag--store nil))
     (supertag--ensure-store)
     ,@body))

(ert-deftest supertag-query-library-test-run-saved-renders-results-buffer ()
  "Running a saved query shows matching nodes as links with a Tags column."
  (supertag-query-library-test--with-isolated-store
    (puthash "n1"
             (list :id "n1" :title "Write report" :tags '("task" "work")
                   :link-type "id")
             (supertag-store-get-collection :nodes))
    (puthash "n2"
             (list :id "n2" :title "Buy groceries" :tags '("errand")
                   :link-type "id")
             (supertag-store-get-collection :nodes))
    (cl-letf (((symbol-function 'supertag-save-store) (lambda (&rest _) t)))
      (supertag-query-save "(tag \"task\")" "my-tasks"))
    (unwind-protect
        (let ((buf (cl-letf (((symbol-function 'pop-to-buffer) #'identity))
                     (supertag-query-run-saved "my-tasks")
                     (get-buffer "*Supertag Saved Query*"))))
          (should buf)
          (with-current-buffer buf
            (let ((text (buffer-string)))
              (should (string-match-p "Write report" text))
              (should (string-match-p "task" text))
              (should-not (string-match-p "Buy groceries" text)))))
      (ignore-errors (kill-buffer "*Supertag Saved Query*")))))

(provide 'query-library-test)

;;; query-library-test.el ends here
