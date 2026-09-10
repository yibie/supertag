;;; ontology-control-plane-v4-example.el --- Example -*- lexical-binding: t; -*-

(require 'supertag-ontology)

(supertag-defontology personal-work
  :version 1

  (field status
    :label "Status"
    :type options
    :options (idea active waiting done))

  (field deadline
    :label "Deadline"
    :type date)

  (type project
    :label "Project"
    :fields (status deadline))

  (type task
    :label "Task"
    :fields (status deadline))

  (link tasks
    :label "Tasks"
    :inverse-label "Project"
    :from project
    :to task
    :from-cardinality many
    :to-cardinality one))

;; Loading this file only registers the declaration.
;; M-x supertag-ontology-preview
;; M-x supertag-ontology-apply

(provide 'ontology-control-plane-v4-example)
