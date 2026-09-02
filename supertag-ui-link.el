;;; supertag-ui-link.el --- Interactive typed Link workflow. -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'supertag-service-node-identity)
(require 'supertag-services-ui)
(require 'supertag-services-sync)
(require 'supertag-services-link)
(require 'supertag-ops-relation)

(defun supertag-link-ui-current-node-id ()
  "Return the semantic node at point or in the current node view."
  (cond
   ((derived-mode-p 'org-mode)
    (save-excursion
      (org-back-to-heading t)
      (let ((node-id (supertag-node-identity-ensure-at-point)))
        ;; Link applicability depends on the current projected Type membership.
        ;; Reconcile the heading before reading Link Definitions so a just-added
        ;; Supertag is immediately available to this command.
        (supertag-node-sync-at-point)
        node-id)))
   ((and (boundp 'supertag-view-node--current-node-id)
         supertag-view-node--current-node-id)
    supertag-view-node--current-node-id)
   (t (user-error "This command requires an Org heading or Supertag node view"))))

(defun supertag-link-ui--read-direction (node-id)
  (let* ((directions (supertag-link-service-directions node-id))
         (candidates
          (mapcar (lambda (direction)
                    (cons (supertag-link-service-direction-label direction)
                          direction))
                  directions)))
    (unless candidates
      (user-error "No Link Definition applies to this node's types"))
    (cdr (assoc (completing-read "Link type: " candidates nil t)
                candidates))))

(defun supertag-link-ui--node-candidates (node-ids)
  (mapcar
   (lambda (node-id)
     (let ((node (supertag-store-get-entity :nodes node-id)))
       (cons (format "%s  [%s]"
                     (supertag-ui-format-node-display node)
                     node-id)
             node-id)))
   node-ids))

(defun supertag-link-ui--read-other-node (node-id direction)
  (let* ((ids (supertag-link-service-candidate-node-ids node-id direction))
         (candidates (supertag-link-ui--node-candidates ids)))
    (unless candidates
      (user-error "No eligible unlinked node is available for this Link"))
    (cdr (assoc (completing-read "Other node: " candidates nil t)
                candidates))))

;;;###autoload
(defun supertag-link-add (&optional node-id)
  "Add one typed Link involving NODE-ID or the current node."
  (interactive)
  (let* ((node-id (or node-id (supertag-link-ui-current-node-id)))
         (direction (supertag-link-ui--read-direction node-id))
         (other-id (supertag-link-ui--read-other-node node-id direction))
         (endpoints (supertag-link-service-endpoints node-id direction other-id))
         (definition-id (plist-get direction :definition-id))
         (conflicts (supertag-link-conflicts
                     definition-id (car endpoints) (cdr endpoints)))
         relation)
    (setq relation
          (if conflicts
              (progn
                (unless (yes-or-no-p
                         (format "Replace %d conflicting Link%s? "
                                 (length conflicts)
                                 (if (= (length conflicts) 1) "" "s")))
                  (user-error "Link creation cancelled"))
                (supertag-link-create-replacing-conflicts
                 definition-id (car endpoints) (cdr endpoints)))
            (supertag-link-create definition-id (car endpoints) (cdr endpoints))))
    (message "Linked %s and %s via %s"
             (supertag-link-service-node-title (car endpoints))
             (supertag-link-service-node-title (cdr endpoints))
             (plist-get direction :label))
    relation))

;;;###autoload
(defun supertag-link-remove (&optional node-id)
  "Remove one typed Link involving NODE-ID or the current node."
  (interactive)
  (let* ((node-id (or node-id (supertag-link-ui-current-node-id)))
         (instances (supertag-link-service-instances node-id))
         (candidates
          (mapcar
           (lambda (instance)
             (cons (format "%s %s %s"
                           (plist-get instance :label)
                           (if (eq (plist-get instance :direction) :out) "->" "<-")
                           (plist-get instance :other-title))
                   instance))
           instances)))
    (unless candidates (user-error "This node has no typed Links"))
    (let* ((instance
            (cdr (assoc (completing-read "Remove Link: " candidates nil t)
                        candidates)))
           (relation (plist-get instance :relation)))
      (when (yes-or-no-p
             (format "Remove Link to %s? " (plist-get instance :other-title)))
        (supertag-relation-delete (plist-get relation :id))
        relation))))

;;;###autoload
(defun supertag-link-menu ()
  "Open the compact typed Link command menu."
  (interactive)
  (pcase (completing-read "Link action: " '("Add Link" "Remove Link") nil t)
    ("Add Link" (call-interactively #'supertag-link-add))
    ("Remove Link" (call-interactively #'supertag-link-remove))))

(provide 'supertag-ui-link)
;;; supertag-ui-link.el ends here
