;;; supertag-view-mention.el --- Unlinked mention projection -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Disposable Node View projection for unlinked mention candidates.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'subr-x)
(require 'supertag-services-mention)
(require 'supertag-ui-mention)
(require 'supertag-view-helper)

(declare-function supertag-goto-node "supertag-services-ui"
                  (node-id &optional other-window))

(defun supertag-view-mention--jump (button)
  "Jump to BUTTON's source node."
  (supertag-goto-node (button-get button 'supertag-source-id)))

(defun supertag-view-mention--link (button)
  "Link BUTTON's mention candidate."
  (supertag-mention-link (button-get button 'supertag-mention)))

(defun supertag-view-mention--link-all (button)
  "Link all mentions represented by BUTTON's source candidate."
  (supertag-mention-link-all-in-node
   (button-get button 'supertag-mention)))

(defun supertag-view-mention--ignore (button)
  "Ignore BUTTON's target in the source node."
  (supertag-mention-ignore-in-node
   (button-get button 'supertag-mention)))

(defun supertag-view-mention--insert-action (label action candidate help)
  "Insert one mention action button."
  (insert-text-button
   label
   'action action
   'follow-link t
   'help-echo help
   'supertag-mention candidate))

(defun supertag-view-mention--wrapped-lines (text)
  "Return display lines for excerpt TEXT, preserving its text properties.
Mirrors the wrapping used by contextual reference cards so both sections
render excerpts with identical width and prefixing."
  (when (and text (not (string-empty-p text)))
    (with-temp-buffer
      (insert text)
      (setq-local fill-column
                  (max 48 (min 92 (- (or (ignore-errors (window-body-width)) 80)
                                      8))))
      (fill-region (point-min) (point-max))
      (split-string (buffer-string) "\n" t))))

(defun supertag-view-mention--context-text (candidate)
  "Return CANDIDATE's excerpt with the exact match highlighted."
  (concat (propertize (or (plist-get candidate :before) "")
                      'face 'font-lock-comment-face)
          (propertize (or (plist-get candidate :match) "")
                      'face 'match)
          (propertize (or (plist-get candidate :after) "")
                      'face 'font-lock-comment-face)))

(defun supertag-view-mention--insert-context (candidate)
  "Insert context excerpt for CANDIDATE with exact match highlighting.
Every wrapped line carries the same \"    > \" prefix as reference cards."
  (if-let* ((lines (supertag-view-mention--wrapped-lines
                    (supertag-view-mention--context-text candidate))))
      (dolist (line lines)
        (insert (propertize "    > " 'face 'font-lock-comment-face))
        (insert (string-trim line))
        (insert "\n"))
    (insert (propertize "    > No direct source text is available.\n"
                        'face `(:foreground ,(supertag-view-helper-get-muted-color)
                                            :slant italic)))))

(defun supertag-view-mention--insert-card (candidate)
  "Insert one unlinked mention CANDIDATE."
  (let ((source-id (plist-get candidate :source-id))
        (source-title (or (plist-get candidate :source-title)
                          (plist-get candidate :source-id)))
        (location (or (plist-get candidate :source-location) "Store node")))
    (insert "  ")
    (insert-text-button
     source-title
     'action #'supertag-view-mention--jump
     'follow-link t
     'help-echo (format "Jump to %s" source-title)
     'supertag-source-id source-id)
    (insert "\n")
    (insert (propertize (format "    %s\n" location)
                        'face `(:foreground
                                ,(supertag-view-helper-get-muted-color)
                                :height 0.9)))
    (supertag-view-mention--insert-context candidate)
    (insert "    ")
    (supertag-view-mention--insert-action
     "[Link]" #'supertag-view-mention--link candidate
     "Turn this occurrence into a canonical Org ID link")
    (insert " ")
    (supertag-view-mention--insert-action
     "[Link all in node]" #'supertag-view-mention--link-all candidate
     "Link every unlinked occurrence in this source node")
    (insert " ")
    (supertag-view-mention--insert-action
     "[Ignore in node]" #'supertag-view-mention--ignore candidate
     "Suppress mentions of this target in this source node")
    ;; One blank line between cards, matching contextual reference cards.
    (insert "\n\n")))

(defun supertag-view-mention-insert-section (target-id)
  "Insert unlinked mention candidates for TARGET-ID."
  (let ((mentions (supertag-mention-service-find target-id)))
    (supertag-view-helper-insert-section-title
     (if mentions
         (format "Unlinked Mentions (%d)" (length mentions))
       "Unlinked Mentions")
     "")
    (if mentions
        (dolist (candidate mentions)
          (supertag-view-mention--insert-card candidate))
      (supertag-view-helper-insert-simple-empty-state
       "No unlinked mentions."))))

(provide 'supertag-view-mention)
;;; supertag-view-mention.el ends here
