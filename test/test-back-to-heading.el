;;; test-back-to-heading.el --- Tests for node demotion -*- lexical-binding: t; -*-
;; Run: emacs --batch -Q --eval '(package-initialize)' -L . \
;;      -l test/test-back-to-heading.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-ui-commands)

(ert-deftest supertag-back-to-heading-removes-id-and-empty-drawer ()
  "Demoting a node removes its ID and an otherwise empty property drawer."
  (with-temp-buffer
    (org-mode)
    (setq-local buffer-file-name "/tmp/supertag-demote-empty-drawer.org")
    (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\nBody\n")
    (goto-char (point-min))
    (let ((native-comp-enable-subr-trampolines nil)
          deleted-id)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'save-buffer) #'ignore)
                ((symbol-function 'supertag-node-delete)
                 (lambda (node-id) (setq deleted-id node-id))))
        (supertag-back-to-heading))
      (should (equal deleted-id "node-id"))
      (should-not (org-entry-get nil "ID"))
      (should-not (string-match-p "^:PROPERTIES:" (buffer-string)))
      (should (string-match-p "^Body$" (buffer-string))))))

(ert-deftest supertag-back-to-heading-preserves-other-properties ()
  "Demoting a node removes only its ID when other properties remain."
  (with-temp-buffer
    (org-mode)
    (setq-local buffer-file-name "/tmp/supertag-demote-properties.org")
    (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:OWNER:    Alice\n:END:\n")
    (goto-char (point-min))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'save-buffer) #'ignore)
                ((symbol-function 'supertag-node-delete) #'ignore))
        (supertag-back-to-heading)))
    (should-not (org-entry-get nil "ID"))
    (should (equal (org-entry-get nil "OWNER") "Alice"))
    (should (string-match-p "^:PROPERTIES:" (buffer-string)))))

(provide 'test-back-to-heading)
;;; test-back-to-heading.el ends here
