;;; supertag-ontology-policy.el --- Fail-closed Ontology Action policy -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Policy is the authorization layer in front of Ontology Action.  Action
;; preconditions answer whether the current world makes an operation valid.
;; Policy answers whether one actor may invoke that valid operation and whether
;; human confirmation is required.  Policy is data only: no arbitrary callback
;; or expression is evaluated here.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-ontology-contract)

(define-error 'supertag-ontology-policy-error
  "Ontology Policy authorization failed")
(define-error 'supertag-ontology-policy-denied
  "Ontology Policy denied Action" 'supertag-ontology-policy-error)
(define-error 'supertag-ontology-policy-propose-only
  "Ontology Policy permits proposal only" 'supertag-ontology-policy-error)
(define-error 'supertag-ontology-policy-confirmation-required
  "Ontology Policy requires confirmation" 'supertag-ontology-policy-error)

(defconst supertag-ontology-policy-actor-kinds
  '(:interactive-user :automation :llm :external)
  "Actor classes every deployed Policy must cover exactly once.")

(defconst supertag-ontology-policy-decisions
  '(:allow :deny :confirm :propose-only)
  "Closed set of Policy decisions.")

(defcustom supertag-ontology-policy-confirmation-ttl 300
  "Maximum lifetime in seconds for a one-use confirmation token."
  :type 'integer
  :group 'supertag)

(defvar supertag-ontology-policy--confirmation-tokens
  (make-hash-table :test #'equal)
  "Private runtime table of unconsumed confirmation capabilities.")

(defun supertag-ontology-policy-list ()
  "Return deployed Policies in stable logical identity order."
  (let (records)
    (maphash
     (lambda (_id record)
       (push (supertag-ontology-contract-copy record) records))
     (supertag-store-get-collection :ontology-policies))
    (sort records
          (lambda (left right)
            (string< (or (plist-get left :logical-id) "")
                     (or (plist-get right :logical-id) ""))))))

(defun supertag-ontology-policy-resolve (reference &optional noerror)
  "Resolve Policy REFERENCE by runtime ID, logical ID, module/key, key or label."
  (let* ((records (supertag-ontology-policy-list))
         (text (cond ((symbolp reference) (symbol-name reference))
                     ((stringp reference) reference)))
         (exact (and text
                     (supertag-store-get-entity :ontology-policies text)))
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
      (error "Ambiguous Ontology Policy reference %S" reference))
     ((not noerror) (error "Unknown Ontology Policy %S" reference)))))

(defun supertag-ontology-policy--normalize-actor-kind (kind)
  "Return canonical actor KIND, accepting the v11 `:user' compatibility alias."
  (pcase kind
    ((or 'user :user 'interactive-user :interactive-user)
     :interactive-user)
    ((or 'automation :automation) :automation)
    ((or 'llm :llm) :llm)
    ((or 'external :external) :external)
    (_ kind)))

(defun supertag-ontology-policy-normalize-actor (actor)
  "Return canonical actor plist for ACTOR or signal.

ACTOR may be one supported keyword/symbol or a plist containing `:kind' and an
optional stable string `:id'.  Additional caller metadata is deliberately not
copied into authorization or audit records."
  (let* ((record
          (cond
           ((or (keywordp actor) (symbolp actor)) (list :kind actor))
           ((and (proper-list-p actor) (plist-member actor :kind))
            actor)
           (t (error "Invalid Ontology Policy actor %S" actor))))
         (kind (supertag-ontology-policy--normalize-actor-kind
                (plist-get record :kind)))
         (id (plist-get record :id)))
    (unless (memq kind supertag-ontology-policy-actor-kinds)
      (error "Unsupported Ontology Policy actor kind %S" kind))
    (when (and (plist-member record :id) (not (stringp id)))
      (error "Ontology Policy actor :id must be a string"))
    (if id (list :kind kind :id id) (list :kind kind))))

(defun supertag-ontology-policy--for-action (action-id)
  "Return deployed Policies governing ACTION-ID."
  (cl-remove-if-not
   (lambda (policy) (equal action-id (plist-get policy :action-id)))
   (supertag-ontology-policy-list)))

(defun supertag-ontology-policy--rules (policy actor-kind)
  "Return POLICY rules matching ACTOR-KIND."
  (cl-remove-if-not
   (lambda (rule)
     (and (proper-list-p rule)
          (eq actor-kind
              (supertag-ontology-policy--normalize-actor-kind
               (plist-get rule :actor)))))
   (and (proper-list-p (plist-get policy :actors))
        (plist-get policy :actors))))

(defun supertag-ontology-policy--confirmation-floor
    (action actor-kind decision)
  "Apply ACTION's minimum confirmation floor to DECISION.

A floor may strengthen only `:allow' to `:confirm'.  It never weakens `:deny',
`:confirm', or `:propose-only'."
  (let ((mode (or (plist-get action :confirmation) :never)))
    (if (and (eq decision :allow)
             (or (eq mode :always)
                 (and (eq mode :llm) (eq actor-kind :llm))
                 (and (eq mode :external) (eq actor-kind :external))))
        :confirm
      decision)))

(defun supertag-ontology-policy-evaluate (action actor)
  "Return a fail-closed Policy decision for deployed ACTION and ACTOR.

This function reads contracts only.  It never runs Function preconditions,
changes the Store, prompts, or contacts external systems."
  (let* ((actor-record (supertag-ontology-policy-normalize-actor actor))
         (actor-kind (plist-get actor-record :kind))
         (action-id (plist-get action :runtime-id))
         (policies (and (stringp action-id)
                        (supertag-ontology-policy--for-action action-id)))
         policy rules rule declared decision reason)
    (cond
     ((not (and (stringp action-id)
                (stringp (plist-get action :contract-hash))))
      (setq decision :deny reason :invalid-action-contract))
     ((null policies)
      (setq decision :deny reason :missing-policy))
     ((cdr policies)
      (setq decision :deny reason :ambiguous-policy))
     (t
      (setq policy (car policies))
      (cond
       ((not (stringp (plist-get policy :contract-hash)))
        (setq decision :deny reason :invalid-policy-contract))
       (t
        (setq rules (supertag-ontology-policy--rules policy actor-kind))
        (cond
         ((null rules)
          (setq decision :deny reason :missing-actor-rule))
         ((cdr rules)
          (setq decision :deny reason :ambiguous-actor-rule))
         (t
          (setq rule (car rules)
                declared (plist-get rule :decision))
          (if (not (memq declared supertag-ontology-policy-decisions))
              (setq decision :deny reason :invalid-policy-decision)
            (setq decision
                  (supertag-ontology-policy--confirmation-floor
                   action actor-kind declared)
                  reason (or (plist-get rule :reason)
                             :declared-policy)))))))))
    (list :decision decision
          :reason reason
          :actor actor-record
          :action-id action-id
          :action-contract-hash (plist-get action :contract-hash)
          :policy-id (and policy (plist-get policy :runtime-id))
          :policy-logical-id (and policy (plist-get policy :logical-id))
          :policy-contract-hash (and policy
                                     (plist-get policy :contract-hash)))))

(defun supertag-ontology-policy--fingerprint (plan decision)
  "Return stable authorization fingerprint for Action PLAN and DECISION."
  (let ((action (plist-get plan :action)))
    (secure-hash
     'sha256
     (prin1-to-string
      (list :action-id (plist-get action :runtime-id)
            :action-contract-hash (plist-get action :contract-hash)
            :policy-id (plist-get decision :policy-id)
            :policy-contract-hash (plist-get decision :policy-contract-hash)
            :decision (plist-get decision :decision)
            :node-id (plist-get plan :node-id)
            :actor (plist-get decision :actor)
            :arguments
            (supertag-ontology-contract-copy
             (plist-get (plist-get plan :bound) :alist))
            ;; Bind interactive confirmation to the exact read-only proposal.
            ;; A state change that alters old/new Field values, Link conflicts,
            ;; or target resolution makes the token stale and requires a fresh
            ;; preview instead of silently executing a different transition.
            :effects
            (supertag-ontology-contract-copy
             (plist-get plan :effects)))))))

(defun supertag-ontology-policy--new-token ()
  "Return an opaque random confirmation token."
  (secure-hash
   'sha256
   (format "%s|%s|%s|%s" (float-time) (random) (emacs-pid)
           (make-temp-name "supertag-policy-"))))

(defun supertag-ontology-policy--prune-confirmations ()
  "Remove expired confirmation capabilities from runtime memory."
  (let ((now (float-time)) expired)
    (maphash
     (lambda (token record)
       (when (< (or (plist-get record :expires-at) 0) now)
         (push token expired)))
     supertag-ontology-policy--confirmation-tokens)
    (dolist (token expired)
      (remhash token supertag-ontology-policy--confirmation-tokens))))

(defun supertag-ontology-policy-request-confirmation (plan actor)
  "Interactively confirm Action PLAN for ACTOR and return a one-use token.

The token is held only in memory and is bound to the Action contract, Policy
contract, subject, normalized actor, and normalized arguments."
  (let* ((decision
          (supertag-ontology-policy-evaluate (plist-get plan :action) actor))
         (label (plist-get (plist-get plan :action) :label)))
    (supertag-ontology-policy--prune-confirmations)
    (unless (eq (plist-get decision :decision) :confirm)
      (user-error "Action %s does not have a confirm decision" label))
    (unless (yes-or-no-p
             (format "Authorize Action %s once for %s? "
                     label (plist-get (plist-get decision :actor) :kind)))
      (user-error "Ontology Action confirmation declined"))
    (let* ((token (supertag-ontology-policy--new-token))
           (now (float-time))
           (record
            (list :fingerprint
                  (supertag-ontology-policy--fingerprint plan decision)
                  :expires-at (+ now supertag-ontology-policy-confirmation-ttl)
                  :confirmed-at now
                  :confirmed-by :interactive-user)))
      (puthash token record supertag-ontology-policy--confirmation-tokens)
      token)))

(defun supertag-ontology-policy-reserve-confirmation
    (plan decision token)
  "Reserve one-use TOKEN for PLAN and DECISION.

Reservation removes TOKEN before the Action transaction.  Call
`supertag-ontology-policy-restore-confirmation' when execution fails before
commit.  The returned record contains the opaque token only in runtime memory."
  (supertag-ontology-policy--prune-confirmations)
  (let ((record (and (stringp token)
                     (gethash token
                              supertag-ontology-policy--confirmation-tokens))))
    (unless record
      (signal 'supertag-ontology-policy-confirmation-required
              (list "Ontology Action requires a valid confirmation token")))
    (unless (equal (plist-get record :fingerprint)
                   (supertag-ontology-policy--fingerprint plan decision))
      (signal 'supertag-ontology-policy-confirmation-required
              (list "Ontology Action confirmation is stale or mismatched")))
    (remhash token supertag-ontology-policy--confirmation-tokens)
    (list :token token :record record)))

(defun supertag-ontology-policy-restore-confirmation (reservation)
  "Restore unexpired confirmation RESERVATION after a failed Action."
  (when-let* ((token (plist-get reservation :token))
              (record (plist-get reservation :record)))
    (when (> (or (plist-get record :expires-at) 0) (float-time))
      (puthash token record supertag-ontology-policy--confirmation-tokens))))

(defun supertag-ontology-policy--validate-reservation
    (plan decision reservation)
  "Validate confirmation RESERVATION against fresh PLAN and DECISION."
  (let ((record (plist-get reservation :record)))
    (unless record
      (signal 'supertag-ontology-policy-confirmation-required
              (list "Ontology Action confirmation is missing")))
    (when (< (or (plist-get record :expires-at) 0) (float-time))
      (signal 'supertag-ontology-policy-confirmation-required
              (list "Ontology Action confirmation token has expired")))
    (unless (equal (plist-get record :fingerprint)
                   (supertag-ontology-policy--fingerprint plan decision))
      (signal 'supertag-ontology-policy-confirmation-required
              (list "Ontology Action confirmation became stale")))
    (list :required t
          :confirmed-at (plist-get record :confirmed-at)
          :confirmed-by (plist-get record :confirmed-by))))

(defun supertag-ontology-policy-authorize
    (plan actor &optional confirmation-reservation)
  "Authorize fresh Action PLAN for ACTOR.

CONFIRMATION-RESERVATION is required only for an effective `:confirm' decision.
`:propose-only' deliberately cannot be elevated by a confirmation token; the
same actor may preview/propose, but another actor with an executable decision
must invoke the Action."
  (let* ((decision
          (supertag-ontology-policy-evaluate (plist-get plan :action) actor))
         (outcome (plist-get decision :decision))
         confirmation)
    (pcase outcome
      (:deny
       (signal 'supertag-ontology-policy-denied
               (list (format "Ontology Policy denied Action %s (%s)"
                             (plist-get (plist-get plan :action) :label)
                             (plist-get decision :reason)))))
      (:propose-only
       (signal 'supertag-ontology-policy-propose-only
               (list (format "Actor %s may propose but not execute Action %s"
                             (plist-get (plist-get decision :actor) :kind)
                             (plist-get (plist-get plan :action) :label)))))
      (:confirm
       (setq confirmation
             (supertag-ontology-policy--validate-reservation
              plan decision confirmation-reservation)))
      (:allow
       (setq confirmation '(:required nil)))
      (_
       (signal 'supertag-ontology-policy-denied
               (list (format "Invalid Policy decision %S" outcome)))))
    (plist-put (supertag-ontology-contract-copy decision)
               :confirmation confirmation)))

(provide 'supertag-ontology-policy)
;;; supertag-ontology-policy.el ends here
