;;; move-nodes-position-test.el --- Positional batch relocation -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'supertag-service-org)

(defmacro supertag-position-test--fixture (&rest body)
  (declare (indent 0))
  `(let* ((dir (make-temp-file "supertag-position-" t))
          (a (expand-file-name "a.org" dir))
          (b (expand-file-name "b.org" dir))
          (c (expand-file-name "c.org" dir))
          (atext "* A\n:PROPERTIES:\n:ID: a\n:END:\nA body\n** Child\n:PROPERTIES:\n:ID: child\n:END:\nChild body\n* Z\n:PROPERTIES:\n:ID: z\n:END:\n")
          (btext "* B\n:PROPERTIES:\n:ID: b\n:END:\nB body\n")
          (ctext "* Target\n:PROPERTIES:\n:ID: target\n:END:\nTarget body\n* Last\n")
          (supertag--store nil)
          (supertag--subscribers (make-hash-table :test 'equal))
          (supertag-sync--internal-modifications (make-hash-table :test 'equal))
          ab bb cb)
     (unwind-protect
         (progn
           (with-temp-file a (insert atext))
           (with-temp-file b (insert btext))
           (with-temp-file c (insert ctext))
           (setq ab (find-file-noselect a) bb (find-file-noselect b) cb (find-file-noselect c))
           (supertag--ensure-store)
           (cl-letf (((symbol-function 'supertag-node-location-find)
                      (lambda (id)
                        (cl-loop for buffer in (list ab bb cb)
                                 thereis (with-current-buffer buffer
                                           (save-excursion
                                             (save-restriction
                                               (widen) (goto-char 1)
                                               (when (re-search-forward (concat "^:ID: " id "$") nil t)
                                                 (org-back-to-heading t) (point-marker)))))))))
             ,@body))
       (dolist (buffer (list ab bb cb))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer)))
       (delete-directory dir t))))

(defun supertag-position-test--disk (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest supertag-position-same-file-both-directions ()
  (supertag-position-test--fixture
    (should (equal '("a") (supertag-service-org-move-nodes '("a") a)))
    (should (string-prefix-p "* Z\n" (supertag-position-test--disk a)))
    (should (equal '("a") (supertag-service-org-move-nodes '("a") a 1)))
    (should (equal atext (supertag-position-test--disk a)))))

(ert-deftest supertag-position-batch-nonappend-order-and-level ()
  (supertag-position-test--fixture
    (let ((anchor (with-current-buffer cb (goto-char 1) (search-forward "* Last")
                                       (beginning-of-line) (point-marker))))
      (should (equal '("b" "a") (supertag-service-org-move-nodes '("b" "a") c anchor 2))))
    (let ((text (supertag-position-test--disk c)))
      (should (< (string-match "^\\*\\* B$" text) (string-match "^\\*\\* A$" text)))
      (should (< (string-match "^\\*\\* A$" text) (string-match "^\\* Last$" text)))
      (should (string-match-p "^\\*\\*\\* Child$" text)))
    (should (equal "" (supertag-position-test--disk b)))
    (should (equal (file-truename c) (plist-get (supertag-node-get "child") :file)))))

(ert-deftest supertag-position-normalizes-parent-child-selection ()
  (supertag-position-test--fixture
    (should (equal '("a" "z")
                   (supertag-service-org-move-nodes '("child" "a" "z" "a") c 1)))
    (should (equal "" (supertag-position-test--disk a)))))

(ert-deftest supertag-position-rejects-self-target-before-id-creation ()
  (supertag-position-test--fixture
    (should-error (supertag-service-org-move-nodes '("a") a 10))
    (should (equal atext (supertag-position-test--disk a)))))

(ert-deftest supertag-position-partial-third-save-restores-every-file ()
  (supertag-position-test--fixture
    (let ((save (symbol-function 'save-buffer)) (calls 0))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (apply save args)
                   (when (= 3 (cl-incf calls)) (error "third save failed")))))
        (should-error (supertag-service-org-move-nodes '("a" "b") c 1))))
    (should (equal atext (supertag-position-test--disk a)))
    (should (equal btext (supertag-position-test--disk b)))
    (should (equal ctext (supertag-position-test--disk c)))
    (should-not (supertag-node-get "a"))))

(ert-deftest supertag-position-multi-source-saves-target-then-each-source-once ()
  (supertag-position-test--fixture
    (let ((save (symbol-function 'save-buffer)) order)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (push (buffer-file-name) order)
                   (apply save args))))
        (should (equal '("a" "b")
                       (supertag-service-org-move-nodes '("a" "b") c 1))))
      (should (equal (list c a b) (nreverse order))))))

(ert-deftest supertag-position-readonly-batch-source-fails-before-edits ()
  (supertag-position-test--fixture
    (with-current-buffer bb (setq buffer-read-only t))
    (should-error (supertag-service-org-move-nodes '("a" "b") c 1))
    (should (equal atext (supertag-position-test--disk a)))
    (should (equal btext (supertag-position-test--disk b)))
    (should (equal ctext (supertag-position-test--disk c)))))

(ert-deftest supertag-position-rollback-preserves-caller-marker-for-retry ()
  (supertag-position-test--fixture
    (let ((marker (with-current-buffer ab
                    (goto-char (point-min))
                    (re-search-forward "^:ID: z$")
                    (org-back-to-heading t)
                    (point-marker))))
      (let ((save (symbol-function 'save-buffer)) (calls 0))
        (cl-letf (((symbol-function 'save-buffer)
                   (lambda (&rest args)
                     (apply save args)
                     (when (= 2 (cl-incf calls))
                       (error "source save failed")))))
          (should-error (supertag-service-org-move-nodes (list marker) c 1))))
      (with-current-buffer ab
        (goto-char marker)
        (should (equal "z" (org-entry-get nil "ID"))))
      (should (equal '("z")
                     (supertag-service-org-move-nodes (list marker) c 1)))
      (should (string-match-p ":ID: a" (supertag-position-test--disk a)))
      (should-not (string-match-p ":ID: z" (supertag-position-test--disk a))))))

(ert-deftest supertag-position-rejects-integer-target-inside-property-drawer ()
  (supertag-position-test--fixture
    (let ((inside-drawer
           (with-current-buffer cb
             (goto-char (point-min))
             (search-forward ":ID: target")
             (1- (point))))
          (id-line-end
           (with-current-buffer cb
             (goto-char (point-min))
             (search-forward ":ID: target")
             (line-end-position))))
      (should-error (supertag-service-org-move-nodes '("a") c inside-drawer))
      (should-error (supertag-service-org-move-nodes '("a") c id-line-end))
      (should (equal atext (supertag-position-test--disk a)))
      (should (equal ctext (supertag-position-test--disk c))))))

(ert-deftest supertag-position-rejects-integer-target-inside-org-block ()
  (supertag-position-test--fixture
    (with-current-buffer cb
      (goto-char (point-max))
      (insert "#+begin_src emacs-lisp\n(message \"safe\")\n#+end_src\n")
      (save-buffer))
    (let ((before (supertag-position-test--disk c))
          (inside-block
           (with-current-buffer cb
             (goto-char (point-min))
             (search-forward "message")
             (point))))
      (should-error (supertag-service-org-move-nodes '("a") c inside-block))
      (should (equal atext (supertag-position-test--disk a)))
      (should (equal before (supertag-position-test--disk c))))))

(ert-deftest supertag-position-mixed-target-source-saves-each-file-once ()
  (supertag-position-test--fixture
    (let ((save (symbol-function 'save-buffer)) order)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (push (buffer-file-name) order)
                   (apply save args))))
        (should (equal '("a" "target")
                       (supertag-service-org-move-nodes
                        '("a" "target") c
                        (with-current-buffer cb (point-max))))))
      (should (equal (list c a) (nreverse order))))
    (let ((text (supertag-position-test--disk c)))
      (should (< (string-match "^\\* Last$" text)
                 (string-match "^\\* A$" text)))
      (should (< (string-match "^\\* A$" text)
                 (string-match "^\\* Target$" text))))))

(ert-deftest supertag-position-idless-root-only-and-failure-rollback ()
  (supertag-position-test--fixture
    (with-current-buffer bb (erase-buffer) (insert "* New\n** Unidentified child\n")
                         (goto-char 1))
    (let ((marker (with-current-buffer bb (point-marker))))
      (cl-letf (((symbol-function 'save-buffer) (lambda (&rest _) (error "save failed"))))
        (should-error (supertag-service-org-move-nodes (list marker) c)))
      (with-current-buffer bb
        (should (equal "* New\n** Unidentified child\n" (buffer-string))))
      (let ((ids (supertag-service-org-move-nodes (list marker) c)))
        (should (= 1 (length ids)))
        (with-current-buffer cb
          (goto-char 1) (search-forward "** Unidentified child") (beginning-of-line)
          (should-not (org-entry-get nil "ID")))))))

(ert-deftest supertag-position-rollback-refreshes-org-element-cache ()
  (supertag-position-test--fixture
    ;; Populate the cache before forcing a restore through erase/insert.
    (with-current-buffer ab
      (goto-char (point-min))
      (should (eq 'headline (org-element-type (org-element-at-point)))))
    (cl-letf (((symbol-function 'save-buffer)
               (lambda (&rest _) (error "save failed"))))
      (should-error (supertag-service-org-move-nodes '("a") c 1)))
    (with-current-buffer ab
      (goto-char (point-min))
      (let ((headline (org-element-at-point)))
        (should (eq 'headline (org-element-type headline)))
        (should (equal "A" (org-element-property :raw-value headline)))
        (should (equal "a" (org-entry-get nil "ID")))))))

(ert-deftest supertag-position-accepts-heading-marker-from-indirect-buffer ()
  (supertag-position-test--fixture
    (let ((indirect (with-current-buffer ab
                      (clone-indirect-buffer " *supertag-move-indirect*" nil))))
      (unwind-protect
          (let ((marker (with-current-buffer indirect
                          (goto-char (point-min))
                          (point-marker))))
            (should (equal '("a")
                           (supertag-service-org-move-nodes (list marker) c 1)))
            (should-not (string-match-p ":ID: a" (supertag-position-test--disk a)))
            (should (string-match-p ":ID: a" (supertag-position-test--disk c))))
        (when (buffer-live-p indirect)
          (kill-buffer indirect))))))

(ert-deftest supertag-position-level-adjustment-preserves-escaped-src-body ()
  (supertag-position-test--fixture
    (with-current-buffer bb
      (erase-buffer)
      (insert "* Code\n:PROPERTIES:\n:ID: code\n:END:\n"
              "#+begin_src org\n,* literal body star\n#+end_src\n")
      (save-buffer))
    (should (equal '("code")
                   (supertag-service-org-move-nodes '("code") c 1 2)))
    (let ((text (supertag-position-test--disk c)))
      (should (string-match-p "^\\*\\* Code$" text))
      (should (string-match-p "^,\\* literal body star$" text)))))
