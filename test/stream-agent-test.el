;;; stream-agent-test.el --- Stream agents without a model -*- lexical-binding: t; -*-

;;; Commentary:

;; A Stream agent is written by a model.  These tests cover everything
;; around that: hand-written agents stand in for what a model would write,
;; and where a reply is needed `supertag-summary--ask' is replaced.  No model
;; is called and nothing outside a temporary vault is touched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-stream-agent)

(defconst supertag-stream-agent-test--view
  "(lambda (data width)
  (let* ((today (plist-get data :today))
         (rows (mapcar (lambda (entry)
                         (let* ((last (cdr (assoc \"LAST_CONTACT\" (plist-get entry :props))))
                                (since (or last (plist-get entry :day))))
                           (list entry (funcall days since today) last)))
                       (plist-get data :records)))
         (due-p (lambda (row) (and (nth 1 row) (> (nth 1 row) 31))))
         (due (cl-sort (cl-remove-if-not due-p rows) '> :key 'cadr))
         (fine (cl-sort (cl-remove-if due-p rows) '<
                        :key (lambda (row) (or (nth 1 row) 0))))
         (line (lambda (row)
                 (list :ref (plist-get (car row) :ref)
                       :line (if (nth 2 row)
                                 (format \"%d 天没联系\" (nth 1 row))
                               (format \"%d 天 · 按创建日期算\" (or (nth 1 row) 0)))))))
    (list :header (format \"%d 人该联系了\" (length due))
          :notes \"没有 LAST_CONTACT 的人按创建日期算\"
          :groups (list (list :label \"该联系了\" :rows (mapcar line due))
                        (list :label \"最近联系过\" :rows (mapcar line fine))))))"
  "A view standing in for the one a model writes from the contact sentence.")

(defconst supertag-stream-agent-test--contact
  `(:name "contact"
    :sentence "超过一个月没联系的人浮到最上面；联系完点一下记一笔，它就沉下去。"
    :scope (:tag "contact")
    :fields ((:name "LAST_CONTACT" :shape date)
             (:name "TIER" :shape choice :values ("核心" "亲密" "熟识")))
    :view ,supertag-stream-agent-test--view
    :actions ((:key "c" :label "刚联系过" :field "LAST_CONTACT" :value today)
              (:key "1" :label "设为核心" :field "TIER" :value "核心")
              (:key "l" :label "选层级" :field "TIER" :value choose))))

(defconst supertag-stream-agent-test--family
  '(:name "family"
    :sentence "家人单独看。"
    :scope (:tag "family")
    :view "(lambda (data width)
  (list :header \"家人\"
        :groups (list (list :label \"家人\"
                            :rows (mapcar (lambda (entry)
                                            (list :ref (plist-get entry :ref) :line \"家人\"))
                                          (plist-get data :records))))))"))

(defun supertag-stream-agent-test--stamp (offset)
  "Return an Org date OFFSET days from today."
  (format-time-string "[%Y-%m-%d %a]" (time-add nil (days-to-time offset))))

(defmacro supertag-stream-agent-test-with-vault (&rest body)
  "Run BODY in a vault of contacts in two files and a diary.
`contact' and `diary' are Tag IDs; `family' extends `contact'.  Agents are
kept under the vault and arrange every Stream.  `friends' and `work' are the
two contact files; work.org declares TIER_ALL itself."
  (declare (indent 0) (debug t))
  `(supertag-document-test-with-vault
     (let ((friends (expand-file-name "friends.org" tmp))
           (work (expand-file-name "work.org" tmp))
           (supertag-stream-agent-directory nil)
           (supertag-stream-agent--last nil)
           (supertag-view-stream-arrange-function #'supertag-stream-agent-arrange))
       (dolist (tag '("contact" "diary"))
         (supertag-tag-create (list :id tag :name tag)))
       (supertag-tag-create (list :id "family" :name "family" :extends '("contact")))
       (with-temp-file friends
         (pcase-dolist (`(,name ,tag ,offset)
                        '(("Alice" "contact" -45) ("Bob" "contact" -10)
                          ("Carol" "contact" -90) ("Eve" "family" -40)))
           (insert (format "* %s #%s\n:PROPERTIES:\n:ID: c-%s\n:LAST_CONTACT: %s\n:END:\n"
                           name tag (downcase name)
                           (supertag-stream-agent-test--stamp offset)))))
       (with-temp-file work
         (insert "#+PROPERTY: TIER_ALL 核心 亲密 熟识 远\n\n"
                 (format "* Frank #contact\n:PROPERTIES:\n:ID: c-frank\n:CREATED: %s\n:PHONE: 555-0101\n:END:\n"
                         (supertag-stream-agent-test--stamp -60))))
       (with-temp-file (expand-file-name "diary.org" tmp)
         (insert "* Monday #diary\n:PROPERTIES:\n:ID: d1\n:END:\nBody secret.\n"))
       (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
       (setq supertag-async--queue nil)
       (unwind-protect (progn ,@body)
         (dolist (buffer (buffer-list))
           (when (string-match-p "\\`\\*Supertag Stream" (buffer-name buffer))
             (kill-buffer buffer)))))))

(defun supertag-stream-agent-test--keep (&rest agents)
  "Keep AGENTS as the only agents of the vault."
  (let ((directory (supertag-stream-agent--directory)))
    (when (file-directory-p directory) (delete-directory directory t))
    (dolist (agent agents) (supertag-stream-agent--write agent))))

