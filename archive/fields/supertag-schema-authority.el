;;; supertag-schema-authority.el --- First-class authority checks for schema mutations. -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; First-class authority checks for schema mutations.

;;; Code:

(require 'cl-lib)

(define-error 'supertag-schema-authority-error "Schema mutation is not authorized")

(defvar supertag-schema-authority-current-actor :interactive
  "Actor performing the current schema mutation.")

(defvar supertag-schema-authority-provider-function nil
  "Function called with ENTITY-KIND and RUNTIME-ID.
It must return nil for an unmanaged entity or an authority plist.")

(defconst supertag-schema-authority-privileged-actors
  '(:ontology-deployment :migration :system-repair)
  "Actors allowed to mutate ontology-managed schema definitions.")

(defun supertag-schema-authority-get (entity-kind runtime-id)
  "Return authority metadata for ENTITY-KIND and RUNTIME-ID."
  (when (and runtime-id
             (functionp supertag-schema-authority-provider-function))
    (funcall supertag-schema-authority-provider-function
             entity-kind runtime-id)))

(defun supertag-schema-authority-managed-p (entity-kind runtime-id)
  "Return non-nil when ENTITY-KIND and RUNTIME-ID are externally managed."
  (let ((authority (supertag-schema-authority-get entity-kind runtime-id)))
    (and authority (plist-get authority :owner))))

(defun supertag-schema-authority-assert (entity-kind runtime-id operation)
  "Assert that the current actor may perform OPERATION.
ENTITY-KIND and RUNTIME-ID identify the schema definition being changed."
  (let ((authority (supertag-schema-authority-get entity-kind runtime-id)))
    (when (and authority
               (eq (plist-get authority :owner) :ontology)
               (not (memq supertag-schema-authority-current-actor
                          supertag-schema-authority-privileged-actors)))
      (signal 'supertag-schema-authority-error
              (list (format "%s %s is managed by ontology %s; edit its source definition"
                            entity-kind runtime-id
                            (or (plist-get authority :logical-id)
                                (plist-get authority :module)
                                "unknown"))
                    :entity-kind entity-kind
                    :runtime-id runtime-id
                    :operation operation
                    :actor supertag-schema-authority-current-actor
                    :authority authority))))
  t)

(defmacro supertag-schema-authority-with-actor (actor &rest body)
  "Evaluate BODY with schema mutation ACTOR."
  (declare (indent 1) (debug t))
  `(let ((supertag-schema-authority-current-actor ,actor))
     ,@body))

(provide 'supertag-schema-authority)
;;; supertag-schema-authority.el ends here
