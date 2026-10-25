;;; summary-test.el --- Summary panels without a model -*- lexical-binding: t; -*-

;;; Commentary:

;; A summary panel's layout is written by a model.  These tests cover
;; everything around that: hand-written layouts and components stand in for
;; what a model would write, and where a reply is needed `supertag-summary--ask'
;; is replaced.  No model is called and nothing outside a temporary vault is
;; touched.
;;
;; Each [Enforced] and [Accepted] rule of summary.md has a test here; the
;; test's docstring names the rule.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-summary)

(defconst supertag-summary-test--board
  "(lambda (data width)
  (let* ((entries (plist-get data :records))
         (projects (cl-remove-if-not (lambda (entry) (plist-get entry :root)) entries))
         (tasks (cl-remove-if (lambda (entry) (plist-get entry :root)) entries))
         (open (cl-remove-if (lambda (entry) (equal (plist-get entry :todo) \"DONE\"))
                             tasks))
         (label (max 10 (- width 14)))
         (row (lambda (entry)
                `(:type :flex :direction :row :gap 1
                  :children
                  ((:type supertag-summary-todo :node ,(plist-get entry :ref))
                   (:type supertag-summary-link :width ,label
                    :node ,(plist-get entry :ref)
                    :label ,(or (plist-get entry :title) \"\")))))))
    (append
     (list
      `(:type :flex :direction :row :gap 2
        :children
        ((:type supertag-summary-fill :label \"open / tasks\" :tone 1)
         (:type supertag-summary-bar :value ,(- (length tasks) (length open))
          :max ,(max 1 (length tasks)) :width 20)
         (:type supertag-summary-line :tone :mute
          :value ,(format \"%d of %d done\" (- (length tasks) (length open))
                          (length tasks))))))
     (mapcar
      (lambda (project)
        (let ((mine (cl-remove-if-not
                     (lambda (entry) (equal (plist-get entry :owner)
                                            (plist-get project :ref)))
                     tasks)))
          `(:type :flex :direction :column :gap 0
            :children
            ,(append
              (list `(:type supertag-summary-fill :tone 2 :width ,(min width 40)
                      :label ,(or (plist-get project :title) \"\")))
              (mapcar row (cl-sort (seq-copy mine) 'string<
                                   :key (lambda (entry)
                                          (if (equal (plist-get entry :todo) \"DONE\")
                                              \"1\" \"0\"))))))))
      projects)
     (let ((loose (cl-remove-if (lambda (entry) (plist-get entry :owner)) tasks)))
       (when loose
         (list `(:type :flex :direction :column :gap 0
                 :children
                 ,(cons '(:type supertag-summary-line :tone :mute
                          :value \"no project\")
                        (mapcar row loose)))))))))"
  "A layout with state buttons, standing in for one a model would write.")

(defconst supertag-summary-test--week-heat
  "(lambda (days width)
  \"按周排列的日历热力图。DAYS 是 \\\"YYYY-MM-DD\\\" 字符串的列表，nil 会被忽略。WIDTH 是可用宽度。占 8 行。\"
  (let* ((stamps (delq nil
                       (mapcar (lambda (day)
                                 (when (and (stringp day) (= (length day) 10))
                                   (round (/ (float-time
                                              (date-to-time (concat day \" 00:00:00\")))
                                             86400))))
                               days))))
    (if (null stamps)
        (list '(:type supertag-summary-line :tone :mute :value \"no dated notes\"))
      (let* ((latest (apply 'max stamps))
             (earliest (apply 'min stamps))
             (final (floor (+ latest 3) 7))
             (weeks (min (max 1 (/ (- width 4) 2))
                         (1+ (- final (floor (+ earliest 3) 7)))))
             (origin (- (* (1+ (- final weeks)) 7) 3))
             (cells (make-vector (* weeks 7) 0))
             (peak 1)
             (rows nil))
        (dolist (stamp stamps)
          (let ((slot (- stamp origin)))
            (when (and (>= slot 0) (< slot (* weeks 7)))
              (aset cells slot (1+ (aref cells slot)))
              (setq peak (max peak (aref cells slot))))))
        (dotimes (weekday 7)
          (let ((line (list (list (nth weekday '(\"Mon \" \"    \" \"Wed \" \"    \"
                                                 \"Fri \" \"    \" \"Sun \"))
                                  :mute))))
            (dotimes (week weeks)
              (let ((amount (aref cells (+ (* week 7) weekday))))
                (push (cond ((zerop amount) '(\"· \" :mute))
                            (t (make-string
                                2 (aref \"░▒▓█\"
                                        (1- (min 4 (max 1 (ceiling (* 4 (/ (float amount)
                                                                          peak))))))))))
                      line)))
            (push (reverse line) rows)))
        (list `(:type supertag-summary-canvas :rows ,(reverse rows)))))))"
  "A component drawing a canvas, standing in for one a model would write.")

(defconst supertag-summary-test--week-heat-demo
  "(lambda (data width)
  (let ((days (mapcar (lambda (entry) (plist-get entry :day))
                      (plist-get data :records))))
    (list
     `(:type :flex :direction :column :gap 0
       :children
       ,(append
         (list `(:type supertag-summary-line :tone :mute
                 :value ,(format \"%d notes by week\" (length days))))
         (funcall week-heat days width))))))"
  "The demo layout of the stand-in component.")

(defmacro supertag-summary-test-with-vault (&rest body)
  "Run BODY in a vault of two projects and five tasks, one outside a project.
`prj' and `task' are Tag IDs; `task' extends `prj'.  `projects' is the Org
file.  Panels are kept under the vault."
  (declare (indent 0) (debug t))
  `(supertag-document-test-with-vault
     (let ((projects (expand-file-name "projects.org" tmp))
           (supertag-summary-directory nil)
           (supertag-summary--panels (make-hash-table :test 'equal))
           (supertag-summary--candidate nil)
           (supertag-summary--last nil)
           (supertag-tag-rekey-functions (list #'supertag-summary-rekey-tag)))
       (supertag-tag-create (list :id "prj" :name "prj"))
       (supertag-tag-create (list :id "task" :name "task" :extends '("prj")))
       (with-temp-file projects
         (insert "#+TODO: TODO NEXT DOING | DONE\n"
                 "* Alpha launch #prj\n:PROPERTIES:\n:ID:       ws-alpha\n:STAGE:    active\n:PHONE:    555-0101\n:REVIEWED: [2026-03-05 Thu]\n:END:\n"
                 "** TODO Write the announcement #task\n:PROPERTIES:\n:ID:       ws-a1\n:CREATED:  [2026-03-02 Mon]\n:END:\nBody secret alpha.\n"
                 "** DONE Book the venue #task\n:PROPERTIES:\n:ID:       ws-a2\n:CREATED:  [2026-03-04 Wed]\n:END:\n"
                 "** NEXT Call the printer #task\n:PROPERTIES:\n:ID:       ws-a3\n:CREATED:  [2026-03-11 Wed]\n:END:\n"
                 "* Beta cleanup #prj\n:PROPERTIES:\n:ID:       ws-beta\n:STAGE:    active\n:PHONE:    555-0199\n:END:\n"
                 "** TODO Archive old notes #task\n:PROPERTIES:\n:ID:       ws-b1\n:CREATED:  [2026-03-12 Thu]\n:END:\n"
                 "* TODO Stray errand #task\n:PROPERTIES:\n:ID:       ws-s1\n:END:\n"))
       (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
       (setq supertag-async--queue nil)
       (unwind-protect (progn ,@body)
         (dolist (buffer (buffer-list))
           (when (string-prefix-p "*Supertag Summary" (buffer-name buffer))
             (kill-buffer buffer)))))))

(defun supertag-summary-test--panel (&optional name)
  "Return a panel named NAME over `prj' with its records fetched."
  (let ((panel (supertag-summary--make (or name "board") "prj" "batch check")))
    (supertag-summary--sync panel)
    panel))

(defun supertag-summary-test--rows ()
  "Return the records of `prj' as (ID REF TODO OWNER ROOT) rows."
  (pcase-let ((`(,index . ,data) (supertag-summary--collect "prj")))
    (mapcar (lambda (entry)
              (list (plist-get (supertag-summary--node index (plist-get entry :ref))
                               :id)
                    (plist-get entry :ref) (plist-get entry :todo)
                    (plist-get entry :owner) (plist-get entry :root)))
            (plist-get data :records))))

(defun supertag-summary-test--page (panel code width)
  "Return the page of PANEL drawn by CODE at WIDTH as attributed text."
  (pcase (supertag-summary--field panel code width)
    (`(:ok ,field . ,_) (supertag-summary--text panel field width))
    (`(:failed ,reason) (ert-fail (list "layout refused" reason)))))

(defun supertag-summary-test--refused (panel code)
  "Return the reason PANEL refuses the layout CODE, failing when it draws."
  (pcase (supertag-summary--field panel code 80)
    (`(:failed ,reason) reason)
    (outcome (ert-fail (list "layout was accepted" code outcome)))))

(defun supertag-summary-test--button (id)
  "Return (FROM TO) of the state button of node ID in the current buffer."
  (cdr (assoc (list 'todo id) textui--focus-anchors)))

(defun supertag-summary-test--buffer-text ()
  "Return the text of the current buffer without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

;;; The fact layer

(ert-deftest supertag-summary-records-come-from-the-store ()
  "Records carry state, owner and root, and are numbered in file order."
  (supertag-summary-test-with-vault
    (should (equal (supertag-summary-test--rows)
                   '(("ws-alpha" "n1" nil nil t)
                     ("ws-a1" "n2" "TODO" "n1" nil)
                     ("ws-a2" "n3" "DONE" "n1" nil)
                     ("ws-a3" "n4" "NEXT" "n1" nil)
                     ("ws-beta" "n5" nil nil t)
                     ("ws-b1" "n6" "TODO" "n5" nil)
                     ("ws-s1" "n7" "TODO" nil nil))))
    (let ((data (cdr (supertag-summary--collect "prj"))))
      (should (equal (plist-get data :title) "#prj"))
      (should (equal (plist-get (nth 1 (plist-get data :records)) :day)
                     "2026-03-02"))
      (should (equal (plist-get (nth 1 (plist-get data :records)) :tags)
                     '("task"))))))

(ert-deftest supertag-summary-skips-files-the-user-excluded ()
  "Notes in files matching the skip regexp are left out of every panel."
  (supertag-summary-test-with-vault
    (let ((supertag-summary-skip-file-regexp "projects\\.org\\'"))
      (should-not (supertag-summary-test--rows)))
    (let ((supertag-summary-skip-file-regexp nil))
      (should (= 7 (length (supertag-summary-test--rows)))))))

(ert-deftest supertag-summary-design-sends-a-sample-and-no-body ()
  "Designing a panel sends six records' facts and no note body."
  (supertag-summary-test-with-vault
    (let (sent)
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (prompt system _callback) (setq sent (list prompt system)))))
        (supertag-summary-design "prj" "board" "show my tasks"))
      (should (string-match-p "show my tasks" (car sent)))
      (should (string-match-p "Write the announcement" (car sent)))
      (should (string-match-p ":priority、:scheduled、:deadline 全部是 nil" (car sent)))
      (should-not (string-match-p "Stray errand" (car sent)))
      (dolist (text sent)
        (should-not (string-match-p "Body secret" text))))))

(ert-deftest supertag-summary-records-carry-properties ()
  "A record gives its properties, a date property as YYYY-MM-DD."
  (supertag-summary-test-with-vault
    (pcase-let* ((`(,_index . ,data) (supertag-summary--collect "prj"))
                 (alpha (seq-find (lambda (entry)
                                    (equal (plist-get entry :title) "Alpha launch"))
                                  (plist-get data :records)))
                 (props (plist-get alpha :props)))
      (should (equal (cdr (assoc "STAGE" props)) "active"))
      (should (equal (cdr (assoc "PHONE" props)) "555-0101"))
      (should (equal (cdr (assoc "REVIEWED" props)) "2026-03-05")))))

(ert-deftest supertag-summary-design-names-properties-and-hides-their-values ()
  "Designing a panel names the properties and shared values, never a value one note has."
  (supertag-summary-test-with-vault
    (let (sent)
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (prompt system _callback) (setq sent (list prompt system)))))
        (supertag-summary-design "prj" "board" "show my tasks"))
      (should (string-match-p "STAGE：2 条，常见值 active" (car sent)))
      (should (string-match-p "REVIEWED：1 条，日期" (car sent)))
      (should (string-match-p "PHONE：2 条" (car sent)))
      (should (string-match-p "(\"REVIEWED\" \\. \"2026-03-05\")" (car sent)))
      (dolist (text sent)
        (should-not (string-match-p "555-01" text)))
      (should (string-match-p "\\* 属性" (cadr sent))))))

;;; Acceptance and drawing

(ert-deftest supertag-summary-accepts-a-layout-at-120-and-80 ()
  "[Accepted] The page lays out at 120 and at 80 columns."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel)))
      (should (equal (supertag-summary--check panel supertag-summary-test--board)
                     '(:ok)))
      (let ((text (substring-no-properties
                   (supertag-summary-test--page
                    panel supertag-summary-test--board 80))))
        (should (string-match-p "\\[ TODO  \\] Write the announcement" text))
        (should (string-match-p "1 of 5 done" text))
        (should (string-match-p "SUPERTAG / SUMMARY" text))
        (should (string-match-p "PRJ / 7 NOTES" text))))))

(ert-deftest supertag-summary-refuses-an-overwide-line ()
  "[Accepted] No line is wider than the page."
  (supertag-summary-test-with-vault
    (pcase (supertag-summary--check
            (supertag-summary-test--panel)
            "(lambda (data width) (list `(:type supertag-summary-line :value ,(make-string 200 ?x))))")
      (`(:failed ,reason) (should (string-match-p "行超出" reason)))
      (verdict (ert-fail (list "overwide layout accepted" verdict))))))

(ert-deftest supertag-summary-refuses-functions-off-the-whitelist ()
  "[Accepted] [Enforced] The code uses only whitelisted functions."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel))
          (victim (expand-file-name "victim" tmp)))
      (with-temp-file victim (insert "keep"))
      (dolist (code (list (format "(lambda (data width) (delete-file %S) (list))" victim)
                          (format "(lambda (data width) (funcall (intern \"delete-file\") %S) (list))" victim)
                          "(lambda (data width) (while t) (list))"
                          "(lambda (data width) (list (list :type 'supertag-summary-line :value (car (read-from-string \"x\")))))"
                          "(progn (list))"))
        (should (stringp (supertag-summary-test--refused panel code))))
      (should (string-match-p
               "delete-file"
               (supertag-summary-test--refused
                panel (format "(lambda (data width) (delete-file %S) (list))" victim))))
      (should (file-exists-p victim)))))

(ert-deftest supertag-summary-names-a-missing-paren ()
  "Code that is not one whole expression is refused with what is missing."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel)))
      (should (string-match-p
               "少了 2 个右括号.*第 2 行"
               (supertag-summary-test--refused
                panel "(lambda (data width)\n  (list (list :type :text :value \"a\")")))
      (should (string-match-p
               "多了 1 个右括号.*第 2 行"
               (supertag-summary-test--refused
                panel "(lambda (data width)\n  (list)))")))
      (should (string-match-p
               "字符串.*第 1 行"
               (supertag-summary-test--refused
                panel "(lambda (data width) (list \"open)")))
      ;; A paren inside a string or written as a character is not counted.
      (should (equal (supertag-summary--check
                      panel "(lambda (data width) (list (list :type :text :value (format \"(%c\" ?\\())))")
                     '(:ok))))))

(ert-deftest supertag-summary-stops-code-that-never-finishes ()
  "Layout code that outruns its time is stopped and reported."
  (supertag-summary-test-with-vault
    (let ((supertag-summary-run-timeout 1))
      (should (string-match-p
               "被停止"
               (supertag-summary-test--refused
                (supertag-summary-test--panel)
                "(lambda (data width) (dotimes (a 100000) (dotimes (b 100000) (+ a b))) (list))"))))))

(ert-deftest supertag-summary-runner-loads-on-its-own ()
  "The runner works in a child Emacs that has no other Supertag code."
  (with-temp-buffer
    (should (eql 0 (call-process
                    (expand-file-name invocation-name invocation-directory)
                    nil t nil "-Q" "--batch"
                    "-l" (locate-library "supertag-summary-runner")
                    "--eval"
                    "(princ (list (featurep 'supertag-summary-runner) (featurep 'supertag-tag)))")))
    (should (string-match-p "(t nil)" (buffer-string)))))

;;; Elements

(ert-deftest supertag-summary-refuses-unknown-elements-and-properties ()
  "[Enforced] Only the 11 element types and their own properties pass."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel)))
      (dolist (code '("(lambda (data width) (list '(:type :image :file \"x.png\")))"
                      "(lambda (data width) (list '(:type widget-button :value \"x\")))"
                      "(lambda (data width) (list '(:type supertag-summary-line :value \"x\" :face error)))"
                      "(lambda (data width) (list '(:type supertag-summary-line :value \"x\" :tone :danger)))"
                      "(lambda (data width) (list '(:type supertag-summary-row :segments ((\"x\" . 1)))))"
                      "(lambda (data width) (list '(:type supertag-summary-canvas :rows (((\"x\" :danger))))))"
                      "(lambda (data width) (list '(:type supertag-summary-canvas :rows (((\"x\" bold))))))"
                      "(lambda (data width) (list '(:type supertag-summary-fill :label \"x\" :tone :strong)))"
                      "(lambda (data width) \"not a list\")"))
        (should (stringp (supertag-summary-test--refused panel code)))))))

(ert-deftest supertag-summary-refuses-an-action-from-layout-code ()
  "[Enforced] An element that carries :action refuses the whole panel."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel)))
      (dolist (code '("(lambda (data width) (list '(:type supertag-summary-todo :node \"n2\" :action ignore)))"
                      "(lambda (data width) (list '(:type supertag-summary-link :node \"n2\" :label \"x\" :action ignore)))"
                      "(lambda (data width) (list '(:type supertag-summary-fill :label \"x\" :action ignore)))"
                      "(lambda (data width) (list '(:type supertag-summary-canvas :rows ((\"x\")) :action ignore)))"
                      "(lambda (data width) (list '(:type :flex :action ignore :children ())))"))
        (should (string-match-p ":action"
                                (supertag-summary-test--refused panel code)))))))

(ert-deftest supertag-summary-button-shows-only-what-supertag-decides ()
  "[Enforced] What a state button shows cannot come from layout code."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel)))
      (should (string-match-p
               ":label"
               (supertag-summary-test--refused
                panel
                "(lambda (data width) (list '(:type supertag-summary-todo :node \"n2\" :label \"DONE\")))")))
      (pcase (supertag-summary--field
              panel
              "(lambda (data width) (list '(:type supertag-summary-todo :node \"n99\")))"
              80)
        (`(:ok ,elements ,unresolved)
         (should (eql unresolved 1))
         (should (eq (plist-get (car elements) :type) 'supertag-summary-line)))
        (outcome (ert-fail outcome)))
      ;; The same note may carry two buttons.
      (should (stringp (supertag-summary-test--page
                        panel
                        "(lambda (data width) (list '(:type supertag-summary-todo :node \"n2\") '(:type supertag-summary-todo :node \"n2\")))"
                        80))))))

(ert-deftest supertag-summary-rebuilds-text-without-properties ()
  "[Enforced] Text is regenerated, so no text property rides along."
  (let* ((supertag-summary--budget 100)
         (supertag-summary--unresolved 0)
         (supertag-summary--buttoned nil)
         (clean (supertag-summary--clean
                 (list :type 'supertag-summary-canvas
                       :rows (list (list (list (propertize "x" 'keymap 'evil
                                                           'face 'error)
                                               :mute))))
                 (make-hash-table :test 'equal) 0))
         (text (car (car (plist-get (car (plist-get clean :children))
                                    :segments))))
         (line (plist-get (supertag-summary--clean
                           (list :type 'supertag-summary-line
                                 :value (propertize "y" 'face 'error))
                           (make-hash-table :test 'equal) 0)
                          :value)))
    (should (equal text "x"))
    (should-not (text-properties-at 0 text))
    (should-not (text-properties-at 0 line))))

(ert-deftest supertag-summary-form-rules-hold-in-the-drawn-page ()
  "[Enforced] One size, no colored text, padded uppercase fills, [ ] buttons."
  (supertag-summary-test-with-vault
    (let* ((panel (supertag-summary-test--panel))
           (text (supertag-summary-test--page
                  panel supertag-summary-test--board 80))
           (faces nil)
           (position 0))
      (while position
        (let ((face (get-text-property position 'face text)))
          (dolist (one (if (listp face) face (list face)))
            (when one (cl-pushnew one faces))))
        (setq position (next-single-property-change position 'face text)))
      ;; Every face is one of the view's role faces or the button face, and
      ;; none of them sets a height.
      (dolist (face faces)
        (should (memq face '(supertag-view-mute supertag-view-accent
                             supertag-view-chip1 supertag-view-chip2
                             supertag-view-chip3 supertag-view-panel
                             supertag-view-rule widget-button)))
        (should (eq 'unspecified (face-attribute face :height nil nil))))
      ;; A fill is padded by one space on each side and upcased.
      (let ((start (string-match " OPEN / TASKS " text)))
        (should start)
        (should (eq 'supertag-view-chip1 (get-text-property start 'face text)))
        (should (eq 'supertag-view-chip1
                    (get-text-property (+ start 13) 'face text))))
      (should (string-match-p "\\[ REVISE \\]" text))
      (should (string-match-p "\\[ TODO  \\]" text)))))

(ert-deftest supertag-summary-fills-are-not-clickable ()
  "[Enforced] A fill expands to static text; only links and buttons act."
  (let ((fill (car (supertag-summary--expand-fill
                    '(:type supertag-summary-fill :label "x" :tone 1))))
        (line (car (supertag-summary--expand-line
                    '(:type supertag-summary-line :value "x")))))
    (should (eq (plist-get fill :type) 'supertag-view-tag-cards-item))
    (should-not (plist-member fill :action))
    (should-not (plist-member line :action))))

;;; Acting on an entry

(ert-deftest supertag-summary-state-button-writes-org-and-redraws ()
  "A state button writes the Org file; the panel redraws and point follows."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel)))
      (supertag-summary--accept panel supertag-summary-test--board)
      (with-current-buffer "*Supertag Summary: board*"
        (let ((position (car (supertag-summary-test--button "ws-a1")))
              (before (supertag-summary-test--rows))
              asked)
          (should position)
          (goto-char position)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest arguments)
                       (setq asked (list collection (nth 4 arguments)))
                       "DONE")))
            (widget-apply-action (widget-at (point))))
          ;; The file's own keywords are offered, the next state by default.
          (should (equal (car asked)
                         '("TODO" "NEXT" "DOING" "DONE" "(no state)")))
          (should (equal (cadr asked) "NEXT"))
          (should (string-match-p
                   "^\\*\\* DONE Write the announcement"
                   (supertag-document-test-disk projects)))
          (should (equal (plist-get (supertag-node-get "ws-a1") :todo) "DONE"))
          (should (equal (mapcar (lambda (row) (list (nth 0 row) (nth 1 row) (nth 3 row)))
                                 before)
                         (mapcar (lambda (row) (list (nth 0 row) (nth 1 row) (nth 3 row)))
                                 (supertag-summary-test--rows))))
          (let ((text (supertag-summary-test--buffer-text)))
            (should (string-match-p "\\[ DONE  \\] Write the announcement" text))
            (should (string-match-p "2 of 5 done" text)))
          (pcase-let ((`(,from ,to) (supertag-summary-test--button "ws-a1")))
            (should (and from (<= from (point)) (<= (point) to)))
            (should (/= from position))))))))

(ert-deftest supertag-summary-entry-titles-are-nodes-to-contextual-actions ()
  "An entry title is the node it names to Embark, as in Node View."
  (require 'supertag-embark)
  (supertag-summary-test-with-vault
    (supertag-summary--accept (supertag-summary-test--panel)
                              supertag-summary-test--board)
    (with-current-buffer "*Supertag Summary: board*"
      (goto-char (point-min))
      (should (search-forward "Write the announcement" nil t))
      (let ((start (match-beginning 0)) (end (match-end 0)))
        (should (equal "ws-a1" (get-text-property start 'supertag-node-id)))
        (should (equal "ws-a1" (get-text-property (1- end) 'supertag-node-id)))
        (should-not (get-text-property end 'supertag-node-id))
        (goto-char (+ start 4))
        (should (equal (supertag-embark-target-finder)
                       (cl-list* 'supertag-node-reference
                                 "Write the announcement" start end)))))))

(ert-deftest supertag-summary-unchanged-redraw-starts-no-child ()
  "A redraw with unchanged records does not run the layout code again."
  (supertag-summary-test-with-vault
    (supertag-summary--accept (supertag-summary-test--panel)
                              supertag-summary-test--board)
    (with-current-buffer "*Supertag Summary: board*"
      (let ((runs 0)
            (field (symbol-function 'supertag-summary--field)))
        (cl-letf (((symbol-function 'supertag-summary--field)
                   (lambda (&rest arguments)
                     (cl-incf runs)
                     (apply field arguments))))
          (textui-refresh (current-buffer))
          (textui-refresh (current-buffer)))
        (should (zerop runs))))))

(ert-deftest supertag-summary-page-frame-is-not-the-models ()
  "[Enforced] Masthead, manifesto, action row and colophon come from Supertag."
  (supertag-summary-test-with-vault
    (let* ((panel (supertag-summary-test--panel))
           (text (substring-no-properties
                  (supertag-summary-test--page
                   panel "(lambda (data width) (list '(:type supertag-summary-line :value \"only this\")))"
                   80)))
           (lines (split-string text "\n")))
      (should (string-match-p "\\` SUPERTAG / SUMMARY " (car lines)))
      (should (string-match-p "YOUR NOTES, AS THEY ARE NOW\\." text))
      (should (string-match-p "\\[ REVISE \\] +\\[ CODE \\] +\\[ REFRESH \\]" text))
      (should (string-match-p "only this" text))
      (should (string-match-p "01 / SUMMARY" text))
      (should (< (string-match "\\[ REFRESH \\]" text)
                 (string-match "only this" text)
                 (string-match "01 / SUMMARY" text))))))

;;; Kept panels

(ert-deftest supertag-summary-panel-file-is-data-and-reopens ()
  "A panel is one NAME.org.summary data file and opens again from it."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel))
          (file (supertag-summary--file "board")))
      (should (equal file (expand-file-name "summaries/board.org.summary" tmp)))
      (plist-put panel :revisions '("tighter"))
      (supertag-summary--accept panel supertag-summary-test--board)
      (kill-buffer "*Supertag Summary: board*")
      (clrhash supertag-summary--panels)
      ;; The layout keeps its line breaks, so a revision diffs line by line.
      (let ((text (supertag-document-test-disk file)))
        (should (string-match-p "\n :tag \"prj\"\n" text))
        (should (string-match-p "\n :revisions (\"tighter\")\n" text))
        (should (> (length (split-string text "\n")) 40)))
      (pcase (supertag-summary--read file 'panel)
        (`(:ok ,data)
         (should (equal (plist-get data :code) supertag-summary-test--board))
         (should (equal (plist-get data :sentence) "batch check")))
        (outcome (ert-fail outcome)))
      (should (equal (supertag-summary--names) '("board")))
      (with-current-buffer (supertag-summary-open "board")
        (should (string-match-p "\\[ TODO  \\] Write the announcement"
                                (supertag-summary-test--buffer-text)))))))

(ert-deftest supertag-summary-reads-a-file-changed-by-a-pull ()
  "A panel whose file changed on disk is read again before it is drawn."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel))
          (file (supertag-summary--file "board")))
      (supertag-summary--accept panel supertag-summary-test--board)
      (supertag-summary--write
       file (list :format 1 :kind 'panel :name "board" :tag "prj"
                  :sentence "from the other machine" :revisions nil
                  :code "(lambda (data width) (list '(:type supertag-summary-line :value \"pulled layout\")))"))
      (set-file-times file (time-add (current-time) 5))
      (with-current-buffer "*Supertag Summary: board*"
        (textui-refresh (current-buffer))
        (let ((text (supertag-summary-test--buffer-text)))
          (should (string-match-p "pulled layout" text))
          (should (string-match-p "from the other machine" text)))))))

(ert-deftest supertag-summary-unusable-file-is-skipped-with-a-message ()
  "A conflicted, unknown or broken file states the problem and stops nothing."
  (supertag-summary-test-with-vault
    (let ((good (list :format 1 :kind 'panel :name "x" :tag "prj"
                      :sentence "s" :revisions nil
                      :code "(lambda (data width) (list))")))
      (dolist (case (list
                     (cons "conflict" "<<<<<<< HEAD\n(:format 1)\n=======\n(:format 1)\n>>>>>>> theirs\n")
                     (cons "format" (prin1-to-string (plist-put (copy-sequence good) :format 2)))
                     (cons "broken" "(:format 1 :kind panel")
                     (cons "kind" (prin1-to-string (plist-put (copy-sequence good) :kind 'component)))
                     (cons "notag" (prin1-to-string (plist-put (copy-sequence good) :tag nil)))))
        (let ((file (supertag-summary--file (car case))))
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert (cdr case)))
          (with-current-buffer (supertag-summary-open (car case))
            (should (string-match-p
                     (format "%s\\.org\\.summary is skipped" (car case))
                     (replace-regexp-in-string
                      "\n" " " (supertag-summary-test--buffer-text))))
            (should-error (supertag-summary-revise (car case) "change")
                          :type 'user-error)))))
    (should (string-match-p
             "conflict markers"
             (cadr (supertag-summary--read (supertag-summary--file "conflict")
                                           'panel))))
    (should (string-match-p
             "format 2"
             (cadr (supertag-summary--read (supertag-summary--file "format")
                                           'panel))))))

(ert-deftest supertag-summary-file-is-never-evaluated ()
  "A kept layout is checked on every draw like a fresh one, and never run here."
  (supertag-summary-test-with-vault
    (let ((file (supertag-summary--file "trap"))
          (victim (expand-file-name "victim" tmp)))
      (with-temp-file victim (insert "keep"))
      (supertag-summary--write
       file (list :format 1 :kind 'panel :name "trap" :tag "prj"
                  :sentence "hand-edited" :revisions nil
                  :code (format "(lambda (data width) (delete-file %S) (list))"
                                victim)))
      (with-current-buffer (supertag-summary-open "trap")
        (should (string-match-p "cannot be drawn: .*delete-file"
                                (replace-regexp-in-string
                                 "\n" " " (supertag-summary-test--buffer-text)))))
      (should (file-exists-p victim)))))

(ert-deftest supertag-summary-panel-of-a-missing-tag-says-so ()
  "A panel whose Tag is gone opens with a message and is not deleted."
  (supertag-summary-test-with-vault
    (let ((file (supertag-summary--file "orphan")))
      (supertag-summary--write
       file (list :format 1 :kind 'panel :name "orphan" :tag "no-such-tag"
                  :sentence "s" :revisions nil
                  :code "(lambda (data width) (list))"))
      (with-current-buffer (supertag-summary-open "orphan")
        (should (string-match-p "no longer exists: no-such-tag"
                                (supertag-summary-test--buffer-text))))
      (should (file-exists-p file)))))

(ert-deftest supertag-summary-panel-follows-its-tag-through-a-rename ()
  "A renamed Tag keeps its panels, also when a legacy Tag gets a new ID."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel))
          (file (supertag-summary--file "board")))
      (supertag-summary--accept panel supertag-summary-test--board)
      (kill-buffer "*Supertag Summary: board*")
      ;; A rename changes the name of a Tag, not its ID: the file is untouched.
      (let ((before (supertag-document-test-disk file)))
        (supertag-tag-update "prj" (lambda (tag) (plist-put tag :name "project")))
        (should (equal before (supertag-document-test-disk file)))
        (with-current-buffer (supertag-summary-open "board")
          (let ((text (supertag-summary-test--buffer-text)))
            (should (string-match-p "PROJECT / 7 NOTES" text))
            (should (string-match-p "Write the announcement" text)))
          (kill-buffer)))
      ;; A legacy Tag, whose ID is its old name, is given a fresh ID once.
      (supertag-tag-rename--rekey "prj" "tag-fresh-id")
      (pcase (supertag-summary--read file 'panel)
        (`(:ok ,data) (should (equal (plist-get data :tag) "tag-fresh-id")))
        (outcome (ert-fail outcome)))
      (with-current-buffer (supertag-summary-open "board")
        (should (string-match-p "Write the announcement"
                                (supertag-summary-test--buffer-text)))))))

;;; Components

(ert-deftest supertag-summary-component-is-kept-and-reused ()
  "A component passes the panel checks, is kept, and a later panel calls it."
  (supertag-summary-test-with-vault
    (let* ((panel (supertag-summary-test--panel "week-heat-demo"))
           (reply (concat "```elisp\n" supertag-summary-test--week-heat "\n\n"
                          supertag-summary-test--week-heat-demo "\n```"))
           (forms (supertag-summary--forms (supertag-summary--strip-fence reply)))
           (verdict (supertag-summary--check-component panel 'week-heat forms)))
      (should (= 2 (length forms)))
      (should (eq (car verdict) :ok))
      (should-not (supertag-summary--components))
      (supertag-summary--keep-component 'week-heat (car forms) "weeks")
      (should (file-exists-p
               (expand-file-name "summaries/components/week-heat.org.summary" tmp)))
      (should (equal (mapcar #'car (supertag-summary--components)) '(week-heat)))
      ;; A second panel calls the kept component, which stays as it was.
      (let ((before (supertag-document-test-disk
                     (supertag-summary--component-file 'week-heat)))
            (second (supertag-summary-test--panel "weeks")))
        (should (equal (supertag-summary--check
                        second supertag-summary-test--week-heat-demo)
                       '(:ok)))
        (should (string-match-p
                 "^Mon [░▒▓█]"
                 (substring-no-properties
                  (supertag-summary-test--page
                   second supertag-summary-test--week-heat-demo 80))))
        (should (equal before (supertag-document-test-disk
                               (supertag-summary--component-file 'week-heat)))))
      (should (string-match-p "(funcall week-heat days width)"
                              (supertag-summary--components-manual)))
      (should (string-match-p "\\* 可用的组件" (supertag-summary--system))))))

(ert-deftest supertag-summary-component-passes-the-same-checks ()
  "[Enforced] A component is whitelisted like a panel and carries no action."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel))
          (call "(lambda (data width) (funcall bad width))"))
      (dolist (form '((lambda (width) "x" (delete-file "/tmp/nope") (list))
                      (lambda (width) "x" (funcall (intern "delete-file") "/tmp/nope"))
                      (progn (delete-file "/tmp/nope"))
                      (lambda (width) "x"
                        (list '(:type supertag-summary-line :value "x"
                                :action ignore)))))
        (let ((supertag-summary--candidate (cons 'bad form)))
          (should (stringp (supertag-summary-test--refused panel call)))))
      ;; A component may be named like an Emacs function.
      (let ((supertag-summary--candidate
             (cons 'calendar
                   '(lambda (width) "x"
                      (list `(:type supertag-summary-canvas
                              :rows ((("ok" 1) " " (,(format "%d" width) :mute)))))))))
        (should (eq :ok (car (supertag-summary--field
                              panel
                              "(lambda (data width) (funcall calendar width))"
                              80))))))))

(ert-deftest supertag-summary-component-replies-are-checked ()
  "A malformed component reply is refused with a reason, not crashed on."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary-test--panel)))
      (should (eq :failed
                  (car (supertag-summary--check-component
                        panel 'week-heat
                        (supertag-summary--forms
                         "(lambda (days width) \"doc\" (list\n\n(lambda (data width) (funcall week-heat nil width))")))))
      (should (string-match-p
               "说明字符串"
               (cadr (supertag-summary--check-component
                      panel 'plain
                      (list "(lambda (width) (list))"
                            "(lambda (data width) (funcall plain width))")))))
      ;; The example the component prompt shows must itself pass.
      (should (eq :ok
                  (car (supertag-summary--check-component
                        panel 'spark
                        (supertag-summary--forms
                         supertag-summary--component-example)))))
      (should-error (supertag-summary--component-name "Bad Name")
                    :type 'user-error)
      (should-error (supertag-summary--component-name "mapcar")
                    :type 'user-error)
      (should (eq 'week-heat (supertag-summary--component-name "week-heat"))))))

;;; Asking the model

(ert-deftest supertag-summary-prompts-are-well-formed ()
  "The prompts describe records, the 11 elements and intact examples."
  (supertag-summary-test-with-vault
    (let ((panel (supertag-summary--system))
          (component (supertag-summary--component-system 'week-heat)))
      (dolist (type (mapcar #'car supertag-summary--keys))
        (should (string-match-p (regexp-quote (format "(:type %s " type)) panel)))
      (should (= 11 (length supertag-summary--keys)))
      (should (string-match-p ":owner 这条记录按大纲位置所属" panel))
      (should (string-match-p "(format \"%d open of %d\"" panel))
      (should (string-match-p "\"%u\"" panel))
      (should-not (string-match-p ":groups" panel))
      (should-not (string-match-p "%s" panel))
      (should (string-match-p "名字是 week-heat" component))
      (should (string-match-p "(funcall week-heat 参数" component))
      (should (string-match-p "(funcall spark" component))
      (should-not (string-match-p "%s" component))
      ;; The example the panel prompt shows must itself pass.
      (should (equal (supertag-summary--check (supertag-summary-test--panel)
                                              supertag-summary--example)
                     '(:ok))))))

(ert-deftest supertag-summary-design-retries-then-keeps-the-layout ()
  "A refused reply goes back with its reason; an accepted one is kept."
  (supertag-summary-test-with-vault
    (let ((replies (list "(lambda (data width) (delete-file \"x\") (list))"
                         (concat "```elisp\n" supertag-summary-test--board "\n```")))
          prompts)
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (prompt _system callback)
                   (push prompt prompts)
                   (funcall callback (pop replies) 'completed))))
        (supertag-summary-design "prj" "board" "show my tasks"))
      (should (= 2 (length prompts)))
      (should (string-match-p "它被拒绝了：.*delete-file" (car prompts)))
      (should (eq :ok (plist-get supertag-summary--last :done)))
      (pcase (supertag-summary--read (supertag-summary--file "board") 'panel)
        (`(:ok ,data)
         (should (equal (plist-get data :code) supertag-summary-test--board))
         (should (equal (plist-get data :sentence) "show my tasks"))
         (should (equal (plist-get data :tag) "prj")))
        (outcome (ert-fail outcome)))
      (should (get-buffer "*Supertag Summary: board*"))
      ;; A revision keeps what the user said and replaces the layout.
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (prompt _system callback)
                   (should (string-match-p "tighter please" prompt))
                   (funcall callback
                            "(lambda (data width) (list '(:type supertag-summary-line :value \"revised\")))"
                            'completed))))
        (supertag-summary-revise "board" "tighter please"))
      (pcase (supertag-summary--read (supertag-summary--file "board") 'panel)
        (`(:ok ,data)
         (should (equal (plist-get data :revisions) '("tighter please")))
         (should (string-match-p "revised" (plist-get data :code))))
        (outcome (ert-fail outcome))))))

(ert-deftest supertag-summary-design-keeps-nothing-when-no-reply-passes ()
  "Three refused replies leave no panel file behind."
  (supertag-summary-test-with-vault
    (let ((asked 0))
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (_prompt _system callback)
                   (cl-incf asked)
                   (funcall callback "(lambda (data width) (kill-emacs))"
                            'completed))))
        (supertag-summary-design "prj" "board" "show my tasks"))
      (should (= 3 asked))
      (should (eq :failed (plist-get supertag-summary--last :done)))
      (should-not (file-exists-p (supertag-summary--file "board"))))))

(ert-deftest supertag-summary-design-asks-before-replacing-a-panel ()
  "Designing over an existing name asks first and keeps the file on no."
  (supertag-summary-test-with-vault
    (supertag-summary--accept (supertag-summary-test--panel)
                              supertag-summary-test--board)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
              ((symbol-function 'supertag-summary--ask)
               (lambda (&rest _) (ert-fail "the model was asked"))))
      (should-error (supertag-summary-design "prj" "board" "another")
                    :type 'user-error))
    (should-error (supertag-summary-design "prj" "../escape" "x")
                  :type 'user-error)
    (should-error (supertag-summary-design "no-such-tag" "x" "x")
                  :type 'user-error)))

(ert-deftest supertag-summary-component-command-keeps-component-not-demo ()
  "The component is kept as a file; its demo panel lives in the session only."
  (supertag-summary-test-with-vault
    (cl-letf (((symbol-function 'supertag-summary--ask)
               (lambda (_prompt _system callback)
                 (funcall callback
                          (concat supertag-summary-test--week-heat "\n\n"
                                  supertag-summary-test--week-heat-demo)
                          'completed))))
      (supertag-summary-component "prj" "week-heat" "weeks as a heat map"))
    (should (file-exists-p (supertag-summary--component-file "week-heat")))
    (should-not (file-exists-p (supertag-summary--file "week-heat-demo")))
    (with-current-buffer "*Supertag Summary: week-heat-demo*"
      (should (string-match-p "^Mon [░▒▓█]" (supertag-summary-test--buffer-text))))))

(ert-deftest supertag-summary-opens-without-superchat ()
  "Opening a kept panel needs no Superchat; designing one says what is missing."
  (supertag-summary-test-with-vault
    (should-not (fboundp 'superchat-runtime-submit))
    (supertag-summary--accept (supertag-summary-test--panel)
                              supertag-summary-test--board)
    (should (get-buffer "*Supertag Summary: board*"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (string-match-p
               "superchat"
               (cadr (should-error
                      (supertag-summary-design "prj" "board" "again")
                      :type 'user-error)))))))

(defmacro supertag-summary-test-with-gptel (request &rest body)
  "Run BODY with gptel taken as loaded and `gptel-request' as REQUEST."
  (declare (indent 1))
  `(let ((had (featurep 'gptel))
         (supertag-summary-provider 'gptel))
     (provide 'gptel)
     (unwind-protect
         (cl-letf (((symbol-function 'gptel-request) ,request)
                   ((symbol-function 'gptel-get-preset) #'ignore)
                   ((symbol-function 'gptel-abort) #'ignore))
           ,@body)
       (unless had (setq features (delq 'gptel features))))))

(ert-deftest supertag-summary-asks-through-gptel ()
  "gptel gets the prompt and system with no tools; its reply comes back."
  (let (seen result)
    (supertag-summary-test-with-gptel
        (lambda (prompt &rest args)
          (setq seen (list prompt (plist-get args :system) gptel-use-tools))
          (funcall (plist-get args :callback) "(lambda (data width) nil)" nil))
      (supertag-summary--ask "the prompt" "the system"
                             (lambda (text status) (setq result (list text status)))))
    (should (equal seen '("the prompt" "the system" nil)))
    (should (equal result '("(lambda (data width) nil)" completed)))))

(ert-deftest supertag-summary-gptel-failure-and-timeout ()
  "A failed gptel request, or none in time, reaches the caller once."
  (let (result)
    (supertag-summary-test-with-gptel
        (lambda (_prompt &rest args)
          (funcall (plist-get args :callback) nil '(:status "HTTP 401")))
      (supertag-summary--ask "p" "s" (lambda (text status) (push (list text status) result))))
    (should (equal result '(("HTTP 401" failed)))))
  (let (result (supertag-summary-timeout 0.05))
    (supertag-summary-test-with-gptel #'ignore
      (supertag-summary--ask "p" "s" (lambda (text status) (push status result)))
      (sleep-for 0.2))
    (should (equal result '(timeout)))))

(ert-deftest supertag-summary-own-provider ()
  "A function as provider is called in place of any package."
  (let (result (supertag-summary-provider
                (lambda (prompt _system callback) (funcall callback (upcase prompt) 'completed))))
    (supertag-summary--ask "hi" "s" (lambda (text status) (setq result (list text status))))
    (should (equal result '("HI" completed)))))

(provide 'summary-test)
;;; summary-test.el ends here
