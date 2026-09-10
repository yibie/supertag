;;; query-block-test.el --- ERT tests for supertag-ui-query-block.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Regression tests for the query-block upgrade on the hardening/p0-p2
;; branch: the shared babel/dynamic-block rendering core in
;; `supertag-ui-query-block.el', its :sort/:order/:limit/:columns result
;; controls, and its "never signal, render an error string instead"
;; guarantee.
;;
;; Every test runs inside an isolated temp directory with a freshly reset
;; in-memory store; none of them ever touch the user's real `~/.emacs.d'.
;;
;; Run:
;;   ./test/run-tests.sh query
;;   emacs -batch -L . --eval "(package-initialize)" \
;;     -l test/query-block-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-tag)
(require 'supertag-ops-field)
(require 'supertag-query)
(require 'supertag-ui-query-block)

;;; --- Shared helpers ---

(defmacro query-block-test--with-clean-store (&rest body)
  "Run BODY with a clean isolated store in a temp directory."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-query-block-test" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag--store nil)
          (supertag--store-origin nil))
     (unwind-protect
         (progn
           (supertag--ensure-store)
           ,@body)
       (ignore-errors (delete-directory tmp t)))))

(defun query-block-test--time (day-offset)
  "Return a distinct Emacs time value, DAY-OFFSET days after a fixed epoch."
  (seconds-to-time (+ 1700000000 (* day-offset 86400))))

(defun query-block-test--make-fixture ()
  "Populate the current store with 10 nodes across 2 tags.
Six nodes are tagged \"project\" with a numeric \"priority\" field and
distinct :created-at timestamps; four are tagged \"area\" (no field).
Returns the list of created node ids, in creation order."
  (supertag-tag-create (list :id "project" :name "project"))
  (supertag-tag-create (list :id "area" :name "area"))
  (supertag-tag-add-field
   "project" '(:name "priority" :type :integer))
  (let (ids)
    (cl-loop
     for i from 1 to 6
     for priority in '(5 3 9 1 7 2)
     do (let* ((id (format "proj-%d" i))
               (node (supertag-node-create
                      (list :id id
                            :title (format "Node %d" i)
                            :file "/tmp/query-block-test.org"
                            :created-at (query-block-test--time i)))))
          (supertag-node-add-tag id "project")
          (supertag-field-set id "project" "priority" priority)
          (push id ids)))
    (cl-loop
     for i from 7 to 10
     do (let* ((id (format "area-%d" i))
               (node (supertag-node-create
                      (list :id id
                            :title (format "Node %d" i)
                            :file "/tmp/query-block-test.org"
                            :created-at (query-block-test--time i)))))
          (supertag-node-add-tag id "area")
          (push id ids)))
    (nreverse ids)))

(defun query-block-test--link-count (table)
  "Count how many node-link cells (\"[[id:...\") appear in TABLE."
  (let ((count 0) (start 0))
    (while (string-match "\\[\\[id:" table start)
      (setq count (1+ count) start (match-end 0)))
    count))

;;; --- 1. Babel executor: existing behavior guard ---

(ert-deftest query-block-babel-tag-query-basic ()
  "A plain tag query returns a table with exactly the tagged nodes."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (let ((table (org-babel-execute:supertag-query-block
                  "(tag \"project\")" nil)))
      (should (stringp table))
      (should (= 6 (query-block-test--link-count table)))
      (dolist (i '(1 2 3 4 5 6))
        (should (string-match-p (format "Node %d" i) table)))
      (dolist (i '(7 8 9 10))
        (should-not (string-match-p (format "Node %d\\b" i) table)))
      (should (string-match-p "|[ \t]*Node[ \t]*|[ \t]*Tags[ \t]*|" table)))))

;;; --- 2. :limit / :order / :sort ---

(ert-deftest query-block-babel-limit-truncates ()
  ":limit truncates the result rows after sorting."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (let ((table (org-babel-execute:supertag-query-block
                  "(tag \"project\")"
                  '((:sort . "priority") (:order . "asc") (:limit . 3)))))
      (should (= 3 (query-block-test--link-count table)))
      ;; Ascending by priority: 1 (Node 4), 2 (Node 6), 3 (Node 2).
      (should (string-match-p "Node 4" table))
      (should (string-match-p "Node 6" table))
      (should (string-match-p "Node 2" table))
      (should-not (string-match-p "Node 1\\b" table))
      (should-not (string-match-p "Node 3\\b" table))
      (should-not (string-match-p "Node 5\\b" table)))))

(ert-deftest query-block-babel-sort-numeric-field-orders-numerically ()
  ":sort on a numeric field orders rows numerically, not lexically."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (let* ((table (org-babel-execute:supertag-query-block
                   "(tag \"project\")"
                   '((:sort . "priority") (:order . "asc"))))
           (pos-4 (string-match "Node 4" table))
           (pos-6 (string-match "Node 6" table))
           (pos-2 (string-match "Node 2" table))
           (pos-1 (string-match "Node 1" table))
           (pos-5 (string-match "Node 5" table))
           (pos-3 (string-match "Node 3" table)))
      ;; priorities: N4=1, N6=2, N2=3, N1=5, N5=7, N3=9 -- ascending order.
      (should (< pos-4 pos-6 pos-2 pos-1 pos-5 pos-3)))))

(ert-deftest query-block-babel-order-desc-reverses ()
  ":order desc reverses the sorted order."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (let* ((table (org-babel-execute:supertag-query-block
                   "(tag \"project\")"
                   '((:sort . "priority") (:order . "desc"))))
           (pos-3 (string-match "Node 3" table))
           (pos-1 (string-match "Node 1" table))
           (pos-4 (string-match "Node 4" table)))
      ;; Descending: Node 3 (priority 9) first, Node 4 (priority 1) last.
      (should (< pos-3 pos-1 pos-4)))))

;;; --- 3. :columns override ---

(ert-deftest query-block-babel-columns-overrides-auto-columns ()
  ":columns overrides the fields auto-derived from the query AST."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (let ((table (org-babel-execute:supertag-query-block
                  "(tag \"project\")"
                  '((:columns . ("priority"))))))
      (should (string-match-p "|[ \t]*Node[ \t]*|[ \t]*Tags[ \t]*|[ \t]*priority[ \t]*|" table))
      ;; The priority values themselves should show up as cell contents.
      (should (string-match-p "5" table))
      (should (string-match-p "9" table)))))

;;; --- 4. Dynamic block ---

(ert-deftest query-block-dblock-writer-inserts-table ()
  "`org-dblock-write:supertag-query' renders a table via `org-dblock-update'."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (with-temp-buffer
      (org-mode)
      (insert "#+BEGIN: supertag-query :query \"(tag \\\"project\\\")\"\n#+END:\n")
      (goto-char (point-min))
      (org-update-dblock)
      (let ((text (buffer-string)))
        (should (= 6 (query-block-test--link-count text)))
        (should (string-match-p "Node 1" text))
        (should (string-match-p (regexp-quote "#+BEGIN: supertag-query") text))
        (should (string-match-p "#\\+END:" text))))))

(ert-deftest query-block-dblock-writer-honors-params ()
  "The dynamic block honors :sort/:order/:limit/:columns like the babel path."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (with-temp-buffer
      (org-mode)
      (insert "#+BEGIN: supertag-query :query \"(tag \\\"project\\\")\" :sort priority :order desc :limit 2 :columns (\"priority\")\n#+END:\n")
      (goto-char (point-min))
      (org-update-dblock)
      (let ((text (buffer-string)))
        (should (= 2 (query-block-test--link-count text)))
        (should (string-match-p "Node 3" text))
        (should (string-match-p "priority" text))))))

;;; --- 5. Errors never signal ---

(ert-deftest query-block-malformed-query-renders-error-no-signal ()
  "A malformed query s-expression renders a one-line error, never signals."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (let ((table (org-babel-execute:supertag-query-block
                  "(this-is-not-an-operator 1 2)" nil)))
      (should (stringp table))
      (should (string-prefix-p "Error:" table)))))

(ert-deftest query-block-unparseable-sexp-renders-error-no-signal ()
  "An unparseable s-expression string renders a one-line error, never signals."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (let ((table (org-babel-execute:supertag-query-block
                  "(tag \"project\"" nil))) ; missing closing paren
      (should (stringp table))
      (should (string-prefix-p "Error:" table)))))

(ert-deftest query-block-invalid-order-renders-error-no-signal ()
  "An invalid :order value renders a one-line error, never signals."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (let ((table (org-babel-execute:supertag-query-block
                  "(tag \"project\")" '((:order . "sideways")))))
      (should (stringp table))
      (should (string-prefix-p "Error:" table)))))

(ert-deftest query-block-dblock-malformed-query-renders-error-no-signal ()
  "The dynamic block renders a one-line error for a malformed query too."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (with-temp-buffer
      (org-mode)
      (insert "#+BEGIN: supertag-query :query \"(bogus-op)\"\n#+END:\n")
      (goto-char (point-min))
      (org-update-dblock)
      (let ((text (buffer-string)))
        (should (string-match-p "Error:" text))))))

(ert-deftest query-block-dblock-missing-query-renders-error-no-signal ()
  "The dynamic block renders a one-line error when :query is absent."
  (query-block-test--with-clean-store
    (query-block-test--make-fixture)
    (with-temp-buffer
      (org-mode)
      (insert "#+BEGIN: supertag-query\n#+END:\n")
      (goto-char (point-min))
      (org-update-dblock)
      (let ((text (buffer-string)))
        (should (string-match-p "Error:" text))))))

(ert-deftest query-block-task-operator-matches-todo-states ()
  "(task ...) matches projected :todo states; multi-arg is OR."
  (query-block-test--with-clean-store
    (supertag-store-put-entity
     :nodes "n1" '(:id "n1" :title "a" :todo "TODO" :priority "A"))
    (supertag-store-put-entity
     :nodes "n2" '(:id "n2" :title "b" :todo "DOING"))
    (supertag-store-put-entity
     :nodes "n3" '(:id "n3" :title "c"))
    (should (equal '("n1") (supertag-query-node-ids '(task "TODO"))))
    (should (equal '("n1" "n2")
                   (sort (supertag-query-node-ids
                          '(task "TODO" "DOING")) #'string<)))
    ;; Case-sensitive: lowercase does not match a projected TODO.
    (should-not (supertag-query-node-ids '(task "todo")))
    ;; A node without a todo state never matches.
    (should-not (member "n3" (supertag-query-node-ids '(task "TODO" "DOING"))))
    ;; Zero states match nothing.
    (should-not (supertag-query-node-ids '(task)))
    ;; Combines with not.
    (should (equal '("n2" "n3")
                   (sort (supertag-query-node-ids
                          '(not (task "TODO"))) #'string<)))))

(ert-deftest query-block-priority-operator-matches-case-insensitively ()
  "(priority ...) matches projected :priority cookies case-insensitively."
  (query-block-test--with-clean-store
    (supertag-store-put-entity
     :nodes "n1" '(:id "n1" :title "a" :priority "A"))
    (supertag-store-put-entity
     :nodes "n2" '(:id "n2" :title "b" :priority "B"))
    (supertag-store-put-entity
     :nodes "n3" '(:id "n3" :title "c"))
    (should (equal '("n1") (supertag-query-node-ids '(priority "a"))))
    (should (equal '("n1" "n2")
                   (sort (supertag-query-node-ids
                          '(priority "A" "B")) #'string<)))
    (should-not (supertag-query-node-ids '(priority "C")))
    (should-not (supertag-query-node-ids '(priority)))
    ;; The scan projection stores "#A" (with the leading #); queries
    ;; spelled without it still match (n1 carries plain "A").
    (supertag-store-put-entity
     :nodes "n4" (list :id "n4" :title "d" :priority "#A"))
    (should (equal '("n1" "n4")
                   (sort (supertag-query-node-ids '(priority "A"))
                         #'string<)))
    (should (equal '("n1" "n4")
                   (sort (supertag-query-node-ids '(priority "#a"))
                         #'string<)))))

(ert-deftest query-block-not-accepts-multiple-arguments ()
  "(not a b ...) excludes the union of its children."
  (query-block-test--with-clean-store
    (supertag-store-put-entity
     :nodes "n1" (list :id "n1" :title "a" :tags (list "x")))
    (supertag-store-put-entity
     :nodes "n2" (list :id "n2" :title "b" :tags (list "y")))
    (supertag-store-put-entity
     :nodes "n3" (list :id "n3" :title "c" :tags (list "z")))
    ;; Multi-arg not = (not (or (tag "x") (tag "y"))).
    (should (equal '("n3")
                   (supertag-query-node-ids '(not (tag "x") (tag "y")))))
    ;; Single-arg behavior unchanged.
    (should (equal '("n2" "n3")
                   (sort (supertag-query-node-ids '(not (tag "x")))
                         #'string<)))
    ;; Zero args still signal.
    (should-error (supertag-query-node-ids '(not)))
    ;; Nested: (not (task "TODO") (priority "A")) excludes both sets.
    (supertag-store-put-entity
     :nodes "n4" '(:id "n4" :title "d" :todo "TODO"))
    (should-not (member "n4" (supertag-query-node-ids
                              '(not (task "TODO") (tag "x")))))))

(ert-deftest query-block-day-symbols-resolve-to-local-midnight ()
  "today/yesterday/tomorrow resolve to local midnight boundaries."
  ;; Fix "now" to a known moment: 2026-08-13 15:30:00 local.
  (cl-letf (((symbol-function 'current-time)
             (lambda () (encode-time 0 30 15 13 8 2026))))
    (let* ((today (supertag-query--resolve-date-string "today"))
           (yesterday (supertag-query--resolve-date-string "yesterday"))
           (tomorrow (supertag-query--resolve-date-string "tomorrow"))
           (decoded-today (decode-time today))
           (decoded-yesterday (decode-time yesterday)))
      ;; today is 2026-08-13 00:00:00 local.
      (should (equal '(0 0 0 13 8 2026)
                     (cl-subseq decoded-today 0 6)))
      ;; yesterday is exactly one day earlier at midnight.
      (should (equal '(0 0 0 12 8 2026)
                     (cl-subseq decoded-yesterday 0 6)))
      ;; today - yesterday = 86400 seconds.
      (should (= 86400 (time-to-seconds
                        (time-subtract today yesterday))))
      ;; tomorrow is one day ahead.
      (should (= 86400 (time-to-seconds
                        (time-subtract tomorrow today))))
      ;; Day symbols work inside query operators.
      (should (time-less-p yesterday today))
      (should (time-less-p today tomorrow)))))

(ert-deftest query-block-hour-and-minute-units ()
  "Relative h/min units resolve to the expected offsets."
  (cl-letf (((symbol-function 'current-time)
             (lambda () (encode-time 0 0 0 13 8 2026))))
    (should (= 14400 (time-to-seconds
                      (time-subtract
                       (supertag-query--resolve-date-string "now")
                       (supertag-query--resolve-date-string "-4h")))))
    (should (= 1800 (time-to-seconds
                     (time-subtract
                      (supertag-query--resolve-date-string "now")
                      (supertag-query--resolve-date-string "-30min")))))
    (should (= 1800 (time-to-seconds
                     (time-subtract
                      (supertag-query--resolve-date-string "+30min")
                      (supertag-query--resolve-date-string "now")))))
    ;; Existing units keep working.
    (should (= 604800 (time-to-seconds
                       (time-subtract
                        (supertag-query--resolve-date-string "now")
                        (supertag-query--resolve-date-string "-1w")))))))

(ert-deftest query-block-sort-by-modifier-sorts-results ()
  "(sort-by ...) inside and sorts results; missing keys go last."
  (query-block-test--with-clean-store
    (supertag-store-put-entity
     :nodes "n1" (list :id "n1" :title "B" :created-at (encode-time 0 0 10 10 8 2026)))
    (supertag-store-put-entity
     :nodes "n2" (list :id "n2" :title "A" :created-at (encode-time 0 0 9 9 8 2026)))
    (supertag-store-put-entity
     :nodes "n3" (list :id "n3" :title "C"))
    (let ((asc (supertag-query-node-ids '(and (sort-by "title" asc))))
          (desc (supertag-query-node-ids '(and (sort-by "title"))))
          (created-desc
           (supertag-query-node-ids '(and (sort-by "created" desc))))
          (bare (supertag-query-node-ids '(sort-by "title" asc)))
          (combined
           (supertag-query-node-ids
            '(and (sort-by "created" desc) (term "B")))))
      ;; title asc by explicit order.
      (should (equal '("n2" "n1" "n3") asc))
      ;; default order is desc.
      (should (equal '("n3" "n1" "n2") desc))
      ;; created desc: n1 (Aug 10) before n2 (Aug 9); n3 missing -> last.
      (should (equal '("n1" "n2" "n3") created-desc))
      ;; Bare sort-by query sorts everything.
      (should (= 3 (length bare)))
      ;; Combined with filters.
      (should (equal '("n1") combined)))))

(ert-deftest query-block-sort-by-wins-over-header-sort ()
  "In-query sort-by takes precedence over the :sort header."
  (query-block-test--with-clean-store
    (supertag-store-put-entity
     :nodes "n1" (list :id "n1" :title "B"))
    (supertag-store-put-entity
     :nodes "n2" (list :id "n2" :title "A"))
    (let ((table (org-babel-execute:supertag-query-block
                  "(and (sort-by \"title\" asc))"
                  '(:sort "title" :order desc))))
      ;; asc from the syntax wins: A row appears before B row.
      (should (string-match-p (regexp-quote "A") table))
      (should (string-match-p (regexp-quote "B") table))
      (should (< (string-match-p (regexp-quote "A") table)
                 (string-match-p (regexp-quote "B") table))))))

(ert-deftest query-block-dynamic-variables-expand-to-day-symbols ()
  "<%today%>/<%yesterday%>/<%tomorrow%> expand before parsing."
  (should (equal "(after \"today\")"
                 (supertag-query-expand "(after \"<%today%>\")")))
  (should (equal "(between \"yesterday\" \"today\")"
                 (supertag-query-expand
                  "(between \"<%yesterday%>\" \"<%today%>\")")))
  (should (equal "(before tomorrow)"
                 (supertag-query-expand "(before <%tomorrow%>)")))
  ;; Unrelated text stays untouched.
  (should (equal "(tag \"<%monday%>\")"
                 (supertag-query-expand "(tag \"<%monday%>\")")))
  ;; End to end: a dynamic variable resolves to the day's midnight.
  (cl-letf (((symbol-function 'current-time)
             (lambda () (encode-time 0 30 15 13 8 2026))))
    (let ((sexp (car (read-from-string
                      (supertag-query-expand "(after \"<%today%>\")")))))
      (should (equal '(after "today") sexp))
      ;; A bare variable (no quotes around it) normalizes to a string
      ;; date argument in the parser.
      (should (equal "today"
                     (plist-get
                      (supertag-query--parse-sexp
                       (car (read-from-string
                             (supertag-query-expand "(after <%today%>)"))))
                      :date))))))

(ert-deftest query-block-aggregate-modifiers ()
  "Aggregate modifiers reduce results; group-by yields an alist."
  (query-block-test--with-clean-store
    (supertag-store-put-entity
     :nodes "n1" (list :id "n1" :title "a"))
    (supertag-store-put-entity
     :nodes "n2" (list :id "n2" :title "b"))
    (supertag-store-put-entity
     :nodes "n3" (list :id "n3" :title "c"))
    (supertag-store-put-field-value "n1" "pages" 100)
    (supertag-store-put-field-value "n2" "pages" 200)
    (supertag-store-put-field-value "n1" "genre" "tech")
    (supertag-store-put-field-value "n2" "genre" "novel")
    (supertag-store-put-field-value "n3" "pages" 50)
    (supertag-store-put-field-value "n3" "genre" "tech")
    (let ((total (supertag-query-evaluate '(and (sum "pages"))))
          (count (supertag-query-evaluate '(and (count))))
          (grouped (supertag-query-evaluate
                    '(and (group-by "genre") (sum "pages")))))
      (should (= 350 total))
      (should (= 3 count))
      (should (equal '(("novel" . 200) ("tech" . 150)) grouped))))
  ;; Non-numeric sum is nil, not an error.
  (query-block-test--with-clean-store
    (supertag-store-put-entity
     :nodes "n1" (list :id "n1" :title "a"))
    (supertag-store-put-field-value "n1" "note" "hello")
    (should-not (supertag-query-evaluate '(and (sum "note"))))))

(ert-deftest query-block-aggregate-guards ()
  "Malformed aggregate queries signal clearly."
  (query-block-test--with-clean-store
    ;; group-by without aggregate
    (should-error (supertag-query-evaluate '(and (group-by "genre"))))
    ;; two aggregates
    (should-error (supertag-query-evaluate
                   '(and (sum "pages") (count))))
    ;; node-ids refuses aggregates
    (should-error (supertag-query-node-ids '(and (sum "pages"))))
    ;; count takes no arguments
    (should-error (supertag-query-evaluate '(and (count "pages"))))
    ;; sort runs before aggregate: sorted order feeds grouping order only;
    ;; scalar aggregate is order-independent.
    (supertag-store-put-entity
     :nodes "n1" (list :id "n1" :title "a"))
    (supertag-store-put-field-value "n1" "pages" 100)
    (should (= 100
               (supertag-query-evaluate
                '(and (sort-by "title" asc) (sum "pages")))))))

(ert-deftest query-block-aggregate-renders-scalar-and-grouped-tables ()
  "Aggregate queries render a scalar row or a group/aggregate table."
  (query-block-test--with-clean-store
    (supertag-store-put-entity
     :nodes "n1" (list :id "n1" :title "a"))
    (supertag-store-put-entity
     :nodes "n2" (list :id "n2" :title "b"))
    (supertag-store-put-field-value "n1" "pages" 100)
    (supertag-store-put-field-value "n2" "pages" 200)
    (supertag-store-put-field-value "n1" "genre" "tech")
    (supertag-store-put-field-value "n2" "genre" "novel")
    ;; Scalar aggregate renders one Aggregate column with the value.
    (let ((table (org-babel-execute:supertag-query-block
                  "(and (sum \"pages\"))" nil)))
      (should (string-match-p "|[ \t]*Aggregate[ \t]*|" table))
      (should (string-match-p "300" table)))
    ;; Grouped aggregate renders Group + Aggregate columns.
    (let ((table (org-babel-execute:supertag-query-block
                  "(and (group-by \"genre\") (sum \"pages\"))" nil)))
      (should (string-match-p "|[ \t]*Group[ \t]*|[ \t]*Aggregate[ \t]*|" table))
      (should (string-match-p "novel" table))
      (should (string-match-p "tech" table))
      (should (string-match-p "200" table))
      (should (string-match-p "100" table)))))

(provide 'query-block-test)

;;; query-block-test.el ends here
