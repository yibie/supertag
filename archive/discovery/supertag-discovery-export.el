;;; supertag-discovery-export.el --- Archived Discovery export commands -*- lexical-binding: t; -*-

;;; Commentary:
;; Archived from supertag-ui-search.el on 2026-09-06 (MODEL_CN:269,
;; COMMANDS-TRIAGE:318-319).
;; Not loaded by default; explicitly load this file to use its functions
;; in a Discovery buffer.
;; Depends on supertag-discovery's buffer-name/selected-nodes helpers and
;; supertag-ops-node's node-get/node-format-link functions.

;;; Code:
(require 'supertag-discovery)
(require 'supertag-ops-node)

(defun supertag-search--insert-generated-node-link-line (node-id title)
  "Insert a non-asserting generated bullet link to NODE-ID titled TITLE."
  (insert "- " (supertag-node-format-link node-id title) "\n"))

(defun supertag-search-get-selected-nodes ()
  "Return selected IDs for the explicitly loaded archived export commands."
  (with-current-buffer supertag-discovery--buffer-name
    (supertag-discovery--selected-nodes)))

(defun supertag-search-export-results-to-new-file ()
  "Export selected search results as a generated Org view in a new file.
The exported links are navigation output, not Document Link assertions."
  (let ((selected-nodes (supertag-search-get-selected-nodes)))
    (if (not selected-nodes)
        (message "No items selected")
      (let* ((default-name "export.org")
             (file (read-file-name
                   "Export to new file: "
                   nil nil nil
                   default-name)))
        (unless (string-match-p "\\.org$" file)
          (error "Export target must be an org file: %s" file))
        (when (and (file-exists-p file)
                  (not (y-or-n-p
                        (format "File %s exists. Overwrite? " file))))
          (error "Export cancelled by user"))

        (with-current-buffer (find-file-noselect file)
          (erase-buffer)
          (org-mode)
          ;; Ensure tab-width is 8 as required by org-current-text-column
          (setq-local tab-width 8)
          (let ((title (file-name-base file)))
            (insert (format "#+TITLE: %s\n" title)
                    "#+OPTIONS: ^:nil\n"
                    "#+STARTUP: showeverything\n\n"
                    "* Search Results\n\n"
                    "#+BEGIN: supertag-search-export\n"))
          (dolist (node-id selected-nodes)
            (when-let* ((node-data (supertag-node-get node-id))
                       (title (plist-get node-data :title))
                       (clean-title (if (stringp title)
                                       (substring-no-properties title)
                                     (prin1-to-string title))))
              (supertag-search--insert-generated-node-link-line
               node-id clean-title)))
          (insert "#+END:\n")
          (save-buffer)
          (find-file file)
          (message "Export of %d links completed successfully to %s"
                  (length selected-nodes) file))))))

(defun supertag-search-export-results-to-file ()
  "Export selected search results to specified file location."
  (message "Export to file functionality not yet implemented in new version"))

(provide 'supertag-discovery-export)
