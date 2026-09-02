;;; supertag-view-api.el --- UI-agnostic data API for Supertag views -*- lexical-binding: t; -*-

;;; Commentary:
;; This module defines the internal public "View Data API" for supertag.
;;
;; Goal:
;; - Provide a stable, UI-agnostic read interface to the underlying DB/Store.
;; - Allow view plugins to build any UI (table, cards, dashboards, graphs, etc.)
;;   while using the same data access contract.
;;
;; Non-goal:
;; - This module does not define UI widgets/components.
;; - This module does not write data; writes should go through ops functions
;;   (e.g. `supertag-field-set', `supertag-node-update') and transactions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-core-notify)
(require 'supertag-core-scan) ; Document Projection queries
(require 'supertag-ops-node)
(require 'supertag-ops-tag)
(require 'supertag-ops-field)
(require 'supertag-ops-relation)
(require 'supertag-ops-link-definition)
(require 'supertag-services-query)

;; --- Query & Entity Fetch ---

(defun supertag-view-api-list-entity-ids (query-spec)
  "Return entity IDs for QUERY-SPEC.

QUERY-SPEC is a plist describing the dataset, for example:
- (:type :tag :value \"foo\")
- (:type :tag :value \"foo\" :include-descendants t)
- (:type :nodes)
- (:type :tags)
- (:type :automations)

This function is UI-agnostic and read-only."
  (let ((type (plist-get query-spec :type)))
    (pcase type
      (:tag
       (let ((tag (plist-get query-spec :value)))
         (unless (and tag (stringp tag) (not (string-empty-p tag)))
           (error "Query :tag requires a non-empty :value string"))
         (supertag-query-node-ids-by-tag
          tag
          (plist-get query-spec :include-descendants))))
      ((or :nodes :tags :relations :link-definition :link-definitions :embeds
           ;; Some query specs use singular names in UI layers; accept them here.
           :automation :automations
           :database :databases)
       (let ((type (pcase type
                     (:automation :automations)
                     (:database :databases)
                     (:link-definition :link-definitions)
                     (_ type))))
         (pcase type
           (:nodes (mapcar #'car (supertag-query-nodes)))
           (:tags (supertag-view-api-list-tag-ids))
           (:relations (mapcar (lambda (relation) (plist-get relation :id))
                               (supertag-query-relations)))
           (:link-definitions
            (mapcar (lambda (definition) (plist-get definition :id))
                    (supertag-link-definition-list)))
           (:automations (mapcar (lambda (automation) (plist-get automation :id))
                                 (supertag-query-automations)))
           ;; :embeds/:databases are legacy/non-canonical
           ;; collections; they contain no entities.
           (_ '()))))
      (_
       (error "Unsupported query type: %S" type)))))

(defun supertag-view-api-get-entity (type entity-id)
  "Return entity plist for TYPE and ENTITY-ID (read-only)."
  (unless (and entity-id (stringp entity-id) (not (string-empty-p entity-id)))
    (error "ENTITY-ID must be a non-empty string"))
  (let ((normalized
         (pcase type
           (:node :nodes)
           (:tag :tags)
           (:relation :relations)
           (:link-definition :link-definitions)
           (:embed :embeds)
           (:automation :automations)
           (:database :databases)
           (_ type))))
    (pcase normalized
      (:nodes (supertag-query-node entity-id))
      (:tags (supertag-tag-get entity-id))
      (:relations (supertag-relation-get entity-id))
      (:link-definitions (supertag-link-definition-get entity-id))
      (:automations
       (car (supertag-query-automations
             (lambda (automation)
               (equal (plist-get automation :id) entity-id)))))
      ;; :embeds/:databases are legacy/non-canonical collections.
      (_ nil))))

(defun supertag-view-api-get-entities (type entity-ids)
  "Return list of entities for TYPE and ENTITY-IDS.

This is a convenience function; callers can still batch on their own.
Entities that do not exist are skipped."
  (let (result)
    (dolist (entity-id entity-ids (nreverse result))
      (let ((entity (and entity-id (supertag-view-api-get-entity type entity-id))))
        (when entity
          (push entity result))))))

;; --- Tag Helpers ---

(defun supertag-view-api-list-tags ()
  "Return tag names (sorted)."
  (sort (delete-dups
         (mapcar (lambda (tag) (plist-get tag :name))
                 (supertag-query-tag-paths)))
        #'string<))

(defun supertag-view-api-list-tag-ids ()
  "Return canonical tag IDs (sorted)."
  (sort (mapcar (lambda (tag) (plist-get tag :id))
                (supertag-query-tag-paths))
        #'string<))

(defun supertag-view-api-tag-id (tag-name)
  "Return tag ID for TAG-NAME, or nil."
  (unless (and (stringp tag-name) (not (string-empty-p tag-name)))
    (error "TAG-NAME must be a non-empty string"))
  (or (and (supertag-tag-get tag-name) tag-name)
      (supertag-tag-resolve-occurrence tag-name)))

(defun supertag-view-api-nodes-by-tag (tag-name &optional include-descendants)
  "Return node IDs that have TAG-NAME.
When INCLUDE-DESCENDANTS is non-nil, include transitive `:extends' descendants."
  (supertag-query-node-ids-by-tag tag-name include-descendants))

(defun supertag-view-api-tag-descendants (tag-name)
  "Return Tag IDs that transitively extend TAG-NAME."
  (supertag-find-tag-descendants tag-name))

;; --- Field Access (UI-agnostic) ---

(defun supertag-view-api-node-base-field (node key)
  "Read KEY from NODE plist."
  (plist-get node key))

(defun supertag-view-api-node-field-in-tag (node-id tag-id field-name)
  "Read FIELD-NAME for NODE-ID within TAG-ID context.

FIELD-NAME is a string (as used by `supertag-field-get-with-default')."
  (unless (and (stringp field-name) (not (string-empty-p field-name)))
    (error "FIELD-NAME must be a non-empty string"))
  (supertag-query-field-value node-id tag-id field-name))

;; --- Subscription ---

(defun supertag-view-api-subscribe (event fn)
  "Subscribe FN to EVENT and return an unsubscribe function.

EVENT is a keyword (e.g. :node-updated) or a store path list.
FN is called with arguments determined by the event publisher."
  (unless (functionp fn)
    (error "FN must be a function"))
  (supertag-subscribe event fn))

(provide 'supertag-view-api)
;;; supertag-view-api.el ends here
