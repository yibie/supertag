;;; automation-templates-test.el --- every built-in template runs -*- lexical-binding: t; -*-
;; A template that builds a rule the engine cannot run is a broken template.
;; `field-change-update-field' and `field-equals-move-node' were exactly that:
;; an unknown trigger (which fails closed), an unknown condition form, and in
;; one case an unknown action type.  `supertag-automation-create' accepted them
;; without error, so the only honest guard is to instantiate every template,
;; fire the event its trigger names, and assert the action's effect.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'document-fixture)
(require 'ownership-fixture)
(require 'supertag-services-sync)
(require 'supertag-service-org)
(require 'supertag-automation)

(defmacro supertag-automation-template-test--with-vault (&rest body)
  "Run BODY with an isolated projection, Automation and async state."
  (declare (indent 0) (debug t))
  `(supertag-ownership-test-with-vault
     (let ((supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--state-source
            (expand-file-name "sync-state.el" supertag-data-directory))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-sync--internal-modifications (make-hash-table :test 'equal))
           (supertag--subscribers (make-hash-table :test 'equal))
           (supertag-after-operation-hook nil)
           (supertag--rule-index (make-hash-table :test 'equal))
           (supertag-automation--enabled t)
           (supertag-automation-sync--enabled t)
           (supertag-automation--executing nil)
           (supertag-automation--processing-queue nil)
           (supertag-automation-sync--processing-stack nil)
           (supertag-automation--event-queue nil)
           (supertag-async--queue nil)
           (supertag-async--processor-fn #'supertag-sync--async-processor)
           (supertag-async-batch-size 1)
           (supertag-async--failed-items nil)
           (supertag-async--timer nil))
       (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore)
                 ((symbol-function 'supertag-async--ensure-timer) #'ignore))
         (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
         (setq supertag-async--queue nil)
         (clrhash supertag-sync--internal-modifications)
         (unwind-protect
             (progn ,@body)
           (dolist (buffer (buffer-list))
             (when-let* ((file (buffer-file-name buffer)))
               (when (file-in-directory-p file vault)
                 (with-current-buffer buffer (set-buffer-modified-p nil))
                 (kill-buffer buffer)))))))))

(defun supertag-automation-template-test--register-tags ()
  "Register every tag these template tests use."
  (dolist (name '("tpl-tag" "tpl-trigger" "tpl-implied" "tpl-go" "tpl-derived"
                  "tpl-scope" "tpl-urgent" "tpl-daily" "tpl-followup" "task" "followup"))
    (supertag-tag-create (list :id name :name name))))

(defun supertag-automation-template-test--create (id params)
  "Instantiate template ID with PARAMS, create the rule, and return it.
Fail loudly when ID is gone, so a renamed or deleted template cannot leave
this suite passing by accident."
  (let* ((template (or (cl-find id supertag-automation-templates
                                :key (lambda (item) (plist-get item :id)))
                       (ert-fail (format "No template with id %S" id))))
         (rule (funcall (plist-get template :build) params)))
    (should (plist-get rule :trigger))
    (should (plist-get rule :actions))
    (supertag-automation-create rule)
    rule))

(defun supertag-automation-template-test--disk (file)
  "Return FILE's text."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun supertag-automation-template-test--subscribe ()
  "Route real store changes into the automation engine."
  (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change))

(defun supertag-automation-template-test--add-tag (node tag)
  "Add TAG to NODE through the real store path, firing tag automation."
  (supertag-automation-template-test--subscribe)
  (supertag-service-org-add-tag node tag))

(defun supertag-automation-template-test--remove-tag (node tag)
  "Remove TAG from NODE through the real store path."
  (supertag-automation-template-test--subscribe)
  (supertag-service-org-remove-tag node tag))

(defun supertag-automation-template-test--set-property (file name value)
  "Save NAME=VALUE in FILE and run the real projection event."
  (supertag-automation-template-test--subscribe)
  (supertag-document-test-save-property file name value)
  (supertag-document-test-drain))

(ert-deftest supertag-automation-template-tag-added-set-todo-state ()
  "Template 1: adding the tag sets the TODO keyword on the node's heading."
  (supertag-automation-template-test--with-vault
    (let ((file (car files)))
      (supertag-automation-template-test--register-tags)
      (supertag-automation-template-test--create
       :tag-added-set-todo-state '((tag . "tpl-tag") (state . "DONE")))
      (supertag-automation-template-test--add-tag
       supertag-ownership-test-node-a "tpl-tag")
      (should (string-match-p "^\\* DONE "
                              (supertag-automation-template-test--disk file)))
      (should (equal "DONE"
                     (plist-get (supertag-node-get supertag-ownership-test-node-a)
                                :todo))))))

(ert-deftest supertag-automation-template-tag-added-set-property ()
  "Template 2: adding the tag writes the configured Org property."
  (supertag-automation-template-test--with-vault
    (let ((file (car files)))
      (supertag-automation-template-test--register-tags)
      (supertag-automation-template-test--create
       :tag-added-set-property '((tag . "tpl-tag") (property . "RANK")
                                 (value . "A")))
      (supertag-automation-template-test--add-tag
       supertag-ownership-test-node-a "tpl-tag")
      (should (string-match-p ":RANK:[ \t]+A"
                              (supertag-automation-template-test--disk file)))
      (should (equal "A"
                     (plist-get (plist-get (supertag-node-get
                                            supertag-ownership-test-node-a)
                                           :properties)
                                :RANK))))))

(ert-deftest supertag-automation-template-tag-added-add-tag ()
  "Template 3: adding the trigger tag adds the implied tag."
  (supertag-automation-template-test--with-vault
    (supertag-automation-template-test--register-tags)
    (supertag-automation-template-test--create
     :tag-added-add-tag '((trigger-tag . "tpl-trigger") (implied-tag . "tpl-implied")))
    (supertag-automation-template-test--add-tag
     supertag-ownership-test-node-a "tpl-trigger")
    (should (member "tpl-implied"
                    (plist-get (supertag-node-get supertag-ownership-test-node-a)
                               :tags)))))

(ert-deftest supertag-automation-template-tag-removed-remove-tag ()
  "Template 4: removing the trigger tag removes the derived tag."
  (supertag-automation-template-test--with-vault
    (supertag-automation-template-test--register-tags)
    (supertag-automation-template-test--add-tag
     supertag-ownership-test-node-a "tpl-derived")
    (supertag-automation-template-test--create
     :tag-removed-remove-tag '((trigger-tag . "tpl-go") (derived-tag . "tpl-derived")))
    (supertag-automation-template-test--add-tag
     supertag-ownership-test-node-a "tpl-go")
    (supertag-automation-template-test--remove-tag
     supertag-ownership-test-node-a "tpl-go")
    (should-not (member "tpl-derived"
                        (plist-get (supertag-node-get supertag-ownership-test-node-a)
                                   :tags)))))

(ert-deftest supertag-automation-template-property-change-update-property ()
  "Template 5: a scoped property change sets the target property."
  (supertag-automation-template-test--with-vault
    (let ((file (car files)))
      (supertag-automation-template-test--register-tags)
      (supertag-automation-template-test--add-tag
       supertag-ownership-test-node-a "tpl-scope")
      (supertag-automation-template-test--create
       :property-change-update-property
       '((scope-tag . "tpl-scope") (source-property . "STAGE")
         (target-property . "TOUCHED") (target-value . "yes")))
      (supertag-automation-template-test--set-property file "STAGE" "ready")
      (should (string-match-p ":TOUCHED:[ \t]+yes"
                              (supertag-automation-template-test--disk file)))
      (should (equal "yes"
                     (plist-get (plist-get (supertag-node-get
                                            supertag-ownership-test-node-a)
                                           :properties)
                                :TOUCHED))))))

(ert-deftest supertag-automation-template-property-equals-move-node ()
  "Template 6: the configured property value moves the node's Org text."
  (supertag-automation-template-test--with-vault
    (let* ((file (car files))
           (target (expand-file-name "archive.org" tmp)))
      (supertag-automation-template-test--register-tags)
      (supertag-automation-template-test--create
       :property-equals-move-node
       (list (cons 'scope-tag "") (cons 'property "STATUS")
             (cons 'value "archived") (cons 'target-file target)))
      (supertag-automation-template-test--set-property file "STATUS" "archived")
      (should (file-exists-p target))
      (should (string-match-p (regexp-quote supertag-ownership-test-node-a)
                              (supertag-automation-template-test--disk target)))
      (should-not (string-match-p (regexp-quote supertag-ownership-test-node-a)
                                  (supertag-automation-template-test--disk file)))
      (should (equal (file-truename target)
                     (plist-get (supertag-node-get supertag-ownership-test-node-a)
                                :file))))))

(ert-deftest supertag-automation-template-property-equals-add-tag ()
  "Template 7: the configured property value adds the tag."
  (supertag-automation-template-test--with-vault
    (let ((file (car files)))
      (supertag-automation-template-test--register-tags)
      (supertag-automation-template-test--create
       :property-equals-add-tag '((property . "RANK") (value . "A")
                                  (tag . "tpl-urgent")))
      (supertag-automation-template-test--set-property file "RANK" "A")
      (should (member "tpl-urgent"
                      (plist-get (supertag-node-get supertag-ownership-test-node-a)
                                 :tags))))))

(ert-deftest supertag-automation-template-daily-set-property-for-tag ()
  "Template 8: the scheduled tick sets the property on tagged nodes."
  (supertag-automation-template-test--with-vault
    (let ((file (car files))
          (supertag-scheduler--tasks (make-hash-table :test 'equal)))
      (supertag-automation-template-test--register-tags)
      (supertag-automation-template-test--add-tag
       supertag-ownership-test-node-a "tpl-daily")
      (make-directory supertag-data-directory t)
      (supertag-automation-template-test--create
       :daily-set-property-for-tag
       '((tag . "tpl-daily") (property . "REVIEW") (value . "done")
         (time . "00:00")))
      ;; The scheduler runner is the matching event for :on-schedule.
      (let ((now (time-convert (encode-time 0 0 12 1 1 2026) 'list)))
        (cl-letf (((symbol-function 'current-time) (lambda () now)))
          (supertag-scheduler--check-tasks)))
      (should (string-match-p ":REVIEW:[ \t]+done"
                              (supertag-automation-template-test--disk file)))
      (should (equal "done"
                     (plist-get (plist-get (supertag-node-get
                                            supertag-ownership-test-node-a)
                                           :properties)
                                :REVIEW))))))

(ert-deftest supertag-automation-template-tag-added-create-followup-node ()
  "Template 9: adding the tag creates the follow-up node in its file."
  (supertag-automation-template-test--with-vault
    (let ((target (expand-file-name "followup.org" vault)))
      (with-temp-file target (insert "#+title: Follow-up\n"))
      (supertag-automation-template-test--register-tags)
      (supertag-automation-template-test--create
       :tag-added-create-followup-node
       (list (cons 'tag "tpl-followup") (cons 'title "Follow-up A")
             (cons 'followup-tags "task, followup") (cons 'target-file target)))
      (supertag-automation-template-test--add-tag
       supertag-ownership-test-node-a "tpl-followup")
      (let ((created (mapcar #'cdr (supertag-find-nodes-by-file (file-truename target)))))
        (should (= 1 (length created)))
        (should (equal "Follow-up A" (plist-get (car created) :title)))
        (should (member "task" (plist-get (car created) :tags)))
        (should (string-match-p (regexp-quote (plist-get (car created) :id))
                                (supertag-automation-template-test--disk target)))))))

(ert-deftest supertag-automation-template-catalog-has-effect-tests ()
  "Every catalog entry must have a corresponding end-to-end effect test."
  (dolist (template supertag-automation-templates)
    (should (ert-test-boundp
             (intern (concat "supertag-automation-template-"
                             (substring (symbol-name (plist-get template :id)) 1)))))))

(ert-deftest supertag-automation-template-rejects-unknown-rule-vocabulary ()
  (supertag-automation-template-test--with-vault
    (dolist (trigger '(:on-field-change :typo (:on-tag-added) (:on-tag-added 1)))
      (should-error
       (supertag-automation-create
        (list :name "invalid" :trigger trigger
              :actions '((:action :add-tag :params (:tag "task")))))))
    (dolist (actions '(((:action :update-field))
                       ((:action :typo))
                       ((:action :case :params
                         (:branches ((:default t :actions ((:action :typo)))))))))
      (should-error
       (supertag-automation-create
        (list :name "invalid" :trigger :on-property-change :actions actions))))
    (should-not (supertag-automation-get "auto-invalid"))))

(provide 'automation-templates-test)
;;; automation-templates-test.el ends here
