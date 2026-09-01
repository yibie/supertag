;;; ontology-llm-tool-v12-example.el --- Explicit LLM tool exposure -*- lexical-binding: t; -*-

(require 'supertag-ontology)

(defun work-project-progress (_node arguments _context)
  "Return a demo project progress value using optional ARGUMENTS."
  (let ((include-blocked (car arguments)))
    (if include-blocked 65 75)))

(supertag-defontology work
  :version 12

  (field status :type options :options (active done))
  (type project :fields (status))

  (function project-progress
    :label "Project progress"
    :description "Calculate current progress without storing a duplicate value"
    :subject project
    :parameters ((include-blocked :type boolean :default nil))
    :returns number
    :implementation work-project-progress
    :llm-tool t
    :tool-name "project_progress")

  (action complete-project
    :label "Complete Project"
    :subject project
    :effects ((set-field status :value "done"))
    :confirmation :never
    :llm-tool t
    :tool-name "complete_project")

  (policy complete-project-access
    :action complete-project
    :actors ((interactive-user allow)
             (automation deny)
             (llm propose-only
                  :reason "The model may prepare a proposal only")
             (external deny))))

;; Loading this file remains pure. Deploy behavioral changes explicitly:
;; M-x supertag-ontology-preview
;; M-x supertag-ontology-apply
;;
;; Inspect generated tools after deployment:
;; M-x supertag-ui-tool-list
;; M-x supertag-ui-tool-copy-catalog-json

(provide 'ontology-llm-tool-v12-example)
;;; ontology-llm-tool-v12-example.el ends here
