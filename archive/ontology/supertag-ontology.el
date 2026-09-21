;;; supertag-ontology.el --- Ontology control plane and runtime facade. -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Public facade for Ontology schema, migration, Function, Action, Policy, and LLM tools.

;;; Code:

(require 'supertag-ontology-model)
(require 'supertag-ontology-registry)
(require 'supertag-ontology-validator)
(require 'supertag-ontology-runtime)
(require 'supertag-ontology-plan)
(require 'supertag-ontology-deploy)
(require 'supertag-ontology-contract)
(require 'supertag-ontology-function)
(require 'supertag-ontology-action)
(require 'supertag-ontology-policy)
(require 'supertag-ontology-tool)
(require 'supertag-ui-action)
(require 'supertag-ui-tool)
(require 'supertag-view-ontology)
(require 'supertag-ontology-migration-model)
(require 'supertag-ontology-migration-registry)
(require 'supertag-ontology-migration-validator)
(require 'supertag-ontology-migration-runtime)
(require 'supertag-ontology-migration-plan)
(require 'supertag-ontology-migration-deploy)
(require 'supertag-view-ontology-migration)

;; Compatibility names retained from the v3 public surface.
(defalias 'supertag-ontology-clear-registry
  #'supertag-ontology-registry-clear)
(defalias 'supertag-ontology-modules
  #'supertag-ontology-registry-modules)
(defalias 'supertag-ontology-get
  #'supertag-ontology-registry-get)
(defalias 'supertag-ontology-plan
  #'supertag-ontology-plan-build)

(defun supertag-ontology-initialize ()
  "Load configured declarations, then optionally apply safe plans."
  (interactive)
  (supertag-ontology-load-files)
  (supertag-ontology-migration-load-files)
  (when (eq supertag-ontology-auto-apply 'safe)
    (dolist (module (supertag-ontology-registry-modules))
      (let* ((model (supertag-ontology-registry-get module))
             (plan (supertag-ontology-plan-build model)))
        (when (supertag-ontology-plan-safe-p plan)
          (supertag-ontology-deploy-apply-plan plan))))))

(provide 'supertag-ontology)
;;; supertag-ontology.el ends here
