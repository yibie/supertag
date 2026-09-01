;;; supertag-ontology-action.el --- Transactional Ontology Action runtime -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Ontology Actions are deployed, typed, declarative semantic transitions.
;; Preview is read-only.  Execution re-resolves the deployed contract, Policy,
;; preconditions, and effects inside one outer Canonical Change transaction.
;; Successful effects and their bounded audit record commit together.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-change)
(require 'supertag-core-store)
(require 'supertag-ops-field)
(require 'supertag-ops-global-field)
(require 'supertag-ops-link-definition)
(require 'supertag-ops-node)
(require 'supertag-ops-relation)
(require 'supertag-ops-tag)
(require 'supertag-ontology-contract)
(require 'supertag-ontology-function)
(require 'supertag-ontology-policy)

(defvar supertag-ontology-action-executed-hook nil
  "Hook run after an Ontology Action has committed.")

(defvar supertag-ontology-action-hook-errors nil
  "Captured post-commit Action hook failures, newest first.")

(defvar supertag-automation-sync--enabled)

(defconst supertag-ontology-action--missing
  (make-symbol "supertag-ontology-action-missing"))

(defun supertag-ontology-action-list ()
  "Return deployed Action definitions in stable identity order."
  (let (records)
    (maphash
     (lambda (_id record)
       (push (supertag-ontology-contract-copy record) records))
     (supertag-store-get-collection :ontology-actions))
    (sort records
          (lambda (left right)
            (string< (or (plist-get left :logical-id) "")
                     (or (plist-get right :logical-id) ""))))))

(defun supertag-ontology-action-resolve (reference &optional noerror)
  "Resolve Action REFERENCE by runtime ID, logical ID, module/key, key or label.

A caller-supplied plist is never trusted as an executable contract.  When it
contains an ID, the deployed Store-owned Action is re-read."
  (let* ((reference
          (if (and (proper-list-p reference) (plist-get reference :runtime-id))
              (plist-get reference :runtime-id)
            (if (and (proper-list-p reference) (plist-get reference :id))
                (plist-get reference :id)
              reference)))
         (records (supertag-ontology-action-list))
         (text (cond ((symbolp reference) (symbol-name reference))
                     ((stringp reference) reference)))
         (exact (and text
                     (supertag-store-get-entity :ontology-actions text)))
         (matches
          (and (not exact)
               (cl-remove-if-not
                (lambda (record)
                  (or (equal text (plist-get record :logical-id))
                      (equal text
                             (format "%s/%s" (plist-get record :module)
                                     (plist-get record :key)))
                      (equal text (format "%s" (plist-get record :key)))
                      (equal text (plist-get record :label))))
                records))))
    (cond
     (exact (supertag-ontology-contract-copy exact))
     ((= (length matches) 1)
      (supertag-ontology-contract-copy (car matches)))
     ((and matches (not noerror))
      (error "Ambiguous Ontology Action reference %S" reference))
     ((not noerror) (error "Unknown Ontology Action %S" reference)))))

(defun supertag-ontology-action--argument-expression-value
    (name bound)
  "Return Action argument NAME from BOUND or reject omission."
  (unless (supertag-ontology-contract-argument-present-p name bound)
    (error "Action expression requires omitted argument %S" name))
  (supertag-ontology-contract-argument name bound))

(defun supertag-ontology-action--expression-value
    (expression node-id bound)
  "Evaluate safe declarative EXPRESSION for NODE-ID and BOUND arguments."
  (pcase expression
    (`(:arg ,name)
     (supertag-ontology-action--argument-expression-value name bound))
    (`(:subject) node-id)
    (`(:literal ,value) (supertag-ontology-contract-copy value))
    (`(:now) (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
    (`(:function ,reference . ,tail)
     (let ((argument-form (plist-get tail :arguments)))
       (supertag-ontology-function-call
        reference node-id
        (supertag-ontology-action--expression-arguments
         argument-form node-id bound))))
    (_ (supertag-ontology-contract-copy expression))))

(defun supertag-ontology-action--expression-arguments
    (arguments node-id bound)
  "Evaluate declarative Function ARGUMENTS for NODE-ID and BOUND arguments."
  (cond
   ((null arguments) nil)
   ((and (proper-list-p arguments) (keywordp (car arguments)))
    (let ((cursor arguments) result)
      (unless (zerop (% (length cursor) 2))
        (error "Action expression argument plist has odd length"))
      (while cursor
        (let ((key (pop cursor)) (expression (pop cursor)))
          (setq result
                (append result
                        (list key
                              (supertag-ontology-action--expression-value
                               expression node-id bound))))))
      result))
   ((and (proper-list-p arguments) (cl-every #'consp arguments))
    (mapcar
     (lambda (pair)
       (cons (car pair)
             (supertag-ontology-action--expression-value
              (if (and (consp (cdr pair)) (null (cddr pair)))
                  (cadr pair)
                (cdr pair))
              node-id bound)))
     arguments))
   (t (error "Action expression arguments must be a plist or alist"))))

(defun supertag-ontology-action--compare (operator actual expected)
  "Evaluate precondition OPERATOR for ACTUAL and EXPECTED."
  (pcase operator
    (:truthy (not (null actual)))
    (:falsey (null actual))
    (:equal (equal actual expected))
    (:not-equal (not (equal actual expected)))
    (:greater (and (numberp actual) (numberp expected) (> actual expected)))
    (:greater-equal
     (and (numberp actual) (numberp expected) (>= actual expected)))
    (:less (and (numberp actual) (numberp expected) (< actual expected)))
    (:less-equal
     (and (numberp actual) (numberp expected) (<= actual expected)))
    (_ (error "Unsupported Action precondition operator %S" operator))))

(defun supertag-ontology-action--check-preconditions
    (definition node-id bound)
  "Check every Function precondition in DEFINITION for NODE-ID and BOUND."
  (dolist (precondition (plist-get definition :preconditions))
    (let* ((function (plist-get precondition :function))
           (arguments
            (supertag-ontology-action--expression-arguments
             (plist-get precondition :arguments) node-id bound))
           (actual (supertag-ontology-function-call
                    function node-id arguments))
           (operator (or (plist-get precondition :operator) :truthy))
           (expected
            (supertag-ontology-action--expression-value
             (plist-get precondition :value) node-id bound)))
      (unless (supertag-ontology-action--compare operator actual expected)
        (user-error "Action precondition failed: %s returned %S"
                    function actual)))))

(defun supertag-ontology-action--subject-field (definition field-id)
  "Return FIELD-ID definition when it belongs to Action DEFINITION's Type."
  (cl-find field-id
           (supertag-tag-get-all-fields
            (plist-get definition :subject-type-id))
           :key (lambda (field) (plist-get field :id)) :test #'equal))

(defun supertag-ontology-action--sensitive-expression-p
    (expression definition)
  "Return non-nil when EXPRESSION transitively reads a sensitive parameter."
  (pcase expression
    (`(:arg ,name)
     (and (plist-get
           (cl-find name (plist-get definition :parameters)
                    :key (lambda (parameter) (plist-get parameter :name))
                    :test #'eq)
           :sensitive)
          t))
    (`(:function ,_reference . ,tail)
     (let ((arguments (plist-get tail :arguments)))
       (cond
        ((and (proper-list-p arguments) (keywordp (car arguments)))
         (cl-loop for (_key value) on arguments by #'cddr
                  thereis
                  (supertag-ontology-action--sensitive-expression-p
                   value definition)))
        ((and (proper-list-p arguments) (cl-every #'consp arguments))
         (cl-some
          (lambda (pair)
            (supertag-ontology-action--sensitive-expression-p
             (if (and (consp (cdr pair)) (null (cddr pair)))
                 (cadr pair)
               (cdr pair))
             definition))
          arguments)))))
    (_ nil)))

(defun supertag-ontology-action--plan-field
    (definition effect node-id bound)
  "Plan one Field EFFECT for Action DEFINITION."
  (let* ((field-id (plist-get effect :field))
         (field (supertag-ontology-action--subject-field definition field-id))
         (old (supertag-store-get-field-value
               node-id field-id supertag-ontology-action--missing)))
    (unless field
      (error "Field %s does not belong to Action subject Type %s"
             field-id (plist-get definition :subject-type-id)))
    (when (eq (plist-get field :type) :node-reference)
      (error "Action v11 cannot mutate node-reference Field %s; use a typed Link effect"
             field-id))
    (pcase (plist-get effect :kind)
      (:set-field
       (let* ((expression (plist-get effect :value))
              (raw (supertag-ontology-action--expression-value
                    expression node-id bound))
              (value (supertag-field-normalize
                      (plist-get definition :subject-type-id) field-id raw)))
         (unless (supertag-field-validate
                  (plist-get definition :subject-type-id) field-id value)
           (error "Action value for Field %s is invalid" field-id))
         (list :kind :set-field :node-id node-id :field-id field-id
               :old-exists (not (eq old supertag-ontology-action--missing))
               :old (unless (eq old supertag-ontology-action--missing)
                      (supertag-ontology-contract-copy old))
               :new (supertag-ontology-contract-copy value)
               :sensitive-p
               (and (supertag-ontology-action--sensitive-expression-p
                     expression definition) t))))
      (:clear-field
       (when (plist-get field :required)
         (error "Required Field %s cannot be cleared" field-id))
       (list :kind :clear-field :node-id node-id :field-id field-id
             :old-exists (not (eq old supertag-ontology-action--missing))
             :old (unless (eq old supertag-ontology-action--missing)
                    (supertag-ontology-contract-copy old)))))))

(defun supertag-ontology-action--plan-link
    (definition effect node-id bound)
  "Plan one subject-anchored typed Link EFFECT."
  (let* ((definition-id (plist-get effect :link))
         (direction (or (plist-get effect :direction) :forward))
         (target-expression (plist-get effect :target))
         (target-id
          (supertag-ontology-action--expression-value
           target-expression node-id bound))
         (from-id (if (eq direction :reverse) target-id node-id))
         (to-id (if (eq direction :reverse) node-id target-id))
         (link-definition (supertag-link-definition-get definition-id)))
    (unless (memq direction '(:forward :reverse))
      (error "Unsupported Action Link direction %S" direction))
    (unless (and (stringp target-id) (not (string-empty-p target-id)))
      (error "Action Link target must resolve to one node ID string"))
    (unless link-definition
      (error "Unknown Link Definition %s" definition-id))
    ;; The subject must occupy the declared endpoint for this direction.
    (unless (supertag-link-definition-node-satisfies-type-p
             node-id
             (plist-get link-definition
                        (if (eq direction :reverse) :to-tag-id :from-tag-id)))
      (error "Action subject does not satisfy the %s endpoint of Link %s"
             direction definition-id))
    (pcase (plist-get effect :kind)
      (:add-link
       (let* ((existing (car (supertag-link-find
                              definition-id from-id to-id)))
              (conflicts (unless existing
                           (supertag-link-conflicts
                            definition-id from-id to-id)))
              (replace (and (plist-get effect :replace) t)))
         (when (and conflicts (not replace))
           (error "Link effect conflicts with %d existing relation(s)"
                  (length conflicts)))
         (if replace
             (progn
               (unless (supertag-link-definition-node-satisfies-type-p
                        from-id (plist-get link-definition :from-tag-id))
                 (error "Link source %s has the wrong Type" from-id))
               (unless (supertag-link-definition-node-satisfies-type-p
                        to-id (plist-get link-definition :to-tag-id))
                 (error "Link target %s has the wrong Type" to-id)))
           (supertag-link-definition-validate-instance
            definition-id from-id to-id))
         (list :kind :add-link :definition-id definition-id
               :subject-id node-id :direction direction :target-id target-id
               :from from-id :to to-id :existing existing
               :replace-conflicts
               (supertag-ontology-contract-copy conflicts)
               :sensitive-target-p
               (and (supertag-ontology-action--sensitive-expression-p
                     target-expression definition) t))))
      (:remove-link
       (let ((relations (supertag-link-find definition-id from-id to-id)))
         (list :kind :remove-link :definition-id definition-id
               :subject-id node-id :direction direction :target-id target-id
               :from from-id :to to-id
               :relations (supertag-ontology-contract-copy relations)
               :sensitive-target-p
               (and (supertag-ontology-action--sensitive-expression-p
                     target-expression definition) t)))))))

(defun supertag-ontology-action--plan (reference node-id arguments)
  "Build a fresh complete Action plan for REFERENCE, NODE-ID and ARGUMENTS."
  (let* ((definition (supertag-ontology-action-resolve reference))
         (node (supertag-node-get node-id)))
    (unless node (error "Action subject node %s does not exist" node-id))
    (unless (supertag-ontology-function-node-satisfies-type-p
             node-id (plist-get definition :subject-type-id))
      (error "Node %s does not satisfy Action subject Type %s"
             node-id (plist-get definition :subject-type-id)))
    (let ((bound
           (supertag-ontology-contract-bind-arguments
            (plist-get definition :parameters) arguments
            #'supertag-ontology-function-node-satisfies-type-p))
          effects)
      (supertag-ontology-action--check-preconditions definition node-id bound)
      (dolist (effect (plist-get definition :effects))
        (push (pcase (plist-get effect :kind)
                ((or :set-field :clear-field)
                 (supertag-ontology-action--plan-field
                  definition effect node-id bound))
                ((or :add-link :remove-link)
                 (supertag-ontology-action--plan-link
                  definition effect node-id bound))
                (_ (error "Unsupported Action effect %S" effect)))
              effects))
      (list :action definition :node-id node-id :bound bound
            :effects (nreverse effects)
            :planned-at (float-time)))))

(defun supertag-ontology-action-preview
    (reference node-id &optional arguments)
  "Build a complete read-only plan for Action REFERENCE."
  (when supertag--transaction-active
    (error "Ontology Action preview cannot run inside an active transaction"))
  (supertag-ontology-action--plan reference node-id arguments))

(defun supertag-ontology-action-propose
    (reference node-id &optional arguments actor)
  "Return a transient Policy-aware proposal for Action REFERENCE.

A `:deny' decision rejects proposal creation.  `:propose-only', `:confirm', and
`:allow' may all inspect a proposal; this function never mutates the Store and
never grants execution authority."
  (let* ((actor-record (supertag-ontology-policy-normalize-actor actor))
         (definition (supertag-ontology-action-resolve reference))
         (decision (supertag-ontology-policy-evaluate definition actor-record)))
    (when (eq (plist-get decision :decision) :deny)
      (signal 'supertag-ontology-policy-denied
              (list (format "Ontology Policy denied proposal for %s"
                            (plist-get definition :label)))))
    (let ((plan (supertag-ontology-action-preview
                 (plist-get definition :runtime-id) node-id arguments)))
      (list :proposal-id
            (secure-hash
             'sha256
             (prin1-to-string
              (list (plist-get definition :contract-hash)
                    node-id
                    (plist-get (plist-get plan :bound) :alist)
                    (plist-get decision :actor)
                    (float-time))))
            :action (supertag-ontology-contract-copy definition)
            :node-id node-id
            :arguments
            (supertag-ontology-contract-copy
             (plist-get (plist-get plan :bound) :redacted))
            :effects
            (mapcar #'supertag-ontology-action--audit-effect
                    (plist-get plan :effects))
            :policy (supertag-ontology-contract-copy decision)
            :proposed-at (float-time)))))

(defun supertag-ontology-action--execution-id (plan)
  "Return unique audit identity for PLAN."
  (format "action-execution-%s"
          (substring
           (secure-hash
            'sha256
            (format "%s|%s|%s|%s"
                    (plist-get (plist-get plan :action) :runtime-id)
                    (plist-get plan :node-id) (float-time) (random)))
           0 32)))

(defun supertag-ontology-action--audit-effect (effect)
  "Return bounded audit identity for planned EFFECT.

Field values are deliberately omitted.  The authoritative Field Store already
owns them, and copying them into Action history would create a second sensitive
fact store."
  (pcase (plist-get effect :kind)
    ((or :set-field :clear-field)
     (list :kind (plist-get effect :kind)
           :node-id (plist-get effect :node-id)
           :field-id (plist-get effect :field-id)
           :changed
           (pcase (plist-get effect :kind)
             (:set-field
              (or (not (plist-get effect :old-exists))
                  (not (equal (plist-get effect :old)
                              (plist-get effect :new)))))
             (:clear-field (and (plist-get effect :old-exists) t)))))
    (:add-link
     (append
      (list :kind :add-link
            :definition-id (plist-get effect :definition-id)
            :replaced-relation-ids
            (mapcar (lambda (relation) (plist-get relation :id))
                    (plist-get effect :replace-conflicts)))
      (list :subject-id (plist-get effect :subject-id)
            :direction (plist-get effect :direction)
            :target-id
            (if (plist-get effect :sensitive-target-p)
                :redacted
              (plist-get effect :target-id)))))
    (:remove-link
     (append
      (list :kind :remove-link
            :definition-id (plist-get effect :definition-id)
            :removed-relation-ids
            (mapcar (lambda (relation) (plist-get relation :id))
                    (plist-get effect :relations)))
      (list :subject-id (plist-get effect :subject-id)
            :direction (plist-get effect :direction)
            :target-id
            (if (plist-get effect :sensitive-target-p)
                :redacted
              (plist-get effect :target-id)))))))

(defun supertag-ontology-action--audit-record (plan execution-id authorization)
  "Build durable success audit record for fresh PLAN."
  (let ((definition (plist-get plan :action)))
    (list :id execution-id :status :succeeded
          :action-id (plist-get definition :runtime-id)
          :logical-id (plist-get definition :logical-id)
          :contract-hash (plist-get definition :contract-hash)
          :module (plist-get definition :module)
          :module-version
          (plist-get
           (supertag-store-get-entity
            :ontology-modules (format "%s" (plist-get definition :module)))
           :version)
          :node-id (plist-get plan :node-id)
          :arguments
          (supertag-ontology-contract-copy
           (plist-get (plist-get plan :bound) :redacted))
          :actor (supertag-ontology-contract-copy
                  (plist-get authorization :actor))
          :policy
          (list :decision (plist-get authorization :decision)
                :reason (plist-get authorization :reason)
                :policy-id (plist-get authorization :policy-id)
                :policy-logical-id
                (plist-get authorization :policy-logical-id)
                :policy-contract-hash
                (plist-get authorization :policy-contract-hash)
                :confirmation
                (supertag-ontology-contract-copy
                 (plist-get authorization :confirmation)))
          :effects (mapcar #'supertag-ontology-action--audit-effect
                           (plist-get plan :effects))
          :executed-at (float-time))))

(defun supertag-ontology-action--apply-effect (definition effect)
  "Apply one already validated EFFECT using the canonical Ops APIs."
  (pcase (plist-get effect :kind)
    (:set-field
     (supertag-field-set
      (plist-get effect :node-id)
      (plist-get definition :subject-type-id)
      (plist-get effect :field-id)
      (supertag-ontology-contract-copy (plist-get effect :new))))
    (:clear-field
     (when (plist-get effect :old-exists)
       (supertag-field-remove
        (plist-get effect :node-id)
        (plist-get definition :subject-type-id)
        (plist-get effect :field-id))))
    (:add-link
     (unless (plist-get effect :existing)
       (dolist (relation (plist-get effect :replace-conflicts))
         (supertag-relation-delete (plist-get relation :id)))
       (supertag-link-create
        (plist-get effect :definition-id)
        (plist-get effect :from) (plist-get effect :to))))
    (:remove-link
     (dolist (relation (plist-get effect :relations))
       (supertag-relation-delete (plist-get relation :id))))
    (_ (error "Unsupported planned Action effect %S" effect))))

(defun supertag-ontology-action--affected (plan)
  "Return bounded affected-collection data for PLAN."
  (let ((field-count
         (cl-count-if (lambda (effect)
                        (memq (plist-get effect :kind)
                              '(:set-field :clear-field)))
                      (plist-get plan :effects)))
        (link-count
         (cl-count-if (lambda (effect)
                        (memq (plist-get effect :kind)
                              '(:add-link :remove-link)))
                      (plist-get plan :effects))))
    (delq nil
          (list (and (> field-count 0)
                     (list :collection :field-values :count field-count))
                (and (> link-count 0)
                     (list :collection :relations :count link-count))
                (list :collection :ontology-action-executions :count 1)))))

(defun supertag-ontology-action--run-post-commit-hooks (record)
  "Run Action hooks for committed RECORD, isolating every failure."
  (setq supertag-ontology-action-hook-errors nil)
  (run-hook-wrapped
   'supertag-ontology-action-executed-hook
   (lambda (callback)
     (condition-case err
         (funcall callback (supertag-ontology-contract-copy record))
       (error
        (let ((failure
               (list :execution-id (plist-get record :id)
                     :hook callback
                     :error (error-message-string err))))
          (push failure supertag-ontology-action-hook-errors)
          (message "[supertag] Ontology Action hook failed: %s"
                   (plist-get failure :error)))))
     nil)))

(defun supertag-ontology-action-execute
    (reference node-id &optional arguments actor confirmation-token)
  "Execute Action REFERENCE for NODE-ID with ARGUMENTS as explicit ACTOR.

`:deny' rejects before Function preconditions.  `:propose-only' can use
`supertag-ontology-action-propose' but cannot execute.  `:confirm' requires a
fresh one-use CONFIRMATION-TOKEN issued by the trusted interactive boundary.
The Action re-resolves Policy, preconditions, and effects inside one outer
Canonical Change transaction."
  (when supertag--transaction-active
    (error "Ontology Action must own the outer transaction"))
  (let* ((definition (supertag-ontology-action-resolve reference))
         (actor-record (supertag-ontology-policy-normalize-actor actor))
         (initial-decision
          (supertag-ontology-policy-evaluate definition actor-record)))
    ;; Fail before expensive Function preconditions when no execution path exists.
    (pcase (plist-get initial-decision :decision)
      (:deny
       (signal 'supertag-ontology-policy-denied
               (list (format "Ontology Policy denied Action %s (%s)"
                             (plist-get definition :label)
                             (plist-get initial-decision :reason)))))
      (:propose-only
       (signal 'supertag-ontology-policy-propose-only
               (list (format "Actor %s may propose but not execute Action %s"
                             (plist-get actor-record :kind)
                             (plist-get definition :label))))))
    (let* ((initial-plan
            (supertag-ontology-action-preview
             (plist-get definition :runtime-id) node-id arguments))
           (reservation
            (when (eq (plist-get initial-decision :decision) :confirm)
              (supertag-ontology-policy-reserve-confirmation
               initial-plan initial-decision confirmation-token)))
           (execution-id (supertag-ontology-action--execution-id initial-plan))
           (envelope
            (list :authority :semantic :scope :fact
                  :operation :ontology-action-executed
                  :subject (list :kind :ontology-action
                                 :id (plist-get definition :runtime-id)
                                 :node-id node-id)
                  :cardinality :single
                  :affected (supertag-ontology-action--affected initial-plan)
                  :metadata (list :execution-id execution-id
                                  :contract-hash
                                  (plist-get definition :contract-hash)
                                  :actor-kind
                                  (plist-get actor-record :kind))))
           (supertag-ops-defer-events t)
           (supertag-ops-deferred-events nil)
           (supertag-automation-sync--enabled nil)
           record committed)
      (condition-case err
          (progn
            (setq record
                  (supertag-change-commit
                   envelope
                   (lambda ()
                     ;; Re-read the Store-owned Action and every dependent fact
                     ;; under the outer transaction.  The UI preview is never the
                     ;; final business authorization.
                     (let* ((fresh-plan
                             (supertag-ontology-action--plan
                              (plist-get definition :runtime-id)
                              node-id arguments))
                            (authorization
                             (supertag-ontology-policy-authorize
                              fresh-plan actor-record reservation))
                            (fresh-definition (plist-get fresh-plan :action))
                            (audit
                             (supertag-ontology-action--audit-record
                              fresh-plan execution-id authorization)))
                       (dolist (effect (plist-get fresh-plan :effects))
                         (supertag-ontology-action--apply-effect
                          fresh-definition effect))
                       (supertag-store-put-entity
                        :ontology-action-executions execution-id audit t)
                       audit))))
            (setq committed t))
        (error
         (when reservation
           (supertag-ontology-policy-restore-confirmation reservation))
         (signal (car err) (cdr err))))
      (when committed
        ;; Ops-level notifications are visible only after the complete Action.
        (supertag-ops-flush-deferred-events
         (nreverse supertag-ops-deferred-events))
        (supertag-ontology-action--run-post-commit-hooks record))
      (supertag-ontology-contract-copy record))))

(defun supertag-ontology-action-applicable (node-id)
  "Return Actions whose subject Type accepts NODE-ID.
Preconditions are intentionally not executed here."
  (cl-remove-if-not
   (lambda (definition)
     (supertag-ontology-function-node-satisfies-type-p
      node-id (plist-get definition :subject-type-id)))
   (supertag-ontology-action-list)))

(provide 'supertag-ontology-action)
;;; supertag-ontology-action.el ends here
