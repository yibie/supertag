;;; supertag-ontology-tool-test.el --- Ontology LLM Tool v12 tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'supertag-ontology-policy-test)
(require 'supertag-ontology-tool)
(require 'supertag-ui-tool)

(defun supertag-v12-test-function (_node arguments _context)
  "Return first ordered argument, preserving explicit nil."
  (car arguments))

(defun supertag-v12-test-count (_node arguments _context)
  "Return COUNT argument or zero."
  (or (car arguments) 0))

(defun supertag-v12-test-install-function
    (id &optional exposed parameters returns implementation)
  "Install deployed Function ID for tool tests."
  (supertag-store-put-entity
   :ontology-functions id
   (list :id id :runtime-id id
         :logical-id (format "work/function/%s" id)
         :module 'work :key (intern id)
         :label (capitalize id)
         :description (format "Tool test Function %s" id)
         :subject-type-id "project"
         :parameters (or parameters nil)
         :returns (or returns :integer)
         :implementation (or implementation 'supertag-v12-test-count)
         :llm-tool (and exposed t)
         :tool-name nil :tool-description nil
         :contract-hash (format "contract-%s" id))))

(defun supertag-v12-test-install-action (id decision &optional exposed)
  "Install deployed status Action ID governed by LLM DECISION."
  (supertag-store-put-entity
   :ontology-actions id
   (list :id id :runtime-id id
         :logical-id (format "work/action/%s" id)
         :module 'work :key (intern id)
         :label (capitalize id)
         :description (format "Tool test Action %s" id)
         :subject-type-id "project"
         :parameters nil :preconditions nil
         :effects '((:kind :set-field :field "status" :value "done"))
         :confirmation :never
         :llm-tool (and exposed t)
         :tool-name nil :tool-description nil
         :contract-hash (format "contract-%s" id)))
  (supertag-store-put-entity
   :ontology-policies (concat id "-policy")
   (list :id (concat id "-policy")
         :runtime-id (concat id "-policy")
         :logical-id (format "work/policy/%s-access" id)
         :module 'work :key (intern (concat id "-access"))
         :label (concat (capitalize id) " Access")
         :action-id id
         :contract-hash (format "policy-contract-%s" id)
         :actors
         `((:actor :automation :decision :deny)
           (:actor :external :decision :deny)
           (:actor :interactive-user :decision :allow)
           (:actor :llm :decision ,decision)))))

(defun supertag-v12-test-tool-by-kind (kind tools)
  "Return first tool of KIND from TOOLS."
  (cl-find kind tools :key (lambda (tool) (plist-get tool :kind))))

(defun supertag-v12-test-json-object-get (object key)
  "Return string KEY from JSON alist OBJECT."
  (cdr (assoc key object)))

(ert-deftest supertag-v12-model-normalizes-explicit-tool-metadata ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 12
             (type project)
             (function count :subject project :returns integer
                       :implementation supertag-v12-test-count
                       :llm-tool t :tool-name "project_count"
                       :tool-description "Count project items")
             (action complete :subject project
                     :llm-tool t :tool-name "complete_project"
                     :effects ((set-field missing :value "done")))
             (policy complete-access :action complete
                     :actors ((interactive-user allow) (automation deny)
                              (llm propose-only) (external deny)))) nil))
         (function (car (plist-get model :functions)))
         (action (car (plist-get model :actions))))
    (should (plist-get function :llm-tool))
    (should (equal "project_count" (plist-get function :tool-name)))
    (should (plist-get action :llm-tool))
    (should (equal "complete_project" (plist-get action :tool-name)))))

(ert-deftest supertag-v12-validator-rejects-invalid-and-duplicate-tool-names ()
  (let* ((model
          (supertag-ontology-model-normalize
           'work
           '(:version 12
             (type project)
             (function one :subject project :returns integer
                       :implementation supertag-v12-test-count
                       :llm-tool maybe :tool-name "bad name")
             (function two :subject project :returns integer
                       :implementation supertag-v12-test-count
                       :llm-tool t :tool-name "duplicate")
             (action three :subject project :llm-tool t
                     :tool-name "duplicate"
                     :effects ((set-field missing :value "x")))
             (policy three-access :action three
                     :actors ((interactive-user deny) (automation deny)
                              (llm deny) (external deny)))) nil))
         (issues (supertag-ontology-validator-validate model)))
    (should (supertag-v11-test-issue-code-p :invalid-llm-tool issues))
    (should (supertag-v11-test-issue-code-p :invalid-tool-name issues))
    (should (supertag-v11-test-issue-code-p :duplicate-tool-name issues))))

(ert-deftest supertag-v12-control-plane-deploys-tool-metadata-idempotently ()
  (supertag-v10-test-with-store
    (let* ((model
            (supertag-ontology-model-normalize
             'work
             '(:version 12
               (field status :type options :options (active done))
               (type project :fields (status))
               (function count :subject project :returns integer
                         :implementation supertag-v12-test-count
                         :llm-tool t :tool-name "project_count")
               (action complete :subject project :llm-tool t
                       :tool-name "complete_project"
                       :effects ((set-field status :value "done")))
               (policy complete-access :action complete
                       :actors ((interactive-user allow) (automation deny)
                                (llm propose-only) (external deny)))) nil))
           (plan (supertag-ontology-plan-build model)))
      (should (supertag-ontology-plan-behavioral-p plan))
      (supertag-ontology-deploy-apply-plan plan t)
      (let ((function (car (supertag-ontology-function-list)))
            (action (car (supertag-ontology-action-list))))
        (should (plist-get function :llm-tool))
        (should (equal "project_count" (plist-get function :tool-name)))
        (should (plist-get action :llm-tool))
        (should (equal "complete_project" (plist-get action :tool-name))))
      (should (supertag-ontology-plan-empty-p
               (supertag-ontology-plan-build model))))))

(ert-deftest supertag-v12-catalog-is-opt-in-and-policy-filtered ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (supertag-v12-test-install-function "read" t)
    (supertag-v12-test-install-function "hidden" nil)
    (dolist (pair '(("execute" . :allow)
                    ("confirm" . :confirm)
                    ("proposal" . :propose-only)
                    ("denied" . :deny)))
      (supertag-v12-test-install-action (car pair) (cdr pair) t))
    (let* ((catalog (supertag-ontology-tool-catalog :llm))
           (tools (plist-get catalog :tools))
           (modes (mapcar (lambda (tool)
                            (cons (plist-get tool :kind)
                                  (plist-get tool :mode)))
                          tools)))
      (should (= 4 (length tools)))
      (should (member '(:function . :read) modes))
      (should (member '(:action . :execute) modes))
      (should (member '(:action . :confirm) modes))
      (should (member '(:action . :proposal) modes))
      (should-not
       (cl-find "hidden" tools
                :key (lambda (tool) (plist-get tool :logical-id))
                :test #'string-match-p))
      (should (cl-find :deny (plist-get catalog :omitted)
                       :key (lambda (item) (plist-get item :decision)))))))

(ert-deftest supertag-v12-schema-preserves-contract-and-sensitive-markers ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function
     "schema" t
     (supertag-ontology-contract-normalize-parameters
      '((flag :type boolean :default nil)
        (mode :type options :options (safe fast) :required t)
        (items :type (:list string) :required nil)
        (owner :type (:type project) :required t :sensitive t)))
     :boolean 'supertag-v12-test-function)
    (let* ((tool (car (supertag-ontology-tool-list :llm)))
           (schema (plist-get tool :input-schema))
           (properties (supertag-v12-test-json-object-get schema "properties"))
           (arguments (supertag-v12-test-json-object-get properties "arguments"))
           (argument-properties
            (supertag-v12-test-json-object-get arguments "properties"))
           (owner (supertag-v12-test-json-object-get
                   argument-properties "owner"))
           (mode (supertag-v12-test-json-object-get
                  argument-properties "mode")))
      (should (equal "project"
                     (supertag-v12-test-json-object-get
                      owner "x-supertag-node-type")))
      (should (eq t (supertag-v12-test-json-object-get owner "writeOnly")))
      (should (equal ["safe" "fast"]
                     (supertag-v12-test-json-object-get mode "enum")))
      (should (equal ["mode" "owner"]
                     (supertag-v12-test-json-object-get
                      arguments "required"))))))

(ert-deftest supertag-v12-versioned-name-fails-closed-after-contract-change ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function "count" t)
    (let* ((old-tool (car (supertag-ontology-tool-list :llm)))
           (old-name (plist-get old-tool :name))
           (definition
            (supertag-store-get-entity :ontology-functions "count")))
      (supertag-store-put-entity
       :ontology-functions "count"
       (plist-put definition :contract-hash "contract-count-v2"))
      (let ((new-name (plist-get (car (supertag-ontology-tool-list :llm))
                                 :name)))
        (should-not (equal old-name new-name))
        (should-error (supertag-ontology-tool-resolve old-name :llm)
                      :type 'supertag-ontology-tool-stale)))))

(ert-deftest supertag-v12-optional-only-arguments-object-is-not-required ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function
     "optional" t
     (supertag-ontology-contract-normalize-parameters
      '((flag :type boolean :default nil)))
     :boolean 'supertag-v12-test-function)
    (let* ((tool (car (supertag-ontology-tool-list :llm)))
           (required
            (supertag-v12-test-json-object-get
             (plist-get tool :input-schema) "required")))
      (should (equal ["subject_id"] required)))))

(ert-deftest supertag-v12-any-json-recurses-through-arrays-and-objects ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function
     "any" t
     (supertag-ontology-contract-normalize-parameters
      '((value :type any :required t)))
     :any 'supertag-v12-test-function)
    (let* ((name (plist-get (car (supertag-ontology-tool-list :llm)) :name))
           (result
            (supertag-ontology-tool-invoke-json
             name
             "{\"subject_id\":\"project-1\",\"arguments\":{\"value\":[{\"flag\":false},null]}}"
             nil :llm)))
      ;; Literal substring match: `[' / `]' are regexp metacharacters.
      (should (string-match-p
               (regexp-quote "\"result\":[{\"flag\":false},null]")
               result)))))

(ert-deftest supertag-v12-any-json-preserves-empty-array-versus-null ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function
     "any-empty" t
     (supertag-ontology-contract-normalize-parameters
      '((value :type any :required t)))
     :any 'supertag-v12-test-function)
    (let ((name (plist-get (car (supertag-ontology-tool-list :llm)) :name)))
      (should (string-match-p
               (regexp-quote "\"result\":[]")
               (supertag-ontology-tool-invoke-json
                name
                "{\"subject_id\":\"project-1\",\"arguments\":{\"value\":[]}}"
                nil :llm)))
      (should (string-match-p
               "\"result\":null"
               (supertag-ontology-tool-invoke-json
                name
                "{\"subject_id\":\"project-1\",\"arguments\":{\"value\":null}}"
                nil :llm))))))

(ert-deftest supertag-v12-action-tool-name-fails-closed-after-policy-change ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action
     nil '((:actor :automation :decision :deny)
           (:actor :external :decision :deny)
           (:actor :interactive-user :decision :allow)
           (:actor :llm :decision :allow)))
    (let ((action (supertag-store-get-entity :ontology-actions "complete")))
      (supertag-store-put-entity
       :ontology-actions "complete" (plist-put action :llm-tool t)))
    (let* ((old-tool (car (supertag-ontology-tool-list :llm)))
           (old-name (plist-get old-tool :name))
           (policy
            (supertag-store-get-entity
             :ontology-policies "complete-policy")))
      (supertag-store-put-entity
       :ontology-policies "complete-policy"
       (plist-put policy :contract-hash "policy-contract-2"))
      (let ((new-name
             (plist-get (car (supertag-ontology-tool-list :llm)) :name)))
        (should-not (equal old-name new-name))
        (should-error (supertag-ontology-tool-resolve old-name :llm)
                      :type 'supertag-ontology-tool-stale)))))

(ert-deftest supertag-v12-json-null-and-false-remain-type-distinct ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function
     "strict" t
     (supertag-ontology-contract-normalize-parameters
      '((value :type boolean :required t)))
     :boolean 'supertag-v12-test-function)
    (let ((name (plist-get (car (supertag-ontology-tool-list :llm)) :name)))
      (should-error
       (supertag-ontology-tool-invoke-json
        name
        "{\"subject_id\":\"project-1\",\"arguments\":{\"value\":null}}"
        nil :llm)
       :type 'supertag-ontology-tool-error))
    (remhash "strict" (supertag-store-get-collection :ontology-functions))
    (supertag-v12-test-install-function
     "nullable" t
     (supertag-ontology-contract-normalize-parameters
      '((value :type (:maybe boolean) :required t)))
     ;; Deployed definitions carry canonical contract types (the model
     ;; layer normalizes `:returns'); this helper writes the store directly.
     '(:maybe :boolean) 'supertag-v12-test-function)
    (let* ((name (plist-get (car (supertag-ontology-tool-list :llm)) :name))
           (json
            (supertag-ontology-tool-invoke-json
             name
             "{\"subject_id\":\"project-1\",\"arguments\":{\"value\":null}}"
             nil :llm)))
      (should (string-match-p "\"result\":null" json)))))

(ert-deftest supertag-v12-confirmation-binds-the-same-typed-json-plan ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-store-put-entity
     :field-definitions "flag"
     '(:id "flag" :name "Flag" :type :boolean :required nil))
    (supertag-store-put-entity
     :tag-field-associations "project"
     '((:field-id "flag" :order 0)))
    (supertag-store-put-field-value "project-1" "flag" t)
    (supertag-store-put-entity
     :ontology-actions "set-flag"
     '(:id "set-flag" :runtime-id "set-flag"
       :logical-id "work/action/set-flag" :module work :key set-flag
       :label "Set flag" :subject-type-id "project"
       :parameters ((:name value :index 0 :type :boolean :required t
                     :has-default nil :sensitive nil :options nil))
       :preconditions nil
       :effects ((:kind :set-field :field "flag" :value (:arg value)))
       :confirmation :never :llm-tool t
       :contract-hash "contract-set-flag"))
    (supertag-store-put-entity
     :ontology-policies "set-flag-policy"
     '(:id "set-flag-policy" :runtime-id "set-flag-policy"
       :logical-id "work/policy/set-flag-access" :module work
       :key set-flag-access :label "Set Flag Access"
       :action-id "set-flag" :contract-hash "policy-set-flag"
       :actors ((:actor :automation :decision :deny)
                (:actor :external :decision :deny)
                (:actor :interactive-user :decision :allow)
                (:actor :llm :decision :confirm))))
    (let* ((tool (car (supertag-ontology-tool-list :llm)))
           (name (plist-get tool :name))
           (input
            '(("subject_id" . "project-1")
              ("arguments" . (("value" . :json-false))))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (let ((token
               (supertag-ontology-tool-request-confirmation
                name input :llm)))
          (should (stringp token))
          (should (equal
                   "executed"
                   (supertag-v12-test-json-object-get
                    (supertag-ontology-tool-invoke
                     name input token :llm)
                    "status")))))
      (should-not (supertag-store-get-field-value "project-1" "flag")))))

(ert-deftest supertag-v12-function-tool-invocation-preserves-json-false ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function
     "echo" t
     (supertag-ontology-contract-normalize-parameters
      '((value :type boolean :required t)))
     :boolean 'supertag-v12-test-function)
    (let* ((tool (car (supertag-ontology-tool-list :llm)))
           (result
            (supertag-ontology-tool-invoke
             (plist-get tool :name)
             '(("subject_id" . "project-1")
               ("arguments" . (("value" . nil))))
             nil :llm)))
      (should (equal "ok" (supertag-v12-test-json-object-get result "status")))
      (should (eq :json-false
                  (supertag-v12-test-json-object-get result "result")))
      (should (string-match-p
               "\"result\":false"
               (supertag-ontology-tool-invoke-json
                (plist-get tool :name)
                "{\"subject_id\":\"project-1\",\"arguments\":{\"value\":false}}"
                nil :llm))))))

(ert-deftest supertag-v12-propose-only-tool-never-executes ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action)
    (let ((action (supertag-store-get-entity :ontology-actions "complete")))
      (supertag-store-put-entity
       :ontology-actions "complete" (plist-put action :llm-tool t)))
    (let* ((tool (car (supertag-ontology-tool-list :llm)))
           (result
            (supertag-ontology-tool-invoke
             (plist-get tool :name)
             '(:subject_id "project-1") nil :llm)))
      (should (eq :proposal (plist-get tool :mode)))
      (should (equal "proposal"
                     (supertag-v12-test-json-object-get result "status")))
      (should (equal "active"
                     (supertag-store-get-field-value
                      "project-1" "status")))
      (should-error
       (supertag-ontology-tool-invoke
        (plist-get tool :name) '(:subject_id "project-1") "fake" :llm)))))

(ert-deftest supertag-v12-allow-action-tool-executes-through-policy ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action
     nil '((:actor :automation :decision :deny)
           (:actor :external :decision :deny)
           (:actor :interactive-user :decision :allow)
           (:actor :llm :decision :allow)))
    (let ((action (supertag-store-get-entity :ontology-actions "complete")))
      (supertag-store-put-entity
       :ontology-actions "complete" (plist-put action :llm-tool t)))
    (let* ((tool (car (supertag-ontology-tool-list :llm)))
           (result
            (supertag-ontology-tool-invoke
             (plist-get tool :name) '(:subject_id "project-1") nil :llm)))
      (should (eq :execute (plist-get tool :mode)))
      (should (equal "executed"
                     (supertag-v12-test-json-object-get result "status")))
      (should (equal "done"
                     (supertag-store-get-field-value
                      "project-1" "status"))))))

(ert-deftest supertag-v12-confirm-tool-requires-out-of-band-capability ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action
     nil '((:actor :automation :decision :deny)
           (:actor :external :decision :deny)
           (:actor :interactive-user :decision :allow)
           (:actor :llm :decision :confirm)))
    (let ((action (supertag-store-get-entity :ontology-actions "complete")))
      (supertag-store-put-entity
       :ontology-actions "complete" (plist-put action :llm-tool t)))
    (let* ((tool (car (supertag-ontology-tool-list :llm)))
           (input '(:subject_id "project-1"))
           (pending
            (supertag-ontology-tool-invoke
             (plist-get tool :name) input nil :llm)))
      (should (eq :confirm (plist-get tool :mode)))
      (should (equal "confirmation_required"
                     (supertag-v12-test-json-object-get pending "status")))
      (should (equal "active"
                     (supertag-store-get-field-value
                      "project-1" "status")))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (let ((token
               (supertag-ontology-tool-request-confirmation
                (plist-get tool :name) input :llm)))
          (should (stringp token))
          (should (equal "executed"
                         (supertag-v12-test-json-object-get
                          (supertag-ontology-tool-invoke
                           (plist-get tool :name) input token :llm)
                          "status")))))
      (should (equal "done"
                     (supertag-store-get-field-value
                      "project-1" "status"))))))

(ert-deftest supertag-v12-denied-action-is-not-addressable-as-a-tool ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-status-action
     nil '((:actor :automation :decision :deny)
           (:actor :external :decision :deny)
           (:actor :interactive-user :decision :allow)
           (:actor :llm :decision :deny)))
    (let ((action (supertag-store-get-entity :ontology-actions "complete")))
      (supertag-store-put-entity
       :ontology-actions "complete" (plist-put action :llm-tool t)))
    (should-not (supertag-ontology-tool-list :llm))
    (should-error
     (supertag-ontology-tool-invoke
      "st_act_complete_fake" '(:subject_id "project-1") nil :llm)
     :type 'supertag-ontology-tool-stale)))

(ert-deftest supertag-v12-rejects-duplicate-top-level-json-keys ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function "count" t)
    (let ((name (plist-get (car (supertag-ontology-tool-list :llm)) :name)))
      (should-error
       (supertag-ontology-tool-invoke-json
        name
        "{\"subject_id\":\"project-1\",\"subject_id\":\"other\"}"
        nil :llm)
       :type 'supertag-ontology-tool-error))))

(ert-deftest supertag-v12-catalog-json-normalizes-keyword-values ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function "count" t)
    (let ((json (supertag-ontology-tool-catalog-json :llm)))
      (should (string-match-p "\"kind\":\"llm\"" json))
      (should-not (string-match-p "\"kind\":\":llm\"" json)))))

(ert-deftest supertag-v12-provider-json-hides-implementation-symbols ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function "count" t)
    (let ((json (supertag-ontology-tool-catalog-json :llm t)))
      (should (string-match-p "st_fn_" json))
      (should (string-match-p "output_schema" json))
      (should-not (string-match-p "supertag-v12-test-count" json))
      (should-not (string-match-p "implementation" json)))))

(ert-deftest supertag-v12-name-limit-fails-instead-of-emitting-invalid-name ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function "count" t)
    (let ((supertag-ontology-tool-name-max-length 8))
      (should-error (supertag-ontology-tool-list :llm)
                    :type 'supertag-ontology-tool-error))))

(ert-deftest supertag-v12-tool-layer-rejects-non-llm-actors-and-persists-nothing ()
  (supertag-v10-test-with-store
    (supertag-v10-test-install-project)
    (supertag-v12-test-install-function "count" t)
    (should-error (supertag-ontology-tool-catalog :automation))
    (dolist (collection '(:ontology-tools :llm-tools :tool-catalogs
                          :ontology-tool-proposals))
      (should-not (memq collection supertag--store-collections)))))

(provide 'supertag-ontology-tool-test)
;;; supertag-ontology-tool-test.el ends here
