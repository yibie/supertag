;;; supertag-ontology-migration-callback.el --- Pure callback boundary -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Migration transformers and Link conflict resolvers run while a read-only
;; plan is being built.  This boundary detects Store writes performed through
;; Supertag's canonical mutation seams, rolls them back, and rejects the
;; callback.  External I/O cannot be made pure by the runtime; declarations
;; must still treat callbacks as deterministic, side-effect-free functions.

;;; Code:

(require 'supertag-core-state)
(require 'supertag-core-transform)

(define-error 'supertag-ontology-migration-impure-callback
  "Ontology migration callback mutated the Supertag Store")

(defun supertag-ontology-migration-callback-call (function &rest arguments)
  "Call FUNCTION with ARGUMENTS inside a read-only Store transaction.

Return FUNCTION's result when no canonical Store path was touched.  If the
callback writes through a Supertag Store mutation seam, roll the write back and
signal `supertag-ontology-migration-impure-callback'.  Planning inside an
already-active transaction is rejected because its writes cannot be isolated
from the caller's transaction log."
  (when supertag--transaction-active
    (signal 'supertag-ontology-migration-impure-callback
            (list function "cannot verify purity inside an active transaction")))
  (let (result)
    (supertag-with-transaction
      (setq result (apply function arguments))
      (when supertag--transaction-log
        (signal 'supertag-ontology-migration-impure-callback
                (list function "wrote to the Supertag Store during preview"))))
    result))

(provide 'supertag-ontology-migration-callback)
;;; supertag-ontology-migration-callback.el ends here
