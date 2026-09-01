;;; supertag-ontology-migration-field.el --- Field migration planning -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Read-only planning for field value conversion and type/field detachment.
;; Execution belongs to `supertag-ontology-migration-deploy'.

;;; Code:

(require 'cl-lib)
(require 'supertag-core-schema)
(require 'supertag-core-store)
(require 'supertag-ontology-model)
(require 'supertag-ontology-migration-callback)
(require 'supertag-ontology-migration-model)
(require 'supertag-ontology-migration-runtime)

(defun supertag-ontology-migration-field--issue
    (severity code message &optional step)
  "Build one field migration issue."
  (list :severity severity :code code :message message :step step))

(defun supertag-ontology-migration-field-values (field-id)
  "Return sorted (NODE-ID VALUE) records for FIELD-ID."
  (let (records)
    (maphash
     (lambda (node-id values)
       (when (and (hash-table-p values)
                  (ht-contains? values field-id))
         (push (list node-id (copy-tree (gethash field-id values))) records)))
     (supertag-store-get-collection :field-values))
    (sort records
          (lambda (left right)
            (string< (car left) (car right))))))

(defun supertag-ontology-migration-field--normalize-option (value)
  "Normalize one options VALUE into runtime representation."
  (cond ((stringp value) value)
        ((symbolp value) (symbol-name value))
        (t value)))

(defun supertag-ontology-migration-field-normalize-target
    (value desired-field)
  "Normalize VALUE against DESIRED-FIELD or signal a precise error."
  (when (and (null value) (plist-get desired-field :required))
    (error "Required field %s cannot become nil"
           (plist-get desired-field :key)))
  (if (null value)
      nil
    (pcase (plist-get desired-field :type)
      (:options
       (let* ((list-value-p (and (listp value) (not (stringp value))))
              (values (if list-value-p value (list value)))
              (normalized
               (mapcar #'supertag-ontology-migration-field--normalize-option
                       values))
              (allowed (plist-get desired-field :options)))
         (when allowed
           (dolist (item normalized)
             (unless (member item allowed)
               (error "Option %S is not allowed for field %s"
                      item (plist-get desired-field :key)))))
         (if list-value-p normalized (car normalized))))
      (:node-reference
       (let* ((values (cond ((stringp value) (list value))
                            ((listp value) value)
                            (t (list value))))
              (normalized
               (mapcar
                (lambda (item)
                  (unless (and (stringp item) (> (length item) 0))
                    (error "Node reference must contain non-empty node IDs"))
                  (unless (supertag-store-get-entity :nodes item)
                    (error "Referenced node %s does not exist" item))
                  item)
                values)))
         (pcase normalized
           ('() nil)
           (`(,single) single)
           (_ normalized))))
      (_
       (supertag--convert-type value (plist-get desired-field :type))))))

