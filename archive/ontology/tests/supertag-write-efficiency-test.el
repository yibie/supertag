;;; supertag-write-efficiency-test.el --- Write-flow efficiency tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'supertag-node)
(require 'supertag-services-ui)
(require 'supertag-ui-commands)

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

(ert-deftest supertag-independent-capture-command-is-retired ()
  "The standalone Capture UI no longer owns a field-fill workflow."
  (should-not (fboundp 'supertag-capture)))

(ert-deftest supertag-standalone-field-page-editor-is-retired ()
  "The old continuous field editor no longer remains callable."
  (should-not (fboundp 'supertag-edit-fields)))

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
