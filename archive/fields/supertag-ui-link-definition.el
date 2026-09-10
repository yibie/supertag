;;; supertag-ui-link-definition.el --- Interactive Link Definition editor. -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-services-query)
(require 'supertag-ops-link-definition)
(require 'supertag-schema-authority)

(defun supertag-ui-link-definition--tag-candidates ()
  (mapcar (lambda (descriptor)
            (cons (plist-get descriptor :display-path)
                  (plist-get descriptor :id)))
          (supertag-query-tag-paths)))

(defun supertag-ui-link-definition--read-tag (prompt &optional initial-id)
  (let* ((candidates (supertag-ui-link-definition--tag-candidates))
         (initial (car (rassoc initial-id candidates)))
         (choice (completing-read prompt candidates nil t nil nil initial)))
    (cdr (assoc choice candidates))))

(defun supertag-ui-link-definition--read-cardinality (prompt initial)
  (intern (concat ":" (completing-read
                        prompt '("one" "many") nil t nil nil
                        (substring (symbol-name (or initial :many)) 1)))))

;;;###autoload
(defun supertag-ui-link-definition-create ()
  "Interactively create one runtime-managed Link Definition."
  (interactive)
  (let* ((name (string-trim (read-string "Link name: ")))
         (inverse (string-trim (read-string "Inverse name (optional): ")))
         (from (supertag-ui-link-definition--read-tag "Source type: "))
         (to (supertag-ui-link-definition--read-tag "Target type: "))
         (from-card (supertag-ui-link-definition--read-cardinality
                     "Targets per source: " :many))
         (to-card (supertag-ui-link-definition--read-cardinality
                   "Sources per target: " :many)))
    (when (string-empty-p name) (user-error "Link name cannot be empty"))
    (supertag-link-definition-create
     (list :name name
           :inverse-name (unless (string-empty-p inverse) inverse)
           :from-tag-id from :to-tag-id to
           :from-cardinality from-card :to-cardinality to-card
           :managed-by :interactive))))

;;;###autoload
(defun supertag-ui-link-definition-edit (definition-id)
  "Interactively edit Link Definition DEFINITION-ID."
  (interactive
   (let* ((candidates
           (mapcar (lambda (definition)
                     (cons (supertag-link-definition-format definition)
                           (plist-get definition :id)))
                   (supertag-link-definition-list)))
          (choice (completing-read "Link Definition: " candidates nil t)))
     (list (cdr (assoc choice candidates)))))
  (supertag-schema-authority-assert :link definition-id :update)
  (let* ((definition (or (supertag-link-definition-get definition-id)
                         (user-error "Unknown Link Definition %s" definition-id)))
         (name (string-trim
                (read-string "Link name: " (plist-get definition :name))))
         (inverse (string-trim
                   (read-string "Inverse name (optional): "
                                (or (plist-get definition :inverse-name) ""))))
         (from (supertag-ui-link-definition--read-tag
                "Source type: " (plist-get definition :from-tag-id)))
         (to (supertag-ui-link-definition--read-tag
              "Target type: " (plist-get definition :to-tag-id)))
         (from-card (supertag-ui-link-definition--read-cardinality
                     "Targets per source: "
                     (plist-get definition :from-cardinality)))
         (to-card (supertag-ui-link-definition--read-cardinality
                   "Sources per target: "
                   (plist-get definition :to-cardinality))))
    (supertag-link-definition-update
     definition-id
     (lambda (previous)
       (let ((updated (copy-tree previous)))
         (dolist (pair `((:name . ,name)
                         (:inverse-name . ,(unless (string-empty-p inverse)
                                             inverse))
                         (:from-tag-id . ,from) (:to-tag-id . ,to)
                         (:from-cardinality . ,from-card)
                         (:to-cardinality . ,to-card)))
           (setq updated (plist-put updated (car pair) (cdr pair))))
         updated)))))

;;;###autoload
(defun supertag-ui-link-definition-delete (definition-id)
  "Delete Link Definition DEFINITION-ID after confirmation."
  (interactive)
  (supertag-schema-authority-assert :link definition-id :delete)
  (let ((definition (or (supertag-link-definition-get definition-id)
                        (user-error "Unknown Link Definition %s" definition-id))))
    (when (yes-or-no-p
           (format "Delete Link Definition '%s'? "
                   (plist-get definition :name)))
      (supertag-link-definition-delete definition-id nil))))

(provide 'supertag-ui-link-definition)
;;; supertag-ui-link-definition.el ends here
