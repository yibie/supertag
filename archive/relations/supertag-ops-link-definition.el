;;; supertag-ops-link-definition.el --- Typed Link definitions for Supertag -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Keywords: outlines, data, ontology
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;;
;; A Link Definition is schema.  A Relation is an instance.
;;
;; Link definitions live in the durable `:link-definitions' Store collection
;; and describe which semantic types may be connected and with what
;; cardinality.  Concrete edges continue to live in `:relations'.  This file
;; deliberately does not depend on `supertag-ops-relation', so the relation
;; module can consume this contract without creating a require cycle.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-core-transform)


(declare-function supertag-relation-delete "supertag-ops-relation" (id))

(defgroup supertag-link-definition nil
  "Typed semantic links for Supertag."
  :group 'supertag)

(defconst supertag-link-definition-cardinalities '(:one :many)
  "Cardinalities accepted for either end of a Link Definition.")

(defvar supertag-link-definition--deployment-in-progress nil
  "Non-nil while Ontology deployment owns Link Definition writes.")

(defun supertag-link-definition--new-id ()
  "Return a fresh opaque Link Definition identifier."
  (let (id)
    (while (or (null id) (supertag-link-definition-get id))
      (setq id
            (concat
             "linkdef-"
             (substring
              (secure-hash
               'sha256
               (format "%s|%s|%s|%s"
                       (float-time) (random) (emacs-pid) (user-uid)))
              0 32))))
    id))

(defun supertag-link-definition--ensure-plist (value)
  "Return VALUE as a copied plist."
  (cond
   ((null value) nil)
   ((hash-table-p value)
    (let (result)
      (maphash (lambda (key item)
                 (setq result (plist-put result key item)))
               value)
      result))
   ((listp value) (copy-tree value))
   (t (error "Invalid Link Definition value: %S" value))))

(defun supertag-link-definition--normalize-cardinality (value default)
  "Normalize cardinality VALUE, using DEFAULT when VALUE is nil."
  (let ((normalized
         (cond
          ((null value) default)
          ((keywordp value) value)
          ((symbolp value) (intern (concat ":" (symbol-name value))))
          ((stringp value) (intern (concat ":" (downcase value))))
          (t value))))
    (unless (memq normalized supertag-link-definition-cardinalities)
      (error "Invalid Link cardinality %S; expected one of %S"
             value supertag-link-definition-cardinalities))
    normalized))

(defun supertag-link-definition--normalize (props &optional existing)
  "Return canonical Link Definition from PROPS and optional EXISTING value."
  (let* ((input (supertag-link-definition--ensure-plist props))
         (previous (supertag-link-definition--ensure-plist existing))
         (id (or (plist-get input :id)
                 (plist-get previous :id)
                 (supertag-link-definition--new-id)))
         (name (or (plist-get input :name)
                   (plist-get input :label)
                   (plist-get previous :name)))
         (from-tag-id (or (plist-get input :from-tag-id)
                          (plist-get input :from)
                          (plist-get previous :from-tag-id)))
         (to-tag-id (or (plist-get input :to-tag-id)
                        (plist-get input :to)
                        (plist-get previous :to-tag-id)))
         (from-cardinality
          (supertag-link-definition--normalize-cardinality
           (if (plist-member input :from-cardinality)
               (plist-get input :from-cardinality)
             (and (plist-member input :cardinality)
                  (plist-get input :cardinality)))
           (or (plist-get previous :from-cardinality) :many)))
         (to-cardinality
          (supertag-link-definition--normalize-cardinality
           (and (plist-member input :to-cardinality)
                (plist-get input :to-cardinality))
           (or (plist-get previous :to-cardinality) :many)))
         (now (current-time))
         (result
          (list :id id
                :name name
                :description
                (if (plist-member input :description)
                    (plist-get input :description)
                  (plist-get previous :description))
                :from-tag-id from-tag-id
                :to-tag-id to-tag-id
                :from-cardinality from-cardinality
                :to-cardinality to-cardinality
                :inverse-name
                (if (or (plist-member input :inverse-name)
                        (plist-member input :inverse-label))
                    (or (plist-get input :inverse-name)
                        (plist-get input :inverse-label))
                  (plist-get previous :inverse-name))
                :managed-by (or (plist-get input :managed-by)
                                (plist-get previous :managed-by)
                                :interactive)
                :ontology-module (or (plist-get input :ontology-module)
                                     (plist-get previous :ontology-module))
                :ontology-key (or (plist-get input :ontology-key)
                                  (plist-get previous :ontology-key))
                :created-at (or (plist-get previous :created-at)
                                (plist-get input :created-at)
                                now)
                :modified-at now)))
    result))

(defun supertag-link-definition--tag-exists-p (tag-id)
  "Return non-nil when TAG-ID names an existing semantic Tag."
  (and (stringp tag-id)
       (supertag-store-get-entity :tags tag-id)))

(defun supertag-link-definition-validate (definition)
  "Validate DEFINITION and return it."
  (let ((id (plist-get definition :id))
        (name (plist-get definition :name))
        (from-tag-id (plist-get definition :from-tag-id))
        (to-tag-id (plist-get definition :to-tag-id))
        (from-cardinality (plist-get definition :from-cardinality))
        (to-cardinality (plist-get definition :to-cardinality))
        (inverse-name (plist-get definition :inverse-name)))
    (unless (and (stringp id) (not (string-empty-p id)))
      (error "Link Definition requires a non-empty string :id: %S" definition))
    (unless (and (stringp name) (not (string-empty-p name)))
      (error "Link Definition %s requires a non-empty string :name" id))
    (unless (supertag-link-definition--tag-exists-p from-tag-id)
      (error "Link Definition %s references missing source Tag %S" id from-tag-id))
    (unless (supertag-link-definition--tag-exists-p to-tag-id)
      (error "Link Definition %s references missing target Tag %S" id to-tag-id))
    (unless (memq from-cardinality supertag-link-definition-cardinalities)
      (error "Link Definition %s has invalid source cardinality %S"
             id from-cardinality))
    (unless (memq to-cardinality supertag-link-definition-cardinalities)
      (error "Link Definition %s has invalid target cardinality %S"
             id to-cardinality))
    (unless (memq (plist-get definition :managed-by) '(:interactive :ontology))
      (error "Link Definition %s has invalid :managed-by %S"
             id (plist-get definition :managed-by)))
    (when (eq (plist-get definition :managed-by) :ontology)
      (unless (symbolp (plist-get definition :ontology-module))
        (error "Ontology-managed Link Definition %s requires symbol :ontology-module"
               id))
      (unless (symbolp (plist-get definition :ontology-key))
        (error "Ontology-managed Link Definition %s requires symbol :ontology-key"
               id)))
    (when (and inverse-name
               (not (and (stringp inverse-name)
                         (not (string-empty-p inverse-name)))))
      (error "Link Definition %s has invalid :inverse-name %S"
             id inverse-name))
    definition))

(defun supertag-link-definition-get (id)
  "Return Link Definition ID, or nil when absent."
  (supertag-store-get-entity :link-definitions id))

(defun supertag-link-definition-list ()
  "Return every Link Definition sorted by display name and identifier."
  (let (result)
    (maphash (lambda (_id definition) (push definition result))
             (supertag-store-get-collection :link-definitions))
    (sort result
          (lambda (left right)
            (string-lessp
             (format "%s\0%s" (or (plist-get left :name) "")
                     (or (plist-get left :id) ""))
             (format "%s\0%s" (or (plist-get right :name) "")
                     (or (plist-get right :id) "")))))))

(defun supertag-link-definition-find-by-ontology-key (module key)
  "Return Link Definition owned by ontology MODULE and logical KEY."
  (seq-find
   (lambda (definition)
     (and (eq module (plist-get definition :ontology-module))
            (eq key (plist-get definition :ontology-key))))
   (supertag-link-definition-list)))

(defun supertag-link-definition-find-by-tag (tag-id)
  "Return Link Definitions whose source or target type is TAG-ID."
  (seq-filter
   (lambda (definition)
     (or (equal tag-id (plist-get definition :from-tag-id))
         (equal tag-id (plist-get definition :to-tag-id))))
   (supertag-link-definition-list)))

(defun supertag-link-definition-assert-tag-deletable (tag-id)
  "Reject deletion of TAG-ID while a Link Definition depends on it."
  (let ((definitions (supertag-link-definition-find-by-tag tag-id)))
    (when definitions
      (user-error
       "Tag %s is used by Link Definition(s): %s"
       tag-id
       (mapconcat
        (lambda (definition)
          (or (plist-get definition :name) (plist-get definition :id)))
        definitions ", ")))))

(defun supertag-link-definition-managed-p (id)
  "Return non-nil when Link Definition ID is controlled by Ontology."
  (eq (plist-get (supertag-link-definition-get id) :managed-by) :ontology))

(defun supertag-link-definition-assert-editable (id)
  "Reject ordinary mutation of ontology-managed definition ID."
  (when (supertag-link-definition-managed-p id)
    (let ((definition (supertag-link-definition-get id)))
      (user-error
       "Link Definition %s is managed by ontology module %s; edit its ontology source"
       (or (plist-get definition :name) id)
       (or (plist-get definition :ontology-module) "unknown")))))

(defun supertag-link-definition-create (props)
  "Create a Link Definition from PROPS."
  (let* ((definition
          (supertag-link-definition-validate
           (supertag-link-definition--normalize props)))
         (id (plist-get definition :id)))
    (when (supertag-link-definition-get id)
      (error "Link Definition %s already exists" id))
    (when (and (eq (plist-get definition :managed-by) :ontology)
               (supertag-link-definition-find-by-ontology-key
                (plist-get definition :ontology-module)
                (plist-get definition :ontology-key)))
      (error "Ontology Link %s/%s is already bound to another definition"
             (plist-get definition :ontology-module)
             (plist-get definition :ontology-key)))
    (supertag-ops-commit
     :operation :create
     :collection :link-definitions
     :id id
     :new definition
     :perform (lambda ()
                (supertag-store-put-entity
                 :link-definitions id definition)
                definition))))


(defun supertag-link-definition-change-requires-migration-p
    (previous candidate)
  "Return non-nil when PREVIOUS to CANDIDATE needs data migration."
  (or (not (equal (plist-get previous :from-tag-id)
                  (plist-get candidate :from-tag-id)))
      (not (equal (plist-get previous :to-tag-id)
                  (plist-get candidate :to-tag-id)))
      (and (eq (plist-get previous :from-cardinality) :many)
           (eq (plist-get candidate :from-cardinality) :one))
      (and (eq (plist-get previous :to-cardinality) :many)
           (eq (plist-get candidate :to-cardinality) :one))))

(defun supertag-link-definition-update (id updater)
  "Update Link Definition ID using UPDATER."

  (supertag-link-definition-assert-editable id)
  (let ((previous (supertag-link-definition-get id)))
    (unless previous
      (error "Link Definition %s does not exist" id))
    (let* ((candidate (funcall updater (copy-tree previous)))
           (normalized
            (supertag-link-definition-validate
             (supertag-link-definition--normalize
              (plist-put candidate :id id) previous)))
           (instances (supertag-link-definition-instance-relations id))
           (binding
            (and (eq (plist-get normalized :managed-by) :ontology)
                 (supertag-link-definition-find-by-ontology-key
                  (plist-get normalized :ontology-module)
                  (plist-get normalized :ontology-key)))))
      (when (and (eq (plist-get previous :managed-by) :ontology)
                 (not (eq (plist-get normalized :managed-by) :ontology)))
        (error "Ontology-managed Link Definition %s cannot be detached by update"
               id))
      (when (and (eq (plist-get previous :managed-by) :ontology)
                 (or (not (eq (plist-get previous :ontology-module)
                              (plist-get normalized :ontology-module)))
                     (not (eq (plist-get previous :ontology-key)
                              (plist-get normalized :ontology-key)))))
        (error "Link Definition %s is already owned by ontology %s/%s and cannot be rebound"
               id (plist-get previous :ontology-module)
               (plist-get previous :ontology-key)))
      (when (and binding (not (equal id (plist-get binding :id))))
        (error "Ontology Link %s/%s is already bound to Link Definition %s"
               (plist-get normalized :ontology-module)
               (plist-get normalized :ontology-key)
               (plist-get binding :id)))
      (when (and instances
                 (not
                  (cl-every
                   (lambda (key)
                     (equal (plist-get previous key)
                            (plist-get normalized key)))
                   '(:from-tag-id :to-tag-id
                     :from-cardinality :to-cardinality))))
        (cond

         ((supertag-link-definition-change-requires-migration-p
           previous normalized)
          (user-error
           "Link Definition %s has instances; migrate endpoint changes or cardinality tightening"
           id))
         (t
          ;; Cardinality relaxation cannot invalidate an existing instance.
          (supertag-link-definition-validate-instances-against
           normalized instances))))
      (supertag-ops-commit
       :operation :update
       :collection :link-definitions
       :id id
       :previous previous
       :new normalized
       :perform (lambda ()
                  (supertag-store-put-entity
                   :link-definitions id normalized)
                  normalized)))))

(defun supertag-link-definition-instance-relations (id)
  "Return concrete relation instances governed by Link Definition ID."
  (let (result)
    (maphash
     (lambda (_relation-id relation)
       (when (and (eq (plist-get relation :type) :ontology-link)
                  (equal id (plist-get relation :link-definition-id)))
         (push relation result)))
     (supertag-store-get-collection :relations))
    (nreverse result)))

(defun supertag-link-definition-validate-instances-against
    (definition instances)
  "Validate INSTANCES against candidate Link DEFINITION.

This is intentionally stricter than the ordinary update guard.  It is used by
the migration actor after conflicting instances have been removed, immediately
before the candidate schema is committed."
  (let ((from-counts (make-hash-table :test #'equal))
        (to-counts (make-hash-table :test #'equal)))
    (dolist (relation instances)
      (let ((from-id (plist-get relation :from))
            (to-id (plist-get relation :to)))
        (unless (supertag-link-definition-node-satisfies-type-p
                 from-id (plist-get definition :from-tag-id))
          (error "Link instance %s source %s does not satisfy migrated source type %s"
                 (plist-get relation :id) from-id
                 (plist-get definition :from-tag-id)))
        (unless (supertag-link-definition-node-satisfies-type-p
                 to-id (plist-get definition :to-tag-id))
          (error "Link instance %s target %s does not satisfy migrated target type %s"
                 (plist-get relation :id) to-id
                 (plist-get definition :to-tag-id)))
        (puthash from-id (1+ (gethash from-id from-counts 0)) from-counts)
        (puthash to-id (1+ (gethash to-id to-counts 0)) to-counts)))
    (when (eq (plist-get definition :from-cardinality) :one)
      (maphash
       (lambda (from-id count)
         (when (> count 1)
           (error "Migrated Link %s still has %d targets for source %s"
                  (plist-get definition :name) count from-id)))
       from-counts))
    (when (eq (plist-get definition :to-cardinality) :one)
      (maphash
       (lambda (to-id count)
         (when (> count 1)
           (error "Migrated Link %s still has %d sources for target %s"
                  (plist-get definition :name) count to-id)))
       to-counts))
    t))

(defun supertag-link-definition-delete (id &optional cascade)
  "Delete Link Definition ID.
Refuse while concrete instances exist unless CASCADE is non-nil."

  (supertag-link-definition-assert-editable id)
  (let ((previous (supertag-link-definition-get id)))
    (unless previous
      (error "Link Definition %s does not exist" id))
    (let ((instances (supertag-link-definition-instance-relations id)))
      (when (and instances (not cascade))
        (user-error
         "Link Definition %s has %d instance(s); delete them first or use cascade"
         id (length instances)))
      (supertag-with-transaction
        (when instances
          (unless (fboundp 'supertag-relation-delete)
            (error "Relation operations are unavailable for cascade deletion"))
          (dolist (relation instances)
            (supertag-relation-delete (plist-get relation :id))))
        (supertag-ops-commit
         :operation :delete
         :collection :link-definitions
         :id id
         :previous previous
         :perform (lambda ()
                    (supertag-store-remove-entity :link-definitions id)
                    nil))))))

(defun supertag-link-definition--tag-descends-from-p (candidate required)
  "Return non-nil when CANDIDATE is REQUIRED or inherits from it."
  (let ((current candidate)
        (seen (make-hash-table :test #'equal))
        found)
    (while (and current (not found) (not (gethash current seen)))
      (puthash current t seen)
      (if (equal current required)
          (setq found t)
        (setq current
              (plist-get (supertag-store-get-entity :tags current) :extends))))
    found))

(defun supertag-link-definition-node-satisfies-type-p (node-id required-tag-id)
  "Return non-nil when NODE-ID has REQUIRED-TAG-ID or one of its subtypes."
  (let ((node (supertag-store-get-entity :nodes node-id)))
    (and node
         (seq-some
          (lambda (tag-id)
            (supertag-link-definition--tag-descends-from-p
             tag-id required-tag-id))
          (plist-get node :tags)))))

(defun supertag-link-definition--matching-instance-p
    (relation definition-id &optional excluded-relation-id)
  "Return non-nil when RELATION is an instance of DEFINITION-ID.
EXCLUDED-RELATION-ID is ignored during an update validation."
  (and relation
       (eq (plist-get relation :type) :ontology-link)
       (not (equal excluded-relation-id (plist-get relation :id)))
       (equal definition-id (plist-get relation :link-definition-id))))

(defun supertag-link-definition-validate-instance
    (definition-id from-id to-id &optional excluded-relation-id)
  "Validate one concrete edge governed by DEFINITION-ID.
FROM-ID and TO-ID are node IDs.  EXCLUDED-RELATION-ID is ignored when checking
cardinality, which allows an existing relation to be updated in place."
  (let ((definition (supertag-link-definition-get definition-id)))
    (unless definition
      (error "Unknown Link Definition %s" definition-id))
    (unless (supertag-store-get-entity :nodes from-id)
      (error "Link source node %s does not exist" from-id))
    (unless (supertag-store-get-entity :nodes to-id)
      (error "Link target node %s does not exist" to-id))
    (unless (supertag-link-definition-node-satisfies-type-p
             from-id (plist-get definition :from-tag-id))
      (error "Node %s does not satisfy Link source type %s"
             from-id (plist-get definition :from-tag-id)))
    (unless (supertag-link-definition-node-satisfies-type-p
             to-id (plist-get definition :to-tag-id))
      (error "Node %s does not satisfy Link target type %s"
             to-id (plist-get definition :to-tag-id)))
    (let ((relations (supertag-store-get-collection :relations)))
      (when (eq (plist-get definition :from-cardinality) :one)
        (maphash
         (lambda (_id relation)
           (when (and
                  (supertag-link-definition--matching-instance-p
                   relation definition-id excluded-relation-id)
                  (equal from-id (plist-get relation :from))
                  (not (equal to-id (plist-get relation :to))))
             (error
              "Link %s permits only one target for source node %s"
              (plist-get definition :name) from-id)))
         relations))
      (when (eq (plist-get definition :to-cardinality) :one)
        (maphash
         (lambda (_id relation)
           (when (and
                  (supertag-link-definition--matching-instance-p
                   relation definition-id excluded-relation-id)
                  (equal to-id (plist-get relation :to))
                  (not (equal from-id (plist-get relation :from))))
             (error
              "Link %s permits only one source for target node %s"
              (plist-get definition :name) to-id)))
         relations)))
    definition))

(defun supertag-link-definition-reference (definition)
  "Return a stable human-facing reference for DEFINITION."
  (let* ((module (plist-get definition :ontology-module))
         (key (plist-get definition :ontology-key)))
    (if (and module key)
        (format "%s/%s" module key)
      (plist-get definition :id))))

(defun supertag-link-definition-resolve (reference &optional noerror)
  "Resolve REFERENCE to one Link Definition.
REFERENCE may be a runtime ID, `module/key', a unique ontology key, or a
unique display name.  Signal on unknown or ambiguous references unless
NOERROR is non-nil."
  (let* ((text (cond ((symbolp reference) (symbol-name reference))
                     ((stringp reference) reference)
                     (t nil)))
         (definitions (supertag-link-definition-list))
         (exact (and text (supertag-link-definition-get text)))
         matches)
    (cond
     (exact exact)
     ((and text (string-match "\\`\\([^/]+\\)/\\([^/]+\\)\\'" text))
      (let ((module (intern (match-string 1 text)))
            (key (intern (match-string 2 text))))
        (setq matches
              (cl-remove-if-not
               (lambda (definition)
                 (and (eq module
                            (plist-get definition :ontology-module))
                        (eq key
                            (plist-get definition :ontology-key))))
               definitions))))
     (text
      (let ((key (intern text)))
        (setq matches
              (cl-remove-if-not
               (lambda (definition)
                 (or (eq key (plist-get definition :ontology-key))
                       (equal text (plist-get definition :name))))
               definitions)))))
    (cond
     (exact exact)
     ((= (length matches) 1) (car matches))
     ((> (length matches) 1)
      (unless noerror
        (user-error "Ambiguous Link Definition %S; use module/key or runtime ID"
                    reference)))
     (t
      (unless noerror
        (user-error "Unknown Link Definition %S" reference))))))

(defun supertag-link-definition-tag-name (tag-id)
  "Return the display name of TAG-ID."
  (let ((tag (supertag-store-get-entity :tags tag-id)))
    (or (plist-get tag :name) tag-id)))

(defun supertag-link-definition-format (definition)
  "Return a compact readable description of DEFINITION."
  (format "%s: %s [%s] -> [%s] %s"
          (or (plist-get definition :name) (plist-get definition :id))
          (supertag-link-definition-tag-name
           (plist-get definition :from-tag-id))
          (substring (symbol-name (plist-get definition :from-cardinality)) 1)
          (substring (symbol-name (plist-get definition :to-cardinality)) 1)
          (supertag-link-definition-tag-name
           (plist-get definition :to-tag-id))))

(provide 'supertag-ops-link-definition)
;;; supertag-ops-link-definition.el ends here
