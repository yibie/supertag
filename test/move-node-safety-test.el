;;; move-node-safety-test.el --- Safe relocation contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'supertag-service-org)

(defun supertag-move-test--disk (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defmacro supertag-move-test--fixture (&rest body)
  (declare (indent 0))
  `(let* ((dir (make-temp-file "supertag-move-test-" t))
          (source (expand-file-name "source.org" dir))
          (target (expand-file-name "target.org" dir))
          (original "* 中文\n:PROPERTIES:\n:ID: parent\n:END:\nBody\n** Child\n:PROPERTIES:\n:ID: child\n:END:\nChild body\n* Stay\n")
          (destination "* Existing\n")
          (supertag-sync--internal-modifications (make-hash-table :test 'equal))
          (projector (symbol-function 'supertag-service-org--retry-move-projection))
          (supertag--store nil)
          (supertag--subscribers (make-hash-table :test 'equal))
          sb tb projected)
     (unwind-protect
         (progn
           (with-temp-file source (insert original))
           (with-temp-file target (insert destination))
           (supertag--ensure-store)
           (setq sb (find-file-noselect source) tb (find-file-noselect target))
           (cl-letf (((symbol-function 'supertag-node-location-find)
                      (lambda (_) (with-current-buffer sb (copy-marker 1))))
                     ((symbol-function 'supertag-service-org--retry-move-projection)
                      (lambda (&rest args) (setq projected args))))
             ,@body))
       (dolist (b (list sb tb))
         (when (buffer-live-p b)
           (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
       (delete-directory dir t))))

(ert-deftest supertag-move-preserves-subtree-and-stub ()
  (supertag-move-test--fixture
    (should (supertag-service-org-move-node-to-file "parent" target t 2))
    (should (string-match-p "\n\\*\\*\\* Child" (supertag-move-test--disk target)))
    (should (string-match-p ":ID: child" (supertag-move-test--disk target)))
    (should (string-match-p "\\[\\[id:parent\\]" (supertag-move-test--disk source)))
    (should-not (string-match-p ":ID: parent" (supertag-move-test--disk source)))
    (should projected)))

(ert-deftest supertag-move-save-failures-restore-disk-and-unsaved-buffers ()
  (dolist (fail '(1 2))
    (supertag-move-test--fixture
      (with-current-buffer sb (goto-char (point-max)) (insert "source draft\n"))
      (with-current-buffer tb (goto-char (point-max)) (insert "target draft\n"))
      (let ((save (symbol-function 'save-buffer)) (calls 0))
        (cl-letf (((symbol-function 'save-buffer)
                   (lambda (&rest args)
                     (apply save args)
                     (when (= (cl-incf calls) fail) (error "partial save")))))
          (should-error (supertag-service-org-move-node-to-file "parent" target))))
      (should (equal original (supertag-move-test--disk source)))
      (should (equal destination (supertag-move-test--disk target)))
      (with-current-buffer sb
        (should (equal (concat original "source draft\n") (buffer-string)))
        (should (buffer-modified-p)))
      (with-current-buffer tb
        (should (equal (concat destination "target draft\n") (buffer-string)))
        (should (buffer-modified-p)))
      (should-not projected))))

(ert-deftest supertag-move-rejects-physical-alias-and-invalid-level ()
  (supertag-move-test--fixture
    (let ((alias (expand-file-name "alias.org" dir)))
      (make-symbolic-link source alias)
      (should-error (supertag-service-org-move-node-to-file "parent" alias)))
    (dolist (level '(0 -1 "2"))
      (should-error (supertag-service-org-move-node-to-file "parent" target nil level)))
    (should (equal original (supertag-move-test--disk source)))
    (should (equal destination (supertag-move-test--disk target)))))

(ert-deftest supertag-move-readonly-validates-before-edits ()
  (supertag-move-test--fixture
    (with-current-buffer sb (setq buffer-read-only t))
    (should-error (supertag-service-org-move-node-to-file "parent" target))
    (should (equal destination (supertag-move-test--disk target)))))

(ert-deftest supertag-move-quit-compensates ()
  (supertag-move-test--fixture
    (let ((save (symbol-function 'save-buffer)))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args) (apply save args) (signal 'quit nil))))
        (should (eq 'quit
                    (condition-case nil
                        (supertag-service-org-move-node-to-file "parent" target)
                      (quit 'quit))))))
    (should (equal destination (supertag-move-test--disk target)))
    (should (equal original (supertag-move-test--disk source)))
    (should-not projected)))

(ert-deftest supertag-move-projection-failure-keeps-durable-documents ()
  (supertag-move-test--fixture
    (cl-letf (((symbol-function 'supertag-service-org--retry-move-projection)
               (lambda (&rest _) (error "projector failed"))))
      (should-error (supertag-service-org-move-node-to-file "parent" target)
                    :type 'supertag-projection-error))
    (should-not (string-match-p ":ID: parent" (supertag-move-test--disk source)))
    (should (string-match-p ":ID: parent" (supertag-move-test--disk target)))))

(ert-deftest supertag-move-projects-child-locations-after-both-saves ()
  (supertag-move-test--fixture
    (cl-letf (((symbol-function 'supertag-service-org--retry-move-projection)
               (lambda (&rest args)
                 (should-not (string-match-p ":ID: parent" (supertag-move-test--disk source)))
                 (should (string-match-p ":ID: child" (supertag-move-test--disk target)))
                 (apply projector args))))
      (supertag-service-org-move-node-to-file "parent" target))
    (dolist (id '("parent" "child"))
      (let ((node (supertag-node-get id)))
        (should (equal (file-truename target) (plist-get node :file)))
        (with-current-buffer tb
          (goto-char (plist-get node :position))
          (should (equal id (org-entry-get nil "ID"))))))))

(ert-deftest supertag-move-recovery-failure-retains-snapshots ()
  (supertag-move-test--fixture
    (let ((save (symbol-function 'save-buffer)) (write (symbol-function 'write-region))
          failed result)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (apply save args) (setq failed t) (error "save failed")))
                ((symbol-function 'write-region)
                 (lambda (&rest args)
                   (if failed (error "disk unavailable") (apply write args)))))
        (setq result (should-error (supertag-service-org-move-node-to-file "parent" target)
                                   :type 'supertag-move-recovery-error)))
      (should (plist-get (cdr result) :snapshots))
      (should (plist-get (cdr result) :recovery-errors))
      (with-current-buffer tb
        (should (equal destination (buffer-string)))
        (should (buffer-modified-p))))
    (should-not projected)))

(ert-deftest supertag-move-omits-intermediate-sync-hook ()
  (supertag-move-test--fixture
    (let (observed)
      (dolist (b (list sb tb))
        (with-current-buffer b
          (setq-local after-save-hook '(supertag-sync--run-on-save))))
      (cl-letf (((symbol-function 'supertag-sync--run-on-save)
                 (lambda () (setq observed t))))
        (supertag-service-org-move-node-to-file "parent" target))
      (should-not observed)
      (should (= 0 (hash-table-count supertag-sync--internal-modifications))))))

(ert-deftest supertag-move-new-target-failure-restores-absence ()
  (supertag-move-test--fixture
    (delete-file target)
    (with-current-buffer tb (erase-buffer) (set-buffer-modified-p nil)
                         (clear-visited-file-modtime))
    (let ((save (symbol-function 'save-buffer)) (calls 0))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (when (= (cl-incf calls) 2) (error "source failed"))
                   (apply save args))))
        (should-error (supertag-service-org-move-node-to-file "parent" target))))
    (should-not (file-exists-p target))
    (should (equal original (supertag-move-test--disk source)))))

(ert-deftest supertag-move-single-heading-file-and-draft-flags ()
  (supertag-move-test--fixture
    (with-current-buffer sb
      (goto-char (point-max)) (search-backward "* Stay") (delete-region (point) (point-max)))
    (with-current-buffer tb (goto-char (point-max)) (insert "draft\n"))
    (supertag-service-org-move-node-to-file "parent" target)
    (should (equal "" (supertag-move-test--disk source)))
    (should (string-match-p "draft\n" (supertag-move-test--disk target)))
    (with-current-buffer sb (should (buffer-modified-p)))
    (with-current-buffer tb (should (buffer-modified-p)))))

(ert-deftest supertag-move-recovery-does-not-overwrite-external-target-change ()
  (supertag-move-test--fixture
    (let ((save (symbol-function 'save-buffer)))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (if (eq (current-buffer) sb)
                       (progn (with-temp-file target (insert "external update\n"))
                              (error "source failed"))
                     (apply save args)))))
        (should-error (supertag-service-org-move-node-to-file "parent" target)
                      :type 'supertag-move-recovery-error)))
    (should (equal "external update\n" (supertag-move-test--disk target)))
    (should (equal original (supertag-move-test--disk source)))))

(ert-deftest supertag-move-revalidates-source-before-deleting ()
  (supertag-move-test--fixture
    (let ((save (symbol-function 'save-buffer)))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (apply save args)
                   (with-current-buffer sb
                     (goto-char (point-max)) (insert "intervening edit\n")))))
        (should-error (supertag-service-org-move-node-to-file "parent" target))))
    (with-current-buffer sb
      (should (equal (concat original "intervening edit\n") (buffer-string))))
    (should (equal destination (supertag-move-test--disk target)))))

(ert-deftest supertag-move-failure-restores-narrowing ()
  (supertag-move-test--fixture
    (with-current-buffer sb (narrow-to-region 1 6) (goto-char 3))
    (cl-letf (((symbol-function 'save-buffer) (lambda (&rest _) (error "fail"))))
      (should-error (supertag-service-org-move-node-to-file "parent" target)))
    (with-current-buffer sb
      (should (= 1 (point-min)))
      (should (= 6 (point-max)))
      (should (= 3 (point))))))

(ert-deftest supertag-move-projection-rollback-is-whole-subtree ()
  (supertag-move-test--fixture
    (let ((project-node (symbol-function 'supertag-service-org-retry-node-projection)))
      (cl-letf (((symbol-function 'supertag-service-org--retry-move-projection) projector)
                ((symbol-function 'supertag-service-org-retry-node-projection)
                 (lambda (id file)
                   (if (equal id "child") (error "child failed")
                     (funcall project-node id file)))))
        (should-error (supertag-service-org-move-node-to-file "parent" target)
                      :type 'supertag-projection-error)))
    (should-not (supertag-node-get "parent"))
    (should-not (supertag-node-get "child"))
    (should (string-match-p ":ID: child" (supertag-move-test--disk target)))))

(ert-deftest supertag-move-rejects-save-hooks-rewriting-moved-content ()
  (supertag-move-test--fixture
    (with-current-buffer tb
      (setq-local before-save-hook
                  (list (lambda ()
                          (goto-char (point-min))
                          (when (search-forward "Child body" nil t)
                            (replace-match "lost child body"))))))
    (should-error (supertag-service-org-move-node-to-file "parent" target))
    (should (equal original (supertag-move-test--disk source)))
    (should (equal destination (supertag-move-test--disk target)))
    (should-not projected)))

(ert-deftest supertag-move-projection-quit-has-retry-data ()
  (supertag-move-test--fixture
    (cl-letf (((symbol-function 'supertag-service-org--retry-move-projection)
               (lambda (&rest _) (signal 'quit nil))))
      (let ((err (should-error (supertag-service-org-move-node-to-file "parent" target)
                               :type 'supertag-projection-error)))
        (should (equal (list source target) (plist-get (cdr err) :retry-args)))))
    (should-not (string-match-p ":ID: parent" (supertag-move-test--disk source)))))

(ert-deftest supertag-move-validates-target-and-existing-ids-before-editing ()
  (supertag-move-test--fixture
    (should-error (supertag-service-org-move-node-to-file "parent" source))
    (with-current-buffer tb (setq buffer-read-only t))
    (should-error (supertag-service-org-move-node-to-file "parent" target))
    (with-current-buffer tb
      (setq buffer-read-only nil)
      (goto-char (point-max))
      (insert "* Duplicate\n:PROPERTIES:\n:ID: child\n:END:\n"))
    (should-error (supertag-service-org-move-node-to-file "parent" target))
    (should (equal original (supertag-move-test--disk source)))
    (should (equal destination (supertag-move-test--disk target)))
    (should-not projected)))

(ert-deftest supertag-move-saves-target-then-source-only-once ()
  (supertag-move-test--fixture
    (let ((save (symbol-function 'save-buffer)) order)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (push (buffer-file-name) order)
                   (apply save args))))
        (supertag-service-org-move-node-to-file "parent" target t))
      (should (equal (list target source) (nreverse order))))
    (with-current-buffer sb (should-not (buffer-modified-p)))
    (with-current-buffer tb (should-not (buffer-modified-p)))))

(ert-deftest supertag-move-failure-suppresses-all-supertag-save-side-effects ()
  (supertag-move-test--fixture
    (let ((save (symbol-function 'save-buffer)) observed
          (default-hooks (default-value 'after-save-hook)))
      (unwind-protect
          (progn
            (set-default 'after-save-hook
                         '(supertag-embed-sync-modified-blocks supertag-git-sync--on-file-saved))
            (dolist (b (list sb tb))
              (with-current-buffer b
                (setq-local after-save-hook '(supertag-sync--run-on-save
                                             supertag-services-embed-on-source-save t))))
            (cl-letf (((symbol-function 'supertag-sync--run-on-save) (lambda () (push 'sync observed)))
                      ((symbol-function 'supertag-embed-sync-modified-blocks) (lambda () (push 'embed observed)))
                      ((symbol-function 'supertag-services-embed-on-source-save) (lambda () (push 'source observed)))
                      ((symbol-function 'supertag-git-sync--on-file-saved) (lambda () (push 'git observed)))
                      ((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (apply save args)
                         (when (eq (current-buffer) sb) (error "source save failed")))))
              (should-error (supertag-service-org-move-node-to-file "parent" target)))
            (should-not observed))
        (set-default 'after-save-hook default-hooks)))))

(ert-deftest supertag-move-notifies-git-after-durable-documents ()
  (supertag-move-test--fixture
    (let (observed)
      (dolist (b (list sb tb))
        (with-current-buffer b (setq-local after-save-hook '(supertag-git-sync--on-file-saved))))
      (cl-letf (((symbol-function 'supertag-git-sync--on-file-saved)
                 (lambda ()
                   (push (list (buffer-file-name)
                               (supertag-move-test--disk source)
                               (supertag-move-test--disk target)
                               projected)
                         observed))))
        (supertag-service-org-move-node-to-file "parent" target))
      (should (equal (list source target) (mapcar #'car (reverse observed))))
      (dolist (snapshot observed)
        (should-not (string-match-p ":ID: parent" (nth 1 snapshot)))
        (should (string-match-p ":ID: child" (nth 2 snapshot)))
        (should (nth 3 snapshot))))))

(ert-deftest supertag-move-git-unavailable-or-failed-keeps-third-party-hooks ()
  (dolist (available '(nil t))
    (supertag-move-test--fixture
      (let ((other-calls 0) (git-calls 0))
        (dolist (b (list sb tb))
          (with-current-buffer b
            (setq-local after-save-hook (list (lambda () (cl-incf other-calls))))))
        (cl-letf (((symbol-function 'supertag-git-sync--on-file-saved)
                   (and available (lambda () (cl-incf git-calls) (error "Git unavailable")))))
          (should (supertag-service-org-move-node-to-file "parent" target)))
        (should (= (if available 2 0) git-calls))
        (should (= 2 other-calls))))))
