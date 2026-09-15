;;; supertag-automation.el --- Unified Automation System for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file implements the complete Automation System 2.0 for the
;; Supertag system. It unifies all automation-related functionality
;; including:
;;
;; 1. Rule indexing and CRUD operations
;; 2. Event-driven automation execution
;; 3. Saved Org property actions
;; 4. Formula evaluation over projected properties
;; 5. Bidirectional relation updates
;; 6. Database-level automation rules
;;
;; Key design principles:
;; 1. Pure data-centric architecture with single source of truth
;; 2. Automatic rule indexing for O(1) performance
;; 3. No manual behavior attachment - rules are applied via index
;; 4. Modern automation with multi-action support
;; 5. Unified state management and execution engine


;; Commands: supertag-automation-insert-template, supertag-automation-list-templates.
;; Public Lisp APIs: rules, events, scheduled tasks and lifecycle.
;; Dependencies: cl-lib, subr-x, ht, json, core-store/persistence,
;;   tag, node, service-org, query.
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'supertag-core-persistence)
(require 'supertag-core-store)     ; For data storage operations

(require 'supertag-tag)        ; For tag operations
(require 'supertag-node)       ; For node operations
(require 'supertag-service-org)
(require 'supertag-query)
(require 'ht)

;;; Customization

(defgroup supertag-automation nil
  "Automation settings for Supertag."
  :group 'supertag)

(defcustom supertag-automation-verbose nil
  "When non-nil, log verbose automation diagnostics.

This controls routine messages such as rule execution traces and no-op action
skips. Errors and warnings are still reported regardless of this flag."
  :type 'boolean
  :group 'supertag-automation)

(defun supertag-automation--log (format-string &rest args)
  "Log FORMAT-STRING with ARGS when `supertag-automation-verbose' is non-nil."
  (when supertag-automation-verbose
    (apply #'message format-string args)))

;;; --- Core State Management ---

(defun supertag-automation--ensure-plist (data)
  "Return a plist copy of DATA, converting hash tables when necessary.
This function preserves all data including tags and fields."
  (cond
   ((null data) nil)
   ((hash-table-p data)
    ;; Convert hash table to plist while preserving all data
    (let (plist)
      (maphash (lambda (k v)
                 ;; Ensure we don't lose data during conversion
                 (if (eq k :tags)
                     ;; Special handling for tags to ensure list format
                     (setq plist (plist-put plist :tags (if (listp v) v (list v))))
                   (setq plist (plist-put plist k v))))
               data)
      plist))
   ((listp data)
    (copy-tree data))
   (t
    (error "Unsupported automation entity format: %S" data))))

(defun supertag-automation--normalize-keyword (name)
  "Normalize NAME into a keyword symbol."
  (cond
   ((keywordp name) name)
   ((symbolp name) (intern (concat ":" (symbol-name name))))
   ((stringp name) (intern (concat ":" name)))
   (t (error "Unsupported property key: %S" name))))

(defvar supertag-automation--enabled t
  "Global flag to enable/disable automation execution.")

(defvar supertag-automation--executing nil
  "Flag to indicate if automation is currently executing actions.
This prevents recursive automation triggers during action execution.")

(defvar supertag-automation--event-queue nil
  "Queue of pending automation events to be processed asynchronously.
Each event is a list: (event-handler-fn args...)")

(defvar supertag-automation--processing-timer nil
  "Timer for processing queued automation events.")

(defvar supertag-automation--processing-queue nil
  "Queue for automation tasks to prevent infinite loops.")

(defvar supertag-automation--current-event nil
  "Dynamically-bound event context during condition evaluation.
Plist keys:
  :path  - store event path
  :old   - old value at that path
  :new   - new value at that path
  :tag-event - when tag event happens, either :added or :removed
  :tag   - the tag name for a tag event")

(defun supertag-automation--event-type (&optional event)
  "Return a keyword describing EVENT type.

EVENT defaults to `supertag-automation--current-event'."
  (let* ((ev (or event supertag-automation--current-event))
         (path (plist-get ev :path)))
    (cond
     ((plist-member ev :tag-event) :tag-change)

     ((and (listp path) (eq (car path) :nodes)
           (>= (length path) 4)
           (eq (nth 2 path) :properties))
      :property-change)
     ((and (listp path) (eq (car path) :nodes)) :node-change)
     (t :unknown))))

(defun supertag-automation--trigger-match-p (trigger &optional event)
  "Return non-nil when TRIGGER matches EVENT.

EVENT defaults to `supertag-automation--current-event'. Unknown triggers
do not match (fail closed)."
  (let* ((ev (or event supertag-automation--current-event))
         (normalized (if (fboundp 'supertag-automation--normalize-trigger)
                         (supertag-automation--normalize-trigger trigger)
                       trigger))
         (event-type (supertag-automation--event-type ev))
         (tag-op (plist-get ev :tag-event))
         (tag (plist-get ev :tag)))
    (pcase normalized
      ((or 'nil :always) t)
      (:on-change (not (eq event-type :unknown)))

      (:on-property-change (eq event-type :property-change))
      (:on-schedule nil)
      (:manual nil)
      (`(:on-tag-added ,tag-name)
       (and (eq event-type :tag-change)
            (eq tag-op :added)
            (equal tag-name tag)))
      (`(:on-tag-removed ,tag-name)
       (and (eq event-type :tag-change)
            (eq tag-op :removed)
            (equal tag-name tag)))
      (_
       (supertag-automation--log "Automation: unknown trigger %S (event=%S)" trigger ev)
       nil))))

;;; --- Automation Rule Indexing System ---

(defvar supertag--rule-index (make-hash-table :test 'equal)
  "The master index for automation rules.
This data structure allows for O(1) lookup of relevant rules
based on a trigger event, avoiding a full scan of all rules.

The structure is a hash table where:
 - KEY is the trigger source (e.g., a property keyword like :status,
  or a tag name like \"Project\").
 - VALUE is a list of rule IDs that are interested in this source.")

(defvar supertag-automation--rule-index-source-token nil
  "Source token represented by `supertag--rule-index'.")

(defun supertag-automation-clear-rule-index ()
  "Clear the derived Automation rule index."
  (setq supertag--rule-index (make-hash-table :test 'equal)
        supertag-automation--rule-index-source-token nil))

(defun supertag--extract-trigger-sources (condition)
  "Return property keys and tag names referenced by CONDITION."
  (let (sources)
    (cl-labels ((walk (form)
                 (when (consp form)
                   (pcase (car form)
                     ('has-tag (push (cadr form) sources))
                     ((or 'has-any-tag 'has-all-tags)
                      (setq sources (append (cdr form) sources)))
                     ((or 'property 'property-equals 'property-test 'property-changed)
                      (push (supertag-query-normalize-property-key (cadr form)) sources))
                     ('quote (walk (cadr form)))
                     ((or 'and 'or 'not) (mapc #'walk (cdr form)))))))
      (walk condition))
    (delete-dups sources)))

(defun supertag--add-rule-to-index (rule)
  "Parse a RULE and add its ID to the global rule index."
  (let* ((rule-id (plist-get rule :id))
         (sources (supertag--extract-trigger-sources (plist-get rule :condition))))
    ;; Also consider the trigger itself as a source if it's specific
    (pcase (plist-get rule :trigger)
      (`(:on-tag-added ,tag-name) (push tag-name sources))
      (`(:on-tag-removed ,tag-name) (push tag-name sources)))

    (dolist (source (cl-remove-duplicates sources :test 'equal))
      (let ((rules (gethash source supertag--rule-index '())))
        ;; Use cl-pushnew to add the rule-id to the list of rules, avoiding duplicates.
        (cl-pushnew rule-id rules :test 'equal)
        ;; Put the updated list back into the hash table.
        (puthash source rules supertag--rule-index)))))

(defun supertag--remove-rule-from-index (rule)
  "Parse a RULE and remove its ID from the global rule index."
  (let* ((rule-id (plist-get rule :id))
         (sources (supertag--extract-trigger-sources (plist-get rule :condition))))
    (pcase (plist-get rule :trigger)
      (`(:on-tag-added ,tag-name) (push tag-name sources))
      (`(:on-tag-removed ,tag-name) (push tag-name sources)))

    (dolist (source (cl-remove-duplicates sources))
      (when-let ((rules (gethash source supertag--rule-index)))
        (puthash source (remove rule-id rules) supertag--rule-index)))))

(defun supertag-rebuild-rule-index ()
  "Clear and rebuild the entire automation rule index.
This function should be called once on system startup to ensure
the index is synchronized with the stored rules."
  (supertag-automation-clear-rule-index)
  (let ((all-rules (supertag-automation-list)))
    (dolist (rule all-rules)
      (supertag--add-rule-to-index rule)))
  (setq supertag-automation--rule-index-source-token
        (supertag-index-source-token '(:automations))))

(defun supertag-automation--ensure-rule-index ()
  "Cold rebuild the rule index when Automation facts changed."
  (unless (supertag-index-source-current-p
           supertag-automation--rule-index-source-token '(:automations))
    (supertag-rebuild-rule-index)))

(defun supertag--get-rules-from-index (event-path)
  "Return rule IDs matching projected properties or tags at EVENT-PATH."
  (supertag-automation--ensure-rule-index)
  (let* ((path (if (consp (car event-path)) (car event-path) event-path))
         (node (and (eq (car path) :nodes) (supertag-query-node (cadr path))))
         (key (and (eq (nth 2 path) :properties) (nth 3 path)))
         (rules (copy-sequence (gethash key supertag--rule-index))))
    (dolist (tag (plist-get node :tags))
      (setq rules (append (gethash tag supertag--rule-index) rules)))
    (cl-remove-duplicates rules :test #'equal)))

;;; --- Data Validation ---

(defun supertag-automation--normalize-trigger (trigger)
  "Normalize trigger to canonical format.
TRIGGER can be:
- A keyword like :on-property-change, :on-schedule
- A list like (:on-tag-added \"tagname\") or (:on-tag-removed \"tagname\")
Returns the normalized trigger."
  (cond
   ;; Already a list form - return as is
   ((and (listp trigger) (keywordp (car trigger))) trigger)
   ;; Simple keyword - return as is
   ((keywordp trigger) trigger)
   ;; String - try to intern it
   ((stringp trigger) (intern trigger))
   ;; Otherwise return as is
   (t trigger)))

(defun supertag--validate-automation-data (data)
  "Validate automation data structure."
  (unless (plist-get data :name)
    (error "Automation missing required :name field: %S" data))
  (unless (plist-get data :trigger)
    (error "Automation missing required :trigger field: %S" data))
  (unless (plist-get data :actions)
    (error "Automation missing required :actions field: %S" data)))


;;; --- Core CRUD Operations ---

(defun supertag-automation-create (automation-data)
  "Create a new automation rule.
AUTOMATION-DATA should contain:
- :name (required) - Automation name
- :description (optional) - Description
- :trigger (required) - Trigger condition
- :condition (optional) - When to execute (list of conditions)
- :actions (required) - List of actions to perform
- :enabled (optional) - Whether automation is enabled (default: t)

Returns the created automation data with assigned ID."
  (supertag-with-transaction
    (let* ((name (plist-get automation-data :name))
           (id (format "auto-%s" (replace-regexp-in-string "[^a-zA-Z0-9-]" "-" name))))

      ;; Validate input data
      (supertag--validate-automation-data automation-data)

      ;; Check if automation already exists and delete it if it does
      (let ((existing (supertag-automation-get id)))
        (when existing
          (supertag-automation-delete id)))

      ;; Prepare automation data
      (let ((automation-plist (list :id id
                                    :name name
                                    :description (or (plist-get automation-data :description) "")
                                    :trigger (supertag-automation--normalize-trigger
                                              (plist-get automation-data :trigger))
                                    :condition (plist-get automation-data :condition)
                                    :actions (plist-get automation-data :actions)
                                    :schedule (plist-get automation-data :schedule)
                                    :enabled (if (plist-member automation-data :enabled)
                                               (plist-get automation-data :enabled)
                                             t)
                                    :created-at (supertag-current-time)
                                    :modified-at (supertag-current-time))))

        ;; Store automation
        (supertag-store-put-entity :automations id automation-plist t)

        ;; Add to the rule index
        (supertag--add-rule-to-index automation-plist)

        ;; Register to scheduler if needed
        (when (eq (plist-get automation-plist :trigger) :on-schedule)
          (supertag-automation--register-scheduled-rule automation-plist))

        ;; Notify system
        (when (fboundp 'supertag-notify)
          (supertag-notify :automation-created :automation-id id :data automation-plist))

        automation-plist))))

(defun supertag-automation-get (id)
  "Get automation by ID."
  (supertag-store-get-entity :automations id))

(defun supertag-automation-update (id updater)
  "Update automation data.
ID is the automation identifier.
UPDATER is a function that receives current data and returns updated data."
  (supertag-with-transaction
  (let ((automation (supertag-automation-get id)))
    (when automation
      (let ((updated-automation (funcall updater automation)))
        (when updated-automation
          ;; Update scheduler bridge
          (when (eq (plist-get automation :trigger) :on-schedule)
            (supertag-automation--deregister-scheduled-rule automation))
          ;; Update indexes
          (supertag--remove-rule-from-index automation)
          ;; Normalize trigger before re-index
          (setq updated-automation
                (plist-put updated-automation :trigger
                           (supertag-automation--normalize-trigger
                            (plist-get updated-automation :trigger))))
          (supertag--add-rule-to-index updated-automation)
          (let ((final-automation (plist-put updated-automation :modified-at (supertag-current-time))))
            (supertag--validate-automation-data final-automation)
            (supertag-store-put-entity :automations id final-automation t)
            ;; Re-register if still scheduled
            (when (eq (plist-get final-automation :trigger) :on-schedule)
              (supertag-automation--register-scheduled-rule final-automation))
            (when (fboundp 'supertag-notify)
              (supertag-notify :automation-updated :automation-id id :data final-automation))
            final-automation)))))))

(defun supertag-automation-delete (id)
  "Delete automation by ID.
Returns the deleted automation data or nil if not found."
  (supertag-with-transaction
    (let ((automation (supertag-automation-get id)))
      (when automation
        ;; Deregister from scheduler if needed
        (when (eq (plist-get automation :trigger) :on-schedule)
          (supertag-automation--deregister-scheduled-rule automation))
        ;; Remove from the rule index
        (supertag--remove-rule-from-index automation)
        ;; Delete from storage
        (supertag-store-remove-entity :automations id)
        ;; Notify system
        (when (fboundp 'supertag-notify)
          (supertag-notify :automation-deleted :automation-id id :data automation))
        (message "Deleted automation: %s" (plist-get automation :name))
        automation))))

(defun supertag-automation-list (&optional filter)
  "List all automations with optional FILTER.
FILTER can be a function that receives automation data and returns t/nil."
  (supertag-query-automations filter))

(defun supertag-automation-get-by-name (name)
  "Get automation by name.
Returns automation data or nil if not found."
  (let ((id (format "auto-%s" (replace-regexp-in-string "[^a-zA-Z0-9-]" "-" name))))
    (supertag-automation-get id)))

;;; --- Query Functions ---

(defun supertag-automation-find-by-trigger (trigger-type)
  "Find all automations with specific trigger type."
  (let ((target (supertag-automation--normalize-trigger trigger-type)))
    (supertag-automation-list
     (lambda (automation)
       (equal (supertag-automation--normalize-trigger
               (plist-get automation :trigger))
              target)))))

(defun supertag-automation-find-enabled ()
  "Find all enabled automations."
  (supertag-automation-list (lambda (automation)
                              (plist-get automation :enabled))))

(defun supertag-automation-find-scheduled ()
  "Find all scheduled automations."
  (supertag-automation-list (lambda (automation)
                              (eq (plist-get automation :trigger) :on-schedule))))

;; === Scheduler Bridge ===
(defun supertag-automation--register-scheduled-rule (rule)
  "Register a :on-schedule RULE with the central scheduler, if available."
  (when (and (eq (plist-get rule :trigger) :on-schedule)
             (fboundp 'supertag-scheduler-register-task))
            (let* ((schedule (plist-get rule :schedule))
                   (time (plist-get schedule :time))
                   (days (plist-get schedule :days-of-week))
                   (id-sym (intern (plist-get rule :id)))
           (runner
            (lambda ()
              (let ((rule-now (supertag-automation-get (plist-get rule :id))))
                (when (and rule-now (plist-get rule-now :enabled))
                  (dolist (action (plist-get rule-now :actions))
                    (when (eq (plist-get action :action) :call-function)
                      (supertag-automation-execute-action
                       :call-function nil (plist-get action :params)
                       (list :scheduled t :rule (plist-get rule-now :id))))))))))
      (condition-case err
                  (progn
                    (supertag-scheduler-register-task id-sym :daily runner
                                                      :time time
                                                      :days-of-week days)
                    (supertag-automation--log "[Automation Scheduler] Registered scheduled rule: %s at %s days=%S"
                                             (plist-get rule :id) time days))
                (error (message "ERROR: Failed to register scheduled rule %s: %S"
                                (plist-get rule :id) err))))))

(defun supertag-automation--deregister-scheduled-rule (rule)
  "Deregister a scheduled RULE from the scheduler, if available."
  (when (and (fboundp 'supertag-scheduler-deregister-task)
             (plist-get rule :id))
    (let ((id-sym (intern (plist-get rule :id))))
              (condition-case err
                  (progn
                    (supertag-scheduler-deregister-task id-sym)
                    (supertag-automation--log "[Automation Scheduler] Deregistered scheduled rule: %s"
                                             (plist-get rule :id)))
                (error (message "ERROR: Failed to deregister scheduled rule %s: %S"
                                (plist-get rule :id) err))))))

(defun supertag-automation--register-all-scheduled ()
  "Register all :on-schedule rules with the scheduler."
  (when (fboundp 'supertag-scheduler-register-task)
    (dolist (rule (supertag-automation-find-scheduled))
      (supertag-automation--register-scheduled-rule rule))))

;;; --- Rule Execution Engine ---

(defun supertag-rule-get (id)
  "Get any rule by ID. Unified interface for rule retrieval."
  (supertag-automation-get id))

(defun supertag-rule-execute (rule node-id context)
  "Execute a rule with given context.
This is called by the automation engine when a rule matches an event."
  (when (and rule (plist-get rule :enabled))
    ;; Prevent recursive automation during action execution
    (unless supertag-automation--executing
      (let ((actions (plist-get rule :actions))
            (rule-id (plist-get rule :id))
            (supertag-automation--executing t))
        (supertag-automation--log "Executing rule %s on node %s" rule-id node-id)
        (unwind-protect
            (progn
              (supertag-automation--execute-actions actions node-id context))
          ;; Always clear the executing flag
          (setq supertag-automation--executing nil))))))

(defun supertag-automation--execute-actions (actions node-id context)
  "Execute ACTIONS sequentially for NODE-ID with CONTEXT.
ACTIONS should be a list of plists, each containing :action and
optionally :params."
  (dolist (action-spec actions)
    (let ((action-type (plist-get action-spec :action))
          (params (plist-get action-spec :params)))
      (if action-type
          (supertag-automation-execute-action action-type node-id params context)
        (message "Automation Warning: Invalid action spec (missing :action): %S" action-spec)))))

(defun supertag-automation-execute-action (action-type node-id params context)
  "Execute a specific action type.
ACTION-TYPE is the action to perform
NODE-ID is the target node
PARAMS are action parameters
CONTEXT provides execution context"
  (pcase action-type
    (:update-property
     (supertag-automation-action-update-property node-id params))

    (:update-todo-state
     (supertag-automation-action-update-todo-state node-id params))

    (:add-tag
     (supertag-automation-action-add-tag node-id params))

    (:remove-tag
     (supertag-automation-action-remove-tag node-id params))

    (:create-node
     (supertag-automation-action-create-node params))


    (:move-node
     (supertag-automation-action-move-node node-id params))

    (:call-function
     (supertag-automation-action-call-function node-id params context))

    (:case
     (supertag-automation-action-case node-id params context))

    (_
     (message "Unknown action type: %s" action-type))))

(defun supertag-automation--case-resolve (spec node-data context)
  "Resolve SPEC to a value for CASE evaluation using NODE-DATA and CONTEXT."
  (pcase spec

    (`(:property ,prop)
     (let ((props (plist-get node-data :properties)))
       (plist-get props (supertag-query-normalize-property-key prop))))
    (`(:value ,value) value)
    (`(:literal ,value) value)
    (`(:context ,key)
     (plist-get context key))
    (`(:function ,fn)
     (when (functionp fn)
       (funcall fn node-data context)))
    (`(:eval ,fn)
     (when (functionp fn)
       (funcall fn node-data context)))
    (_ spec)))

(defun supertag-automation--case-branch-match-p (branch value node-data context)
  "Return non-nil when BRANCH matches VALUE.
BRANCH can specify :equals (single value or list), :in (list),
:match (regexp), or :test (function)."
  (cond
   ((plist-get branch :default) nil)
   ((plist-member branch :equals)
    (let ((expected (plist-get branch :equals)))
      (if (listp expected)
          (cl-some (lambda (item) (equal item value)) expected)
        (equal expected value))))
   ((plist-member branch :in)
    (let ((collection (plist-get branch :in)))
      (and (listp collection)
           (cl-some (lambda (item) (equal item value)) collection))))
   ((plist-member branch :match)
    (let ((pattern (plist-get branch :match)))
      (cond
       ((and (stringp pattern) (stringp value))
        (string-match-p pattern value))
       ((functionp pattern)
        (funcall pattern value node-data context))
       (t nil))))
   ((plist-member branch :test)
    (let ((fn (plist-get branch :test)))
      (when (functionp fn)
        (funcall fn value node-data context))))
   (t nil)))

(defun supertag-automation-action-case (node-id params context)
  "Evaluate CASE action described by PARAMS for NODE-ID with CONTEXT."
  (let* ((node-data (or (supertag-query-node node-id)
                        (list :id node-id :tags nil :properties nil)))
         (on-spec (plist-get params :on))
         (branches (plist-get params :branches))
         (value (supertag-automation--case-resolve on-spec node-data context))
         (matched nil)
         (default-actions nil))
    (unless (listp branches)
      (message "Automation Warning: CASE branches must be a list, got %S" branches)
      (setq branches nil))
    (dolist (branch branches)
      (let ((actions (or (plist-get branch :actions)
                         (plist-get branch :do)
                         (plist-get branch :then))))
        (cond
         ((plist-get branch :default)
          (setq default-actions actions))
         ((and (not matched)
               (supertag-automation--case-branch-match-p branch value node-data context))
          (setq matched t)
          (when actions
            (supertag-automation--execute-actions actions node-id context))))))
    (when (and (not matched) default-actions)
      (supertag-automation--execute-actions default-actions node-id context))))

(defun supertag-automation-action-update-property (node-id params)
  "Update NODE-ID's Org property from PARAMS, then refresh its Projection."
  (let ((property (plist-get params :property))
        (value (plist-get params :value)))
    (unless node-id
      (user-error "Automation :update-property requires a node ID"))
    (unless property
      (user-error "Automation :update-property requires :property"))
    (supertag-service-org-set-property node-id property value)))

(defun supertag-automation-action-update-todo-state (node-id params)
  "Update the TODO state of a node.
PARAMS should contain :state with the new TODO keyword (e.g., \"DONE\")."
  (when-let ((state (plist-get params :state)))
    (supertag-service-org-set-todo-state node-id state)))

(defun supertag-automation--semantic-tag-id (tag)
  "Return TAG's Semantic Tag ID, or TAG when it is unresolved."
  (or (and (supertag-tag-get tag) tag)
      (supertag-tag-resolve-occurrence tag)
      tag))

(defun supertag-automation-action-add-tag (node-id params)
  "Add a tag to the node.
Append inline #tag at the end of the headline when it is not present."
  (when (and node-id)
    (when-let ((tag-name (plist-get params :tag)))
      (let ((tag-id (supertag-automation--semantic-tag-id tag-name)))
        (unless (supertag-tag-get tag-id)
          (setq tag-id (supertag-tag-ensure tag-name)))
        (supertag-service-org-add-tag node-id tag-id 'end)
        (supertag-automation--log
         "Automation: Added tag '%s' to node %s" tag-name node-id)))))

(defun supertag-automation-action-remove-tag (node-id params)
  "Remove a tag from the node.
Uses the same Org-first path as UI commands."
  (when (and node-id)
    (when-let ((tag-name (plist-get params :tag)))
      (if-let* ((tag-id
                 (or (and (supertag-tag-get tag-name) tag-name)
                     (supertag-tag-resolve-occurrence tag-name))))
          (progn
            (supertag-service-org-remove-tag node-id tag-id)
            (supertag-automation--log
             "Automation: Removed tag '%s' from node %s" tag-name node-id))
        (supertag-automation--log
         "SKIP(remove-tag): tag '%s' is unresolved" tag-name)))))

(defun supertag-automation-action-call-function (node-id params context)
  "Call a custom function with node context."
  (let ((function (plist-get params :function))
        (args (plist-get params :args)))
    (when (functionp function)
      (apply function node-id context args))))

(defun supertag-automation-action-move-node (node-id params)
  "Move NODE-ID to target file via org service."
  (let ((target-file (plist-get params :target-file))
        (leave-link (plist-get params :leave-link))
        (target-level (plist-get params :target-level)))
    (unless node-id
      (user-error "Automation :move-node requires a node ID"))
    (unless (and (stringp target-file) (not (string-empty-p target-file)))
      (user-error "Automation :move-node requires :target-file"))
    (let ((source-file (supertag-node-location-file node-id)))
      (unless source-file
        (user-error "Cannot resolve source for node %s" node-id))
      (if (or (equal (expand-file-name source-file)
                     (expand-file-name target-file))
              (and (file-exists-p target-file)
                   (file-equal-p source-file target-file)))
          (supertag-automation--log
           "SKIP(:move-node): node %s already in %s" node-id target-file)
        (supertag-service-org-move-node-to-file
         node-id target-file leave-link target-level)))))

(defun supertag-automation-action-create-node (params)
  "Create an Org node.  PARAMS requires :title and :target-file; :tags is optional."
  (let ((title (plist-get params :title))
        (tags (plist-get params :tags))
        (target-file (plist-get params :target-file)))
    (let ((node-id
           (supertag-service-org-create-node target-file title tags)))
      (supertag-automation--log
       "Created node %s (title=%s tags=%S target=%s)"
       node-id title tags target-file)
      node-id)))


;;; --- Formula Field Engine ---

(defun supertag-automation-calculate-formula (entity-id formula-field)
  "Calculate formula field value for an entity.
ENTITY-ID is the target entity.
FORMULA-FIELD is the field configuration with formula."
  (let* ((formula (plist-get formula-field :formula))
         (field-name (plist-get formula-field :name)))

    (when formula
      (let ((result (supertag-automation--evaluate-formula formula entity-id)))
        (when result
          ;; Formula fields are for view-time rendering only in System 2.0
          result)))))

(defun supertag-automation--evaluate-formula (formula entity-id)
  "Evaluate FORMULA for ENTITY-ID via the shared formula service.
Supports {{...}} placeholders, arithmetic and helper functions."
  (let ((entity (or (supertag-query-node entity-id)
                    (supertag-tag-get entity-id))))
    (condition-case nil
        (supertag-formula-evaluate formula entity)
      (error 0))))

;;; --- Event Integration (Updated for Sync Processing) ---

(defun supertag-automation--queue-event (handler-fn &rest args)
  "Queue an automation event for asynchronous processing (legacy support).
HANDLER-FN is the function to call, ARGS are its arguments.
DEPRECATED: Use synchronous processing via supertag-automation-sync instead."
  (when supertag-automation--enabled
    (push (cons handler-fn args) supertag-automation--event-queue)
    ;; Schedule processing if not already scheduled
    (unless supertag-automation--processing-timer
      (setq supertag-automation--processing-timer
            (run-at-time 0.001 nil #'supertag-automation--process-event-queue)))))

(defun supertag-automation--process-event-queue ()
  "Process all queued automation events (legacy support)."
  (setq supertag-automation--processing-timer nil)
  (when supertag-automation--event-queue)
    (let ((events (nreverse supertag-automation--event-queue)))
      (setq supertag-automation--event-queue nil)
      (dolist (event events)
        (let ((handler (car event))
              (args (cdr event)))
          (apply handler args)))))

(defun supertag-automation--handle-entity-change (path old-value new-value)
  "Handle entity changes and trigger automation.
This integrates with the event notification system.
Events are now processed synchronously via the new commit system."
  ;; Ensure sync module is loaded and route through the new sync system
  (let ((operation (cond
                    ;; Determine operation type from context
                    ((null old-value) :create)
                    ((null new-value) :delete)
                    (t :update)))
        (collection (car path))
        (id (cadr path))
        (payload new-value)
        (previous old-value))
    ;; Preserve the projected property path as event metadata.
    (supertag-automation-sync-handle-event
     operation collection id payload previous (list :path path))))

(defun supertag-automation--handle-entity-change-sync (path old-value new-value)
  "Synchronously handle entity changes (called from event queue).
This is the actual handler that was previously called directly."
  (when (listp path)
    (let* ((node-id (cadr path))
           (entity-type (car path))
           ;; Detect tag change under :nodes path like (:nodes ID :tags ...)
           (tags-change-under-node (and (eq entity-type :nodes) (member :tags path))))
      ;; Aggressive Re-entrancy Guard: Do not run any automation on a node
      ;; if it is already being processed.
      (when (and supertag-automation--enabled
                 (not (cl-member node-id supertag-automation--processing-queue :test 'equal)))
        (unwind-protect
            (progn
              ;; Add the node-id to the processing queue.
              (push node-id supertag-automation--processing-queue)
              (when (and (listp path) (>= (length path) 2))
                (cond
                 ;; Generic node changes (exclude explicit tag list change)
                 ((and (eq entity-type :nodes) (not tags-change-under-node))
                  (supertag-automation--handle-node-change path old-value new-value))
                 ;; Tag list changes (explicit :tags path or :nodes ... :tags ...)
                 ((or (eq entity-type :tags) tags-change-under-node)
                  (let* ((old-tags (if (listp old-value)
                                       old-value
                                     (let ((nd (supertag-query-node node-id)))
                                       (plist-get nd :tags))))
                         (new-tags (if (listp new-value)
                                       new-value
                                     (let ((nd (supertag-query-node node-id)))
                                       (plist-get nd :tags)))))
                    (supertag-automation--handle-tag-change node-id old-tags new-tags))))))
          ;; Always remove the node-id from the queue when done.
          (setq supertag-automation--processing-queue
                (cl-delete node-id supertag-automation--processing-queue :test 'equal)))))))

(defun supertag-automation--handle-node-change (path old-value new-value)
  "Handle node changes and trigger relevant automation."
  (let ((rule-ids (supertag--get-rules-from-index path)))
            (dolist (rule-id rule-ids)
              (when-let ((rule (supertag-rule-get rule-id)))
                (let ((trig (plist-get rule :trigger)))
          ;; Runtime trigger gate: skip tag-only triggers here
          (if (and (consp trig) (memq (car trig) '(:on-tag-added :on-tag-removed)))
                      nil
                    (let ((supertag-automation--current-event (list :path path :old old-value :new new-value)))
                      (if (and (supertag-automation--trigger-match-p trig supertag-automation--current-event)
                               (supertag-automation--evaluate-condition (plist-get rule :condition) (cadr path)))
                          (progn
                            (supertag-automation--log "Condition passed for rule %s. Executing actions." rule-id)
                            (supertag-automation--log "INDEX-MATCH: Event %S triggered rule %S" path rule-id)
                            (supertag-rule-execute rule (cadr path)
                                                   (list :path path :old old-value :new new-value)))
                        ))))))))

(defun supertag-automation--handle-tag-change (node-id old-tags new-tags)
  "Detect added/removed tags and execute runtime-gated tag rules."
  (let* ((resolve (lambda (value)
                    (cond
                     ((listp value) value)
                     (t (let ((nd (supertag-query-node node-id)))
                          (plist-get nd :tags))))))
         (old (cl-remove-duplicates (copy-sequence (or (funcall resolve old-tags) '()))
                                    :test 'equal))
         (new (cl-remove-duplicates (copy-sequence (or (funcall resolve new-tags) '()))
                                    :test 'equal))
         (added (cl-set-difference new old :test 'equal))
         (removed (cl-set-difference old new :test 'equal)))
    (dolist (tag added)
      (supertag-automation--execute-tag-trigger node-id tag :added))
    (dolist (tag removed)
      (supertag-automation--execute-tag-trigger node-id tag :removed))))

(defun supertag-automation--execute-tag-trigger (node-id tag-name op)
  "Execute rules gated by :trigger (:on-tag-added TAG) or (:on-tag-removed TAG)."
  (supertag-automation--ensure-rule-index)
  (let ((candidate (gethash tag-name supertag--rule-index)))
    (when candidate
      (dolist (rule-id candidate)
        (when-let ((rule (supertag-rule-get rule-id)))
          (pcase (plist-get rule :trigger)
                    (`(:on-tag-added ,tn)
                     (when (and (eq op :added) (equal tn tag-name)
                                (let ((supertag-automation--current-event (list :tag-event op :tag tag-name)))
                                  (supertag-automation--evaluate-condition (plist-get rule :condition) node-id)))
                       (supertag-automation--log "INDEX-MATCH: Tag added '%s' triggered rule %s" tag-name rule-id)
                       (supertag-rule-execute rule node-id (list :tag-event :added :tag tag-name))))
                    (`(:on-tag-removed ,tn)
                     (when (and (eq op :removed) (equal tn tag-name)
                                (let ((supertag-automation--current-event (list :tag-event op :tag tag-name)))
                                  (supertag-automation--evaluate-condition (plist-get rule :condition) node-id)))
                       (supertag-automation--log "INDEX-MATCH: Tag removed '%s' triggered rule %s" tag-name rule-id)
                       (supertag-rule-execute rule node-id (list :tag-event :removed :tag tag-name))))
                    (_ nil)))))))

;; Helper functions for condition evaluation


(defun supertag-automation--property-changed-p (name)
  "Return non-nil when Org property NAME changed in the current event."
  (let ((path (plist-get supertag-automation--current-event :path)))
    (and (eq (car path) :nodes) (eq (nth 2 path) :properties)
         (eq (nth 3 path) (supertag-query-normalize-property-key name)))))

(defun supertag-automation--condition-to-query (condition)
  "Convert a legacy automation CONDITION to query-sexp syntax.
Returns the converted sexp, or nil when CONDITION (or any part of it)
uses a form with no query equivalent: event conditions
(property-changed), test conditions,
and keyword property reads.  New-style query conditions pass through
unchanged; and/or/not are shared by both grammars."
  (cond
   ((null condition) t)
   ((not (consp condition)) condition)
   ((memq (car condition) '(and or))
    (let ((converted (mapcar #'supertag-automation--condition-to-query
                             (cdr condition))))
      (and (not (memq nil converted))
           (cons (car condition) converted))))
   ((eq (car condition) 'not)
    (let ((converted (supertag-automation--condition-to-query
                      (cadr condition))))
      (and converted (list 'not converted))))
   ((eq (car condition) 'quote)
    (supertag-automation--condition-to-query (cadr condition)))
   ((memq (car condition) '(has-tag tag))
    (list 'tag (cadr condition)))
   ((eq (car condition) 'has-any-tag)
    (cons 'or (mapcar (lambda (tag) (list 'tag tag)) (cdr condition))))
   ((eq (car condition) 'has-all-tags)
    (cons 'and (mapcar (lambda (tag) (list 'tag tag)) (cdr condition))))

   ((eq (car condition) 'property-equals)
    (list 'property (substring (symbol-name (supertag-query-normalize-property-key
                                           (cadr condition))) 1) (caddr condition)))
   ((memq (car condition) '(property-changed property-test))
    nil)
   ;; Query operators without a legacy equivalent pass through.
   ((memq (car condition) '(property term after before between recent-days
                            in-month in-year sort-by sum count avg
                            min max first last unique-count concat
                            group-by))
    condition)
   (t nil)))

(defun supertag-automation--eval-single-condition (cond-form node-data)
  "Evaluate a single condition COND-FORM against NODE-DATA.
Returns t if condition passes, nil otherwise."
  (let* ((tags (plist-get node-data :tags))
         (props (plist-get node-data :properties))
         (node-id (plist-get node-data :id))
         (op (car cond-form))
         (args (cdr cond-form)))

    (pcase op
      ;; Logical operators: each child converts to the query grammar when
      ;; possible (the engine decides), otherwise falls back to the
      ;; dedicated evaluator for event/test forms.
      ('and
       (cl-every (lambda (sub-cond)
                   (let ((query (supertag-automation--condition-to-query
                                 sub-cond)))
                     (if query
                         (member node-id (supertag-query-node-ids query))
                       (supertag-automation--eval-single-condition
                        sub-cond node-data))))
                 args))

      ('or
       (cl-some (lambda (sub-cond)
                  (let ((query (supertag-automation--condition-to-query
                                sub-cond)))
                    (if query
                        (member node-id (supertag-query-node-ids query))
                      (supertag-automation--eval-single-condition
                       sub-cond node-data))))
                args))

      ('not
       (let ((query (supertag-automation--condition-to-query (car args))))
         (if query
             (not (member node-id (supertag-query-node-ids query)))
           (not (supertag-automation--eval-single-condition
                 (car args) node-data)))))

      ;; Unwrap quoted conditions
      ('quote
       (supertag-automation--eval-single-condition (cadr cond-form) node-data))

      ;; Tag conditions migrated to the query grammar; only the forms
      ;; without a query equivalent remain below (event conditions,
      ;; tests, and keyword property reads).

      ;; Property conditions
      ('property-equals
       (equal (supertag-query-property-value node-id (car args)) (cadr args)))

      ('property-changed
       (let ((key (car args)))
         (if (or (keywordp key) (stringp key))
             (supertag-automation--property-changed-p key)
           nil)))

      ('property-test
       (when (functionp (cadr args))
         (apply (cadr args) (supertag-query-property-value node-id (car args)) (cddr args))))

)))

(defun supertag-automation--evaluate-condition (condition node-id)
  "Evaluate a rule CONDITION for NODE-ID.
Returns t if condition passes, nil otherwise.
Empty/nil conditions always return t."
  (if (not condition)
      t
    (let ((node-data (supertag-query-node node-id)))
      (unless node-data
        (message "Automation Warning: Node %s not found" node-id)
        (setq node-data (list :id node-id :tags nil :properties nil)))

      ;; Handle both quoted and unquoted conditions
      (let ((cond-to-eval (if (and (consp condition)
                                   (eq (car condition) 'quote))
                              (cadr condition)
                            condition)))
        (cond
         ;; Empty/nil condition always passes
         ((null cond-to-eval) t)
         ;; 't means always true (unconditional)
         ((eq cond-to-eval t) t)
         ;; Must be a list form
         ((not (consp cond-to-eval))
          (message "Automation Warning: Condition is not a list: %S" cond-to-eval)
          nil)
         (t
          (let ((query (supertag-automation--condition-to-query
                        cond-to-eval)))
            (if query
                ;; Query grammar (new or converted): reuse the query
                ;; engine so automation and query blocks agree on the
                ;; matched set.
                (member node-id (supertag-query-node-ids query))
              ;; Forms without a query equivalent (event conditions,
              ;; tests, keyword property reads).
              (supertag-automation--eval-single-condition
               cond-to-eval node-data)))))))))

;;; --- System Integration ---

(defvar supertag-automation--subscribed nil
  "Non-nil once the Store event callback has been registered.")

(defun supertag-automation-init ()
  "Initialize the unified automation system.
Sets up rule indexing and event handlers for the automation engine."

  ;; Clear all state
  (supertag-automation-clear-rule-index)
  (setq supertag-automation--processing-queue nil)

  ;; Build the rule index for the first time
  (supertag-rebuild-rule-index)

  ;; Register all scheduled rules with scheduler (user may start scheduler separately)
  (supertag-automation--register-all-scheduled)

  ;; Subscribe to entity changes
  (when (and (not supertag-automation--subscribed) (fboundp 'supertag-subscribe))
    (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change)
    (setq supertag-automation--subscribed t))

  (setq supertag-automation--enabled t))

(defun supertag-automation-cleanup ()
  "Cleanup the unified automation system."
  (setq supertag-automation--enabled nil)
  (supertag-automation-clear-rule-index)
  (setq supertag-automation--processing-queue nil)
  (message "Unified automation system cleaned up"))

(defun supertag-automation--after-store-load ()
  "Refresh Automation's derived state after a persisted Store is loaded."
  (condition-case err
      (progn
        (supertag-automation-clear-rule-index)
        (supertag-rebuild-rule-index)
        (supertag-automation--register-all-scheduled))
    (error
     (message "[Supertag Automation] Failed to refresh loaded rules: %S" err))))

;;; --- Event Adaptation ---

;;; Customization

(defgroup supertag-automation-sync nil
  "Synchronous automation execution settings for Supertag."
  :group 'supertag)


;;; --- Synchronous Event Processing State ---

(defvar supertag-automation-sync--processing-stack nil
  "Stack of currently processing node IDs to prevent infinite loops.")

(defvar supertag-automation-sync--enabled t
  "Enable/disable synchronous automation processing.")

(defvar supertag-automation-sync--async-enabled t
  "Enable async fallback for large installations.")

(defvar supertag-automation-sync--batch-size 50
  "Maximum number of operations to process before forcing async fallback.")

;;; --- Main Synchronous Event Handler ---

(defun supertag-automation-sync-handle-event (operation collection id payload previous &rest metadata)
  "Handle store events synchronously using the new commit system.
This function replaces the old queue-based event processing.

OPERATION is the operation type (:create, :update, :delete).
COLLECTION is the target collection (:nodes or :tags).
ID is the entity identifier.
PAYLOAD is the operation data.
PREVIOUS is the previous entity value.
METADATA is additional operation context."

  (when supertag-automation-sync--enabled
    (pcase collection
      (:nodes
       (supertag-automation-sync--handle-node-event operation id payload previous metadata))
      (:tags
       (supertag-automation-sync--handle-tag-event operation id payload previous metadata)))))

(defun supertag-automation-sync--handle-node-event (operation id payload previous metadata)
  "Handle node-related events synchronously."
  (when id
    (if (supertag-automation-sync--should-process-async-p)
        ;; Fallback to async processing for large operations
        (supertag-automation-sync--queue-async-handler
         (lambda () (supertag-automation-sync--handle-node-event operation id payload previous metadata)))

      ;; Process synchronously
      (supertag-automation-sync--with-protection id
        (lambda ()
          (pcase operation
            (:update
             (supertag-automation-sync--process-node-change id previous payload))
            (:create
             (supertag-automation-sync--process-node-creation id payload))
            (:delete
             (supertag-automation-sync--process-node-deletion id previous))
            (_ nil)))))))


(defun supertag-automation-sync--handle-tag-event (operation id payload previous metadata)
  "Handle tag-related events synchronously."
  (when id
    (let ((node-ids (supertag-automation-sync--get-affected-node-ids id operation previous)))
      (dolist (node-id node-ids)
        (supertag-automation-sync--with-protection node-id
          (lambda ()
            (supertag-automation-sync--process-tag-change node-id operation id)))))))

;;; --- Node Change Processing ---

(defun supertag-automation-sync--normalize-tag-list (value)
  "Normalize VALUE into a tag list."
  (cond
   ((null value) nil)
   ((listp value) value)
   (t (list value))))

(defun supertag-automation-sync--diff-tags (old-tags new-tags)
  "Return (ADDED . REMOVED) between OLD-TAGS and NEW-TAGS."
  (let* ((old (cl-remove-duplicates (copy-sequence (supertag-automation-sync--normalize-tag-list old-tags))
                                    :test 'equal))
         (new (cl-remove-duplicates (copy-sequence (supertag-automation-sync--normalize-tag-list new-tags))
                                    :test 'equal))
         (added (cl-set-difference new old :test 'equal))
         (removed (cl-set-difference old new :test 'equal)))
    (cons added removed)))

(defun supertag-automation-sync--condition-contains-op-p (condition ops)
  "Return non-nil when CONDITION contains any operator in OPS.

OPS is a list of symbols, e.g. '(property-changed)."
  (when condition
    (let ((targets (if (listp ops) ops (list ops)))
          (found nil))
      (cl-labels ((walk (form)
                        (when (and (not found) (consp form))
                          (pcase (car form)
                            ('quote (walk (cadr form)))
                            (_
                             (when (memq (car form) targets)
                               (setq found t))
                             (dolist (sub (cdr form))
                               (walk sub)))))))
        (walk condition))
      found)))

(defun supertag-automation-sync--execute-rule-for-event (rule node-id event)
  "Execute RULE for NODE-ID under EVENT when trigger/condition pass."
  (let* ((trigger (plist-get rule :trigger))
         (condition (plist-get rule :condition))
         (supertag-automation--current-event event))
    (when (and (supertag-automation--trigger-match-p trigger event)
               (supertag-automation--evaluate-condition condition node-id))
      (supertag-rule-execute rule node-id event))))

(defun supertag-automation-sync--execute-tag-trigger (node-id tag-name op)
  "Execute tag-trigger rules for NODE-ID when TAG-NAME changes.
OP must be :added or :removed."
  (supertag-automation--ensure-rule-index)
  (when (and (boundp 'supertag--rule-index) tag-name)
    (when-let ((candidate (gethash tag-name supertag--rule-index)))
      (dolist (rule-id (cl-remove-duplicates candidate :test #'equal))
        (when-let ((rule (supertag-automation-get rule-id)))
          (pcase (plist-get rule :trigger)
            (`(:on-tag-added ,tn)
             (when (and (eq op :added) (equal tn tag-name))
               (supertag-automation-sync--execute-rule-for-event
                rule node-id (list :tag-event :added :tag tag-name))))
            (`(:on-tag-removed ,tn)
             (when (and (eq op :removed) (equal tn tag-name))
               (supertag-automation-sync--execute-rule-for-event
                rule node-id (list :tag-event :removed :tag tag-name))))
            (_ nil)))))))

(defun supertag-automation-sync--make-property-event (node-id prop old-val new-val)
  "Build a property-change event for NODE-ID/PROP."
  (list :path (list :nodes node-id :properties prop) :old old-val :new new-val))

(defun supertag-automation-sync--process-node-change (node-id old-node new-node)
  "Process a node change and trigger relevant automation rules."
  (let* ((old-tags (plist-get old-node :tags))
         (new-tags (plist-get new-node :tags))
         (tag-diff (supertag-automation-sync--diff-tags old-tags new-tags))
         (added-tags (car tag-diff))
         (removed-tags (cdr tag-diff))
         (changed-props (supertag-automation-sync--get-changed-properties old-node new-node))
         (rule-ids (supertag-automation-sync--get-relevant-rules node-id old-node new-node)))

    ;; 1) Tag triggers (runtime-gated): (:on-tag-added ...) / (:on-tag-removed ...)
    (dolist (tag added-tags)
      (supertag-automation-sync--execute-tag-trigger node-id tag :added))
    (dolist (tag removed-tags)
      (supertag-automation-sync--execute-tag-trigger node-id tag :removed))

    ;; 2) Property-change driven rules: provide precise :path so
    ;; (property-changed ...) can work deterministically.
    (when changed-props
      (let* ((old-props (plist-get old-node :properties))
             (new-props (plist-get new-node :properties))
             (representative (car changed-props))
             (representative-event
              (supertag-automation-sync--make-property-event
               node-id representative
               (plist-get old-props representative)
               (plist-get new-props representative))))
        (dolist (rule-id rule-ids)
          (when-let ((rule (supertag-automation-get rule-id)))
            ;; Skip tag-only triggers here; they are handled above.
            (let ((trigger (plist-get rule :trigger)))
              (unless (and (consp trigger) (memq (car trigger) '(:on-tag-added :on-tag-removed)))
                (if (supertag-automation-sync--condition-contains-op-p
                     (plist-get rule :condition)
                     '(property-changed))
                    ;; Change-sensitive rules: evaluate once per changed property.
                    (dolist (prop changed-props)
                      (supertag-automation-sync--execute-rule-for-event
                       rule node-id
                       (supertag-automation-sync--make-property-event
                        node-id prop
                        (plist-get old-props prop)
                        (plist-get new-props prop))))
                  ;; Generic rules: evaluate once per update.
                  (supertag-automation-sync--execute-rule-for-event
                   rule node-id representative-event))))))))

    ;; 3) Non-property changes (e.g., title/metadata) with no tag/property delta:
    ;; fall back to a node-change event.
    (when (and (null changed-props)
               (null added-tags)
               (null removed-tags)
               (not (equal old-node new-node)))
      (let ((node-event (list :path (list :nodes node-id) :old old-node :new new-node)))
        (dolist (rule-id rule-ids)
          (when-let ((rule (supertag-automation-get rule-id)))
            (let ((trigger (plist-get rule :trigger)))
              (unless (and (consp trigger) (memq (car trigger) '(:on-tag-added :on-tag-removed)))
                (supertag-automation-sync--execute-rule-for-event rule node-id node-event)))))))))

(defun supertag-automation-sync--process-node-creation (node-id payload)
  "Process a node creation and trigger relevant automation rules."
  (let* ((node-data (or payload (supertag-query-node node-id)))
         (rule-ids (supertag-automation-sync--get-relevant-rules node-id nil node-data)))
    ;; Treat initial tags as :added events (first time the node is tagged).
    (dolist (tag (supertag-automation-sync--normalize-tag-list (plist-get node-data :tags)))
      (supertag-automation-sync--execute-tag-trigger node-id tag :added))
    (dolist (rule-id rule-ids)
      (when-let ((rule (supertag-automation-get rule-id)))
        ;; Skip tag-only triggers here; they are handled above.
        (let ((trigger (plist-get rule :trigger)))
          (unless (and (consp trigger) (memq (car trigger) '(:on-tag-added :on-tag-removed)))
            (supertag-automation-sync--execute-rule-for-event
             rule node-id (list :path (list :nodes node-id) :old nil :new node-data))))))))

(defun supertag-automation-sync--process-node-deletion (node-id old-node)
  "Process a node deletion and trigger relevant automation rules."
  (let ((rule-ids (supertag-automation-sync--get-relevant-rules node-id old-node nil)))
    (dolist (rule-id rule-ids)
      (when-let ((rule (supertag-automation-get rule-id)))
        ;; Skip tag-only triggers; deletion is not a tag-change event.
        (let ((trigger (plist-get rule :trigger)))
          (unless (and (consp trigger) (memq (car trigger) '(:on-tag-added :on-tag-removed)))
            (supertag-automation-sync--execute-rule-for-event
             rule node-id (list :path (list :nodes node-id) :old old-node :new nil))))))))

(defun supertag-automation-sync--process-tag-change (node-id operation tag-id)
  "Process a tag change on a node and trigger relevant automation rules."
  (let ((op (pcase operation
              ((or :added :add-tag) :added)
              ((or :removed :remove-tag) :removed)
              (_ operation))))
    (when (memq op '(:added :removed))
      (supertag-automation-sync--execute-tag-trigger node-id tag-id op))))


;;; --- Rule Lookup and Matching ---

(defun supertag-automation-sync--get-relevant-rules (node-id old-node new-node)
  "Get automation rules relevant to a node change.
This is an optimized version of the original rule lookup."
  (supertag-automation--ensure-rule-index)
  (let ((rules '())
        (node-data (or new-node old-node (supertag-query-node node-id))))
    (when node-data
      ;; Get rules based on node tags - safe lookup
      (let ((node-tags (plist-get node-data :tags)))
        (when (and node-tags (boundp 'supertag--rule-index))
          (dolist (tag node-tags)
            (when-let ((tag-rules (gethash tag supertag--rule-index)))
              (setq rules (append tag-rules rules))))))

      ;; Get rules based on changed properties - safe lookup
      (when (and old-node new-node (boundp 'supertag--rule-index))
        (let ((changed-props (supertag-automation-sync--get-changed-properties old-node new-node)))
          (dolist (prop changed-props)
            (when-let ((prop-rules (gethash prop supertag--rule-index)))
              (setq rules (append prop-rules rules)))))))

    ;; Remove duplicates and filter by trigger type
    (cl-remove-duplicates rules :test #'equal)))

(defun supertag-automation-sync--get-tag-trigger-rules (tag-id operation)
  "Get rules triggered by tag operations."
  (supertag-automation--ensure-rule-index)
  (when (boundp 'supertag--rule-index)
    (let ((candidate-rules (gethash tag-id supertag--rule-index)))
      (when candidate-rules
        (cl-remove-if-not
         (lambda (rule-id)
           (when-let ((rule (supertag-automation-get rule-id)))
             (pcase (plist-get rule :trigger)
               (`(:on-tag-added ,tn) (and (memq operation '(:added :add-tag)) (equal tn tag-id)))
               (`(:on-tag-removed ,tn) (and (memq operation '(:removed :remove-tag)) (equal tn tag-id)))
               (_ nil))))
         candidate-rules)))))

(defun supertag-automation-sync--get-changed-properties (old-node new-node)
  "Get list of changed properties between OLD-NODE and NEW-NODE."
  (let ((changed '())
        (old-props (or (plist-get old-node :properties) '()))
        (new-props (or (plist-get new-node :properties) '())))
    ;; Compare properties
    (cl-loop for (key value) on new-props by #'cddr do
             (unless (equal (plist-get old-props key) value)
               (push key changed)))
    ;; Check for removed properties
    (cl-loop for (key _value) on old-props by #'cddr do
             (unless (plist-member new-props key)
               (push key changed)))
    (cl-remove-duplicates changed :test #'equal)))

(defun supertag-automation-sync--get-affected-node-ids (tag-id operation previous-tags)
  "Get list of node IDs affected by a tag operation."
  (ignore operation previous-tags)
  (mapcar #'car
          (supertag-query-nodes
           (lambda (_id node-data)
             (and (plist-get node-data :tags)
                  (member tag-id (plist-get node-data :tags)))))))

;;; --- Recursion Protection and Async Fallback ---

(defun supertag-automation-sync--with-protection (node-id thunk)
  "Execute THUNK with recursion protection for NODE-ID."
  (if (cl-member node-id supertag-automation-sync--processing-stack)
      (message "Automation: Skipping recursive processing for node %s" node-id)
    (unwind-protect
        (progn
          (push node-id supertag-automation-sync--processing-stack)
          (funcall thunk))
      (setq supertag-automation-sync--processing-stack
            (cl-delete node-id supertag-automation-sync--processing-stack :test #'equal)))))

(defun supertag-automation-sync--should-process-async-p ()
  "Determine if the current operation should be processed asynchronously."
  (and supertag-automation-sync--async-enabled
       (> (length supertag-automation-sync--processing-stack) supertag-automation-sync--batch-size)))

(defun supertag-automation-sync--queue-async-handler (handler)
  "Queue an async handler for later processing."
  (when supertag-automation-sync--async-enabled
    (push handler supertag-automation--event-queue)
    (unless supertag-automation--processing-timer
      (setq supertag-automation--processing-timer
            (run-at-time 0.001 nil #'supertag-automation-sync--process-async-queue)))))

(defun supertag-automation-sync--process-async-queue ()
  "Process all queued async handlers."
  (setq supertag-automation--processing-timer nil)
  (when supertag-automation--event-queue
    (let ((handlers (nreverse supertag-automation--event-queue)))
      (setq supertag-automation--event-queue nil)
      (dolist (handler handlers)
        (condition-case err
            (funcall handler)
          (error (message "Async automation handler failed: %S" err)))))))

;;; --- Integration with Commit System ---


;;; --- Configuration and Utilities ---

(defun supertag-automation-sync-enable ()
  "Enable synchronous automation processing."
  (setq supertag-automation-sync--enabled t)
  (message "Synchronous automation processing enabled"))

(defun supertag-automation-sync-disable ()
  "Disable synchronous automation processing."
  (setq supertag-automation-sync--enabled nil)
  (message "Synchronous automation processing disabled"))

(defun supertag-automation-sync-toggle-async ()
  "Toggle async fallback for large operations."
  (setq supertag-automation-sync--async-enabled (not supertag-automation-sync--async-enabled))
  (message "Async fallback %s" (if supertag-automation-sync--async-enabled "enabled" "disabled")))

(defun supertag-automation-sync--reset-runtime ()
  "Discard pending automation-sync work at a vault boundary."
  (setq supertag-automation-sync--processing-stack nil))


;;; --- Scheduled Tasks ---

;;; === Configuration ===

(defcustom supertag-scheduler-check-interval 300
  "Interval in seconds for master timer to check for pending tasks.
300 seconds (5 minutes) provides good balance between accuracy and resource usage."
  :type 'integer
  :group 'supertag-services)

;;; === Core State Management ===

(defvar supertag-scheduler--tasks (make-hash-table :test 'equal)
  "Central registry for all scheduled tasks.
Key: Unique task ID (symbol)
Value: Task plist with :type, :function, and scheduling parameters")

(defvar supertag-scheduler--master-timer nil
  "Master timer that periodically calls `supertag-scheduler--check-tasks`.")

(defvar supertag-scheduler--state-file nil
  "File to persist state of daily tasks (last run times).")

(defun supertag-scheduler--state-path ()
  (supertag-data-file "scheduler-state.json"))

;;; === State Persistence ===

(defun supertag-scheduler--save-state ()
  "Save task states (last-run times) to persistent storage."
  (let ((state (make-hash-table :test 'equal)))
    (maphash (lambda (id task)
               (when-let ((last-run (plist-get task :last-run)))
                 (puthash (symbol-name id) last-run state)))
             supertag-scheduler--tasks)
    (with-temp-buffer
      (insert (json-encode state))
      (write-file (supertag-scheduler--state-path) nil))))

(defun supertag-scheduler--load-state ()
  "Load task states from persistent storage."
  (when (file-exists-p (supertag-scheduler--state-path))
    (let ((json-content (with-temp-buffer
                          (insert-file-contents (supertag-scheduler--state-path))
                          (buffer-string))))
      (when (> (length (string-trim json-content)) 0)
        (let ((state (json-parse-string
                      json-content :object-type 'hash-table
                      :array-type 'list :null-object nil)))
          (maphash (lambda (id task)
                     (let ((last-run (gethash (symbol-name id) state)))
                       (when last-run
                         (plist-put task :last-run last-run)
                         (puthash id task supertag-scheduler--tasks))))
                   supertag-scheduler--tasks))))))

;;; === Public API ===

(defun supertag-scheduler-register-task (id type function &rest args)
  "Register a task with the central scheduler.
ID: Unique symbol identifying the task
TYPE: :interval or :daily
FUNCTION: Function to call when task runs
ARGS: Plist with scheduling parameters:
  - :interval seconds for interval tasks
  - :time HH:MM string for daily tasks"
  (let ((task (list :type type :function function))
        (previous (gethash id supertag-scheduler--tasks)))
    (pcase type
      (:interval
       (let ((interval (plist-get args :interval)))
         (unless (and (integerp interval) (> interval 0))
           (error "Invalid interval for task %s" id))
         (setq task (plist-put task :interval interval))))
      (:daily
       (let ((time (plist-get args :time))
             (days (plist-get args :days-of-week)))
         (unless (and (stringp time) (string-match "^[0-2][0-9]:[0-5][0-9]$" time))
           (error "Invalid time format for task %s. Must be HH:MM" id))
         (setq task (plist-put task :time time))
         (when days
           (setq task (plist-put task :days-of-week days))))))
    (when-let* ((last-run (plist-get previous :last-run)))
      (setq task (plist-put task :last-run last-run)))
    (puthash id task supertag-scheduler--tasks)
    (message "[Supertag Scheduler] Task '%s' registered." id)))

(defun supertag-scheduler-deregister-task (id)
  "Remove a task from the scheduler.
ID: Unique symbol of task to remove."
  (remhash id supertag-scheduler--tasks)
  (message "[Supertag Scheduler] Task '%s' deregistered." id))

(defun supertag-scheduler-start ()
  "Start the master scheduler timer.
Should be called once during Supertag initialization."
  (unless (timerp supertag-scheduler--master-timer)
    (supertag-scheduler--load-state)
    (setq supertag-scheduler--master-timer
          (run-with-timer 0
                          supertag-scheduler-check-interval
                          #'supertag-scheduler--check-tasks))))

(defun supertag-scheduler-stop ()
  "Stop the master scheduler timer."
  (when (timerp supertag-scheduler--master-timer)
    (cancel-timer supertag-scheduler--master-timer)
    (setq supertag-scheduler--master-timer nil)
    (supertag-scheduler--save-state)
    (message "Supertag Scheduler stopped.")))

(defun supertag-scheduler-list-tasks ()
  "Display all registered tasks and their status."
  (let ((tasks '()))
    (maphash (lambda (id task)
               (push (format "- %s: %s" id task) tasks))
             supertag-scheduler--tasks)
    (message "[Supertag Scheduler] Registered tasks:\n%s"
             (mapconcat #'identity (nreverse tasks) "\n"))))

;;; === Core Scheduling Logic ===

(defun supertag-scheduler--check-tasks ()
  "Master timer function - check and execute pending tasks.
Prevents thundering herd by running only one daily task per cycle."
  (let ((now (supertag-current-time))
        (daily-task-ran nil))
    (maphash
     (lambda (id task)
       (pcase (plist-get task :type)
         (:interval
          (let ((interval (plist-get task :interval))
                (last-run (plist-get task :last-run)))
            (when (or (not last-run)
                      (>= (time-to-seconds (time-subtract now last-run)) interval))
              (supertag-scheduler--run-task id task now))))
         (:daily
          (unless daily-task-ran
            (let* ((today (format-time-string "%Y-%m-%d" now))
                   (current-time (format-time-string "%H:%M" now))
                   (scheduled-time (plist-get task :time))
                   (last-run (plist-get task :last-run))
                   (days (plist-get task :days-of-week)))
              (when (and (string-greaterp current-time scheduled-time)
                         (not (equal last-run today))
                         (or (null days)
                             (memq (string-to-number (format-time-string "%u" now))
                                   days)))
                (supertag-scheduler--run-task id task now)
                (setq daily-task-ran t)))))))
     supertag-scheduler--tasks)))

(defun supertag-scheduler--run-task (id task now)
  "Execute a task and update its state."
  (let ((func (plist-get task :function)))
    (message "[Supertag Scheduler] Running task '%s'..." id)
    (condition-case err
        (funcall func)
      (error (message "[Supertag Scheduler] Task '%s' failed: %S" id err)))
    ;; Update last-run time
    (pcase (plist-get task :type)
      (:interval (plist-put task :last-run now))
      (:daily (plist-put task :last-run (format-time-string "%Y-%m-%d" now))))
    (puthash id task supertag-scheduler--tasks)
    ;; Persist state after daily tasks
    (when (eq (plist-get task :type) :daily)
      (supertag-scheduler--save-state))))

(defun supertag-scheduler--reset-runtime ()
  "Clear scheduler tasks and timer when switching vaults."
  (when (timerp supertag-scheduler--master-timer)
    (cancel-timer supertag-scheduler--master-timer))
  (setq supertag-scheduler--master-timer nil)
  (clrhash supertag-scheduler--tasks))


;;; --- Rule Templates ---

;;; --- Small helpers ---

(defun supertag-automation-templates--param (params key)
  "Return the value of KEY in the PARAMS alist collected from the user."
  (cdr (assq key params)))

(defun supertag-automation-templates--keywordize (name)
  "Turn NAME (a string, symbol, or keyword) into a keyword like :FOO."
  (cond
   ((keywordp name) name)
   ((symbolp name) (intern (concat ":" (symbol-name name))))
   ((stringp name) (intern (concat ":" (string-remove-prefix ":" (string-trim name)))))
   (t (error "supertag-automation-templates: cannot keywordize %S" name))))

(defun supertag-automation-templates--split-tags (raw)
  "Split RAW (a comma/space separated string) into a list of tag names."
  (split-string (or raw "") "[,\s]+" t "[ \t]+"))

;;; --- :call-function target used by the scheduled template ---
;;
;; Scheduled (:on-schedule) rules only ever run :call-function actions
;; (see Commentary above), so any "update a property/field on every node
;; with a tag, once a day" template must go through a real function
;; symbol rather than a plain :update-property action spec.

(defun supertag-automation-templates--scheduled-set-property (node-id context tag property value)
  "Set PROPERTY to VALUE on every node tagged TAG.
Intended to be used as the :function of a :call-function action on an
:on-schedule rule.  NODE-ID and CONTEXT are supplied by the scheduler
runner (see `supertag-automation--register-scheduled-rule') and are
unused here because scheduled rules are not scoped to a single node."
  (ignore node-id context)
  (dolist (nid (supertag-index-get-nodes-by-tag tag))
    (supertag-automation-action-update-property nid (list :property property :value value))))

;;; --- Template catalog ---
;;
;; Each template is a plist:
;;   :id          unique symbol
;;   :name        short human-readable name
;;   :description one sentence describing what the rule automates
;;   :params      list of (KEY PROMPT TYPE)
;;                  KEY    - symbol used to look the value up in the alist
;;                           passed to :build
;;                  PROMPT - string shown to the user
;;                  TYPE   - one of `tag', `todo-state', `property',
;;                           `value', `string', `file' (drives which
;;                           reader `supertag-automation-insert-template'
;;                           uses)
;;   :build       function: (alist-of (KEY . VALUE)) -> plist suitable
;;                for `supertag-automation-create'

(defconst supertag-automation-templates
  (list
   ;; 1. Tag added -> set TODO state ------------------------------------
   (list
    :id :tag-added-set-todo-state
    :name "Tag added -> set TODO state"
    :description "When a tag is added to a node, set its TODO keyword (e.g. adding #done sets TODO state to DONE)."
    :params '((tag "Tag that triggers the rule (e.g. done)" tag)
              (state "TODO keyword to apply (e.g. DONE)" todo-state))
    :build (lambda (params)
             (let* ((tag (supertag-automation-templates--param params 'tag))
                    (state (supertag-automation-templates--param params 'state)))
               (list :name (format "Tag '%s' sets TODO %s" tag state)
                     :description (format "Adding tag '%s' sets the TODO state to %s." tag state)
                     :trigger (list :on-tag-added tag)
                     :actions (list (list :action :update-todo-state
                                          :params (list :state state)))))))

   ;; 2. Tag added -> set a property -------------------------------------
   (list
    :id :tag-added-set-property
    :name "Tag added -> set a property"
    :description "When a tag is added to a node, set an Org property to a fixed value (e.g. adding #urgent sets PRIORITY to A)."
    :params '((tag "Tag that triggers the rule (e.g. urgent)" tag)
              (property "Property name to set (e.g. PRIORITY)" property)
              (value "Value to assign (e.g. A)" value))
    :build (lambda (params)
             (let* ((tag (supertag-automation-templates--param params 'tag))
                    (property (supertag-automation-templates--param params 'property))
                    (value (supertag-automation-templates--param params 'value))
                    (prop-kw (supertag-automation-templates--keywordize property)))
               (list :name (format "Tag '%s' sets %s" tag property)
                     :description (format "Adding tag '%s' sets property %s to %s." tag property value)
                     :trigger (list :on-tag-added tag)
                     :actions (list (list :action :update-property
                                          :params (list :property prop-kw :value value)))))))

   ;; 3. Tag added -> add another tag (implication) ----------------------
   (list
    :id :tag-added-add-tag
    :name "Tag added -> add another tag (implication)"
    :description "When a tag is added, automatically add a second tag too (e.g. #bug implies #needs-triage)."
    :params '((trigger-tag "Tag that triggers the rule (e.g. bug)" tag)
              (implied-tag "Tag to add automatically (e.g. needs-triage)" tag))
    :build (lambda (params)
             (let* ((trigger-tag (supertag-automation-templates--param params 'trigger-tag))
                    (implied-tag (supertag-automation-templates--param params 'implied-tag)))
               (list :name (format "Tag '%s' implies '%s'" trigger-tag implied-tag)
                     :description (format "Adding tag '%s' automatically adds tag '%s'." trigger-tag implied-tag)
                     :trigger (list :on-tag-added trigger-tag)
                     :actions (list (list :action :add-tag
                                          :params (list :tag implied-tag)))))))

   ;; 4. Tag removed -> remove a derived tag -----------------------------
   (list
    :id :tag-removed-remove-tag
    :name "Tag removed -> remove a derived tag"
    :description "When a tag is removed from a node, remove a second, dependent tag as well (e.g. removing #active also removes #on-hold)."
    :params '((trigger-tag "Tag whose removal triggers the rule (e.g. active)" tag)
              (derived-tag "Tag to remove along with it (e.g. on-hold)" tag))
    :build (lambda (params)
             (let* ((trigger-tag (supertag-automation-templates--param params 'trigger-tag))
                    (derived-tag (supertag-automation-templates--param params 'derived-tag)))
               (list :name (format "Removing '%s' removes '%s'" trigger-tag derived-tag)
                     :description (format "Removing tag '%s' automatically removes tag '%s'." trigger-tag derived-tag)
                     :trigger (list :on-tag-removed trigger-tag)
                     :actions (list (list :action :remove-tag
                                          :params (list :tag derived-tag)))))))

   ;; 5. Field change -> update a tag field on the same node -------------
   (list
    :id :field-change-update-field
    :name "Field change -> update another field"
    :description "Scoped to a tag: whenever one field on a node changes, set another field on that node to a fixed value."
    :params '((scope-tag "Only run for nodes with this tag (e.g. task)" tag)
              (source-field "Field whose change triggers the rule (e.g. status)" string)
              (target-tag "Tag ID that defines the field to update (usually same as scope tag)" tag)
              (target-field "Field to update (e.g. last-touched)" string)
              (target-value "Value to set on the target field" value))
    :build (lambda (params)
             (let* ((scope-tag (supertag-automation-templates--param params 'scope-tag))
                    (source-field (supertag-automation-templates--param params 'source-field))
                    (target-tag (supertag-automation-templates--param params 'target-tag))
                    (target-field (supertag-automation-templates--param params 'target-field))
                    (target-value (supertag-automation-templates--param params 'target-value)))
               (list :name (format "%s/%s change updates %s" scope-tag source-field target-field)
                     :description (format "On nodes tagged '%s', a change to field '%s' sets field '%s' to %s."
                                          scope-tag source-field target-field target-value)
                     :trigger :on-field-change
                     :condition (list 'and
                                      (list 'has-tag scope-tag)
                                      (list 'field-changed source-field))
                     :actions (list (list :action :update-field
                                          :params (list :tag target-tag
                                                        :field target-field
                                                        :value target-value)))))))

   ;; 6. Field equals value -> move node to an archive file --------------
   (list
    :id :field-equals-move-node
    :name "Field equals value -> move node to file"
    :description "Whenever a field is set to a specific value, move the node into an archive (or any target) file."
    :params '((scope-tag "Only run for nodes with this tag (leave blank for any node)" tag)
              (field "Field to test (e.g. status)" string)
              (value "Value that triggers the move (e.g. archived)" value)
              (target-file "Absolute path of the file to move matching nodes into" file))
    :build (lambda (params)
             (let* ((scope-tag (string-trim (or (supertag-automation-templates--param params 'scope-tag) "")))
                    (field (supertag-automation-templates--param params 'field))
                    (value (supertag-automation-templates--param params 'value))
                    (target-file (supertag-automation-templates--param params 'target-file))
                    (field-cond (list 'field-equals field value))
                    (condition (if (string-empty-p scope-tag)
                                   field-cond
                                 (list 'and (list 'has-tag scope-tag) field-cond))))
               (list :name (format "%s=%s moves to %s" field value (file-name-nondirectory target-file))
                     :description (format "When field '%s' equals %s, move the node into %s."
                                          field value target-file)
                     :trigger :on-field-change
                     :condition condition
                     :actions (list (list :action :move-node
                                          :params (list :target-file target-file)))))))

   ;; 7. Property equals value -> add a tag -------------------------------
   (list
    :id :property-equals-add-tag
    :name "Property equals value -> add tag"
    :description "Whenever a node property equals a specific value, automatically add a tag (e.g. priority = A adds #urgent)."
    :params '((property "Property to test, without colon (e.g. priority)" property)
              (value "Value that triggers the tag add (e.g. A)" value)
              (tag "Tag to add when the condition matches" tag))
    :build (lambda (params)
             (let* ((property (supertag-automation-templates--param params 'property))
                    (value (supertag-automation-templates--param params 'value))
                    (tag (supertag-automation-templates--param params 'tag))
                    (prop-kw (supertag-automation-templates--keywordize property)))
               (list :name (format "%s=%s adds '%s'" property value tag)
                     :description (format "When property %s equals %s, add tag '%s'." property value tag)
                     :trigger :on-property-change
                     :condition (list 'property-equals prop-kw value)
                     :actions (list (list :action :add-tag
                                          :params (list :tag tag)))))))

   ;; 8. Scheduled daily rule -> update a property on all tagged nodes ---
   (list
    :id :daily-set-property-for-tag
    :name "Scheduled daily -> set property on tagged nodes"
    :description "Once a day, set a property to a fixed value on every node that carries a given tag."
    :params '((tag "Nodes with this tag get updated every day (e.g. weekly-review)" tag)
              (property "Property to set (e.g. LAST-REVIEWED)" property)
              (value "Value to assign" value)
              (time "Time of day to run, 24h HH:MM (e.g. 06:00)" string))
    :build (lambda (params)
             (let* ((tag (supertag-automation-templates--param params 'tag))
                    (property (supertag-automation-templates--param params 'property))
                    (value (supertag-automation-templates--param params 'value))
                    (time (supertag-automation-templates--param params 'time))
                    (prop-kw (supertag-automation-templates--keywordize property)))
               (list :name (format "Daily %s: set %s on '%s' nodes" time property tag)
                     :description (format "Every day at %s, set property %s to %s on every node tagged '%s'."
                                          time property value tag)
                     :trigger :on-schedule
                     :schedule (list :time time)
                     :actions (list (list :action :call-function
                                          :params (list :function #'supertag-automation-templates--scheduled-set-property
                                                        :args (list tag prop-kw value))))))))

   ;; 9. Tag added -> create a follow-up node -----------------------------
   (list
    :id :tag-added-create-followup-node
    :name "Tag added -> create follow-up node"
    :description "When a tag is added, create a brand-new node with a given title and tags (the engine does not support linking it back to the source node)."
    :params '((tag "Tag that triggers creation of a follow-up node (e.g. needs-followup)" tag)
              (title "Title for the new node" string)
              (followup-tags "Comma-separated tags to apply to the new node (e.g. task, followup)" string)
              (target-file "Destination Org file" file))
    :build (lambda (params)
             (let* ((tag (supertag-automation-templates--param params 'tag))
                    (title (supertag-automation-templates--param params 'title))
                    (followup-tags (supertag-automation-templates--split-tags
                                    (supertag-automation-templates--param params 'followup-tags)))
                    (target-file (supertag-automation-templates--param params 'target-file)))
               (list :name (format "Tag '%s' creates follow-up" tag)
                     :description (format "Adding tag '%s' creates a new node titled '%s'." tag title)
                     :trigger (list :on-tag-added tag)
                     :actions (list (list :action :create-node
                                          :params (list :title title
                                                        :tags followup-tags
                                                        :target-file target-file))))))))
  "Catalog of ready-made Automation 2.0 rule templates.

Every :trigger/condition/action keyword used by these templates was
verified against `supertag-automation.el'.  One idea from the original
brief was intentionally dropped:

  - A `:case' (multi-branch) action template.  `:case' branches need a
    nested :on spec plus a list of :equals/:in/:match/:test branches,
    each with its own :actions - that is a small program, not a handful
    of scalar parameters, so it does not fit this template's
    (key prompt type) shape.  Users who need branching logic are
    expected to compose it by hand with `supertag-automation-create',
    using the templates above as worked examples of the surrounding
    plist shape.

The `:manual' trigger was also left out: it never fires automatically
\(`supertag-automation--trigger-match-p' always returns nil for it\), so
a rule built on it would need a bespoke call to `supertag-rule-execute'
with no UI entry point provided elsewhere in the codebase to invoke it.")

;;; --- Interactive instantiation ---

(defun supertag-automation-templates--all-tag-names ()
  "Return known tag names for completion, or nil if unavailable."
  (ignore-errors (supertag-view-api-list-tag-ids)))

(defun supertag-automation-templates--read-tag (prompt)
  "Read a tag name for PROMPT, offering existing tags as completion."
  (string-trim
   (or (supertag-ui-read-tag
        (concat prompt ": ")
        (supertag-automation-templates--all-tag-names)
        t t)
       "")))

(defun supertag-automation-templates--read-todo-state (prompt)
  "Read a TODO keyword for PROMPT, offering `org-todo-keywords-1' when known."
  (let ((states (if (and (boundp 'org-todo-keywords-1) org-todo-keywords-1)
                     org-todo-keywords-1
                   '("TODO" "NEXT" "DONE" "CANCELLED"))))
    (string-trim (completing-read (concat prompt ": ") states nil nil))))

(defun supertag-automation-templates--read-param (prompt type)
  "Read one parameter value for PROMPT according to TYPE."
  (pcase type
    ('tag (supertag-automation-templates--read-tag prompt))
    ('todo-state (supertag-automation-templates--read-todo-state prompt))
    ('file (expand-file-name (read-file-name (concat prompt ": "))))
    ((or 'property 'value 'string _) (string-trim (read-string (concat prompt ": "))))))

(defun supertag-automation-templates--collect-params (template)
  "Prompt the user for every entry in TEMPLATE's :params.
Returns an alist of (KEY . VALUE)."
  (mapcar (lambda (spec)
            (cl-destructuring-bind (key prompt type) spec
              (cons key (supertag-automation-templates--read-param prompt type))))
          (plist-get template :params)))

(defun supertag-automation-templates--choose ()
  "Prompt the user to choose a template, annotated with its description.
Returns the chosen template plist."
  (let* ((candidates (mapcar (lambda (tpl) (cons (plist-get tpl :name) tpl))
                             supertag-automation-templates))
         (completion-extra-properties
          (list :annotation-function
                (lambda (name)
                  (let ((tpl (cdr (assoc name candidates))))
                    (when tpl (concat "  -- " (plist-get tpl :description)))))))
         (choice (completing-read "Automation template: " candidates nil t)))
    (or (cdr (assoc choice candidates))
        (user-error "Unknown automation template: %s" choice))))

(defun supertag-automation-templates--preview-buffer (template rule-args)
  "Render RULE-ARGS (built from TEMPLATE) into a preview buffer and return it."
  (let ((buf (get-buffer-create "*Supertag Automation Preview*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format ";; Template: %s\n" (plist-get template :name)))
        (insert (format ";; %s\n\n" (plist-get template :description)))
        (insert ";; Arguments that will be passed to `supertag-automation-create':\n")
        (pp rule-args (current-buffer)))
      (emacs-lisp-mode)
      (setq buffer-read-only t)
      (goto-char (point-min)))
    buf))

(defun supertag-automation-templates--create-with-retry (rule-args)
  "Create the automation described by RULE-ARGS, renaming on name clash.

`supertag-automation-create' derives a rule's storage id from its
:name and silently REPLACES any existing rule sharing that id -- it
never signals a duplicate-name error.  To avoid surprising the user by
clobbering an unrelated existing rule, check `supertag-automation-get-by-name'
first and offer to pick a different name."
  (let ((name (plist-get rule-args :name)))
    (while (and name
                (supertag-automation-get-by-name name)
                (not (y-or-n-p
                      (format "An automation named '%s' already exists and would be REPLACED. Continue? "
                              name))))
      (setq name (read-string "New automation name: " name))
      (setq rule-args (plist-put rule-args :name name)))
    (condition-case err
        (let ((created (supertag-automation-create rule-args)))
          (message "Created automation '%s' (id=%s)."
                   (plist-get created :name) (plist-get created :id))
          created)
      (error
       (message "Failed to create automation: %s" (error-message-string err))
       nil))))

;;;###autoload
(defun supertag-automation-insert-template ()
  "Instantiate one of `supertag-automation-templates' interactively.

Prompts for a template, then for each of its declared parameters,
previews the resulting rule plist in a temporary buffer, and only
calls `supertag-automation-create' after explicit confirmation."
  (interactive)
  (let* ((template (supertag-automation-templates--choose))
         (params (supertag-automation-templates--collect-params template))
         (rule-args (funcall (plist-get template :build) params))
         (buf (supertag-automation-templates--preview-buffer template rule-args)))
    (display-buffer buf)
    (if (y-or-n-p (format "Create automation '%s'? " (plist-get rule-args :name)))
        (supertag-automation-templates--create-with-retry rule-args)
      (message "Automation creation cancelled."))))

;;;###autoload
(defun supertag-automation-list-templates ()
  "Browse the `supertag-automation-templates' catalog in a read-only buffer."
  (interactive)
  (let ((buf (get-buffer-create "*Supertag Automation Templates*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (tpl supertag-automation-templates)
          (insert (format "%s  [%s]\n" (plist-get tpl :name) (plist-get tpl :id)))
          (insert (format "    %s\n" (plist-get tpl :description)))
          (insert (format "    Params: %s\n\n"
                          (mapconcat (lambda (p) (symbol-name (car p)))
                                     (plist-get tpl :params) ", ")))))
      (goto-char (point-min))
      (special-mode))
    (display-buffer buf)))

;;; --- Auto-initialization ---

;; Initialize the automation system when loaded
(supertag-automation-init)
(add-hook 'supertag-persistence-after-load-hook
          #'supertag-automation--after-store-load)

(defun supertag-automation--reset-runtime ()
  "Discard queued automation work at a vault boundary."
  (when (timerp supertag-automation--processing-timer)
    (cancel-timer supertag-automation--processing-timer))
  (setq supertag-automation--event-queue nil
        supertag-automation--processing-queue nil
        supertag-automation--current-event nil
        supertag-automation--processing-timer nil))

(provide 'supertag-automation)

;;; supertag-automation.el ends here
