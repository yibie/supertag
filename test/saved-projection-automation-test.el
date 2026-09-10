;;; saved-projection-automation-test.el --- Saved projection events -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-services-sync)
(require 'supertag-service-org)
(require 'supertag-automation)

(defmacro supertag-saved-projection-test--with-vault (&rest body)
  "Run BODY with isolated projection, Automation, and async state."
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
           (supertag-automation--enabled t)
           (supertag-automation-sync--enabled t)
           (supertag-automation--executing nil)
           (supertag-automation--processing-queue nil)
           (supertag-automation-sync--processing-stack nil)
           (supertag-automation--event-queue nil)
           (supertag-async--queue nil)
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

(defun supertag-saved-projection-test--disk-property (file property)
  "Return local PROPERTY on FILE's first heading."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (goto-char (point-min))
    (org-entry-get nil property nil)))

(defun supertag-saved-projection-test--save-property (file property value)
  "Save PROPERTY VALUE in FILE through the daily after-save hook."
  (with-current-buffer (find-file-noselect file)
    (org-mode)
    (goto-char (point-min))
    (should-not (supertag--is-internal-modification-p file))
    (if value
        (org-entry-put nil property value)
      (org-entry-delete nil property))
    (let ((hook-calls 0))
      (setq-local after-save-hook nil)
      (add-hook 'after-save-hook
                (lambda ()
                  (cl-incf hook-calls)
                  (supertag-sync--run-on-save))
                nil t)
      (save-buffer)
      (should (= 1 hook-calls)))))

(defun supertag-saved-projection-test--run-incremental (file)
  "Process saved FILE through the normal single-file incremental path."
  (setq supertag-async--queue nil)
  (supertag-sync--process-single-file
   file '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0)))

(defun supertag-saved-projection-test--exercise-route (route)
  "Exercise a real saved property update through ROUTE."
  (supertag-saved-projection-test--with-vault
    (let ((file (car files))
          (events nil)
          (writes 0)
          (created-at
           (plist-get (supertag-node-get supertag-ownership-test-node-a)
                      :created-at)))
      (pcase route
        (:store
         (supertag-subscribe :store-changed
                             #'supertag-automation--handle-entity-change))
        (:enabled-store
         (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change)
         (supertag-automation-sync-enable)))
      (add-hook 'supertag-after-operation-hook
                (lambda (event)
                  (when (and (eq (plist-get event :collection) :nodes)
                             (equal (plist-get event :id)
                                    supertag-ownership-test-node-a))
                    (push event events))))
      (supertag-automation-create
       `(:name ,(format "saved-%s" route)
         :trigger :on-property-change
         :condition ,(if (eq route :store)
                         '(property "STAGE" "go")
                       '(and (has-tag "project")
                             (property "STAGE" "go")))
         :actions ((:action :update-property
                    :params (:property "RESULT" :value "matched")))))
      (cl-letf (((symbol-function 'save-buffer)
                 (let ((real-save (symbol-function 'save-buffer)))
                   (lambda (&rest args)
                     (cl-incf writes)
                     (apply real-save args)))))
        (supertag-saved-projection-test--save-property file "STAGE" "go")
        (supertag-saved-projection-test--run-incremental file)
        ;; The action's saved projection must not replay the source rule.
        (supertag-saved-projection-test--run-incremental file))
      (should (equal "matched"
                     (supertag-saved-projection-test--disk-property
                      file "RESULT")))
      (should (= 2 writes))
      (let ((node (supertag-node-get supertag-ownership-test-node-a)))
        (should (equal created-at (plist-get node :created-at)))
        (should (member "project" (plist-get node :tags)))
        (should (member supertag-ownership-test-node-b
                        (plist-get node :ref-to)))
        (should-not (plist-get node :orphaned-at)))
      (let ((update (cl-find-if
                     (lambda (event)
                       (let ((previous-properties
                              (plist-get (plist-get event :previous) :properties))
                             (current-properties
                              (plist-get (plist-get event :current) :properties)))
                         (and (eq (plist-get event :operation) :update)
                              (not (plist-member previous-properties :STAGE))
                              (equal "go" (plist-get current-properties :STAGE)))))
                     events)))
        (should update)
        (should (plist-get update :previous))
        (should-not (plist-member
                     (plist-get (plist-get update :previous) :properties)
                     :STAGE))
        (should (equal "go"
                       (plist-get (plist-get (plist-get update :current)
                                             :properties)
                                  :STAGE)))))))

(ert-deftest supertag-saved-projection-default-route-runs-real-action-once ()
  "A saved property update reaches the Store-event route exactly once."
  (supertag-saved-projection-test--exercise-route :store))

(ert-deftest supertag-saved-projection-enabled-store-route-runs-real-action-once ()
  "A saved tag/property update reaches the commit-hook route exactly once."
  (supertag-saved-projection-test--exercise-route :enabled-store))

(ert-deftest supertag-saved-projection-delete-and-hash-noop-are-exact ()
  "Deletion replaces projected properties; identical sync emits no event."
  (supertag-saved-projection-test--with-vault
    (let ((file (car files))
          (calls (list 0))
          (node-events 0))
      (supertag-subscribe :store-changed
                          #'supertag-automation--handle-entity-change)
      (supertag-saved-projection-test--save-property file "STAGE" "go")
      (supertag-saved-projection-test--run-incremental file)
      (supertag-automation-create
       `(:name "saved-property-delete"
         :trigger :on-property-change
         :condition (not (property "STAGE" "go"))
         :actions ((:action :call-function
                    :params (:function ,(lambda (&rest _)
                                          (setcar calls (1+ (car calls)))))))))
      (add-hook 'supertag-after-operation-hook
                (lambda (event)
                  (when (and (eq (plist-get event :collection) :nodes)
                             (equal (plist-get event :id)
                                    supertag-ownership-test-node-a)
                             (plist-get event :changed))
                    (cl-incf node-events))))
      (supertag-saved-projection-test--save-property file "STAGE" "go")
      (supertag-saved-projection-test--run-incremental file)
      (should (= 0 (car calls)))
      (should (= 0 node-events))
      (supertag-saved-projection-test--save-property file "STAGE" nil)
      (supertag-saved-projection-test--run-incremental file)
      (should (= 1 (car calls)))
      (should (= 1 node-events))
      (should-not
       (plist-member
        (plist-get (supertag-node-get supertag-ownership-test-node-a)
                   :properties)
        :STAGE))
      (supertag-saved-projection-test--run-incremental file)
      (should (= 1 (car calls)))
      (should (= 1 node-events)))))

(defun supertag-saved-projection-test--replace-disk-property
    (file property value)
  "Replace PROPERTY with VALUE in FILE without invoking buffer hooks."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (goto-char (point-min))
    (org-entry-put nil property value)
    (write-region (point-min) (point-max) file nil 'silent)))

(defun supertag-saved-projection-test--exercise-reindex-route (route)
  "Verify pure reindex suppression through Automation ROUTE."
  (supertag-saved-projection-test--with-vault
    (let* ((changed-file (car files))
           (identical-file (cadr files))
           (new-file (expand-file-name "new.org" vault))
           (events nil))
      (pcase route
        (:store
         (supertag-subscribe :store-changed
                             #'supertag-automation--handle-entity-change))
        (:enabled-store
         (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change)
         (supertag-automation-sync-enable)))
      (add-hook 'supertag-after-operation-hook
                (lambda (event)
                  (when (eq (plist-get event :collection) :nodes)
                    (push event events))))
      (supertag-automation-create
       `(:name ,(format "reindex-%s" route)
         :trigger :on-property-change
         :condition (property "STAGE" "go")
         :actions ((:action :update-property
                    :params (:property "RESULT" :value "forbidden")))))
      (supertag-saved-projection-test--replace-disk-property
       changed-file "STAGE" "go")
      (with-temp-file new-file
        (insert "* New\n:PROPERTIES:\n:ID:       saved-new-node\n"
                ":STAGE:    go\n:END:\n"))
      (let ((changed-before (with-temp-buffer
                              (insert-file-contents changed-file)
                              (buffer-string)))
            (identical-before (with-temp-buffer
                                (insert-file-contents identical-file)
                                (buffer-string)))
            (new-before (with-temp-buffer
                          (insert-file-contents new-file)
                          (buffer-string))))
        (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
        (should (equal changed-before
                       (with-temp-buffer
                         (insert-file-contents changed-file)
                         (buffer-string))))
        (should (equal identical-before
                       (with-temp-buffer
                         (insert-file-contents identical-file)
                         (buffer-string))))
        (should (equal new-before
                       (with-temp-buffer
                         (insert-file-contents new-file)
                         (buffer-string)))))
      (should (equal "go"
                     (plist-get
                      (plist-get
                       (supertag-node-get supertag-ownership-test-node-a)
                       :properties)
                      :STAGE)))
      (should (supertag-node-get "saved-new-node"))
      (should-not (supertag-saved-projection-test--disk-property
                   changed-file "RESULT"))
      (should-not (supertag-saved-projection-test--disk-property
                   new-file "RESULT"))
      (should (cl-find-if
               (lambda (event)
                 (and (eq (plist-get event :operation) :update)
                      (equal (plist-get event :id)
                             supertag-ownership-test-node-a)))
               events))
      (should (cl-find-if
               (lambda (event)
                 (and (eq (plist-get event :operation) :create)
                      (equal (plist-get event :id) "saved-new-node")
                      (null (plist-get event :previous))))
               events))
      (should supertag-automation-sync--enabled)
      (should-not supertag-automation--event-queue)
      (should-not supertag-async--queue))))

(ert-deftest supertag-reindex-store-route-never-runs-business-actions ()
  "Changed, new, and identical projections are inert on the Store route."
  (supertag-saved-projection-test--exercise-reindex-route :store))

(ert-deftest supertag-reindex-enabled-store-route-never-runs-business-actions ()
  "Changed, new, and identical projections are inert on the enabled Store route."
  (supertag-saved-projection-test--exercise-reindex-route :enabled-store))

(provide 'saved-projection-automation-test)
;;; saved-projection-automation-test.el ends here
