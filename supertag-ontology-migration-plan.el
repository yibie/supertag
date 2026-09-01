;;; supertag-ontology-migration-plan.el --- Migration plan orchestration -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Composes validation, destructive-change coverage, field conversion, Link
;; conflict resolution, and stale-data hashes into one read-only plan.  The
;; specialized planners live in separate high-cohesion modules.

;;; Code:

(require 'cl-lib)
(require 'supertag-ontology-registry)
(require 'supertag-ontology-plan)
(require 'supertag-ontology-runtime)
(require 'supertag-ontology-migration-model)
(require 'supertag-ontology-migration-validator)
(require 'supertag-ontology-migration-runtime)
(require 'supertag-ontology-migration-coverage)
(require 'supertag-ontology-migration-field)
(require 'supertag-ontology-migration-link)

(defun supertag-ontology-migration-plan--issue
    (severity code message &optional step operation)
  "Build one migration planning issue."
  (list :severity severity :code code :message message
        :step step :operation operation))

(defun supertag-ontology-migration-plan--issues-have-errors-p (issues)
  "Return non-nil when ISSUES contains an error."
  (cl-some
   (lambda (issue) (eq (plist-get issue :severity) :error))
   issues))

(defun supertag-ontology-migration-plan--build-step
    (migration model step)
  "Build one data plan for STEP."
  (pcase (plist-get step :kind)
    (:transform-field
     (supertag-ontology-migration-field-plan-transform
      migration model step))
    (:detach-field
     (supertag-ontology-migration-field-plan-detach model step))
    (:tighten-link
     (supertag-ontology-migration-link-plan-tighten
      migration model step))))

(defun supertag-ontology-migration-plan--canonical-data (migration model)
  "Return live data relevant to MIGRATION against MODEL."
  (let (fields links)
    (dolist (step (plist-get migration :steps))
      (pcase (plist-get step :kind)
        (:transform-field
         (when-let ((record
                     (supertag-ontology-migration-field-canonical-data
                      model step)))
           (push record fields)))
        (:tighten-link
         (when-let ((record
                     (supertag-ontology-migration-link-canonical-data
                      model step)))
           (push record links)))))
    (list :fields
          (sort fields
                (lambda (left right)
                  (string< (car left) (car right))))
          :links
          (sort links
                (lambda (left right)
                  (string< (car left) (car right)))))))

(defun supertag-ontology-migration-plan-data-hash (migration model)
  "Return hash of live data relevant to MIGRATION and MODEL."
  (secure-hash
   'sha256
   (prin1-to-string
    (supertag-ontology-migration-plan--canonical-data migration model))))

(defun supertag-ontology-migration-plan-build (migration &optional model)
  "Build a complete read-only plan for normalized MIGRATION.

MODEL defaults to the registered desired ontology model for the migration's
module."
  (let* ((module (plist-get migration :module))
         (model
          (or model
              (and module (supertag-ontology-registry-get module))))
         (validation
          (supertag-ontology-migration-validator-validate migration))
         (module-record
          (and module (supertag-ontology-runtime-module-get module)))
         (applied
          (supertag-ontology-migration-runtime-get
           (plist-get migration :logical-id)))
         ontology-plan
         coverage
         used
         step-plans
         issues)
    (setq issues (copy-sequence validation))
    (unless model
      (push
       (supertag-ontology-migration-plan--issue
        :error :missing-ontology-model
        (format "Ontology module %S is not registered" module))
       issues))
    (unless module-record
      (push
       (supertag-ontology-migration-plan--issue
        :error :module-not-deployed
        (format "Ontology module %S has not been deployed" module))
       issues))
    (when (and module-record
               (not (equal (plist-get module-record :version)
                           (plist-get migration :from-version))))
      (push
       (supertag-ontology-migration-plan--issue
        :error :deployed-version-mismatch
        (format "Module %s is at version %s, migration starts at %s"
                module
                (plist-get module-record :version)
                (plist-get migration :from-version)))
       issues))
    (when (and model
               (not (equal (plist-get model :version)
                           (plist-get migration :to-version))))
      (push
       (supertag-ontology-migration-plan--issue
        :error :target-version-mismatch
        (format "Desired ontology is version %s, migration targets %s"
                (plist-get model :version)
                (plist-get migration :to-version)))
       issues))
    (when applied
      (push
       (supertag-ontology-migration-plan--issue
        :error :already-applied
        (format "Migration %s was already applied at %s"
                (plist-get migration :logical-id)
                (plist-get applied :applied-at)))
       issues))
    (when model
      (setq ontology-plan (supertag-ontology-plan-build model))
      (dolist (issue (plist-get ontology-plan :issues))
        (push issue issues))
      (setq coverage
            (supertag-ontology-migration-coverage-analyze
             migration model ontology-plan))
      (setq issues
            (nconc (copy-sequence (plist-get coverage :issues)) issues))
      (setq used (plist-get coverage :used))
      ;; User callbacks are only needed after the declaration, version,
      ;; binding, and exact-coverage checks all pass.  Do not execute a
      ;; transformer or resolver for a plan that is already known to be
      ;; inapplicable (for example, an already-applied migration).
      (unless (supertag-ontology-migration-plan--issues-have-errors-p issues)
        (dolist (step (plist-get migration :steps))
          (when (gethash (plist-get step :id) used)
            (let ((step-plan
                   (supertag-ontology-migration-plan--build-step
                    migration model step)))
              (push step-plan step-plans)
              (setq issues
                    (nconc (copy-sequence (plist-get step-plan :issues))
                           issues)))))))
    (list :migration migration
          :migration-hash
          (supertag-ontology-migration-model-hash migration)
          :module module
          :from-version (plist-get migration :from-version)
          :to-version (plist-get migration :to-version)
          :model model
          :model-hash
          (and model (supertag-ontology-model-hash model))
          :ontology-plan ontology-plan
          :runtime-hash
          (and ontology-plan (plist-get ontology-plan :runtime-hash))
          :data-hash
          (and model
               (supertag-ontology-migration-plan-data-hash migration model))
          :step-plans (nreverse step-plans)
          :issues (nreverse issues)
          :applied-record applied)))

(defun supertag-ontology-migration-plan-errors-p (plan)
  "Return non-nil when PLAN contains an error."
  (cl-some
   (lambda (issue)
     (eq (plist-get issue :severity) :error))
   (plist-get plan :issues)))

(defun supertag-ontology-migration-plan-ready-p (plan)
  "Return non-nil when PLAN may be applied."
  (and (not (supertag-ontology-migration-plan-errors-p plan))
       (plist-get plan :ontology-plan)
       (supertag-ontology-plan-destructive-p
        (plist-get plan :ontology-plan))))

(defun supertag-ontology-migration-plan-actions (plan)
  "Return all data actions in PLAN in deterministic step order."
  (apply #'append
         (mapcar
          (lambda (step-plan)
            (copy-sequence (plist-get step-plan :actions)))
          (plist-get plan :step-plans))))

(provide 'supertag-ontology-migration-plan)
;;; supertag-ontology-migration-plan.el ends here
