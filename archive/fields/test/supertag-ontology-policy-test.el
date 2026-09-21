;;; supertag-ontology-policy-test.el --- Ontology Policy focused tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'supertag-ontology-action-test)
(require 'supertag-ui-action)
(require 'supertag-view-node)

(defun supertag-v11-test-issue-code-p (code issues)
  "Return non-nil when ISSUES contain CODE."
  (cl-find code issues :key (lambda (issue) (plist-get issue :code))))

(defun supertag-v11-test-policy-model (&optional actors)
  "Return a minimal model using ACTORS for one Action Policy."
  (supertag-ontology-model-normalize
   'work
   `(:version 11
     (field status :type options :options (active done))
     (type project :fields (status))
     (action complete :subject project
             :effects ((set-field status :value "done")))
     (policy complete-access :action complete
             :actors ,(or actors
                          '((interactive-user allow)
                            (automation deny)
                            (llm propose-only)
                            (external deny)))))
   '(:file "policy.el" :line 1)))

(ert-deftest supertag-v11-policy-normalizes-closed-actor-map-and-propose-only ()
  (let* ((model (supertag-v11-test-policy-model
                 '((user allow) (automation deny)
                   (llm propose) (external deny))))
         (policy (car (plist-get model :policies))))
    (should (equal '(:automation :external :interactive-user :llm)
                   (mapcar (lambda (rule) (plist-get rule :actor))
                           (plist-get policy :actors))))
    (should (eq :propose-only
                (plist-get
                 (cl-find :llm (plist-get policy :actors)
                          :key (lambda (rule) (plist-get rule :actor)))
                 :decision)))))

(ert-deftest supertag-v11-validator-requires-complete-actor-coverage ()
  (let ((issues
         (supertag-ontology-validator-validate
          (supertag-v11-test-policy-model
           '((interactive-user allow) (automation deny)
             (llm propose-only))))))
    (should (supertag-v11-test-issue-code-p
             :missing-policy-actor issues))))

(ert-deftest supertag-v11-validator-requires-one-policy-per-action ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 11
             (field status :type text)
             (type project :fields (status))
             (action complete :subject project
                     :effects ((set-field status :value "done")))) nil))
         (issues (supertag-ontology-validator-validate model)))
    (should (supertag-v11-test-issue-code-p
             :missing-action-policy issues))))

(ert-deftest supertag-v11-validator-rejects-two-policies-for-one-action ()
  (let* ((model (supertag-v11-test-policy-model))
         (duplicate (copy-tree (car (plist-get model :policies)))))
    (setq duplicate (plist-put duplicate :key 'other-access))
    (setq duplicate (plist-put duplicate :logical-id
                               "work/policy/other-access"))
    (setq model
          (plist-put model :policies
                     (append (plist-get model :policies)
                             (list duplicate))))
    (should (supertag-v11-test-issue-code-p
             :duplicate-action-policy
             (supertag-ontology-validator-validate model)))))

(ert-deftest supertag-v11-policy-deployment-is-behavioral-and-idempotent ()
  (supertag-v10-test-with-store
    (let* ((model (supertag-v11-test-policy-model))
           (plan (supertag-ontology-plan-build model)))
      (should-not (supertag-ontology-plan-errors-p plan))
      (should (supertag-ontology-plan-behavioral-p plan))
      (should-error (supertag-ontology-deploy-apply-plan plan))
      (supertag-ontology-deploy-apply-plan plan t)
      (let ((policy (car (supertag-ontology-policy-list))))
        (should (equal "ontology-action-"
                       (substring (plist-get policy :action-id) 0 16)))
        (should (supertag-ontology-runtime-binding-get
                 'work :policy 'complete-access)))
      (should (supertag-ontology-plan-empty-p
               (supertag-ontology-plan-build model))))))

(ert-deftest supertag-v11-policy-update-needs-explicit-behavioral-approval ()
  (supertag-v10-test-with-store
    (let* ((first-model (supertag-v11-test-policy-model))
           (first-plan (supertag-ontology-plan-build first-model)))
      (supertag-ontology-deploy-apply-plan first-plan t)
      (let* ((before (car (supertag-ontology-policy-list)))
             (runtime-id (plist-get before :runtime-id))
             (before-hash (plist-get before :contract-hash))
             (second-model
              (supertag-v11-test-policy-model
               '((interactive-user allow) (automation deny)
                 (llm allow) (external deny))))
             (second-plan (supertag-ontology-plan-build second-model)))
        (should (supertag-ontology-plan-behavioral-p second-plan))
        (should-error (supertag-ontology-deploy-apply-plan second-plan))
        (supertag-ontology-deploy-apply-plan second-plan t)
        (let ((after (supertag-ontology-policy-resolve runtime-id)))
          (should-not (equal before-hash (plist-get after :contract-hash)))
          (should (eq :allow
                      (plist-get
                       (supertag-ontology-policy-evaluate
                        (supertag-ontology-action-resolve 'complete) :llm)
                       :decision))))))))

(ert-deftest supertag-v11-policy-fails-closed-without-or-with-ambiguous-definition ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (remhash "complete-policy"
             (supertag-store-get-collection :ontology-policies))
    (should (eq :deny
                (plist-get
                 (supertag-ontology-policy-evaluate
                  (supertag-ontology-action-resolve "complete")
                  :interactive-user)
                 :decision)))
    (should-error
     (supertag-ontology-action-execute
      "complete" "project-1" nil :interactive-user))
    (supertag-v10-test-install-status-action)
    (let ((duplicate
           (copy-tree
            (supertag-store-get-entity
             :ontology-policies "complete-policy"))))
      (setq duplicate (plist-put duplicate :id "other-policy"))
      (setq duplicate (plist-put duplicate :runtime-id "other-policy"))
      (supertag-store-put-entity
       :ontology-policies "other-policy" duplicate))
    (should (eq :deny
                (plist-get
                 (supertag-ontology-policy-evaluate
                  (supertag-ontology-action-resolve "complete")
                  :interactive-user)
                 :decision)))))

(ert-deftest supertag-v11-policy-requires-explicit-supported-actor ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (should-error
     (supertag-ontology-action-execute "complete" "project-1"))
    (should-error
     (supertag-ontology-action-propose "complete" "project-1" nil nil))
    (should-error
     (supertag-ontology-action-execute
      "complete" "project-1" nil :unknown))))

(ert-deftest supertag-v11-deny-runs-before-function-preconditions ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (cl-letf (((symbol-function 'supertag-ontology-action-preview)
               (lambda (&rest _) (error "preview must not run"))))
      (should-error
       (supertag-ontology-action-execute
        "complete" "project-1" nil :automation)
       :type 'supertag-ontology-policy-denied))))

(ert-deftest supertag-v11-propose-only-can-preview-but-cannot-execute ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (let ((proposal
           (supertag-ontology-action-propose
            "complete" "project-1" nil :llm)))
      (should (eq :propose-only
                  (plist-get (plist-get proposal :policy) :decision)))
      (should (equal "active"
                     (supertag-store-get-field-value
                      "project-1" "status")))
      (should (= 0 (hash-table-count
                    (supertag-store-get-collection
                     :ontology-action-executions)))))
    (should-error
     (supertag-ontology-action-execute
      "complete" "project-1" nil :llm)
     :type 'supertag-ontology-policy-propose-only)))

(ert-deftest supertag-v11-confirmation-cannot-elevate-propose-only ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (let* ((plan (supertag-ontology-action-preview
                  "complete" "project-1"))
           (decision
            (supertag-ontology-policy-evaluate
             (supertag-ontology-action-resolve "complete") :llm)))
      (should-error
       (supertag-ontology-policy-request-confirmation plan :llm))
      (should-error
       (supertag-ontology-policy-authorize
        plan :llm '(:token "invented"))
       :type 'supertag-ontology-policy-propose-only)
      (should (eq :propose-only (plist-get decision :decision))))))

(ert-deftest supertag-v11-allow-commits-canonical-actor-and-policy-audit ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (let* ((record
            (supertag-ontology-action-execute
             "complete" "project-1" nil
             '(:kind :user :id "person-1")))
           (policy (plist-get record :policy)))
      (should (equal '(:kind :interactive-user :id "person-1")
                     (plist-get record :actor)))
      (should (eq :allow (plist-get policy :decision)))
      (should (equal "policy-contract-1"
                     (plist-get policy :policy-contract-hash)))
      (should-not
       (plist-get (plist-get policy :confirmation) :required)))))

(ert-deftest supertag-v11-action-confirmation-floor-can-only-strengthen-allow ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action nil
     '((:actor :automation :decision :deny)
       (:actor :external :decision :deny)
       (:actor :interactive-user :decision :allow)
       (:actor :llm :decision :allow)))
    (let ((action (supertag-store-get-entity
                   :ontology-actions "complete")))
      (supertag-store-put-entity
       :ontology-actions "complete"
       (plist-put action :confirmation :llm)))
    (should (eq :confirm
                (plist-get
                 (supertag-ontology-policy-evaluate
                  (supertag-ontology-action-resolve "complete") :llm)
                 :decision)))
    (should (eq :allow
                (plist-get
                 (supertag-ontology-policy-evaluate
                  (supertag-ontology-action-resolve "complete")
                  :interactive-user)
                 :decision)))))

(ert-deftest supertag-v11-confirmation-token-is-one-use-and-state-bound ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action nil
     '((:actor :automation :decision :deny)
       (:actor :external :decision :deny)
       (:actor :interactive-user :decision :confirm)
       (:actor :llm :decision :propose-only)))
    (let* ((plan (supertag-ontology-action-preview
                  "complete" "project-1"))
           (token
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) t)))
              (supertag-ontology-policy-request-confirmation
               plan :interactive-user))))
      ;; A changed Field old value changes the exact proposed effect fingerprint.
      (supertag-store-put-field-value "project-1" "status" "blocked")
      (should-error
       (supertag-ontology-action-execute
        "complete" "project-1" nil :interactive-user token)
       :type 'supertag-ontology-policy-confirmation-required)
      ;; Failed stale use restores the reserved token only when it had first
      ;; matched the initial plan; here reserve itself failed, so request fresh.
      (let* ((fresh-plan (supertag-ontology-action-preview
                          "complete" "project-1"))
             (fresh-token
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (&rest _) t)))
                (supertag-ontology-policy-request-confirmation
                 fresh-plan :interactive-user))))
        (should (eq :succeeded
                    (plist-get
                     (supertag-ontology-action-execute
                      "complete" "project-1" nil
                      :interactive-user fresh-token)
                     :status)))
        (should-error
         (supertag-ontology-action-execute
          "complete" "project-1" nil
          :interactive-user fresh-token)
         :type 'supertag-ontology-policy-confirmation-required)))))

(ert-deftest supertag-v11-confirmation-token-is-policy-contract-bound ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action nil
     '((:actor :automation :decision :deny)
       (:actor :external :decision :deny)
       (:actor :interactive-user :decision :confirm)
       (:actor :llm :decision :propose-only)))
    (let* ((plan (supertag-ontology-action-preview
                  "complete" "project-1"))
           (token
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) t)))
              (supertag-ontology-policy-request-confirmation
               plan :interactive-user)))
           (policy (supertag-store-get-entity
                    :ontology-policies "complete-policy")))
      (supertag-store-put-entity
       :ontology-policies "complete-policy"
       (plist-put policy :contract-hash "policy-contract-2"))
      (should-error
       (supertag-ontology-action-execute
        "complete" "project-1" nil :interactive-user token)
       :type 'supertag-ontology-policy-confirmation-required)
      (should (equal "active"
                     (supertag-store-get-field-value
                      "project-1" "status"))))))

(ert-deftest supertag-v11-node-view-capability-renderers-are-retired ()
  (should-not (fboundp 'supertag-view-node--insert-action-row))
  (should-not
   (fboundp 'supertag-view-node--insert-ontology-capabilities-section))
  (should-not (lookup-key supertag-view-node-mode-map (kbd "A")))
  (should-not
   (string-match-p "Run or propose an Ontology Action"
                   (documentation 'supertag-view-node-mode))))

(provide 'supertag-ontology-policy-test)
;;; supertag-ontology-policy-test.el ends here
