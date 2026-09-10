;;; tag-merge-plan-test.el --- Tag merge plan file preflight -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'supertag-tag)

(defmacro supertag-merge-plan-test--with-store (&rest body)
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-merge-plan-" t))
          (supertag-data-directory tmp)
          (supertag--base-data-directory tmp)
          (supertag-db-file (expand-file-name "store.el" tmp))
          (supertag--store nil)
          (supertag--subscribers (make-hash-table :test 'equal)))
     (unwind-protect
         (progn (supertag--ensure-store) ,@body)
       (delete-directory tmp t))))

(ert-deftest supertag-tag-merge-plan-reports-missing-file ()
  (supertag-merge-plan-test--with-store
    (let ((a (plist-get (supertag-tag-create '(:name "a")) :id))
          (b (plist-get (supertag-tag-create '(:name "b")) :id)))
      (supertag-store-put-entity
       :nodes "node" (list :id "node" :title "Node" :tags (list a)
                           :file (expand-file-name "missing.org" tmp)))
      (let ((plan (supertag-tag-merge-plan (list a b) b)))
        (should (cl-find :missing-file (plist-get plan :conflicts)
                         :key (lambda (item) (plist-get item :kind))))
        (should-error (supertag-tag-merge-execute plan))
        (should (supertag-tag-get a))))))

(ert-deftest supertag-tag-merge-plan-reports-unsaved-buffer ()
  (supertag-merge-plan-test--with-store
    (let* ((a (plist-get (supertag-tag-create '(:name "a")) :id))
           (b (plist-get (supertag-tag-create '(:name "b")) :id))
           (file (expand-file-name "node.org" tmp))
           (text "* Node\n")
           buffer)
      (write-region text nil file nil 'silent)
      (supertag-store-put-entity
       :nodes "node" (list :id "node" :title "Node" :tags (list a) :file file))
      (unwind-protect
          (progn
            (setq buffer (find-file-noselect file))
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "x"))
            (let ((plan (supertag-tag-merge-plan (list a b) b)))
              (should (cl-find :unsaved-buffer (plist-get plan :conflicts)
                               :key (lambda (item) (plist-get item :kind))))
              (should-error (supertag-tag-merge-execute plan))
              (should (supertag-tag-get a))
              (should (equal text (with-temp-buffer
                                    (insert-file-contents file)
                                    (buffer-string))))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(provide 'tag-merge-plan-test)

;;; Current API file writes and rollback, independent of retired field fixtures.

(defun supertag-merge-plan-test--disk (file)
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun supertag-merge-plan-test--snapshot (files)
  (list (mapcar (lambda (file)
                  (with-current-buffer (find-file-noselect file)
                    (list (supertag-merge-plan-test--disk file)
                          (buffer-string) (buffer-modified-p))))
                files)
        ;; Canonical values compare contents, not hash-table object identity.
        (supertag--persistence--canonicalize-value supertag--store)
        (copy-tree supertag-query-saved)
        (supertag--persistence--canonicalize-value supertag--view-configs)))

(defmacro supertag-merge-plan-test--with-files (operation &rest body)
  (declare (indent 1))
  `(supertag-merge-plan-test--with-store
     (let* ((operation ,operation)
            (sources (if (eq operation 'rename) '("old") '("old" "other")))
            (targets '("new"))
            (second-source (or (cadr sources) (car sources)))
            (files (list (expand-file-name "one.org" tmp)
                         (expand-file-name "two.org" tmp)))
            (supertag-query-saved
             (list (cons "retained" (prin1-to-string (cons 'has-any-tag sources)))))
            (supertag--view-configs (make-hash-table :test 'eq))
            (org-mode-hook nil) (find-file-hook nil) (after-save-hook nil)
            (org-id-locations-file (expand-file-name "ids" tmp))
            (supertag-db-backup-directory (expand-file-name "backups" tmp))
            (supertag-sync-directories nil)
            (supertag-active-sync-directory nil))
       (unwind-protect
           (progn
             (dolist (id sources) (supertag-tag-create (list :id id :name id)))
             (when (eq operation 'rename)
               (supertag-tag-create '(:id "child" :name "child" :extends "old")))
             (puthash 'retained (list :id 'retained :tag (car sources) :tags (copy-sequence sources))
                      supertag--view-configs)
             (cl-loop for file in files for index from 1 do
                      (let ((id (format "merge-node-%s" index)))
                        (with-temp-file file
                          (insert (format "#+FILETAGS: :%s:%s:\n* Note\n:PROPERTIES:\n:ID: %s\n:END:\nBody #%s #%s\n#+CAPTION: #%s\n#+begin_src text\n#%s\n#+end_src\n"
                                          (car sources) second-source id
                                          (car sources) second-source
                                          (car sources) (car sources))))
                        (supertag-store-put-entity
                         :nodes id (list :id id :title "Note" :type :node :file file
                                         :tags (copy-sequence sources)
                                         :tag-occurrences (copy-sequence sources)))))
             ,@body)
         (dolist (file files)
           (when-let* ((buffer (get-file-buffer file)))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))))))

(defun supertag-merge-plan-test--plan (operation sources)
  (if (eq operation 'rename)
      (supertag-tag-rename-plan "old" "new")
    (supertag-tag-merge-plan sources "new")))

(defun supertag-merge-plan-test--execute (operation plan)
  (if (eq operation 'rename)
      (supertag-tag-rename-execute plan)
    (supertag-tag-merge-execute plan)))

(defun supertag-merge-plan-test--assert-success (operation sources targets files)
  (dolist (source sources) (should-not (supertag-tag-get source)))
  (dolist (target targets) (should (supertag-tag-get target)))
  (when (eq operation 'rename)
    (should (equal "new" (supertag-tag-parent "child")))
    (should (equal '("child") (supertag-query-tag-children "new"))))
  (dolist (id '("merge-node-1" "merge-node-2"))
    (should (equal targets (plist-get (supertag-node-get id) :tags))))
  (should (equal (cons 'has-any-tag targets)
                 (read (cdr (assoc "retained" supertag-query-saved)))))
  (should (equal "new" (plist-get (gethash 'retained supertag--view-configs) :tag)))
  (should (equal targets (plist-get (gethash 'retained supertag--view-configs) :tags)))
  (dolist (file files)
    (let* ((second "new")
           (disk (supertag-merge-plan-test--disk file)))
      (should (string-match-p (regexp-quote (format "#+FILETAGS: :new:%s:" second)) disk))
      (should (string-match-p (regexp-quote (format "Body #new #%s" second)) disk))
      (should (string-match-p (regexp-quote "#+CAPTION: #old\n#+begin_src text\n#old\n#+end_src") disk))
      (with-current-buffer (find-file-noselect file)
        (should (equal disk (buffer-string)))
        (should-not (buffer-modified-p))))))

(ert-deftest supertag-tag-merge-current-api-writes-files-and-registries ()
  (supertag-merge-plan-test--with-files 'merge
    (let* ((before (supertag-merge-plan-test--snapshot files))
           (plan (supertag-merge-plan-test--plan operation sources)))
      (should-not (plist-get plan :conflicts))
      (should (equal before (supertag-merge-plan-test--snapshot files)))
      (let ((result (supertag-merge-plan-test--execute operation plan)))
        (should (eq :merged (plist-get result :status)))
        (should (= 8 (plist-get result :file-change-count))))
      (supertag-merge-plan-test--assert-success operation sources targets files))))

(ert-deftest supertag-tag-merge-namespace-current-api-writes-files-and-registries ()
  (supertag-merge-plan-test--with-files 'rename
    (let* ((before (supertag-merge-plan-test--snapshot files))
           (plan (supertag-merge-plan-test--plan operation sources)))
      (should-not (plist-get plan :conflicts))
      (should (equal before (supertag-merge-plan-test--snapshot files)))
      (let ((result (supertag-merge-plan-test--execute operation plan)))
        (should (eq :renamed (plist-get result :status)))
        (should (= 8 (plist-get result :file-change-count))))
      (supertag-merge-plan-test--assert-success operation sources targets files))))

(ert-deftest supertag-tag-merge-current-api-restores-after-later-file-pass-error ()
  (dolist (kind '(merge rename))
    (supertag-merge-plan-test--with-files kind
      (let* ((before (supertag-merge-plan-test--snapshot files))
             (plan (supertag-merge-plan-test--plan operation sources))
             (original (symbol-function 'supertag-view-helper-rename-tag-text-in-files))
             (calls 0) wrote-first-pass)
        (cl-letf
            (((symbol-function 'supertag-view-helper-rename-tag-text-in-files)
              (lambda (&rest args)
                (cl-incf calls)
                (cond
                 ((and (eq operation 'rename) (= calls 1))
                  ;; Rename now has one mapping.  Fail after its first file
                  ;; was written, not in a removed descendant-mapping pass.
                  (funcall original (nth 0 args) (nth 1 args)
                           (list (car files)))
                  (setq wrote-first-pass
                        (not (equal (caaar before)
                                    (supertag-merge-plan-test--disk
                                     (car files)))))
                  (error "injected later file pass"))
                 ((= calls 1)
                  (prog1 (apply original args)
                    (setq wrote-first-pass
                          (not (equal (caaar before)
                                      (supertag-merge-plan-test--disk
                                       (car files)))))))
                 (t (error "injected later file pass"))))))
          (should (equal "injected later file pass"
                         (error-message-string
                          (should-error (supertag-merge-plan-test--execute operation plan))))))
        (should wrote-first-pass)
        (should (= calls (if (eq operation 'rename) 1 2)))
        (should (equal before (supertag-merge-plan-test--snapshot files)))))))

(ert-deftest supertag-tag-merge-current-api-restores-after-derived-index-error ()
  (dolist (kind '(merge rename))
    (supertag-merge-plan-test--with-files kind
      (let* ((before (supertag-merge-plan-test--snapshot files))
             (plan (supertag-merge-plan-test--plan operation sources))
             (original (symbol-function 'supertag-tag-merge--rebuild-derived-state))
             (calls 0) wrote-all-passes)
        (cl-letf (((symbol-function 'supertag-tag-merge--rebuild-derived-state)
                   (lambda ()
                     (cl-incf calls)
                     (if (= calls 1)
                         (progn
                           (setq wrote-all-passes
                                 (cl-every (lambda (file)
                                             (string-match-p "Body #new #new"
                                                             (supertag-merge-plan-test--disk file)))
                                           files))
                           (error "injected derived index"))
                       (funcall original)))))
          (should (equal "injected derived index"
                         (error-message-string
                          (should-error (supertag-merge-plan-test--execute operation plan))))))
        (should wrote-all-passes)
        (should (= calls 2))
        (should (equal before (supertag-merge-plan-test--snapshot files)))))))

(ert-deftest supertag-tag-merge-current-api-rechecks-draft-after-preview ()
  (dolist (kind '(merge rename))
    (supertag-merge-plan-test--with-files kind
      (let ((plan (supertag-merge-plan-test--plan operation sources)))
        (should-not (plist-get plan :conflicts))
        (with-current-buffer (find-file-noselect (car files))
          (goto-char (point-max)) (insert "New user draft\n"))
        (let ((before (supertag-merge-plan-test--snapshot files)))
          (should-error (supertag-merge-plan-test--execute operation plan))
          (should (equal before (supertag-merge-plan-test--snapshot files))))))))
