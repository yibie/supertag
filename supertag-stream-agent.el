;;; supertag-stream-agent.el --- A Stream laid out for its kind of note -*- lexical-binding: t; -*-

;;; Commentary:

;; A Stream agent makes the Stream of one tag fit what the user keeps there.
;; The user says one sentence; a model writes the agent once; from then on it
;; runs without a model, every time the Stream is drawn.
;;
;; An agent is a data file, stream-agents/NAME.eld beside the notes:
;;
;;   (:name "contact"
;;    :sentence "the sentence it was made from"
;;    :revisions ("each change the user asked for" ...)
;;    :scope (:tag TAG-ID)
;;    :fields ((:name "LAST_CONTACT" :shape date)
;;             (:name "TIER" :shape choice :values ("核心" "亲密" "熟识")))
;;    :view "(lambda (data width) ...)"
;;    :actions ((:key "c" :label "..." :field "LAST_CONTACT" :value today)
;;              (:key "1" :label "..." :field "TIER" :value "核心")))
;;
;; Who decides what:
;;
;; - Scope.  An agent applies to every Stream whose nodes all lie in its
;;   scope, so a narrowed Stream and a query Stream over the same notes get
;;   it without any rule of inheritance.  The smallest matching scope wins.
;; - View.  Model code, run in the child Emacs of `supertag-summary-runner'
;;   with its whitelist.  It returns data only: groups, their order and one
;;   line per node.  Stream draws the titles, bodies, selection and its own
;;   keys.  Nodes the view leaves out are drawn in a last group: an agent can
;;   reorder, never hide.
;; - Fields.  Properties are made for the user's need, so the agent declares
;;   the ones it writes.  The declaration is the field's rule for every node
;;   in scope, whichever file it lives in; Org has no per-tag rule.
;; - Actions.  Data, not code: a key writes one declared field on the node
;;   at point.  The value is today, the creation day, a fixed value or one
;;   the user picks; the values come from Org's KEY_ALL where the node lives,
;;   then the agent's declaration, then the values already in use.
;;
;; Design and revision show the model what its agent draws on the real
;; records, without titles or values, before the agent is kept: logic that
;; runs but does not do what was asked is the usual failure.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'supertag-summary)
(require 'supertag-view-stream)

(defgroup supertag-stream-agent nil
  "Streams laid out by an agent a model writes from one sentence."
  :group 'supertag)

(defcustom supertag-stream-agent-directory nil
  "Directory where Stream agents are kept, one NAME.eld each.
Nil means `stream-agents/' under the sync directory, beside summary
panels, or under `supertag-data-directory' when no sync directory is set."
  :type '(choice (const :tag "Beside the notes" nil) directory)
  :group 'supertag-stream-agent)

(defcustom supertag-stream-agent-width 100
  "Width an agent's lines are fitted to."
  :type 'integer
  :group 'supertag-stream-agent)

(defcustom supertag-stream-agent-self-check-rounds 2
  "How many times a newly written agent is shown what it draws."
  :type 'integer
  :group 'supertag-stream-agent)

(defconst supertag-stream-agent--own-keys '("R" "C")
  "Keys every agent's Stream gives to revising and showing the agent.")

(defconst supertag-stream-agent--values '(today created choose)
  "What an action may write besides a fixed string.")

(defconst supertag-stream-agent--shapes '(date number text choice)
  "Shapes a declared field may have.")

(defvar supertag-stream-agent--last nil
  "The outcome of the last design or revision, kept for inspection.")

;;; Files

(defun supertag-stream-agent--directory ()
  "Return the directory agents are kept in."
  (file-name-as-directory
   (expand-file-name
    (or supertag-stream-agent-directory
        (expand-file-name
         "stream-agents"
         (or (car (supertag-sync--effective-directories))
             supertag-data-directory))))))

(defun supertag-stream-agent--file (name)
  "Return the file of the agent NAME."
  (expand-file-name (concat name ".eld") (supertag-stream-agent--directory)))

(defun supertag-stream-agent--read (file)
  "Return the agent kept in FILE, or nil."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents file)
      (read (current-buffer)))))

(defun supertag-stream-agent--write (agent)
  "Keep AGENT in its file and return it."
  (let ((file (supertag-stream-agent--file (plist-get agent :name))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (let ((print-length nil) (print-level nil))
        (prin1 agent (current-buffer))
        (insert "\n"))))
  agent)

;;; Rules

(defun supertag-stream-agent--reserved-keys ()
  "Return the keys an action may not take."
  (let (keys)
    (map-keymap (lambda (event _)
                  (when (characterp event) (push (string event) keys)))
                supertag-view-stream-mode-map)
    (append supertag-stream-agent--own-keys keys)))

(defun supertag-stream-agent--reserved-field-p (name)
  "Return non-nil when NAME is a property Org or Supertag owns."
  (let ((name (upcase name)))
    (or (member name '("ID" "CREATED" "CATEGORY" "VISIBILITY" "COLUMNS"
                       "LOGGING" "ARCHIVE" "STYLE" "ORDERED" "NOBLOCKING"))
        (member name org-special-properties)
        (string-suffix-p "_ALL" name))))

(defun supertag-stream-agent--scope-ids (scope)
  "Return the node IDs SCOPE covers, resolving a tag the way Stream does."
  (pcase scope
    (`(:tag ,tag) (supertag-view-api-nodes-by-tag tag t))
    (`(:query ,query) (supertag-query-node-ids query))
    (_ nil)))

(defun supertag-stream-agent--declared (agent field)
  "Return AGENT's declaration of FIELD, or nil."
  (seq-find (lambda (spec) (equal (plist-get spec :name) field))
            (plist-get agent :fields)))

(defun supertag-stream-agent--field-values (field ids)
  "Return the distinct values FIELD has on the nodes IDS."
  (let ((key (intern (concat ":" field)))
        values)
    (dolist (node (supertag-view-api-get-entities :nodes ids))
      (when-let* ((value (plist-get (plist-get node :properties) key)))
        (cl-pushnew (format "%s" value) values :test #'equal)))
    (nreverse values)))

(defun supertag-stream-agent--org-allowed (id field)
  "Return the values Org declares for FIELD where node ID lives, or nil."
  (when-let* ((marker (ignore-errors (supertag-node-location-find id))))
    (prog1 (with-current-buffer (marker-buffer marker)
             (org-with-wide-buffer
              (goto-char marker)
              (mapcar #'substring-no-properties
                      (let ((org-property-allowed-value-functions nil))
                        (ignore-errors
                          (org-property-get-allowed-values (point) field))))))
      (set-marker marker nil))))

(defun supertag-stream-agent--choices (agent field ids &optional id)
  "Return the values FIELD may take on node ID among IDS.
Org's declaration where ID lives comes first, then AGENT's, then the values
the nodes IDS already use."
  (delete-dups
   (append (and id (supertag-stream-agent--org-allowed id field))
           (copy-sequence (plist-get (supertag-stream-agent--declared agent field)
                                     :values))
           (supertag-stream-agent--field-values field ids))))

(defun supertag-stream-agent--field-refused (spec)
  "Return why the field declaration SPEC is refused, or nil."
  (let ((name (plist-get spec :name))
        (shape (plist-get spec :shape))
        (values (plist-get spec :values)))
    (cond
     ((not (and (stringp name)
                (let ((case-fold-search nil))
                  (string-match-p "\\`[A-Z][A-Z0-9_]*\\'" name))))
      (format "字段名 %S 要用大写字母、数字和下划线" name))
     ((supertag-stream-agent--reserved-field-p name)
      (format "字段 %s 归 Org 或 Supertag 管，换一个名字" name))
     ((not (memq shape supertag-stream-agent--shapes))
      (format "字段 %s 的 :shape %S 不在 date number text choice 之中" name shape))
     ((and (eq shape 'choice)
           (not (and (consp values) (seq-every-p #'stringp values))))
      (format "字段 %s 是 choice，要在 :values 里列出可选的值" name)))))

(defun supertag-stream-agent--action-refused (agent action ids reserved)
  "Return why ACTION of AGENT over IDS is refused, or nil.
RESERVED are the keys an action may not take."
  (let* ((key (plist-get action :key))
         (field (plist-get action :field))
         (value (plist-get action :value))
         (spec (and (stringp field) (supertag-stream-agent--declared agent field))))
    (cond
     ((not (and (stringp key) (= (length key) 1)))
      (format "动作的键 %S 必须是一个字符" key))
     ((member key reserved) (format "动作的键 %s 已被 Stream 占用" key))
     ((not (stringp field)) (format "动作的字段 %S 必须是字符串" field))
     ((supertag-stream-agent--reserved-field-p field)
      (format "字段 %s 归 Org 或 Supertag 管，动作不能写它" field))
     ((not (or spec (supertag-stream-agent--field-values field ids)))
      (format "字段 %s 在范围内没人用过，也没有在 :fields 里声明" field))
     ((not (or (stringp value) (memq value supertag-stream-agent--values)))
      (format "动作的值 %S 只能是 today、created、choose 或一个字符串" value))
     ((and (memq value '(today created)) spec
           (not (eq (plist-get spec :shape) 'date)))
      (format "字段 %s 不是 date，不能写 %s" field value))
     ((and (eq value 'choose)
           (null (supertag-stream-agent--choices agent field ids)))
      (format "字段 %s 没有可选的值：在 :fields 里把它声明成 choice 并给出 :values"
              field))
     ((and (stringp value)
           (not (member value (supertag-stream-agent--choices agent field ids))))
      (format "动作要写的值 %S 不在字段 %s 的可选值里" value field)))))

(defun supertag-stream-agent--refused (agent)
  "Return why AGENT may not be used, or nil."
  (let ((ids (supertag-stream-agent--scope-ids (plist-get agent :scope)))
        (reserved (supertag-stream-agent--reserved-keys)))
    (cond
     ((not (stringp (plist-get agent :name))) "没有 :name")
     ((not (stringp (plist-get agent :view))) "没有 :view")
     ((null ids) (format "范围 %S 里没有节点" (plist-get agent :scope)))
     ((seq-some #'supertag-stream-agent--field-refused (plist-get agent :fields)))
     (t (seq-some (lambda (action)
                    (supertag-stream-agent--action-refused agent action ids reserved))
                  (plist-get agent :actions))))))

;;; Agents and matching

(defun supertag-stream-agent--agents ()
  "Return the kept agents that may be used, by name."
  (let ((directory (supertag-stream-agent--directory))
        agents)
    (dolist (file (and (file-directory-p directory)
                       (directory-files directory t "\\.eld\\'")))
      (let ((agent (supertag-stream-agent--read file)))
        (when (and agent (not (supertag-stream-agent--refused agent)))
          (push agent agents))))
    (sort agents (lambda (a b) (string< (plist-get a :name) (plist-get b :name))))))

(defun supertag-stream-agent--match (ids)
  "Return the agent for a Stream of IDS, or nil.
The agent's scope must hold every ID; the smallest such scope wins."
  (when ids
    (let (best best-size)
      (dolist (agent (supertag-stream-agent--agents))
        (let* ((scope (supertag-stream-agent--scope-ids (plist-get agent :scope)))
               (table (make-hash-table :test 'equal :size (length scope))))
          (dolist (id scope) (puthash id t table))
          (when (and (cl-every (lambda (id) (gethash id table)) ids)
                     (or (null best-size) (< (length scope) best-size)))
            (setq best agent best-size (length scope)))))
      best)))

;;; Records and the view

(defconst supertag-stream-agent--helpers
  '((days . (lambda (from to)
              "Whole days from FROM to TO, both \"YYYY-MM-DD\"; nil if either is not."
              (when (and (stringp from) (stringp to)
                         (= (length from) 10) (= (length to) 10))
                (round (/ (- (float-time
                              (encode-time 0 0 12
                                           (string-to-number (substring to 8 10))
                                           (string-to-number (substring to 5 7))
                                           (string-to-number (substring to 0 4))))
                             (float-time
                              (encode-time 0 0 12
                                           (string-to-number (substring from 8 10))
                                           (string-to-number (substring from 5 7))
                                           (string-to-number (substring from 0 4)))))
                          86400))))))
  "Functions bound around every view.
Date arithmetic is done once here, at noon, so a time zone or daylight
saving change cannot shift a day.")

(defun supertag-stream-agent--records (nodes)
  "Return (INDEX . DATA) for NODES.
DATA has the record shape summary uses, plus :touched, the day a node last
changed.  INDEX maps each record's :ref to its node."
  (let ((index (make-hash-table :test 'equal))
        (number 0))
    (cons index
          (list
           :today (format-time-string "%Y-%m-%d")
           :total (length nodes)
           :records
           (mapcar
            (lambda (node)
              (let ((ref (format "n%d" (cl-incf number)))
                    (day (supertag-summary--node-day node)))
                (puthash ref node index)
                (list :ref ref
                      :title (supertag-summary--node-title node)
                      :todo (plist-get node :todo)
                      :tags (mapcar #'supertag-tag--name (plist-get node :tags))
                      :day (and day (= (length day) 10) day)
                      :scheduled (supertag-summary--date (plist-get node :scheduled))
                      :deadline (supertag-summary--date (plist-get node :deadline))
                      :file (file-name-nondirectory (or (plist-get node :file) ""))
                      :props (supertag-summary--props node)
                      :touched (when-let* ((time (plist-get node :modified-at)))
                                 (format-time-string "%Y-%m-%d" time)))))
            nodes)))))

(defun supertag-stream-agent--call-helpers (code)
  "Return CODE with a quoted helper name after funcall or apply unquoted.
Helpers are bound as variables, so (funcall \\='days ...) would look up a
global function that does not exist.  Models write it that way often."
  (let ((case-fold-search nil))
    (dolist (name (mapcar #'car supertag-stream-agent--helpers) code)
      (setq code (replace-regexp-in-string
                  (format "(\\(funcall\\|apply\\)[ \t\n]+\\(?:'\\|#'\\)\\(%s\\)\\_>"
                          (regexp-quote (symbol-name name)))
                  "(\\1 \\2" code)))))

(defun supertag-stream-agent--run (code data width)
  "Run view CODE on DATA at WIDTH in the child Emacs.
Return (:ok FRAME) or (:failed REASON)."
  (setq code (supertag-stream-agent--call-helpers code))
  (if-let* ((why (supertag-summary--unbalanced code)))
      (list :failed why)
    (let ((files (mapcar (lambda (_) (make-temp-file "supertag-stream-agent" nil ".el"))
                         '(code data helpers out))))
      (unwind-protect
          (pcase-let ((`(,code-file ,data-file ,helpers-file ,out-file) files)
                      (print-length nil) (print-level nil)
                      (coding-system-for-write 'utf-8))
            (with-temp-file code-file (insert code))
            (with-temp-file data-file (prin1 data (current-buffer)))
            (with-temp-file helpers-file
              (prin1 supertag-stream-agent--helpers (current-buffer)))
            (pcase (supertag-summary--run-child
                    (list code-file data-file out-file (number-to-string width)
                          helpers-file))
              (`(0 . ,_) (list :ok (supertag-stream-agent--read out-file)))
              (`(nil . ,_) (list :failed "运行超时"))
              (`(,_ . ,output)
               (list :failed (string-remove-prefix "ERROR: " output)))))
        (dolist (file files)
          (when (file-exists-p file) (delete-file file)))))))

(defun supertag-stream-agent--line (value width)
  "Return VALUE as one line no wider than WIDTH, or nil."
  (when (stringp value)
    (let ((line (string-trim (car (split-string value "\n")))))
      (unless (string-empty-p line)
        (truncate-string-to-width line width nil nil "…")))))

(defun supertag-stream-agent--frame (frame index nodes width)
  "Check FRAME against INDEX and return (:header :notes :groups :omitted).
Groups are (LABEL (NODE . LINE) ...).  NODES missing from FRAME go to a
last group, so none is hidden."
  (unless (and (listp frame) (listp (plist-get frame :groups)))
    (error "view 必须返回 (:header … :notes … :groups (…))"))
  (let ((seen (make-hash-table :test 'equal))
        groups)
    (dolist (group (plist-get frame :groups))
      (let (rows)
        (dolist (row (plist-get group :rows))
          (let ((node (gethash (plist-get row :ref) index)))
            (unless node (error "行引用了不存在的记录 %S" (plist-get row :ref)))
            (unless (gethash (plist-get node :id) seen)
              (puthash (plist-get node :id) t seen)
              (push (cons node (supertag-stream-agent--line (plist-get row :line) width))
                    rows))))
        (when rows
          (push (cons (or (supertag-stream-agent--line (plist-get group :label) width) "")
                      (nreverse rows))
                groups))))
    (let ((omitted (cl-remove-if (lambda (node) (gethash (plist-get node :id) seen))
                                 nodes)))
      (when omitted
        (push (cons "其余" (mapcar #'list omitted)) groups))
      (list :header (supertag-stream-agent--line (plist-get frame :header) width)
            :notes (supertag-stream-agent--line (plist-get frame :notes) width)
            :groups (nreverse groups)
            :omitted (length omitted)))))

(defun supertag-stream-agent--draw (agent nodes &optional width)
  "Return AGENT's drawing of NODES at WIDTH, or (:failed REASON)."
  (let ((width (or width supertag-stream-agent-width)))
    (pcase-let ((`(,index . ,data) (supertag-stream-agent--records nodes)))
      (pcase (supertag-stream-agent--run (plist-get agent :view) data width)
        (`(:ok ,frame)
         (condition-case err
             (supertag-stream-agent--frame frame index nodes width)
           (error (list :failed (error-message-string err)))))
        (failed failed)))))

;;; Drawing in Stream

(supertag-widget-register 'supertag-stream-agent-gap
  (lambda (_props) (insert "  ")))

(defun supertag-stream-agent--fields-line (agent)
  "Return the fields AGENT declares as one line, or nil."
  (when-let* ((fields (plist-get agent :fields)))
    (concat "FIELDS / "
            (mapconcat (lambda (spec)
                         (format "%s %s" (plist-get spec :name)
                                 (pcase (plist-get spec :shape)
                                   ('choice (string-join (plist-get spec :values) ", "))
                                   ('date "日期") ('number "数字") (_ "文本"))))
                       fields "  "))))

(defun supertag-stream-agent--buttons (agent)
  "Return the REVISE, CODE and REFRESH row of AGENT.
Buttons for the mouse and keys for the keyboard run the same commands."
  (let ((name (plist-get agent :name)))
    (list :type :stack :spacing 0
          :children
          (append
           (mapcan (lambda (button)
                     (list (list :type :button :label (format "[ %s ]" (car button))
                                 :action (cdr button) :help-echo (car button)
                                 :newline nil)
                           (list :type :supertag-stream-agent-gap)))
                   (list (cons "REVISE"
                               (lambda (&rest _)
                                 (supertag-stream-agent-revise
                                  name (read-string (format "%s 要怎么改：" name)))))
                         (cons "CODE" (lambda (&rest _) (supertag-stream-agent-show name)))
                         (cons "REFRESH" (lambda (&rest _) (supertag-view-refresh)))))
           (list (list :type :text
                       :content (propertize "R revise  C code  g refresh"
                                            'font-lock-face
                                            'supertag-view-stream-line-face)))))))

(defun supertag-stream-agent--header (agent drawing failed)
  "Return the header widgets of AGENT's Stream.
DRAWING is what the view returned; FAILED, when non-nil, why it could not draw."
  (list
   (list :type :text
         :content
         (string-join
          (delq nil
                (list (propertize (format " AGENT / %s " (upcase (plist-get agent :name)))
                                  'font-lock-face 'supertag-view-stream-date-face)
                      (and failed (format "画不出来：%s" failed))
                      (plist-get drawing :header)
                      (plist-get drawing :notes)
                      (supertag-stream-agent--fields-line agent)
                      (when-let* ((actions (plist-get agent :actions)))
                        (mapconcat (lambda (action)
                                     (format "[%s] %s" (plist-get action :key)
                                             (plist-get action :label)))
                                   actions "  "))))
          "\n"))
   (supertag-stream-agent--buttons agent)))

(defun supertag-stream-agent--keymap (agent)
  "Return the Stream keymap with AGENT's keys."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map supertag-view-stream-mode-map)
    (define-key map (kbd "R") #'supertag-stream-agent-revise)
    (define-key map (kbd "C") #'supertag-stream-agent-show)
    (dolist (action (plist-get agent :actions))
      (let ((action action))
        (define-key map (kbd (plist-get action :key))
                    (lambda ()
                      (interactive)
                      (supertag-stream-agent--act action)))))
    map))

(defun supertag-stream-agent-arrange (input state)
  "Arrange the Stream STATE built from INPUT by the agent whose scope holds it.
Return STATE unchanged when no agent matches.  This is
`supertag-view-stream-arrange-function'."
  (let ((agent (supertag-stream-agent--match (supertag-view-stream--input-ids input))))
    (if (not agent)
        state
      (let* ((nodes (plist-get state :nodes))
             (drawing (supertag-stream-agent--draw agent nodes))
             (failed (plist-get drawing :failed))
             (groups (if failed
                         (list (cons "其余" (mapcar #'list nodes)))
                       (plist-get drawing :groups))))
        (append (list :agent agent
                      :arrangement (list :header (supertag-stream-agent--header
                                                  agent drawing failed)
                                         :groups groups
                                         :keymap (supertag-stream-agent--keymap agent)))
                (plist-put (copy-sequence state) :nodes
                           (mapcan (lambda (group) (mapcar #'car (cdr group)))
                                   groups)))))))

;;; Actions

(defun supertag-stream-agent--current ()
  "Return the agent that drew this Stream, or nil."
  (and (boundp 'supertag-view--instance)
       (plist-get (plist-get supertag-view--instance :state) :agent)))

(defun supertag-stream-agent--value (agent action node ids)
  "Return the text ACTION of AGENT writes on NODE; IDS is the agent's scope."
  (let* ((field (plist-get action :field))
         (existing (supertag-stream-agent--field-values field ids))
         ;; Follow the field's existing values; a new field gets an Org date.
         (stamped (or (null existing)
                      (seq-some (lambda (value) (string-prefix-p "[" value)) existing)))
         (day (lambda (time)
                (format-time-string (if stamped "[%Y-%m-%d %a]" "%Y-%m-%d") time))))
    (pcase (plist-get action :value)
      ('today (funcall day nil))
      ('created (funcall day (or (supertag-view-stream--created-time node)
                                 (user-error "This node has no creation time"))))
      ('choose (completing-read
                (format "%s: " field)
                (supertag-stream-agent--choices agent field ids (plist-get node :id))
                nil t))
      ((and (pred stringp) value) value))))

(defun supertag-stream-agent--act (action)
  "Do ACTION on the node at point and keep the cursor on the same row.
The node may move to another group; the cursor does not follow it."
  (let* ((main (current-buffer))
         (agent (or (supertag-stream-agent--current) (user-error "No agent here")))
         (id (or (supertag-view-stream--current-node-id) (user-error "No node at point")))
         (row (cl-position id (supertag-view-stream--node-ids main) :test #'equal)))
    (supertag-service-org-set-property
     id (plist-get action :field)
     (supertag-stream-agent--value
      agent action (supertag-node-get id)
      (supertag-stream-agent--scope-ids (plist-get agent :scope))))
    (supertag-view-refresh)
    (when-let* ((ids (supertag-view-stream--node-ids main)))
      (supertag-view-stream--select-node main (nth (min (or row 0) (1- (length ids))) ids)))))

;;; Showing an agent

(defun supertag-stream-agent--read-name ()
  "Return the agent of this Stream, or one the user picks."
  (or (plist-get (supertag-stream-agent--current) :name)
      (completing-read "Agent: "
                       (mapcar (lambda (agent) (plist-get agent :name))
                               (supertag-stream-agent--agents))
                       nil t)))

(defun supertag-stream-agent-show (name)
  "Show the agent NAME: its sentence, revisions, fields, actions and view."
  (interactive (list (supertag-stream-agent--read-name)))
  (let ((agent (or (supertag-stream-agent--read (supertag-stream-agent--file name))
                   (user-error "No agent named %s" name)))
        (print-length nil) (print-level nil))
    (with-current-buffer (get-buffer-create (format "*Supertag Stream Agent: %s*" name))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format ";; %s\n" (plist-get agent :sentence)))
        (dolist (change (plist-get agent :revisions))
          (insert (format ";; 修改：%s\n" change)))
        (insert "\n:fields\n")
        (pp (plist-get agent :fields) (current-buffer))
        (insert "\n:actions\n")
        (pp (plist-get agent :actions) (current-buffer))
        (insert "\n:view\n")
        (pp (car (read-from-string (plist-get agent :view))) (current-buffer)))
      (emacs-lisp-mode)
      (goto-char (point-min))
      (view-mode 1)
      (pop-to-buffer (current-buffer)))))

(defun supertag-stream-agent--refresh-streams ()
  "Redraw every open Stream, so a new or changed agent shows."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'supertag-view-stream-mode)
        (supertag-view-refresh)))))

(defun supertag-stream-agent--show-stream (tag)
  "Show a Stream of TAG, opening one when none is open."
  (if-let* ((open (seq-find
                   (lambda (buffer)
                     (with-current-buffer buffer
                       (and (derived-mode-p 'supertag-view-stream-mode)
                            (equal (plist-get (plist-get supertag-view--instance :input)
                                              :tag)
                                   tag))))
                   (buffer-list))))
      (pop-to-buffer open)
    (supertag-view-stream--open (list :tag tag))))

;;; Design

(defconst supertag-stream-agent--system
  (concat
   "你为用户的一条 Stream 写一个嵌入式代理。Stream 是一列笔记。\
Stream 自己画每条笔记的标题、标签和正文，自己负责选中、打开和编辑；\
代理只决定：怎么分组、组内谁在前、每条笔记标题后面加一句什么，以及用户能按哪些键做什么。

只输出一个表达式，不要解释，不要代码块标记：

(:fields (字段 …)
 :actions (动作 …)
 :view (lambda (data width) …))

* data
(:today \"YYYY-MM-DD\" :total 条数 :records (记录 …))
每条记录：(:ref \"n1\" :title 标题 :todo 状态或nil :tags (标签名 …) :day \"YYYY-MM-DD\"（这条笔记属于哪天，优先用它写的 CREATED）\
 :scheduled :deadline（\"YYYY-MM-DD\" 或 nil） :file 文件名\
 :props ((\"属性名\" . 值) …) :touched \"YYYY-MM-DD\"（最后一次改动）)

* view 返回
(:header \"一行概况\" :notes \"一句说明或 nil\"\
 :groups ((:label \"组名\" :rows ((:ref \"n1\" :line \"一句注释\") …)) …))
- 每个 :ref 最多出现一次。:line 是一行，不超过 width 个字符；标题 Stream 已经画了，不要重复标题。
- 页面是 Org 的缓冲区，/ * _ = ~ + 会被当成 Org 的标记。分隔几项用逗号（,）或 ·，不要用这些符号。
- 你没列出的记录，Stream 会原样放进\"其余\"。\"其余\"永远排在你所有组之后，只是兜底，不是分组的手段：\
用户的话要求排在某处的记录（包括\"沉到最后\"的），必须自己列进组里。
- 用户的话里有做不到的部分，就在 :notes 里如实说一句，不要声称做到了，也不要悄悄删掉。

* 日期
算两个日期相差几天，一律用 (funcall days 从 到)，两个参数都是 \"YYYY-MM-DD\"，返回整数天，参数不是日期时返回 nil。\
不要自己用 float-time 或 86400 算天数。

* 能用的函数
只能用这些：" (mapconcat #'symbol-name supertag-summary-runner-allowed " ")
   "，以及 seq- 开头的函数。不能读写文件、不能联网、不能调用模型。\
变量名不要和函数同名（例如不要用 record、list、string、length、format 当变量名）。

" supertag-summary-property-guide "

* 动作要写的属性
- 用户的话需要记下什么，就为它设计一个属性。动作要写的属性都在 :fields 里声明：\
(:name \"名字\" :shape 形状)，形状是 date、number、text、choice 之一。\
choice 还要给出可选值：(:name \"TIER\" :shape choice :values (\"核心\" \"亲密\" \"熟识\"))。
- 这条声明就是这个属性在整个标签下的规则，不管笔记在哪个文件里，都按它来写。
- 名字用大写字母、数字和下划线，说清是什么（LAST_CONTACT，不要 LC）。\
已有的属性意思相同就用它，不必声明，除非你要给它定可选值。
- 不能用 TODO、SCHEDULED、DEADLINE、PRIORITY、TAGS 这些 Org 自己的属性，也不能用 _ALL 结尾的名字。
- 日期由 Stream 按 Org 的格式写入（[2026-10-24 Sat]），读的时候 data 里已经是 \"YYYY-MM-DD\"。

* 动作
每个动作：(:key \"c\" :label \"按钮说明\" :field \"属性名\" :value 值)
- :key 是一个字符，不能是 n p e v f u m g q R C（Stream 已经用了）。
- :value 是 today（写今天，只用于 date）、created（写这条笔记的创建日期，只用于 date）、\
choose（让用户从可选值里选一个），或者一个字符串（直接写这个值，必须是这个属性的可选值或已有的值）。
- 一组固定的选择（比如四个层级）可以每个值一个键，也可以一个键加 choose。
- 动作只会把这一个属性写到用户当前选中的那条笔记上。不能新建笔记、不能写别的东西、不能定时运行。
- 动作写完后 Stream 会重画，光标停在原来的行位置。没有需要的动作就写 :actions nil。")
  "System prompt asking for a Stream agent.")

(defun supertag-stream-agent--prompt (tag sentence)
  "Return the prompt asking for the agent of TAG from SENTENCE.
It names the properties in scope and shows six records, whose non-date
property values read …; no body is sent."
  (let* ((ids (supertag-view-api-nodes-by-tag tag t))
         (records (plist-get (cdr (supertag-stream-agent--records
                                   (supertag-view-api-get-entities :nodes ids)))
                             :records))
         (print-length nil) (print-level nil))
    (format "用户的话：%s\n\n这条 Stream 是 #%s 下的 %d 条笔记。\n\n已有的属性：\n%s\n\n今天是 %s。前 6 条记录（非日期的属性值换成了 …）：\n%s"
            sentence (supertag-tag--name tag) (length ids)
            (or (supertag-summary-property-lines records) "（没有）")
            (format-time-string "%Y-%m-%d")
            (mapconcat (lambda (entry)
                         (prin1-to-string (supertag-summary-property-mask entry)))
                       (seq-take records 6) "\n"))))

(defun supertag-stream-agent--parse (response)
  "Return (:ok FIELDS ACTIONS VIEW-CODE) from RESPONSE, or (:failed REASON)."
  (let ((text (supertag-summary--strip-fence response)))
    ;; A model often explains before the expression; start at it.
    (when (string-match "^(:" text)
      (setq text (substring text (match-beginning 0))))
    (if-let* ((why (supertag-summary--unbalanced text)))
        (list :failed why)
      (condition-case err
          (let ((form (car (read-from-string text))))
            (cond
             ((not (and (consp form) (keywordp (car form))))
              (list :failed "输出必须是一个 (:fields … :actions … :view (lambda (data width) …)) 表达式"))
             ((not (eq (car-safe (plist-get form :view)) 'lambda))
              (list :failed ":view 必须是 (lambda (data width) …)"))
             (t (list :ok (plist-get form :fields) (plist-get form :actions)
                      (let ((print-length nil) (print-level nil))
                        (prin1-to-string (plist-get form :view)))))))
        (error (list :failed (format "读不出表达式：%s" (error-message-string err))))))))

(defun supertag-stream-agent--check (agent)
  "Return nil when AGENT draws its scope at 100 and 80 columns, or why not."
  (or (supertag-stream-agent--refused agent)
      (let ((nodes (supertag-view-api-get-entities
                    :nodes (supertag-stream-agent--scope-ids (plist-get agent :scope)))))
        (seq-some (lambda (width)
                    (when-let* ((why (plist-get (supertag-stream-agent--draw agent nodes width)
                                                :failed)))
                      (format "宽度 %d：%s" width why)))
                  '(100 80)))))

(defun supertag-stream-agent--where (drawing id)
  "Return (LABEL POSITION GROUP) of node ID in DRAWING, or nil."
  (cl-loop for group in (plist-get drawing :groups)
           for g from 1
           for pos = (cl-position id (cdr group)
                                  :key (lambda (row) (plist-get (car row) :id))
                                  :test #'equal)
           when pos return (list (car group) (1+ pos) g)))

(defun supertag-stream-agent--probe-value (agent action ids id)
  "Return the value ACTION would write on node ID, or nil when it can't say."
  (pcase (plist-get action :value)
    ('today (format-time-string "[%Y-%m-%d %a]"))
    ('choose (car (supertag-stream-agent--choices agent (plist-get action :field) ids id)))
    ((and (pred stringp) value) value)))

(defun supertag-stream-agent--with-value (nodes id field value)
  "Return NODES with FIELD of node ID set to VALUE, in memory only."
  (mapcar (lambda (node)
            (if (not (equal (plist-get node :id) id))
                node
              (plist-put (copy-sequence node) :properties
                         (plist-put (copy-sequence (plist-get node :properties))
                                    (intern (concat ":" field)) value))))
          nodes))

(defun supertag-stream-agent--report (agent)
  "Describe AGENT's drawing of its real records, without titles or values.
Give the groups and their sizes, and where a node goes when each action is
pressed: the facts a model needs to see whether it did what was asked."
  (let* ((ids (supertag-stream-agent--scope-ids (plist-get agent :scope)))
         (nodes (supertag-view-api-get-entities :nodes ids))
         (drawing (supertag-stream-agent--draw agent nodes))
         (groups (plist-get drawing :groups))
         (omitted (or (plist-get drawing :omitted) 0))
         lines)
    (push (format "共 %d 条，分成 %d 组（按页面上的顺序）：" (length nodes) (length groups))
          lines)
    (cl-loop for group in groups for g from 1
             do (push (format "  %d. %s：%d 条%s" g (car group) (length (cdr group))
                              (if (and (= g (length groups)) (> omitted 0))
                                  "（你没列出、Stream 补上的）" ""))
                      lines))
    (when (> omitted 0)
      (push (format "注意：有 %d 条你没有列出，它们排在最后。" omitted) lines))
    (dolist (action (plist-get agent :actions))
      ;; Press it on the first node of the first group and of the last.
      (let (tried)
        (dolist (group (delete-dups (list (car groups) (car (last groups)))))
          (let* ((id (plist-get (car (cadr group)) :id))
                 (value (and id (not (member id tried))
                             (supertag-stream-agent--probe-value agent action ids id))))
            (when value
              (push id tried)
              (let* ((before (supertag-stream-agent--where drawing id))
                     (after-drawing (supertag-stream-agent--draw
                                     agent (supertag-stream-agent--with-value
                                            nodes id (plist-get action :field) value)))
                     (after (and (not (plist-get after-drawing :failed))
                                 (supertag-stream-agent--where after-drawing id))))
                (push (format "按 %s（%s，写 %s=%s）：一条原在第 %d 组「%s」第 %d 位 → %s"
                              (plist-get action :key) (plist-get action :label)
                              (plist-get action :field) value
                              (nth 2 before) (nth 0 before) (nth 1 before)
                              (cond ((plist-get after-drawing :failed)
                                     (format "画不出来：%s" (plist-get after-drawing :failed)))
                                    (after (format "第 %d 组「%s」第 %d 位（共 %d 组）"
                                                   (nth 2 after) (nth 0 after) (nth 1 after)
                                                   (length (plist-get after-drawing :groups))))))
                      lines)))))))
    (string-join (nreverse lines) "\n")))

(defun supertag-stream-agent--note (job verdict response)
  "Record on JOB one attempt: its VERDICT and the model's RESPONSE."
  (plist-put job :attempts
             (append (plist-get job :attempts) (list (list verdict response)))))

(defun supertag-stream-agent--finish (job agent)
  "Keep AGENT, the outcome of JOB, and show its Stream."
  (supertag-stream-agent--write agent)
  (setq supertag-stream-agent--last (plist-put job :outcome 'kept))
  (supertag-stream-agent--refresh-streams)
  (supertag-stream-agent--show-stream (plist-get (plist-get agent :scope) :tag))
  (message "Stream agent %s kept" (plist-get agent :name)))

(defun supertag-stream-agent--give-up (job why)
  "End JOB without an agent, because of WHY."
  (setq supertag-stream-agent--last (plist-put (plist-put job :outcome 'none) :why why))
  (message "Stream agent %s: no agent was accepted: %s" (plist-get job :name) why))

(defun supertag-stream-agent--ask (job prompt tries)
  "Ask the model for JOB's agent with PROMPT; retry TRIES more times."
  (supertag-summary--ask
   prompt supertag-stream-agent--system
   (lambda (response status)
     ;; Superchat swallows errors raised here; say them.
     (condition-case err
         (supertag-stream-agent--handle job response status tries)
       (error
        (supertag-stream-agent--give-up job (error-message-string err)))))))

(defun supertag-stream-agent--handle (job response status tries)
  "Check RESPONSE for JOB; self-check it, keep it, retry, or give up."
  (let* ((parsed (if (eq status 'completed)
                     (supertag-stream-agent--parse response)
                   (list :failed (format "%s: %s" status response))))
         (agent (and (eq (car parsed) :ok)
                     (list :name (plist-get job :name)
                           :sentence (plist-get job :sentence)
                           :revisions (plist-get job :revisions)
                           :scope (list :tag (plist-get job :tag))
                           :fields (nth 1 parsed)
                           :actions (nth 2 parsed)
                           :view (nth 3 parsed))))
         (why (if agent (supertag-stream-agent--check agent) (cadr parsed))))
    (supertag-stream-agent--note job why response)
    (cond
     ((and (null why) (> (plist-get job :checks) 0))
      (supertag-stream-agent--self-check job agent response tries))
     ((null why) (supertag-stream-agent--finish job agent))
     ((and (eq status 'completed) (> tries 0))
      (supertag-stream-agent--ask
       job
       (format "%s\n\n你上次的输出是：\n%s\n\n它被拒绝了：%s\n请改正后重新输出完整的表达式。"
               (plist-get job :base) response why)
       (1- tries)))
     (t (supertag-stream-agent--give-up job why)))))

(defun supertag-stream-agent--self-check (job agent response tries)
  "Show the model what AGENT draws; keep it on OK, otherwise take its fix.
RESPONSE is what the model wrote; TRIES how many retries remain."
  (let ((report (supertag-stream-agent--report agent)))
    (plist-put job :checks (1- (plist-get job :checks)))
    (supertag-stream-agent--note job (concat "self-check:\n" report) nil)
    (message "Stream agent %s: checking what it draws…" (plist-get job :name))
    (supertag-summary--ask
     (format "%s\n\n你写的代理是：\n%s\n\n它已经能运行。用户真实数据画出的结果（不含标题和属性值）：\n%s\n\n\
对照用户的话逐条检查：分组和顺序对不对；该在某组的记录有没有掉进最后；每个按键之后，那条记录是不是到了用户说的位置。\n\
全部符合，只输出 OK。有不符合的，输出改正后的完整表达式（不要解释）。"
             (plist-get job :base) response report)
     supertag-stream-agent--system
     (lambda (reply status)
       (condition-case err
           (cond
            ((and (eq status 'completed)
                  (string-match-p "\\`[ \t\n]*OK[ \t\n。.]*\\'" (or reply "")))
             (supertag-stream-agent--note job "self-check: OK" reply)
             (supertag-stream-agent--finish job agent))
            ((eq status 'completed)
             (supertag-stream-agent--handle job reply status (max tries 2)))
            ;; The check could not run; keep what already works.
            (t (supertag-stream-agent--finish job agent)))
         (error
          (supertag-stream-agent--give-up job (error-message-string err))))))))

(defun supertag-stream-agent--start (tag sentence revisions base)
  "Ask for the agent of TAG from SENTENCE and REVISIONS with prompt BASE."
  (let ((job (list :name (supertag-tag--name tag) :tag tag :sentence sentence
                   :revisions revisions :base base
                   :checks supertag-stream-agent-self-check-rounds
                   :attempts nil)))
    (setq supertag-stream-agent--last job)
    (supertag-stream-agent--ask job base 2)))

(defun supertag-stream-agent-design (tag sentence)
  "Have the model write the agent of the Stream of TAG from SENTENCE.
The agent is kept beside the notes and used by every Stream of TAG."
  (interactive
   (list (plist-get (supertag-view--read-tag) :value)
         (read-string "这条 Stream 要怎么处理：")))
  (let* ((tag (or (supertag-view-api-tag-id tag) (user-error "No tag named %s" tag)))
         (name (supertag-tag--name tag)))
    (when (and (file-exists-p (supertag-stream-agent--file name))
               (not (yes-or-no-p (format "Replace the agent of #%s? " name))))
      (user-error "Kept the agent of #%s" name))
    (message "Stream agent %s: asking the model…" name)
    (supertag-stream-agent--start tag sentence nil
                                  (supertag-stream-agent--prompt tag sentence))))

(defun supertag-stream-agent-revise (name change)
  "Have the model change the agent NAME as CHANGE says.
The model sees the agent as it is and every change asked before.  Only the
user's words are kept as revisions, never the model's own checks."
  (interactive
   (let ((name (supertag-stream-agent--read-name)))
     (list name (read-string (format "%s 要怎么改：" name)))))
  (let* ((agent (or (supertag-stream-agent--read (supertag-stream-agent--file name))
                    (user-error "No agent named %s" name)))
         (tag (plist-get (plist-get agent :scope) :tag))
         (before (plist-get agent :revisions))
         (print-length nil) (print-level nil))
    (message "Stream agent %s: asking the model to revise…" name)
    (supertag-stream-agent--start
     tag (plist-get agent :sentence) (append before (list change))
     (format "%s\n\n这个代理现在是：\n(:fields %S\n :actions %S\n :view %s)\n%s\n这次用户要求：%s\n\n\
在现在的代理上改，用户没提到的部分保持不变。输出完整的表达式。"
             (supertag-stream-agent--prompt tag (plist-get agent :sentence))
             (plist-get agent :fields) (plist-get agent :actions) (plist-get agent :view)
             (if before
                 (concat "\n用户之前要求过的修改（都要继续满足）：\n"
                         (mapconcat (lambda (c) (concat "- " c)) before "\n") "\n")
               "")
             change))))

(provide 'supertag-stream-agent)

;;; supertag-stream-agent.el ends here
