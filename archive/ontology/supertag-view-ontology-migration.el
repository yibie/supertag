;;; supertag-view-ontology-migration.el --- Migration preview and commands -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Human-facing commands for the migration control plane.  Preview remains
;; read-only; apply delegates to the atomic deployment module.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-ontology-migration-registry)
(require 'supertag-ontology-migration-validator)
(require 'supertag-ontology-migration-plan)
(require 'supertag-ontology-migration-deploy)
(require 'supertag-ontology-migration-runtime)

(defconst supertag-view-ontology-migration-buffer-name
  "*Supertag Ontology Migration*")

(defun supertag-view-ontology-migration--read-name ()
  "Read one registered migration logical ID."
  (let ((ids (supertag-ontology-migration-registry-ids)))
    (unless ids
      (user-error "No ontology migration is registered"))
    (completing-read "Migration: " ids nil t)))

(defun supertag-view-ontology-migration--migration (name)
  "Return migration NAME or signal a user-facing error."
  (or (supertag-ontology-migration-registry-get name)
      (user-error "Unknown ontology migration %s" name)))

(defun supertag-view-ontology-migration--insert-issue (issue)
  "Insert one ISSUE into the current buffer."
  (insert
   (format "  %-7s %-30s %s\n"
           (upcase (substring (symbol-name (plist-get issue :severity)) 1))
           (plist-get issue :code)
           (plist-get issue :message))))

(defun supertag-view-ontology-migration--insert-sample (sample)
  "Insert one migration SAMPLE."
  (insert (format "      %S\n" sample)))

(defun supertag-view-ontology-migration--insert-step-plan (step-plan)
  "Insert summary of STEP-PLAN."
  (let* ((step (plist-get step-plan :step))
         (kind (plist-get step-plan :kind)))
    (insert
     (format "  %s\n"
             (pcase kind
               (:transform-field
                (format "transform-field %s: scanned=%d changed=%d dropped=%d cleared=%d"
                        (plist-get step :field)
                        (or (plist-get step-plan :scanned) 0)
                        (or (plist-get step-plan :changed) 0)
                        (or (plist-get step-plan :dropped) 0)
                        (or (plist-get step-plan :cleared) 0)))
               (:detach-field
                (format "detach-field %s/%s"
                        (plist-get step :type) (plist-get step :field)))
               (:tighten-link
                (format "tighten-link %s: scanned=%d delete=%d"
                        (plist-get step :link)
                        (or (plist-get step-plan :scanned) 0)
                        (or (plist-get step-plan :deleted) 0)))
               (_ (format "%S" kind)))))
    (dolist (sample (plist-get step-plan :samples))
      (supertag-view-ontology-migration--insert-sample sample))))

(defun supertag-ontology-migration-preview (&optional name)
  "Build and display migration plan NAME without writing the Store."
  (interactive)
  (let* ((name (or name (supertag-view-ontology-migration--read-name)))
         (migration (supertag-view-ontology-migration--migration name))
         (plan (supertag-ontology-migration-plan-build migration)))
    (with-current-buffer
        (get-buffer-create supertag-view-ontology-migration-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Ontology migration: %s\n\n" name))
        (insert (format "Module:        %s\n" (plist-get migration :module)))
        (insert (format "Version:       %s -> %s\n"
                        (plist-get migration :from-version)
                        (plist-get migration :to-version)))
        (insert (format "Migration hash: %s\n"
                        (plist-get plan :migration-hash)))
        (insert (format "Ready:         %s\n\n"
                        (if (supertag-ontology-migration-plan-ready-p plan)
                            "yes" "no")))
        (insert "Issues\n")
        (if-let ((issues (plist-get plan :issues)))
            (dolist (issue issues)
              (supertag-view-ontology-migration--insert-issue issue))
          (insert "  None\n"))
        (insert "\nData steps\n")
        (if-let ((steps (plist-get plan :step-plans)))
            (dolist (step steps)
              (supertag-view-ontology-migration--insert-step-plan step))
          (insert "  None\n"))
        (insert "\nOntology operations\n")
        (if-let* ((ontology-plan (plist-get plan :ontology-plan))
                  (operations (plist-get ontology-plan :operations)))
            (dolist (operation operations)
              (insert
               (format "  %-11s %-15s %s\n"
                       (upcase
                        (substring
                         (symbol-name (plist-get operation :class)) 1))
                       (substring
                        (symbol-name (plist-get operation :operation)) 1)
                       (plist-get operation :logical-id))))
          (insert "  None\n"))
        (goto-char (point-min))
        (special-mode))
      (display-buffer (current-buffer)))
    plan))

(defun supertag-ontology-migration-validate (&optional name)
  "Validate migration NAME and return issue plists."
  (interactive)
  (let* ((name (or name (supertag-view-ontology-migration--read-name)))
         (migration (supertag-view-ontology-migration--migration name))
         (issues
          (supertag-ontology-migration-validator-validate migration)))
    (when (called-interactively-p 'interactive)
      (if issues
          (message "%s"
                   (mapconcat (lambda (issue) (plist-get issue :message))
                              issues "; "))
        (message "Migration %s is valid" name)))
    issues))

(defun supertag-ontology-migration-apply (&optional name)
  "Preview again and atomically apply migration NAME."
  (interactive)
  (let* ((name (or name (supertag-view-ontology-migration--read-name)))
         (migration (supertag-view-ontology-migration--migration name))
         (plan (supertag-ontology-migration-plan-build migration)))
    (when (supertag-ontology-migration-plan-errors-p plan)
      (let ((first
             (cl-find-if
              (lambda (issue) (eq (plist-get issue :severity) :error))
              (plist-get plan :issues))))
        (user-error "Migration is not ready: %s"
                    (or (plist-get first :message) "unknown error"))))
    (when (and (called-interactively-p 'interactive)
               (not
                (yes-or-no-p
                 (format "Apply migration %s (%s -> %s) with %d data action(s)? "
                         name
                         (plist-get migration :from-version)
                         (plist-get migration :to-version)
                         (length
                          (supertag-ontology-migration-plan-actions plan))))))
      (user-error "Migration cancelled"))
    (supertag-ontology-migration-deploy-apply-plan plan)
    (message "Migration %s applied; ontology %s is now version %s"
             name (plist-get migration :module)
             (plist-get migration :to-version))
    plan))

(defun supertag-ontology-migration-status (&optional module)
  "Display applied migrations, optionally restricted to MODULE."
  (interactive)
  (let ((records (supertag-ontology-migration-runtime-list module)))
    (with-current-buffer
        (get-buffer-create supertag-view-ontology-migration-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (if module
                    (format "Applied ontology migrations: %s\n\n" module)
                  "Applied ontology migrations\n\n"))
        (if records
            (dolist (record records)
              (insert
               (format "  %s  %s  %s -> %s  %s\n"
                       (plist-get record :logical-id)
                       (plist-get record :module)
                       (plist-get record :from-version)
                       (plist-get record :to-version)
                       (format-time-string
                        "%Y-%m-%d %H:%M:%S"
                        (seconds-to-time (plist-get record :applied-at))))))
          (insert "  None\n"))
        (goto-char (point-min))
        (special-mode))
      (display-buffer (current-buffer)))
    records))

(defun supertag-ontology-migration-goto-definition (&optional name)
  "Visit source declaration for migration NAME."
  (interactive)
  (let* ((name (or name (supertag-view-ontology-migration--read-name)))
         (migration (supertag-view-ontology-migration--migration name))
         (source (plist-get migration :source))
         (file (plist-get source :file))
         (line (or (plist-get source :line) 1)))
    (unless (and file (file-readable-p file))
      (user-error "Migration source file is unavailable"))
    (find-file file)
    (goto-char (point-min))
    (forward-line (1- line))))

(provide 'supertag-view-ontology-migration)
;;; supertag-view-ontology-migration.el ends here
