;;; supertag-services-link.el --- Read model for typed Link workflows. -*- lexical-binding: t; -*-

;;; Commentary:
;; Composes Link Definitions, instances and node types into UI-ready data.
;; It does not mutate the Store.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-ops-link-definition)
(require 'supertag-ops-relation)

(defun supertag-link-service-node-title (node-id)
  "Return a readable title for NODE-ID."
  (let ((node (supertag-store-get-entity :nodes node-id)))
    (or (plist-get node :raw-value) (plist-get node :title) node-id)))

(defun supertag-link-service-direction-label (direction)
  "Return a completion label for DIRECTION descriptor."
  (let* ((definition (plist-get direction :definition))
         (arrow (if (eq (plist-get direction :direction) :out) "->" "<-"))
         (name (plist-get direction :label))
         (other-tag (supertag-link-definition-tag-name
                     (plist-get direction :other-tag-id))))
    (format "%s %s %s  [%s]" name arrow other-tag
            (supertag-link-definition-reference definition))))

(defun supertag-link-service-directions (node-id)
  "Return Link directions applicable to NODE-ID's semantic types."
  (let (result)
    (dolist (definition (supertag-link-definition-list))
      (when (supertag-link-definition-node-satisfies-type-p
             node-id (plist-get definition :from-tag-id))
        (push (list :definition definition
                    :definition-id (plist-get definition :id)
                    :direction :out
                    :label (or (plist-get definition :name)
                               (plist-get definition :id))
                    :other-tag-id (plist-get definition :to-tag-id))
              result))
      (when (supertag-link-definition-node-satisfies-type-p
             node-id (plist-get definition :to-tag-id))
        (push (list :definition definition
                    :definition-id (plist-get definition :id)
                    :direction :in
                    :label (or (plist-get definition :inverse-name)
                               (plist-get definition :name)
                               (plist-get definition :id))
                    :other-tag-id (plist-get definition :from-tag-id))
              result)))
    (sort result
          (lambda (a b)
            (string< (supertag-link-service-direction-label a)
                     (supertag-link-service-direction-label b))))))

(defun supertag-link-service-instances (node-id)
  "Return UI-ready typed Link instances touching NODE-ID."
  (let (result)
    (dolist (relation (supertag-link-instances-for-node node-id))
      (let* ((out-p (equal node-id (plist-get relation :from)))
             (definition
              (supertag-link-definition-get
               (plist-get relation :link-definition-id)))
             (other-id (if out-p (plist-get relation :to)
                         (plist-get relation :from))))
        (when definition
          (push (list :relation relation
                      :relation-id (plist-get relation :id)
                      :definition definition
                      :definition-id (plist-get definition :id)
                      :direction (if out-p :out :in)
                      :label (if out-p
                                 (or (plist-get definition :name)
                                     (plist-get definition :id))
                               (or (plist-get definition :inverse-name)
                                   (plist-get definition :name)
                                   (plist-get definition :id)))
                      :other-node-id other-id
                      :other-title (supertag-link-service-node-title other-id))
                result))))
    (sort result
          (lambda (a b)
            (string< (format "%s/%s" (plist-get a :label)
                             (plist-get a :other-title))
                     (format "%s/%s" (plist-get b :label)
                             (plist-get b :other-title)))))))

(defun supertag-link-service-candidate-node-ids (node-id direction)
  "Return valid other endpoint IDs for NODE-ID and DIRECTION."
  (let* ((definition-id (plist-get direction :definition-id))
         (out-p (eq (plist-get direction :direction) :out))
         (required-tag-id (plist-get direction :other-tag-id))
         result)
    (maphash
     (lambda (candidate-id _node)
       (when (and (not (equal candidate-id node-id))
                  (supertag-link-definition-node-satisfies-type-p
                   candidate-id required-tag-id)
                  (if out-p
                      (null (supertag-link-find definition-id node-id candidate-id))
                    (null (supertag-link-find definition-id candidate-id node-id))))
         (push candidate-id result)))
     (supertag-store-get-collection :nodes))
    (sort result
          (lambda (a b)
            (string< (supertag-link-service-node-title a)
                     (supertag-link-service-node-title b))))))

(defun supertag-link-service-endpoints (node-id direction other-node-id)
  "Return (FROM-ID . TO-ID) for the selected DIRECTION."
  (if (eq (plist-get direction :direction) :out)
      (cons node-id other-node-id)
    (cons other-node-id node-id)))

(provide 'supertag-services-link)
;;; supertag-services-link.el ends here
