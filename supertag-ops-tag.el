;;; supertag/ops/tag.el --- Tag operations for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file provides standardized operations for Tag entities in the
;; Supertag data-centric architecture. All operations leverage
;; the core transform mechanism and adhere to the defined schema.

;;; Code:

(require 'cl-lib)
(require 'org-id)
(require 'subr-x)
(require 'supertag-core-index)
(require 'supertag-core-store)
(require 'supertag-core-schema)
(require 'supertag-core-tag-path)
(require 'supertag-core-transform)
(require 'supertag-ops-link-definition)
(require 'supertag-ops-relation)
(require 'supertag-ops-node)
(require 'supertag-ops-schema)
(require 'supertag-ops-global-field)
(require 'supertag-schema-authority)


(declare-function supertag-tag-path-rename-plan
                  "supertag-ops-tag-merge" (old-root new-root))
(declare-function supertag-tag-path-rename-execute
                  "supertag-ops-tag-merge" (plan))

(declare-function supertag-query-saved-map-forms "supertag-query-library" (function))
(declare-function supertag-view-config-list "supertag-view-framework" ())

;;; --- Internal Helper ---

(defun supertag--validate-tag-data (data)
  "Strict validation for tag data. Fails fast on any inconsistency.
Implements immediate error reporting as preferred by the user."
  (unless (plist-get data :id)
    (error "Tag missing required :id field: %S" data))
  (unless (plist-get data :name)
    (error "Tag missing required :name field: %S" data))
  (when-let* ((aliases (plist-get data :aliases)))
    (unless (and (proper-list-p aliases) (cl-every #'stringp aliases))
      (error "Tag :aliases must be a list of strings, got: %S" aliases)))
  ;; Validate time format compliance (Emacs native format)
  (when-let ((created-at (plist-get data :created-at)))
    (unless (condition-case nil
                (progn (format-time-string "%s" created-at) t)
              (error nil))
      (error "Tag :created-at must use Emacs time format, got: %S" created-at)))
  (when-let ((modified-at (plist-get data :modified-at)))
    (unless (condition-case nil
                (progn (format-time-string "%s" modified-at) t)
              (error nil))
      (error "Tag :modified-at must use Emacs time format, got: %S" modified-at))))

(defun supertag--ensure-plist (data)
  "Ensure DATA is in plist format, converting from hash table if necessary."
  (if (hash-table-p data)
      (let ((plist '()))
        (maphash (lambda (k v)
                   (setq plist (plist-put plist k v)))
                 data)
        plist)
    data))

(defun supertag--deep-copy-plist (plist)
  "Create a deep copy of PLIST, recursively copying nested lists.
This ensures that modifications to the copy do not affect the original."
  (if (not (listp plist))
      plist
    (let ((result '()))
      (while plist
        (let ((key (car plist))
              (val (cadr plist)))
          (setq result
                (plist-put result key
                           (cond
                            ;; Recursively copy nested plists (keyword-prefixed lists)
                            ((and (listp val) (keywordp (car-safe val)))
                             (supertag--deep-copy-plist val))
                            ;; Copy lists of plists (like :fields)
                            ((and (listp val) (listp (car-safe val)))
                             (mapcar #'supertag--deep-copy-plist val))
                            ;; Copy simple lists
                            ((listp val)
                             (copy-sequence val))
                            ;; Non-list values are copied as-is
                            (t val)))))
        (setq plist (cddr plist)))
      result)))

(defun supertag--normalize-tag-extends (tag)
  "Normalize the :extends field in TAG plist to a sanitized tag id or nil."
  (if (plist-member tag :extends)
      (let* ((ext (plist-get tag :extends))
             (normalized (and (stringp ext)
                               (not (string-empty-p ext))
                               (supertag-sanitize-tag-name ext))))
        (plist-put tag :extends normalized))
    tag))

;; ID generation is now handled by supertag-id-utils.el

(defun supertag-tag-stable-id-p (value)
  "Return non-nil when VALUE has the Stable Semantic Tag ID shape."
  (and (stringp value)
       (string-match-p "\\`tag-[0-9a-f]\\{32\\}\\'" value)))

(defun supertag-tag--new-stable-id ()
  "Return a fresh Stable Semantic Tag ID."
  (let (id)
    (while (or (null id) (supertag-tag-get id))
      (setq id
            (concat "tag-"
                    (replace-regexp-in-string
                     "-" "" (downcase (org-id-uuid))))))
    id))

(defvar supertag-tag--token-index (make-hash-table :test 'equal)
  "Index: normalized occurrence token -> sorted Semantic Tag IDs.")

(defvar supertag-tag--display-path-index (make-hash-table :test 'equal)
  "Index: Semantic Tag ID -> canonical display path.")

(defvar supertag-tag--descendants-index (make-hash-table :test 'equal)
  "Index: Semantic Tag ID -> transitive descendant IDs.")

(defvar supertag-tag--index-source-token nil
  "Source token represented by the Tag indexes.")

(defun supertag-tag-index-clear ()
  "Clear every Semantic Tag lookup index."
  (setq supertag-tag--token-index (make-hash-table :test 'equal)
        supertag-tag--display-path-index (make-hash-table :test 'equal)
        supertag-tag--descendants-index (make-hash-table :test 'equal)
        supertag-tag--index-source-token nil))

(defun supertag-tag--compute-display-path (tag-id tags)
  "Compute TAG-ID's display path directly from TAGS."
  (let ((current tag-id)
        (seen (make-hash-table :test 'equal))
        parts cycle)
    (while (and current (not cycle))
      (if (gethash current seen)
          (setq cycle t)
        (puthash current t seen)
        (let* ((tag (supertag--ensure-plist (gethash current tags)))
               (parent (plist-get tag :extends)))
          (push (if tag
                    (supertag-sanitize-tag-name
                     (or (plist-get tag :name) current))
                  current)
                parts)
          (setq current parent))))
    (if cycle tag-id (string-join parts "/"))))

(defun supertag-tag--descendant-p (candidate parent tags)
  "Return non-nil when CANDIDATE transitively extends PARENT in TAGS."
  (let ((current candidate)
        (seen (make-hash-table :test 'equal))
        found)
    (while (and current (not found) (not (gethash current seen)))
      (puthash current t seen)
      (setq current
            (plist-get (supertag--ensure-plist (gethash current tags))
                       :extends))
      (setq found (equal current parent)))
    found))

(defun supertag-tag-index-rebuild ()
  "Cold rebuild token, display-path and descendant indexes from Store."
  (supertag-tag-index-clear)
  (condition-case err
      (let ((tags (supertag-store-get-collection :tags)))
        (when (hash-table-p tags)
          (maphash
           (lambda (tag-id _tag)
             (puthash tag-id
                      (supertag-tag--compute-display-path tag-id tags)
                      supertag-tag--display-path-index))
           tags)
          (maphash
           (lambda (tag-id raw-tag)
             (dolist (token (supertag-tag--tokens
                             tag-id (supertag--ensure-plist raw-tag)))
               (puthash token
                        (cons tag-id (gethash token supertag-tag--token-index))
                        supertag-tag--token-index)))
           tags)
          (maphash
           (lambda (token owners)
             (puthash token (sort (delete-dups owners) #'string<)
                      supertag-tag--token-index))
           supertag-tag--token-index)
          ;; ponytail: O(T²) only during cold rebuild; use a child adjacency
          ;; walk if measured Vault startup time makes this material.
          (maphash
           (lambda (parent-id _parent)
             (let (descendants)
               (maphash
                (lambda (candidate-id _candidate)
                  (when (and (not (equal candidate-id parent-id))
                             (supertag-tag--descendant-p
                              candidate-id parent-id tags))
                    (push candidate-id descendants)))
                tags)
               (puthash parent-id (nreverse descendants)
                        supertag-tag--descendants-index)))
           tags))
        (setq supertag-tag--index-source-token
              (supertag-index-source-token '(:tags))))
    (error
     (supertag-tag-index-clear)
     (signal (car err) (cdr err)))))

(defun supertag-tag--ensure-index ()
  "Cold rebuild Semantic Tag indexes when Tag facts changed."
  (unless (supertag-index-source-current-p
           supertag-tag--index-source-token '(:tags))
    (supertag-tag-index-rebuild)))

(defun supertag-tag--normalize-aliases (aliases)
  "Return sorted unique occurrence tokens from ALIASES."
  (sort
   (delete-dups
    (mapcar #'supertag-sanitize-tag-name
            (cl-remove-if-not #'stringp aliases)))
   #'string<))

(defun supertag-tag--path-for-name (name parent-id)
  "Return NAME's occurrence path below PARENT-ID."
  (let ((leaf (supertag-sanitize-tag-name name)))
    (if parent-id
        (concat (supertag-tag-display-path parent-id) "/" leaf)
      leaf)))

(defun supertag-tag--tokens (tag-id tag)
  "Return every token that identifies TAG-ID and TAG."
  (supertag-tag--normalize-aliases
   (append (list tag-id
                 (plist-get tag :name)
                 (supertag-tag--compute-display-path
                  tag-id (supertag-store-get-collection :tags)))
           (plist-get tag :aliases))))

(cl-defun supertag-tag--matching-ids
    (token &optional (tag-ids nil tag-ids-supplied-p))
  "Return Tag IDs that claim TOKEN, optionally limited to TAG-IDS."
  (when (and (stringp token) (not (string-empty-p token)))
    (supertag-tag--ensure-index)
    (let* ((normalized (supertag-sanitize-tag-name token))
           (owners (copy-sequence
                    (gethash normalized supertag-tag--token-index))))
      (if tag-ids-supplied-p
          (cl-remove-if-not (lambda (tag-id) (member tag-id tag-ids)) owners)
        owners))))

(defun supertag-tag--assert-tokens-unique (tag-id tokens)
  "Signal when another Tag besides TAG-ID claims one of TOKENS."
  (dolist (token (supertag-tag--normalize-aliases tokens))
    (let ((owners (remove tag-id (supertag-tag--matching-ids token))))
      (when owners
        (user-error "Tag token '%s' is already owned by %s"
                    token (string-join owners ", "))))))

(defun supertag-tag--assert-all-tokens-unique ()
  "Signal when any occurrence token belongs to multiple Semantic Tags."
  (let ((claims (make-hash-table :test 'equal)))
    (maphash
     (lambda (tag-id raw-tag)
       (dolist (token (supertag-tag--tokens
                       tag-id (supertag--ensure-plist raw-tag)))
         (puthash token (cons tag-id (gethash token claims)) claims)))
     (supertag-store-get-collection :tags))
    (maphash
     (lambda (token owners)
       (setq owners (sort (delete-dups owners) #'string<))
       (when (cdr owners)
         (user-error "Tag token '%s' is owned by %s"
                     token (string-join owners ", "))))
     claims)
    t))

;;; --- Tag Operations ---

;; 3.1 Basic Operations

(defun supertag-tag-create (props)
  "Create a new tag using the unified commit system.
PROPS is a plist of tag properties.
Returns the created tag data."
  (when (plist-get props :fields)
    (user-error
     "Tag :fields is legacy storage; create the tag, then use `supertag-tag-add-field'"))
  (let* ((raw-name (plist-get props :name))
         (name (and (stringp raw-name)
                    (supertag-sanitize-tag-name raw-name)))
         (requested-id (plist-get props :id))
         (existing-id (and (not requested-id) name
                           (supertag-tag-resolve-occurrence name)))
         (id (or requested-id existing-id (supertag-tag--new-stable-id)))
         (raw-extends (plist-get props :extends))
         (extends
          (when (and (stringp raw-extends) (not (string-empty-p raw-extends)))
            (or (and (supertag-tag-get raw-extends) raw-extends)
                (supertag-tag-resolve-occurrence raw-extends)
                (user-error "Parent Tag '%s' does not exist" raw-extends))))
         (existing-tag (supertag-tag-get id)))
    ;; Check if tag exists
    (if existing-tag
        (progn
          (message "Tag '%s' already exists, returning existing tag." id)
          existing-tag)
      (unless (and (stringp name) (not (string-empty-p name)))
        (user-error "Tag name cannot be empty"))
      (when (string-match-p "/" id)
        (user-error
         "Tag IDs cannot contain '/'; create the tag and set :extends instead"))
      ;; If tag does not exist, create it
      (let* ((aliases
              (supertag-tag--normalize-aliases
               (append (list id name (supertag-tag--path-for-name name extends))
                       (plist-get props :aliases))))
             (final-props `(:id ,id
                             :name ,name
                             :aliases ,aliases
                             :type :tag
                             :extends ,extends
                             :created-at ,(current-time)
                             :modified-at ,(current-time)))
             (normalized-props (supertag--normalize-tag-extends final-props)))
        (supertag-tag--assert-tokens-unique id aliases)
        ;; Use unified commit system
        (supertag-ops-commit
         :operation :create
         :collection :tags
         :id id
         :new normalized-props
         :perform (lambda ()
                    (supertag-store-put-entity :tags id normalized-props)
                    (supertag-ops-schema-rebuild-cache)
                    normalized-props))))))

(defun supertag-tag-get (id)
  "Get tag data.
ID is the unique identifier of the tag.
Returns tag data, or nil if it does not exist."
  (supertag-store-get-entity :tags id))

(defun supertag-tag-find-ghosts ()
  "Return Tag IDs whose stored value is nil (ghost entries)."
  (let (ghosts)
    (maphash
     (lambda (key value)
       (when (null value)
         (push key ghosts)))
     (supertag-store-get-collection :tags))
    ghosts))

(defun supertag-tag-display-path (tag-id)
  "Return TAG-ID's canonical occurrence path through explicit parents."
  (supertag-tag--ensure-index)
  (or (gethash tag-id supertag-tag--display-path-index)
      (supertag-tag--compute-display-path
       tag-id (supertag-store-get-collection :tags))))

(defun supertag-tag-descendants (tag-id)
  "Return cached transitive descendants of Semantic TAG-ID."
  (supertag-tag--ensure-index)
  (copy-sequence (gethash tag-id supertag-tag--descendants-index)))

(cl-defun supertag-tag-resolve-display-path
    (path &optional (tag-ids nil tag-ids-supplied-p))
  "Return the real Tag ID displayed as PATH.
Limit the search to TAG-IDS when supplied."
  (if tag-ids-supplied-p
      (supertag-tag-resolve-occurrence path tag-ids)
    (supertag-tag-resolve-occurrence path)))

(cl-defun supertag-tag-resolve-occurrence
    (token &optional (tag-ids nil tag-ids-supplied-p))
  "Return the existing Semantic Tag ID resolved from occurrence TOKEN.
Return nil when TOKEN has no Semantic Tag.  This function never creates or
modifies Tag entities."
  (let ((matches
         (if tag-ids-supplied-p
             (supertag-tag--matching-ids token tag-ids)
           (supertag-tag--matching-ids token))))
    (cond
     ((null matches) nil)
     ((null (cdr matches)) (car matches))
     (t (error "Ambiguous Tag token '%s' is owned by %s"
               token (string-join matches ", "))))))

(defun supertag-tag-affixate-candidates (candidates)
  "Display CANDIDATES with parent paths without changing their Tag IDs."
  (mapcar
   (lambda (candidate)
     (let* ((new-name (get-text-property 0 'new-tag-name candidate))
            (id (or new-name
                    (get-text-property 0 'supertag-tag-id candidate)
                    (substring-no-properties candidate)))
            (path (or (get-text-property 0 'new-tag-display-path candidate)
                      (supertag-tag-display-path id)))
            (suffix
             (cond
              ((get-text-property 0 'supertag-tag-conflict candidate)
               (propertize "  [Conflict]" 'face 'error))
              ((get-text-property 0 'is-new-tag candidate)
               (propertize "  [New]" 'face 'warning))
              ((get-text-property 0 'supertag-tag-occurrence candidate)
               (propertize "  [Unresolved]" 'face 'shadow))
              (t ""))))
       (list path "" suffix)))
   candidates))

(defun supertag-tag-update (id updater)
  "Update tag data using the unified commit system.
ID is the unique identifier of the tag.
UPDATER is a function that receives the current tag data and returns the updated data.
Returns the updated tag data."
  
  (supertag-schema-authority-assert :type id :update)
(let ((previous (supertag-tag-get id)))
    (when previous
      ;; Convert hash table to plist if necessary
      (let* ((original-plist (supertag--ensure-plist previous))
             ;; Deep copy to avoid mutation affecting original-plist comparison
             (copy-for-update (supertag--deep-copy-plist original-plist)))
        (supertag-with-transaction
          (supertag-ops-commit
           :operation :update
           :collection :tags
           :id id
           :previous original-plist
           :perform (lambda ()
                      (let ((updated-tag (funcall updater copy-for-update)))
                        (when updated-tag
                        ;; Always save if updater returned non-nil, since the updater
                        ;; is expected to make changes. The equal check was unreliable
                        ;; due to plist-put mutation semantics.
                        (let* ((normalized-tag (supertag--normalize-tag-extends updated-tag))
                               (aliases
                                (supertag-tag--normalize-aliases
                                 (append
                                  (list id (plist-get normalized-tag :name)
                                        (supertag-tag--path-for-name
                                         (plist-get normalized-tag :name)
                                         (plist-get normalized-tag :extends)))
                                  (plist-get normalized-tag :aliases))))
                               (normalized-tag
                                (plist-put normalized-tag :aliases aliases))
                               (final-tag (plist-put normalized-tag :modified-at (current-time))))
                          (supertag-tag--assert-tokens-unique id aliases)
                          (supertag--validate-tag-data final-tag)
                            (supertag-store-put-entity :tags id final-tag)
                            (supertag-tag--assert-all-tokens-unique)
                            (supertag-ops-schema-rebuild-cache)
                            final-tag))))))))))

(defun supertag-tag-delete (id &optional before-delete)
  "Delete a tag using the unified commit system.
ID is the unique identifier of the tag.
When BEFORE-DELETE is non-nil, call it with ID after operation hooks and
immediately before the Store mutation.
Returns the deleted tag data."
  
  (supertag-schema-authority-assert :type id :delete)
(let ((previous (supertag-tag-get id)))
    (when previous
      (supertag-link-definition-assert-tag-deletable id)
      (supertag-ops-commit
       :operation :delete
       :collection :tags
       :id id
       :previous previous
       :perform (lambda ()
                  (when before-delete
                    (funcall before-delete id))
                  (supertag-store-remove-entity :tags id)
                  (supertag-ops-schema-rebuild-cache)
                  nil)))))

(defun supertag-tag--referenced-ids (tag-ids)
  "Return TAG-IDS referenced by data or loaded configuration.
TAG-IDS are explicit so validation still sees candidates already removed
from the Tag registry by an in-flight cleanup transaction."
  (require 'supertag-query-library)
  (let ((known (make-hash-table :test 'equal))
        (referenced (make-hash-table :test 'equal))
        (seen (make-hash-table :test 'eq))
        (tags (supertag-store-get-collection :tags)))
    (dolist (id tag-ids)
      (when (stringp id)
        (puthash id t known)))
    (cl-labels
        ((mark-all ()
           (maphash (lambda (id _value) (puthash id t referenced)) known))
         (walk (value)
           (cond
            ((stringp value)
             (when (gethash value known)
               (puthash value t referenced)))
            ((hash-table-p value)
             (unless (gethash value seen)
               (puthash value t seen)
               (maphash (lambda (key item) (walk key) (walk item)) value)))
            ((consp value)
             (walk (car value))
             (walk (cdr value))))))
      (dolist (collection (supertag-store-collection-names))
        (unless (eq collection :tags)
          (walk (supertag-store-get-collection collection))))
      (maphash
       (lambda (id raw-tag)
         (let ((tag (supertag--ensure-plist raw-tag)))
           (when (plist-get tag :extends)
             (when (gethash id known)
               (puthash id t referenced)))
           (walk (plist-get tag :extends))))
       tags)
      (when (fboundp 'supertag-view-config-list)
        (walk (supertag-view-config-list)))
      (unless (supertag-query-saved-map-forms #'walk)
        (mark-all)))
    (let (ids)
      (maphash (lambda (id _value)
                 (push id ids))
               referenced)
      (sort ids #'string<))))

(defun supertag-tag-orphaned-ids ()
  "Return sorted Tag IDs with no data or loaded configuration references.
Tags that own fields or inheritance are treated as schema and retained.
The scan is intentionally conservative: an exact Tag ID anywhere outside
the Tag registry counts as a reference."
  (let ((tags (supertag-store-get-collection :tags))
        ids)
    (maphash (lambda (id value)
               (when value (push id ids)))
             tags)
    (sort (cl-set-difference
           ids (supertag-tag--referenced-ids ids) :test #'equal)
          #'string<)))

(defun supertag-tag-delete-orphans (tag-ids)
  "Delete TAG-IDS only when every ID is still an orphan.
No Org file is edited.  The full set is rechecked immediately before the
transaction so a stale preview cannot delete a newly referenced Tag.
Return the number of deleted Tag entities."
  (let* ((ids (delete-dups (copy-sequence tag-ids)))
         (orphans (supertag-tag-orphaned-ids))
         (blocked (cl-set-difference ids orphans :test #'equal)))
    (when blocked
      (user-error "Refusing to delete referenced or schema Tag(s): %s"
                  (string-join blocked ", ")))
    (supertag-with-transaction
      (dolist (id ids)
        (supertag-tag-delete
         id
         (lambda (current-id)
           (unless (member current-id (supertag-tag-orphaned-ids))
             (user-error "Tag is no longer orphaned: %s" current-id)))))
      (let ((post-hook-blocked
             (delete-dups
              (append (supertag-tag--referenced-ids ids)
                      (cl-remove-if-not #'supertag-tag-get ids)))))
        (when post-hook-blocked
          (user-error "Cleanup hooks retained or referenced Tag(s): %s"
                      (string-join post-hook-blocked ", ")))))
    (length ids)))

(defun supertag-ops-delete-tag-everywhere (tag-name)
  "Delete a tag and all its uses from the database and all org files.
This is a non-interactive, high-level operation. It finds all nodes
with TAG-NAME, cleans up all database relations, and then removes
the tag text from the source files.
Returns the number of instances removed from files."
  (when (and tag-name (not (string-empty-p tag-name)))
    (let* ((tag-id (or (and (supertag-tag-get tag-name) tag-name)
                       (supertag-tag-resolve-occurrence tag-name)
                       (user-error "Tag '%s' not found" tag-name)))
           (tag (supertag--ensure-plist (supertag-tag-get tag-id)))
           (nodes-with-tag (supertag-find-nodes-by-tag tag-id))
           (files (delete-dups (mapcar (lambda (node-pair)
                                         (let ((node (cdr node-pair)))
                                           (plist-get node :file)))
                                       nodes-with-tag)))
           (tokens
            (delete-dups
             (append
              (list (supertag-sanitize-tag-name (plist-get tag :name)))
              (apply
               #'append
               (mapcar
                (lambda (node-pair)
                  (cl-remove-if-not
                   (lambda (token)
                     (equal tag-id
                            (ignore-errors
                              (supertag-tag-resolve-occurrence token))))
                   (plist-get (cdr node-pair) :tag-occurrences)))
                nodes-with-tag))))))

      ;; Clean up relations and node properties in a single loop
      (dolist (node-pair nodes-with-tag)
        (let* ((node-id (car node-pair))
               (relations (supertag-relation-find-between node-id tag-id :node-tag)))
          (dolist (rel relations)
            (supertag-relation-delete (plist-get rel :id)))
          (supertag-node-remove-tag node-id tag-id)))

      ;; Delete the tag definition itself
      (supertag-tag-delete tag-id)

      ;; Remove tag text from all associated files
      (require 'supertag-view-helper)
      (let ((total-deleted 0))
        (dolist (token tokens)
          (setq total-deleted
                (+ total-deleted
                   (supertag-view-helper-remove-tag-text-from-files
                    token files))))
        (message "Tag '%s' completely deleted. Removed %d instances from files."
                 tag-name (or total-deleted 0))
        total-deleted))))

(cl-defun supertag-ops-add-tag-to-node (node-id tag-id &key create-if-needed extends)
  "High-level operation to add a tag to a node.
This non-interactive function ensures the tag exists (creating it
if CREATE-IF-NEEDED is non-nil) and then creates the node-tag
relationship. It also updates the node's :tags property to ensure
index consistency.  When creating, EXTENDS sets the existing parent
Tag ID; an existing Tag is never silently reparented.

It does NOT modify the buffer.
Returns t if the relationship was created or already exists, nil otherwise."
  (when (and node-id (not (string-empty-p tag-id)))
    (supertag-with-transaction
      (unless (supertag-node-get node-id)
        (user-error "Node '%s' does not exist" node-id))
      (let* ((resolved-id
              (or (and (supertag-tag-get tag-id) tag-id)
                  (supertag-tag-resolve-occurrence tag-id)))
             (parent-id
              (and extends
                   (or (and (supertag-tag-get extends) extends)
                       (supertag-tag-resolve-occurrence extends))))
             (existing (and resolved-id (supertag-tag-get resolved-id))))
        (when extends
          (unless parent-id
            (user-error "Parent Tag '%s' does not exist" extends))
          (when (and existing
                     (not (equal parent-id
                                 (plist-get (supertag--ensure-plist existing)
                                            :extends))))
            (user-error "Tag '%s' already exists under a different parent"
                        tag-id)))

        ;; 1. Ensure tag definition exists.
        (when (and create-if-needed (not existing))
          (setq existing
                (supertag-tag-create
                 `(:name ,tag-id :extends ,parent-id)))
          (setq resolved-id (plist-get existing :id)))

        ;; 2. If tag exists, create the relationship and update node.
        (if-let* ((raw-tag (and resolved-id (supertag-tag-get resolved-id))))
            (let ((tag (supertag--ensure-plist raw-tag)))
              (supertag-node-add-tag node-id resolved-id)
              (unless (supertag-relation-find-between
                       node-id (plist-get tag :id) :node-tag)
                (supertag-relation-create
                 `(:type :node-tag :from ,node-id :to ,(plist-get tag :id))))
              t)
          nil)))))

;; 3.2 Field Operations

(defun supertag-tag--normalize-field-def (field-def)
  "Normalize FIELD-DEF plist before persisting.
Ensures :options fields carry a proper :options list; signals when missing."
  (let* ((type (plist-get field-def :type))
         (options (plist-get field-def :options)))
    (when (eq type :options)
      (cond
       ((and (listp options) (not (stringp options)))
        ;; ok
        )
       ((stringp options)
        (setq field-def
              (plist-put field-def :options
                         (split-string options "," t "[ \t\n\r]+"))))
       ((null options)
        (error "Options field '%s' must include :options list" (plist-get field-def :name)))
       (t
        (error "Options field '%s' has invalid :options %S" (plist-get field-def :name) options))))
    field-def))

(defun supertag-tag-add-field (tag-id field-def)
  "Add a field definition to a tag.
TAG-ID is the unique identifier of the tag.
FIELD-DEF is a plist of the field definition.
Returns the updated tag data."
  
  (supertag-schema-authority-assert :type tag-id :associate-field)
(setq field-def (supertag-tag--normalize-field-def field-def))
  (let ((fid (or (plist-get field-def :id)
                 (supertag-sanitize-field-id (plist-get field-def :name)))))
    (unless fid
      (error "Field must have :name to derive id"))
    (if (supertag-global-field-get fid)
        (supertag-global-field-update fid (lambda (_old) field-def))
      (supertag-global-field-create field-def))
    (supertag-tag-associate-field tag-id fid)
    (supertag-ops-schema-rebuild-cache)
    (supertag-tag-get tag-id)))

(defun supertag-tag-define-field (tag-id field-name type &optional properties)
  "Define or update a field for a tag with explicit TYPE and PROPERTIES.
This is a high-level wrapper that constructs the field-def and calls
`supertag-tag-add-field`. It enforces the rule that an :options
type must be accompanied by an :options property.

For :options type, PROPERTIES should include :options '(...).
Example: (supertag-tag-define-field \"task\" \"Priority\" :options '(:options (\"High\" \"Medium\" \"Low\")))"
  (let ((field-def (append `(:name ,field-name :type ,type) properties)))
    (supertag-tag-add-field tag-id field-def)))

(defun supertag-tag-remove-field (tag-id field-name)
  "Remove a field definition from a tag.
TAG-ID is the unique identifier of the tag.
FIELD-NAME is the name of the field to remove.
Returns the updated tag data."
  
  (supertag-schema-authority-assert :type tag-id :disassociate-field)
(when-let* ((fid (or (plist-get (supertag-tag-get-field tag-id field-name) :id)
                        (supertag-sanitize-field-id field-name))))
    (supertag-tag-disassociate-field tag-id fid))
  (supertag-tag-get tag-id))

(defun supertag-tag-list-missing-fields ()
  "List tags with no global field associations or no parent."
  (interactive)
  (let ((tags-table (supertag-store-get-collection :tags))
        (associations
         (supertag-store-get-collection :tag-field-associations))
        (missing-fields '())
        (missing-extends '())
        (total-tags 0))
    (maphash
     (lambda (tag-id tag-data)
       (cl-incf total-tags)
       (let ((fields (gethash tag-id associations))
             (extends (plist-get tag-data :extends)))
         (when (null fields)
           (push tag-id missing-fields))
         (when (null extends)
           (push tag-id missing-extends))))
     tags-table)

    (let ((report (format "=== Tag Field Status Report ===\nTotal tags: %d\nTags without global field associations: %d\nTags with nil :extends: %d\n\nTags without field associations:\n%s\n"
                         total-tags
                         (length missing-fields)
                         (length missing-extends)
                         (mapconcat #'identity (nreverse missing-fields) "\n"))))
      (message "%s" report)
      (with-current-buffer (get-buffer-create "*Supertag Missing Fields*")
        (erase-buffer)
        (insert report)
        (goto-char (point-min))
        (display-buffer (current-buffer)))
      (list :missing-fields missing-fields
            :missing-extends missing-extends))))

(defun supertag-tag-rename-field (tag-id old-name new-name)
  "Rename a field definition in a tag.
TAG-ID is the unique identifier of the tag.
OLD-NAME is the current name of the field.
NEW-NAME is the new name for the field.
Returns the updated tag data."
  (let* ((field (supertag-tag-get-field tag-id old-name))
         (field-id (plist-get field :id)))
    (unless field-id
      (error "Field '%s' not found on tag '%s'" old-name tag-id))
    (supertag-global-field-update
     field-id
     (lambda (definition)
       (plist-put definition :name new-name)))
    (supertag-ops-schema-rebuild-cache)
    (supertag-tag-get tag-id)))

(defun supertag-tag-rename (old-id new-name)
  "Rename OLD-ID's canonical name to NEW-NAME without changing its identity."
  (interactive "sRename tag from: \nsRename tag to: ")
  (let ((canonical (supertag-sanitize-tag-name new-name)))
    (when (string-match-p "/" canonical)
      (user-error
       "Canonical Tag names cannot contain '/'; use :extends for nesting"))
    (let* ((tag-id (or (and (supertag-tag-get old-id) old-id)
                       (supertag-tag-resolve-occurrence old-id)
                       (user-error "Tag '%s' not found" old-id)))
           (tag (copy-tree (supertag--ensure-plist (supertag-tag-get tag-id))))
           (old-name (plist-get tag :name))
           (old-path (supertag-tag-display-path tag-id))
           (new-path (supertag-tag--path-for-name
                      canonical (plist-get tag :extends)))
           (aliases (supertag-tag--normalize-aliases
                     (append (list tag-id old-name old-path canonical new-path)
                             (plist-get tag :aliases)))))
      (supertag-tag--assert-tokens-unique tag-id aliases)
      (supertag-tag-update
       tag-id
       (lambda (current)
         (setq current (plist-put current :name canonical))
         (plist-put current :aliases aliases)))
      (message "Renamed Semantic Tag '%s' to '%s'; ID and Org tokens unchanged."
               old-name canonical)
      tag-id)))

(defun supertag--set-tag-parent (child-id parent-id)
  "Set CHILD-ID to extend PARENT-ID, rebuilding schema cache."
  (let ((child (supertag-tag-get child-id))
        (parent (supertag-tag-get parent-id)))
    (unless child
      (error "Child tag '%s' does not exist" child-id))
    (unless parent
      (error "Parent tag '%s' does not exist" parent-id))
    (let* ((normalized-child (plist-get (supertag--ensure-plist child) :id))
           (normalized-parent (supertag-sanitize-tag-name parent-id)))
      (when (string= normalized-child normalized-parent)
        (error "Tag '%s' cannot extend itself" normalized-child))
    (supertag-tag-update child-id
      (lambda (tag)
        (when tag
          (plist-put tag :extends normalized-parent)))))))

(defun supertag--clear-parent (child-id)
  "Clear the parent (extends) relationship for CHILD-ID."
  (unless (supertag-tag-get child-id)
    (error "Child tag '%s' does not exist" child-id))
  (supertag-tag-update child-id
    (lambda (tag)
      (when tag
        (plist-put tag :extends nil)))))

(defun supertag-tag-get-field (tag-id field-name)
  "Get a field definition from a tag.
TAG-ID is the unique identifier of the tag.
FIELD-NAME is the name of the field.
Returns the field definition, or nil if not found."
  (let ((fid (supertag-sanitize-field-id field-name)))
    (cl-find-if
     (lambda (field)
       (or (equal fid (plist-get field :id))
           (equal field-name (plist-get field :name))))
     (supertag-tag-get-all-fields tag-id))))

(defun supertag-tag--move-field (tag-id field-name delta)
  "Move FIELD-NAME by DELTA in TAG-ID's global association order."
  (let* ((field-id (plist-get (supertag-tag-get-field tag-id field-name) :id))
         (entries (supertag--normalize-tag-field-associations
                   (supertag-store-get-tag-field-associations tag-id)))
         (index (cl-position field-id entries
                             :key #'supertag--assoc-entry-field-id
                             :test #'equal))
         (target (and index (+ index delta))))
    (when (and target (>= target 0) (< target (length entries)))
      (setq entries (copy-tree entries))
      (cl-rotatef (nth index entries) (nth target entries))
      (setq entries
            (cl-loop for entry in entries
                     for order from 0
                     collect (plist-put entry :order order)))
      (supertag-store-put-tag-field-associations tag-id entries t)
      (supertag-ops-schema-rebuild-cache))
    entries))

(defun supertag-tag-move-field-up (tag-id field-name)
  "Move a field definition up in the tag's field list.
TAG-ID is the unique identifier of the tag.
FIELD-NAME is the name of the field to move up.
Returns the updated tag data."
  (supertag-tag--move-field tag-id field-name -1))

(defun supertag-tag-move-field-down (tag-id field-name)
  "Move a field definition down in the tag's field list.
TAG-ID is the unique identifier of the tag.
FIELD-NAME is the name of the field to move down.
Returns the updated tag data."
  (supertag-tag--move-field tag-id field-name 1))

(defun supertag-tag-get-all-fields (tag-id)
  "Get all field definitions for a tag, including inherited fields.
TAG-ID is the unique identifier of the tag.
Returns a list of global field definition plists, or an empty list."
  (let ((resolved (ignore-errors
                    (supertag-ops-schema-get-resolved-tag tag-id))))
    (if (and resolved (plist-get resolved :fields))
        (plist-get resolved :fields)
      (let* ((entries (supertag--normalize-tag-field-associations
                       (supertag-store-get-tag-field-associations tag-id)))
             result)
        (dolist (entry entries (nreverse result))
          (when-let* ((definition
                       (supertag-store-get-field-definition
                        (supertag--assoc-entry-field-id entry))))
            (push definition result)))))))

(defun supertag-sanitize-tag-name (name)
  "Sanitize a string into a valid tag name.
Removes leading/trailing whitespace, a leading '#', and converts
internal whitespace to single underscores."
  (if (or (null name) (string-empty-p name))
      (error "Tag name cannot be empty")
    (let* ((clean-name (substring-no-properties name))
           (trimmed (string-trim clean-name))
           (no-hash (if (string-prefix-p "#" trimmed)
                        (substring trimmed 1)
                      trimmed))
           (sanitized (replace-regexp-in-string "\\s-+" "_" no-hash)))
      (if (string-empty-p sanitized)
          (error "Invalid tag name: %s" name)
        sanitized))))

(provide 'supertag-ops-tag)

;;; supertag/ops/tag.el ends here
