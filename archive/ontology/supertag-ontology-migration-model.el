;;; supertag-ontology-migration-model.el --- Pure migration DSL model -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Normalizes migration declarations into pure data.  No Store access occurs
;; in this module.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst supertag-ontology-migration-model-version 1)

(defcustom supertag-ontology-migration-preview-sample-limit 10
  "Maximum changed records retained as examples in one migration step plan."
  :type 'integer
  :group 'supertag-ontology)

(defconst supertag-ontology-migration-model-top-keywords
  '(:module :from :from-version :to :to-version :description))
(defconst supertag-ontology-migration-model-transform-field-keywords
  '(:using :on-error))
(defconst supertag-ontology-migration-model-detach-field-keywords nil)
(defconst supertag-ontology-migration-model-tighten-link-keywords
  '(:source-resolver :target-resolver))

(defconst supertag-ontology-migration-drop 'supertag-ontology-migration-drop
  "Transformer result meaning that the current field value must be removed.")

(defun supertag-ontology-migration-model--plist-keys (plist)
  "Return keys from PLIST without validating values."
  (let (keys)
    (while plist
      (push (pop plist) keys)
      (pop plist))
    (nreverse keys)))

(defun supertag-ontology-migration-model--normalize-key (value)
  "Normalize a DSL identifier VALUE."
  (cond ((symbolp value) value)
        ((stringp value) (intern value))
        (t value)))

(defun supertag-ontology-migration-model--function-symbol (value)
  "Normalize function reference VALUE to a symbol when possible."
  (cond
   ((null value) nil)
   ((symbolp value) value)
   ((and (consp value) (eq (car value) 'function)
         (symbolp (cadr value)) (null (cddr value)))
    (cadr value))
   (t value)))

(defun supertag-ontology-migration-model-logical-id (module name)
  "Return stable logical identity for MODULE migration NAME."
  (format "%s/migration/%s" module name))

(defun supertag-ontology-migration-model--step-id (migration-name index kind)
  "Return stable step ID."
  (format "%s/step/%03d/%s" migration-name index kind))

(defun supertag-ontology-migration-model--unknown-keywords (plist allowed)
  "Return PLIST keys not present in ALLOWED."
  (cl-set-difference
   (supertag-ontology-migration-model--plist-keys plist)
   allowed :test #'eq))

(defun supertag-ontology-migration-model--normalize-step
    (migration-name module form index source)
  "Normalize migration step FORM."
  (let ((kind (car-safe form)))
    (pcase kind
      ('transform-field
       (let* ((field (nth 1 form))
              (plist (nthcdr 2 form)))
         (list :id (supertag-ontology-migration-model--step-id
                    migration-name index 'transform-field)
               :kind :transform-field :module module
               :field (supertag-ontology-migration-model--normalize-key field)
               :using (supertag-ontology-migration-model--function-symbol
                       (plist-get plist :using))
               :on-error (or (plist-get plist :on-error) :abort)
               :unknown-keywords
               (supertag-ontology-migration-model--unknown-keywords
                plist supertag-ontology-migration-model-transform-field-keywords)
               :source source)))
      ('detach-field
       (let* ((type (nth 1 form))
              (field (nth 2 form))
              (plist (nthcdr 3 form)))
         (list :id (supertag-ontology-migration-model--step-id
                    migration-name index 'detach-field)
               :kind :detach-field :module module
               :type (supertag-ontology-migration-model--normalize-key type)
               :field (supertag-ontology-migration-model--normalize-key field)
               :unknown-keywords
               (supertag-ontology-migration-model--unknown-keywords
                plist supertag-ontology-migration-model-detach-field-keywords)
               :source source)))
      ('tighten-link
       (let* ((link (nth 1 form))
              (plist (nthcdr 2 form)))
         (list :id (supertag-ontology-migration-model--step-id
                    migration-name index 'tighten-link)
               :kind :tighten-link :module module
               :link (supertag-ontology-migration-model--normalize-key link)
               :source-resolver
               (supertag-ontology-migration-model--function-symbol
                (plist-get plist :source-resolver))
               :target-resolver
               (supertag-ontology-migration-model--function-symbol
                (plist-get plist :target-resolver))
               :unknown-keywords
               (supertag-ontology-migration-model--unknown-keywords
                plist supertag-ontology-migration-model-tighten-link-keywords)
               :source source)))
      (_
       (list :id (supertag-ontology-migration-model--step-id
                  migration-name index 'unknown)
             :kind :unknown :raw form :module module :source source)))))

(defun supertag-ontology-migration-model-normalize (name raw-body source)
  "Normalize migration NAME RAW-BODY from SOURCE."
  (let (module from-version to-version description unknown-top steps)
    (while (keywordp (car raw-body))
      (let ((key (pop raw-body))
            (value (pop raw-body)))
        (pcase key
          (:module (setq module
                         (supertag-ontology-migration-model--normalize-key value)))
          ((or :from :from-version) (setq from-version value))
          ((or :to :to-version) (setq to-version value))
          (:description (setq description value))
          (_ (push (list key value) unknown-top)))))
    (cl-loop for form in raw-body
             for index from 1
             do (push (supertag-ontology-migration-model--normalize-step
                       name module form index source)
                      steps))
    (list :model-version supertag-ontology-migration-model-version
          :name name
          :logical-id (supertag-ontology-migration-model-logical-id module name)
          :module module
          :from-version from-version
          :to-version to-version
          :description description
          :source source
          :unknown-top (nreverse unknown-top)
          :steps (nreverse steps))))

(defun supertag-ontology-migration-model--canonical-step (step)
  "Return semantic data for STEP."
  (pcase (plist-get step :kind)
    (:transform-field
     (list :kind :transform-field :field (plist-get step :field)
           :using (plist-get step :using)
           :on-error (plist-get step :on-error)))
    (:detach-field
     (list :kind :detach-field :type (plist-get step :type)
           :field (plist-get step :field)))
    (:tighten-link
     (list :kind :tighten-link :link (plist-get step :link)
           :source-resolver (plist-get step :source-resolver)
           :target-resolver (plist-get step :target-resolver)))
    (_ (list :kind :unknown :raw (plist-get step :raw)))))

(defun supertag-ontology-migration-model-semantic-data (migration)
  "Return canonical semantic data for MIGRATION."
  (list :model-version (plist-get migration :model-version)
        :name (plist-get migration :name)
        :module (plist-get migration :module)
        :from-version (plist-get migration :from-version)
        :to-version (plist-get migration :to-version)
        :steps (mapcar #'supertag-ontology-migration-model--canonical-step
                       (plist-get migration :steps))))

(defun supertag-ontology-migration-model-hash (migration)
  "Return semantic SHA-256 hash for MIGRATION."
  (secure-hash
   'sha256
   (prin1-to-string
    (supertag-ontology-migration-model-semantic-data migration))))

(defun supertag-ontology-migration-identity (value _context)
  "Return VALUE unchanged.
Useful when a destructive Schema update only needs explicit acknowledgement."
  value)

(provide 'supertag-ontology-migration-model)
;;; supertag-ontology-migration-model.el ends here
