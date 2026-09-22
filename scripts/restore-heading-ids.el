;;; restore-heading-ids.el --- Restore IDs for org headings -*- lexical-binding: t; -*-

;;; Commentary:
;; This standalone script restores heading IDs without using the database.
;; It creates or restores IDs for headings containing #tags.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-id)

(defun restore-heading-ids--has-tag-p (title)
  "Return non-nil if TITLE contains a #tag-style tag."
  (and (stringp title)
       (string-match-p "#[a-zA-Z][a-zA-Z0-9_-]*" title)))

(cl-defun restore-heading-ids-in-file (file)
  "Create IDs for headings in FILE that contain #tags but have no ID.
Return (CREATED . TOTAL), the number of IDs created and headings scanned.
Return nil if FILE is invalid or processing fails."
  (if (not (and (stringp file) (file-exists-p file)))
      (progn
        (message "File does not exist or is invalid: %s" file)
        nil)
    (let* ((created-count 0)
           (total-count 0)
           (existing-buffer (find-buffer-visiting file))
           (buffer (condition-case err
                      (or existing-buffer (find-file-noselect file t))
                    (error
                     (message "Failed to open file %s: %s" file (error-message-string err))
                     nil))))
      (unless buffer
        (message "Could not open file: %s" file)
        (cl-return-from restore-heading-ids-in-file nil))
      (with-current-buffer buffer
        (org-mode)
        (org-with-wide-buffer
         (goto-char (point-min))
         (while (re-search-forward org-heading-regexp nil t)
           (cl-incf total-count)
           (when (org-at-heading-p)
             (let ((title (org-get-heading t t t t))
                   (id (org-entry-get nil "ID")))
               (when (and (not id) (restore-heading-ids--has-tag-p title))
                 (let ((new-id (org-id-new)))
                   (org-entry-put nil "ID" new-id)
                   (org-id-add-location new-id (buffer-file-name))
                   (cl-incf created-count)
                   (message "Created ID %s: %s" new-id title))))))))
      
      ;; Save changes.
      (when (buffer-modified-p)
        (condition-case err
            (save-buffer)
          (error
           (message "Failed to save file %s: %s" file (error-message-string err)))))
      
      ;; Close buffers opened by this command.
      (unless existing-buffer
        (ignore-errors (kill-buffer buffer)))
      
      (cons created-count total-count))))   

(defun restore-heading-ids-in-directory (dir)
  "Create IDs for #tagged headings without IDs in every Org file under DIR."
  (interactive "DSelect directory: ")
  (if (not (and (stringp dir) (file-directory-p dir)))
      (user-error "Invalid directory: %s" dir)
    (let* ((files (condition-case err
                     (directory-files-recursively dir "\\.org$")
                   (error
                    (user-error "Failed to search directory: %s" (error-message-string err)))))
           (total-files (length files))
           (total-created 0)
           (total-headings 0)
           (processed-files 0)
           (error-files 0))
      
      (message "Processing directory: %s" dir)
      (message "Org files found: %d" total-files)
      
      (dolist (file files)
        (condition-case err
            (progn
              (message "[%d/%d] Processing file: %s..."
                      (1+ processed-files) total-files
                      (file-name-nondirectory file))
              (let ((result (restore-heading-ids-in-file file)))
                (if result
                    (progn
                      (cl-incf processed-files)
                      (cl-incf total-created (car result))
                      (cl-incf total-headings (cdr result))
                      (message "[%d/%d] %s: IDs created=%d, headings=%d"
                              processed-files total-files
                              (file-name-nondirectory file)
                              (car result)
                              (cdr result)))
                  (cl-incf error-files))))
          (error
           (cl-incf error-files)
           (message "Error processing file %s: %s"
                    (file-name-nondirectory file)
                    (error-message-string err))
           (sit-for 1)))) ; Pause for one second after showing the error.
      
      (message "")
      (message "=== Processing complete ===")
      (message "Files processed successfully: %d/%d" processed-files total-files)
      (message "Files with errors: %d" error-files)
      (message "Headings processed: %d" total-headings)
      (message "IDs created: %d" total-created)
      (when (> error-files 0)
        (message "Files failed: %d; review the errors above" error-files)))))

(defun restore-heading-ids-current-file ()
  "Create IDs for #tagged headings without IDs in the current file."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Run this command in an Org buffer"))
  
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "Current buffer is not visiting a file"))
    
    (let ((result (restore-heading-ids-in-file file)))
      (if result
          (message "IDs created: %d; headings processed: %d"
                   (car result)
                   (cdr result))
        (message "Error processing file")))))

(defun restore-heading-ids-at-point ()
  "Create an ID for the heading at point if it has a #tag but no ID."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Run this command in an Org buffer"))
  
  (unless (org-at-heading-p)
    (user-error "Move point to an Org heading"))
  
  (let ((title (org-get-heading t t t t))
        (id (org-entry-get nil "ID")))
    (cond
     (id
      (message "Current heading already has ID: %s" id))
     ((not (restore-heading-ids--has-tag-p title))
      (message "Current heading has no #tag"))
     (t
      (let ((new-id (org-id-new)))
        (org-entry-put nil "ID" new-id)
        (org-id-add-location new-id (buffer-file-name))
        (message "Created new ID: %s" new-id))))))

(provide 'restore-heading-ids)
;;; restore-heading-ids.el ends here
