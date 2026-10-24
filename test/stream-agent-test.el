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
        (should (string-search "FIELDS / LAST_CONTACT 日期  TIER 核心, 亲密, 熟识"
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
                   '("其余" "Bob")))))

(ert-deftest supertag-stream-agent-that-fails-still-shows-every-node ()
  "A view that fails says why above all the nodes, and the agent's keys remain."
  (supertag-stream-agent-test-with-vault
    (supertag-stream-agent-test--keep
     (plist-put (copy-sequence supertag-stream-agent-test--contact) :view
                "(lambda (data width) (car 1))"))
    (let ((buffer (supertag-stream-agent-test--open '(:tag "contact"))))
      (should (equal (length (cdar (supertag-stream-agent-test--groups buffer))) 5))
      (with-current-buffer buffer
        (should (string-search "画不出来" (buffer-string)))
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

(provide 'stream-agent-test)

;;; stream-agent-test.el ends here
