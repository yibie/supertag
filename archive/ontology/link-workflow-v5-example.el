;;; link-workflow-v5-example.el --- Minimal typed-Link example. -*- lexical-binding: t; -*-

(require 'supertag-ontology)

(supertag-defontology work
  :version 1
  :description "Small project/task domain"

  (field status
    :label "Status"
    :type options
    :options (idea active blocked done))

  (type project
    :label "Project"
    :fields (status))

  (type task
    :label "Task"
    :fields (status))

  (link tasks
    :label "Tasks"
    :inverse-label "Project"
    :from project
    :to task
    :from-cardinality many
    :to-cardinality one))

;; Load this file, then run:
;;   M-x supertag-ontology-preview
;;   M-x supertag-ontology-apply
;;
;; At a Project or Task heading:
;;   M-x supertag-link-menu
;;
;; Query Projects that have a blocked Task:
;;   (supertag-query-node-ids
;;    '(and (tag "Project")
;;          (link work/tasks (field "Status" "blocked"))))

(provide 'link-workflow-v5-example)
;;; link-workflow-v5-example.el ends here
