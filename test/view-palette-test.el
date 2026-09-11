;;; view-palette-test.el --- Palette tests for Supertag views -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'supertag-view-framework)

(ert-deftest supertag-view-palette-default-is-paper ()
  (should (eq supertag-view-palette 'paper)))

(ert-deftest supertag-view-palette-neon-changes-primary-chip-background ()
  (let ((original supertag-view-palette))
    (unwind-protect
        (progn
          (supertag-view-apply-palette 'paper)
          (let ((paper (face-background 'supertag-view-chip1 nil t)))
            (supertag-view-apply-palette 'neon)
            (should (eq supertag-view-palette 'neon))
            (should-not (equal paper (face-background 'supertag-view-chip1 nil t)))))
      (supertag-view-apply-palette original))))

(ert-deftest supertag-view-palette-rejects-unknown-name ()
  (should-error (supertag-view-apply-palette 'not-a-palette) :type 'user-error))

(provide 'view-palette-test)
;;; view-palette-test.el ends here
