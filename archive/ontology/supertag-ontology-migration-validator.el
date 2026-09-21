;;; supertag-ontology-migration-validator.el --- Pure migration validation -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Validation is total: malformed declarations produce issue plists instead of
;; leaking incidental type errors from normalization or planning.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'supertag-ontology-migration-model)

(defun supertag-ontology-migration-validator--issue
    (severity code message &optional step)
  "Build one migration validation issue."
  (list :severity severity :code code :message message :step step))

(defun supertag-ontology-migration-validator--identifier-p (value)
  "Return non-nil when VALUE is a usable DSL identifier."
  (and (symbolp value) (not (keywordp value))))

(defun supertag-ontology-migration-validator--function-p (value)
  "Return non-nil when VALUE names an available function."
  (and (symbolp value) (fboundp value)))

(defun supertag-ontology-migration-validator--duplicate-issue
    (seen key step)
  "Return duplicate coverage issue for KEY, or remember it in SEEN."
  (if (gethash key seen)
      (supertag-ontology-migration-validator--issue
       :error :duplicate-step
       (format "Migration target %S is covered by more than one step" key)
       step)
    (puthash key t seen)
    nil))

(defun supertag-ontology-migration-validator--validate-step (step seen)
  "Return validation issues for STEP, updating duplicate table SEEN."
  (let (issues)
    (dolist (key (plist-get step :unknown-keywords))
      (push (supertag-ontology-migration-validator--issue
             :error :unknown-step-keyword
             (format "Unknown %s keyword %S"
                     (plist-get step :kind) key)
             step)
            issues))
    (pcase (plist-get step :kind)
      (:transform-field
       (unless (supertag-ontology-migration-validator--identifier-p
                (plist-get step :field))
         (push (supertag-ontology-migration-validator--issue
                :error :invalid-field-key
                "transform-field requires a non-keyword field identifier"
                step)
               issues))
       (unless (supertag-ontology-migration-validator--function-p
                (plist-get step :using))
         (push (supertag-ontology-migration-validator--issue
                :error :invalid-transformer
                (format "Transformer %S is not a defined function"
                        (plist-get step :using))
                step)
               issues))
       (unless (memq (plist-get step :on-error) '(:abort :drop))
         (push (supertag-ontology-migration-validator--issue
                :error :invalid-on-error
                "transform-field :on-error must be :abort or :drop"
                step)
               issues))
       (when-let ((issue
                   (supertag-ontology-migration-validator--duplicate-issue
                    seen (list :field (plist-get step :field)) step)))
         (push issue issues)))
      (:detach-field
       (unless (supertag-ontology-migration-validator--identifier-p
                (plist-get step :type))
         (push (supertag-ontology-migration-validator--issue
                :error :invalid-type-key
                "detach-field requires a non-keyword type identifier"
                step)
               issues))
       (unless (supertag-ontology-migration-validator--identifier-p
                (plist-get step :field))
         (push (supertag-ontology-migration-validator--issue
                :error :invalid-field-key
                "detach-field requires a non-keyword field identifier"
                step)
               issues))
       (when-let ((issue
                   (supertag-ontology-migration-validator--duplicate-issue
                    seen (list :type-field
                               (plist-get step :type)
                               (plist-get step :field))
                    step)))
         (push issue issues)))
      (:tighten-link
       (unless (supertag-ontology-migration-validator--identifier-p
                (plist-get step :link))
         (push (supertag-ontology-migration-validator--issue
                :error :invalid-link-key
                "tighten-link requires a non-keyword link identifier"
                step)
               issues))
       (dolist (slot '(:source-resolver :target-resolver))
         (let ((resolver (plist-get step slot)))
           (when (and resolver
                      (not (supertag-ontology-migration-validator--function-p
                            resolver)))
             (push (supertag-ontology-migration-validator--issue
                    :error :invalid-resolver
                    (format "%S %S is not a defined function" slot resolver)
                    step)
                   issues))))
       (when-let ((issue
                   (supertag-ontology-migration-validator--duplicate-issue
                    seen (list :link (plist-get step :link)) step)))
         (push issue issues)))
      (_
       (push (supertag-ontology-migration-validator--issue
              :error :unknown-step
              (format "Unknown migration step %S" (plist-get step :raw))
              step)
             issues)))
    (nreverse issues)))

(defun supertag-ontology-migration-validator-validate (migration)
  "Return validation issues for normalized MIGRATION.

The function never intentionally signals for user-provided declaration data."
  (condition-case err
      (let ((seen (make-hash-table :test #'equal))
            issues)
        (unless (supertag-ontology-migration-validator--identifier-p
                 (plist-get migration :name))
          (push (supertag-ontology-migration-validator--issue
                 :error :invalid-name
                 "Migration name must be a non-keyword symbol")
                issues))
        (unless (supertag-ontology-migration-validator--identifier-p
                 (plist-get migration :module))
          (push (supertag-ontology-migration-validator--issue
                 :error :invalid-module
                 "Migration :module must be a non-keyword symbol")
                issues))
        (let ((from (plist-get migration :from-version))
              (to (plist-get migration :to-version)))
          (unless (and (integerp from) (>= from 0))
            (push (supertag-ontology-migration-validator--issue
                   :error :invalid-from-version
                   "Migration :from-version must be a non-negative integer")
                  issues))
          (unless (and (integerp to) (>= to 0))
            (push (supertag-ontology-migration-validator--issue
                   :error :invalid-to-version
                   "Migration :to-version must be a non-negative integer")
                  issues))
          (when (and (integerp from) (integerp to) (>= from to))
            (push (supertag-ontology-migration-validator--issue
                   :error :invalid-version-order
                   "Migration target version must be greater than source version")
                  issues)))
        (when (and (plist-get migration :description)
                   (not (stringp (plist-get migration :description))))
          (push (supertag-ontology-migration-validator--issue
                 :error :invalid-description
                 "Migration :description must be a string")
                issues))
        (dolist (pair (plist-get migration :unknown-top))
          (push (supertag-ontology-migration-validator--issue
                 :error :unknown-top-keyword
                 (format "Unknown migration keyword %S" (car-safe pair)))
                issues))
        (if (null (plist-get migration :steps))
            (push (supertag-ontology-migration-validator--issue
                   :error :empty-migration
                   "Migration must declare at least one step")
                  issues)
          (dolist (step (plist-get migration :steps))
            (setq issues
                  (nconc (nreverse
                          (supertag-ontology-migration-validator--validate-step
                           step seen))
                         issues))))
        (nreverse issues))
    (error
     (list
      (supertag-ontology-migration-validator--issue
       :error :validator-failure
       (format "Migration validation failed safely: %s"
               (error-message-string err)))))))

(defun supertag-ontology-migration-validator-errors-p (issues)
  "Return non-nil when ISSUES contains an error."
  (cl-some (lambda (issue) (eq (plist-get issue :severity) :error)) issues))

(provide 'supertag-ontology-migration-validator)
;;; supertag-ontology-migration-validator.el ends here
