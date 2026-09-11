;;; view-palette-test.el --- Palette tests for Supertag views -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))
(require 'supertag-view-framework)

(defmacro supertag-view-palette-test--with-light-theme (&rest body)
  "Evaluate BODY with a light frame background."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'frame-parameter)
              (lambda (_frame parameter)
                (when (eq parameter 'background-mode) 'light))))
     ,@body))

(ert-deftest supertag-view-palette-default-accent-keeps-blue-light-value ()
  (supertag-view-palette-test--with-light-theme
    (should (equal "#0066CC" (supertag-view-helper-get-accent-color)))))

(ert-deftest supertag-view-palette-violet-changes-accent ()
  (let ((supertag-view-palette 'violet))
    (supertag-view-palette-test--with-light-theme
      (should (equal "#6D28D9" (supertag-view-helper-get-accent-color))))))

(ert-deftest supertag-view-palette-custom-plist-is-honored ()
  (let ((supertag-view-palette '(:accent ("#123456" . "#ABCDEF"))))
    (supertag-view-palette-test--with-light-theme
      (should (equal "#123456" (supertag-view-helper-get-accent-color))))))

(ert-deftest supertag-view-palette-unknown-symbol-falls-back-to-blue ()
  (let ((supertag-view-palette 'not-a-palette))
    (supertag-view-palette-test--with-light-theme
      (should (equal "#0066CC" (supertag-view-helper-get-accent-color))))))

(provide 'view-palette-test)

;;; view-palette-test.el ends here
