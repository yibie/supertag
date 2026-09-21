;;; supertag-ontology-function.el --- Read-only Ontology Function runtime -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; A deployed Ontology Function is a Store-owned contract plus a trusted Elisp
;; implementation symbol.  Calls validate subject, parameters and return
;; values.  The implementation runs behind the canonical Store read-only seam;
;; this is not a general Elisp sandbox.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-ops-node)
(require 'supertag-ops-link-definition)
(require 'supertag-ontology-contract)

(defvar supertag-ontology-function--call-stack nil
  "Runtime IDs of Functions active in the current dynamic call chain.")

(defun supertag-ontology-function-list ()
  "Return deployed Function definitions in stable identity order."
  (let (records)
    (maphash (lambda (_id record)
               (push (supertag-ontology-contract-copy record) records))
             (supertag-store-get-collection :ontology-functions))
    (sort records
          (lambda (left right)
            (string< (or (plist-get left :logical-id) "")
                     (or (plist-get right :logical-id) ""))))))

(defun supertag-ontology-function-resolve (reference &optional noerror)
  "Resolve Function REFERENCE by runtime ID, logical ID, module/key or key."
  (let* ((records (supertag-ontology-function-list))
         (text (cond ((symbolp reference) (symbol-name reference))
                     ((stringp reference) reference)))
         (exact (and text
                     (supertag-store-get-entity :ontology-functions text)))
         (matches
          (and (not exact)
               (cl-remove-if-not
                (lambda (record)
                  (or (equal text (plist-get record :logical-id))
                      (equal text
                             (format "%s/%s" (plist-get record :module)
                                     (plist-get record :key)))
                      (equal text (format "%s" (plist-get record :key)))
                      (equal text (plist-get record :label))))
                records))))
    (cond
     (exact (supertag-ontology-contract-copy exact))
     ((= (length matches) 1)
      (supertag-ontology-contract-copy (car matches)))
     ((and matches (not noerror))
      (error "Ambiguous Ontology Function reference %S" reference))
     ((not noerror) (error "Unknown Ontology Function %S" reference)))))

(defun supertag-ontology-function-node-satisfies-type-p
    (node-or-id required-type-id)
  "Return non-nil when NODE-OR-ID is a node of REQUIRED-TYPE-ID."
  (let ((node-id (if (stringp node-or-id)
                     node-or-id
                   (plist-get node-or-id :id))))
    (and node-id
         (supertag-node-get node-id)
         (supertag-link-definition-node-satisfies-type-p
          node-id required-type-id))))

(defun supertag-ontology-function--context (definition node-id bound)
  "Return immutable call context for DEFINITION, NODE-ID and BOUND args."
  (list :function-id (plist-get definition :runtime-id)
        :logical-id (plist-get definition :logical-id)
        :node-id node-id
        :arguments
        (supertag-ontology-contract-copy (plist-get bound :alist))))

(defun supertag-ontology-function-call (reference node-id &optional arguments)
  "Call deployed Function REFERENCE for NODE-ID with ARGUMENTS.

The trusted implementation receives three values: a copied subject node, an
ordered copied argument list, and a copied context plist."
  (let* ((definition (supertag-ontology-function-resolve reference))
         (runtime-id (plist-get definition :runtime-id))
         (node (supertag-node-get node-id)))
    (unless node
      (error "Function subject node %s does not exist" node-id))
    (unless (supertag-ontology-function-node-satisfies-type-p
             node-id (plist-get definition :subject-type-id))
      (error "Node %s does not satisfy Function subject Type %s"
             node-id (plist-get definition :subject-type-id)))
    (when (member runtime-id supertag-ontology-function--call-stack)
      (error "Ontology Function call cycle: %S"
             (reverse (cons runtime-id
                            supertag-ontology-function--call-stack))))
    (let* ((bound
            (supertag-ontology-contract-bind-arguments
             (plist-get definition :parameters) arguments
             #'supertag-ontology-function-node-satisfies-type-p))
           (implementation (plist-get definition :implementation))
           (context
            (supertag-ontology-function--context definition node-id bound))
           result)
      (unless (and (symbolp implementation) (fboundp implementation))
        (error "Function implementation %S is unavailable" implementation))
      (let ((supertag-ontology-function--call-stack
             (cons runtime-id supertag-ontology-function--call-stack))
            (supertag-store-read-only-context
             (format "Ontology Function %s" runtime-id)))
        (setq result
              (funcall implementation
                       (supertag-ontology-contract-copy node)
                       (supertag-ontology-contract-copy
                        (plist-get bound :ordered))
                       (supertag-ontology-contract-copy context))))
      (unless (supertag-ontology-contract-value-valid-p
               result (plist-get definition :returns)
               #'supertag-ontology-function-node-satisfies-type-p nil)
        (error "Function %s returned %S, which does not satisfy %S"
               (plist-get definition :logical-id) result
               (plist-get definition :returns)))
      (supertag-ontology-contract-copy result))))

(defun supertag-ontology-function-applicable (node-id)
  "Return deployed Functions whose subject Type accepts NODE-ID."
  (cl-remove-if-not
   (lambda (definition)
     (supertag-ontology-function-node-satisfies-type-p
      node-id (plist-get definition :subject-type-id)))
   (supertag-ontology-function-list)))

(provide 'supertag-ontology-function)
;;; supertag-ontology-function.el ends here
