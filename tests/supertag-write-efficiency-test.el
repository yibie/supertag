;;; supertag-write-efficiency-test.el --- Write-flow efficiency tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'supertag-services-capture)
(require 'supertag-services-ui)
(require 'supertag-ui-commands)

(ert-deftest supertag-capture-target-reader-defaults-to-session-memory ()
  "The previous successful target is the one-key file default."
  (let* ((file (make-temp-file "supertag-capture-target" nil ".org"))
         (supertag-capture--session-target-file file)
         (supertag-capture-persist-last-target nil)
         seen-default)
    (unwind-protect
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (_prompt _directory default &rest _)
                     (setq seen-default default)
                     default)))
          (should (equal file (supertag-capture-read-target-file)))
          (should (equal file seen-default)))
      (delete-file file))))

(ert-deftest supertag-capture-target-memory-persists-only-when-enabled ()
  "Session memory is unconditional; Custom persistence is opt-in."
  (let ((file (expand-file-name "capture.org" temporary-file-directory))
        (supertag-capture--session-target-file nil)
        (supertag-capture-persisted-target-file nil)
        (supertag-capture-persist-last-target nil)
        saved)
    (cl-letf (((symbol-function 'customize-save-variable)
               (lambda (symbol value)
                 (setq saved (list symbol value)))))
      (supertag-capture-remember-target-file file)
      (should (equal file supertag-capture--session-target-file))
      (should-not saved)
      (let ((supertag-capture-persist-last-target t))
        (supertag-capture-remember-target-file file)
        (should (equal file supertag-capture-persisted-target-file))
        (should (equal (list 'supertag-capture-persisted-target-file file)
                       saved))))))

(ert-deftest supertag-capture-position-ret-uses-safe-subtree-boundary ()
  "RET keeps the current note intact and inserts before the next heading."
  (let* ((file (make-temp-file "supertag-capture-position" nil ".org"
                               (concat "* Existing\n"
                                       "First half of the paragraph, "
                                       "second half stays here.\n"
                                       "* Next\nNext body\n")))
         (buffer (find-file-noselect file))
         seen-default)
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (goto-char (point-min))
          (search-forward "paragraph")
          (let ((suggested (point)))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt _collection &optional _predicate
                                _require-match _initial _history default &rest _)
                         (setq seen-default default)
                         default)))
              (let ((result (supertag-ui-select-insert-position file suggested)))
                (should (equal "Current Position" seen-default))
                (goto-char (point-min))
                (re-search-forward "^\\* Next$")
                (should (= (line-beginning-position)
                           (plist-get result :position)))
                (should (= 1 (plist-get result :level)))
                (goto-char (plist-get result :position))
                (insert "* Captured\n")
                (goto-char (point-min))
                (should (search-forward
                         (concat "First half of the paragraph, "
                                 "second half stays here.\n"
                                 "* Captured\n* Next")
                         nil t))))))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)
      (delete-file file))))

(ert-deftest supertag-capture-position-ret-uses-file-end ()
  "RET accepts file end when the selected target is not the current file."
  (let* ((file (make-temp-file "supertag-capture-position" nil ".org"
                               "* Existing\n"))
         (buffer (find-file-noselect file))
         seen-default)
    (unwind-protect
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt _collection &optional _predicate
                            _require-match _initial _history default &rest _)
                     (setq seen-default default)
                     default)))
          (let ((result (supertag-ui-select-insert-position file)))
            (should (equal "File End" seen-default))
            (with-current-buffer buffer
              (should (= (point-max) (plist-get result :position))))))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)
      (delete-file file))))

