;;; ontology-policy-v11-example.el --- Small Policy example -*- lexical-binding: t; -*-

(require 'supertag-ontology)

(supertag-defontology work
  :version 11

  (field status
    :label "Status"
    :type options
    :options (active done))

  (type project
    :label "Project"
    :fields (status))

  (action complete-project
    :label "Complete Project"
    :subject project
    :effects
    ((set-field status :value "done")))

  (policy complete-project-access
    :label "Complete Project Access"
    :action complete-project
    :actors
    ((interactive-user confirm
      :reason "A person must approve project completion")
     (automation deny
      :reason "Automation cannot complete projects")
     (llm propose-only
      :reason "The model may prepare a proposal only")
     (external deny
      :reason "External execution is disabled"))))

;; Loading is pure. Review and deploy explicitly:
;; M-x supertag-ontology-preview
;; M-x supertag-ontology-apply
;;
;; At a Project heading or in Node View:
;; M-x supertag-action-run

(provide 'ontology-policy-v11-example)
;;; ontology-policy-v11-example.el ends here
