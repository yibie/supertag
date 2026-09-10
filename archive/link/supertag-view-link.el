;;; supertag-view-link.el --- Typed Link projection for node views. -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'supertag-services-link)
(require 'supertag-view-helper)

(declare-function supertag-goto-node "supertag-ui-commands" (node-id &optional other-window))

(defun supertag-view-link--insert-node (instance)
  (let* ((node-id (plist-get instance :other-node-id))
         (title (plist-get instance :other-title))
         (start (point))
         (map (make-sparse-keymap))
         (action `(lambda () (interactive) (supertag-goto-node ,node-id))))
    (insert (format "    %s\n" title))
    (define-key map [mouse-1] action)
    (define-key map (kbd "RET") action)
    (add-text-properties
     start (1- (point))
     `(supertag-node-id ,node-id
                        supertag-link-relation-id ,(plist-get instance :relation-id)
                        face link keymap ,map mouse-face highlight
                        help-echo ,(format "Jump to %s" title)))))

(defun supertag-view-link-insert-section (node-id)
  "Insert NODE-ID's typed Links into the current buffer."
  (let ((instances (supertag-link-service-instances node-id)))
    (supertag-view-helper-insert-section-title
     (if instances (format "Typed Links (%d)" (length instances)) "Typed Links")
     "")
    (if (null instances)
        (supertag-view-helper-insert-simple-empty-state
         "No typed Links. Use l a to add one.")
      (let ((groups (make-hash-table :test #'equal)) order)
        (dolist (instance instances)
          (let ((key (cons (plist-get instance :definition-id)
                           (plist-get instance :direction))))
            (unless (gethash key groups) (push key order))
            (puthash key (append (gethash key groups) (list instance)) groups)))
        (dolist (key (nreverse order))
          (let* ((items (gethash key groups))
                 (first (car items)))
            (insert (format "  %s (%d)\n" (plist-get first :label) (length items)))
            (dolist (instance items)
              (supertag-view-link--insert-node instance))))
        (insert "\n")))))

(provide 'supertag-view-link)
;;; supertag-view-link.el ends here
