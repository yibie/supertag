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
      (should-not (supertag-tag-parent book))
      (supertag-tag-set-parent book media)
      (should (equal media (supertag-tag-parent book))))))

(ert-deftest supertag-tag-set-parent-rejects-cycle ()
  (supertag-tag-manager-test--with-store
    (let* ((a (plist-get (supertag-tag-create '(:name "a")) :id))
           (b (plist-get (supertag-tag-create `(:name "b" :extends ,a)) :id)))
      (should-error (supertag-tag-set-parent a b) :type 'user-error)
      (should-not (supertag-tag-parent a)))))

(ert-deftest supertag-tag-set-parent-rejects-missing-parent ()
  (supertag-tag-manager-test--with-store
    (let ((book (plist-get (supertag-tag-create '(:name "book")) :id)))
      (should-error (supertag-tag-set-parent book "does-not-exist")
                    :type 'user-error)
      (should-not (supertag-tag-parent book)))))

(ert-deftest supertag-tag-set-parent-clears-with-explicit-nil ()
  (supertag-tag-manager-test--with-store
    (let* ((media (plist-get (supertag-tag-create '(:name "media")) :id))
           (book (plist-get (supertag-tag-create `(:name "book" :extends ,media))
                            :id)))
      (should (equal media (supertag-tag-parent book)))
      (supertag-tag-set-parent book nil)
      (should-not (supertag-tag-parent book)))))

(ert-deftest supertag-tag-set-parent-interactive-none-candidate-clears ()
  (supertag-tag-manager-test--with-store
    (let* ((media (plist-get (supertag-tag-create '(:name "media")) :id))
           (book (plist-get (supertag-tag-create `(:name "book" :extends ,media))
                            :id)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt _table &rest _)
                   (if (string-prefix-p "Parent" prompt)
                       "(none)"
                     (error "Unexpected prompt: %s" prompt)))))
        (supertag-tag-set-parent book))
      (should-not (supertag-tag-parent book)))))

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
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt _table &rest _)
                     (if (string-prefix-p "Tag:" prompt)
                         (error "Should not prompt for the tag itself")
                       "media"))))
          (supertag-tag-set-parent))
        (should (equal media (supertag-tag-parent
                               (supertag-tag-resolve-occurrence "book"))))))))

;;; --- supertag-tag-affixate-candidates hierarchy prefix ---

(ert-deftest supertag-tag-affixate-shows-ancestor-chain-for-flat-candidates ()
  (supertag-tag-manager-test--with-store
    (let* ((media (plist-get (supertag-tag-create '(:name "media")) :id))
           (book (plist-get (supertag-tag-create `(:name "book" :extends ,media))
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
                              :extends "media" :aliases '("book")))
          (supertag-store-put-entity
           :tags "novel" (list :id "novel" :name "novel" :type :tag
                               :extends "book" :aliases '("novel" "fiction")))
          (supertag-store-put-entity
           :tags "work" (list :id "work" :name "work" :type :tag
                              :aliases '("work")))
          (supertag-store-put-entity
           :tags "ghost" (list :id "ghost" :name "ghost" :type :tag
                               :extends "missing-parent" :aliases '("ghost")))
          (supertag-store-put-entity
           :nodes "n1" (list :id "n1" :title "N1" :tags '("media")))
          (supertag-store-put-entity
           :nodes "n2" (list :id "n2" :title "N2" :tags '("book")))
          (let ((buffer (supertag-view-tags)))
            (with-current-buffer buffer
              (should (derived-mode-p 'supertag-view-tags-mode))
              (let ((text (buffer-string)))
                (should (string-match-p "^media  (1 个节点)$" text))
                (should (string-match-p "^  book  (1 个节点)$" text))
                (should (string-match-p
                         "^    novel  (0 个节点)  别名: fiction$" text))
                (should (string-match-p "^work  (0 个节点)$" text))
                (should (string-match-p "^ghost  (0 个节点)  \\[Orphan" text)))
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
              (should (equal "media" (supertag-tag-parent
                                       (supertag-tag-resolve-occurrence "book"))))
              (should (string-match-p "^  book  (0 个节点)$" (buffer-string)))
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
              (should (string-match-p "^book  (0 个节点)$" (buffer-string)))
              (search-forward "book")
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) "media")))
                (supertag-view-tags-set-parent))
              (should (equal "media" (supertag-tag-parent "book")))
              (should (string-match-p "^  book  (0 个节点)$" (buffer-string)))
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

(provide 'tag-manager-test)
;;; tag-manager-test.el ends here
