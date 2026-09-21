# change_automation_alignment_20260116

## 2026-01-21

- Modify `supertag-automation-sync.el`: keep `supertag-automation-sync--process-node-change` fallback within the `let*` scope to avoid `changed-props` void-variable crashes during async sync.
- Add `.phrase/phases/phase-automation-alignment-20260116/issue_automation_alignment_20260121_changed_props_void.md`: record issue006 for the async worker crash.
- Modify `.phrase/docs/ISSUES.md`: register issue006 for the automation async worker crash.
- Modify `.phrase/phases/phase-automation-alignment-20260116/task_automation_alignment_20260116.md`: add task007 and mark complete.
- Modify `.phrase/docs/CHANGE.md`: add the 2026-01-21 change index entry.

## 2026-01-16

- Add `.phrase/phases/phase-automation-alignment-20260116/spec_automation_alignment_20260116.md`: Define goals/non-goals, user flows, edge cases, and acceptance criteria for Automation 2.0 doc-code alignment.
- Add `.phrase/phases/phase-automation-alignment-20260116/plan_automation_alignment_20260116.md`: Define milestones, scope, priorities, risks, and rollback for the phase.
- Add `.phrase/phases/phase-automation-alignment-20260116/task_automation_alignment_20260116.md`: Track phase tasks (doc-first, no new DSL, no API renames).
- Add `.phrase/phases/phase-automation-alignment-20260116/change_automation_alignment_20260116.md`: Start change log for this phase.
- Modify `doc/AUTOMATION-SYSTEM-GUIDE.md`: Align guide with current implementation (remove condition `:formula`, fix triggers/conditions/actions tables, document event context and `:path` shapes, correct maintenance commands and index examples, switch tag operation examples to `supertag-add-tag`/inline `#tag`, update debug knobs to `supertag-automation-verbose` and `supertag-debug-log-field-events`).
- Modify `supertag-automation-sync.el`: Preserve precise event context for node updates by emitting per-property `:path` events (`(:nodes ID :properties KEY)`), and derive tag add/remove events from node tag diffs so `property-changed` and tag triggers are deterministic and match the guide.
- Modify `doc/AUTOMATION-SYSTEM-GUIDE.md`: Add a minimal manual verification matrix (tag add/remove, property-changed, property-test) to provide a repeatable end-to-end sanity checklist.
- Modify `doc/AUTOMATION-SYSTEM-GUIDE_cn.md`: Align Chinese guide with the English guide and current implementation (remove condition `:formula`, fix triggers/conditions/actions tables and index examples, document event context, correct maintenance/debug knobs, switch tag operation examples to `supertag-add-tag`/inline `#tag`, add the same minimal verification matrix).
- Modify `supertag-services-formula.el`: Fix formula service implementation and add placeholder expansion (`{{...}}`) plus a controlled helper surface (`get-property`, `days-until`) for render-time formula evaluation.
- Modify `supertag-view-table.el`: Compute `:formula` field values at table render time using `supertag-formula-evaluate` (read-only, not persisted).
