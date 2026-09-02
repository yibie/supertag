;;; supertag-core-scan.el --- Scan-based query functions for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file provides internal Document Projection queries.  Tag membership
;; uses rebuildable indexes; residual text/date/file queries still scan the
;; Store below high-level services.

;;; Code:

(require 'cl-lib)
(require 'supertag-core-index)
(require 'supertag-core-store)
(require 'supertag-ops-node)
(require 'supertag-ops-tag)


;;; --- Document Projection Queries ---

(defun supertag-find-tag-descendants (tag-name)
  "Return stored tag IDs that transitively extend TAG-NAME."
  (let ((tag-id (or (and (supertag-tag-get tag-name) tag-name)
                    (supertag-tag-resolve-occurrence tag-name)
                    tag-name)))
    (supertag-tag-descendants tag-id)))

(defun supertag-index-get-nodes-by-tag (tag-name &optional include-descendants)
  "Return indexed node IDs for TAG-NAME.
When INCLUDE-DESCENDANTS is non-nil, include transitive descendants."
  (let* ((resolved (or (and (supertag-tag-get tag-name) tag-name)
                       (supertag-tag-resolve-occurrence tag-name)
                       tag-name))
         (matching-tags (cons resolved
                             (and include-descendants
                                  (supertag-find-tag-descendants resolved)))))
    (supertag-index-find-node-ids-by-tags matching-tags)))

(defun supertag-index-get-nodes-by-word (word)
  "Find all nodes containing WORD by scanning the store.
This is an O(N) operation and performs a simple substring search."
  (let ((nodes-ht (supertag-store-get-collection :nodes))
        (results '())
        (search-word (downcase word)))
    (when (hash-table-p nodes-ht)
      (maphash (lambda (node-id node-data)
                 (let ((title (plist-get node-data :title))
                       (content (plist-get node-data :content)))
                   (when (or (and title (string-match-p (regexp-quote search-word) (downcase title)))
                             (and content (string-match-p (regexp-quote search-word) (downcase content))))
                     (push node-id results))))
               nodes-ht))
    (nreverse (delete-dups results))))

(defun supertag-index-get-nodes-by-date-range (start-time end-time &optional date-field)
  "Find all nodes created/modified within a date range by scanning.
This is an O(N) operation.
DATE-FIELD can be :created-at or :modified-at (default :created-at)."
  (let* ((field (or date-field :created-at))
         (nodes-ht (supertag-store-get-collection :nodes))
         (matching-nodes '()))
    (when (hash-table-p nodes-ht)
      (maphash (lambda (node-id node-data)
                 (let ((node-time (plist-get node-data field)))
                   (when node-time
                     (let ((start-check (or (null start-time) (time-less-p start-time node-time)))
                           (end-check (or (null end-time) (time-less-p node-time end-time))))
                       (when (and start-check end-check)
                         (push node-id matching-nodes))))))
               nodes-ht))
    (nreverse matching-nodes)))

(defun supertag-find-nodes-by-tag (tag-name &optional include-descendants)
  "Return indexed nodes with TAG-NAME.
TAG-NAME is the name of the tag to search for.
When INCLUDE-DESCENDANTS is non-nil, tags that transitively extend
TAG-NAME also match.
Returns a list of (node-id . node-data) pairs."
  (let* ((resolved (or (and (supertag-tag-get tag-name) tag-name)
                       (supertag-tag-resolve-occurrence tag-name)
                       tag-name))
         (matching-tags (cons resolved
                             (and include-descendants
                                  (supertag-find-tag-descendants resolved))))
         (nodes-ht (supertag-store-get-collection :nodes))
         results)
    (dolist (node-id (supertag-index-find-node-ids-by-tags matching-tags)
                     (nreverse results))
      (when-let* ((node (gethash node-id nodes-ht)))
        (push (cons node-id node) results)))))

(defun supertag-find-nodes-by-file (file-path)
  "Find all nodes located in FILE-PATH.
Returns a list of (node-id . node-data) pairs."
  (let ((nodes-collection (supertag-store-get-collection :nodes))
        (found-nodes '()))
    (when (hash-table-p nodes-collection)
      (maphash
       (lambda (id node-data)
         ;; Safely extract :file and ensure it's a string
         (when-let* ((node-file (and node-data (plist-get node-data :file)))
                     ((stringp node-file)))
           ;; Direct string comparison without path normalization
           (when (equal node-file file-path)
             (push (cons id node-data) found-nodes))))
       nodes-collection))
    (nreverse found-nodes)))

(defun supertag-find-file-node (file-path)
  "Find the file node (level 0) for FILE-PATH.
Returns (node-id . node-data) or nil."
  (let ((nodes-collection (supertag-store-get-collection :nodes))
        (found nil))
    (when (hash-table-p nodes-collection)
      (maphash
       (lambda (id node-data)
         (when (and node-data
                    (eq (plist-get node-data :level) 0)
                    (equal (plist-get node-data :file) file-path)
                    (not found))
           (setq found (cons id node-data))))
       nodes-collection))
    found))

(provide 'supertag-core-scan)


;;; supertag-core-scan.el ends here
