;;; supertag-ontology-migration-link.el --- Link migration planning -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Read-only planning for cardinality tightening.  The resolver selects one
;; relation to keep in every conflict group; all other relations become explicit
;; delete actions in the migration plan.

;;; Code:

(require 'cl-lib)
(require 'supertag-ontology-model)
(require 'supertag-ontology-migration-callback)
(require 'supertag-ontology-migration-runtime)
(require 'supertag-ops-link-definition)

(defun supertag-ontology-migration-link--issue
    (severity code message &optional step)
  "Build one Link migration issue."
  (list :severity severity :code code :message message :step step))

(defun supertag-ontology-migration-link--resolver-result-id (result)
  "Return relation ID represented by resolver RESULT."
  (cond ((stringp result) result)
        ((listp result) (plist-get result :id))
        (t nil)))

(defun supertag-ontology-migration-link--resolve-group
    (relations resolver context step)
  "Return (KEEP-ID ISSUE) for conflicting RELATIONS."
  (if (<= (length relations) 1)
      (list (plist-get (car relations) :id) nil)
    (if (null resolver)
        (list
         nil
         (supertag-ontology-migration-link--issue
          :error :missing-link-resolver
          (format "%s conflict %S has %d relations but no resolver"
                  (plist-get context :side)
                  (plist-get context :endpoint-id)
                  (length relations))
          step))
      (condition-case err
          (let* ((ordered-relations
                  (sort
                   (copy-tree relations)
                   (lambda (left right)
                     (string< (or (plist-get left :id) "")
                              (or (plist-get right :id) "")))))
                 (result
                  (supertag-ontology-migration-callback-call
                   resolver ordered-relations context))
                 (keep-id
                  (supertag-ontology-migration-link--resolver-result-id result)))
            (if (cl-find keep-id relations
                         :key (lambda (relation) (plist-get relation :id))
                         :test #'equal)
                (list keep-id nil)
              (list
               nil
               (supertag-ontology-migration-link--issue
                :error :invalid-link-resolver-result
                (format "Resolver %S returned %S, not a relation in conflict group"
                        resolver result)
                step))))
        (error
         (list
          nil
          (supertag-ontology-migration-link--issue
           :error
           (if (eq (car err)
                   'supertag-ontology-migration-impure-callback)
               :impure-link-resolver
             :link-resolver-failed)
           (format "Resolver %S failed: %s"
                   resolver (error-message-string err))
           step)))))))

(defun supertag-ontology-migration-link--groups (relations slot)
  "Return deterministic (ENDPOINT-ID . RELATIONS) groups for SLOT."
  (let ((table (make-hash-table :test #'equal))
        groups)
    (dolist (relation relations)
      (let ((key (plist-get relation slot)))
        (puthash key (cons relation (gethash key table)) table)))
    (maphash
     (lambda (key values)
       (push (cons key values) groups))
     table)
    (sort groups
          (lambda (left right)
            (string< (format "%s" (car left))
                     (format "%s" (car right)))))))

(defun supertag-ontology-migration-link--remaining (relations deleted)
  "Return RELATIONS whose IDs are not present in DELETED."
  (cl-remove-if
   (lambda (relation)
     (gethash (plist-get relation :id) deleted))
   relations))

(defun supertag-ontology-migration-link-plan-tighten
    (migration model step)
  "Build relation-deletion plan for tighten-link STEP."
  (let* ((key (plist-get step :link))
         (desired (supertag-ontology-model-find model :link key))
         (runtime-id
          (supertag-ontology-migration-runtime-entity-id model :link key))
         (relations
          (and runtime-id
               (supertag-link-definition-instance-relations runtime-id)))
         (deleted (make-hash-table :test #'equal))
         actions
         samples
         issues)
    (cond
     ((null desired)
      (push
       (supertag-ontology-migration-link--issue
        :error :missing-target-link
        (format "Migration target Link %s is not declared" key) step)
       issues))
     ((null runtime-id)
      (push
       (supertag-ontology-migration-link--issue
        :error :missing-runtime-link
        (format "Link %s has no runtime binding" key) step)
       issues))
     (t
      (dolist
          (spec
           `((:one ,(plist-get desired :from-cardinality)
                   :from :source ,(plist-get step :source-resolver))
             (:one ,(plist-get desired :to-cardinality)
                   :to :target ,(plist-get step :target-resolver))))
        (pcase-let ((`(,required ,actual ,slot ,side ,resolver) spec))
          (when (eq actual required)
            (let ((groups
                   (supertag-ontology-migration-link--groups
                    (supertag-ontology-migration-link--remaining
                     relations deleted)
                    slot)))
              (dolist (entry groups)
                (let ((endpoint-id (car entry))
                      (group (cdr entry)))
                  (when (> (length group) 1)
                    (pcase-let*
                        ((context
                          (list :migration (plist-get migration :name)
                                :module (plist-get migration :module)
                                :link key
                                :link-definition-id runtime-id
                                :side side
                                :endpoint-id endpoint-id))
                         (`(,keep-id ,issue)
                          (supertag-ontology-migration-link--resolve-group
                           group resolver context step)))
                      (if issue
                          (push issue issues)
                        (dolist (relation group)
                          (unless (equal keep-id (plist-get relation :id))
                            (puthash (plist-get relation :id)
                                     relation deleted))))))))))))))
    (maphash
     (lambda (relation-id relation)
       (push (list :kind :delete-relation
                   :relation-id relation-id
                   :old-value relation)
             actions)
       (when (< (length samples)
                supertag-ontology-migration-preview-sample-limit)
         (push (list :relation-id relation-id
                     :from (plist-get relation :from)
                     :to (plist-get relation :to))
               samples)))
     deleted)
    (setq actions
          (sort actions
                (lambda (left right)
                  (string< (plist-get left :relation-id)
                           (plist-get right :relation-id)))))
    (list :step step
          :kind :tighten-link
          :runtime-id runtime-id
          :scanned (length relations)
          :deleted (length actions)
          :actions actions
          :samples
          (sort samples
                (lambda (left right)
                  (string< (plist-get left :relation-id)
                           (plist-get right :relation-id))))
          :issues (nreverse issues))))

(defun supertag-ontology-migration-link-canonical-data (model step)
  "Return canonical live Link data relevant to STEP."
  (when-let ((runtime-id
              (supertag-ontology-migration-runtime-entity-id
               model :link (plist-get step :link))))
    (list
     runtime-id
     (sort
      (mapcar
       (lambda (relation)
         (list :id (plist-get relation :id)
               :from (plist-get relation :from)
               :to (plist-get relation :to)
               :link-definition-id
               (plist-get relation :link-definition-id)))
       (supertag-link-definition-instance-relations runtime-id))
      (lambda (left right)
        (string< (plist-get left :id) (plist-get right :id)))))))

(provide 'supertag-ontology-migration-link)
;;; supertag-ontology-migration-link.el ends here
