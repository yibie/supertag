;;; test-view-stream.el --- Stream View workflow tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-view-framework)
(require 'supertag-view-stream)

(defmacro supertag-view-stream-test--with-store (&rest body)
  "Run BODY with an isolated Store and subscriber table."
  (declare (indent 0))
  `(let ((supertag--store nil)
         (supertag--subscribers (make-hash-table :test 'equal)))
     (supertag--ensure-store)
     (supertag-view-stream--register-view)
     ,@body))

(defun supertag-view-stream-test--put-node
    (id title tags content created-at &optional file level)
  "Put a Stream fixture node with ID, TITLE, TAGS and CONTENT."
  (supertag-store-put-entity
   :nodes id
   (list :id id :type :node :title title :tags tags :content content
         :created-at created-at :file file :level (or level 1))))

(defun supertag-view-stream-test--put-tag (id &optional parent)
  "Put a Stream fixture Tag ID with an optional `:extends' PARENT."
  (supertag-store-put-entity
   :tags id (list :id id :name id :type :tag :extends (list parent))))

(defun supertag-view-stream-test--kill-buffers ()
  "Kill Stream test buffers without prompting."
  (dolist (buffer (buffer-list))
    (when (and (buffer-name buffer)
               (string-match-p
                "\\`\\*Supertag \\(Stream\\|Stream Index\\|Edit\\)"
                (buffer-name buffer)))
      (with-current-buffer buffer
        (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(ert-deftest supertag-view-stream-state-includes-real-descendants-and-sorts ()
  "Stream uses transitive `:extends' descendants only."
  (supertag-view-stream-test--with-store
    (supertag-view-stream-test--put-tag "diary")
    (supertag-view-stream-test--put-tag "diary/happy" "diary")
    (supertag-view-stream-test--put-tag "diary/private" "diary")
    (supertag-view-stream-test--put-tag "diary/private/day" "diary/private")
    (supertag-view-stream-test--put-tag "diaryx")
    (supertag-view-stream-test--put-tag "legacy" "diary")
    (supertag-view-stream-test--put-node
     "late" "Late" '("diary") "late" '(0 30 0 0))
    (supertag-view-stream-test--put-node
     "early" "Early" '("diary/happy") "early" '(0 10 0 0))
    (supertag-view-stream-test--put-node
     "lookalike" "Wrong" '("diaryx") "wrong" '(0 1 0 0))
    (supertag-view-stream-test--put-node
     "flat-extends" "Inherited" '("legacy") "inherited" '(0 2 0 0))
    (supertag-view-stream-test--put-node
     "untimed-b" "B" '("diary/private/day") "b" nil)
    (supertag-view-stream-test--put-node
     "untimed-a" "A" '("diary/private") "a" nil)
    (let ((state (supertag-view-stream--build-state '(:tag "diary"))))
      (should-not (plist-member state :layout))
      (should
       (equal (mapcar (lambda (node) (plist-get node :id))
              (plist-get state :nodes))
              '("flat-extends" "early" "late" "untimed-a" "untimed-b")))
      (let ((undated
             (car (last (supertag-view-stream--group-nodes-by-date
                         (plist-get state :nodes))))))
        (should (equal (car undated) "No date"))
        (should (equal (mapcar (lambda (node) (plist-get node :id))
                               (cdr undated))
                       '("untimed-a" "untimed-b")))))))

(ert-deftest supertag-view-stream-runtime-renders-date-grouped-title-list ()
  "The Runtime must group keyed title/tag rows by creation day."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (progn
          (supertag-view-stream-test--put-node
           "node-1" "Package archives"
           '("emacs" "elpa")
           "A paragraph.\n\n| Name | URL |\n| GNU | elpa.gnu.org |\n\n#+begin_quote\nKeep it small.\n#+end_quote"
           (encode-time 0 14 7 2 11 2025)
           "/tmp/private-note.org")
          (supertag-view-stream-test--put-node
           "node-2" "Second package" '("emacs") "Second body"
           (encode-time 0 45 9 2 11 2025))
          (supertag-view-stream-test--put-node
           "node-3" "Next day" '("emacs") "Next body"
           (encode-time 0 0 8 3 11 2025))
          (let ((system-time-locale "C"))
            (cl-letf (((symbol-function 'display-buffer) #'ignore))
              (let ((buffer
                     (supertag-view-open
                      'stream '(:tag "emacs"))))
                (with-current-buffer buffer
                  (font-lock-ensure)
                  (should (derived-mode-p 'supertag-view-stream-mode))
                  (should (equal (plist-get supertag-view--instance :view-id)
                                 'stream))
                  (should (= (how-many "^2025-11-02 Sun$"
                                       (point-min) (point-max))
                             1))
                  (should (= (how-many "^2025-11-03 Mon$"
                                       (point-min) (point-max))
                             1))
                  (should-not (string-match-p "07:14" (buffer-string)))
                  (should (string-match-p
                           "Package archives  #emacs #elpa"
                           (buffer-string)))
                  (should (string-match-p "Second package  #emacs"
                                          (buffer-string)))
                  (should (string-match-p "Next day  #emacs"
                                          (buffer-string)))
                  (should (string-match-p "Package archives" (buffer-string)))
                  ;; Fix 2: the stored body is shown, indented under its title.
                  (should (string-match-p "A paragraph\\." (buffer-string)))
                  (should (string-match-p "| GNU | elpa.gnu.org |"
                                          (buffer-string)))
                  ;; The 6-line default cap hides the tail and marks it.
                  (should (string-match-p "…" (buffer-string)))
                  (should-not (string-match-p "Keep it small" (buffer-string)))
                  (should-not (string-match-p "/tmp/private-note.org"
                                              (buffer-string)))
                  (goto-char (point-min))
                  (should (eq (get-text-property (point) 'font-lock-face)
                              'org-level-3))
                  (search-forward "2025-11-02 Sun")
                  (search-forward "Package archives")
                  (should (equal (buffer-substring-no-properties
                                  (line-beginning-position)
                                  (line-end-position))
                                 "Package archives  #emacs #elpa"))
                  (let ((position (1- (point))))
                    (should (equal (get-text-property
                                    position 'supertag-entity-id)
                                   "node-1"))
                    (should-not (button-at position))
                    (should-not (get-text-property position 'mouse-face))
                    (should (eq (get-text-property position 'font-lock-face)
                                'supertag-view-stream-title-face)))
                  (search-forward "#emacs")
                  (should (equal (get-text-property
                                  (1- (point)) 'supertag-entity-id)
                                 "node-1"))
                  (search-forward "Second package")
                  (search-forward "2025-11-03 Mon")
                  (search-forward "Next day"))))))
      (supertag-view-stream-test--kill-buffers))))

(ert-deftest supertag-view-stream-refresh-restores-node-id-and-falls-back ()
  "Refresh must restore the same node, then fall back when it disappears."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (progn
          (supertag-view-stream-test--put-node
           "node-1" "First" '("diary") "First body" '(0 10 0 0))
          (supertag-view-stream-test--put-node
           "node-2" "Second" '("diary") "Second body" '(0 20 0 0))
          (cl-letf (((symbol-function 'display-buffer) #'ignore))
            (let ((buffer
                   (supertag-view-open
                    'stream '(:tag "diary"))))
              (with-current-buffer buffer
                (goto-char (point-min))
                (search-forward "Second")
                (should (equal (supertag-view-stream--current-node-id)
                               "node-2")))
              (supertag-view-stream-test--put-node
               "node-0" "Earlier" '("diary") "Earlier body" '(0 1 0 0))
              (supertag-view-refresh buffer)
              (with-current-buffer buffer
                (should (equal (supertag-view-stream--current-node-id)
                               "node-2")))
              (remhash "node-2" (supertag-store-get-collection :nodes))
              (supertag-view-refresh buffer)
              (with-current-buffer buffer
                (should (equal (supertag-view-stream--current-node-id)
                               "node-0"))))))
      (supertag-view-stream-test--kill-buffers))))

(ert-deftest supertag-view-stream-public-command-opens-one-summary-buffer ()
  "The public command must open one metadata/title Runtime buffer."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-view-stream-test--put-tag "diary")
          (supertag-view-stream-test--put-tag "diary/happy" "diary")
          (supertag-view-stream-test--put-node
           "node-1" "First title" '("diary")
           "First body"
           '(0 10 0 0))
          (supertag-view-stream-test--put-node
           "node-2" "Second title" '("diary/happy") "Second body" '(0 20 0 0))
          (let ((main (supertag-view-stream "diary")))
            (should (buffer-live-p main))
            (should-not (get-buffer "*Supertag Stream Index: diary*"))
            (with-current-buffer main
              (should (string-match-p "First title" (buffer-string)))
              (should (string-match-p "Second title" (buffer-string)))
              (should (string-match-p "First body" (buffer-string)))
              (should (string-match-p "Second body" (buffer-string)))
              (should-not (lookup-key supertag-view-stream-mode-map
                                      (kbd "s"))))
            (with-current-buffer main
              (supertag-view-stream-quit))
            (should-not (buffer-live-p main))))
      (supertag-view-stream-test--kill-buffers))))

(ert-deftest supertag-view-stream-public-command-keeps-one-buffer-per-tag ()
  "Different tags get different buffers; reopening one tag reuses its buffer."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-view-stream-test--put-tag "diary")
          (supertag-view-stream-test--put-tag "work")
          (supertag-view-stream-test--put-node
           "diary-node" "Diary title" '("diary") "Diary body" '(0 10 0 0))
          (supertag-view-stream-test--put-node
           "work-node" "Work title" '("work") "Work body" '(0 20 0 0))
          (let* ((diary (supertag-view-stream "diary"))
                 (work (supertag-view-stream "work")))
            (should-not (eq diary work))
            (should (equal (buffer-name diary) "*Supertag Stream: diary*"))
            (should (equal (buffer-name work) "*Supertag Stream: work*"))
            (should-not (get-buffer "*Supertag Stream Index: diary*"))
            (should-not (get-buffer "*Supertag Stream Index: work*"))
            (let ((diary-again (supertag-view-stream "diary")))
              (should (eq diary diary-again))
              (should (buffer-live-p work))
              (with-current-buffer diary
                (should (equal (plist-get
                                (plist-get supertag-view--instance :input) :tag)
                               "diary"))
                (should (string-match-p "Diary title" (buffer-string)))
                (should (string-match-p "Diary body" (buffer-string)))
                (should-not (string-match-p "Work title" (buffer-string))))
              (with-current-buffer work
                (should (equal (plist-get
                                (plist-get supertag-view--instance :input) :tag)
                               "work"))
                (should (string-match-p "Work title" (buffer-string)))
                (should (string-match-p "Work body" (buffer-string)))
                (should-not (string-match-p "Diary title" (buffer-string)))))))
      (supertag-view-stream-test--kill-buffers))))

(ert-deftest supertag-view-stream-navigation-and-node-view-use-stable-id ()
  "Navigation and field dispatch must use the node ID at point."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (progn
          (supertag-view-stream-test--put-node
           "node-1" "First" '("diary") "First body" '(0 10 0 0))
          (supertag-view-stream-test--put-node
           "node-2" "Second" '("diary") "Second body" '(0 20 0 0))
          (cl-letf (((symbol-function 'display-buffer) #'ignore))
            (let ((buffer
                   (supertag-view-open
                    'stream '(:tag "diary")))
                  opened no-focus)
              (with-current-buffer buffer
                (goto-char (point-min))
                (should (equal (supertag-view-stream--current-node-id)
                               "node-1"))
                (supertag-view-stream-next-node)
                (should (equal (supertag-view-stream--current-node-id)
                               "node-2"))
                (should
                 (equal (get-text-property
                         (overlay-start supertag-view-stream--selection-overlay)
                         'supertag-entity-id)
                        "node-2"))
                (cl-letf (((symbol-function 'supertag-view-node-open)
                           (lambda (node-id &optional no-focus-arg)
                             (setq opened node-id
                                   no-focus no-focus-arg))))
                  (supertag-view-stream-open-node-view))
                (should (equal opened "node-2"))
                ;; `v' never focuses Node View from the Stream.
                (should no-focus)))))
      (supertag-view-stream-test--kill-buffers))))

(ert-deftest supertag-view-stream-navigation-does-not-pin-point-to-window-top ()
  "Moving among visible Stream titles must preserve the window start."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-view-stream-test--put-node
           "node-1" "First" '("diary") "First body" '(0 10 0 0))
          (supertag-view-stream-test--put-node
           "node-2" "Second" '("diary") "Second body" '(0 20 0 0))
          (let* ((main (supertag-view-stream "diary"))
                 (window (get-buffer-window main t))
                 (start (window-start window)))
            (with-selected-window window
              (supertag-view-stream-next-node))
            (should (= (window-start window) start))
            (should (equal (with-current-buffer main
                             (supertag-view-stream--current-node-id))
                           "node-2"))))
      (supertag-view-stream-test--kill-buffers))))

(ert-deftest supertag-view-stream-edit-confirms-or-aborts-expanded-source ()
  "Stream edit must show title/body, confirm changes and support abort."
  (supertag-view-stream-test--with-store
    (let ((file (make-temp-file
                 "supertag-stream-edit-" nil ".org"
                 "* Parent #diary\n:PROPERTIES:\n:ID: edit-node\n:END:\nOriginal body\n** Child\nChild body\n"))
          base
          edit
          main)
      (unwind-protect
          (progn
            (supertag-view-stream-test--put-node
             "edit-node" "Parent" '("diary") "Original body"
             '(0 10 0 0) file 1)
            (setq base (find-file-noselect file))
            (with-current-buffer base
              (org-mode)
              (goto-char (point-min))
              (org-fold-hide-entry))
            (cl-letf (((symbol-function 'display-buffer) #'ignore))
              (setq main
                    (supertag-view-open
                     'stream '(:tag "diary")))
              (with-current-buffer main
                (setq edit (supertag-view-stream-edit)))
              (with-current-buffer edit
                (should (buffer-narrowed-p))
                (should (eq (key-binding (kbd "C-c C-c"))
                            #'supertag-view-stream-edit-finish))
                (goto-char (point-min))
                (should (looking-at-p "\\* Parent"))
                (search-forward "Original body")
                (should-not (invisible-p (1- (point))))
                (should-not (string-match-p "Child body" (buffer-string)))
                (should (eq (key-binding (kbd "C-c C-k"))
                            #'supertag-view-stream-edit-abort))
                (goto-char (point-max))
                (insert "Aborted in Stream\n")
                (call-interactively (key-binding (kbd "C-c C-k"))))
              (should-not (buffer-live-p edit))
              (with-current-buffer base
                (should (string-match-p "Original body" (buffer-string)))
                (should-not (string-match-p "Aborted in Stream"
                                            (buffer-string)))
                (should-not (buffer-modified-p)))
              (should (equal (plist-get
                              (supertag-store-get-entity :nodes "edit-node")
                              :content)
                             "Original body"))
              (with-current-buffer main
                (setq edit (supertag-view-stream-edit)))
              (with-current-buffer edit
                (goto-char (point-max))
                (insert "Changed in Stream\n")
                (call-interactively (key-binding (kbd "C-c C-c"))))
              (should-not (buffer-live-p edit))
              (with-current-buffer base
                (should (string-match-p "Changed in Stream"
                                        (buffer-string)))
                (should-not (buffer-modified-p)))
              (should (equal (plist-get
                              (supertag-store-get-entity :nodes "edit-node")
                              :created-at)
                             '(0 10 0 0)))
              (should (string-match-p
                       "Changed in Stream"
                       (or (plist-get
                            (supertag-store-get-entity :nodes "edit-node")
                            :content)
                           "")))
              (with-temp-buffer
                (insert-file-contents file)
                (should (string-match-p "Changed in Stream"
                                        (buffer-string))))))
        (when (buffer-live-p edit)
          (with-current-buffer edit (set-buffer-modified-p nil))
          (kill-buffer edit))
        (when (buffer-live-p base)
          (with-current-buffer base (set-buffer-modified-p nil))
          (kill-buffer base))
        (supertag-view-stream-test--kill-buffers)
        (delete-file file)))))

(ert-deftest supertag-view-stream-runtime-owns-store-subscription ()
  "Killing the main Stream buffer must remove its only Store subscription."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (progn
          (supertag-view-stream-test--put-node
           "node-1" "First" '("diary") "Body" '(0 10 0 0))
          (cl-letf (((symbol-function 'display-buffer) #'ignore))
            (let ((buffer
                   (supertag-view-open
                    'stream '(:tag "diary"))))
              (should (= 1 (length
                            (gethash :store-changed supertag--subscribers))))
              (kill-buffer buffer)
              (should-not (gethash :store-changed supertag--subscribers)))))
      (supertag-view-stream-test--kill-buffers))))

(ert-deftest supertag-view-stream-shows-tag-names-not-ids ()
  "A row and the header show a Tag's name, never its opaque stable ID."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (progn
          (let ((stable "tag-6e82dd80ff784c00bf2b9a94685930db"))
            (supertag-store-put-entity
             :tags stable
             (list :id stable :name "emacs" :type :tag :extends nil))
            (supertag-view-stream-test--put-node
             "node-1" "Package archives" (list stable "diary")
             "Body" '(0 10 0 0))
            (cl-letf (((symbol-function 'display-buffer) #'ignore))
              (let ((buffer (supertag-view-open 'stream (list :tag stable))))
                (with-current-buffer buffer
                  (should (string-match-p "Package archives  #emacs #diary"
                                          (buffer-string)))
                  (should-not (string-match-p stable (buffer-string)))
                  (should (equal header-line-format " #emacs   1 nodes "))))))
          ;; An ID with no Tag record falls back to the ID string.
          (supertag-view-stream-test--put-node
           "node-2" "Orphan" '("tag-ffffffffffffffffffffffffffffffff") "body" '(0 20 0 0))
          (cl-letf (((symbol-function 'display-buffer) #'ignore))
            (let ((buffer (supertag-view-open
                           'stream (list :tag "tag-ffffffffffffffffffffffffffffffff"))))
              (with-current-buffer buffer
                (should (string-match-p
                         "Orphan  #tag-ffffffffffffffffffffffffffffffff"
                         (buffer-string)))
                (should (equal header-line-format
                               " #tag-ffffffffffffffffffffffffffffffff   1 nodes ")))))
          ;; The empty-stream text names the Tag too, not the raw token.
          (cl-letf (((symbol-function 'display-buffer) #'ignore))
            (let ((buffer (supertag-view-open 'stream (list :tag "unknown-token"))))
              (with-current-buffer buffer
                (should (equal (buffer-string) "No nodes for #unknown-token.\n"))))))
      (supertag-view-stream-test--kill-buffers))))

(ert-deftest supertag-view-stream-body-is-shown-capped-and-drawer-free ()
  "The stored body is shown, capped with `…', and hides Org scaffolding."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (progn
          (supertag-view-stream-test--put-tag "diary")
          (supertag-view-stream-test--put-node
           "node-1" "With body" '("diary")
           (concat ":PROPERTIES:\n:ID: node-1\n:END:\n"
                   "First line.\n"
                   "SCHEDULED: <2026-01-01 Thu>\n"
                   "\n"
                   "Second line.\n"
                   "Third line.\nFourth line.\nFifth line.\nSixth line.\n"
                   "Seventh line.\nEighth line.\n")
           '(0 10 0 0))
          (supertag-view-stream-test--put-node
           "node-2" "Empty body" '("diary") "   \n  \n" '(0 20 0 0))
          (cl-letf (((symbol-function 'display-buffer) #'ignore))
            (let ((buffer (supertag-view-open 'stream '(:tag "diary"))))
              (with-current-buffer buffer
                (font-lock-ensure)
                (should (string-match-p "First line\\." (buffer-string)))
                (should (string-match-p "^  Second line\\.$" (buffer-string)))
                ;; The property drawer and planning line are not shown.
                (should-not (string-match-p ":PROPERTIES:" (buffer-string)))
                (should-not (string-match-p ":ID: node-1" (buffer-string)))
                (should-not (string-match-p "SCHEDULED:" (buffer-string)))
                ;; Six body lines show (blank lines included), the rest is
                ;; replaced by the visible marker.
                (should (string-match-p "Fifth line\\.…" (buffer-string)))
                (should-not (string-match-p "Sixth line" (buffer-string)))
                (should-not (string-match-p "Seventh line" (buffer-string)))
                (should-not (string-match-p "Eighth line" (buffer-string)))
                ;; An empty body contributes no lines at all.
                (should-not (string-match-p "Empty body\n  " (buffer-string)))
                ;; Body lines belong to the node and use the quiet face.
                (goto-char (point-min))
                (search-forward "First line")
                (should (equal "node-1"
                               (get-text-property (1- (point)) 'supertag-entity-id)))
                (should (eq (get-text-property (1- (point)) 'font-lock-face)
                            'supertag-view-excerpt))
                ;; The selection overlay covers the whole block.
                (supertag-view-stream--highlight "node-1")
                (should (equal (buffer-substring-no-properties
                                (overlay-start supertag-view-stream--selection-overlay)
                                (overlay-end supertag-view-stream--selection-overlay))
                               (concat "With body  #diary\n"
                                       "  First line.\n\n  Second line.\n"
                                       "  Third line.\n  Fourth line.\n"
                                       "  Fifth line.…\n")))))))
      (supertag-view-stream-test--kill-buffers))))

(ert-deftest supertag-view-stream-v-keeps-focus-and-point-in-the-stream ()
  "`v' shows Node View without selecting its window."
  (supertag-view-stream-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-view-stream-test--put-tag "diary")
          (supertag-view-stream-test--put-node
           "node-1" "First" '("diary") "First body" '(0 10 0 0))
          (supertag-view-stream-test--put-node
           "node-2" "Second" '("diary") "Second body" '(0 20 0 0))
          (let ((main (supertag-view-stream "diary")))
            (should (eq main (window-buffer (selected-window))))
            (with-current-buffer main
              (goto-char (point-min))
              (supertag-view-stream-next-node)
              (let ((point (point)))
                (supertag-view-stream-open-node-view)
                (should (= point (point)))))
            ;; Focus never left the Stream window or buffer.
            (should (eq main (window-buffer (selected-window))))
            (should (eq main (current-buffer)))
            ;; Node View was shown for the current node, without focus.
            (let ((node-view (supertag-view-node--buffer)))
              (should node-view)
              (should (equal "node-2"
                             (plist-get (plist-get (buffer-local-value
                                                    'supertag-view--instance
                                                    node-view)
                                                   :input)
                                        :node-id))))))
      (supertag-view-stream-test--kill-buffers))))

(provide 'test-view-stream)

;;; test-view-stream.el ends here
