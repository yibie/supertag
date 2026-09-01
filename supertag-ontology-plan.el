;;; supertag-ontology-plan.el --- Desired-model versus live-Store planning. -*- lexical-binding: t; -*-

;;; Commentary:
;; Pure planning.  No Store mutation occurs here.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-ontology-model)
(require 'supertag-ontology-validator)
(require 'supertag-ontology-runtime)

(defvar supertag-ontology-plan--current-snapshot nil)

(defun supertag-ontology-plan--issue (severity code entity format-string &rest args)
  (list :severity severity :code code :entity entity
        :message (apply #'format format-string args)))

(defun supertag-ontology-plan--binding-for (model entity)
  "Return ENTITY's binding from the planning snapshot only."
  (cl-find-if
   (lambda (binding)
     (and (equal (plist-get model :module) (plist-get binding :module))
          (eq (plist-get entity :kind) (plist-get binding :kind))
          (equal (plist-get entity :key) (plist-get binding :key))))
   (plist-get supertag-ontology-plan--current-snapshot :bindings)))

(defun supertag-ontology-plan--runtime-id (model entity)
  (or (plist-get entity :runtime-id)
      (plist-get (supertag-ontology-plan--binding-for model entity) :runtime-id)))

(defun supertag-ontology-plan--runtime-ref (model kind key)
  (when-let ((entity (supertag-ontology-model-find model kind key)))
    (or (supertag-ontology-plan--runtime-id model entity)
        (plist-get entity :logical-id))))

(defun supertag-ontology-plan--change (class operation entity runtime-id changes)
  (list :class class :operation operation
        :entity-kind (plist-get entity :kind)
        :logical-id (plist-get entity :logical-id)
        :key (plist-get entity :key)
        :runtime-id runtime-id :desired entity :changes changes))

(defun supertag-ontology-plan--set-difference (a b)
  (cl-set-difference (copy-sequence (or a nil)) (copy-sequence (or b nil))
                     :test #'equal))

(defun supertag-ontology-plan--plan-field (model entity runtime)
  (let ((runtime-id (supertag-ontology-plan--runtime-id model entity))
        changes destructive)
    (if (null runtime-id)
        (list (supertag-ontology-plan--change :safe :create-field entity nil nil))
      (unless (equal (plist-get entity :label) (plist-get runtime :label))
        (push (list :slot :label :from (plist-get runtime :label)
                    :to (plist-get entity :label)) changes))
      (unless (equal (plist-get entity :type) (plist-get runtime :type))
        (setq destructive t)
        (push (list :slot :type :from (plist-get runtime :type)
                    :to (plist-get entity :type)) changes))
      (let ((removed (supertag-ontology-plan--set-difference
                      (plist-get runtime :options) (plist-get entity :options)))
            (added (supertag-ontology-plan--set-difference
                    (plist-get entity :options) (plist-get runtime :options))))
        (when removed (setq destructive t))
        (when (or removed added)
          (push (list :slot :options :add added :remove removed) changes)))
      (let ((desired-required (and (plist-get entity :required) t))
            (actual-required (and (plist-get runtime :required) t)))
        (unless (eq desired-required actual-required)
          ;; Tightening optional -> required is destructive because existing
          ;; nodes may have no stored value.  Relaxing required -> optional is
          ;; safe and needs no data rewrite.
          (when (and desired-required (not actual-required))
            (setq destructive t))
          (push (list :slot :required
                      :from actual-required :to desired-required)
                changes)))
      (unless (equal (plist-get entity :default)
                     (plist-get runtime :default))
        (push (list :slot :default
                    :from (plist-get runtime :default)
                    :to (plist-get entity :default))
              changes))
      (when changes
        (list (supertag-ontology-plan--change
               (if destructive :destructive :safe)
               :update-field entity runtime-id (nreverse changes)))))))

(defun supertag-ontology-plan--desired-type-field-ids (model entity)
  (mapcar (lambda (key) (supertag-ontology-plan--runtime-ref model :field key))
          (plist-get entity :fields)))

(defun supertag-ontology-plan--plan-type (model entity runtime)
  (let* ((runtime-id (supertag-ontology-plan--runtime-id model entity))
         (desired-parent (and (plist-get entity :extends)
                              (supertag-ontology-plan--runtime-ref
                               model :type (plist-get entity :extends))))
         (desired-fields (supertag-ontology-plan--desired-type-field-ids model entity))
         changes destructive)
    (if (null runtime-id)
        (list (supertag-ontology-plan--change
               :safe :create-type entity nil
               (list :extends desired-parent :fields desired-fields)))
      (unless (equal (plist-get entity :label) (plist-get runtime :label))
        (push (list :slot :label :from (plist-get runtime :label)
                    :to (plist-get entity :label)) changes))
      (unless (equal desired-parent (plist-get runtime :extends))
        (setq destructive (and (plist-get runtime :extends) t))
        (push (list :slot :extends :from (plist-get runtime :extends)
                    :to desired-parent) changes))
      (let ((removed (supertag-ontology-plan--set-difference
                      (plist-get runtime :fields) desired-fields))
            (added (supertag-ontology-plan--set-difference
                    desired-fields (plist-get runtime :fields))))
        (when removed (setq destructive t))
        (when (or removed added)
          (push (list :slot :fields :add added :remove removed) changes)))
      ;; Occurrence aliases.  The Tag ops layer owns the alias slot: it adds
      ;; the id, name and display path itself and users may add tokens by
      ;; hand, so the ontology only guarantees that its own tokens (the type
      ;; key plus declared :aliases) are answered.  Adding a token rewrites
      ;; no user data, so it is SAFE.  A token the ontology declared earlier
      ;; and has since dropped is offered as a SAFE :remove: the adapter
      ;; releases only tokens it recorded as ontology-managed and never
      ;; touches user-added aliases.  Records without an alias slot were
      ;; never normalized by the Tag ops layer (bare fixtures); their token
      ;; set is not reconciled here.
      (when (plist-get runtime :aliases-known-p)
        (let* ((desired (supertag-ontology-model-type-aliases entity))
               (answered (append (plist-get runtime :aliases)
                                 (list runtime-id (plist-get runtime :label))))
               (missing (cl-remove-if (lambda (token) (member token answered))
                                      desired))
               (stale (cl-remove-if (lambda (token) (member token desired))
                                    (plist-get runtime :managed-aliases))))
          (when (or missing stale)
            (push (list :slot :aliases :add missing :remove stale) changes))))
      (when changes
        (list (supertag-ontology-plan--change
               (if destructive :destructive :safe)
               :update-type entity runtime-id (nreverse changes)))))))

(defun supertag-ontology-plan--plan-link (model entity runtime)
  (let* ((runtime-id (supertag-ontology-plan--runtime-id model entity))
         (from-id (supertag-ontology-plan--runtime-ref model :type
                                                       (plist-get entity :from)))
         (to-id (supertag-ontology-plan--runtime-ref model :type
                                                     (plist-get entity :to)))
         changes destructive)
    (if (null runtime-id)
        (list (supertag-ontology-plan--change
               :safe :create-link entity nil
               (list :from-runtime-id from-id :to-runtime-id to-id)))
      (dolist (spec `((:label ,(plist-get entity :label)
                                ,(plist-get runtime :label) nil)
                      (:inverse-label ,(plist-get entity :inverse-label)
                                        ,(plist-get runtime :inverse-label) nil)
                      (:from-runtime-id ,from-id
                                        ,(plist-get runtime :from-runtime-id) t)
                      (:to-runtime-id ,to-id
                                      ,(plist-get runtime :to-runtime-id) t)
                      ;; Relaxing one -> many is safe.  Tightening many -> one
                      ;; needs an explicit migration because existing instances
                      ;; may conflict.
                      (:from-cardinality ,(plist-get entity :from-cardinality)
                                           ,(plist-get runtime :from-cardinality)
                                           ,(and (eq (plist-get runtime :from-cardinality) :many)
                                                 (eq (plist-get entity :from-cardinality) :one)))
                      (:to-cardinality ,(plist-get entity :to-cardinality)
                                         ,(plist-get runtime :to-cardinality)
                                         ,(and (eq (plist-get runtime :to-cardinality) :many)
                                               (eq (plist-get entity :to-cardinality) :one)))))
        (pcase-let ((`(,slot ,desired ,actual ,destructive-p) spec))
          (unless (equal desired actual)
            (when destructive-p (setq destructive t))
            (push (list :slot slot :from actual :to desired) changes))))
      (when changes
        (list (supertag-ontology-plan--change
               (if destructive :destructive :safe)
               :update-link entity runtime-id (nreverse changes)))))))

(defun supertag-ontology-plan--runtime-contract-type (model type)
  "Resolve Ontology Type keys embedded in contract TYPE for MODEL."
  (pcase type
    (`(:type ,key)
     (list :type (supertag-ontology-plan--runtime-ref model :type key)))
    (`(:maybe ,inner)
     (list :maybe (supertag-ontology-plan--runtime-contract-type model inner)))
    (`(:list ,inner)
     (list :list (supertag-ontology-plan--runtime-contract-type model inner)))
    (_ type)))

(defun supertag-ontology-plan--runtime-parameters (model parameters)
  "Resolve Ontology Type references in ordered PARAMETERS."
  (mapcar
   (lambda (parameter)
     (let ((copy (copy-tree parameter)))
       (plist-put
        copy :type
        (supertag-ontology-plan--runtime-contract-type
         model (plist-get parameter :type)))))
   parameters))

(defun supertag-ontology-plan--resolved-behavior (model entity)
  "Return runtime-reference contract for Function, Action or Policy ENTITY."
  (let ((resolved
         (unless (eq (plist-get entity :kind) :policy)
           (list :subject-type-id
                 (supertag-ontology-plan--runtime-ref
                  model :type (plist-get entity :subject))
                 :parameters
                 (supertag-ontology-plan--runtime-parameters
                  model (plist-get entity :parameters))))))
    (pcase (plist-get entity :kind)
      (:function
       (setq resolved
             (append resolved
                     (list :returns
                           (supertag-ontology-plan--runtime-contract-type
                            model (plist-get entity :returns))))))
      (:action
       (setq resolved
             (append
              resolved
              (list
               :preconditions
               (mapcar
                (lambda (precondition)
                  (let ((copy (copy-tree precondition)))
                    (plist-put
                     copy :function
                     (supertag-ontology-plan--runtime-ref
                      model :function (plist-get precondition :function)))))
                (plist-get entity :preconditions))
               :effects
               (mapcar
                (lambda (effect)
                  (let ((copy (copy-tree effect)))
                    (pcase (plist-get effect :kind)
                      ((or :set-field :clear-field)
                       (setq copy
                             (plist-put
                              copy :field
                              (supertag-ontology-plan--runtime-ref
                               model :field (plist-get effect :field)))))
                      ((or :add-link :remove-link)
                       (setq copy
                             (plist-put
                              copy :link
                              (supertag-ontology-plan--runtime-ref
                               model :link (plist-get effect :link))))))
                    copy))
                (plist-get entity :effects))))))
      (:policy
       (setq resolved
             (list :action-id
                   (supertag-ontology-plan--runtime-ref
                    model :action (plist-get entity :action))))))
    resolved))

(defun supertag-ontology-plan--behavior-contract (entity resolved)
  "Return comparable deployed contract for ENTITY and RESOLVED references."
  (append
   (list :label (plist-get entity :label)
         :description (plist-get entity :description)
         :subject-type-id (plist-get resolved :subject-type-id)
         :parameters (copy-tree (plist-get resolved :parameters))
         :llm-tool (and (plist-get entity :llm-tool) t)
         :tool-name (plist-get entity :tool-name)
         :tool-description (plist-get entity :tool-description))
   (pcase (plist-get entity :kind)
     (:function
      (list :returns (copy-tree (plist-get resolved :returns))
            :implementation (plist-get entity :implementation)))
     (:action
      (list :preconditions (copy-tree (plist-get resolved :preconditions))
            :effects (copy-tree (plist-get resolved :effects))
            :confirmation (plist-get entity :confirmation)))
     (:policy
      (list :action-id (plist-get resolved :action-id)
            :actors (copy-tree (plist-get entity :actors)))))))

(defun supertag-ontology-plan--plan-behavior (model entity runtime)
  "Plan Function, Action or Policy ENTITY against RUNTIME."
  (let* ((runtime-id (supertag-ontology-plan--runtime-id model entity))
         (resolved (supertag-ontology-plan--resolved-behavior model entity))
         (desired (supertag-ontology-plan--behavior-contract entity resolved))
         (kind (plist-get entity :kind))
         (prefix (substring (symbol-name kind) 1))
         changes)
    (if (null runtime-id)
        (list (supertag-ontology-plan--change
               :behavioral (intern (format ":create-%s" prefix)) entity nil resolved))
      (dolist (slot (pcase kind
                      (:function
                       '(:label :description :subject-type-id :parameters
                         :returns :implementation :llm-tool :tool-name
                         :tool-description))
                      (:action
                       '(:label :description :subject-type-id :parameters
                         :preconditions :effects :confirmation :llm-tool
                         :tool-name :tool-description))
                      (:policy
                       '(:label :description :action-id :actors))))
        (unless (equal (plist-get desired slot) (plist-get runtime slot))
          (push (list :slot slot :from (copy-tree (plist-get runtime slot))
                      :to (copy-tree (plist-get desired slot)))
                changes)))
      (when changes
        (list (supertag-ontology-plan--change
               ;; Executable contracts do not rewrite user data, but they do
               ;; change what the system can compute or execute.  They require
               ;; explicit behavioral approval and are never safe-auto-applied.
               :behavioral
               (intern (format ":update-%s" prefix)) entity runtime-id
               (list :resolved resolved :diff (nreverse changes))))))))

(defun supertag-ontology-plan--entity-operations (model entity runtime)
  (pcase (plist-get entity :kind)
    (:field (supertag-ontology-plan--plan-field model entity runtime))
    (:type (supertag-ontology-plan--plan-type model entity runtime))
    (:link (supertag-ontology-plan--plan-link model entity runtime))
    ((or :function :action :policy)
     (supertag-ontology-plan--plan-behavior model entity runtime))))

(defun supertag-ontology-plan-build (model &optional snapshot)
  "Build a deployment plan by comparing MODEL with live SNAPSHOT."
  (let* ((snapshot (or snapshot (supertag-ontology-runtime-snapshot)))
         (issues (supertag-ontology-validator-validate model))
         (module (plist-get model :module))
         (supertag-ontology-plan--current-snapshot snapshot)
         (module-record
          (cl-find module (plist-get snapshot :modules)
                   :key (lambda (record) (plist-get record :module))
                   :test #'equal))
         operations)
    (unless (supertag-ontology-validator-errors-p issues)
      (dolist (entity (supertag-ontology-model-entities model))
        (let* ((kind (plist-get entity :kind))
               (explicit-id (plist-get entity :runtime-id))
               (binding (supertag-ontology-plan--binding-for model entity))
               (bound-id (plist-get binding :runtime-id))
               (runtime-id (or explicit-id bound-id))
               (other-binding
                (and runtime-id
                     (cl-find-if
                      (lambda (record)
                        (and (eq kind (plist-get record :kind))
                             (equal runtime-id (plist-get record :runtime-id))
                             ;; Ownership identity is the structured
                             ;; module/kind/key triple.  Older v4 bindings may
                             ;; carry a colonized logical-id string; that is a
                             ;; formatting difference, not another owner.
                             (not (and
                                   (equal module (plist-get record :module))
                                   (eq kind (plist-get record :kind))
                                   (equal (plist-get entity :key)
                                          (plist-get record :key))))))
                      (plist-get snapshot :bindings))))
               (runtime (and runtime-id
                             (supertag-ontology-runtime-find snapshot kind runtime-id))))
          (when other-binding
            (push (supertag-ontology-plan--issue
                   :error :runtime-already-bound entity
                   "Runtime %s is already owned by %s"
                   runtime-id (plist-get other-binding :logical-id))
                  issues))
          (when (and explicit-id bound-id (not (equal explicit-id bound-id)))
            (push (supertag-ontology-plan--issue
                   :error :runtime-rebinding entity
                   "%s is bound to %s; refusing rebind to %s"
                   (plist-get entity :logical-id) bound-id explicit-id)
                  issues))
          (when (and runtime-id (null runtime))
            (push (supertag-ontology-plan--issue
                   :error :missing-runtime-entity entity
                   "Runtime %s %s does not exist" kind runtime-id)
                  issues))
          (when (and (null runtime-id)
                     (supertag-ontology-runtime-find-label
                      snapshot kind (plist-get entity :label)))
            (push (supertag-ontology-plan--issue
                   :error :implicit-adoption entity
                   "A runtime %s named %S exists; declare :runtime-id to adopt it"
                   kind (plist-get entity :label))
                  issues))
          (when (and runtime-id runtime)
            (let ((collisions
                   (cl-remove runtime
                              (supertag-ontology-runtime-find-label
                               snapshot kind (plist-get entity :label))
                              :test #'eq)))
              (when collisions
                (push (supertag-ontology-plan--issue
                       :error :runtime-label-collision entity
                       "Renaming %s to %S collides with runtime %s"
                       runtime-id (plist-get entity :label)
                       (plist-get (car collisions) :runtime-id))
                      issues))))
          (unless (cl-some
                   (lambda (issue)
                     (and (eq (plist-get issue :severity) :error)
                          (eq (plist-get issue :entity) entity)))
                   issues)
            (let ((entity-ops
                   (supertag-ontology-plan--entity-operations model entity runtime)))
              (setq operations (nconc operations entity-ops))
              ;; Explicit adoption with no structural change still needs a binding.
              (when (and runtime-id runtime
                         (or (null binding)
                             (eq (plist-get binding :control-storage) :legacy)
                             (not (equal (plist-get binding :logical-id)
                                         (plist-get entity :logical-id))))
                         (null entity-ops))
                (setq operations
                      (nconc operations
                             (list (supertag-ontology-plan--change
                                    :safe :bind-entity entity runtime-id nil)))))))))
      (dolist (binding
               (cl-remove-if-not
                (lambda (record) (equal module (plist-get record :module)))
                (plist-get snapshot :bindings)))
        (unless (supertag-ontology-model-find
                 model (plist-get binding :kind) (plist-get binding :key))
          (push (supertag-ontology-plan--change
                 :destructive :delete-managed binding
                 (plist-get binding :runtime-id) nil)
                operations))))
    (let* ((model-hash (supertag-ontology-model-hash model))
           (source (plist-get model :source))
           (module-update-p
            (or (null module-record)
                (eq (plist-get module-record :control-storage) :legacy)
                (not (equal model-hash (plist-get module-record :model-hash)))
                (not (equal (plist-get model :version)
                            (plist-get module-record :version)))
                (not (equal (plist-get source :file)
                            (plist-get module-record :source-file))))))
      (list :module module :version (plist-get model :version)
            :model model :model-hash model-hash
            :snapshot snapshot
            :runtime-hash (supertag-ontology-runtime-hash snapshot)
            :module-update-p module-update-p
            :issues (nreverse issues)
            :operations operations))))

(defun supertag-ontology-plan-errors-p (plan)
  (cl-some (lambda (issue) (eq (plist-get issue :severity) :error))
           (plist-get plan :issues)))

(defun supertag-ontology-plan-destructive-p (plan)
  (cl-some (lambda (op) (eq (plist-get op :class) :destructive))
           (plist-get plan :operations)))

(defun supertag-ontology-plan-behavioral-p (plan)
  "Return non-nil when PLAN changes Function, Action, or Policy behavior."
  (cl-some (lambda (op) (eq (plist-get op :class) :behavioral))
           (plist-get plan :operations)))

(defun supertag-ontology-plan-safe-p (plan)
  "Return non-nil when PLAN contains only non-behavioral safe changes."
  (and (not (supertag-ontology-plan-errors-p plan))
       (not (supertag-ontology-plan-destructive-p plan))
       (not (supertag-ontology-plan-behavioral-p plan))))

(defun supertag-ontology-plan-empty-p (plan)
  "Return non-nil when PLAN needs no Store mutation."
  (and (null (plist-get plan :operations))
       (not (plist-get plan :module-update-p))))

(provide 'supertag-ontology-plan)
;;; supertag-ontology-plan.el ends here
