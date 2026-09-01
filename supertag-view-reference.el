;;; supertag-view-reference.el --- Contextual reference projection -*- lexical-binding: t; -*-

;;; Commentary:
;; Renders outgoing references and incoming Backlinks as contextual cards. The
;; data comes entirely from Store projections and relation queries; this view
;; owns no facts and may be rebuilt at any time.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-services-reference)
(require 'supertag-view-helper)

(declare-function supertag-goto-node "supertag-services-ui"
                  (node-id &optional other-window))

(defun supertag-view-reference--kind-summary (item)
  "Return a compact reference-kind summary for ITEM."
  (mapconcat #'supertag-reference-service-kind-label
             (sort (copy-sequence (or (plist-get item :kinds) '()))
                   (lambda (left right)
                     (string< (symbol-name (or left :unknown))
                              (symbol-name (or right :unknown)))))
             ", "))

(defun supertag-view-reference--wrapped-lines (text)
  "Return display lines for contextual TEXT."
  (when (and text (not (string-empty-p text)))
    (with-temp-buffer
      (insert text)
      (setq-local fill-column
                  (max 48 (min 92 (- (or (ignore-errors (window-body-width)) 80)
                                      8))))
      (fill-region (point-min) (point-max))
      (split-string (buffer-string) "\n" t))))

(defun supertag-view-reference--insert-card (item)
  "Insert one contextual reference ITEM."
  (let* ((node-id (or (plist-get item :node-id)
                      (plist-get item :source-id)
                      (plist-get item :target-id)))
         (title (or (plist-get item :title)
                    (plist-get item :source-title)
                    (plist-get item :target-title)))
         (location (or (plist-get item :location)
                       (plist-get item :source-location)
                       (plist-get item :target-location)))
         (kind-summary (supertag-view-reference--kind-summary item))
         (start (point))
         (map (make-sparse-keymap))
         (action `(lambda () (interactive) (supertag-goto-node ,node-id))))
    (insert "  ")
    (let ((title-start (point)))
      (insert title)
      (define-key map [mouse-1] action)
      (define-key map (kbd "RET") action)
      (add-text-properties
       title-start (point)
       `(supertag-node-id ,node-id
                          face link
                          keymap ,map
                          mouse-face highlight
                          help-echo ,(format "Jump to %s" title))))
    (insert "\n")
    (insert (propertize
             (format "    %s%s\n"
                     location
                     (if (string-empty-p kind-summary)
                         ""
                       (format " | %s" kind-summary)))
             'face `(:foreground ,(supertag-view-helper-get-muted-color)
                                 :height 0.9)))
    (if-let* ((lines (supertag-view-reference--wrapped-lines
                      (plist-get item :snippet))))
        (dolist (line lines)
          (insert (propertize (format "    > %s\n" line)
                              'face 'font-lock-comment-face)))
      (insert (propertize "    > No direct source text is available.\n"
                          'face `(:foreground ,(supertag-view-helper-get-muted-color)
                                              :slant italic))))
    (insert "\n")
    (add-text-properties
     start (point)
     `(supertag-reference-node-id ,node-id
                                    supertag-reference-relation-ids
                                    ,(plist-get item :relation-ids)))))

(defun supertag-view-reference-insert-outgoing-section (node-id)
  "Insert contextual outgoing references for NODE-ID."
  (let ((references (supertag-reference-service-outgoing node-id)))
    (supertag-view-helper-insert-section-title
     (if references
         (format "References (%d)" (length references))
       "References")
     "")
    (if references
        (dolist (item references)
          (supertag-view-reference--insert-card item))
      (supertag-view-helper-insert-simple-empty-state
       "No outgoing references."))))

(defun supertag-view-reference-insert-backlinks-section (node-id)
  "Insert contextual backlinks for NODE-ID into the current buffer."
  (let ((backlinks (supertag-reference-service-backlinks node-id)))
    (supertag-view-helper-insert-section-title
     (if backlinks
         (format "Backlinks (%d)" (length backlinks))
       "Backlinks")
     "")
    (if backlinks
        (dolist (item backlinks)
          (supertag-view-reference--insert-card item))
      (supertag-view-helper-insert-simple-empty-state
       "No incoming references."))))

(defun supertag-view-reference-insert-sections (node-id)
  "Insert outgoing references and contextual backlinks for NODE-ID."
  (supertag-view-reference-insert-outgoing-section node-id)
  (insert "\n")
  (supertag-view-reference-insert-backlinks-section node-id)
  (insert "\n"))

(provide 'supertag-view-reference)
;;; supertag-view-reference.el ends here
