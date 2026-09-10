;;; supertag-ui-tool.el --- Inspect generated Ontology LLM tools -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Read-only inspection UI for the transient provider-neutral tool catalog.
;; It neither registers tools with a provider nor opens a network connection.

;;; Code:

(require 'supertag-ontology-tool)

(defvar-local supertag-ui-tool--actor '(:kind :llm)
  "Actor used by the current tool catalog buffer.")

(defvar supertag-ui-tool-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'supertag-ui-tool-refresh)
    (define-key map (kbd "j") #'supertag-ui-tool-copy-catalog-json)
    map)
  "Keymap for `supertag-ui-tool-mode'.")

(define-derived-mode supertag-ui-tool-mode special-mode "Supertag-Tools"
  "Major mode for generated Ontology LLM tool catalogs."
  (setq-local truncate-lines t))

(defun supertag-ui-tool--insert-tool (tool)
  "Insert one TOOL descriptor."
  (insert (propertize (plist-get tool :name) 'face 'font-lock-function-name-face))
  (insert (format "\n  kind: %s\n  mode: %s\n  logical: %s\n"
                  (plist-get tool :kind)
                  (plist-get tool :mode)
                  (plist-get tool :logical-id)))
  (insert (format "  %s\n\n" (plist-get tool :description))))

(defun supertag-ui-tool--render ()
  "Render the current actor's tool catalog."
  (let* ((inhibit-read-only t)
         (catalog (supertag-ontology-tool-catalog supertag-ui-tool--actor))
         (tools (plist-get catalog :tools))
         (omitted (plist-get catalog :omitted)))
    (erase-buffer)
    (insert (propertize "Ontology LLM Tool Catalog\n" 'face 'bold))
    (insert (format "catalog: %s\nactor: %S\n\n"
                    (plist-get catalog :catalog-hash)
                    (plist-get catalog :actor)))
    (if tools
        (dolist (tool tools) (supertag-ui-tool--insert-tool tool))
      (insert "No Function or Action is currently exposed to the LLM actor.\n"))
    (when omitted
      (insert (propertize "\nOmitted Action tools\n" 'face 'bold))
      (dolist (item omitted)
        (insert (format "  %s: %s\n"
                        (or (plist-get item :logical-id)
                            (plist-get item :runtime-id))
                        (or (plist-get item :decision)
                            (plist-get item :reason))))))
    (goto-char (point-min))))

;;;###autoload
(defun supertag-ui-tool-list (&optional actor)
  "Open a read-only generated tool catalog for ACTOR."
  (interactive)
  (let ((buffer (get-buffer-create "*Supertag LLM Tools*")))
    (with-current-buffer buffer
      (supertag-ui-tool-mode)
      (setq-local supertag-ui-tool--actor
                  (or actor '(:kind :llm)))
      (supertag-ui-tool--render))
    (pop-to-buffer buffer)))

(defun supertag-ui-tool-refresh ()
  "Refresh the current generated catalog."
  (interactive)
  (supertag-ui-tool--render)
  (message "Supertag LLM tool catalog refreshed"))

;;;###autoload
(defun supertag-ui-tool-copy-catalog-json (&optional pretty)
  "Copy the current actor's generated catalog JSON.
With prefix argument PRETTY, indent the JSON."
  (interactive "P")
  (let ((json (supertag-ontology-tool-catalog-json
               supertag-ui-tool--actor pretty)))
    (kill-new json)
    (message "Copied %d bytes of generated tool JSON" (length json))
    json))

(provide 'supertag-ui-tool)
;;; supertag-ui-tool.el ends here
