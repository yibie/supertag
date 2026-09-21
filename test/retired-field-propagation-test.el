;;; retired-field-propagation-test.el --- Retired relation behavior -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-persistence)
(require 'supertag-node)
(require 'supertag-ops-field)
(require 'supertag-link)
(require 'supertag-automation)

(defmacro supertag-retired-propagation-test--with-store (&rest body)
  "Run BODY with isolated nodes and inert historical relation metadata."
  (declare (indent 0) (debug t))
  `(let* ((tmp (make-temp-file "supertag-retired-propagation-" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag--store nil)
          (supertag--store-origin nil)
          (supertag--subscribers (make-hash-table :test 'equal))
          (supertag-after-operation-hook nil)
          (legacy-relation
           '(:id "legacy-sync" :type :sync-field
             :from "source" :to "target"
             :kind :semantic-edge :origin :semantic
             :sync-fields ("status")
             :rollup-field "total" :rollup-function sum
             :rollup-property (:from-field "effort" :to-field "total"))))
     (unwind-protect
         (progn
           (supertag--ensure-store)
           (supertag-node-create '(:id "source" :title "Source"))
           (supertag-node-create '(:id "target" :title "Target"))
           ;; Historical behavior metadata is loaded directly, as an old Store
           ;; would contain it.  The creation API is intentionally bypassed.
           (supertag-store-put-entity :relations "legacy-sync"
                                      (copy-tree legacy-relation))
           (supertag-store-put-field-value "source" "status" "old")
           (supertag-store-put-field-value "target" "status" "keep")
           ,@body)
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-retired-propagation-test--install-rule (counter)
  "Install one ordinary field-event rule that increments COUNTER."
  (supertag-automation-create
   `(:name "ordinary-field-rule"
     :trigger :on-field-change
     :condition (global-field-changed "status")
     :actions ((:action :call-function
                :params (:function ,(lambda (&rest _)
                                      (setcar counter (1+ (car counter)))))))))
  (supertag-rebuild-rule-index))

(ert-deftest supertag-retired-propagation-default-event-keeps-history-and-runs-rule-once ()
  "The default store-event route runs rules without field propagation."
  (supertag-retired-propagation-test--with-store
    (let ((calls (list 0))
          (before (copy-tree (supertag-relation-get "legacy-sync"))))
      (supertag-retired-propagation-test--install-rule calls)
      (supertag-subscribe :store-changed
                          #'supertag-automation--handle-entity-change)
      (supertag-store-put-field-value "source" "status" "changed" t)
      (should (= 1 (car calls)))
      (should (equal "keep"
                     (supertag-store-get-field-value "target" "status")))
      (should (equal before (supertag-relation-get "legacy-sync"))))))

(ert-deftest supertag-retired-propagation-commit-hook-keeps-history-and-runs-rule-once ()
  "The opt-in commit-hook route also omits retired propagation."
  (supertag-retired-propagation-test--with-store
    (let ((calls (list 0))
          (before (copy-tree (supertag-relation-get "legacy-sync"))))
      (supertag-retired-propagation-test--install-rule calls)
      (add-hook 'supertag-after-operation-hook
                #'supertag-automation-sync--handle-commit-result)
      (supertag-ops-commit
       :operation :update :collection :field-values :id "source"
       :path '(:field-values "source" "status")
       :previous "old" :new "changed"
       :perform (lambda ()
                  (supertag-store-put-field-value
                   "source" "status" "changed")))
      (should (= 1 (car calls)))
      (should (equal "keep"
                     (supertag-store-get-field-value "target" "status")))
      (should (equal before (supertag-relation-get "legacy-sync"))))))

(ert-deftest supertag-retired-propagation-relation-event-is-inert ()
  "A historical relation event cannot execute its old sync metadata."
  (supertag-retired-propagation-test--with-store
    (supertag-subscribe :store-changed
                        #'supertag-automation--handle-entity-change)
    (supertag-relation-update
     "legacy-sync" (lambda (relation) (plist-put relation :label "changed")))
    (should (equal "keep"
                   (supertag-store-get-field-value "target" "status")))
    (should (equal "changed"
                   (plist-get (supertag-relation-get "legacy-sync") :label)))
    (dolist (key '(:type :sync-fields :rollup-field :rollup-function
                        :rollup-property))
      (should (equal (plist-get legacy-relation key)
                     (plist-get (supertag-relation-get "legacy-sync") key))))))

(ert-deftest supertag-retired-propagation-rejects-new-behavior-before-mutation ()
  "Retired plist/hash behavior fails before relation mutation."
  (supertag-retired-propagation-test--with-store
    (dolist (extra '((:type :sync-field)
                     (:type :rollup)
                     (:sync-fields ("status"))
                     (:rollup-field "total")
                     (:rollup-property (:function sum))
                     (:rollup-function sum)
                     (:rollup-config (:field "total" :function sum))))
      (let ((before (hash-table-count
                     (supertag-store-get-collection :relations))))
        (should-error
         (supertag-relation-create
          (append extra (list :type :reference :from "source" :to "target")))
         :type 'user-error)
        (should (= before
                   (hash-table-count
                    (supertag-store-get-collection :relations))))))
    (let ((ordinary (make-hash-table :test #'eq)))
      (puthash :type :reference ordinary)
      (puthash :from "source" ordinary)
      (puthash :to "target" ordinary)
      (should (plist-get (supertag-relation-create ordinary) :id)))
    (let ((retired (make-hash-table :test #'eq))
          (before (hash-table-count
                   (supertag-store-get-collection :relations))))
      (puthash :type :reference retired)
      (puthash :from "target" retired)
      (puthash :to "source" retired)
      (puthash :sync-fields '("status") retired)
      (should-error (supertag-relation-create retired) :type 'user-error)
      (should (= before
                 (hash-table-count
                  (supertag-store-get-collection :relations)))))))

(ert-deftest supertag-retired-propagation-history-survives-update-and-persistence ()
  "Unrelated updates and Store reload preserve retired metadata verbatim."
  (supertag-retired-propagation-test--with-store
    (let ((expected
           (supertag-relation-update
            "legacy-sync"
            (lambda (relation) (plist-put relation :label "kept")))))
      (supertag--persistence-write-store-atomically supertag-db-file)
      (let* ((reloaded (supertag--persistence--try-read-store
                        supertag-db-file))
             (actual (gethash "legacy-sync" (gethash :relations reloaded))))
        (dolist (key '(:type :from :to :sync-fields :rollup-field
                            :rollup-function :rollup-property :label))
          (should (equal (plist-get expected key) (plist-get actual key))))))))

(ert-deftest supertag-retired-propagation-executors-are-removed ()
  "Retired manual and helper symbols are not callable compatibility no-ops."
  (dolist (symbol '(supertag-automation-sync-field
                    supertag-automation-sync-all-relations
                    supertag-automation-calculate-rollup
                    supertag-automation-recalculate-all-rollups
                    supertag-automation-sync-all-fields
                    supertag-relation-sync-fields
                    supertag-relation-calculate-rollup
                    supertag-relation-update-all-rollups
                    supertag-relation-sync-all-fields))
    (should-not (fboundp symbol))))

(ert-deftest supertag-retired-propagation-keeps-read-time-query-aggregate ()
  "Query aggregation remains available independently of relation rollups."
  (supertag-retired-propagation-test--with-store
    (supertag-store-put-field-definition
     "effort" '(:id "effort" :name "effort" :type :number))
    (supertag-store-put-field-value "source" "effort" 2)
    (supertag-store-put-field-value "target" "effort" 3)
    (should (= 5 (supertag-query-evaluate '(and (sum "effort")))))))

(provide 'retired-field-propagation-test)

;;; retired-field-propagation-test.el ends here