(defun supertag-stream-agent-test--open (input)
  "Open the Stream of INPUT and return its buffer."
  (supertag-view-stream--open input))

(defun supertag-stream-agent-test--state (buffer)
  "Return the state BUFFER's Stream was drawn from."
  (with-current-buffer buffer (plist-get supertag-view--instance :state)))

(defun supertag-stream-agent-test--agent (buffer)
  "Return the name of the agent that drew BUFFER, or nil."
  (plist-get (plist-get (supertag-stream-agent-test--state buffer) :agent) :name))

(defun supertag-stream-agent-test--groups (buffer)
  "Return BUFFER's groups as (LABEL TITLE ...)."
  (mapcar (lambda (group)
            (cons (car group)
                  (mapcar (lambda (row) (plist-get (car row) :title)) (cdr group))))
          (plist-get (plist-get (supertag-stream-agent-test--state buffer)
                                :arrangement)
                     :groups)))

(defun supertag-stream-agent-test--prop (file heading key)
  "Return KEY under HEADING in FILE on disk, or nil."
  (with-temp-buffer
    (insert-file-contents file)
    (and (re-search-forward
          (concat "^\\* " heading ".*\n:PROPERTIES:\n\\(?:.*\n\\)*?:" key ":[ \t]+\\(.*\\)$")
          nil t)
         (match-string 1))))

(defun supertag-stream-agent-test--refusal (fields actions)
  "Return why an agent with FIELDS and ACTIONS over `contact' is refused."
  (supertag-stream-agent--refused
   (list :name "r" :scope '(:tag "contact") :view "(lambda (d w) nil)"
         :fields fields :actions actions)))

;;; Matching

