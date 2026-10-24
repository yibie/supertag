;;; supertag-summary.el --- A tag's information panel, laid out by a model -*- lexical-binding: t; -*-

;;; Commentary:
;; Commands: supertag-summary-design, supertag-summary-revise,
;; supertag-summary-open, supertag-summary-component.
;; Dependencies: cl-lib, subr-x, seq, textui, supertag-vault, supertag-node,
;; supertag-query, supertag-tag, supertag-services-sync, supertag-service-org,
;; supertag-ai, supertag-view-framework, supertag-view-tag-cards,
;; supertag-summary-runner; superchat or gptel, optional, to write code.
;;
;; A summary is the information panel of one tag.  The user says in one
;; sentence what the panel should show; a model writes the layout as
;; (lambda (data width) ...) returning interface elements; Supertag draws it
;; with TextUI.  `summary.md' is the contract this file implements.
;;
;;   M-x supertag-summary-design     tag → name → what you want to see
;;   M-x supertag-summary-revise     name → what to change
;;   M-x supertag-summary-open       name
;;   M-x supertag-summary-component  tag → name → what it draws
;;
;; The model decides the layout and nothing else.  Its code never runs in
;; this session: a child Emacs refuses it unless every function it names is
;; allowed, runs it, and prints what it returned (see
;; `supertag-summary-runner').  This file then rebuilds every element from
;; numbers and plain text, so the widgets, their faces and what a click does
;; all come from the expanders below.
;;
;; The records a panel draws come from the Store every time the buffer is
;; drawn.  No model reads a note: designing a panel sends the title, state
;; and tags of six records as a sample, and nothing else.
;;
;; A panel is kept as NAME.org.summary, a data file that is read and never
;; evaluated, so Git can carry it to other machines.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'textui)
(require 'supertag-vault)
(require 'supertag-node)
(require 'supertag-query)
(require 'supertag-tag)
(require 'supertag-services-sync)
(require 'supertag-service-org)
(require 'supertag-ai)
(require 'supertag-view-framework)
(require 'supertag-view-tag-cards)
(require 'supertag-summary-runner)

(declare-function superchat-sink-create "superchat-sink" (&rest plist))
(declare-function gptel-request "gptel-request" (&optional prompt &rest args))
(declare-function gptel-abort "gptel-request" (buf))
(declare-function gptel-get-preset "gptel" (name))
(defvar gptel-use-tools)
(defvar gptel-include-reasoning)
(declare-function supertag-git-sync-file-written "supertag-git" (file))
(defvar org-todo-keywords-1)

(defgroup supertag-summary nil
  "Information panels a model lays out over the notes of a tag."
  :group 'supertag)

(defcustom supertag-summary-directory nil
  "Directory where summary panels are kept, one NAME.org.summary each.
Nil means `summaries/' under the sync directory, so the panels travel with
the notes, or under `supertag-data-directory' when no sync directory is set.
Components are kept in its `components/' subdirectory."
  :type '(choice (const :tag "Beside the notes" nil) directory)
  :group 'supertag-summary)

(defcustom supertag-summary-palette 'paper
  "The view palette summary panels are shown in."
  :type 'symbol
  :group 'supertag-summary)

(defcustom supertag-summary-skip-file-regexp "archive\\.org\\'"
  "Notes in files whose name matches this are left out of every panel.
Nil leaves nothing out."
  :type '(choice (const :tag "Leave nothing out" nil) regexp)
  :group 'supertag-summary)

(defcustom supertag-summary-timeout 180
  "Seconds a model may take to write a panel or a component."
  :type 'integer
  :group 'supertag-summary)

(defcustom supertag-summary-provider 'auto
  "What sends the request when a model writes a panel or a Stream agent.
`auto' uses Superchat when it can be loaded and gptel otherwise.
`superchat' or `gptel' uses that package.  With gptel, a preset named
`supertag' chooses the model when there is one; otherwise gptel's own
defaults do.  gptel quietly replaces a model its backend does not
list in `:models', so the preset's model must be listed there.  A
model that thinks before answering can run past
`supertag-summary-timeout'; turn its thinking off in the backend, for
LM Studio with `:request-params' (:reasoning_effort \"none\").
A function is called with PROMPT, SYSTEM and CALLBACK, and
must call CALLBACK once with the reply text and `completed', or with an
error message and another status."
  :type '(choice (const :tag "Superchat, else gptel" auto)
                 (const :tag "Superchat" superchat)
                 (const :tag "gptel" gptel)
                 (function :tag "Own function"))
  :group 'supertag-summary)

(defcustom supertag-summary-run-timeout 20
  "Seconds layout code may run in its child Emacs before it is stopped."
  :type 'number
  :group 'supertag-summary)

(defconst supertag-summary--extension ".org.summary"
  "The suffix of a file that keeps a panel or a component.")

(defvar supertag-summary--panels (make-hash-table :test 'equal)
  "The panels of this session by name.")

(defvar supertag-summary--candidate nil
  "The (NAME . FORM) of a component being checked before it is kept.")

(defvar supertag-summary--last nil
  "The outcome of the last design or revision, kept for inspection.")

;;; Files

(defun supertag-summary--directory ()
  "Return the directory panels are kept in."
  (file-name-as-directory
   (expand-file-name
    (or supertag-summary-directory
        (expand-file-name
         "summaries"
         (or (car (supertag-sync--effective-directories))
             supertag-data-directory))))))

(defun supertag-summary--components-directory ()
  "Return the directory components are kept in."
  (expand-file-name "components/" (supertag-summary--directory)))

(defun supertag-summary--file (name)
  "Return the file that keeps panel NAME."
  (expand-file-name (concat name supertag-summary--extension)
                    (supertag-summary--directory)))

(defun supertag-summary--component-file (name)
  "Return the file that keeps component NAME."
  (expand-file-name (format "%s%s" name supertag-summary--extension)
                    (supertag-summary--components-directory)))

(defun supertag-summary--names-in (directory)
  "Return the names of the files kept in DIRECTORY, sorted."
  (and (file-directory-p directory)
       (mapcar (lambda (file)
                 (string-remove-suffix supertag-summary--extension file))
               (directory-files
                directory nil
                (concat "\\`[^.].*" (regexp-quote supertag-summary--extension)
                        "\\'")))))

(defun supertag-summary--names ()
  "Return the names of the kept panels."
  (supertag-summary--names-in (supertag-summary--directory)))

(defun supertag-summary--data-file (name)
  "Return the per-machine file holding the records panel NAME draws."
  (expand-file-name (concat (secure-hash 'sha1 name) ".data")
                    (expand-file-name "summary/" supertag-data-directory)))

(defun supertag-summary--read (file kind)
  "Return (:ok PLIST) for the KIND kept in FILE, or (:failed TEXT).
FILE is read as data.  Nothing in it is evaluated."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (if (re-search-forward "^\\(?:<<<<<<<\\|>>>>>>>\\) " nil t)
            (list :failed "it has unresolved Git conflict markers")
          (goto-char (point-min))
          (let ((data (read (current-buffer))))
            (cond
             ((not (and (proper-list-p data) (cl-evenp (length data))))
              (list :failed "it does not hold a property list"))
             ((not (eql (plist-get data :format) 1))
              (list :failed (format "its format %S is not one this version reads"
                                    (plist-get data :format))))
             ((not (eq (plist-get data :kind) kind))
              (list :failed (format "it holds a %s, not a %s"
                                    (plist-get data :kind) kind)))
             ((not (stringp (plist-get data :code)))
              (list :failed "it holds no layout code"))
             ((and (eq kind 'panel) (not (stringp (plist-get data :tag))))
              (list :failed "it names no tag"))
             ((not (and (proper-list-p (plist-get data :revisions))
                        (cl-every #'stringp (plist-get data :revisions))))
              (list :failed "its revisions are not a list of sentences"))
             (t (list :ok data))))))
    (error (list :failed (format "it cannot be read (%s)"
                                 (error-message-string err))))))

(defun supertag-summary--write (file plist)
  "Write PLIST to FILE as data, one property to a line.
Strings keep their line breaks, so a revised layout differs line by line."
  (let ((coding-system-for-write 'utf-8)
        (print-escape-newlines nil)
        (print-escape-control-characters nil)
        (print-escape-nonascii nil)
        (print-escape-multibyte nil)
        (print-length nil)
        (print-level nil))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";;; Supertag summary.  Data: read, never evaluated."
              "  -*- mode: lisp-data; coding: utf-8 -*-\n(")
      (cl-loop for (key value) on plist by #'cddr
               for separator = "" then "\n "
               do (insert separator (symbol-name key) " "
                          (prin1-to-string value)))
      (insert ")\n")))
  ;; Code wrote this file, so no save hook saw it.
  (when (and (bound-and-true-p supertag-git-sync-mode)
             (fboundp 'supertag-git-sync-file-written))
    (supertag-git-sync-file-written file)))

(defun supertag-summary--mtime (file)
  "Return the modification time of FILE, or nil."
  (file-attribute-modification-time (file-attributes file)))

;;; Records, straight from the Store

(defconst supertag-summary--day-regexp
  "\\(\\(?:19\\|20\\)[0-9][0-9]\\)[-/.年]\\([0-9]\\{1,2\\}\\)\\(?:[-/.月]\\([0-9]\\{1,2\\}\\)\\)?"
  "Match a year and month, optionally a day, in free text.")

(defun supertag-summary--day-in (text)
  "Return the first date in TEXT as YYYY-MM-DD or YYYY-MM, or nil."
  (when (and (stringp text)
             (string-match supertag-summary--day-regexp text))
    (let ((year (match-string 1 text))
          (month (string-to-number (match-string 2 text)))
          (day (and (match-string 3 text)
                    (string-to-number (match-string 3 text)))))
      (when (<= 1 month 12)
        (if (and day (<= 1 day 31))
            (format "%s-%02d-%02d" year month day)
          (format "%s-%02d" year month))))))

(defun supertag-summary--node-day (node)
  "Return the day NODE belongs to, preferring what the user wrote.
In order: its CREATED property, the deepest dated outline ancestor, a date in
its title, the day it was created.  A day is YYYY-MM-DD or YYYY-MM."
  (let ((olp (plist-get node :olp))
        (created (plist-get node :created-at)))
    (or (supertag-summary--day-in
         (plist-get (plist-get node :properties) :CREATED))
        (cl-some #'supertag-summary--day-in (reverse (and (listp olp) olp)))
        (supertag-summary--day-in (plist-get node :title))
        (when-let* ((time (cond ((stringp created)
                                 (ignore-errors (date-to-time created)))
                                (created))))
          (ignore-errors (format-time-string "%Y-%m-%d" time))))))

(defun supertag-summary--node-title (node)
  "Return the title NODE is shown under."
  (let ((title (or (plist-get node :title) (plist-get node :raw-value))))
    (if (and (stringp title) (not (string-empty-p title))) title "Untitled")))

(defun supertag-summary--date (value)
  "Return VALUE, a planning date of a node, as YYYY-MM-DD or nil."
  (cond ((stringp value)
         (let ((day (supertag-summary--day-in value)))
           (and day (= (length day) 10) day)))
        ((and value (listp value))
         (ignore-errors (format-time-string "%Y-%m-%d" value)))))

;;; Properties, shared with the Stream agents

(defconst supertag-summary--timestamp-regexp
  "\\`[[<]?\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)\\(?: [^]>]*\\)?[]>]?\\'"
  "Match a property value that is a date and nothing else, Org timestamp or plain.")

(defun supertag-summary--props (node)
  "Return the properties of NODE as ((NAME . VALUE) ...).
A value that is a date, such as [2026-10-23 Fri], is given as YYYY-MM-DD;
any other value is its text."
  (let ((props (plist-get node :properties))
        alist)
    (while props
      (let ((key (car props))
            (text (format "%s" (cadr props))))
        (push (cons (if (keywordp key) (substring (symbol-name key) 1) (format "%s" key))
                    (if (string-match supertag-summary--timestamp-regexp text)
                        (match-string 1 text)
                      text))
              alist))
      (setq props (cddr props)))
    (nreverse alist)))

(defun supertag-summary--ymd-p (value)
  "Return non-nil when VALUE is a YYYY-MM-DD string."
  (and (stringp value)
       (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" value)))

(defun supertag-summary-property-lines (records)
  "Return a line per property of RECORDS, most used first, or nil.
A line gives the name, how many records have it, whether it holds dates, and
the values more than one record shares.  A value only one record has, such as
a phone number or an address, is personal data and is left out; a value many
records share is a category the layout may need to group by or write back."
  (let ((table (make-hash-table :test 'equal))
        names)
    (dolist (entry records)
      (pcase-dolist (`(,name . ,value) (plist-get entry :props))
        (unless (gethash name table) (push name names))
        (push value (gethash name table))))
    (when names
      (mapconcat
       (lambda (name)
         (let* ((values (gethash name table))
                (datep (cl-every #'supertag-summary--ymd-p values))
                (counts (make-hash-table :test 'equal))
                shared)
           (unless datep
             (dolist (value values) (cl-incf (gethash value counts 0)))
             (maphash (lambda (value n) (when (> n 1) (push (cons value n) shared)))
                      counts))
           (format "- %s：%d 条%s%s" name (length values)
                   (if datep "，日期" "")
                   (if shared
                       (concat "，常见值 "
                               (mapconcat (lambda (pair) (truncate-string-to-width (car pair) 30))
                                          (seq-take (cl-sort shared #'> :key #'cdr) 8)
                                          "、"))
                     ""))))
       (cl-sort names #'> :key (lambda (name) (length (gethash name table))))
       "\n"))))

(defun supertag-summary-property-mask (entry)
  "Return ENTRY with every property value that is not a date shown as …."
  (let ((copy (copy-sequence entry)))
    (plist-put copy :props
               (mapcar (lambda (pair)
                         (cons (car pair)
                               (if (supertag-summary--ymd-p (cdr pair)) (cdr pair) "…")))
                       (plist-get entry :props)))))

(defconst supertag-summary-property-guide
  "* 属性
每条记录的 :props 是 ((\"属性名\" . 值) …)，取一个属性：(cdr (assoc \"名字\" (plist-get entry :props)))。
- 属性是用户为自己的需要随手建的，没有预先定好的结构。很多记录没有某个属性，没有时是 nil，要为它准备好显示。
- 值都是字符串。日期类的值已经换成 \"YYYY-MM-DD\"；数字比较前先用 string-to-number。
- 下面列出了这批记录已有的属性：名字、几条有、是不是日期、几条记录共用的值。\
用户的话提到的东西，先在里面找意思相同的名字和值，不要用一个不存在的名字。
- ID、CREATED、CATEGORY 这类是 Org 和 Supertag 自己用的，不是用户的数据。"
  "What a model is told about node properties, by summary and by Stream agents.")

(defun supertag-summary--live-p (node)
  "Return non-nil when NODE is a heading outside the skipped files."
  (not (or (eql (plist-get node :level) 0)
           (and supertag-summary-skip-file-regexp
                (string-match-p supertag-summary-skip-file-regexp
                                (or (plist-get node :file) ""))))))

(defun supertag-summary--node (index ref)
  "Return the node INDEX knows as REF."
  (gethash ref index))

(defun supertag-summary--collect (tag)
  "Return (INDEX . DATA) for the notes of TAG and of the tags below it.
TAG is a Tag ID.  INDEX maps the refs in DATA to nodes.  Nodes are numbered
in file and position order, so a ref names the same note from one drawing to
the next as long as no note is added or removed before it."
  (let* ((nodes (sort (cl-remove-if-not
                       #'supertag-summary--live-p
                       (supertag-view-api-get-entities
                        :nodes (supertag-view-api-nodes-by-tag tag t)))
                      (lambda (a b)
                        (let ((file-a (or (plist-get a :file) ""))
                              (file-b (or (plist-get b :file) "")))
                          (if (equal file-a file-b)
                              (< (or (plist-get a :pos) 0)
                                 (or (plist-get b :pos) 0))
                            (string< file-a file-b))))))
         (index (make-hash-table :test 'equal))
         (roots (make-hash-table :test 'equal))
         (title (format "#%s" (supertag-tag--name tag)))
         (number 0)
         (states nil)
         (items (mapcar (lambda (node)
                          (let ((ref (format "n%d" (cl-incf number))))
                            (puthash ref node index)
                            (cons ref node)))
                        nodes)))
    ;; A node's `:olp' ends with its own title.
    (pcase-dolist (`(,ref . ,node) items)
      (when (member tag (plist-get node :tags))
        (puthash (list (plist-get node :file) (plist-get node :olp)) ref roots)))
    (cons
     index
     (list
      :title title
      :today (format-time-string "%Y-%m-%d")
      :total (length items)
      :records
      (mapcar
       (pcase-lambda (`(,ref . ,node))
         (let* ((olp (plist-get node :olp))
                (rootp (and (member tag (plist-get node :tags)) t))
                (state (plist-get node :todo))
                (day (supertag-summary--node-day node)))
           (when state (cl-incf (alist-get state states 0 nil #'equal)))
           (list :ref ref
                 :title (supertag-summary--node-title node)
                 :todo state
                 :priority (when-let* ((priority (plist-get node :priority)))
                             (format "%s" priority))
                 :tags (mapcar #'supertag-tag--name (plist-get node :tags))
                 :root rootp
                 :owner (and (not rootp) (listp olp)
                             (cl-loop
                              for depth from (1- (length olp)) downto 1
                              thereis (gethash (list (plist-get node :file)
                                                     (seq-take olp depth))
                                               roots)))
                 :day (and day (= (length day) 10) day)
                 :scheduled (supertag-summary--date (plist-get node :scheduled))
                 :deadline (supertag-summary--date (plist-get node :deadline))
                 :props (supertag-summary--props node)
                 :file (file-name-nondirectory (or (plist-get node :file) "")))))
       items)
      :states (mapcar #'car (cl-sort states #'> :key #'cdr))))))

(defun supertag-summary--sync (panel)
  "Bring the records of PANEL up to date with the Store.
The data file is rewritten only when the records changed.  Return a
signature of the records."
  (pcase-let* ((`(,index . ,data) (supertag-summary--collect
                                   (plist-get panel :tag)))
               (print-length nil)
               (print-level nil)
               (text (prin1-to-string data))
               (signature (secure-hash 'sha1 text))
               (coding-system-for-write 'utf-8))
    (plist-put panel :index index)
    (plist-put panel :total (plist-get data :total))
    (unless (and (equal signature (plist-get panel :signature))
                 (file-exists-p (plist-get panel :data-file)))
      (make-directory (file-name-directory (plist-get panel :data-file)) t)
      (with-temp-file (plist-get panel :data-file) (insert text))
      (plist-put panel :signature signature))
    signature))

(defun supertag-summary--describe (data)
  "Return what the model is told about DATA: its size and a sample."
  (let* ((records (plist-get data :records))
         (roots (cl-count-if (lambda (entry) (plist-get entry :root)) records))
         (owned (cl-count-if (lambda (entry) (plist-get entry :owner)) records))
         ;; A layout built around a field nobody fills in draws empty columns.
         (empty (cl-remove-if
                 (lambda (key)
                   (cl-some (lambda (entry) (plist-get entry key)) records))
                 '(:priority :day :scheduled :deadline)))
         (properties (supertag-summary-property-lines records))
         (print-length nil)
         (print-level 4))
    (format "这批记录来自 %s，共 %d 条：%d 条本身带这个标签，%d 条挂在它们下面，\
%d 条两者都不是。出现过的 TODO 状态（从多到少）：%s；有 %d 条没有状态。%s\n\n\
%s\n\n前 6 条记录的样子（日期以外的属性值写成 …）：\n%s"
            (plist-get data :title) (length records) roots owned
            (- (length records) roots owned)
            (or (plist-get data :states) "没有")
            (cl-count-if-not (lambda (entry) (plist-get entry :todo)) records)
            (if empty
                (format "\n这批记录里 %s 全部是 nil，不要围绕它们排版。"
                        (mapconcat #'symbol-name empty "、"))
              "")
            (if properties
                (concat "这批记录已有的属性：\n" properties)
              "这批记录还没有属性。")
            (mapconcat (lambda (entry)
                         (prin1-to-string (supertag-summary-property-mask entry)))
                       (seq-take records 6) "\n"))))

;;; Checking what layout code returned

(defconst supertag-summary--keys
  '((:flex :direction :gap :padding :border :layout :children)
    (:grid :columns :min-column-width :gap :column-gap :row-gap :padding
     :border :layout :children)
    (:text :value :tone :layout)
    (supertag-summary-line :value :tone :width :layout)
    (supertag-summary-fill :label :tone :width :layout)
    (supertag-summary-link :node :label :marker :width :layout)
    (supertag-summary-bar :value :max :width :layout)
    (supertag-summary-heat :values :max :cell :layout)
    (supertag-summary-rule :width :layout)
    (supertag-summary-canvas :rows :layout)
    (supertag-summary-todo :node :width :layout))
  "The element types layout code may return, each with the properties it takes.")

(defvar supertag-summary--budget nil
  "Elements the panel being checked may still contain.")

(defvar supertag-summary--unresolved nil
  "Links of the panel being checked that named no record.")

(defvar supertag-summary--buttoned nil
  "Node IDs that already have a state button in the panel being checked.")

(defun supertag-summary--show (value)
  "Return VALUE printed short enough to quote in an error."
  (let ((print-length 6) (print-level 3))
    (truncate-string-to-width (prin1-to-string value) 120 nil nil "…")))

(defun supertag-summary--count (value what minimum)
  "Return VALUE as an integer of at least MINIMUM, or refuse WHAT."
  (unless (and (numberp value) (>= value 0) (<= value 2000))
    (error "%s 必须是 0 到 2000 之间的数：%s" what
           (supertag-summary--show value)))
  (max minimum (round value)))

(defun supertag-summary--string (value what)
  "Return VALUE as one line of plain text, or refuse WHAT."
  (cond ((null value) "")
        ((numberp value) (number-to-string value))
        ((stringp value)
         (replace-regexp-in-string "[\n\r\t]+" " "
                                   (substring-no-properties value)))
        (t (error "%s 必须是字符串：%s" what (supertag-summary--show value)))))

(defun supertag-summary--metrics ()
  "Return (MEASURE . CELL) of the layout in effect.
A graphical frame measures pixels, because a CJK glyph is seldom exactly two
cells wide there; everything else counts columns."
  (or (textui--pixel-metrics) (cons #'string-width 1)))

(defun supertag-summary--fit (text width &optional prefix suffix)
  "Return PREFIX TEXT SUFFIX in the face of TEXT, cut to WIDTH layout columns.
TEXT loses characters from its end and gains an ellipsis until the whole
string fits.  Without WIDTH nothing is cut."
  (let* ((face (and (> (length text) 0) (get-text-property 0 'face text)))
         (plain (substring-no-properties text))
         (build (lambda (body)
                  (let ((whole (concat prefix body suffix)))
                    (if face (propertize whole 'face face) whole))))
         (whole (funcall build plain)))
    (when width
      (pcase-let* ((`(,measure . ,cell) (supertag-summary--metrics))
                   (budget (* width cell))
                   (keep (length plain)))
        (while (and (> keep 0) (> (funcall measure whole) budget))
          (setq keep (1- keep)
                whole (funcall build (concat (substring plain 0 keep) "…"))))))
    whole))

(defun supertag-summary--tone (tone)
  "Return the checked text TONE."
  (unless (memq tone '(nil :normal :mute :strong))
    (error ":tone 只能是 :normal、:mute 或 :strong：%s"
           (supertag-summary--show tone)))
  tone)

(defun supertag-summary--tone-face (tone)
  "Return the role face for text TONE, or nil."
  (pcase tone
    (:mute 'supertag-view-mute)
    (:strong 'supertag-view-accent)))

(defun supertag-summary--layout (layout native)
  "Return the checked parent-facing LAYOUT; NATIVE elements cannot shrink."
  (unless (and (proper-list-p layout) (cl-evenp (length layout)))
    (error ":layout 必须是属性列表：%s" (supertag-summary--show layout)))
  (let (clean)
    (cl-loop
     for (key value) on layout by #'cddr do
     (pcase key
       ((or :width :min-width)
        (unless (and native (eq key :min-width))
          (setq clean (nconc clean
                             (list key (supertag-summary--count
                                        value (symbol-name key) 1))))))
       (:grow
        (unless (and (numberp value) (>= value 0))
          (error ":grow 必须是不小于 0 的数：%s" (supertag-summary--show value)))
        (setq clean (nconc clean (list :grow value))))
       (_ (error ":layout 里没有 %s 这个属性，只有 :width、:min-width、:grow"
                 (supertag-summary--show key)))))
    clean))

(defun supertag-summary--gaps (element keys)
  "Return the KEYS of ELEMENT that are present, each as a checked count."
  (cl-loop for key in keys
           when (plist-member element key)
           append (list key (supertag-summary--count
                             (plist-get element key) (symbol-name key) 0))))

(defun supertag-summary--children (element index depth)
  "Return the checked children of container ELEMENT at DEPTH.
INDEX resolves the records they name."
  (let ((children (plist-get element :children)))
    (unless (proper-list-p children)
      (error ":children 必须是元素的列表：%s" (supertag-summary--show children)))
    (mapcar (lambda (child) (supertag-summary--clean child index (1+ depth)))
            children)))

(defun supertag-summary--canvas-row (row)
  "Return canvas ROW as a checked one-line element.
ROW is a string or a list of segments; a segment is a string or (TEXT TONE)."
  (let ((segments (if (stringp row) (list row) row)))
    (unless (and (proper-list-p segments) (<= (length segments) 400))
      (error "画布的每一行必须是不超过 400 段的列表：%s"
             (supertag-summary--show row)))
    (when (< (cl-decf supertag-summary--budget (length segments)) 0)
      (error "元素超过 4000 个，请少画一些"))
    (list :type 'supertag-summary-row
          :segments
          (mapcar
           (lambda (segment)
             (let* ((whole (or (stringp segment)
                               (and (consp segment) (proper-list-p segment)
                                    (<= (length segment) 2))))
                    (text (if (consp segment) (car segment) segment))
                    (tone (and whole (consp segment) (cadr segment))))
               (unless (and whole (memq tone '(nil :normal :mute :strong 1 2 3)))
                 (error "画布的一段必须是 \"文字\" 或 (\"文字\" 色调)，\
色调只能是 :normal、:mute、:strong、1、2、3：%s"
                        (supertag-summary--show segment)))
               (cons (supertag-summary--string text "画布里的文字") tone)))
           segments))))

(defun supertag-summary--clean (element index depth)
  "Return a checked copy of ELEMENT at DEPTH whose records resolve in INDEX.
Nothing of ELEMENT itself survives: every value is rebuilt from a number or
from plain text, so no function and no text property can ride along."
  (when (> depth 12) (error "元素嵌套超过 12 层"))
  (when (< (cl-decf supertag-summary--budget) 0)
    (error "元素超过 4000 个，请少画一些"))
  (unless (and (proper-list-p element) (cl-evenp (length element)))
    (error "每个元素必须是带 :type 的属性列表：%s"
           (supertag-summary--show element)))
  (let* ((type (plist-get element :type))
         (keys (alist-get type supertag-summary--keys))
         (take (lambda (key) (plist-get element key))))
    (unless keys
      (error "没有 %s 这种元素，只能用：%s"
             (supertag-summary--show type)
             (mapconcat (lambda (entry) (format "%s" (car entry)))
                        supertag-summary--keys " ")))
    (cl-loop for key in element by #'cddr do
             (unless (or (eq key :type) (memq key keys))
               (error "%s 没有 %s 这个属性，只有：%s" type
                      (supertag-summary--show key)
                      (mapconcat #'symbol-name keys " "))))
    (let ((layout (and (funcall take :layout)
                       (supertag-summary--layout
                        (funcall take :layout) (not (keywordp type)))))
          (width (and (funcall take :width)
                      (supertag-summary--count (funcall take :width) ":width" 1))))
      (append
       (pcase type
         (:flex
          (let ((direction (or (funcall take :direction) :column)))
            (unless (memq direction '(:row :column))
              (error ":direction 只能是 :row 或 :column：%s"
                     (supertag-summary--show direction)))
            (append
             (list :type :flex :direction direction)
             (supertag-summary--gaps element '(:gap :padding))
             (and (funcall take :border) (list :border t))
             (list :children
                   (supertag-summary--children element index depth)))))
         (:grid
          (append
           (list :type :grid
                 :columns (supertag-summary--count
                           (funcall take :columns) ":columns" 1)
                 :min-column-width (supertag-summary--count
                                    (or (funcall take :min-column-width) 16)
                                    ":min-column-width" 1))
           (supertag-summary--gaps
            element '(:gap :column-gap :row-gap :padding))
           (and (funcall take :border) (list :border t))
           (list :children
                 (supertag-summary--children element index depth))))
         (:text
          (let ((text (supertag-summary--string (funcall take :value) ":value"))
                (face (supertag-summary--tone-face
                       (supertag-summary--tone (funcall take :tone)))))
            (when (string-empty-p text) (setq text " "))
            (list :type :text :wrap 'greedy :align 'left
                  :value (if face (propertize text 'face face) text))))
         ('supertag-summary-line
          (list :type type
                :value (supertag-summary--string (funcall take :value) ":value")
                :tone (supertag-summary--tone (funcall take :tone))
                :width width))
         ('supertag-summary-fill
          (let ((tone (or (funcall take :tone) 1)))
            (unless (integerp tone)
              (error "色块的 :tone 只能是 1、2 或 3：%s"
                     (supertag-summary--show tone)))
            (list :type type
                  :label (supertag-summary--string (funcall take :label) ":label")
                  :tone (1+ (mod (1- tone) 3))
                  :width width)))
         ('supertag-summary-link
          (let* ((ref (funcall take :node))
                 (node (and (stringp ref) (supertag-summary--node index ref)))
                 (marker (or (funcall take :marker) ""))
                 (label (supertag-summary--string (funcall take :label) ":label")))
            (unless (member marker '("" "→" "+"))
              (error "链接的 :marker 只能是 \"→\" 或 \"+\"：%s"
                     (supertag-summary--show marker)))
            (unless (string-empty-p marker)
              (setq label (concat marker " " label)))
            (if node
                (list :type type :label label :node-id (plist-get node :id)
                      :width width)
              (cl-incf supertag-summary--unresolved)
              (list :type 'supertag-summary-line :value label :tone nil
                    :width width))))
         ('supertag-summary-bar
          (let* ((value (or (funcall take :value) 0))
                 (most (or (funcall take :max) value)))
            (unless (and (numberp value) (numberp most))
              (error "比例条的 :value 和 :max 必须是数：%s"
                     (supertag-summary--show element)))
            (list :type type :value (max 0 value) :max (max 1 most)
                  :width (or width 12))))
         ('supertag-summary-heat
          (let ((values (funcall take :values))
                (cell (or (funcall take :cell) 2)))
            (unless (and (proper-list-p values) (<= (length values) 400)
                         (cl-every (lambda (value)
                                     (or (null value) (numberp value)))
                                   values))
              (error "密度格的 :values 必须是不超过 400 个数的列表：%s"
                     (supertag-summary--show values)))
            (unless (memq cell '(1 2))
              (error "密度格的 :cell 只能是 1 或 2：%s"
                     (supertag-summary--show cell)))
            (setq values (mapcar (lambda (value) (max 0 (or value 0))) values))
            (list :type type :values values :cell cell
                  :max (max 1 (let ((most (funcall take :max)))
                                (if (numberp most)
                                    most
                                  (apply #'max 0 values)))))))
         ('supertag-summary-rule
          (list :type type :width (or width 24)))
         ;; Only the node travels: the state shown and what a click does are
         ;; decided here, never by layout code.
         ('supertag-summary-todo
          (let* ((ref (funcall take :node))
                 (node (and (stringp ref) (supertag-summary--node index ref))))
            (if node
                ;; TextUI refuses two elements with one focus id, so only
                ;; the first button of a note gets point back after a redraw.
                (let* ((id (plist-get node :id))
                       (first (not (member id supertag-summary--buttoned))))
                  (when first (push id supertag-summary--buttoned))
                  (list :type type :node-id id :focus first
                        :width (min 12 (or width 5))))
              (cl-incf supertag-summary--unresolved)
              (list :type 'supertag-summary-line :value "" :tone nil
                    :width (+ 4 (min 12 (or width 5)))))))
         ;; A canvas becomes a gapless column of one-line rows, so it nests
         ;; anywhere a TextUI block could not.
         ('supertag-summary-canvas
          (let ((rows (funcall take :rows)))
            (unless (and (proper-list-p rows) rows (<= (length rows) 200))
              (error "画布的 :rows 必须是 1 到 200 行的列表：%s"
                     (supertag-summary--show rows)))
            (list :type :flex :direction :column :gap 0
                  :children (mapcar #'supertag-summary--canvas-row rows)))))
       (and layout (list :layout layout))))))

;;; The element vocabulary

(defun supertag-summary--item (text face element)
  "Return a static one-line item showing TEXT in FACE, laid out as ELEMENT asks."
  (append (list :type 'supertag-view-tag-cards-item :format "%v"
                :value (if face (propertize text 'face face) text))
          (when-let* ((layout (plist-get element :layout)))
            (list :layout layout))))

(defun supertag-summary--expand-line (element)
  "Expand the one-line text ELEMENT."
  (let ((text (format "%s" (or (plist-get element :value) "")))
        (face (supertag-summary--tone-face (plist-get element :tone))))
    (when (string-empty-p text) (setq text " "))
    (list (supertag-summary--item
           (supertag-summary--fit (if face (propertize text 'face face) text)
                                  (plist-get element :width))
           nil element))))

(defun supertag-summary--expand-fill (element)
  "Expand the filled label ELEMENT."
  (list (supertag-summary--item
         (supertag-summary--fit
          (propertize (upcase (format "%s" (or (plist-get element :label) "")))
                      'face (pcase (plist-get element :tone)
                              (2 'supertag-view-chip2)
                              (3 'supertag-view-chip3)
                              (_ 'supertag-view-chip1)))
          (plist-get element :width) " " " ")
         nil element)))

(defun supertag-summary--expand-link (element)
  "Expand the node link ELEMENT into a bracket-free link button."
  (let ((label (supertag-summary--fit
                (format "%s" (or (plist-get element :label) ""))
                (plist-get element :width)))
        (id (plist-get element :node-id)))
    (list (append (list :type 'supertag-view-tag-cards-link
                        :tag label :value label
                        :action (lambda (&rest _) (supertag-goto-node id t)))
                  (when-let* ((layout (plist-get element :layout)))
                    (list :layout layout))))))

(defun supertag-summary--expand-bar (element)
  "Expand the ratio bar ELEMENT."
  (let* ((width (max 1 (or (plist-get element :width) 12)))
         (most (max 1 (or (plist-get element :max) 1)))
         (value (min most (max 0 (or (plist-get element :value) 0))))
         (filled (round (* width (/ (float value) most)))))
    (list (supertag-summary--item
           (concat (propertize (make-string filled ?=)
                               'face 'supertag-view-accent)
                   (propertize (make-string (- width filled) ?-)
                               'face 'supertag-view-mute))
           nil element))))

(defun supertag-summary--expand-heat (element)
  "Expand the density row ELEMENT."
  (let ((most (max 1 (or (plist-get element :max) 1)))
        (cell (or (plist-get element :cell) 2)))
    (list (supertag-summary--item
           (mapconcat
            (lambda (value)
              (if (<= value 0)
                  (propertize (make-string cell ?·) 'face 'supertag-view-mute)
                (make-string
                 cell
                 (aref "░▒▓█"
                       (1- (min 4 (max 1 (ceiling (* 4 (/ (float value)
                                                         most))))))))))
            (plist-get element :values) "")
           nil element))))

(defun supertag-summary--expand-rule (element)
  "Expand the ornament rule ELEMENT."
  (let ((width (max 1 (or (plist-get element :width) 24))))
    (list (supertag-summary--item
           (truncate-string-to-width
            (apply #'concat (make-list (1+ (/ width 4)) "+ . "))
            width)
           'supertag-view-rule element))))

(defun supertag-summary--expand-row (element)
  "Expand the canvas row ELEMENT: toned segments joined into one line."
  (let ((text (mapconcat
               (pcase-lambda (`(,text . ,tone))
                 (let ((face (pcase tone
                               (:mute 'supertag-view-mute)
                               (:strong 'supertag-view-accent)
                               (1 'supertag-view-chip1)
                               (2 'supertag-view-chip2)
                               (3 'supertag-view-chip3))))
                   (if face (propertize text 'face face) text)))
               (plist-get element :segments) "")))
    (list (supertag-summary--item (if (string-empty-p text) " " text)
                                  nil element))))

(defun supertag-summary--todo-states (node)
  "Return the TODO keywords of the file NODE lives in."
  (or (when-let* ((file (plist-get node :file))
                  ((file-readable-p file)))
        (with-current-buffer (find-file-noselect file)
          (and (boundp 'org-todo-keywords-1)
               (copy-sequence org-todo-keywords-1))))
      '("TODO" "DONE")))

(defun supertag-summary--set-todo (id)
  "Ask for a new TODO state of node ID, write it to Org, and redraw."
  (let* ((node (or (supertag-node-get id)
                   (user-error "This note is no longer in the database")))
         (states (supertag-summary--todo-states node))
         (current (plist-get node :todo))
         (none "(no state)")
         (choice (completing-read
                  (format "State of \"%s\" (now %s): "
                          (truncate-string-to-width
                           (supertag-summary--node-title node) 40 nil nil "…")
                          (or current "none"))
                  (append states (list none)) nil t nil nil
                  (or (cadr (member current states)) (car states)))))
    (supertag-service-org-set-todo-state
     id (if (equal choice none) 'none choice))
    (when (derived-mode-p 'textui-mode)
      (textui-refresh (current-buffer)))))

(defun supertag-summary--expand-todo (element)
  "Expand the state button ELEMENT, showing the state the node has now."
  (let* ((id (plist-get element :node-id))
         (width (or (plist-get element :width) 5))
         (state (or (plist-get (supertag-node-get id) :todo) "-"))
         (label (truncate-string-to-width state width nil ?\s)))
    ;; The focus id lets TextUI put point back on this button after a redraw.
    (list (append (supertag-view-tag-cards--button
                   label
                   (lambda (&rest _) (supertag-summary--set-todo id)))
                  (when-let* ((layout
                               (append (and (plist-get element :focus)
                                            (list :focus-id (list 'todo id)))
                                       (plist-get element :layout))))
                    (list :layout layout))))))

(textui-register-expander 'supertag-summary-todo #'supertag-summary--expand-todo)
(textui-register-expander 'supertag-summary-row #'supertag-summary--expand-row)
(textui-register-expander 'supertag-summary-line #'supertag-summary--expand-line)
(textui-register-expander 'supertag-summary-fill #'supertag-summary--expand-fill)
(textui-register-expander 'supertag-summary-link #'supertag-summary--expand-link)
(textui-register-expander 'supertag-summary-bar #'supertag-summary--expand-bar)
(textui-register-expander 'supertag-summary-heat #'supertag-summary--expand-heat)
(textui-register-expander 'supertag-summary-rule #'supertag-summary--expand-rule)

;;; Components

(defun supertag-summary--component-names ()
  "Return the names of the kept components as symbols, sorted."
  (mapcar #'intern
          (cl-remove-if-not
           (lambda (name) (string-match-p "\\`[a-z][a-z0-9-]*\\'" name))
           (supertag-summary--names-in
            (supertag-summary--components-directory)))))

(defun supertag-summary--component-form (name)
  "Return the (lambda ...) form kept for component NAME, or nil.
Nothing is run.  A file that cannot be read is left out."
  (pcase (supertag-summary--read (supertag-summary--component-file name)
                                 'component)
    (`(:ok ,data)
     (ignore-errors (car (read-from-string (plist-get data :code)))))))

(defun supertag-summary--components ()
  "Return every component as (NAME . FORM), the one being checked included."
  (let ((components
         (delq nil
               (mapcar (lambda (name)
                         (when-let* ((form (supertag-summary--component-form
                                            name)))
                           (cons name form)))
                       (supertag-summary--component-names)))))
    (when-let* ((candidate supertag-summary--candidate))
      (setq components
            (append (assq-delete-all (car candidate) components)
                    (list candidate))))
    components))

(defun supertag-summary--components-manual ()
  "Return what the model is told about the kept components, or an empty string."
  (if-let* ((components (supertag-summary--components)))
      (concat
       "\n* 可用的组件\n\n\
下面这些是以前写好的组件。它们已经绑定在同名的变量上，用 (funcall 名字 参数 …) 调用，\
返回一个元素的列表：可以直接当作某个容器的 :children，或者用 append 拼进别的列表。\
合用的时候优先用组件，不要重新画一遍。\n\n"
       (mapconcat
        (pcase-lambda (`(,name . ,form))
          (format "  (funcall %s%s)\n      %s" name
                  (mapconcat (lambda (argument) (format " %s" argument))
                             (cadr form) "")
                  (replace-regexp-in-string
                   "\n" "\n      "
                   (if (stringp (nth 2 form)) (nth 2 form) "（没有说明）"))))
        components "\n")
       "\n")
    ""))

;;; Running layout code

(defun supertag-summary--run-child (arguments)
  "Run the runner on ARGUMENTS in a child Emacs.
Return (STATUS . OUTPUT).  STATUS is nil when the child had to be stopped."
  (let ((runner (or (locate-library "supertag-summary-runner")
                    (error "supertag-summary-runner is not on the load path"))))
    (with-temp-buffer
      (let* ((process
              (make-process
               :name "supertag-summary"
               :buffer (current-buffer)
               :command (append
                         (list (expand-file-name invocation-name
                                                 invocation-directory)
                               "-Q" "--batch" "-l" runner
                               "-f" "supertag-summary-runner-main")
                         arguments)
               :connection-type 'pipe
               :noquery t
               :sentinel #'ignore))
             (deadline (+ (float-time) supertag-summary-run-timeout)))
        ;; Only this process is served, and no timer runs, so nothing else
        ;; can redraw the panel while it waits for its own layout.
        (while (and (process-live-p process) (< (float-time) deadline))
          (accept-process-output process 0.05 nil 1))
        (if (process-live-p process)
            (progn (delete-process process) (cons nil ""))
          (accept-process-output process 0 nil 1)
          (cons (process-exit-status process)
                (string-trim (buffer-string))))))))

(defun supertag-summary--unbalanced (code)
  "Return why CODE is not one whole expression, or nil when it is.
The child Emacs would only say it reached the end of the file, which gives
the model nothing to correct."
  (with-temp-buffer
    (with-syntax-table emacs-lisp-mode-syntax-table
      (insert code)
      (let* ((state (syntax-ppss (point-max)))
             (depth (car state))
             (line (lambda (pos) (line-number-at-pos pos))))
        (cond
         ((nth 3 state)
          (format "字符串没有闭合：从第 %d 行开始的字符串一直到代码末尾都没有结束的引号"
                  (funcall line (nth 8 state))))
         ((> depth 0)
          (format "括号不配对：代码结尾处少了 %d 个右括号。最内层没有闭合的左括号在第 %d 行"
                  depth (funcall line (nth 1 state))))
         ((< depth 0)
          (goto-char (point-min))
          (let ((level 0) (where nil))
            (while (and (not where) (< (point) (point-max)))
              (let ((s (syntax-ppss)))
                (unless (or (nth 3 s) (nth 4 s))
                  (pcase (char-after)
                    (?\( (cl-incf level))
                    (?\) (cl-decf level)
                         (when (< level 0) (setq where (point)))))))
              (forward-char 1))
            (format "括号不配对：多了 %d 个右括号，第一个多出的在第 %d 行"
                    (- depth) (funcall line (or where (point-max))))))
         (t
          (let ((end (condition-case nil
                         (cdr (read-from-string code))
                       (error nil))))
            (when (and end (string-match-p "[^ \t\n]" (substring code end)))
              (format "第一个表达式在第 %d 行就结束了，后面还有别的内容；只输出一个完整的表达式"
                      (funcall line (1+ end)))))))))))

(defun supertag-summary--field (panel code width)
  "Run CODE for PANEL at WIDTH in a child Emacs and check what it returns.
Return (:ok ELEMENTS UNRESOLVED) or (:failed TEXT)."
  (if-let* ((problem (supertag-summary--unbalanced code)))
      (list :failed problem)
    (supertag-summary--run-field panel code width)))

(defun supertag-summary--run-field (panel code width)
  "Run CODE, one whole expression, for PANEL at WIDTH.
See `supertag-summary--field'."
  (let ((code-file (make-temp-file "supertag-summary-" nil ".el"))
        (out-file (make-temp-file "supertag-summary-" nil ".out"))
        (components-file (make-temp-file "supertag-summary-" nil ".components"))
        (coding-system-for-write 'utf-8))
    (unwind-protect
        (progn
          (with-temp-file code-file (insert code "\n"))
          (with-temp-file components-file
            (let ((print-length nil) (print-level nil))
              (prin1 (supertag-summary--components) (current-buffer))))
          (pcase-let ((`(,status . ,text)
                       (supertag-summary--run-child
                        (list code-file (plist-get panel :data-file) out-file
                              (number-to-string width) components-file))))
            (cond
             ((null status)
              (list :failed (format "代码运行超过 %s 秒，被停止了"
                                    supertag-summary-run-timeout)))
             ((not (eql status 0))
              (list :failed (if (string-match "ERROR: \\(.*\\)" text)
                                (match-string 1 text)
                              (format "子进程以 %s 结束 %s" status text))))
             ((> (file-attribute-size (file-attributes out-file)) 2000000)
              (list :failed "返回的内容超过 2MB"))
             (t
              (condition-case err
                  (let* ((read-circle nil)
                         (frame (with-temp-buffer
                                  (insert-file-contents out-file)
                                  (goto-char (point-min))
                                  (read (current-buffer))))
                         (supertag-summary--budget 4000)
                         (supertag-summary--unresolved 0)
                         (supertag-summary--buttoned nil))
                    (unless (and (proper-list-p frame) frame)
                      (error "函数必须返回非空的元素列表：%s"
                             (supertag-summary--show frame)))
                    (list :ok
                          (mapcar (lambda (element)
                                    (supertag-summary--clean
                                     element (plist-get panel :index) 0))
                                  frame)
                          supertag-summary--unresolved))
                (error (list :failed (error-message-string err))))))))
      (delete-file code-file)
      (delete-file out-file)
      (delete-file components-file))))

;;; The page around the model-written field

(defun supertag-summary--pad (text width)
  "Return TEXT right-padded with spaces to WIDTH columns."
  (concat text (make-string (max 0 (- width (string-width text))) ?\s)))

(defun supertag-summary--note (text)
  "Return a field that says TEXT in place of a panel's layout."
  (list (list :type :text :wrap 'greedy :align 'left :value text)))

(defun supertag-summary--show-code (name)
  "Display the code behind panel NAME."
  (let ((panel (supertag-summary--panel name)))
    (with-current-buffer (get-buffer-create
                          (format "*Supertag Summary Code: %s*" name))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert ";; " (or (plist-get panel :sentence) "") "\n")
        (dolist (feedback (reverse (plist-get panel :revisions)))
          (insert ";; revised: " feedback "\n"))
        (insert "\n" (or (plist-get panel :code) "") "\n")
        (emacs-lisp-mode)
        (setq buffer-read-only t)
        (goto-char (point-min)))
      (display-buffer (current-buffer)))))

(defun supertag-summary--page (panel field width)
  "Return the whole page for PANEL at WIDTH around the model-written FIELD."
  (let* ((name (plist-get panel :name))
         (tag (plist-get panel :tag))
         (brand "SUPERTAG / SUMMARY")
         (status (format "PANEL / %s" (upcase name)))
         ;; A panel that cannot be read names no tag.
         (volume (if tag
                     (format "%s / %d NOTES" (upcase (supertag-tag--name tag))
                             (or (plist-get panel :total) 0))
                   "SUMMARY / UNAVAILABLE"))
         (middle (- width (string-width brand) (string-width status) 8)))
    (list
     :type :flex :direction :column :gap 1
     :children
     (append
      (list
       (list :type :flex :direction :row :gap 2
             :children
             (list (list :type 'supertag-summary-fill :label brand :tone 1)
                   (list :type 'supertag-summary-line :tone :mute
                         :value (supertag-summary--pad volume middle))
                   (list :type 'supertag-summary-fill :label status :tone 3)))
       (list :type :flex :direction :column :gap 0
             :children
             (list (supertag-summary--item
                    (supertag-summary--pad "YOUR NOTES, AS THEY ARE NOW." width)
                    'supertag-view-panel nil)
                   (supertag-summary--item
                    (supertag-summary--pad "DRAWN THE WAY YOU ASKED." width)
                    'supertag-view-panel nil)
                   (list :type :text :wrap 'greedy :align 'left
                         :value (let ((sentence (plist-get panel :sentence)))
                                  (if (and sentence
                                           (not (string-empty-p sentence)))
                                      sentence
                                    " ")))))
       (list :type :flex :direction :row :gap 2
             :children
             (list (supertag-view-tag-cards--button
                    "REVISE"
                    (lambda (&rest _)
                      (supertag-summary-revise
                       name (read-string "What to change: "))))
                   (supertag-view-tag-cards--button
                    "CODE"
                    (lambda (&rest _) (supertag-summary--show-code name)))
                   (supertag-view-tag-cards--button
                    "REFRESH"
                    (lambda (&rest _) (textui-refresh (current-buffer)))))))
      field
      (list
       (list :type :flex :direction :column :gap 0
             :children
             (list (list :type 'supertag-summary-line :value " ")
                   (list :type 'supertag-summary-rule :width (min width 48))
                   (list :type 'supertag-summary-line :tone :mute :width width
                         :value
                         (format "01 / SUMMARY  records from the store + layout by model%s"
                                 (if-let* ((seconds (plist-get panel :seconds)))
                                     (format "  ·  drawn in %.2fs" seconds)
                                   "")))
                   (list :type 'supertag-summary-line :value "SUPERTAG"
                         :tone :strong))))))))

;;; Panels

(defun supertag-summary--make (name tag sentence)
  "Return a panel named NAME over the Tag ID TAG made from SENTENCE.
Every key a later `plist-put' sets is present, so the plist changes in place."
  (list :name name :tag tag :sentence sentence :revisions nil :code nil
        :index nil :total 0 :signature nil :seconds nil
        :cache (make-hash-table :test 'equal)
        :data-file (supertag-summary--data-file name)
        :describe nil :problem nil :mtime nil :transient nil))

(defun supertag-summary--restore (name)
  "Return panel NAME rebuilt from its file, or nil without a file.
A file that cannot be used gives a panel that only states the problem."
  (let ((file (supertag-summary--file name)))
    (when (file-exists-p file)
      (let ((panel (supertag-summary--make name nil nil)))
        (plist-put panel :mtime (supertag-summary--mtime file))
        (pcase (supertag-summary--read file 'panel)
          (`(:ok ,data)
           (plist-put panel :tag (plist-get data :tag))
           (plist-put panel :sentence (plist-get data :sentence))
           (plist-put panel :revisions (plist-get data :revisions))
           (plist-put panel :code (string-trim (plist-get data :code))))
          (`(:failed ,reason)
           (plist-put panel :problem
                      (format "%s is skipped: %s."
                              (file-name-nondirectory file) reason))))
        (puthash name panel supertag-summary--panels)))))

(defun supertag-summary--panel (name)
  "Return panel NAME as it is kept now, or nil.
A panel whose file changed since it was read, as after a Git pull, is read
again."
  (let ((panel (gethash name supertag-summary--panels)))
    (if (and panel
             (or (plist-get panel :transient)
                 (equal (plist-get panel :mtime)
                        (supertag-summary--mtime (supertag-summary--file name)))))
        panel
      (or (supertag-summary--restore name)
          (progn (remhash name supertag-summary--panels) nil)))))

(defun supertag-summary--keep (panel)
  "Write PANEL to its file unless it is a transient demo."
  (unless (plist-get panel :transient)
    (let ((file (supertag-summary--file (plist-get panel :name))))
      (supertag-summary--write
       file
       (list :format 1 :kind 'panel
             :name (plist-get panel :name)
             :tag (plist-get panel :tag)
             :sentence (plist-get panel :sentence)
             :revisions (plist-get panel :revisions)
             :code (plist-get panel :code)))
      (plist-put panel :mtime (supertag-summary--mtime file)))))

(defun supertag-summary--accept (panel code)
  "Keep CODE as the accepted layout of PANEL and show it."
  (plist-put panel :code code)
  (plist-put panel :cache (make-hash-table :test 'equal))
  (supertag-summary--keep panel)
  (puthash (plist-get panel :name) panel supertag-summary--panels)
  (supertag-summary-open (plist-get panel :name)))

(defun supertag-summary--draw (panel width)
  "Return the field of PANEL at WIDTH, drawn from the notes as they are now.
The layout code runs again only when the records changed since the last
drawing at WIDTH."
  (cond
   ((plist-get panel :problem)
    (supertag-summary--note (plist-get panel :problem)))
   ((not (supertag-tag-get (plist-get panel :tag)))
    (supertag-summary--note
     (format "The tag this panel was made for no longer exists: %s."
             (plist-get panel :tag))))
   (t
    (let* ((key (cons width (supertag-summary--sync panel)))
           (cache (plist-get panel :cache))
           (outcome (or (gethash key cache)
                        (progn
                          (clrhash cache)
                          (puthash key
                                   (supertag-summary--field
                                    panel (plist-get panel :code) width)
                                   cache)))))
      (pcase outcome
        (`(:ok ,elements . ,_) elements)
        (`(:failed ,reason)
         (supertag-summary--note
          (format "These records cannot be drawn: %s" reason))))))))

(defun supertag-summary--frame (width)
  "Return the page of the panel named in `textui-state' at WIDTH."
  (let* ((name (plist-get textui-state :panel))
         (panel (or (supertag-summary--panel name)
                    (let ((gone (supertag-summary--make name nil nil)))
                      (plist-put gone :problem
                                 (format "Panel %s is no longer kept." name))
                      gone)))
         (started (float-time))
         (field (supertag-summary--draw panel width)))
    (plist-put panel :seconds (- (float-time) started))
    (list (supertag-summary--page panel field width))))

(defvar supertag-summary-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'widget-forward)
    (define-key map (kbd "<backtab>") #'widget-backward)
    map)
  "Keymap for `supertag-summary-mode'.")

(define-derived-mode supertag-summary-mode textui-mode "Supertag-Summary"
  "A summary panel: the notes of a tag, laid out by a model.
TAB and S-TAB move among links and buttons; RET and mouse-1 activate."
  :group 'supertag-summary
  (setq-local buffer-read-only t
              cursor-type 'box
              line-spacing 0.1)
  (supertag-view-tag-cards--enforce-no-wrap)
  (supertag-view-apply-palette-locally supertag-summary-palette))

(supertag-view-register-modal-state 'supertag-summary-mode)
(put 'supertag-summary-mode 'completion-predicate #'ignore)

;;; Acceptance

(defun supertag-summary--text (panel field width)
  "Return the page of PANEL around FIELD laid out as attributed text at WIDTH.
The layout uses the metrics in effect, so in a graphical session this is what
a window WIDTH cells wide would show."
  (with-temp-buffer
    (supertag-summary-mode)
    (textui--render-frame
     (list (supertag-summary--page panel field width))
     width)))

(defun supertag-summary--lines (text)
  "Return the lines of TEXT without trailing blanks, each with its width.
The width is in layout columns, rounded up."
  (pcase-let ((`(,measure . ,cell) (supertag-summary--metrics)))
    (mapcar (lambda (line)
              (let ((line (string-trim-right line)))
                (cons (ceiling (/ (float (funcall measure line)) cell))
                      (substring-no-properties line))))
            (split-string text "\n"))))

(defun supertag-summary--check (panel code)
  "Return (:ok) when CODE draws PANEL within 120 and 80 columns.
Otherwise return (:failed TEXT) with a reason the model can act on."
  (catch 'verdict
    (dolist (width '(120 80))
      (pcase (supertag-summary--field panel code width)
        (`(:failed ,reason)
         (throw 'verdict (list :failed (format "宽度 %d：%s" width reason))))
        (`(:ok ,field . ,_)
         (let* ((text (condition-case err
                          (supertag-summary--text panel field width)
                        (error
                         (throw 'verdict
                                (list :failed
                                      (format "宽度 %d 时 TextUI 排不出来：%s"
                                              width
                                              (error-message-string err)))))))
                (wide (cl-sort
                       (cl-remove-if-not
                        (lambda (line) (> (car line) width))
                        (supertag-summary--lines text))
                       #'> :key #'car)))
           (when wide
             (throw 'verdict
                    (list :failed
                          (format "宽度 %d 时有 %d 行超出，最宽的一行有 %d 列：「%s」。\
单行元素不会自动变窄，请给它们更小的 :width，或者少并排几个。"
                                  width (length wide)
                                  (caar wide)
                                  (truncate-string-to-width
                                   (string-trim (cdar wide)) 100 nil nil
                                   "…")))))))))
    (list :ok)))

;;; Asking the model

;; The manual is shared by the two things a model may be asked to write: a
;; panel, and a component that panels call.
(defconst supertag-summary--data-manual
  "* 数据

data 是一个属性列表：
  :title 字符串；:today \"YYYY-MM-DD\"；:total 记录总数；:states 这批记录里出现过的 TODO 状态，从多到少；:records 记录的列表。
这些记录直接来自笔记库，没有模型读过它们：没有摘要，只有事实。每次打开、每次改完状态，都会用最新的记录重新调用你的函数，\
所以分组、排序、计数都要在函数里从 :records 现算，不能把任何一条记录、任何一个数写死在代码里。
每条记录是属性列表：
  :ref 字符串，交给链接和状态按钮的 :node
  :title 标题
  :todo 状态字符串（\"TODO\"、\"DONE\" 这类）或 nil；哪些算完成由用户的话决定，没说就只把 \"DONE\" 当作完成
  :priority \"A\"、\"B\"、\"C\" 或 nil
  :tags 标签名的列表
  :root 为 t 表示这条记录本身带着这个标签（比如项目本身），nil 表示它是别的记录
  :owner 这条记录按大纲位置所属的那条 :root 记录的 :ref；自己是 :root，或者上面没有 :root 记录时是 nil
  :day 记录的日期，:scheduled 计划日期，:deadline 截止日期，都是 \"YYYY-MM-DD\" 或 nil
  :props 这条记录的属性，((\"属性名\" . 值) …)，见下面的「属性」
  :file 所在的文件名
任何字段都可能是 nil。数先用 (or x 0)，字符串先用 (or x \"\") 处理。
"
  "What a model is told about the data a panel draws.")

(defun supertag-summary--manual (intro example)
  "Return a system prompt: INTRO, the manual of elements and rules, EXAMPLE."
  (format "%s

面板显示在 Emacs 的等宽文本界面里。width 是可用宽度，单位是字符列；窗口变宽变窄时会用新的 width 重新调用你的函数。\
页眉、按钮和页脚已经有了，你只写正文。你返回的顶层元素会竖着排，彼此之间空一行。

* 元素

每个元素是一个带 :type 的属性列表。只有下面十一种；别的类型、别的属性都会被拒绝。

布局元素：
  (:type :flex :direction :row 或 :column :gap N :padding N :border t :children (元素 …))
      :row 横排，一行放不下时后面的子元素自动换到下一行，:gap 是子元素之间的空格数。
      :column 竖排，:gap 是子元素之间的空行数。:gap 不写时是 1，想紧挨着就写 :gap 0。
  (:type :grid :columns N :min-column-width N :column-gap N :row-gap N :children (元素 …))
      等宽的列，子元素按顺序填入。:columns 是最多几列；窗口变窄时自动减少列数，每列不窄于 :min-column-width。
  任何元素都可以带 :layout (:width N :grow N)，供它的父容器使用：:width 是起始宽度，:grow 是分配剩余宽度的权重。

内容元素：
  (:type :text :value \"…\" :tone :normal 或 :mute 或 :strong)
      段落，会按它分到的宽度自动折行。长句子用它。
  (:type supertag-summary-line :value \"…\" :tone … :width N)
      单行文字，不折行。给了 :width 就截断到这么多列并补上 …。
  (:type supertag-summary-fill :label \"…\" :tone 1 或 2 或 3 :width N)
      色块标签：强调色背景上的深色字，两侧各留一格，英文自动转成大写。
  (:type supertag-summary-link :node REF :label \"…\" :marker \"→\" :width N)
      可以点击的链接，点了跳到那条笔记。REF 是记录的 :ref。单行，不折行。
  (:type supertag-summary-todo :node REF :width N)
      状态按钮，画成 [ TODO ]：显示这条记录现在的 TODO 状态，没有状态时是 [ - ]。点它可以改状态，改完面板会重画。\
显示哪个状态由系统决定，永远是最新的，不用也不能由你传。状态文字占 :width 列（默认 5，最多 12，长了截断），整个按钮占 :width + 4 列。
  (:type supertag-summary-bar :value N :max N :width N)
      比例条，画成 ====----，占 :width 列。
  (:type supertag-summary-heat :values (N …) :max N :cell 1 或 2)
      一行密度格：每个数一格，每格占 :cell 列，数越大越深，0 是一个淡点。几行叠起来就是热力图。
  (:type supertag-summary-rule :width N)
      一条 + . + . 装饰线。
  (:type supertag-summary-canvas :rows (行 …))
      字符画布，给上面这些元素画不出来的图用：坐标轴和刻度、按周排的日历、迷你折线、分段的比例条、树状连线。\
每行是若干段的列表，一段是 \"文字\" 或 (\"文字\" 色调)；色调是 :normal、:mute、:strong 之一（文字的轻重），或 1、2、3（和色块一样的底色）。\
各行原样输出，一行一行紧挨着，不折行也不裁剪，所以每一行的宽度要自己算好。\
要让上下各行对齐，这些行里就只用半角字符：英文、数字、空格，以及 ░ ▒ ▓ █ ▁ ▂ ▃ ▄ ▅ ▆ ▇ · ─ │ ┌ ┐ └ ┘ ├ ┤ 这类符号；中文放在画布外面，或者只放在一行的最右端。\
画布不能点击，要链接就在画布旁边另放链接元素。最多 200 行。

* 设计规则

- 只有一种字号，没有彩色文字。层次只靠四样东西：色块、大小写、留白、位置。
- 色块只用于名称和标题，不用于正文和说明。标签写成 \"NOUN / NOUN\" 或 \"NOUN / 007\"，斜杠两侧各一个空格。相邻的块轮换 1、2、3：1 是当前的、主要的，2 是结构和容器，3 是信息和计数。
- 一张卡片分三部分，各部分之间空一行：一行次要信息（:mute），色块标题，然后是内容和条目。条目用链接，:marker 是 \"→\"。
- 默认不用边框，卡片之间靠留白和色块标题分开。
- 空的字段、没有内容的组不要画成空壳；值得一提的话，合在一行次要文字里。
- 这是一块信息面板，不是一张字段表。按用户的话和这批信息的性质决定版式：先给出一眼能看到的全局（总数、分布、谁最需要注意），再给细节。能用比例条、密度格表达的数量就不要只写成数字。

* 宽度

- 中文和全角符号每个按 2 列估算，英文、数字和这些符号 = - + . → … 各占 1 列。用 string-width 量。屏幕上中文往往比 2 列略宽，所以估算要留余量。
- 给了 :width 的单行元素，会按屏幕上的真实宽度裁剪到这么多列，一定不会超出。没给 :width 的不会被裁剪。
- 任何一行都不能超过 width 列，否则整块面板被拒绝。
- :text 会自动折行。其余内容元素都是单行的，不会自动变窄；凡是内容长度不定的（标题、链接），要么用 :text，要么给 :width。
- 用 :grid 时自己由 width 决定列数，把同一个数同时用作 :columns，并让 :min-column-width 足够小。每列的宽度是 (/ (- width (* 列间距 (1- 列数))) 列数)，列里的单行元素 :width 不能超过它。
- 横排（:row）里并排的单行元素，宽度加上间距之和不能超过它们所在容器的宽度。

%s日期是字符串。要算星期或相隔几天，先 (date-to-time (concat day \" 00:00:00\"))，只有 \"YYYY-MM-DD\" 这种完整日期才能这样转；\
(format-time-string \"%%u\" 时间) 得到星期几（1 是周一，7 是周日），(float-time 时间) 除以 86400 得到天数。

* 代码

- 只能使用这些函数、宏和特殊形式，以及任何 seq- 开头的函数；用了别的会被拒绝：%s
- 不能用 while、defun、pcase、catch、error、message、insert、intern、eval、propertize。
- 检查是按名字做的：代码里出现的任何名字，只要它是 Emacs 里一个不在上面名单内的函数，就会被拒绝，哪怕你只是把它当变量名。所以变量不要叫 record、count、elt、values、fill、rest、first、position、remove、delete、search、replace 这类名字，用 entry、item、total、amount 这样的。
- 可以用反引号构造元素。
%s
* 写法示例（只说明语法，不要照抄它的版式）

%s"
          intro
          supertag-summary--data-manual
          (mapconcat #'symbol-name supertag-summary-runner-allowed " ")
          (supertag-summary--components-manual)
          example))

(defconst supertag-summary--example
  "(lambda (data width)
  (let* ((entries (plist-get data :records))
         (open (cl-remove-if (lambda (entry)
                               (or (plist-get entry :root)
                                   (null (plist-get entry :todo))
                                   (equal (plist-get entry :todo) \"DONE\")))
                             entries))
         (label (max 10 (- width 12))))
    (list
     `(:type supertag-summary-line :tone :mute
       :value ,(format \"%d open of %d\" (length open) (length entries)))
     `(:type :flex :direction :column :gap 0
       :children
       ,(mapcar (lambda (entry)
                  `(:type :flex :direction :row :gap 1
                    :children
                    ((:type supertag-summary-todo :node ,(plist-get entry :ref))
                     (:type supertag-summary-link :width ,label
                      :node ,(plist-get entry :ref)
                      :label ,(or (plist-get entry :title) \"\")))))
                open)))))"
  "The syntax example shown to a model that writes a panel.")

(defun supertag-summary--system ()
  "Return the system prompt asking for panel code."
  (supertag-summary--manual
   "你为用户的笔记编写一块信息面板。用户用一句话说了他想在这里看到什么、处理什么。\
写一个 Emacs Lisp 表达式 (lambda (data width) ...)，它返回一个界面元素的列表。\
只输出这个表达式，不要解释，不要代码块标记。

这块面板不只是用来看的，用户可以在上面动手。凡是他可能点开的条目，都给它一个能点开的链接；\
凡是他要处理的条目（任务这类有状态的记录），再给它一个状态按钮，并且按「接下来该处理哪条」来排，而不是按记录的先后。

面板只读属性，不写属性。用户的话要的属性还没有时，在页面上说出来，不要假装有。\n\n"
   (concat supertag-summary-property-guide "\n\n" supertag-summary--example)))

(defun supertag-summary--strip-fence (response)
  "Return the code in RESPONSE without any code fence around it."
  (let ((text (string-trim (or response ""))))
    (when (string-match "\\````[a-z-]*\n" text)
      (setq text (substring text (match-end 0))))
    (when (string-match "\n```\\'" text)
      (setq text (substring text 0 (match-beginning 0))))
    text))

(defun supertag-summary--provider ()
  "Return what sends the model request: `superchat', `gptel' or a function."
  (pcase supertag-summary-provider
    ('auto
     ;; lazy-require: both packages are optional and only writing code needs one.
     (cond ((progn (require 'superchat nil t) (fboundp 'superchat-runtime-submit))
            'superchat)
           ((require 'gptel nil t) 'gptel)
           (t (user-error "Writing a panel or an agent needs superchat or gptel loaded"))))
    ('gptel
     (unless (require 'gptel nil t)
       (user-error "`supertag-summary-provider' is gptel, but gptel cannot be loaded"))
     'gptel)
    (provider provider)))

(defun supertag-summary--ask (prompt system callback)
  "Send PROMPT with SYSTEM to the model.
Call CALLBACK with the reply text and the status, `completed' on success."
  (pcase (supertag-summary--provider)
    ('superchat (supertag-summary--ask-superchat prompt system callback))
    ('gptel (supertag-summary--ask-gptel prompt system callback))
    (provider (funcall provider prompt system callback))))

(defun supertag-summary--ask-gptel (prompt system callback)
  "Send PROMPT with SYSTEM through gptel; call CALLBACK as `--ask' does.
The gptel preset named `supertag', when there is one, chooses the model;
otherwise the user's gptel defaults do.  No tools are offered."
  (let* ((buffer (generate-new-buffer " *supertag-model*"))
         (done nil)
         timer
         (finish (lambda (text status)
                   (unless done
                     (setq done t)
                     (when timer (cancel-timer timer))
                     (when (buffer-live-p buffer) (kill-buffer buffer))
                     (funcall callback text status))))
         (send
          (lambda ()
            (let ((gptel-use-tools nil)
                  (gptel-include-reasoning nil))
              (gptel-request prompt
                :buffer buffer :system system :stream nil
                :callback
                (lambda (response info)
                  (cond ((stringp response) (funcall finish response 'completed))
                        ((null response)
                         (funcall finish (format "%s" (plist-get info :status))
                                  'failed))
                        ;; abort is ours (timeout); reasoning is not the reply.
                        (t nil))))))))
    (setq timer
          (run-at-time supertag-summary-timeout nil
                       (lambda ()
                         (when (buffer-live-p buffer) (ignore-errors (gptel-abort buffer)))
                         (funcall finish (format "No reply within %d seconds"
                                                 supertag-summary-timeout)
                                  'timeout))))
    (if (and (fboundp 'gptel-get-preset) (gptel-get-preset 'supertag))
        ;; gptel-with-preset is a macro of an optional package; expand it here.
        (eval `(gptel-with-preset 'supertag (funcall ,send)) t)
      (funcall send))))

(defun supertag-summary--ask-superchat (prompt system callback)
  "Send PROMPT with SYSTEM through Superchat; call CALLBACK as `--ask' does."
  (supertag-ai--ensure-runtime)
  (supertag-ai--submit
   (list :type :llm-query :input "supertag summary"
         :prompt prompt :system-prompt system
         :buffer (supertag-ai--host-buffer) :tools 'none
         :record-conversation nil
         :origin (list :surface 'supertag :prompt 'summary)
         :deadline supertag-summary-timeout
         :sink (superchat-sink-create
                :final (lambda (_run result)
                         (funcall callback (plist-get result :text) 'completed))
                :error (lambda (_run failure)
                         (funcall callback (plist-get failure :text)
                                  (plist-get failure :status)))))))

(defun supertag-summary--note-attempt (verdict text)
  "Record VERDICT and the reply TEXT it judged in `supertag-summary--last'.
Every reply is kept, so a refused one can be looked at afterwards."
  (setq supertag-summary--last
        (plist-put supertag-summary--last :attempts
                   (cons verdict (plist-get supertag-summary--last :attempts))))
  (setq supertag-summary--last
        (plist-put supertag-summary--last :codes
                   (cons text (plist-get supertag-summary--last :codes)))))

(defun supertag-summary--finish (outcome)
  "Record OUTCOME, `:ok' or `:failed', of the request in progress."
  (setq supertag-summary--last
        (plist-put supertag-summary--last :done outcome)))

(defun supertag-summary--attempt (panel base prompt tries)
  "Ask for the layout of PANEL with PROMPT; retry TRIES more times.
BASE is the request without any report of an earlier failure."
  (supertag-summary--ask
   prompt (supertag-summary--system)
   (lambda (response status)
     (let* ((code (supertag-summary--strip-fence response))
            (verdict (if (eq status 'completed)
                         (supertag-summary--check panel code)
                       (list :failed (format "%s" response)))))
       (supertag-summary--note-attempt verdict code)
       (cond
        ((eq (car verdict) :ok)
         (supertag-summary--accept panel code)
         (supertag-summary--finish :ok)
         (message "Supertag summary %s: drawn" (plist-get panel :name)))
        ((and (eq status 'completed) (> tries 0))
         (supertag-summary--attempt
          panel base
          (format "%s\n\n你上次写的代码是：\n%s\n\n它被拒绝了：%s\n请改正后重新输出完整的表达式。"
                  base code (cadr verdict))
          (1- tries)))
        (t
         (supertag-summary--finish :failed)
         (message "Supertag summary %s: no layout was accepted: %s"
                  (plist-get panel :name) (cadr verdict))))))))

(defun supertag-summary--start (name)
  "Begin recording a request about NAME in `supertag-summary--last'."
  (setq supertag-summary--last
        (list :name name :started (float-time) :attempts nil :done nil)))

(defun supertag-summary--panel-name (name)
  "Return NAME when it can name a panel file, or refuse it."
  (let ((name (string-trim name)))
    (when (or (string-empty-p name)
              (string-prefix-p "." name)
              (string-match-p "[/\\:\0\n]" name))
      (user-error "A panel name cannot be empty, start with a dot, or contain / \\ :"))
    name))

(defun supertag-summary--tag-id (tag)
  "Return the Tag ID that the tag name or ID TAG stands for, or refuse it."
  (or (supertag-view-api-tag-id tag)
      (user-error "No tag named %s" tag)))

;;;###autoload
(defun supertag-summary-open (name)
  "Show the summary panel NAME, drawn from the notes as they are now."
  (interactive
   (list (completing-read "Summary panel: " (supertag-summary--names) nil t)))
  (unless (supertag-summary--panel name)
    (user-error "No summary panel named %s" name))
  (let* ((buffer-name (format "*Supertag Summary: %s*" name))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'supertag-summary-mode)
        (supertag-summary-mode)))
    (textui-open buffer-name #'supertag-summary--frame (list :panel name))
    (with-current-buffer buffer
      (supertag-view-tag-cards--enforce-no-wrap)
      (supertag-view-apply-palette-locally supertag-summary-palette))
    buffer))

;;;###autoload
(defun supertag-summary-design (tag name sentence)
  "Have the model lay out summary panel NAME over the notes of TAG.
SENTENCE says what the user wants to see and do there.  No note is sent to
the model except the title, state and tags of six records, as a sample."
  (interactive
   (list (completing-read "Summary of tag: " (supertag-view-api-list-tags)
                          nil t)
         (read-string "Panel name: ")
         (read-string "What to show: ")))
  (let* ((name (supertag-summary--panel-name name))
         (id (supertag-summary--tag-id tag)))
    (when (string-empty-p (string-trim sentence))
      (user-error "Say what the panel should show"))
    (when (and (file-exists-p (supertag-summary--file name))
               (not (yes-or-no-p
                     (format "Summary panel %s exists.  Replace it? " name))))
      (user-error "Kept the existing panel %s" name))
    (let* ((panel (supertag-summary--make name id sentence))
           (data (cdr (supertag-summary--collect id))))
      (when (null (plist-get data :records))
        (user-error "No notes under #%s" tag))
      (supertag-summary--sync panel)
      (plist-put panel :describe (supertag-summary--describe data))
      (supertag-summary--start name)
      (message "Supertag summary %s: asking the model…" name)
      (let ((base (format "用户的话：%s\n\n%s" sentence
                          (plist-get panel :describe))))
        (supertag-summary--attempt panel base base 2)))))

;;;###autoload
(defun supertag-summary-revise (name feedback)
  "Have the model change the summary panel NAME as FEEDBACK asks."
  (interactive
   (list (completing-read "Summary panel: " (supertag-summary--names) nil t)
         (read-string "What to change: ")))
  (let ((current (or (supertag-summary--panel name)
                     (user-error "No summary panel named %s" name))))
    (when (plist-get current :problem)
      (user-error "%s" (plist-get current :problem)))
    (when (string-empty-p (string-trim feedback))
      (user-error "Say what to change"))
    (let* ((panel (copy-sequence current))
           (describe (progn
                       (supertag-summary--sync panel)
                       (supertag-summary--describe
                        (cdr (supertag-summary--collect
                              (plist-get panel :tag))))))
           (base (format "这是现在的面板代码：\n%s\n\n用户看了面板，要求修改：%s\n\n%s\n\n输出修改后的完整表达式。"
                         (plist-get current :code) feedback describe)))
      (setq panel (plist-put panel :revisions
                             (cons feedback (plist-get current :revisions))))
      (supertag-summary--start name)
      (message "Supertag summary %s: asking the model…" name)
      (supertag-summary--attempt panel base base 2))))

;;; Components written by the model

(defconst supertag-summary--component-example
  "(lambda (amounts width)
  \"一行迷你柱状图。AMOUNTS 是不小于 0 的数的列表，每个数画成一格，越大越高；\
全是 0 或空列表时画成一行淡点。WIDTH 是可用宽度，超出的数从左边丢掉。占 1 行。\"
  (let* ((shown (last amounts (max 1 (min width (length amounts)))))
         (peak (apply 'max (cons 1 shown))))
    (list
     `(:type supertag-summary-canvas
       :rows (,(mapcar (lambda (amount)
                         (if (<= amount 0)
                             '(\"·\" :mute)
                           (list (substring \"▁▂▃▄▅▆▇█\"
                                            (min 7 (floor (* 8 (/ (float amount) peak))))
                                            (1+ (min 7 (floor (* 8 (/ (float amount) peak))))))
                                 :strong)))
                       shown))))))

(lambda (data width)
  (list
   `(:type :flex :direction :column :gap 0
     :children
     ,(append
       (list `(:type supertag-summary-line :tone :mute :value \"每条记录的标签数\"))
       (funcall spark
                (mapcar (lambda (entry) (length (plist-get entry :tags)))
                        (plist-get data :records))
                width)))))"
  "The syntax example shown to a model that writes a component named spark.")

(defun supertag-summary--component-system (name)
  "Return the system prompt asking for the component NAME and its demo."
  (supertag-summary--manual
   (format "你为用户的笔记面板编写一个可以反复使用的组件，名字是 %s。用户用一句话说了它画什么。\
输出两个 Emacs Lisp 表达式，一前一后，都从行首的 (lambda 开始；不要解释，不要代码块标记。

第一个是组件：(lambda (参数 … width) \"说明\" …)，返回一个元素的列表。\
参数表后面必须紧跟一个字符串作为说明，它是以后使用这个组件的人唯一能看到的东西，要写清楚：\
它画什么；每个参数是什么（类型、形状、能不能是 nil）；占多宽、多少行。\
组件拿不到 data，要画的东西全部由参数传进来，这样换一批数据、换一块面板也能用；\
参数要取最朴素的形状（数的列表、字符串的列表、日期字符串的列表），不要要求调用的人先把数据整理成这批数据特有的样子。\
最后一个参数是可用宽度，组件在这个宽度内自己决定画多少。

第二个是示例面板：(lambda (data width) …)，用 (funcall %s 参数 …) 调用这个组件，把下面给出的这批数据画出来。\
示例面板要短，只为了让用户看到组件的样子：一行说明加上组件本身就够了。

下面的说明对组件和示例面板都适用。"
           name name)
   (concat "下面是名为 spark 的组件和它的示例面板：\n\n"
           supertag-summary--component-example)))

(defun supertag-summary--forms (response)
  "Return the source of each (lambda ...) that starts a line of RESPONSE.
A form whose brackets do not balance is returned up to the end of RESPONSE."
  (let ((start 0) forms)
    (while (and (< start (length response))
                (string-match "^(lambda\\_>" response start))
      (let* ((from (match-beginning 0))
             (end (condition-case nil
                      (cdr (read-from-string response from))
                    (error (length response)))))
        (push (string-trim (substring response from end)) forms)
        (setq start end)))
    (nreverse forms)))

(defun supertag-summary--check-component (panel name forms)
  "Return (:ok FORM) when FORMS hold a sound component NAME and its demo.
FORMS are the sources of the component and of a demo layout that draws the
records of PANEL with it.  Otherwise return (:failed TEXT)."
  (pcase-let ((`(,source ,demo) forms))
    (condition-case err
        (let ((form (and source (car (read-from-string source)))))
          (cond
           ((not (and source demo (= (length forms) 2)))
            (list :failed (format "需要正好两个从行首开始的 (lambda …) 表达式，\
先组件后示例面板；收到 %d 个。括号不配对也会造成这个结果" (length forms))))
           ((not (stringp (nth 2 form)))
            (list :failed "组件的参数表后面必须紧跟一个说明字符串"))
           ((not (cdddr form))
            (list :failed "组件在说明字符串后面没有代码"))
           ((not (string-match-p (format "(funcall[ \n]+%s\\_>" name) demo))
            (list :failed (format "示例面板没有用 (funcall %s …) 调用组件" name)))
           (t
            (let ((supertag-summary--candidate (cons name form)))
              (pcase (supertag-summary--check panel demo)
                (`(:ok) (list :ok form))
                (verdict verdict))))))
      (error (list :failed (format "读不出表达式，多半是括号不配对：%s"
                                   (error-message-string err)))))))

(defun supertag-summary--keep-component (name source sentence)
  "Keep SOURCE as component NAME, with the SENTENCE it was made from."
  (supertag-summary--write
   (supertag-summary--component-file name)
   (list :format 1 :kind 'component
         :name (format "%s" name)
         :sentence sentence
         :revisions nil
         :code source)))

(defun supertag-summary--component-attempt (panel name base prompt tries)
  "Ask for component NAME and a demo drawing PANEL; retry TRIES more times.
BASE is the request without any report of an earlier failure."
  (supertag-summary--ask
   prompt (supertag-summary--component-system name)
   (lambda (response status)
     (let* ((text (supertag-summary--strip-fence response))
            (forms (supertag-summary--forms text))
            (verdict (if (eq status 'completed)
                         (supertag-summary--check-component panel name forms)
                       (list :failed (format "%s" response)))))
       (supertag-summary--note-attempt verdict text)
       (cond
        ((eq (car verdict) :ok)
         (supertag-summary--keep-component
          name (car forms) (plist-get panel :sentence))
         (supertag-summary--accept panel (cadr forms))
         (supertag-summary--finish :ok)
         (message "Supertag summary component %s: kept; its demo is panel %s"
                  name (plist-get panel :name)))
        ((and (eq status 'completed) (> tries 0))
         (supertag-summary--component-attempt
          panel name base
          (format "%s\n\n你上次的输出是：\n%s\n\n它被拒绝了：%s\n请改正后重新输出完整的两个表达式。"
                  base text (cadr verdict))
          (1- tries)))
        (t
         (supertag-summary--finish :failed)
         (message "Supertag summary component %s: none was accepted: %s"
                  name (cadr verdict))))))))

(defun supertag-summary--component-name (name)
  "Return NAME as a component symbol, or refuse it."
  (unless (string-match-p "\\`[a-z][a-z0-9-]*\\'" name)
    (user-error "A component name is lowercase letters, digits and hyphens: %s"
                name))
  (let ((symbol (intern name)))
    (when (or (memq symbol '(data width nil t))
              (memq symbol supertag-summary-runner-allowed)
              (string-prefix-p "seq-" name))
      (user-error "The name %s already means something else; pick another"
                  name))
    symbol))

;;;###autoload
(defun supertag-summary-component (tag name sentence)
  "Have the model write the component NAME, shown on the notes of TAG.
SENTENCE says what the component draws.  The component is kept for later
panels.  A demo panel named NAME-demo shows it for this session only."
  (interactive
   (list (completing-read "Show it on tag: " (supertag-view-api-list-tags)
                          nil t)
         (read-string "Component name (lowercase, digits, hyphens): ")
         (read-string "What it draws: ")))
  (let* ((symbol (supertag-summary--component-name name))
         (id (supertag-summary--tag-id tag))
         (panel (supertag-summary--make (concat name "-demo") id sentence))
         (data (cdr (supertag-summary--collect id))))
    (when (string-empty-p (string-trim sentence))
      (user-error "Say what the component draws"))
    (when (null (plist-get data :records))
      (user-error "No notes under #%s" tag))
    (when (and (file-exists-p (supertag-summary--component-file name))
               (not (yes-or-no-p
                     (format "Component %s exists.  Replace it? " name))))
      (user-error "Kept the existing component %s" name))
    (plist-put panel :transient t)
    (supertag-summary--sync panel)
    (plist-put panel :describe (supertag-summary--describe data))
    (supertag-summary--start name)
    (message "Supertag summary component %s: asking the model…" name)
    (let ((base (format "组件要画的是：%s\n\n示例面板要画的这批数据：\n%s"
                        sentence (plist-get panel :describe))))
      (supertag-summary--component-attempt panel symbol base base 2))))

;;; Following a Tag that gets a new ID

;;;###autoload
(defun supertag-summary-rekey-tag (old-id new-id)
  "Point every kept panel made for the Tag OLD-ID at NEW-ID.
A legacy Tag whose ID is its name gets a fresh ID the first time it is
renamed; its panels follow it here.  Return the number of panels changed."
  (let ((changed 0))
    (dolist (name (supertag-summary--names) changed)
      (pcase (supertag-summary--read (supertag-summary--file name) 'panel)
        (`(:ok ,data)
         (when (equal (plist-get data :tag) old-id)
           (supertag-summary--write (supertag-summary--file name)
                                    (plist-put data :tag new-id))
           (remhash name supertag-summary--panels)
           (cl-incf changed)))))))

(provide 'supertag-summary)
;;; supertag-summary.el ends here
