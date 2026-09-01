;;; supertag-ui-embark.el --- Embark integration for supertag-act -*- lexical-binding: t; -*-

;;; Commentary:
;; Optional Embark adapter.  Supertag's own `supertag-act' works without
;; Embark; this module additionally exposes the recognized object at
;; point as an Embark target of type `supertag-object', so Embark users
;; can reach Supertag actions through their usual `embark-act' gesture.
;;
;; Loading this file is safe without Embark installed: registration only
;; happens after Embark itself is loaded.

;;; Code:

(require 'supertag-ui-act)

(defvar embark-target-finders)
(defvar embark-keymap-alist)

(defvar supertag-embark--target-cache nil
  "Last complete Supertag target found for an Embark action.
The record also captures source buffer, position, bounds, and modification
tick so an action never has to guess by re-running detection at a new point.")

(defun supertag-embark--cache-target (target begin end)
  "Cache complete TARGET from BEGIN to END in the current buffer."
  (setq supertag-embark--target-cache
        (list :target target
              :buffer (current-buffer)
              :point (point)
              :begin begin
              :end end
              :tick (buffer-chars-modified-tick))))

(defun supertag-embark--cached-target ()
  "Return the validated complete target for the pending Embark action."
  (let* ((record supertag-embark--target-cache)
         (buffer (plist-get record :buffer))
         (position (plist-get record :point))
         (begin (plist-get record :begin))
         (end (plist-get record :end)))
    (unless (and record (buffer-live-p buffer))
      (user-error "The Supertag Embark target is no longer available"))
    (unless (eq (current-buffer) buffer)
      (user-error "Return to the buffer where the Supertag target was found"))
    (unless (= (plist-get record :tick) (buffer-chars-modified-tick))
      (user-error "The Supertag target changed; run embark-act again"))
    (unless (or (= (point) position)
                (and (< begin end) (<= begin (point)) (< (point) end)))
      (user-error "Point moved away from the Supertag Embark target"))
    (plist-get record :target)))

(defun supertag-embark-target-finder ()
  "Recognize the Supertag object at point as an Embark target."
  (if-let* ((target (supertag-act--target-at-point)))
      (let ((begin (or (plist-get target :begin) (point)))
            (end (or (plist-get target :end) (point))))
        (supertag-embark--cache-target target begin end)
        `(supertag-object ,(supertag-act--target-label target)
                          ,begin . ,end))))

(defun supertag-embark-act-dwim (&optional _embark-label)
  "Run the default action for Embark's cached complete Supertag target."
  (interactive)
  (supertag-act--run-default (supertag-embark--cached-target)))

(defun supertag-embark-act (&optional _embark-label)
  "Open actions for Embark's cached complete Supertag target."
  (interactive)
  (supertag-act--act-on-target (supertag-embark--cached-target)))

(defvar supertag-embark-object-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'supertag-embark-act-dwim)
    (define-key map (kbd "a") #'supertag-embark-act)
    map)
  "Embark actions for a `supertag-object' target.
`supertag-embark-act' opens the full context action menu using the complete
target captured by the finder, so this map stays minimal without re-detecting
whatever happens to be at point later.")

;;;###autoload
(defun supertag-embark-setup ()
  "Register Supertag's target finder and keymap with Embark."
  (add-to-list 'embark-target-finders #'supertag-embark-target-finder)
  (add-to-list 'embark-keymap-alist
               '(supertag-object . supertag-embark-object-map)))

(with-eval-after-load 'embark
  (supertag-embark-setup))

(provide 'supertag-ui-embark)
;;; supertag-ui-embark.el ends here