(ert-deftest supertag-stream-agent-arranges-the-stream-of-its-tag ()
  "The agent of a tag groups and orders that tag's Stream as its view says."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep supertag-stream-agent-test--contact)
    (let ((buffer (supertag-stream-agent-test--open '(:tag "contact"))))
      (should (equal (supertag-stream-agent-test--agent buffer) "contact"))
      (should (equal (supertag-stream-agent-test--groups buffer)
                     '(("该联系了" "Carol" "Frank" "Alice" "Eve")
                       ("最近联系过" "Bob"))))
      ;; Moving through the Stream follows what is drawn.
      (should (equal (mapcar (lambda (node) (plist-get node :title))
                             (plist-get (supertag-stream-agent-test--state buffer) :nodes))
                     '("Carol" "Frank" "Alice" "Eve" "Bob")))
      (with-current-buffer buffer
        (should (string-search "AGENT / CONTACT" (buffer-string)))
        (should (string-search "4 人该联系了" (buffer-string)))
        (should (string-search "45 天没联系" (buffer-string)))
        (should (string-search "FIELDS / LAST_CONTACT date  TIER 核心, 亲密, 熟识"
                               (buffer-string)))))))

(ert-deftest supertag-stream-agent-matches-by-scope-not-by-inheritance ()
  "A narrowed Stream and a query Stream within the scope get the agent; others don't."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep supertag-stream-agent-test--contact)
    (should (equal (supertag-stream-agent-test--agent
                    (supertag-stream-agent-test--open
                     '(:tag "contact" :query (property "PHONE" "555-0101"))))
                   "contact"))
    (should (equal (supertag-stream-agent-test--agent
                    (supertag-stream-agent-test--open '(:query (tag "contact"))))
                   "contact"))
    (let ((diary (supertag-stream-agent-test--open '(:tag "diary"))))
      (should-not (supertag-stream-agent-test--agent diary))
      (should-not (plist-get (supertag-stream-agent-test--state diary) :arrangement)))))

(ert-deftest supertag-stream-agent-smallest-scope-wins ()
  "When two scopes hold a Stream, the agent of the smaller one draws it."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep supertag-stream-agent-test--contact
                                      supertag-stream-agent-test--family)
    (should (equal (supertag-stream-agent-test--agent
                    (supertag-stream-agent-test--open '(:tag "family")))
                   "family"))
    (should (equal (supertag-stream-agent-test--agent
                    (supertag-stream-agent-test--open '(:tag "contact")))
                   "contact"))))

(ert-deftest supertag-stream-agent-cannot-hide-a-node ()
  "A node the view leaves out is drawn in a last group."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep
     (plist-put (copy-sequence supertag-stream-agent-test--contact) :view
                "(lambda (data width)
  (list :groups (list (list :label \"一部分\"
                            :rows (mapcar (lambda (entry) (list :ref (plist-get entry :ref)))
                                          (cl-remove-if (lambda (entry) (equal (plist-get entry :title) \"Bob\"))
                                                        (plist-get data :records)))))))"))
    (should (equal (car (last (supertag-stream-agent-test--groups
                               (supertag-stream-agent-test--open '(:tag "contact")))))
                   '("Others" "Bob")))))

(ert-deftest supertag-stream-agent-that-fails-still-shows-every-node ()
  "A view that fails says why above all the nodes, and the agent's keys remain."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep
     (plist-put (copy-sequence supertag-stream-agent-test--contact) :view
                "(lambda (data width) (car 1))"))
    (let ((buffer (supertag-stream-agent-test--open '(:tag "contact"))))
      (should (equal (length (cdar (supertag-stream-agent-test--groups buffer))) 5))
      (with-current-buffer buffer
        (should (string-search "Cannot draw" (buffer-string)))
        (should (eq (key-binding (kbd "R")) #'supertag-stream-agent-revise))))))

(ert-deftest supertag-stream-agent-lines-fit-the-width ()
  "The view runs in the child at 100 and 80 columns, and lines are fitted."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep supertag-stream-agent-test--contact)
    (should-not (supertag-stream-agent--check supertag-stream-agent-test--contact))
    (let ((drawing (supertag-stream-agent--draw
                    (plist-put (copy-sequence supertag-stream-agent-test--contact) :view
                               "(lambda (data width)
  (list :groups (list (list :label \"x\"
                            :rows (list (list :ref \"n1\" :line (make-string 200 ?a)))))))")
                    (supertag-view-api-get-entities
                     :nodes (supertag-view-api-nodes-by-tag "contact" t))
                    40)))
      (should (<= (string-width (cdr (cadr (car (plist-get drawing :groups))))) 40)))))

;;; Outline

(defun supertag-stream-agent-test--projects (directory)
  "Add to DIRECTORY projects whose tasks sit under them, with a plain heading between."
  (supertag-tag-create (list :id "prj" :name "prj"))
  (supertag-tag-create (list :id "task" :name "task" :extends '("prj")))
  (with-temp-file (expand-file-name "projects.org" directory)
    (insert "* Hangji #prj\n:PROPERTIES:\n:ID: p-hangji\n:END:\n"
            "** Phase one\n:PROPERTIES:\n:ID: p-phase\n:END:\n"
            "*** Invoices #task\n:PROPERTIES:\n:ID: t-invoices\n:END:\n"
            "**** Customs code #task\n:PROPERTIES:\n:ID: t-customs\n:END:\n"
            "* Garden #prj\n:PROPERTIES:\n:ID: p-garden\n:END:\n"))
  (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
  (setq supertag-async--queue nil))

(defconst supertag-stream-agent-test--tree
  "(lambda (data width)
  (let* ((records (plist-get data :records))
         (kids (lambda (ref)
                 (seq-filter (lambda (entry) (equal (plist-get entry :parent) ref))
                             records)))
         (rows nil))
    (dolist (top (funcall kids nil))
      (push (list :ref (plist-get top :ref)) rows)
      (dolist (child (funcall kids (plist-get top :ref)))
        (push (list :ref (plist-get child :ref) :depth 1) rows)
        (dolist (grand (funcall kids (plist-get child :ref)))
          (push (list :ref (plist-get grand :ref) :depth 2) rows))))
    (list :groups (list (list :label \"项目\" :rows (nreverse rows))))))"
  "A view that hangs each task under its project.")

(ert-deftest supertag-stream-agent-records-carry-the-outline ()
  "Records give the level, the headings above, and the nearest ancestor in the Stream."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--projects tmp)
    (let* ((nodes (supertag-view-api-get-entities
                   :nodes (supertag-view-api-nodes-by-tag "prj" t)))
           (records (plist-get (cdr (supertag-stream-agent--records nodes)) :records))
           (by-title (lambda (title)
                       (cl-find title records
                                :key (lambda (entry) (plist-get entry :title))
                                :test #'equal))))
      (should (= 4 (length records)))
      (let ((hangji (funcall by-title "Hangji"))
            (invoices (funcall by-title "Invoices"))
            (customs (funcall by-title "Customs code")))
        (should (= 1 (plist-get hangji :level)))
        (should-not (plist-get hangji :parent))
        (should (= 3 (plist-get invoices :level)))
        (should (equal '("Hangji" "Phase one") (plist-get invoices :path)))
        ;; Phase one is not in the Stream, so Invoices hangs under Hangji.
        (should (equal (plist-get hangji :ref) (plist-get invoices :parent)))
        (should (equal (plist-get invoices :ref) (plist-get customs :parent)))
        (should-not (plist-get (funcall by-title "Garden") :parent))))))

(ert-deftest supertag-stream-agent-view-can-indent-a-row ()
  "A row's :depth indents it; a bad depth fails the view; the report counts indents."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--projects tmp)
    (let ((agent (list :name "prj" :sentence "任务挂在它的项目下面。"
                       :scope '(:tag "prj") :fields nil :actions nil
                       :view supertag-stream-agent-test--tree)))
      (supertag-stream-agent-test--keep agent)
      (let* ((buffer (supertag-stream-agent-test--open '(:tag "prj")))
             (rows (cdar (plist-get (plist-get (supertag-stream-agent-test--state buffer)
                                               :arrangement)
                                    :groups)))
             (depths (mapcar (lambda (row)
                               (cons (plist-get (car row) :title)
                                     (if (consp (cdr row)) (nth 2 row) 0)))
                             rows)))
        (should (equal 0 (cdr (assoc "Hangji" depths))))
        (should (equal 1 (cdr (assoc "Invoices" depths))))
        (should (equal 2 (cdr (assoc "Customs code" depths))))
        (should (equal 0 (cdr (assoc "Garden" depths))))
        ;; Each task comes right after the row it hangs under.
        (let ((titles (mapcar #'car depths)))
          (should (equal (cdr (member "Hangji" titles))
                         (append '("Invoices" "Customs code")
                                 (cdr (member "Customs code" titles))))))
        (with-current-buffer buffer
          (should (string-match-p "^  → Invoices" (buffer-string)))
          (should (string-match-p "^    → Customs code" (buffer-string)))
          (should (string-match-p "^Garden" (buffer-string)))))
      (should (string-search "缩进的行 2 条，其中 0 条没有排在它的上级下面"
                             (supertag-stream-agent--report agent)))
      (let ((flat (plist-put (copy-sequence agent) :view
                             "(lambda (data width)
  (list :groups (list (list :label \"x\"
                            :rows (mapcar (lambda (entry)
                                            (list :ref (plist-get entry :ref) :depth 1))
                                          (plist-get data :records))))))")))
        (should (string-search "其中 4 条没有排在它的上级下面"
                               (supertag-stream-agent--report flat))))
      (let ((bad (plist-put (copy-sequence agent) :view
                            "(lambda (data width)
  (list :groups (list (list :label \"x\"
                            :rows (list (list :ref \"n1\" :depth 9))))))")))
        (should (string-match-p ":depth must be"
                                (plist-get (supertag-stream-agent--draw
                                            bad (supertag-view-api-get-entities
                                                 :nodes (supertag-view-api-nodes-by-tag
                                                         "prj" t)))
                                           :failed)))))))

(ert-deftest supertag-stream-agent-view-can-leave-out-a-body ()
  "A row with :body nil draws its title alone; other rows keep their body."
  (supertag-stream-agent-test-with-vault
    (supertag-tag-create (list :id "prj" :name "prj"))
    (with-temp-file (expand-file-name "bodies.org" tmp)
      (insert "* Hangji #prj\n:PROPERTIES:\n:ID: p-hangji\n:END:\nProject plan.\n"
              "** Invoices #prj\n:PROPERTIES:\n:ID: t-invoices\n:END:\nTask detail.\n"))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (setq supertag-async--queue nil)
    (let ((agent (list :name "prj" :sentence "任务只显示标题。"
                       :scope '(:tag "prj") :fields nil :actions nil
                       :view "(lambda (data width)
  (list :groups
        (list (list :label \"项目\"
                    :rows (mapcar (lambda (entry)
                                    (if (plist-get entry :parent)
                                        (list :ref (plist-get entry :ref) :body nil)
                                      (list :ref (plist-get entry :ref))))
                                  (plist-get data :records))))))")))
      (supertag-stream-agent-test--keep agent)
      (with-current-buffer (supertag-stream-agent-test--open '(:tag "prj"))
        (should (string-search "Project plan." (buffer-string)))
        (should (string-search "Invoices" (buffer-string)))
        (should-not (string-search "Task detail." (buffer-string))))
      (should (string-search "只显示标题、不显示正文的行 1 条"
                             (supertag-stream-agent--report agent))))
    ;; An indented note is marked, and its body sits under its title text,
    ;; so the parent's body and the child's title never share a column.
    (supertag-stream-agent-test--keep
     (list :name "prj" :sentence "任务挂在项目下面。"
           :scope '(:tag "prj") :fields nil :actions nil
           :view "(lambda (data width)
  (list :groups
        (list (list :label \"项目\"
                    :rows (mapcar (lambda (entry)
                                    (list :ref (plist-get entry :ref)
                                          :depth (if (plist-get entry :parent) 1 0)))
                                  (plist-get data :records))))))"))
    (with-current-buffer (supertag-stream-agent-test--open '(:tag "prj"))
      (should (string-match-p "^  Project plan\\." (buffer-string)))
      (should (string-match-p "^  → Invoices" (buffer-string)))
      (should (string-match-p "^      Task detail\\." (buffer-string))))
    ;; With no agent, 0 body lines leaves the titles alone, without a stray `…'.
    (supertag-stream-agent-test--keep)
    (let ((supertag-view-stream-body-max-lines 0))
      (with-current-buffer (supertag-stream-agent-test--open '(:tag "prj"))
        (should (string-search "Hangji" (buffer-string)))
        (should-not (string-search "Project plan." (buffer-string)))
        (should-not (string-search "…" (buffer-string)))))))

;;; Keys and actions

(ert-deftest supertag-stream-agent-keys-work-on-a-fresh-open ()
  "The agent's keys are bound when the Stream first opens, before any refresh."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep supertag-stream-agent-test--contact)
    (with-current-buffer (supertag-stream-agent-test--open '(:tag "contact"))
      (should (eq (key-binding (kbd "R")) #'supertag-stream-agent-revise))
      (should (eq (key-binding (kbd "C")) #'supertag-stream-agent-show))
      (should (eq (key-binding (kbd "n")) #'supertag-view-stream-next-node))
      (should (functionp (key-binding (kbd "c"))))
      (should-not (eq (key-binding (kbd "c")) 'org-self-insert-command)))))

(ert-deftest supertag-stream-agent-buttons-run-the-commands ()
  "REVISE, CODE and REFRESH are buttons that run the same commands as the keys."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep supertag-stream-agent-test--contact)
    (with-current-buffer (supertag-stream-agent-test--open '(:tag "contact"))
      (goto-char (point-min))
      (should (search-forward "[ REVISE ]" nil t))
      (let (revised)
        (cl-letf (((symbol-function 'supertag-stream-agent-revise)
                   (lambda (name change) (setq revised (list name change))))
                  ((symbol-function 'read-string) (lambda (&rest _) "更紧凑")))
          (goto-char (match-beginning 0))
          (push-button))
        (should (equal revised '("contact" "更紧凑")))))))

(ert-deftest supertag-stream-agent-action-writes-org-and-keeps-the-row ()
  "A key writes the field on the node at point; the node moves, the cursor doesn't."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep supertag-stream-agent-test--contact)
    (let ((buffer (supertag-stream-agent-test--open '(:tag "contact"))))
      (with-current-buffer buffer
        (supertag-view-stream--select-node buffer "c-alice")
        (call-interactively (key-binding (kbd "c")))
        (should (equal (supertag-stream-agent-test--prop friends "Alice" "LAST_CONTACT")
                       (supertag-stream-agent-test--stamp 0)))
        (should (equal (supertag-stream-agent-test--groups buffer)
                       '(("该联系了" "Carol" "Frank" "Eve")
                         ("最近联系过" "Alice" "Bob"))))
        ;; Alice was third; the third row is now Eve.
        (should (equal (supertag-view-stream--current-node-id) "c-eve"))))))

(ert-deftest supertag-stream-agent-declaration-holds-in-every-file ()
  "A fixed value the agent declares is written the same in any file."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep supertag-stream-agent-test--contact)
    (let ((buffer (supertag-stream-agent-test--open '(:tag "contact"))))
      (with-current-buffer buffer
        (dolist (id '("c-alice" "c-frank"))
          (supertag-view-stream--select-node buffer id)
          (call-interactively (key-binding (kbd "1"))))))
    (should (equal (supertag-stream-agent-test--prop friends "Alice" "TIER") "核心"))
    (should (equal (supertag-stream-agent-test--prop work "Frank" "TIER") "核心"))))

(ert-deftest supertag-stream-agent-org-declaration-comes-first ()
  "Choices come from Org's KEY_ALL where the node lives, then the agent's."
  (supertag-stream-agent-test-with-vault
    (let ((ids (supertag-stream-agent--scope-ids '(:tag "contact")))
          (agent supertag-stream-agent-test--contact))
      (should (equal (supertag-stream-agent--choices agent "TIER" ids "c-frank")
                     '("核心" "亲密" "熟识" "远")))
      (should (equal (supertag-stream-agent--choices agent "TIER" ids "c-alice")
                     '("核心" "亲密" "熟识"))))))

(ert-deftest supertag-stream-agent-refuses-what-the-rules-forbid ()
  "Undeclared fields, values outside the choices, reserved names and bad keys are refused."
  (supertag-stream-agent-test-with-vault
    (dolist (case
             '((nil ((:key "x" :label "?" :field "MOOD" :value "calm")))
               ;; In use on a note, but not declared.
               (nil ((:key "x" :label "?" :field "LAST_CONTACT" :value today)))
               (((:name "TIER" :shape choice :values ("a" "b")))
                ((:key "x" :label "?" :field "TIER" :value "c")))
               (((:name "CATEGORY" :shape text)) nil)
               (((:name "MOOD" :shape choice)) nil)
               (((:name "TIER" :shape choice :values ("a")))
                ((:key "x" :label "?" :field "TIER" :value today)))
               (((:name "tier" :shape text)) nil)
               (((:name "NEXT" :shape date))
                ((:key "n" :label "?" :field "NEXT" :value today)))
               (((:name "NEXT" :shape date))
                ((:key "R" :label "?" :field "NEXT" :value today)))))
      (should (supertag-stream-agent-test--refusal (car case) (cadr case))))
    (should-not (supertag-stream-agent-test--refusal
                 '((:name "NEXT_CONTACT" :shape date))
                 '((:key "x" :label "?" :field "NEXT_CONTACT" :value today))))
    ;; A refused agent is not used.
    (supertag-stream-agent-test--keep
     (plist-put (copy-sequence supertag-stream-agent-test--contact) :actions
                '((:key "q" :label "?" :field "LAST_CONTACT" :value today))))
    (should-not (supertag-stream-agent-test--agent
                 (supertag-stream-agent-test--open '(:tag "contact"))))))

(ert-deftest supertag-stream-agent-days-is-called-either-way ()
  "(funcall \\='days …) reaches the helper as (funcall days …) does."
  (should (equal (supertag-stream-agent--call-helpers
                  "(funcall 'days a b) (funcall #'days a b) (apply 'days l) (funcall 'daysx a)")
                 "(funcall days a b) (funcall days a b) (apply days l) (funcall 'daysx a)")))

;;; Design

(defun supertag-stream-agent-test--reply (agent)
  "Return AGENT as the model would answer with it."
  (let ((print-length nil) (print-level nil))
    (format "(:fields %S\n :actions %S\n :view %s)"
            (plist-get agent :fields) (plist-get agent :actions) (plist-get agent :view))))

(ert-deftest supertag-stream-agent-design-sends-no-body-and-no-value ()
  "Designing sends the sentence, property names and six records; no body or private value."
  (supertag-stream-agent-test-with-vault
    (let (sent)
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (prompt system _callback) (setq sent (list prompt system)))))
        (supertag-stream-agent-design "contact" "记一笔就沉下去"))
      (should (string-match-p "记一笔就沉下去" (car sent)))
      (should (string-match-p "LAST_CONTACT" (car sent)))
      (should (string-match-p "\\* 动作要写的属性" (cadr sent)))
      (should (string-match-p "\\* 属性" (cadr sent)))
      (dolist (text sent)
        (should-not (string-match-p "555-01" text))
        (should-not (string-match-p "Body secret" text))))))

(ert-deftest supertag-stream-agent-design-self-checks-then-keeps ()
  "A working agent is shown what it draws; on OK it is kept and its Stream opens."
  (supertag-stream-agent-test-with-vault
    (let ((replies (list "(:view (lambda (data width) (delete-file \"x\")))"
                         (concat "说明。\n" (supertag-stream-agent-test--reply
                                            supertag-stream-agent-test--contact))
                         "OK"))
          prompts)
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (prompt _system callback)
                   (push prompt prompts)
                   (funcall callback (pop replies) 'completed))))
        (supertag-stream-agent-design "contact" "联系完记一笔"))
      (should (= 3 (length prompts)))
      (should (string-match-p "它被拒绝了：.*delete-file" (nth 1 prompts)))
      ;; The check shows groups, sizes and where a key moves a node; what it
      ;; adds to the design prompt carries no titles.
      (let ((check (substring (car prompts)
                              (string-search "用户真实数据画出的结果" (car prompts)))))
        (should (string-match-p "1\\. 该联系了：4 条" check))
        (should (string-match-p "按 c（刚联系过.*→ 第 2 组「最近联系过」" check))
        (should-not (string-match-p "Carol" check)))
      (should (eq 'kept (plist-get supertag-stream-agent--last :outcome)))
      (let ((kept (supertag-stream-agent--read (supertag-stream-agent--file "contact"))))
        (should (equal (plist-get kept :sentence) "联系完记一笔"))
        (should (equal (plist-get kept :fields)
                       (plist-get supertag-stream-agent-test--contact :fields))))
      (should (get-buffer "*Supertag Stream: contact*")))))

(ert-deftest supertag-stream-agent-self-check-correction-is-kept ()
  "When the check finds a fault, the corrected agent replaces the first."
  (supertag-stream-agent-test-with-vault
    (let* ((fixed (plist-put (copy-sequence supertag-stream-agent-test--contact) :view
                             (plist-get supertag-stream-agent-test--family :view)))
           (replies (list (supertag-stream-agent-test--reply supertag-stream-agent-test--contact)
                          (supertag-stream-agent-test--reply fixed)
                          "OK")))
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (_prompt _system callback)
                   (funcall callback (pop replies) 'completed))))
        (supertag-stream-agent-design "contact" "联系完记一笔"))
      (should (string-match-p
               "家人" (plist-get (supertag-stream-agent--read
                                  (supertag-stream-agent--file "contact"))
                                 :view))))))

(ert-deftest supertag-stream-agent-revision-keeps-only-the-users-words ()
  "A revision sees the agent and earlier changes; only the user's words are kept."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep
     (plist-put (copy-sequence supertag-stream-agent-test--contact) :revisions '("first")))
    (let (sent)
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (prompt _system callback)
                   (push prompt sent)
                   (funcall callback
                            (if (string-match-p "\\`[^\n]*你写的代理是" prompt) "OK"
                              (if (string-match-p "已经能运行" prompt) "OK"
                                (supertag-stream-agent-test--reply
                                 supertag-stream-agent-test--contact)))
                            'completed))))
        (supertag-stream-agent-revise "contact" "second"))
      (should (string-match-p "- first" (car (last sent))))
      (should (string-match-p "这次用户要求：second" (car (last sent))))
      (should (equal (plist-get (supertag-stream-agent--read
                                 (supertag-stream-agent--file "contact"))
                                :revisions)
                     '("first" "second"))))))

(ert-deftest supertag-stream-agent-revision-asks-to-declare-missing-fields ()
  "Revising an agent whose action writes an undeclared field asks the model to declare it."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep
     (plist-put (copy-sequence supertag-stream-agent-test--contact) :fields nil))
    (let (sent)
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (prompt _system callback)
                   (push prompt sent)
                   (funcall callback "x" 'error))))
        (supertag-stream-agent-revise "contact" "anything"))
      (should (string-match-p "字段 LAST_CONTACT、TIER 还没有在 :fields 里声明"
                              (car (last sent)))))))

(ert-deftest supertag-stream-agent-design-keeps-nothing-when-no-reply-passes ()
  "Three refused replies leave no agent file behind."
  (supertag-stream-agent-test-with-vault
    (let ((asked 0))
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (_prompt _system callback)
                   (cl-incf asked)
                   (funcall callback "(:view (lambda (data width) (kill-emacs)))"
                            'completed))))
        (supertag-stream-agent-design "contact" "x"))
      (should (= 3 asked))
      (should (eq 'none (plist-get supertag-stream-agent--last :outcome)))
      (should-not (file-exists-p (supertag-stream-agent--file "contact"))))))

;;; Rules a new agent must pass

(defconst supertag-stream-agent-test--partial
  "(lambda (data width)
  (list :groups (list (list :label \"一部分\"
                            :rows (mapcar (lambda (entry) (list :ref (plist-get entry :ref)))
                                          (cdr (plist-get data :records)))))))"
  "A view that leaves the first record out.")

(ert-deftest supertag-stream-agent-check-refuses-a-left-out-record ()
  "An agent whose view leaves a record out of every group is refused."
  (supertag-stream-agent-test-with-vault
    (should (string-match-p
             "1 条记录没有列进任何组"
             (supertag-stream-agent--check
              (plist-put (copy-sequence supertag-stream-agent-test--contact) :view
                         supertag-stream-agent-test--partial))))))

(ert-deftest supertag-stream-agent-check-refuses-a-view-that-breaks-on-one-note ()
  "An agent whose view fails when the Stream holds one note is refused."
  (supertag-stream-agent-test-with-vault
    (should (string-match-p
             "只剩 1 条笔记"
             (supertag-stream-agent--check
              (plist-put (copy-sequence supertag-stream-agent-test--contact) :view
                         "(lambda (data width)
  (let ((records (plist-get data :records)))
    ;; Breaks on one note: the half-way mark divides by zero.
    (list :header (format \"%d\" (/ 100 (1- (length records))))
          :groups (list (list :label \"全部\"
                              :rows (mapcar (lambda (entry) (list :ref (plist-get entry :ref)))
                                            records))))))"))))))

(ert-deftest supertag-stream-agent-check-refuses-a-key-that-breaks-the-view ()
  "An agent whose view fails once one of its keys has written is refused."
  (supertag-stream-agent-test-with-vault
    (should (string-match-p
             "按 1 写入 TIER=核心 之后画不出来"
             (supertag-stream-agent--check
              (plist-put (copy-sequence supertag-stream-agent-test--contact) :view
                         "(lambda (data width)
  (list :groups (list (list :label \"全部\"
                            :rows (mapcar (lambda (entry)
                                            (when (assoc \"TIER\" (plist-get entry :props))
                                              (car 1))
                                            (list :ref (plist-get entry :ref)))
                                          (plist-get data :records))))))"))))))

(ert-deftest supertag-stream-agent-design-rewrites-an-agent-that-leaves-records-out ()
  "A reply that leaves a record out is refused, and the model writes it again."
  (supertag-stream-agent-test-with-vault
    (let ((replies (list (supertag-stream-agent-test--reply
                          (plist-put (copy-sequence supertag-stream-agent-test--contact)
                                     :view supertag-stream-agent-test--partial))
                         (supertag-stream-agent-test--reply supertag-stream-agent-test--contact)
                         "OK"))
          prompts)
      (cl-letf (((symbol-function 'supertag-summary--ask)
                 (lambda (prompt _system callback)
                   (push prompt prompts)
                   (funcall callback (pop replies) 'completed))))
        (supertag-stream-agent-design "contact" "联系完记一笔"))
      (should (string-match-p "没有列进任何组" (nth 1 prompts)))
      (should (eq 'kept (plist-get supertag-stream-agent--last :outcome))))))

;;; Asking for a value

(ert-deftest supertag-stream-agent-ask-takes-what-the-user-types ()
  "An ask action writes a typed date, number or line; ask on a choice field is refused."
  (supertag-stream-agent-test-with-vault
    (let ((agent (list :name "contact" :scope '(:tag "contact")
                       :view supertag-stream-agent-test--view
                       :fields '((:name "NEXT_CONTACT" :shape date)
                                 (:name "MET" :shape number)
                                 (:name "NOTE" :shape text))
                       :actions '((:key "x" :label "下次联系" :field "NEXT_CONTACT" :value ask)
                                  (:key "j" :label "见过几次" :field "MET" :value ask)
                                  (:key "w" :label "写一句" :field "NOTE" :value ask)))))
      (should-not (supertag-stream-agent--refused agent))
      (supertag-stream-agent-test--keep agent)
      (let ((buffer (supertag-stream-agent-test--open '(:tag "contact"))))
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'org-read-date)
                     (lambda (&rest _) (encode-time 0 0 0 1 11 2026)))
                    ((symbol-function 'read-number) (lambda (&rest _) 3))
                    ((symbol-function 'read-string) (lambda (&rest _) " 喜欢爬山\n ")))
            (dolist (key '("x" "j" "w"))
              (supertag-view-stream--select-node buffer "c-alice")
              (call-interactively (key-binding (kbd key)))))))
      (should (equal (supertag-stream-agent-test--prop friends "Alice" "NEXT_CONTACT")
                     "[2026-11-01 Sun]"))
      (should (equal (supertag-stream-agent-test--prop friends "Alice" "MET") "3"))
      (should (equal (supertag-stream-agent-test--prop friends "Alice" "NOTE") "喜欢爬山")))
    (should (string-match-p
             "use choose"
             (supertag-stream-agent-test--refusal
              '((:name "TIER" :shape choice :values ("a")))
              '((:key "x" :label "?" :field "TIER" :value ask)))))))

(defun supertag-stream-agent-test--planning (file heading key)
  "Return Org's KEY, SCHEDULED or DEADLINE, under HEADING in FILE on disk."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (goto-char (point-min))
    (and (re-search-forward (concat "^\\* " heading) nil t)
         (org-entry-get nil key))))

(ert-deftest supertag-stream-agent-puts-a-note-on-a-day ()
  "SCHEDULED and DEADLINE are written undeclared, as Org dates, and the view sees them."
  (supertag-stream-agent-test-with-vault
    (let ((agent (list :name "contact" :scope '(:tag "contact")
                       :view "(lambda (data width)
  (list :groups (list (list :label \"有日期\"
                            :rows (mapcar (lambda (entry)
                                            (list :ref (plist-get entry :ref)
                                                  :line (or (plist-get entry :scheduled) \"\")))
                                          (seq-filter (lambda (entry) (plist-get entry :scheduled))
                                                      (plist-get data :records))))
                      (list :label \"其余\"
                            :rows (mapcar (lambda (entry) (list :ref (plist-get entry :ref) :line \"\"))
                                          (seq-remove (lambda (entry) (plist-get entry :scheduled))
                                                      (plist-get data :records)))))))"
                       :actions '((:key "s" :label "排到某天" :field "SCHEDULED" :value ask)
                                  (:key "d" :label "今天截止" :field "DEADLINE" :value today)))))
      (should-not (supertag-stream-agent--refused agent))
      (supertag-stream-agent-test--keep agent)
      (let ((buffer (supertag-stream-agent-test--open '(:tag "contact"))))
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'org-read-date)
                     (lambda (&rest _) (encode-time 0 0 0 1 11 2026))))
            (supertag-view-stream--select-node buffer "c-alice")
            (call-interactively (key-binding (kbd "s")))
            (supertag-view-stream--select-node buffer "c-bob")
            (call-interactively (key-binding (kbd "d")))))
        (should (equal (car (car (supertag-stream-agent-test--groups buffer))) "有日期"))
        (should (member "Alice" (car (supertag-stream-agent-test--groups buffer)))))
      (should (equal (supertag-stream-agent-test--planning friends "Alice" "SCHEDULED")
                     "<2026-11-01 Sun>"))
      (should (equal (supertag-stream-agent-test--planning friends "Bob" "DEADLINE")
                     (format-time-string "<%Y-%m-%d %a>")))
      ;; Org's own rule, not a property drawer entry.
      (should-not (supertag-stream-agent-test--prop friends "Alice" "SCHEDULED"))))
  (supertag-stream-agent-test-with-vault
    ;; A fixed value or a choice is not a date.
    (dolist (value '("2026-11-01" choose))
      (should (supertag-stream-agent-test--refusal
               nil `((:key "s" :label "?" :field "SCHEDULED" :value ,value)))))
    ;; Other Org properties stay forbidden.
    (should (supertag-stream-agent-test--refusal
             nil '((:key "t" :label "?" :field "TODO" :value "DONE"))))))

;;; Managing agents

(ert-deftest supertag-stream-agent-stop-start-and-delete ()
  "A stopped agent keeps its file and no longer draws; started, it draws again; deleted, it is gone."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep supertag-stream-agent-test--contact)
    (supertag-stream-agent-stop "contact")
    (should (plist-get (supertag-stream-agent--read (supertag-stream-agent--file "contact"))
                       :disabled))
    (should-not (supertag-stream-agent-test--agent
                 (supertag-stream-agent-test--open '(:tag "contact"))))
    (supertag-stream-agent-start "contact")
    (should-not (plist-member (supertag-stream-agent--read
                               (supertag-stream-agent--file "contact"))
                              :disabled))
    (should (equal (supertag-stream-agent-test--agent
                    (supertag-stream-agent-test--open '(:tag "contact")))
                   "contact"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (supertag-stream-agent-delete "contact"))
    (should-not (file-exists-p (supertag-stream-agent--file "contact")))
    (should-not (supertag-stream-agent-test--agent
                 (supertag-stream-agent-test--open '(:tag "contact"))))))

(ert-deftest supertag-stream-agent-list-shows-every-agent-and-why-one-fails ()
  "Every kept agent is listed, a refused or unreadable one with why."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep
     supertag-stream-agent-test--contact
     (plist-put (copy-sequence supertag-stream-agent-test--family) :actions
                '((:key "n" :label "?" :field "NOPE" :value today))))
    (with-temp-file (supertag-stream-agent--file "broken") (insert "(:name"))
    (let ((entries (supertag-stream-agent--all)))
      (should (equal (mapcar (lambda (entry) (plist-get (car entry) :name)) entries)
                     '("broken" "contact" "family")))
      (should (equal (mapcar #'supertag-stream-agent--state entries)
                     '("broken" "active" "broken")))
      (should (equal (cdr (car entries)) "File cannot be read")))))

(ert-deftest supertag-stream-agent-open-offers-agents-in-use ()
  "Open lists only working, started agents and shows the Stream of the scope."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep
     supertag-stream-agent-test--contact
     (plist-put (copy-sequence supertag-stream-agent-test--family) :actions
                '((:key "n" :label "?" :field "NOPE" :value today))))
    (with-temp-file (supertag-stream-agent--file "broken") (insert "(:name"))
    (let (offered buffers)
      (unwind-protect
          (save-window-excursion
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt table &rest _)
                         (setq offered (mapcar #'car table))
                         "contact")))
              (push (call-interactively #'supertag-stream-agent-open) buffers))
            (should (equal offered '("contact")))
            (with-current-buffer (car buffers)
              (should (equal (plist-get supertag-view--instance :input)
                             '(:tag "contact"))))
            ;; Opened again, the same Stream comes back.
            (should (eq (supertag-stream-agent-open "contact") (car buffers)))
            ;; A query scope opens the stream of that query.
            (push (supertag-stream-agent--show-stream '(:query (tag "contact")))
                  buffers)
            (with-current-buffer (car buffers)
              (should (equal (plist-get supertag-view--instance :input)
                             '(:query (tag "contact")))))
            (supertag-stream-agent-stop "contact")
            (should-error (call-interactively #'supertag-stream-agent-open)
                          :type 'user-error))
        (mapc (lambda (buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
              buffers)))))

(provide 'stream-agent-test)

;;; stream-agent-test.el ends here
