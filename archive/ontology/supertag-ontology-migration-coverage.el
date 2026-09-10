;;; supertag-ontology-migration-coverage.el --- Destructive change coverage -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Matches destructive ontology operations to explicit migration steps.  This
;; module is pure with respect to the Store: it only reads the desired model,
;; the deployment plan, and runtime bindings supplied by the runtime boundary.

;;; Code:

(require 'cl-lib)
(require 'supertag-ontology-model)
(require 'supertag-ontology-migration-runtime)

(defun supertag-ontology-migration-coverage--issue
    (severity code message &optional step operation)
  "Build one migration coverage issue."
  (list :severity severity :code code :message message
        :step step :operation operation))

(defun supertag-ontology-migration-coverage--step
    (migration kind &rest selectors)
  "Find one MIGRATION step of KIND matching SELECTORS plist."
  (cl-find-if
   (lambda (step)
     (and (eq kind (plist-get step :kind))
          (cl-loop for (slot value) on selectors by #'cddr
                   always (equal value (plist-get step slot)))))
   (plist-get migration :steps)))

(defun supertag-ontology-migration-coverage--mark-used (used step)
  "Mark STEP as used in USED and return STEP."
  (when step
    (puthash (plist-get step :id) t used))
  step)

(defun supertag-ontology-migration-coverage--field
    (migration operation used)
  "Return coverage issues for destructive field OPERATION."
  (let* ((key (plist-get operation :key))
         (changes (plist-get operation :changes))
         (required-tightening
          (cl-find-if
           (lambda (change)
             (and (eq (plist-get change :slot) :required)
                  (null (plist-get change :from))
                  (eq (plist-get change :to) t)))
           changes))
         (transform-needed
          (cl-some
           (lambda (change)
             (memq (plist-get change :slot) '(:type :options)))
           changes))
         issues)
    ;; A transform-field step only visits nodes that already have values.  It
    ;; cannot prove or repair the absence of values on every node carrying a
    ;; type that uses the field, so optional -> required needs a future
    ;; fill-missing step rather than pretending transform-field covers it.
    (when required-tightening
      (push
       (supertag-ontology-migration-coverage--issue
        :error :unsupported-required-tightening
        (format "Making field %s required is not supported by Migration DSL v1"
                key)
        nil operation)
       issues))
    (when transform-needed
      (let ((step
             (supertag-ontology-migration-coverage--step
              migration :transform-field :field key)))
        (if step
            (supertag-ontology-migration-coverage--mark-used used step)
          (push
           (supertag-ontology-migration-coverage--issue
            :error :uncovered-field-change
            (format "Destructive field change %s requires (transform-field %s ...)"
                    (plist-get operation :logical-id) key)
            nil operation)
           issues))))
    (unless (or required-tightening transform-needed)
      (push
       (supertag-ontology-migration-coverage--issue
        :error :unsupported-field-migration
        (format "Field migration %s is not supported by Migration DSL v1" key)
        nil operation)
       issues))
    (nreverse issues)))

(defun supertag-ontology-migration-coverage--type
    (migration model operation used)
  "Return coverage issues for destructive type OPERATION."
  (let ((type-key (plist-get operation :key))
        issues
        covered)
    (dolist (change (plist-get operation :changes))
      (pcase (plist-get change :slot)
        (:extends
         (when (plist-get change :from)
           (push
            (supertag-ontology-migration-coverage--issue
             :error :unsupported-parent-migration
             (format "Changing parent of type %s is not supported by Migration DSL v1"
                     type-key)
             nil operation)
            issues)))
        (:fields
         (dolist (runtime-field-id (plist-get change :remove))
           (let* ((field-key
                   (supertag-ontology-migration-runtime-field-key
                    model runtime-field-id))
                  (step
                   (and field-key
                        (supertag-ontology-migration-coverage--step
                         migration :detach-field
                         :type type-key :field field-key))))
             (if step
                 (progn
                   (setq covered t)
                   (supertag-ontology-migration-coverage--mark-used used step))
               (push
                (supertag-ontology-migration-coverage--issue
                 :error :uncovered-field-detach
                 (if field-key
                     (format "Removing %s from type %s requires (detach-field %s %s)"
                             field-key type-key type-key field-key)
                   (format "Cannot map runtime field %s removed from type %s to an ontology key"
                           runtime-field-id type-key))
                 nil operation)
                issues)))))))
    (unless (or issues covered)
      (push
       (supertag-ontology-migration-coverage--issue
        :error :unsupported-type-migration
        (format "Type migration %s is not supported by Migration DSL v1"
                type-key)
        nil operation)
       issues))
    (nreverse issues)))

(defun supertag-ontology-migration-coverage--tightening-p (change)
  "Return non-nil when CHANGE tightens cardinality many to one."
  (and (memq (plist-get change :slot)
             '(:from-cardinality :to-cardinality))
       (eq (plist-get change :from) :many)
       (eq (plist-get change :to) :one)))

(defun supertag-ontology-migration-coverage--link
    (migration operation used)
  "Return coverage issues for destructive Link OPERATION."
  (let ((key (plist-get operation :key))
        needs-tighten
        issues)
    (dolist (change (plist-get operation :changes))
      (pcase (plist-get change :slot)
        ((or :from-runtime-id :to-runtime-id)
         (push
          (supertag-ontology-migration-coverage--issue
           :error :unsupported-link-endpoint-migration
           (format "Changing endpoints of Link %s is not supported by Migration DSL v1"
                   key)
           nil operation)
          issues))
        ((or :from-cardinality :to-cardinality)
         (when (supertag-ontology-migration-coverage--tightening-p change)
           (setq needs-tighten t)))))
    (when needs-tighten
      (let ((step
             (supertag-ontology-migration-coverage--step
              migration :tighten-link :link key)))
        (if step
            (supertag-ontology-migration-coverage--mark-used used step)
          (push
           (supertag-ontology-migration-coverage--issue
            :error :uncovered-link-tightening
            (format "Tightening Link %s requires (tighten-link %s ...)" key key)
            nil operation)
           issues))))
    (unless (or issues needs-tighten)
      (push
       (supertag-ontology-migration-coverage--issue
        :error :unsupported-link-migration
        (format "Link migration %s is not supported by Migration DSL v1" key)
        nil operation)
       issues))
    (nreverse issues)))

(defun supertag-ontology-migration-coverage-analyze
    (migration model ontology-plan)
  "Return coverage result for MIGRATION, MODEL, and ONTOLOGY-PLAN.

The result is a plist containing :issues and a :used hash table keyed by
migration step ID.  Every destructive operation must have exact coverage and
every declared step must cover an operation in the current live diff."
  (let ((used (make-hash-table :test #'equal))
        issues
        (destructive-count 0))
    (dolist (operation (plist-get ontology-plan :operations))
      (when (eq (plist-get operation :class) :destructive)
        (setq destructive-count (1+ destructive-count))
        (setq
         issues
         (nconc
          issues
          (pcase (plist-get operation :operation)
            (:update-field
             (supertag-ontology-migration-coverage--field
              migration operation used))
            (:update-type
             (supertag-ontology-migration-coverage--type
              migration model operation used))
            (:update-link
             (supertag-ontology-migration-coverage--link
              migration operation used))
            (:delete-managed
             (list
              (supertag-ontology-migration-coverage--issue
               :error :unsupported-managed-deletion
               (format "Deleting managed %s %s is not supported by Migration DSL v1"
                       (plist-get operation :entity-kind)
                       (plist-get operation :logical-id))
               nil operation)))
            (_
             (list
              (supertag-ontology-migration-coverage--issue
               :error :unsupported-destructive-operation
               (format "Unsupported destructive operation %S"
                       (plist-get operation :operation))
               nil operation))))))))
    (when (zerop destructive-count)
      (push
       (supertag-ontology-migration-coverage--issue
        :error :no-destructive-change
        "The desired ontology has no destructive change requiring this migration")
       issues))
    (dolist (step (plist-get migration :steps))
      (unless (gethash (plist-get step :id) used)
        (push
         (supertag-ontology-migration-coverage--issue
          :error :unused-step
          (format "Migration step %s does not cover a current destructive change"
                  (plist-get step :id))
          step)
         issues)))
    (list :issues (nreverse issues) :used used)))

(provide 'supertag-ontology-migration-coverage)
;;; supertag-ontology-migration-coverage.el ends here
