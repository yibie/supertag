;;; ontology-migration-v8-example.el --- Migration DSL example -*- lexical-binding: t; -*-

(require 'supertag-ontology)

;; Assume personal-work version 1 has already been deployed.  The current
;; ontology source now declares version 2 with:
;; - status changed from text to options;
;; - project no longer associated with legacy-note;
;; - tasks target cardinality tightened from many to one.

(defun personal-work-migrate-status-v2 (value _context)
  "Convert legacy status VALUE to the version-two options vocabulary."
  (pcase (downcase (format "%s" value))
    ((or "doing" "in progress") "active")
    ((or "finished" "complete" "done") "done")
    ("waiting" "waiting")
    (_ "idea")))

(defun personal-work-keep-oldest-task-owner (relations _context)
  "Keep the first stable relation from conflicting RELATIONS."
  ;; The planner already supplies RELATIONS sorted by stable relation ID.
  (car relations))

(supertag-defmigration personal-work-v2
  :module personal-work
  :from 1
  :to 2
  :description "Normalize status, detach legacy-note, and assign one project per task"

  (transform-field status
    :using personal-work-migrate-status-v2
    :on-error :abort)

  (detach-field project legacy-note)

  (tighten-link tasks
    :target-resolver personal-work-keep-oldest-task-owner))

;; Loading this file only registers the migration.
;;
;; M-x supertag-ontology-migration-validate
;; M-x supertag-ontology-migration-preview
;; M-x supertag-ontology-migration-apply

(provide 'ontology-migration-v8-example)
;;; ontology-migration-v8-example.el ends here
