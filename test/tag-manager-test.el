;;; tag-manager-test.el --- Tag Manager view, set-parent and affixation -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-tag)
(require 'supertag-view-framework)
(require 'supertag-view-tags)

(defvar evil-emacs-state-modes)

(defmacro supertag-tag-manager-test--with-store (&rest body)
  "Run BODY with an isolated Store and subscriber table."
  (declare (indent 0))
  `(let ((supertag--store nil)
         (supertag--subscribers (make-hash-table :test 'equal)))
     (supertag--ensure-store)
     (supertag-view-tags--register-view)
     ,@body))

(defun supertag-tag-manager-test--kill-buffers ()
  "Kill Tag Manager test buffers without prompting."
  (dolist (buffer (buffer-list))
    (when (and (buffer-name buffer)
               (string-match-p "\\`\\*Supertag Tags\\*" (buffer-name buffer)))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

;;; --- supertag-tag-set-parent ---

(ert-deftest supertag-tag-set-parent-sets-extends ()
  (supertag-tag-manager-test--with-store
    (let ((media (plist-get (supertag-tag-create '(:name "media")) :id))
          (book (plist-get (supertag-tag-create '(:name "book")) :id)))
      (should-not (supertag-tag-parents book))
      (supertag-tag-set-parent book (list media))
      (should (equal (list media) (supertag-tag-parents book))))))

(ert-deftest supertag-tag-set-parent-rejects-cycle ()
  (supertag-tag-manager-test--with-store
    (let* ((a (plist-get (supertag-tag-create '(:name "a")) :id))
           (b (plist-get (supertag-tag-create (list :name "b" :extends (list a))) :id)))
      (should-error (supertag-tag-set-parent a (list b)) :type 'user-error)
      (should-not (supertag-tag-parents a)))))

(ert-deftest supertag-tag-set-parent-rejects-missing-parent ()
  (supertag-tag-manager-test--with-store
    (let ((book (plist-get (supertag-tag-create '(:name "book")) :id)))
      (should-error (supertag-tag-set-parent book (list "does-not-exist"))
                    :type 'user-error)
      (should-not (supertag-tag-parents book)))))

(ert-deftest supertag-tag-set-parent-clears-with-explicit-nil ()
  (supertag-tag-manager-test--with-store
    (let* ((media (plist-get (supertag-tag-create '(:name "media")) :id))
           (book (plist-get (supertag-tag-create (list :name "book" :extends (list media)))
                            :id)))
      (should (equal (list media) (supertag-tag-parents book)))
      (supertag-tag-set-parent book nil)
      (should-not (supertag-tag-parents book)))))

(ert-deftest supertag-tag-set-parent-interactive-empty-clears ()
  (supertag-tag-manager-test--with-store
    (let* ((media (plist-get (supertag-tag-create '(:name "media")) :id))
           (book (plist-get (supertag-tag-create (list :name "book" :extends (list media)))
                            :id)))
      (should (equal (list media) (supertag-tag-parents book)))
      (cl-letf (((symbol-function 'completing-read-multiple)
                 (lambda (prompt &rest _)
                   (if (string-prefix-p "Parents for" prompt)
                       (list "")
                     (error "Unexpected prompt: %s" prompt)))))
        (supertag-tag-set-parent book))
      ;; Empty input clears every parent.
      (should-not (supertag-tag-parents book)))))

(ert-deftest supertag-tag-set-parent-defaults-to-tag-at-point ()
  (supertag-tag-manager-test--with-store
    (let ((media (plist-get (supertag-tag-create '(:name "media")) :id)))
      (supertag-tag-create '(:name "book"))
      (with-temp-buffer
        (org-mode)
        (insert "Reading #book notes")
        (goto-char (point-min))
        (search-forward "#book")
        (backward-char 2)
        (cl-letf (((symbol-function 'completing-read-multiple)
                   (lambda (prompt &rest _)
                     (if (string-prefix-p "Parents for" prompt)
                         (list "media")
                       (error "Unexpected prompt: %s" prompt)))))
          (supertag-tag-set-parent))
        (should (equal (list media)
                       (supertag-tag-parents
                        (supertag-tag-resolve-occurrence "book"))))))))

;;; --- supertag-tag-affixate-candidates hierarchy prefix ---

(ert-deftest supertag-tag-affixate-shows-ancestor-chain-for-flat-candidates ()
  (supertag-tag-manager-test--with-store
    (let* ((media (plist-get (supertag-tag-create '(:name "media")) :id))
           (book (plist-get (supertag-tag-create (list :name "book" :extends (list media)))
                            :id))
           (existing (propertize "book" 'supertag-tag-id book))
           (new-candidate (propertize "newtag" 'new-tag-name "newtag"
                                       'is-new-tag t)))
      (let ((row (car (supertag-tag-affixate-candidates (list existing)))))
        (should (equal (nth 0 row) "media › book"))
        (should (equal (nth 1 row) "")))
      (let ((row (car (supertag-tag-affixate-candidates (list new-candidate)))))
        ;; A brand-new tag has no stored ancestors: no "x › " prefix.
        (should (equal (nth 0 row) "newtag"))
        (should (equal (nth 2 row) (propertize "  [New]" 'face 'warning)))))))

;;; --- Tag Manager view ---

(ert-deftest supertag-view-tags-renders-extends-tree-three-levels ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-store-put-entity
           :tags "media" (list :id "media" :name "media" :type :tag
                               :aliases '("media")))
          (supertag-store-put-entity
           :tags "book" (list :id "book" :name "book" :type :tag
                              :extends (list "media") :aliases '("book")))
          (supertag-store-put-entity
           :tags "novel" (list :id "novel" :name "novel" :type :tag
                               :extends (list "book") :aliases '("novel" "fiction")))
          (supertag-store-put-entity
           :tags "work" (list :id "work" :name "work" :type :tag
                              :aliases '("work")))
          (supertag-store-put-entity
           :tags "ghost" (list :id "ghost" :name "ghost" :type :tag
                               :extends (list "missing-parent") :aliases '("ghost")))
          (supertag-store-put-entity
           :nodes "n1" (list :id "n1" :title "N1" :tags '("media")))
          (supertag-store-put-entity
           :nodes "n2" (list :id "n2" :title "N2" :tags '("book")))
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (should (derived-mode-p 'supertag-view-tags-mode))
              (let ((text (buffer-string)))
                (should (string-match-p "^  media  (1 个节点)$" text))
                (should (string-match-p "^    book  (1 个节点)$" text))
                (should (string-match-p
                         "^      novel  (0 个节点)  别名: fiction$" text))
                (should (string-match-p "^  work  (0 个节点)$" text))
                (should (string-match-p "^  ghost  (0 个节点)  \\[Orphan" text)))
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-create-child-under-tag-at-point ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-tag-create '(:id "media" :name "media"))
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "media")
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _) "book")))
                (supertag-view-tags-create-child))
              (should (equal (list "media")
                             (supertag-tag-parents
                              (supertag-tag-resolve-occurrence "book"))))
              (should (string-match-p "^    book  (0 个节点)$" (buffer-string)))
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-set-parent-refreshes-tree ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-tag-create '(:id "media" :name "media"))
          (supertag-tag-create '(:id "book" :name "book"))
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (should (string-match-p "^  book  (0 个节点)$" (buffer-string)))
              (search-forward "book")
              (cl-letf (((symbol-function 'completing-read-multiple)
                         (lambda (&rest _) (list "media"))))
                (supertag-view-tags-set-parent))
              (should (equal (list "media") (supertag-tag-parents "book")))
              (should (string-match-p "^    book  (0 个节点)$" (buffer-string)))
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-shows-a-multi-parent-tag-under-each-parent ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-tag-create '(:id "tools" :name "tools"))
          (supertag-tag-create '(:id "topics" :name "topics"))
          (supertag-tag-create
           '(:id "emacs" :name "emacs" :extends ("tools" "topics")))
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (let ((text (buffer-string)))
                ;; The DAG expands into the tree: one child row under each
                ;; parent, while the header still counts Tags, not rows.
                (should (equal 2
                               (length
                                (seq-filter
                                 (lambda (line)
                                   (string-match-p "^    emacs  (0 个节点)$" line))
                                 (split-string text "\n")))))
                (should (string-match-p "^  tools  (0 个节点)$" text))
                (should (string-match-p "^  topics  (0 个节点)$" text))
                (should (string-match-p " Tag Manager   3 tags" header-line-format)))
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-create-command-makes-a-root-or-a-path ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "media")))
                (supertag-view-tags-create))
              (should (equal "media"
                             (plist-get (supertag-tag-get
                                         (supertag-tag-resolve-occurrence "media"))
                                        :name)))
              (should (string-match-p "^  media  (0 个节点)$" (buffer-string)))
              ;; `/' creates the whole chain under the new root.
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _) "media/book")))
                (supertag-view-tags-create))
              (let ((book (supertag-tag-resolve-occurrence "book")))
                (should book)
                (should (equal (list (supertag-tag-resolve-occurrence "media"))
                               (supertag-tag-parents book)))
                (should (string-match-p "^    book  (0 个节点)$" (buffer-string))))
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-create-child-accepts-a-path ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-tag-create '(:id "media" :name "media"))
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "media")
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _) "book/fiction")))
                (supertag-view-tags-create-child))
              ;; The first segment hangs under this row; the leaf follows it.
              (let ((book (supertag-tag-resolve-occurrence "book"))
                    (fiction (supertag-tag-resolve-occurrence "fiction")))
                (should book)
                (should fiction)
                (should (equal (list "media") (supertag-tag-parents book)))
                (should (equal (list book) (supertag-tag-parents fiction))))
              (should (string-match-p "^    book  (0 个节点)$" (buffer-string)))
              (should (string-match-p "^      fiction  (0 个节点)$" (buffer-string)))
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-edit-aliases-persists-to-store ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-tag-create '(:id "book" :name "book"))
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "book")
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _) "fiction, novel")))
                (supertag-view-tags-edit-aliases))
              (should (equal '("fiction" "novel")
                             (sort (supertag-view-tags--extra-aliases
                                    (supertag-tag-get "book") "book")
                                   #'string<)))
              (should (string-match-p "别名: fiction, novel" (buffer-string)))
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-open-stream-and-quit ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (supertag-tag-create '(:id "book" :name "book"))
          (supertag-store-put-entity
           :nodes "n1" (list :id "n1" :title "N1" :tags '("book")))
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "book")
              (let ((stream (supertag-view-tags-open-stream)))
                (should (buffer-live-p stream))
                (should (derived-mode-p 'supertag-view-stream-mode))
                (with-current-buffer stream
                  (supertag-view-stream-quit))))
            (with-current-buffer buffer
              (supertag-view-tags-quit))
            (should-not (buffer-live-p buffer))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-marks-render-and-clear ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (dolist (id '("alpha" "beta"))
            (supertag-tag-create (list :id id :name id)))
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (goto-char (point-min)) (search-forward "alpha") (beginning-of-line)
              (supertag-view-tags-mark)
              (should (equal supertag-view-tags--marked-ids '("alpha")))
              (should (string-match-p "^\\* alpha" (buffer-string)))
              (goto-char (point-min)) (search-forward "alpha") (beginning-of-line)
              (supertag-view-tags-unmark)
              (should-not supertag-view-tags--marked-ids)
              (should (string-match-p "^  alpha" (buffer-string)))
              (goto-char (point-min)) (search-forward "alpha") (beginning-of-line)
              (supertag-view-tags-mark)
              (goto-char (point-min)) (search-forward "beta") (beginning-of-line)
              (supertag-view-tags-mark)
              (should (= 2 (length supertag-view-tags--marked-ids)))
              (supertag-view-tags-unmark-all)
              (should-not supertag-view-tags--marked-ids)
              (should-not (string-match-p "^\\* " (buffer-string)))
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-delete-marks-with-one-confirmation ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (dolist (id '("alpha" "beta" "gamma"))
            (supertag-tag-create (list :id id :name id)))
          (let ((buffer (supertag-view-tags)) prompts)
            (with-current-buffer buffer
              (setq supertag-view-tags--marked-ids '("alpha" "beta"))
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (prompt) (push prompt prompts) t)))
                (supertag-view-tags-delete))
              (should (equal 1 (length prompts)))
              (should (string-match-p "Delete 2 tags (alpha, beta) everywhere?" (car prompts)))
              (should-not (supertag-tag-get "alpha"))
              (should-not (supertag-tag-get "beta"))
              (should (supertag-tag-get "gamma"))
              (should-not supertag-view-tags--marked-ids)
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-tags-delete-current-row-without-marks ()
  (supertag-tag-manager-test--with-store
    (unwind-protect
        (save-window-excursion
          (dolist (id '("alpha" "beta"))
            (supertag-tag-create (list :id id :name id)))
          (let ((buffer (supertag-view-tags)) (confirmations 0))
            (with-current-buffer buffer
              (goto-char (point-min)) (search-forward "alpha") (beginning-of-line)
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (_prompt) (cl-incf confirmations) t)))
                (supertag-view-tags-delete))
              (should (= 1 confirmations))
              (should-not (supertag-tag-get "alpha"))
              (should (supertag-tag-get "beta"))
              (supertag-view-tags-quit))))
      (supertag-tag-manager-test--kill-buffers))))

(ert-deftest supertag-view-register-modal-state-is-idempotent-for-evil ()
  (let ((evil-emacs-state-modes nil)
        calls)
    (let ((real-featurep (symbol-function 'featurep)))
      (cl-letf (((symbol-function 'featurep)
                 (lambda (feature)
                   (or (eq feature 'evil) (funcall real-featurep feature))))
                ((symbol-function 'evil-set-initial-state)
                 (lambda (mode state) (push (cons mode state) calls))))
      (supertag-view-register-modal-state 'supertag-view-tags-mode)
      (supertag-view-register-modal-state 'supertag-view-tags-mode)))
    (should (equal evil-emacs-state-modes '(supertag-view-tags-mode)))
    (should (equal calls '((supertag-view-tags-mode . emacs)
                           (supertag-view-tags-mode . emacs))))))

(ert-deftest supertag-view-tags-mode-disables-meow ()
  (unless (fboundp 'meow-mode)
    (define-minor-mode meow-mode
      "Dummy buffer-local Meow mode for Tag Manager tests."
      :init-value nil
      :lighter nil))
  (let ((old-default (default-value 'meow-mode)))
    (unwind-protect
        (progn
          ;; A major-mode transition clears buffer locals, so use the default
          ;; value to model a globally enabled buffer-local mode.
          (setq-default meow-mode t)
          (with-temp-buffer
            (supertag-view-tags-mode)
            (should-not meow-mode)))
      (setq-default meow-mode old-default))))

(provide 'tag-manager-test)
;;; tag-manager-test.el ends here
