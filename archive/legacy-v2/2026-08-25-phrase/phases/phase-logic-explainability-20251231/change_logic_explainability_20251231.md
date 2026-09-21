# change_logic_explainability_20251231

## 2025-12-31

- Modify `supertag-automation-sync.el`: Add `supertag-automation-sync-use-commit-hooks` (default nil) and remove default commit-hook registration to avoid duplicate automation triggers.
- Modify `supertag-automation.el`: Add `supertag-automation-verbose` + `supertag-automation--log`; gate routine messages (rule execution traces, SKIP/no-op notices, scheduler info); mark internal modifications before saving and save quietly in tag actions.
- Modify `supertag-service-org.el`: Avoid no-op TODO updates; only sync/save when buffer actually changed; mark internal modification before save and save quietly.
- Modify `supertag-services-sync.el`: Add `supertag-sync-verbose` + `supertag-sync--log`; stop printing internal/external save decisions by default.
- Modify `doc/ONTOLOGY-ARCHITECTURE_cn.md`: Add “初中生 3 分钟版本” and a dedicated “解释/诊断（为什么没跑）” entry under logic-layer landing.
- Modify `supertag-view-table.el` + `CHANGELOG.org`: Restore `C-o` reference jump support (paired with `o` for current row jump).
- Modify `supertag-service-org.el` + `supertag-automation.el`: Revert default TODO update behavior per user decision (automation may create TODO keywords via `org-todo`).
- Modify `supertag-automation.el` + `supertag-automation-sync.el`: Enforce `:trigger` matching before condition evaluation/execution; unknown triggers now fail closed to prevent accidental mass updates.
- Modify `supertag-test.el` + `doc/AUTOMATION-SYSTEM-GUIDE_cn.md`: Dry-run surfaces trigger typos as trigger-miss; docs warn about trigger spelling.
