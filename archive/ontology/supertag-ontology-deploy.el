;;; supertag-ontology-deploy.el --- Atomic deployment of ontology plans. -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-state)
(require 'supertag-schema-authority)
(require 'supertag-ontology-model)
(require 'supertag-ontology-plan)
(require 'supertag-ontology-runtime)
(require 'supertag-ontology-adapter)

(defvar supertag-ontology-deployed-hook nil)

(defvar supertag-ontology-deploy--transaction-thunk nil
  "Dynamically bound deployment thunk for `supertag-ontology-deploy--default-transaction'.")

(defun supertag-ontology-deploy--default-transaction (thunk)
  "Execute THUNK inside `supertag-with-transaction'."
  (let ((supertag-ontology-deploy--transaction-thunk thunk))
    (eval '(supertag-with-transaction
             (funcall supertag-ontology-deploy--transaction-thunk)) t)))

(defcustom supertag-ontology-deploy-transaction-function
  #'supertag-ontology-deploy--default-transaction
  "Function receiving a zero-argument deployment thunk."
  :type 'function)

(defcustom supertag-ontology-deploy-operation-function
  #'supertag-ontology-deploy--apply-operation
  "Function applying one normalized deployment operation."
  :type 'function)

(defun supertag-ontology-deploy--resolve-ref (created ref)
  (if (and (stringp ref) (string-match-p "/" ref))
      (or (gethash ref created)
          (error "Unresolved logical runtime reference %s" ref))
    ref))

(defun supertag-ontology-deploy--resolve-contract-type (created type)
  "Resolve logical references embedded in contract TYPE."
  (pcase type
    (`(:type ,ref)
     (list :type (supertag-ontology-deploy--resolve-ref created ref)))
    (`(:maybe ,inner)
     (list :maybe
           (supertag-ontology-deploy--resolve-contract-type created inner)))
    (`(:list ,inner)
     (list :list
           (supertag-ontology-deploy--resolve-contract-type created inner)))
    (_ type)))

(defun supertag-ontology-deploy--resolve-behavior (created raw)
  "Resolve logical IDs in a compiled Function, Action or Policy contract."
  (let ((resolved (copy-tree raw)))
    (when (plist-member resolved :subject-type-id)
      (setq resolved
            (plist-put
             resolved :subject-type-id
             (supertag-ontology-deploy--resolve-ref
              created (plist-get resolved :subject-type-id)))))
    (when (plist-member resolved :parameters)
      (setq resolved
            (plist-put
             resolved :parameters
             (mapcar
              (lambda (parameter)
                (let ((copy (copy-tree parameter)))
                  (plist-put
                   copy :type
                   (supertag-ontology-deploy--resolve-contract-type
                    created (plist-get parameter :type)))))
              (plist-get resolved :parameters)))))
    (when (plist-member resolved :action-id)
      (setq resolved
            (plist-put
             resolved :action-id
             (supertag-ontology-deploy--resolve-ref
              created (plist-get resolved :action-id)))))
    (when (plist-member resolved :returns)
      (setq resolved
            (plist-put
             resolved :returns
             (supertag-ontology-deploy--resolve-contract-type
              created (plist-get resolved :returns)))))
    (when (plist-member resolved :preconditions)
      (setq resolved
            (plist-put
             resolved :preconditions
             (mapcar
              (lambda (precondition)
                (let ((copy (copy-tree precondition)))
                  (plist-put
                   copy :function
                   (supertag-ontology-deploy--resolve-ref
                    created (plist-get precondition :function)))))
              (plist-get resolved :preconditions)))))
    (when (plist-member resolved :effects)
      (setq resolved
            (plist-put
             resolved :effects
             (mapcar
              (lambda (effect)
                (let ((copy (copy-tree effect)))
                  (pcase (plist-get effect :kind)
                    ((or :set-field :clear-field)
                     (setq copy
                           (plist-put
                            copy :field
                            (supertag-ontology-deploy--resolve-ref
                             created (plist-get effect :field)))))
                    ((or :add-link :remove-link)
                     (setq copy
                           (plist-put
                            copy :link
                            (supertag-ontology-deploy--resolve-ref
                             created (plist-get effect :link))))))
                  copy))
              (plist-get resolved :effects)))))
    resolved))

(defun supertag-ontology-deploy--binding-record (plan operation runtime-id)
  (let* ((model (plist-get plan :model))
         (entity (plist-get operation :desired))
         (source (plist-get model :source)))
    (list :owner :ontology :managed-by :ontology
          :module (plist-get model :module)
          :kind (plist-get entity :kind) :key (plist-get entity :key)
          :logical-id (plist-get entity :logical-id)
          :runtime-id runtime-id :label (plist-get entity :label)
          :source-file (plist-get source :file)
          :source-line (plist-get source :line)
          :module-version (plist-get model :version))))

(defun supertag-ontology-deploy--adapter-entity (plan entity)
  "Return ENTITY enriched with module metadata for the adapter."
  (let ((copy (copy-tree entity)))
    (setq copy (plist-put copy :module (plist-get plan :module)))
    copy))

(defun supertag-ontology-deploy--apply-operation (plan operation created)
  (let* ((entity (supertag-ontology-deploy--adapter-entity
                  plan (plist-get operation :desired)))
         (logical-id (plist-get operation :logical-id))
         (runtime-id (plist-get operation :runtime-id))
         result-id)
    (pcase (plist-get operation :operation)
      (:bind-entity (setq result-id runtime-id))
      (:create-field
       (setq result-id (supertag-ontology-adapter-create-field entity)))
      (:update-field
       (setq result-id (supertag-ontology-adapter-update-field runtime-id entity)))
      (:create-type
       (setq result-id (supertag-ontology-adapter-create-type entity))
       (let* ((changes (plist-get operation :changes))
              (parent (supertag-ontology-deploy--resolve-ref
                       created (plist-get changes :extends))))
         (when parent
           (supertag-ontology-adapter-set-type-parent result-id parent))
         (dolist (field-ref (plist-get changes :fields))
           (supertag-ontology-adapter-add-type-field
            result-id (supertag-ontology-deploy--resolve-ref created field-ref)))))
      (:update-type
       (setq result-id (supertag-ontology-adapter-update-type runtime-id entity))
       (dolist (change (plist-get operation :changes))
         (pcase (plist-get change :slot)
           (:extends
            (supertag-ontology-adapter-set-type-parent
             runtime-id
             (supertag-ontology-deploy--resolve-ref created
                                                    (plist-get change :to))))
           (:fields
            (dolist (field-ref (plist-get change :remove))
              (supertag-ontology-adapter-remove-type-field
               runtime-id
               (supertag-ontology-deploy--resolve-ref created field-ref)))
            (dolist (field-ref (plist-get change :add))
              (supertag-ontology-adapter-add-type-field
               runtime-id
               (supertag-ontology-deploy--resolve-ref created field-ref)))))))
      (:create-link
       (let ((changes (plist-get operation :changes)))
         (setq result-id
               (supertag-ontology-adapter-create-link
                entity
                (supertag-ontology-deploy--resolve-ref
                 created (plist-get changes :from-runtime-id))
                (supertag-ontology-deploy--resolve-ref
                 created (plist-get changes :to-runtime-id))))))
      (:update-link
       (setq result-id
             (supertag-ontology-adapter-update-link
              runtime-id entity
              (supertag-ontology-deploy--resolve-ref
               created
               (supertag-ontology-plan--runtime-ref
                (plist-get plan :model) :type (plist-get entity :from)))
              (supertag-ontology-deploy--resolve-ref
               created
               (supertag-ontology-plan--runtime-ref
                (plist-get plan :model) :type (plist-get entity :to))))))
      ((or :create-function :create-action :create-policy)
       (setq result-id
             (supertag-ontology-adapter-create-behavior
              entity
              (supertag-ontology-deploy--resolve-behavior
               created (plist-get operation :changes)))))
      ((or :update-function :update-action :update-policy)
       (setq result-id
             (supertag-ontology-adapter-update-behavior
              runtime-id entity
              (supertag-ontology-deploy--resolve-behavior
               created (plist-get (plist-get operation :changes)
                                   :resolved)))))
      (_ (error "Unsupported ontology deployment operation %S"
                (plist-get operation :operation))))
    (when logical-id
      (puthash logical-id result-id created)
      (supertag-ontology-runtime-binding-put
       (supertag-ontology-deploy--binding-record plan operation result-id)))
    result-id))

(defun supertag-ontology-deploy--assert-current (plan)
  "Reject PLAN when the live Store changed after planning."
  (let ((planned (plist-get plan :runtime-hash))
        (current (supertag-ontology-runtime-hash)))
    (unless (equal planned current)
      (user-error "Ontology plan is stale; preview again before applying"))))

(defun supertag-ontology-deploy--created-map (plan)
  "Return logical-id -> runtime-id map initialized for PLAN."
  (let ((created (make-hash-table :test #'equal)))
    (dolist (binding (supertag-ontology-runtime-bindings
                      (plist-get plan :module)))
      (puthash (plist-get binding :logical-id)
               (plist-get binding :runtime-id) created))
    created))

(defun supertag-ontology-deploy--write-module-record (plan)
  "Persist PLAN's module provenance when required."
  (when (plist-get plan :module-update-p)
    (let* ((model (plist-get plan :model))
           (source (plist-get model :source)))
      (supertag-ontology-runtime-module-put
       (list :module (plist-get model :module)
             :version (plist-get model :version)
             :model-hash (plist-get plan :model-hash)
             :source-file (plist-get source :file)
             :source-line (plist-get source :line)
             :deployed-at (float-time))))))

(defun supertag-ontology-deploy-execute-plan
    (plan &optional allow-destructive allow-behavioral)
  "Execute PLAN in the caller's mutation boundary.

The caller owns actor selection, transaction scope, and post-commit hooks.
When ALLOW-DESTRUCTIVE is nil, reject destructive operations.  When
ALLOW-BEHAVIORAL is nil, reject Function, Action, and Policy changes.  This is
the single execution primitive used both by ordinary ontology deployment and by
the migration subsystem."
  (when allow-destructive
    (unless (eq supertag-schema-authority-current-actor :migration)
      (error "Destructive ontology execution requires the :migration actor"))
    (unless supertag--transaction-active
      (error "Destructive ontology execution requires an active Store transaction")))
  (when (supertag-ontology-plan-errors-p plan)
    (user-error "Ontology plan contains validation or binding errors"))
  (when (and (supertag-ontology-plan-destructive-p plan)
             (not allow-destructive))
    (user-error "Ontology plan contains destructive changes; migration is required"))
  (when (and (supertag-ontology-plan-behavioral-p plan)
             (not allow-behavioral))
    (user-error
     "Ontology plan contains executable Function, Action, or Policy changes; explicit approval is required"))
  (supertag-ontology-deploy--assert-current plan)
  (unless (supertag-ontology-plan-empty-p plan)
    (let ((created (supertag-ontology-deploy--created-map plan)))
      (dolist (operation (plist-get plan :operations))
        (funcall supertag-ontology-deploy-operation-function
                 plan operation created))
      (supertag-ontology-deploy--write-module-record plan)))
  plan)

(defun supertag-ontology-deploy-apply-plan (plan &optional allow-behavioral)
  "Atomically apply PLAN; executable changes need ALLOW-BEHAVIORAL."
  (when (supertag-ontology-plan-errors-p plan)
    (user-error "Ontology plan contains validation or binding errors"))
  (when (supertag-ontology-plan-destructive-p plan)
    (user-error "Ontology plan contains destructive changes; migration is required"))
  (when (and (supertag-ontology-plan-behavioral-p plan)
             (not allow-behavioral))
    (user-error
     "Ontology plan contains executable Function, Action, or Policy changes; explicit approval is required"))
  (supertag-ontology-deploy--assert-current plan)
  (if (supertag-ontology-plan-empty-p plan)
      plan
    (progn
      (supertag-schema-authority-with-actor :ontology-deployment
        (funcall
         supertag-ontology-deploy-transaction-function
         (lambda ()
           (supertag-ontology-deploy-execute-plan
            plan nil allow-behavioral))))
      (run-hook-with-args 'supertag-ontology-deployed-hook plan)
      plan)))

(provide 'supertag-ontology-deploy)
;;; supertag-ontology-deploy.el ends here
