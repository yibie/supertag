;;; supertag-ontology-adapter.el --- Deployment adapter to current Supertag Ops APIs. -*- lexical-binding: t; -*-

;;; Commentary:
;; This module is intentionally boring: each deployment operation maps to one
;; concrete, current Ops API.  No argument-list introspection or legacy name
;; guessing is allowed at this boundary.

;;; Code:

(require 'cl-lib)
(require 'supertag-schema-authority)
(require 'supertag-core-store)
(require 'supertag-ops-global-field)
(require 'supertag-ops-tag)
(require 'supertag-ops-link-definition)
(require 'supertag-ontology-model)

(defun supertag-ontology-adapter--field-record (entity &optional runtime-id)
  (let ((record (list :name (plist-get entity :label)
                      :type (plist-get entity :type)
                      :options (copy-sequence (plist-get entity :options)))))
    (when runtime-id (setq record (plist-put record :id runtime-id)))
    (setq record (plist-put record :required
                            (and (plist-get entity :required) t)))
    (when (plist-member entity :default)
      (setq record (plist-put record :default (plist-get entity :default))))
    record))

(defun supertag-ontology-adapter-create-field (entity)
  "Create FIELD ENTITY and return its runtime ID."
  (plist-get
   (supertag-global-field-create
    (supertag-ontology-adapter--field-record entity))
   :id))

(defun supertag-ontology-adapter-update-field (runtime-id entity)
  "Update FIELD RUNTIME-ID from ENTITY and return RUNTIME-ID."
  (supertag-global-field-update
   runtime-id
   (lambda (previous)
     (let ((updated (copy-tree previous)))
       (setq updated (plist-put updated :name (plist-get entity :label)))
       (setq updated (plist-put updated :type (plist-get entity :type)))
       (setq updated (plist-put updated :options
                                (copy-sequence (plist-get entity :options))))
       (setq updated (plist-put updated :required
                                (and (plist-get entity :required) t)))
       (if (plist-member entity :default)
           (setq updated (plist-put updated :default
                                    (plist-get entity :default)))
         (setq updated (plist-put updated :default nil)))
       updated)))
  runtime-id)

(defun supertag-ontology-adapter--type-aliases (entity)
  "Return occurrence tokens TYPE ENTITY must answer to besides its label.

The Tag `:name' carries the human label (for example \"Project\"), but
users write the ontology key in headings (for example `#project').
Occurrence matching is exact, so the key is declared as an alias, together
with every token declared under the type's `:aliases'."
  (supertag-ontology-model-type-aliases entity))

(defun supertag-ontology-adapter--assert-type-aliases-free (entity runtime-id)
  "Signal when a Tag other than RUNTIME-ID already owns one of ENTITY's aliases.
This runs before the Ops layer so the error names the ontology type."
  (dolist (alias (supertag-ontology-adapter--type-aliases entity))
    (let ((owner (supertag-tag-resolve-occurrence alias)))
      (when (and owner (not (equal owner runtime-id)))
        (user-error
         "Ontology type %s cannot claim occurrence token '%s': it is already owned by Tag %s"
         (plist-get entity :logical-id) alias owner)))))

(defun supertag-ontology-adapter--merge-type-aliases (previous managed)
  "Return PREVIOUS Tag data answering MANAGED ontology tokens.

The Tag layer normalizes the alias slot itself (id, name, display path) and
users may add tokens by hand; those are always kept.  Tokens recorded under
`:ontology-aliases' by an earlier deployment that are no longer MANAGED are
released, so a token dropped from the declaration stops resolving to the
type.  MANAGED is recorded as the new `:ontology-aliases'."
  (let* ((released (cl-set-difference
                    (plist-get previous :ontology-aliases) managed
                    :test #'equal))
         (kept (cl-remove-if (lambda (alias) (member alias released))
                             (plist-get previous :aliases)))
         (updated (plist-put previous :aliases (append kept managed))))
    (plist-put updated :ontology-aliases managed)))

(defun supertag-ontology-adapter-create-type (entity)
  "Create TYPE ENTITY and return its runtime ID.
The Tag is named after the label and aliased to the ontology-managed tokens,
which are also recorded on the Tag so later deployments can release them."
  (supertag-ontology-adapter--assert-type-aliases-free entity nil)
  (let* ((managed (supertag-ontology-adapter--type-aliases entity))
         (runtime-id
          (plist-get
           (supertag-tag-create
            (list :name (plist-get entity :label) :aliases managed))
           :id)))
    ;; `supertag-tag-create' only stores its own slots, so the managed
    ;; tokens are recorded in a follow-up update.
    (supertag-tag-update
     runtime-id
     (lambda (previous)
       (supertag-ontology-adapter--merge-type-aliases previous managed)))
    runtime-id))

(defun supertag-ontology-adapter-update-type (runtime-id entity)
  "Update TYPE RUNTIME-ID from ENTITY and return RUNTIME-ID.
User-added aliases are kept; ontology-managed tokens are added when missing
and released when the declaration no longer names them."
  (supertag-ontology-adapter--assert-type-aliases-free entity runtime-id)
  (let ((managed (supertag-ontology-adapter--type-aliases entity)))
    (supertag-tag-update
     runtime-id
     (lambda (previous)
       (supertag-ontology-adapter--merge-type-aliases
        (plist-put previous :name (plist-get entity :label))
        managed))))
  runtime-id)

(defun supertag-ontology-adapter-set-type-parent (type-id parent-id)
  "Set TYPE-ID parent to PARENT-ID."
  (supertag-tag-update
   type-id
   (lambda (previous) (plist-put previous :extends parent-id)))
  type-id)

(defun supertag-ontology-adapter-add-type-field (type-id field-id)
  "Associate FIELD-ID with TYPE-ID."
  (supertag-schema-authority-assert :type type-id :associate-field)
  (supertag-tag-associate-field type-id field-id)
  type-id)

(defun supertag-ontology-adapter-remove-type-field (type-id field-id)
  "Remove FIELD-ID association from TYPE-ID."
  (supertag-schema-authority-assert :type type-id :disassociate-field)
  (supertag-tag-disassociate-field type-id field-id)
  type-id)

(defun supertag-ontology-adapter-create-link (entity from-id to-id)
  "Create Link Definition ENTITY and return its runtime ID."
  (plist-get
   (supertag-link-definition-create
    (list :name (plist-get entity :label)
          :inverse-name (plist-get entity :inverse-label)
          :from-tag-id from-id :to-tag-id to-id
          :from-cardinality (plist-get entity :from-cardinality)
          :to-cardinality (plist-get entity :to-cardinality)
          :managed-by :ontology
          :ontology-module (plist-get entity :module)
          :ontology-key (plist-get entity :key)))
   :id))

(defun supertag-ontology-adapter-update-link (runtime-id entity from-id to-id)
  "Update Link Definition RUNTIME-ID and return it."
  (supertag-link-definition-update
   runtime-id
   (lambda (previous)
     (let ((updated (copy-tree previous)))
       (dolist (pair `((:name . ,(plist-get entity :label))
                       (:inverse-name . ,(plist-get entity :inverse-label))
                       (:from-tag-id . ,from-id)
                       (:to-tag-id . ,to-id)
                       (:from-cardinality . ,(plist-get entity :from-cardinality))
                       (:to-cardinality . ,(plist-get entity :to-cardinality))))
         (setq updated (plist-put updated (car pair) (cdr pair))))
       updated)))
  runtime-id)

(defun supertag-ontology-adapter--behavior-id (entity)
  "Return stable runtime identifier for Function, Action or Policy ENTITY."
  (or (plist-get entity :runtime-id)
      (format "ontology-%s-%s"
              (substring (symbol-name (plist-get entity :kind)) 1)
              (substring
               (secure-hash 'sha256 (plist-get entity :logical-id)) 0 24))))

(defun supertag-ontology-adapter-behavior-contract-hash (record)
  "Return stable contract hash for deployed behavior RECORD."
  (secure-hash
   'sha256
   (prin1-to-string
    (cl-loop for (key value) on record by #'cddr
             unless (memq key '(:description :contract-hash :raw))
             append (list key value)))))

(defun supertag-ontology-adapter--behavior-record
    (entity resolved &optional runtime-id)
  "Build deployed behavior record from ENTITY and RESOLVED references."
  (let* ((id (or runtime-id
                 (supertag-ontology-adapter--behavior-id entity)))
         (record (list :id id :runtime-id id
                       :kind (plist-get entity :kind)
                       :module (plist-get entity :module)
                       :key (plist-get entity :key)
                       :logical-id (plist-get entity :logical-id)
                       :label (plist-get entity :label)
                       :description (plist-get entity :description)
                       :subject-type-id (plist-get resolved :subject-type-id)
                       :parameters (copy-tree (plist-get resolved :parameters))
                       :llm-tool (and (plist-get entity :llm-tool) t)
                       :tool-name (plist-get entity :tool-name)
                       :tool-description (plist-get entity :tool-description))))
    (pcase (plist-get entity :kind)
      (:function
       (setq record
             (append record
                     (list :returns (copy-tree (plist-get resolved :returns))
                           :implementation (plist-get entity :implementation)))))
      (:action
       (setq record
             (append record
                     (list :preconditions
                           (copy-tree (plist-get resolved :preconditions))
                           :effects (copy-tree (plist-get resolved :effects))
                           :confirmation (plist-get entity :confirmation)))))
      (:policy
       (setq record
             (append record
                     (list :action-id (plist-get resolved :action-id)
                           :actors (copy-tree (plist-get entity :actors)))))))
    (plist-put record :contract-hash
               (supertag-ontology-adapter-behavior-contract-hash record))))

(defun supertag-ontology-adapter-create-behavior (entity resolved)
  "Create deployed Function, Action or Policy ENTITY using RESOLVED references."
  (let* ((record (supertag-ontology-adapter--behavior-record entity resolved))
         (collection (pcase (plist-get entity :kind)
                       (:function :ontology-functions)
                       (:action :ontology-actions)
                       (:policy :ontology-policies)))
         (id (plist-get record :id)))
    (when (supertag-store-get-entity collection id)
      (error "Ontology behavior runtime %s already exists" id))
    (supertag-store-put-entity collection id record t)
    id))

(defun supertag-ontology-adapter-update-behavior
    (runtime-id entity resolved)
  "Update deployed Function, Action or Policy RUNTIME-ID."
  (let* ((collection (pcase (plist-get entity :kind)
                       (:function :ontology-functions)
                       (:action :ontology-actions)
                       (:policy :ontology-policies)))
         (previous (supertag-store-get-entity collection runtime-id)))
    (unless previous
      (error "Ontology behavior runtime %s does not exist" runtime-id))
    (supertag-store-put-entity
     collection runtime-id
     (supertag-ontology-adapter--behavior-record
      entity resolved runtime-id)
     t)
    runtime-id))

(provide 'supertag-ontology-adapter)
;;; supertag-ontology-adapter.el ends here
