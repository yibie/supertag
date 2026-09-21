;;; view-palette-test.el --- Palette tests for Supertag views -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'supertag-view-framework)

(ert-deftest supertag-view-palette-default-is-paper ()
  (should (eq supertag-view-palette 'paper)))

(defun supertag-view-palette-test--buffer-background (face)
  "Return the locally remapped FACE background in the current buffer."
  (let ((specs (cdr (assq face face-remapping-alist)))
        result)
    (dolist (spec specs)
      (when (and (listp spec) (plist-member spec :background))
        (setq result (plist-get spec :background))))
    result))

(defun supertag-view-palette-test--expected-background (palette face)
  "Return PALETTE's FACE background for the current background mode."
  (let* ((entry (assq face (cdr (assq palette supertag-view-palettes))))
         (spec (if (eq (frame-parameter nil 'background-mode) 'dark)
                   (cddr entry)
                 (cadr entry))))
    (plist-get spec :background)))

(ert-deftest supertag-view-palette-applies-locally-per-buffer ()
  "Two buffers can report different chip1 backgrounds at the same time."
  (let ((first (generate-new-buffer " *palette-paper*"))
        (second (generate-new-buffer " *palette-neon*")))
    (unwind-protect
        (progn
          (with-current-buffer first
            (supertag-view-apply-palette-locally 'paper))
          (with-current-buffer second
            (supertag-view-apply-palette-locally 'neon))
          (let ((paper (with-current-buffer first
                         (supertag-view-palette-test--buffer-background
                          'supertag-view-chip1)))
                (neon (with-current-buffer second
                        (supertag-view-palette-test--buffer-background
                         'supertag-view-chip1))))
            (should (equal paper (supertag-view-palette-test--expected-background
                                  'paper 'supertag-view-chip1)))
            (should (equal neon (supertag-view-palette-test--expected-background
                                 'neon 'supertag-view-chip1)))
            (should-not (equal paper neon))
            (should (eq 'paper (with-current-buffer first supertag-view--local-palette)))
            (should (eq 'neon (with-current-buffer second supertag-view--local-palette))))
          (should-error (with-current-buffer first
                          (supertag-view-apply-palette-locally 'missing))
                        :type 'user-error))
      (kill-buffer first)
      (kill-buffer second))))

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
