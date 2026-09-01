;;; supertag-view-ontology.el --- Inspection commands for the ontology control plane. -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Inspection commands for the ontology control plane.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-ontology-registry)
(require 'supertag-ontology-validator)
(require 'supertag-ontology-runtime)
(require 'supertag-ontology-plan)
(require 'supertag-ontology-deploy)
(require 'supertag-ontology-migration-registry)
(require 'supertag-ontology-migration-runtime)

(defconst supertag-view-ontology-buffer-name "*Supertag Ontology*")

(defun supertag-view-ontology--read-module ()
  (let ((modules (supertag-ontology-registry-modules)))
    (unless modules (user-error "No ontology module is registered"))
    (intern (completing-read "Ontology module: "
                             (mapcar #'symbol-name modules) nil t))))

(defun supertag-view-ontology--insert-issue (issue)
  (insert (format "  %s %-24s %s\n"
                  (upcase (substring (symbol-name (plist-get issue :severity)) 1))
                  (plist-get issue :code)
                  (plist-get issue :message))))

(defun supertag-view-ontology--insert-operation (operation)
  (insert (format "  %-11s %-14s %s%s\n"
                  (upcase (substring (symbol-name (plist-get operation :class)) 1))
                  (substring (symbol-name (plist-get operation :operation)) 1)
                  (plist-get operation :logical-id)
                  (if-let ((id (plist-get operation :runtime-id)))
                      (format " -> %s" id) ""))))

(defun supertag-ontology-preview (&optional module)
  "Preview live-Store deployment plan for MODULE."
  (interactive)
  (let* ((module (or module (supertag-view-ontology--read-module)))
         (model (or (supertag-ontology-registry-get module)
                    (user-error "Unknown ontology module %s" module)))
         (plan (supertag-ontology-plan-build model)))
    (with-current-buffer (get-buffer-create supertag-view-ontology-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Ontology %s\n\n" module))
        (insert (format "Desired version: %s\nModel hash: %s\n\n"
                        (plist-get model :version)
                        (plist-get plan :model-hash)))
        (insert "Issues\n")
        (if-let ((issues (plist-get plan :issues)))
            (dolist (issue issues) (supertag-view-ontology--insert-issue issue))
          (insert "  None\n"))
        (insert "\nOperations\n")
        (if-let ((operations (plist-get plan :operations)))
            (dolist (operation operations)
              (supertag-view-ontology--insert-operation operation))
          (insert "  No changes\n"))
        (goto-char (point-min))
        (special-mode))
      (display-buffer (current-buffer)))
    plan))

(defun supertag-ontology-validate (&optional module)
  "Validate registered ontology MODULE and show all issues."
  (interactive)
  (let* ((module (or module (supertag-view-ontology--read-module)))
         (model (or (supertag-ontology-registry-get module)
                    (user-error "Unknown ontology module %s" module)))
         (issues (supertag-ontology-validator-validate model)))
    (if (called-interactively-p 'interactive)
        (if issues
            (message "%s" (mapconcat (lambda (x) (plist-get x :message))
                                      issues "; "))
          (message "Ontology %s is valid" module)))
    issues))

(defun supertag-ontology-apply (&optional module allow-behavioral)
  "Build and atomically apply a valid plan for MODULE."
  (interactive)
  (let* ((module (or module (supertag-view-ontology--read-module)))
         (model (or (supertag-ontology-registry-get module)
                    (user-error "Unknown ontology module %s" module)))
         (plan (supertag-ontology-plan-build model)))
    (when (supertag-ontology-plan-destructive-p plan)
      (let* ((deployed (supertag-ontology-runtime-module-get module))
             (migration
              (and deployed
                   (supertag-ontology-migration-registry-find
                    module (plist-get deployed :version)
                    (plist-get model :version)))))
        (if migration
            (user-error
             "Ontology change is destructive; apply migration %s with M-x supertag-ontology-migration-apply"
             (plist-get migration :name))
          (user-error
           "Ontology change is destructive; declare a matching migration before applying"))))
    (when (and (supertag-ontology-plan-behavioral-p plan)
               (called-interactively-p 'interactive))
      (setq allow-behavioral
            (yes-or-no-p
             "This plan changes executable Function, Action, or Policy contracts. Deploy it? ")))
    (supertag-ontology-deploy-apply-plan plan allow-behavioral)
    (message "Ontology %s version %s deployed"
             module (plist-get model :version))
    plan))

(defun supertag-ontology-status (&optional module)
  "Show deployed and desired status for MODULE."
  (interactive)
  (let* ((module (or module (supertag-view-ontology--read-module)))
         (desired (supertag-ontology-registry-get module))
         (deployed (supertag-ontology-runtime-module-get module)))
    (with-current-buffer (get-buffer-create supertag-view-ontology-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Ontology status: %s\n\n" module))
        (insert (format "Desired version:  %s\n"
                        (or (plist-get desired :version) "not loaded")))
        (insert (format "Deployed version: %s\n"
                        (or (plist-get deployed :version) "not deployed")))
        (insert (format "Desired hash:     %s\n"
                        (and desired (supertag-ontology-model-hash desired))))
        (insert (format "Deployed hash:    %s\n"
                        (plist-get deployed :model-hash)))
        (insert (format "Bindings:         %d\n"
                        (length (supertag-ontology-runtime-bindings module))))
        (insert (format "Migrations:       %d\n"
                        (length
                         (supertag-ontology-migration-runtime-list module))))
        (goto-char (point-min))
        (special-mode))
      (display-buffer (current-buffer)))
    (list :desired desired :deployed deployed)))

(defun supertag-ontology-goto-definition (&optional module)
  "Visit source declaration for MODULE."
  (interactive)
  (let* ((module (or module (supertag-view-ontology--read-module)))
         (model (supertag-ontology-registry-get module))
         (source (plist-get model :source))
         (file (plist-get source :file))
         (line (or (plist-get source :line) 1)))
    (unless (and file (file-readable-p file))
      (user-error "Source file for %s is unavailable" module))
    (find-file file)
    (goto-char (point-min))
    (forward-line (1- line))))

(provide 'supertag-view-ontology)
;;; supertag-view-ontology.el ends here