(defun supertag-ontology-migration-field-plan-transform
    (migration model step)
  "Build data plan for a transform-field STEP."
  (let* ((key (plist-get step :field))
         (desired (supertag-ontology-model-find model :field key))
         (runtime-id
          (supertag-ontology-migration-runtime-entity-id model :field key))
         (values
          (and runtime-id
               (supertag-ontology-migration-field-values runtime-id)))
         (transformer (plist-get step :using))
         ;; A field that the same migration also detaches is expected to
         ;; lose values; clearing it silently is not suspicious.
         (detached-p
          (cl-some
           (lambda (other)
             (and (eq (plist-get other :kind) :detach-field)
                  (eq (plist-get other :field) key)))
           (plist-get migration :steps)))
         actions
         samples
         issues
         (changed 0)
         (dropped 0)
         (cleared 0)
         cleared-example)
    (cond
     ((null desired)
      (push
       (supertag-ontology-migration-field--issue
        :error :missing-target-field
        (format "Migration target field %s is not declared" key) step)
       issues))
     ((null runtime-id)
      (push
       (supertag-ontology-migration-field--issue
        :error :missing-runtime-field
        (format "Field %s has no runtime binding" key) step)
       issues))
     (t
      (dolist (entry values)
        (let* ((node-id (nth 0 entry))
               (old-value (nth 1 entry))
               (context
                (list :migration (plist-get migration :name)
                      :module (plist-get migration :module)
                      :field key
                      :field-id runtime-id
                      :node-id node-id
                      :target-field desired)))
          (condition-case err
              (let* ((transformed
                      (supertag-ontology-migration-callback-call
                       transformer old-value context))
                     (drop-p
                      (eq transformed supertag-ontology-migration-drop))
                     (new-value
                      (unless drop-p
                        (supertag-ontology-migration-field-normalize-target
                         transformed desired))))
                (when (and drop-p (plist-get desired :required))
                  (error "Required field %s cannot be dropped on node %s"
                         key node-id))
                (cond
                 (drop-p
                  (setq dropped (1+ dropped)
                        changed (1+ changed))
                  (push (list :kind :remove-field-value
                              :node-id node-id
                              :field-id runtime-id
                              :field-key key
                              :old-value old-value)
                        actions))
                 ((not (equal old-value new-value))
                  (setq changed (1+ changed))
                  (when (and old-value (null new-value) (not detached-p))
                    (setq cleared (1+ cleared))
                    (unless cleared-example
                      (setq cleared-example node-id)))
                  (push (list :kind :set-field-value
                              :node-id node-id
                              :field-id runtime-id
                              :field-key key
                              :old-value old-value
                              :new-value new-value
                              :field-type (plist-get desired :type))
                        actions)))
                (when (and
                       (< (length samples)
                          supertag-ontology-migration-preview-sample-limit)
                       (or drop-p (not (equal old-value new-value))))
                  (push (list :node-id node-id
                              :from old-value
                              :to (if drop-p :drop new-value))
                        samples)))
            (error
             (if (and (eq (plist-get step :on-error) :drop)
                      (not (plist-get desired :required))
                      (not (eq (car err)
                               'supertag-ontology-migration-impure-callback)))
                 (progn
                   (setq dropped (1+ dropped)
                         changed (1+ changed))
                   (push (list :kind :remove-field-value
                               :node-id node-id
                               :field-id runtime-id
                               :field-key key
                               :old-value old-value
                               :reason (error-message-string err))
                         actions)
                   (when (< (length samples)
                            supertag-ontology-migration-preview-sample-limit)
                     (push (list :node-id node-id
                                 :from old-value
                                 :to :drop
                                 :reason (error-message-string err))
                           samples)))
               (push
                (supertag-ontology-migration-field--issue
                 :error
                 (if (eq (car err)
                         'supertag-ontology-migration-impure-callback)
                     :impure-transformer
                   :field-transform-failed)
                 (format "Field %s value on node %s failed: %s"
                         key node-id (error-message-string err))
                 step)
                issues))))))
      ;; A transformer that turns existing values into nil is a common
      ;; silent bug (for example a `pcase' without a fallback).  Intentional
      ;; clearing stays allowed, so this is a warning rather than an error;
      ;; explicit removal should return `supertag-ontology-migration-drop'.
      (when (> cleared 0)
        (push
         (supertag-ontology-migration-field--issue
          :warning :transform-clears-value
          (format "Field %s transform maps %d non-nil value(s) to nil (for example node %s); return supertag-ontology-migration-drop to remove a value on purpose"
                  key cleared cleared-example)
          step)
         issues))))
    (list :step step
          :kind :transform-field
          :runtime-id runtime-id
          :scanned (length values)
          :changed changed
          :dropped dropped
          :cleared cleared
          :actions (nreverse actions)
          :samples (nreverse samples)
          :issues (nreverse issues))))

(defun supertag-ontology-migration-field-plan-detach (model step)
  "Build a no-data-action preview for detach-field STEP."
  (list :step step
        :kind :detach-field
        :type-runtime-id
        (supertag-ontology-migration-runtime-entity-id
         model :type (plist-get step :type))
        :field-runtime-id
        (supertag-ontology-migration-runtime-entity-id
         model :field (plist-get step :field))
        :actions nil
        :issues nil))

(defun supertag-ontology-migration-field-canonical-data (model step)
  "Return canonical live field data relevant to STEP."
  (when-let ((runtime-id
              (supertag-ontology-migration-runtime-entity-id
               model :field (plist-get step :field))))
    (list runtime-id
          (supertag-ontology-migration-field-values runtime-id))))

(provide 'supertag-ontology-migration-field)
;;; supertag-ontology-migration-field.el ends here
