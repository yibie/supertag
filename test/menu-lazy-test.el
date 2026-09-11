;;; menu-lazy-test.el --- Menu native lazy command contract -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)

(defconst supertag-menu-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defun supertag-menu-test--child (body)
  "Run BODY with only Menu loaded in a fresh, isolated Emacs process."
  (let* ((tmp (make-temp-file "supertag-menu-test-" t))
         (script (expand-file-name "child.el" tmp))
         (menu (expand-file-name "supertag-menu.el" supertag-menu-test--root))
         (process-environment (copy-sequence process-environment)))
    (setenv "HOME" tmp)
    (setenv "CFFIXED_USER_HOME" tmp)
    (setenv "XDG_CONFIG_HOME" (expand-file-name ".config" tmp))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1
             `(progn
                (require 'cl-lib) (require 'ert)
                (setq user-emacs-directory ,(file-name-as-directory tmp)
                      after-init-time nil custom-file ,(expand-file-name "custom.el" tmp))
                (defvar sm-test-tmp ,tmp)
                (defvar sm-test-menu ,menu)
                (defvar sm-test-loads 0)
                (defvar sm-test-prefix nil)
                (defun sm-test-write (feature &rest forms)
                  (with-temp-file (expand-file-name (concat (symbol-name feature) ".el") sm-test-tmp)
                    (insert ";;; -*- lexical-binding: t; -*-\n")
                    (dolist (form forms) (prin1 form (current-buffer)) (insert "\n"))))
                (add-to-list 'load-path sm-test-tmp)
                (load sm-test-menu nil nil t)
                ,body
                (princ "MENU-LAZY-CHILD-PASS\n"))
             (current-buffer)))
          (with-temp-buffer
            (let ((exit (call-process
                         (or (getenv "EMACS_BIN")
                             (expand-file-name invocation-name invocation-directory))
                         nil t nil "-Q" "--batch" "-L" supertag-menu-test--root "-l" script)))
              (unless (and (equal exit 0) (string-match-p "MENU-LAZY-CHILD-PASS" (buffer-string)))
                (ert-fail (format "Menu child exit=%S\n%s" exit (buffer-string)))))))
      (delete-directory tmp t))))

(ert-deftest supertag-menu-lazy-menu-only-and-reload ()
  (supertag-menu-test--child
   '(progn
      (let (wrappers)
        (with-temp-buffer
          (insert-file-contents sm-test-menu)
          (condition-case nil
              (while t
                (let ((form (read (current-buffer))))
                  (when (eq (car-safe form) 'supertag-menu--defwrapper) (push form wrappers))))
            (end-of-file nil)))
        (should (= 34 (length wrappers)))
        (dotimes (_ 2)
          (dolist (row wrappers)
            (should (commandp (nth 1 row)))
            (should-not (featurep (nth 2 row)))
            (should-not (fboundp (nth 3 row))))
          (load sm-test-menu nil nil t)))
      (should-not (featurep 'supertag-core-store))
      (should-not (featurep 'supertag)))))

(ert-deftest supertag-menu-lazy-prefix-once-and-menu-reload ()
  (supertag-menu-test--child
   '(progn
      (sm-test-write 'sm-test-owner
                     '(cl-incf sm-test-loads)
                     '(defun sm-test-target (prefix) (interactive "P")
                        (setq sm-test-prefix prefix) :result)
                     '(provide 'sm-test-owner))
      (supertag-menu--defwrapper sm-test-wrapper sm-test-owner sm-test-target "Test")
      (should-not (fboundp 'sm-test-target))
      (let ((current-prefix-arg '(16)))
        (should (eq :result (call-interactively #'sm-test-wrapper))))
      (should (equal '(16) sm-test-prefix))
      (should (= 1 sm-test-loads))
      (let ((target (symbol-function 'sm-test-target)))
        (load sm-test-menu nil nil t)
        (supertag-menu--defwrapper sm-test-wrapper sm-test-owner sm-test-target "Test")
        (should (eq target (symbol-function 'sm-test-target))))
      (let ((current-prefix-arg '-)) (call-interactively #'sm-test-wrapper))
      (should (eq '- sm-test-prefix))
      (should (= 1 sm-test-loads)))))

(ert-deftest supertag-menu-lazy-existing-bindings-are-authoritative ()
  (supertag-menu-test--child
   '(progn
      (sm-test-write 'sm-test-owner '(error "Owner must not be loaded"))
      (defun sm-test-target () (interactive) :prebound)
      (supertag-menu--defwrapper sm-test-wrapper sm-test-owner sm-test-target "Test")
      (should (eq :prebound (call-interactively #'sm-test-wrapper)))
      (should-not (featurep 'sm-test-owner))
      (fmakunbound 'sm-test-target)
      (sm-test-write 'sm-test-alternate
                     '(cl-incf sm-test-loads)
                     '(defun sm-test-target () (interactive) :alternate))
      (autoload 'sm-test-target "sm-test-alternate" nil t)
      (let ((binding (symbol-function 'sm-test-target)))
        (load sm-test-menu nil nil t)
        (supertag-menu--defwrapper sm-test-wrapper sm-test-owner sm-test-target "Test")
        (should (eq binding (symbol-function 'sm-test-target))))
      (should (eq :alternate (call-interactively #'sm-test-wrapper)))
      (should (= 1 sm-test-loads))
      (should-not (featurep 'sm-test-owner)))))

(ert-deftest supertag-menu-lazy-provided-owner-missing-target-unavailable ()
  (supertag-menu-test--child
   '(progn
      (provide 'sm-test-owner)
      (sm-test-write 'sm-test-owner '(error "Provided owner must not be reloaded"))
      (supertag-menu--defwrapper sm-test-wrapper sm-test-owner sm-test-target "Test")
      (let ((reason (should-error (call-interactively #'sm-test-wrapper) :type 'user-error)))
        (should (string-match-p "unavailable" (error-message-string reason))))
      (should-not (fboundp 'sm-test-target)))))

(ert-deftest supertag-menu-lazy-cold-missing-target-native-error ()
  (supertag-menu-test--child
   '(progn
      (sm-test-write 'sm-test-owner '(cl-incf sm-test-loads) '(provide 'sm-test-owner))
      (supertag-menu--defwrapper sm-test-wrapper sm-test-owner sm-test-target "Test")
      (dotimes (i 2)
        (let ((reason (should-error (call-interactively #'sm-test-wrapper))))
          (should (eq 'error (car reason)))
          (should (string-match-p "failed to define function" (error-message-string reason))))
        (should (= (1+ i) sm-test-loads))
        (should (autoloadp (symbol-function 'sm-test-target)))))))

(ert-deftest supertag-menu-lazy-no-provide-and-optional-missing-file ()
  (supertag-menu-test--child
   '(progn
      (sm-test-write 'sm-test-owner '(defun sm-test-target () (interactive) :defined))
      (supertag-menu--defwrapper sm-test-wrapper sm-test-owner sm-test-target "Test")
      (should (eq :defined (call-interactively #'sm-test-wrapper)))
      (should-not (featurep 'sm-test-owner))
      (supertag-menu--defwrapper sm-test-missing-wrapper sm-test-missing-owner sm-test-missing-target "Test")
      (should-error (call-interactively #'sm-test-missing-wrapper) :type 'file-missing)
      (should (autoloadp (symbol-function 'sm-test-missing-target))))))

(ert-deftest supertag-menu-lazy-loader-error-quit-and-native-retry ()
  (supertag-menu-test--child
   '(dolist (failure '(error quit))
      (let ((owner (intern (format "sm-test-%s-owner" failure)))
            (target (intern (format "sm-test-%s-target" failure)))
            (wrapper (intern (format "sm-test-%s-wrapper" failure)))
            (sm-test-loads 0))
        (sm-test-write owner '(cl-incf sm-test-loads) `(signal ',failure '("original loader failure")))
        (eval `(supertag-menu--defwrapper ,wrapper ,owner ,target "Test") t)
        (should (equal (list failure "original loader failure")
                       (condition-case reason (call-interactively wrapper)
                         ((error quit) reason))))
        (should (= 1 sm-test-loads))
        (should (autoloadp (symbol-function target)))
        (sm-test-write owner '(cl-incf sm-test-loads)
                       `(defun ,target () (interactive) :retried) `(provide ',owner))
        (should (eq :retried (call-interactively wrapper)))
        (should (= 2 sm-test-loads))))))

(provide 'menu-lazy-test)
;;; menu-lazy-test.el ends here
