# Logic Layer Stage (Spec + Tech Research)

## Stage Definition
Introduce a declarative Logic Layer that sits between Data and Behavior in org-supertag.

## User Benefit Hypotheses
- Reduce manual state sync (project status derived from task state).
- Reduce rework via early constraint warnings (deadline consistency).
- Improve view consistency (single semantic definition used across UI).
- Improve AI safety (actions only allowed on logic-approved contexts).

## Exit Criteria (This Stage Ends When...)
- A minimal DSL is defined and documented.
- Logic rules can be evaluated on current data.
- Automation can consume logic results by reference (id or name).
- A pilot demo shows end-to-end flow: data change -> logic -> automation.

## Scope
- Declarative rules: derived facts, constraints, semantic views.
- No direct mutations from logic (logic is read-only).
- Behavior uses logic results but keeps existing triggers and actions.

## Non-Goals
- Full inference engine or complex reasoning.
- Automatic fixes for constraints.
- Rewriting all existing automations.

## Core Concepts
- Data: entities, fields, relations (existing tags/fields/relations).
- Logic: read-only semantics (derive/constraint/view).
- Behavior: actions triggered by events, using logic outputs.

## DSL (Minimal Spec)

### Form
- S-expression list of rules.
- Rules are pure and side-effect free.

### Rule Types
- :derive   -> computes a field value or flag
- :constraint -> validates; returns diagnostics
- :view     -> named query set

### Predicates (Minimal)
- (tag "name")
- (field= "name" "value")
- (field< "name" value)
- (field> "name" value)
- (exists (node ...))
- (related :type "rel" :to $self)
- (and ...), (or ...), (not ...)
- (now)

### Example: Project/Task
```elisp
(setq supertag-logic
      '((:id "project-blocked" :type :derive
         :for (tag "project")
         :derive ((field "status")
                  (if (exists (node :tag "task"
                                    :related (:type "belongs-to" :to $self)
                                    :where (field= "status" "blocked")))
                      "blocked" "ok")))
        (:id "task-deadline<=project" :type :constraint
         :for (tag "task")
         :assert (<= (field "deadline")
                     (field-of (related :type "belongs-to") "deadline"))
         :message "task deadline after project")
        (:id "overdue-tasks" :type :view
         :select (node :tag "task")
         :where (and (field< "deadline" (now))
                     (not (field= "status" "done")))))))
```

### Example: Contact
```elisp
(setq supertag-logic
      '((:id "contact-followup" :type :view
         :select (node :tag "contact")
         :where (and (field< "last-contact" (days-ago 30))
                     (not (field= "tier" "other")))))))
```

## Automation Integration

### Behavior Consumes Logic by Reference
- Existing conditions remain valid.
- New condition form: (logic "overdue-tasks")
- New derived fields are treated as read-only outputs.

### Example (Automation)
```elisp
(:id "notify-overdue"
 :trigger :on-view-open
 :condition '(logic "overdue-tasks")
 :actions ((:action :notify :params (:message "You have overdue tasks"))))
```

## Evaluation Strategy (Tech Research)
- On-demand evaluation for views, with memoized results.
- Incremental evaluation for derives/constraints triggered by data changes.
- Cache invalidation keyed by entity id and field updates.
- Diagnostics stored separately (non-destructive).

## Storage Options
- Option A: store rules inside the db file (simple, less portable).
- Option B: store rules in a dedicated .el/.org file (auditable, versioned).
- Option C: mix A+B (db cache + file as source of truth).

## Decision Log (Open Questions)
- Rule source of truth: Option A vs Option B vs Option C.
- Evaluation mode: pull-on-read vs push-on-write vs hybrid cache.
- Derived values: materialize into fields vs overlay-only (avoid conflicts).
- Constraint handling: warn-only vs block behavior vs block writes.
- Time semantics: snapshot "now" per eval vs per rule vs per entity.
- Rule ids/versioning: stable ids vs versioned ids and migration path.

## Explainability Requirements
- For each derived field, provide a trace: which rule + which inputs.
- For each constraint, provide diagnostics: entity, rule id, message.

## Pilot Plan
1) Implement DSL parser + evaluator for :derive/:constraint/:view.
2) Add minimal API:
   - (logic-view "overdue-tasks")
   - (logic-derive "project-blocked" entity-id)
   - (logic-diagnostics entity-id)
3) Connect one automation to logic view id.
4) Demo with project/task and contact datasets.

## Success Metrics
- At least 1 manual sync removed (project status).
- At least 1 automated warning caught (deadline mismatch).
- View consistency: same "overdue" set across UI and automation.

## Risks
- Performance regressions on large datasets.
- Derived values conflicting with user edits.
- DSL complexity creep.

## Mitigations
- Start with narrow predicate set.
- Keep derived values separate from manual fields (namespaced).
- Add explicit "explain" output before auto-apply.
