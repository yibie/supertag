;;; supertag-ontology-migration-runtime.el --- Store-owned migration ledger -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Applied migration records live in the canonical Supertag Store.  They are
;; control metadata, not another copy of the ontology schema.

;;; Code:

(require 'cl-lib)
(require 'supertag-core-store)
(require 'supertag-ontology-model)
(require 'supertag-ontology-runtime)


(defun supertag-ontology-migration-runtime-entity-id (model kind key)
  "Resolve MODEL's KIND entity KEY to its current runtime ID."
  (when-let ((entity (supertag-ontology-model-find model kind key)))
    (or (plist-get entity :runtime-id)
        (plist-get
         (supertag-ontology-runtime-binding-get
          (plist-get model :module) kind key)
         :runtime-id))))

(defun supertag-ontology-migration-runtime-field-key (model runtime-id)
  "Return MODEL field key bound to RUNTIME-ID, or nil."
  (or
   (when-let ((entity
               (cl-find-if
                (lambda (candidate)
                  (equal runtime-id
                         (supertag-ontology-migration-runtime-entity-id
                          model :field (plist-get candidate :key))))
                (plist-get model :fields))))
     (plist-get entity :key))
   (when-let ((binding
               (cl-find-if
                (lambda (record)
                  (and (eq (plist-get record :kind) :field)
                       (equal runtime-id (plist-get record :runtime-id))))
                (supertag-ontology-runtime-bindings
                 (plist-get model :module)))))
     (plist-get binding :key))))

(defun supertag-ontology-migration-runtime-key (logical-id)
  "Return durable Store key for migration LOGICAL-ID."
  (format "%s" logical-id))

(defun supertag-ontology-migration-runtime-get (logical-id)
  "Return applied migration record for LOGICAL-ID, or nil."
  (supertag-store-get-entity
   :ontology-migrations
   (supertag-ontology-migration-runtime-key logical-id)))

(defun supertag-ontology-migration-runtime-put (record)
  "Persist applied migration RECORD through the Store transaction seam."
  (let ((logical-id (plist-get record :logical-id)))
    (unless (and (stringp logical-id) (> (length logical-id) 0))
      (error "Migration ledger record requires :logical-id"))
    (supertag-store-put-entity
     :ontology-migrations
     (supertag-ontology-migration-runtime-key logical-id)
     (copy-tree record))))

(defun supertag-ontology-migration-runtime-list (&optional module)
  "Return applied migration records, optionally restricted to MODULE."
  (let (records)
    (maphash
     (lambda (_id record)
       (when (or (null module)
                 (equal module (plist-get record :module)))
         (push (copy-tree record) records)))
     (supertag-store-get-collection :ontology-migrations))
    (sort records
          (lambda (left right)
            (let ((left-time (or (plist-get left :applied-at) 0))
                  (right-time (or (plist-get right :applied-at) 0)))
              (if (= left-time right-time)
                  (string< (or (plist-get left :logical-id) "")
                           (or (plist-get right :logical-id) ""))
                (< left-time right-time)))))))

(provide 'supertag-ontology-migration-runtime)
;;; supertag-ontology-migration-runtime.el ends here
