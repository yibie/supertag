;;; supertag-ontology-migration-deploy.el --- Atomic ontology migrations -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Applies data actions, destructive schema changes, provenance, and the
;; migration ledger in one existing Supertag Store transaction.

;;; Code:

(require 'cl-lib)
(require 'supertag-core-store)
(require 'supertag-core-transform)
(require 'supertag-schema-authority)
(require 'supertag-ontology-registry)
(require 'supertag-ontology-runtime)
(require 'supertag-ontology-model)
(require 'supertag-ontology-deploy)
(require 'supertag-ontology-migration-model)
(require 'supertag-ontology-migration-registry)
(require 'supertag-ontology-migration-field)
(require 'supertag-ontology-migration-plan)
(require 'supertag-ontology-migration-runtime)
(require 'supertag-ops-relation)

;; Migration is one explicit state transition.  Ordinary automation must not
;; observe and react to the temporary states between data cleanup and schema
;; commit; integrations should use `supertag-ontology-migrated-hook' instead.
(defvar supertag-automation--enabled)
(defvar supertag-automation-sync--enabled)

(defvar supertag-ontology-migrated-hook nil
  "Hook run after an ontology migration commits successfully.")

(defun supertag-ontology-migration-deploy--assert-current (plan)
  "Reject PLAN when schema, relevant data, version, or ledger changed."
  (unless (supertag-ontology-migration-plan-ready-p plan)
    (user-error "Migration plan contains errors or lacks destructive coverage"))
  (let* ((migration (plist-get plan :migration))
         (model (plist-get plan :model))
         (logical-id (plist-get migration :logical-id))
         (current-migration
          (supertag-ontology-migration-registry-get logical-id))
         (current-model
          (supertag-ontology-registry-get (plist-get migration :module)))
         (module-record
          (supertag-ontology-runtime-module-get (plist-get migration :module))))
    ;; A plan built from a registered declaration must still match what the
    ;; registry holds now.  A migration normalized directly (tooling, tests)
    ;; has no registry entry; the declaration embedded in the plan is then
    ;; authoritative and must still match the hash recorded at preview time.
    (unless (equal (plist-get plan :migration-hash)
                   (supertag-ontology-migration-model-hash
                    (or current-migration migration)))
      (user-error "Migration declaration changed after preview; build a new plan"))
    (unless (and current-model
                 (equal (plist-get plan :model-hash)
                        (supertag-ontology-model-hash current-model)))
      (user-error "Desired ontology changed after migration preview; build a new plan"))
    (when (supertag-ontology-migration-runtime-get logical-id)
      (user-error "Migration %s has already been applied" logical-id))
    (unless (equal (plist-get module-record :version)
                   (plist-get migration :from-version))
      (user-error "Ontology module version changed after migration preview"))
    (unless (equal (plist-get plan :runtime-hash)
                   (supertag-ontology-runtime-hash))
      (user-error "Migration schema plan is stale; preview again"))
    (unless (equal (plist-get plan :data-hash)
                   (supertag-ontology-migration-plan-data-hash
                    migration model))
      (user-error "Migration data plan is stale; preview again"))
    (supertag-ontology-migration-deploy--assert-actions-current plan)))

(defun supertag-ontology-migration-deploy--assert-actions-current (plan)
  "Revalidate PLAN's data actions against current node and target schema state."
  (let ((model (plist-get plan :model)))
    (dolist (action (supertag-ontology-migration-plan-actions plan))
      (pcase (plist-get action :kind)
        ((or :set-field-value :remove-field-value)
         (unless (supertag-store-get-entity :nodes (plist-get action :node-id))
           (user-error "Migration node %s no longer exists"
                       (plist-get action :node-id))))
        (:delete-relation
         (unless (supertag-relation-get (plist-get action :relation-id))
           (user-error "Migration relation %s no longer exists"
                       (plist-get action :relation-id)))))
      (when (eq (plist-get action :kind) :set-field-value)
        (let ((field
               (supertag-ontology-model-find
                model :field (plist-get action :field-key))))
          (unless field
            (user-error "Migration target field %s is no longer declared"
                        (plist-get action :field-key)))
          (unless
              (equal
               (plist-get action :new-value)
               (supertag-ontology-migration-field-normalize-target
                (copy-tree (plist-get action :new-value)) field))
            (user-error "Migration value for node %s no longer matches target field %s"
                        (plist-get action :node-id)
                        (plist-get action :field-key))))))))

(defun supertag-ontology-migration-deploy--apply-action (action)
  "Apply one normalized migration ACTION."
  (pcase (plist-get action :kind)
    (:set-field-value
     (supertag-store-put-field-value
      (plist-get action :node-id)
      (plist-get action :field-id)
      (copy-tree (plist-get action :new-value))
      t))
    (:remove-field-value
     (supertag-store-remove-field-value
      (plist-get action :node-id)
      (plist-get action :field-id)))
    (:delete-relation
     (unless (supertag-relation-get (plist-get action :relation-id))
       (error "Migration relation %s disappeared before apply"
              (plist-get action :relation-id)))
     (supertag-relation-delete (plist-get action :relation-id)))
    (_
     (error "Unsupported migration action %S" (plist-get action :kind)))))

(defun supertag-ontology-migration-deploy--field-reference-relations (field-id)
  "Return all Field Reference projections owned by FIELD-ID."
  (let (relations)
    (maphash
     (lambda (_id relation)
       (when (supertag-relation-field-reference-p relation field-id)
         (push relation relations)))
     (supertag-store-get-collection :relations))
    relations))

(defun supertag-ontology-migration-deploy--reconcile-transformed-fields (plan)
  "Reconcile derived Field Reference relations after PLAN's schema update."
  (dolist (step-plan (plist-get plan :step-plans))
    (when (eq (plist-get step-plan :kind) :transform-field)
      (let* ((field-id (plist-get step-plan :runtime-id))
             (definition (supertag-store-get-field-definition field-id))
             (existing
              (supertag-ontology-migration-deploy--field-reference-relations
               field-id)))
        (if (eq (plist-get definition :type) :node-reference)
            (let ((nodes (make-hash-table :test #'equal)))
              (dolist (relation existing)
                (puthash (plist-get relation :from) t nodes))
              (maphash
               (lambda (node-id values)
                 (when (and (hash-table-p values)
                            (ht-contains? values field-id))
                   (puthash node-id t nodes)))
               (supertag-store-get-collection :field-values))
              (maphash
               (lambda (node-id _)
                 (supertag-relation-reconcile-field-reference node-id field-id))
               nodes))
          (dolist (relation existing)
            (supertag-relation-delete (plist-get relation :id))))))))

(defun supertag-ontology-migration-deploy--ledger-record (plan)
  "Return durable applied-migration record for PLAN."
  (let* ((migration (plist-get plan :migration))
         (model (plist-get plan :model))
         (source (plist-get migration :source)))
    (list :logical-id (plist-get migration :logical-id)
          :name (plist-get migration :name)
          :module (plist-get migration :module)
          :from-version (plist-get migration :from-version)
          :to-version (plist-get migration :to-version)
          :migration-model-version (plist-get migration :model-version)
          :migration-hash (plist-get plan :migration-hash)
          :ontology-model-hash (supertag-ontology-model-hash model)
          :runtime-hash-before (plist-get plan :runtime-hash)
          :data-hash-before (plist-get plan :data-hash)
          :step-count (length (plist-get migration :steps))
          :action-count
          (length (supertag-ontology-migration-plan-actions plan))
          :source-file (plist-get source :file)
          :source-line (plist-get source :line)
          :applied-at (float-time))))

(defun supertag-ontology-migration-deploy-apply-plan (plan)
  "Atomically apply migration PLAN exactly once."
  (supertag-ontology-migration-deploy--assert-current plan)
  ;; When the automation engine is active, load its synchronous gate before
  ;; creating the dynamic suppression bindings below.  This avoids loading the
  ;; module for users who do not use Automation, while ensuring an already
  ;; subscribed handler cannot initialize itself halfway through migration.
  (when (featurep 'supertag-automation)
    (require 'supertag-automation-sync nil t))
  (let ((ontology-plan (plist-get plan :ontology-plan)))
    (let ((supertag-automation--enabled nil)
          (supertag-automation-sync--enabled nil))
      (supertag-schema-authority-with-actor :migration
        (supertag-with-transaction
          (dolist (action (supertag-ontology-migration-plan-actions plan))
            (supertag-ontology-migration-deploy--apply-action action))
          ;; Data conflicts are resolved first; the candidate schema is then
          ;; validated by its normal Ops boundary under the :migration actor.
          (supertag-ontology-deploy-execute-plan ontology-plan t t)
          (supertag-ontology-migration-deploy--reconcile-transformed-fields plan)
          (supertag-ontology-migration-runtime-put
           (supertag-ontology-migration-deploy--ledger-record plan)))))
    (run-hook-with-args 'supertag-ontology-deployed-hook ontology-plan)
    (run-hook-with-args 'supertag-ontology-migrated-hook plan)
    plan))

(provide 'supertag-ontology-migration-deploy)
;;; supertag-ontology-migration-deploy.el ends here
