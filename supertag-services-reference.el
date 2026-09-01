;;; supertag-services-reference.el --- Read model for references and backlinks -*- lexical-binding: t; -*-

;;; Commentary:
;; Builds UI-ready reference candidates and contextual backlinks from the
;; canonical Supertag Store.  This module is read-only: it does not edit Org
;; documents and does not own reference facts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-services-query)

(defgroup supertag-reference nil
  "Reference and contextual backlink support for Supertag."
  :group 'supertag)

(defcustom supertag-reference-context-length 220
  "Maximum number of characters in one contextual backlink excerpt."
  :type 'integer
  :group 'supertag-reference)

(defcustom supertag-reference-context-before 72
  "Preferred number of characters shown before the matched reference term."
  :type 'integer
  :group 'supertag-reference)

(defun supertag-reference-service--node-prop (node prop)
  "Return PROP from plist or hash-table NODE."
  (cond
   ((hash-table-p node) (gethash prop node))
   ((listp node) (plist-get node prop))
   (t nil)))

(defun supertag-reference-service--node-properties (node)
  "Return NODE's user properties as a plist."
  (let ((properties (supertag-reference-service--node-prop node :properties)))
    (cond
     ((hash-table-p properties)
      (let (result)
        (maphash (lambda (key value)
                   (setq result (plist-put result key value)))
                 properties)
        result))
     ((listp properties) properties)
     (t nil))))

(defun supertag-reference-service--split-aliases (value)
  "Return normalized aliases represented by VALUE."
  (cond
   ((null value) nil)
   ((listp value)
    (cl-remove-if #'string-empty-p
                  (mapcar (lambda (item)
                            (string-trim (format "%s" item)))
                          value)))
   ((stringp value)
    (cl-remove-if #'string-empty-p
                  (mapcar #'string-trim
                          (split-string value "[,，;；]" t))))
   (t nil)))

(defun supertag-reference-service-node-title (node-or-id)
  "Return a readable title for NODE-OR-ID."
  (let* ((node (if (stringp node-or-id)
                   (supertag-store-get-entity :nodes node-or-id)
                 node-or-id))
         (id (and (stringp node-or-id) node-or-id)))
    (or (supertag-reference-service--node-prop node :raw-value)
        (supertag-reference-service--node-prop node :title)
        id
        "Untitled")))

(defun supertag-reference-service-node-aliases (node)
  "Return reference aliases declared by NODE."
  (supertag-reference-service--split-aliases
   (plist-get (supertag-reference-service--node-properties node)
              :SUPERTAG_ALIASES)))

(defun supertag-reference-service-node-terms (node)
  "Return NODE's title and aliases as unique non-empty terms."
  (cl-delete-duplicates
   (cl-remove-if
    #'string-empty-p
    (mapcar (lambda (term) (string-trim (format "%s" term)))
            (cons (supertag-reference-service-node-title node)
                  (supertag-reference-service-node-aliases node))))
   :test #'string-equal))

(defun supertag-reference-service-node-location (node)
  "Return a compact, human-readable location label for NODE."
  (let* ((file (supertag-reference-service--node-prop node :file))
         (file-label (and file (file-name-nondirectory file)))
         (olp (supertag-reference-service--node-prop node :olp))
         (path (and (listp olp)
                    (string-join
                     (cl-remove-if #'string-empty-p
                                   (mapcar (lambda (item)
                                             (string-trim (format "%s" item)))
                                           olp))
                     " / "))))
    (cond
     ((and file-label path) (format "%s | %s" file-label path))
     (file-label file-label)
     (path path)
     (t "Store node"))))

(defun supertag-reference-service--clean-content (content)
  "Return CONTENT normalized for compact contextual display."
  (let ((text (or content "")))
    ;; Keep user-facing descriptions and remove physical Org link syntax.
    (setq text
          (replace-regexp-in-string
           "\\[\\[[^]]+\\]\\[\\([^]]+\\)\\]\\]" "\\1" text t))
    (setq text
          (replace-regexp-in-string
           "\\[\\[\\([^]]+\\)\\]\\]" "\\1" text t))
    (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text))))

(defun supertag-reference-service--linked-description (content target-node)
  "Return CONTENT's physical link description for TARGET-NODE, if present."
  (when-let* ((target-id
               (supertag-reference-service--node-prop target-node :id)))
    (let ((regexp
           (format "\\[\\[\\(?:id\\|denote\\):%s\\]\\[\\([^]]+\\)\\]\\]"
                   (regexp-quote (format "%s" target-id)))))
      (when (string-match regexp (or content ""))
        (match-string 1 content)))))

(defun supertag-reference-service-context-snippet (source-node target-node)
  "Return a compact excerpt from SOURCE-NODE centered on TARGET-NODE."
  (let* ((case-fold-search t)
         (raw-content
          (supertag-reference-service--node-prop source-node :content))
         (text (supertag-reference-service--clean-content raw-content))
         (link-description
          (supertag-reference-service--linked-description
           raw-content target-node))
         (terms (sort (if link-description
                          (cl-adjoin
                           link-description
                           (supertag-reference-service-node-terms target-node)
                           :test #'equal)
                        (supertag-reference-service-node-terms target-node))
                      (lambda (left right) (> (length left) (length right)))))
         (case-fold-search t)
         match)
    (dolist (term terms)
      (when (and (not match)
                 (not (string-empty-p term))
                 (string-match (regexp-quote term) text))
        (setq match (cons (match-beginning 0) (match-end 0)))))
    (unless (string-empty-p text)
      (let* ((limit (max 40 supertag-reference-context-length))
             (match-start (or (car-safe match) 0))
             (match-end (or (cdr-safe match) (min (length text) limit)))
             (start (if match
                        (max 0 (- match-start supertag-reference-context-before))
                      0))
             (end (min (length text) (+ start limit))))
        ;; Ensure a late match remains visible when the initial right edge was
        ;; clipped by the fixed excerpt length.
        (when (> match-end end)
          (setq end (min (length text) match-end)
                start (max 0 (- end limit))))
        (concat (if (> start 0) "…" "")
                (string-trim (substring text start end))
                (if (< end (length text)) "…" ""))))))

(defun supertag-reference-service-kind-label (kind)
  "Return a user-facing label for reference KIND."
  (pcase kind
    (:document-link "Document link")
    (:semantic-edge "Semantic mention")
    (:field-reference "Field reference")
    (:legacy-reference "Legacy reference")
    (_ "Reference")))

(defun supertag-reference-service--aggregate (anchor-id direction)
  "Aggregate references touching ANCHOR-ID in DIRECTION.

DIRECTION is `:out' for referenced targets or `:in' for Backlink sources."
  (let* ((anchor (supertag-store-get-entity :nodes anchor-id))
         (relations
          (when anchor
            (if (eq direction :out)
                (supertag-query-relations-from anchor-id :reference)
              (supertag-query-relations-to anchor-id :reference))))
         (by-endpoint (make-hash-table :test #'equal))
         result)
    (dolist (relation relations)
      (let* ((out-p (eq direction :out))
             (endpoint-id (plist-get relation (if out-p :to :from)))
             (endpoint (supertag-store-get-entity :nodes endpoint-id)))
        (when endpoint
          (let* ((existing (gethash endpoint-id by-endpoint))
                 (title (supertag-reference-service-node-title endpoint))
                 (location (supertag-reference-service-node-location endpoint))
                 (file (supertag-reference-service--node-prop endpoint :file))
                 (position
                  (or (supertag-reference-service--node-prop endpoint :position)
                      (supertag-reference-service--node-prop endpoint :pos)
                      0))
                 (source (if out-p anchor endpoint))
                 (target (if out-p endpoint anchor))
                 (item
                  (list :node-id endpoint-id
                        :title title
                        :location location
                        :file file
                        :position position
                        :snippet
                        (supertag-reference-service-context-snippet source target)
                        :kinds
                        (cl-adjoin (plist-get relation :kind)
                                   (plist-get existing :kinds))
                        :relation-ids
                        (cl-adjoin (plist-get relation :id)
                                   (plist-get existing :relation-ids)
                                   :test #'equal))))
            ;; Direction-specific aliases keep the read model explicit for
            ;; callers that care which endpoint was projected.
            (setq item
                  (append item
                          (if out-p
                              (list :target-id endpoint-id
                                    :target-title title
                                    :target-location location)
                            (list :source-id endpoint-id
                                  :source-title title
                                  :source-location location
                                  :source-file file
                                  :source-position position))))
            (puthash endpoint-id item by-endpoint)))))
    (maphash (lambda (_endpoint-id item) (push item result)) by-endpoint)
    result))

(defun supertag-reference-service-backlinks (target-id)
  "Return contextual incoming references for TARGET-ID.

The result contains one item per source node. Multiple relation kinds from the
same source are aggregated instead of rendering duplicate cards."
  (sort
   (supertag-reference-service--aggregate target-id :in)
   (lambda (left right)
     (let ((left-file (or (plist-get left :file) ""))
           (right-file (or (plist-get right :file) "")))
       (if (string-equal left-file right-file)
           (< (or (plist-get left :position) 0)
              (or (plist-get right :position) 0))
         (string< left-file right-file))))))

(defun supertag-reference-service-outgoing (source-id)
  "Return contextual outgoing references for SOURCE-ID.

The result contains one item per target node. Multiple relation kinds between
the same endpoints are aggregated instead of rendering duplicate cards."
  (sort
   (supertag-reference-service--aggregate source-id :out)
   (lambda (left right)
     (string< (format "%s/%s"
                      (or (plist-get left :title) "")
                      (or (plist-get left :node-id) ""))
              (format "%s/%s"
                      (or (plist-get right :title) "")
                      (or (plist-get right :node-id) ""))))))

(defun supertag-reference-service--candidate-base-label (node)
  "Return the base completion label for NODE."
  (format "%s  (%s)"
          (supertag-reference-service-node-title node)
          (supertag-reference-service-node-location node)))

(defun supertag-reference-service-candidates (&optional exclude-id)
  "Return UI-ready reference candidates, excluding EXCLUDE-ID when non-nil."
  (let ((raw nil)
        (counts (make-hash-table :test #'equal))
        result)
    (maphash
     (lambda (node-id node)
       (when (and (not (equal node-id exclude-id))
                  (eq (supertag-reference-service--node-prop node :type) :node)
                  (not (string-empty-p
                        (string-trim
                         (supertag-reference-service-node-title node)))))
         (let ((base (supertag-reference-service--candidate-base-label node)))
           (puthash base (1+ (gethash base counts 0)) counts)
           (push (list :node-id node-id
                       :node node
                       :title (supertag-reference-service-node-title node)
                       :terms (supertag-reference-service-node-terms node)
                       :base-label base)
                 raw))))
     (supertag-store-get-collection :nodes))
    (dolist (candidate raw)
      (let* ((base (plist-get candidate :base-label))
             (display (if (> (gethash base counts 0) 1)
                          (format "%s [%s]" base (plist-get candidate :node-id))
                        base)))
        (push (plist-put (copy-sequence candidate) :display display) result)))
    (sort result
          (lambda (left right)
            (string< (plist-get left :display)
                     (plist-get right :display))))))

(defun supertag-reference-service-find-by-term (term &optional exclude-id)
  "Return the unique reference candidate matching TERM.
Signal an error when TERM names more than one node."
  (let* ((clean (string-trim (or term "")))
         (candidates (supertag-reference-service-candidates exclude-id))
         (exact
          (cl-remove-if-not
           (lambda (candidate)
             (member clean (plist-get candidate :terms)))
           candidates))
         (matches
          (or exact
              (let ((folded (downcase clean)))
                (cl-remove-if-not
                 (lambda (candidate)
                   (cl-some (lambda (candidate-term)
                              (string-equal folded (downcase candidate-term)))
                            (plist-get candidate :terms)))
                 candidates)))))
    (pcase (length matches)
      (0 nil)
      (1 (car matches))
      (_ (user-error "Reference title is ambiguous: %s" clean)))))

(provide 'supertag-services-reference)
;;; supertag-services-reference.el ends here
