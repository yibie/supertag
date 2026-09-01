# Ontology Function and Action v10

This release extends the v8 Ontology Control Plane with two domain
capabilities while preserving the existing ownership boundary:

```text
Function = typed, read-only computation
Action   = typed, declarative Semantic Fact mutation
```

Function implementations are trusted Elisp symbols.  They receive a copied
subject node, an ordered argument list, and a copied call context.  The Store
mutation seam rejects writes while the implementation runs.  This is a
Supertag Store guarantee, not a general Elisp sandbox.

Actions support four effects in v10:

```text
set-field
clear-field
add-link
remove-link
```

Action preconditions call deployed Functions before mutation.  All effects are
planned and validated before one Canonical Change transaction commits the
effects and the `:ontology-action-executions` audit record together.

## Declaration

```elisp
(defun work-project-progress (_project arguments _context)
  (or (car arguments) 100))

(supertag-defontology work
  :version 10

  (field status
    :label "Status"
    :type options
    :options (active done))

  (field completed-at
    :label "Completed At"
    :type timestamp)

  (type project
    :label "Project"
    :fields (status completed-at))

  (function project-progress
    :label "Project Progress"
    :subject project
    :parameters ((include-blocked :type boolean :default nil))
    :returns number
    :implementation work-project-progress)

  (action complete-project
    :label "Complete Project"
    :subject project
    :parameters ((completed-at :type timestamp))
    :preconditions
    ((function project-progress :operator :equal :value 100))
    :effects
    ((set-field status :value "done")
     (set-field completed-at :value (:arg completed-at)))))
```

Parameter order is contractual.  Missing input, explicit `nil`, false, and an
empty list remain distinct.  Defaults and return values pass through the same
type validator used for supplied arguments.

## Runtime

```elisp
(supertag-ontology-function-call
 'project-progress "PROJECT-NODE-ID"
 '(:include-blocked nil))

(supertag-ontology-action-preview
 'complete-project "PROJECT-NODE-ID"
 '(:completed-at "2026-08-28T12:00:00Z"))

(supertag-ontology-action-execute
 'complete-project "PROJECT-NODE-ID"
 '(:completed-at "2026-08-28T12:00:00Z")
 :user)
```

Node View lists Functions and Actions whose subject Type accepts the current
node.  Listing does not run Functions or Action preconditions.

## Boundary

v10 does not add arbitrary Elisp Action effects, Org text mutation, shell or
network effects, Policy evaluation, or LLM Tool Generation.  Those require
separate adapters or later control-plane layers.