(ert-deftest supertag-capture-headline-can-skip-tags ()
  "Declining the Tag round does not open Tag completion."
  (cl-letf (((symbol-function 'read-string)
             (lambda (&rest _) "Title"))
            ((symbol-function 'y-or-n-p)
             (lambda (&rest _) nil))
            ((symbol-function 'supertag-ui-read-tags)
             (lambda (&rest _)
               (ert-fail "Tag completion should have been skipped"))))
    (should (equal '(:headline "Title" :tags nil)
                   (supertag-capture-interactive-headline)))))

(ert-deftest supertag-capture-can-defer-fields-and-remembers-successful-target ()
  "Deferring fields performs no field edit and still remembers the target."
  (let ((file (make-temp-file "supertag-capture-defer" nil ".org"))
        remembered)
    (unwind-protect
        (cl-letf (((symbol-function 'supertag-capture-interactive-headline)
                   (lambda () '(:headline "Captured" :tags ("project"))))
                  ((symbol-function 'read-string) (lambda (&rest _) ""))
                  ((symbol-function 'supertag-ui-select-insert-position)
                   (lambda (_file) '(:position 1 :level 1)))
                  ((symbol-function 'supertag-node-identity-new)
                   (lambda () "node-1"))
                  ((symbol-function 'supertag-capture--insert-node-into-buffer)
                   #'ignore)
                  ((symbol-function 'supertag-node-create) #'identity)
                  ((symbol-function 'supertag-capture-add-tags-to-nodes)
                   (lambda (&rest _) '("project")))
                  ((symbol-function 'supertag-tag-get-all-fields)
                   (lambda (_tag-id) '((:name "Summary" :type :string))))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                  ((symbol-function 'supertag-edit-fields)
                   (lambda (&rest _)
                     (ert-fail "Deferred fields must not be edited")))
                  ((symbol-function 'supertag-capture-remember-target-file)
                   (lambda (target) (setq remembered target))))
          (should (equal "node-1" (supertag-capture file)))
          (should (equal (expand-file-name file) remembered)))
      (delete-file file))))

(ert-deftest supertag-edit-fields-prompts-all-and-writes-once ()
  "The page editor carries defaults, omits unchanged values, and batches writes."
  (let* ((fields '((:id "summary" :name "Summary" :type :string)
                   (:id "effort" :name "Effort" :type :integer)))
         (current-values '(("Summary" . "old") ("Effort" . 1)))
         seen-defaults
         written)
    (cl-letf (((symbol-function 'supertag-node-get)
               (lambda (_node-id) '(:id "node-1")))
              ((symbol-function 'supertag-ui--ensure-node-synced) #'ignore)
              ((symbol-function 'supertag-view--resolve-node-tags)
               (lambda (_node-id) '("project")))
              ((symbol-function 'supertag-tag-get-all-fields)
               (lambda (_tag-id) fields))
              ((symbol-function 'supertag-field-get-with-default)
               (lambda (_node-id _tag-id field-name)
                 (cdr (assoc field-name current-values))))
              ((symbol-function 'supertag-ui-read-field-value)
               (lambda (field current)
                 (push (cons (plist-get field :name) current) seen-defaults)
                 (if (equal (plist-get field :name) "Effort") "3" current)))
              ((symbol-function 'supertag-field-set-many)
               (lambda (node-id specs)
                 (setq written (list node-id specs)))))
      (should (= 1 (supertag-edit-fields "node-1" "project")))
      (should (equal '(("Summary" . "old") ("Effort" . 1))
                     (nreverse seen-defaults)))
      (should (equal "node-1" (car written)))
      (should
       (equal '((:tag "project" :field "Effort" :value "3"
                      :provenance (:origin :human)))
              (cadr written))))))

(ert-deftest supertag-node-reference-single-uses-one-completion ()
  "A scalar node-reference bypasses the Add/Done multi-select state machine."
  (let (single-initial multi-called)
    (cl-letf (((symbol-function 'supertag-ui-select-node)
               (lambda (_prompt _use-cache _with-preview initial)
                 (setq single-initial initial)
                 "new-node"))
              ((symbol-function 'supertag-ui-select-multiple-nodes)
               (lambda (&rest _)
                 (setq multi-called t)
                 nil)))
      (should (equal "new-node"
                     (supertag-ui-read-field-value
                      '(:name "Owner" :type :node-reference)
                      "old-node")))
      (should (equal "old-node" single-initial))
      (should-not multi-called))))

(ert-deftest supertag-node-reference-multiple-keeps-state-machine ()
  "An explicitly multi-valued node-reference retains the existing selector."
  (let (single-called seen-initial)
    (cl-letf (((symbol-function 'supertag-ui-select-node)
               (lambda (&rest _)
                 (setq single-called t)
                 nil))
              ((symbol-function 'supertag-ui-select-multiple-nodes)
               (lambda (_prompt _use-cache initial &rest _)
                 (setq seen-initial initial)
                 '("old-node" "new-node"))))
      (should (equal '("old-node" "new-node")
                     (supertag-ui-read-field-value
                      '(:name "Related" :type :node-reference :multiple t)
                      "old-node")))
      (should (equal '("old-node") seen-initial))
      (should-not single-called))))

(provide 'supertag-write-efficiency-test)

;;; supertag-write-efficiency-test.el ends here
