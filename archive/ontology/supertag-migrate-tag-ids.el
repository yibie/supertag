;;; supertag-migrate-tag-ids.el --- Migration script for UUID tag IDs to name-based IDs -*- lexical-binding: t; -*-

;;; Commentary:
;; This script migrates UUID-based tag IDs to name-based IDs in the supertag database.
;; It handles the complete migration process including:
;; 1. Tag entity ID updates
;; 2. Node tag list updates
;; 3. Node-tag relation updates
;; 4. Data consistency validation

;;; Code:

(require 'cl-lib)
(require 'supertag-core-store)
(require 'supertag-core-transform) ; For `supertag-with-transaction'
(require 'supertag-core-persistence) ; Validation and dirty-state helpers
(require 'supertag-ops-tag)
(require 'supertag-ops-node)
(require 'supertag-ops-relation)
(require 'supertag-ontology-adapter)

(defun supertag-migrate--is-uuid-tag-id-p (id)
  "Check if ID is a UUID-based tag ID.
Returns t if ID matches the UUID format used by old tag creation."
  (and (stringp id)
       (string-match-p
        "\\`id-[0-9]\\{8\\}-[0-9]\\{6\\}-[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\'"
        id)))

(defun supertag-migrate--get-tag-name-from-uuid-id (uuid-id)
  "Extract tag name from UUID-based tag ID.
For UUID IDs like 'id-20250827-215408-110aec2b-2b16-42b8-a53a-c804c671f038',
we need to get the actual tag name from the tag entity."
  (when-let* ((tag (supertag-tag-get uuid-id))
              (tag-name (plist-get tag :name)))
    tag-name))

(defun supertag-migrate--generate-new-tag-id (tag-name)
  "Generate new tag ID from tag name using the same sanitization logic."
  (supertag-sanitize-tag-name tag-name))

(defun supertag-migrate--find-all-uuid-tags ()
  "Find all UUID-based tags in the database.
Returns alist of (old-uuid-id . tag-data) pairs."
  (let ((uuid-tags '()))
    (maphash (lambda (id tag-data)
               (when (and (eq (plist-get tag-data :type) :tag)
                          (supertag-migrate--is-uuid-tag-id-p id))
                 (push (cons id tag-data) uuid-tags)))
             (supertag-store-get-collection :tags))
    uuid-tags))

(defun supertag-migrate--update-node-tags-list (node-id old-tag-id new-tag-id)
  "Update a node's tags list by replacing OLD-TAG-ID with NEW-TAG-ID."
  (supertag-node-update node-id
    (lambda (node)
      (let* ((tags (plist-get node :tags))
             (new-tags (mapcar (lambda (tag)
                                 (if (equal tag old-tag-id)
                                     new-tag-id
                                   tag))
                               tags)))
        (plist-put node :tags new-tags)))))

(defun supertag-migrate--update-all-node-tags (old-tag-id new-tag-id)
  "Update all nodes that reference OLD-TAG-ID to use NEW-TAG-ID."
  (maphash (lambda (node-id node-data)
             (when (and (eq (plist-get node-data :type) :node)
                        (member old-tag-id (plist-get node-data :tags)))
               (supertag-migrate--update-node-tags-list node-id old-tag-id new-tag-id)))
           (supertag-store-get-collection :nodes)))

(defun supertag-migrate--update-node-tag-relations (old-tag-id new-tag-id)
  "Update all node-tag relations from OLD-TAG-ID to NEW-TAG-ID."
  (let ((relations (supertag-relation-find-by-to old-tag-id :node-tag)))
    (dolist (relation relations)
      (let* ((relation-id (plist-get relation :id))
             (from-node-id (plist-get relation :from)))
        ;; Delete old relation
        (supertag-relation-delete relation-id)
        ;; Create new relation
        (supertag-relation-create
         (list :type :node-tag
               :from from-node-id
               :to new-tag-id
               :created-at (plist-get relation :created-at)))))))

(defun supertag-migrate--update-link-definition-endpoints
    (old-tag-id new-tag-id)
  "Rewrite Link Definition endpoints from OLD-TAG-ID to NEW-TAG-ID."
  (let (updates)
    (maphash
     (lambda (definition-id raw-definition)
       (let ((definition (copy-tree raw-definition))
             changed)
         (when (equal old-tag-id (plist-get definition :from-tag-id))
           (setq definition
                 (plist-put definition :from-tag-id new-tag-id)
                 changed t))
         (when (equal old-tag-id (plist-get definition :to-tag-id))
           (setq definition
                 (plist-put definition :to-tag-id new-tag-id)
                 changed t))
         (when changed
           (push (cons definition-id definition) updates))))
     (supertag-store-get-collection :link-definitions))
    (dolist (entry updates)
      (supertag-store-put-entity
       :link-definitions (car entry) (cdr entry) t))))

(defun supertag-migrate--rewrite-contract-type (type old-tag-id new-tag-id)
  "Rewrite OLD-TAG-ID to NEW-TAG-ID inside contract TYPE."
  (pcase type
    (`(:type ,runtime-id)
     (list :type (if (equal runtime-id old-tag-id)
                     new-tag-id runtime-id)))
    (`(:maybe ,inner)
     (list :maybe
           (supertag-migrate--rewrite-contract-type
            inner old-tag-id new-tag-id)))
    (`(:list ,inner)
     (list :list
           (supertag-migrate--rewrite-contract-type
            inner old-tag-id new-tag-id)))
    (_ type)))

(defun supertag-migrate--contract-has-uuid-tag-p (type)
  "Return non-nil when contract TYPE contains a legacy UUID Tag ID."
  (pcase type
    (`(:type ,runtime-id)
     (supertag-migrate--is-uuid-tag-id-p runtime-id))
    (`(:maybe ,inner)
     (supertag-migrate--contract-has-uuid-tag-p inner))
    (`(:list ,inner)
     (supertag-migrate--contract-has-uuid-tag-p inner))
    (_ nil)))

(defun supertag-migrate--update-ontology-behavior-types
    (old-tag-id new-tag-id)
  "Rewrite Function and Action Type references during Tag ID migration."
  (dolist (collection '(:ontology-functions :ontology-actions))
    (let (updates)
      (maphash
       (lambda (runtime-id raw)
         (let ((record (copy-tree raw)) changed)
           (when (equal old-tag-id (plist-get record :subject-type-id))
             (setq record (plist-put record :subject-type-id new-tag-id)
                   changed t))
           (when (plist-member record :parameters)
             (let ((rewritten
                    (mapcar
                     (lambda (parameter)
                       (let ((copy (copy-tree parameter)))
                         (plist-put
                          copy :type
                          (supertag-migrate--rewrite-contract-type
                           (plist-get parameter :type)
                           old-tag-id new-tag-id))))
                     (plist-get record :parameters))))
               (unless (equal rewritten (plist-get record :parameters))
                 (setq record (plist-put record :parameters rewritten)
                       changed t))))
           (when (plist-member record :returns)
             (let ((rewritten
                    (supertag-migrate--rewrite-contract-type
                     (plist-get record :returns) old-tag-id new-tag-id)))
               (unless (equal rewritten (plist-get record :returns))
                 (setq record (plist-put record :returns rewritten)
                       changed t))))
           (when changed
             (setq record
                   (plist-put
                    record :contract-hash
                    (supertag-ontology-adapter-behavior-contract-hash
                     record)))
             (push (cons runtime-id record) updates))))
       (supertag-store-get-collection collection))
      (dolist (entry updates)
        (supertag-store-put-entity collection (car entry) (cdr entry) t)))))

(defun supertag-migrate--update-ontology-type-bindings
    (old-tag-id new-tag-id)
  "Rewrite managed Ontology Type bindings after a Tag ID migration."
  (let (updates)
    (maphash
     (lambda (binding-id record)
       (when (and (eq (plist-get record :kind) :type)
                  (equal old-tag-id (plist-get record :runtime-id)))
         (push (cons binding-id
                     (plist-put (copy-tree record) :runtime-id new-tag-id))
               updates)))
     (supertag-store-get-collection :ontology-bindings))
    (dolist (entry updates)
      (supertag-store-put-entity
       :ontology-bindings (car entry) (cdr entry) t))))

(defun supertag-migrate--migrate-single-tag (old-tag-id tag-data)
  "Migrate a single UUID-based tag to name-based ID.
Returns new tag ID if successful, nil otherwise."
  (let* ((tag-name (plist-get tag-data :name))
         (new-tag-id (supertag-migrate--generate-new-tag-id tag-name)))

    ;; Check if new tag ID already exists (should not happen)
    (when (supertag-tag-get new-tag-id)
      (error "Cannot migrate tag %s: new ID %s already exists" old-tag-id new-tag-id))

    ;; Update tag entity ID
    (let ((updated-tag-data (plist-put (copy-sequence tag-data) :id new-tag-id)))
      (supertag-store-put-entity :tags new-tag-id updated-tag-data t)
      (supertag-migrate--update-link-definition-endpoints
       old-tag-id new-tag-id)
      (supertag-migrate--update-ontology-behavior-types
       old-tag-id new-tag-id)
      (supertag-migrate--update-ontology-type-bindings
       old-tag-id new-tag-id)
      (supertag-store-remove-entity :tags old-tag-id))

    ;; Update all node tag lists
    (supertag-migrate--update-all-node-tags old-tag-id new-tag-id)

    ;; Update all node-tag relations
    (supertag-migrate--update-node-tag-relations old-tag-id new-tag-id)

    new-tag-id))

(defun supertag-migrate-tag-ids ()
  "Safely migrate tag ID format.
Uses transaction mechanism to ensure data integrity,
automatically rolling back if migration fails."
  (interactive)
  (message "Starting safe tag ID migration...")

  (supertag-with-transaction
    (let ((uuid-tags (supertag-migrate--find-all-uuid-tags))
          (migrated-count 0)
          (migration-errors '()))

      (if (null uuid-tags)
          (message "No UUID-based tags found. Migration not needed.")

        (message "Found %d UUID-based tags to migrate..." (length uuid-tags))

        (dolist (tag-entry uuid-tags)
          (let* ((old-id (car tag-entry))
                 (tag-data (cdr tag-entry)))
            (condition-case err
                (progn
                  (supertag-migrate--migrate-single-tag old-id tag-data)
                  (cl-incf migrated-count)
                  (message "Migrated tag: %s -> %s" old-id (plist-get tag-data :name)))
              (error
               (push (format "Failed to migrate tag %s: %s" old-id (error-message-string err))
                     migration-errors)))))

        ;; 验证迁移结果
        (if migration-errors
            (progn
              (message "Migration completed with %d errors:" (length migration-errors))
              (dolist (err migration-errors)
                (message "  %s" err))
              (error "Tag ID migration failed with errors"))

          (if (supertag--validate-tag-references)
              (progn
                (message "Tag ID migration completed successfully!")
                (message "Migrated %d UUID-based tags to name-based IDs" migrated-count)
                (supertag-mark-dirty))
            (error "Migration validation failed - data consistency check failed")))))))

(defun supertag-migrate--validate-migration ()
  "Validate that the migration was successful.
Checks that no UUID-based tags remain and all references are updated."
  (let ((remaining-uuid-tags (supertag-migrate--find-all-uuid-tags))
        (validation-errors '()))

    ;; Check for remaining UUID tags
    (when remaining-uuid-tags
      (push (format "Found %d remaining UUID-based tags" (length remaining-uuid-tags))
            validation-errors))

    ;; Check for orphaned node tag references
    (maphash (lambda (node-id node-data)
               (when (eq (plist-get node-data :type) :node)
                 (dolist (tag-id (plist-get node-data :tags))
                   (when (supertag-migrate--is-uuid-tag-id-p tag-id)
                     (push (format "Node %s has orphaned UUID tag reference: %s" node-id tag-id)
                           validation-errors)))))
             (supertag-store-get-collection :nodes))

    ;; Check for orphaned relations
    (maphash (lambda (_relation-id relation-data)
               (when (and (eq (plist-get relation-data :type) :node-tag)
                          (supertag-migrate--is-uuid-tag-id-p (plist-get relation-data :to)))
                 (push (format "Orphaned node-tag relation: %s -> %s"
                               (plist-get relation-data :from) (plist-get relation-data :to))
                       validation-errors)))
             (supertag-store-get-collection :relations))

    ;; Check for orphaned Link Definition endpoint types.
    (maphash
     (lambda (definition-id definition)
       (dolist (slot '(:from-tag-id :to-tag-id))
         (let ((tag-id (plist-get definition slot)))
           (when (supertag-migrate--is-uuid-tag-id-p tag-id)
             (push (format "Link Definition %s has orphaned UUID endpoint %s: %s"
                           definition-id slot tag-id)
                   validation-errors)))))
     (supertag-store-get-collection :link-definitions))

    ;; Check deployed Function and Action subject/parameter/return Type refs.
    (dolist (collection '(:ontology-functions :ontology-actions))
      (maphash
       (lambda (runtime-id record)
         (when (supertag-migrate--is-uuid-tag-id-p
                (plist-get record :subject-type-id))
           (push (format "%s %s has orphaned subject Type %s"
                         collection runtime-id
                         (plist-get record :subject-type-id))
                 validation-errors))
         (when (or
                (cl-some
                 (lambda (parameter)
                   (supertag-migrate--contract-has-uuid-tag-p
                    (plist-get parameter :type)))
                 (plist-get record :parameters))
                (supertag-migrate--contract-has-uuid-tag-p
                 (plist-get record :returns)))
           (push (format "%s %s has an orphaned contract Type"
                         collection runtime-id)
                 validation-errors)))
       (supertag-store-get-collection collection)))

    (maphash
     (lambda (binding-id record)
       (when (and (eq (plist-get record :kind) :type)
                  (supertag-migrate--is-uuid-tag-id-p
                   (plist-get record :runtime-id)))
         (push (format "Ontology binding %s has orphaned Type runtime %s"
                       binding-id (plist-get record :runtime-id))
               validation-errors)))
     (supertag-store-get-collection :ontology-bindings))

    (if validation-errors
        (progn
          (message "Validation failed with %d errors:" (length validation-errors))
          (dolist (error validation-errors)
            (message "  %s" error))
          nil)
      (message "Migration validation passed!")
      t)))

(defun supertag-migrate-tag-ids-with-validation ()
  "Perform migration followed by validation."
  (interactive)
  (supertag-migrate-tag-ids)
  (supertag-migrate--validate-migration))

(provide 'supertag-migrate-tag-ids)
;;; supertag-migrate-tag-ids.el ends here
