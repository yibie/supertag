;;; personal-work-ontology.el --- Example supertag ontology -*- lexical-binding: t; -*-
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

  (type entity
    :label "Entity")

  (type project
    :label "Project"
    :extends entity
    :fields (status deadline))

  (type task
    :label "Task"
    :extends entity
    :fields (status deadline))

  ;; One Project may contain many Tasks; one Task belongs to at most one
  ;; Project through this Link Definition.  Concrete edges are created later
  ;; with `supertag-link-create'.
  (link tasks
    :label "Tasks"
    :inverse-label "Project"
    :from project
    :to task
    :from-cardinality many
    :to-cardinality one))

(provide 'personal-work-ontology)
;;; personal-work-ontology.el ends here
