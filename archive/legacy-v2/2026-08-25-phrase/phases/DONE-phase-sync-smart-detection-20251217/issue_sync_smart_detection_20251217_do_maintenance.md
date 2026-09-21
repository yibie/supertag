# issue002 [x] `supertag-sync--check-and-sync` 运行时报错 `(void-variable do-maintenance)`

## Summary

在运行自动同步或手动触发同步时，Emacs 报错：

- `(void-variable do-maintenance)`

导致同步流程中断。

## Environment

- Repo: org-supertag
- Phase: `phase-sync-smart-detection-20251217`
- Emacs: （待补充）
- OS: （待补充）
- org-supertag commit: （待补充）

## Repro

1. 配置 `org-supertag-sync-directories`（确保 auto-sync 会运行）
2. 触发一次 `supertag-sync--check-and-sync`（等待 auto-sync tick 或手动调用）
3. 观察报错 `(void-variable do-maintenance)`

## Expected vs Actual

- Expected：sync 正常运行，maintenance（validate/GC）按配置的 tick 频率执行
- Actual：`do-maintenance` 变量未绑定导致异常

## Root Cause

`do-maintenance` 在一个 `let*` 中被绑定，但该 `let*` 提前结束，
后续的事务处理与 GC 分支仍引用 `do-maintenance`，从而变成未绑定的自由变量。

## Fix

调整 `supertag-sync--check-and-sync` 的作用域：

- 将 `supertag-with-transaction` 以及 maintenance GC 分支放入同一个 `let*` 作用域内，
  确保 `do-maintenance` 在整个同步执行路径上都可见且一致。

## Verification

1. 启动 auto-sync 或手动触发同步，不再出现 `(void-variable do-maintenance)`；
2. `supertag-sync-maintenance-every-n-ticks` 为 1/5/10 等时，maintenance 的执行频率符合预期；
3. 在无变更场景下，sync 仍可正常结束并输出/静默（按 `supertag-sync-quiet-when-idle`）。

## User Confirmation

- [x] 用户确认：同步不再报错且 maintenance 行为符合预期

## Resolved

- Resolved At: 2025-12-17
- Resolved By: fix in `supertag-services-sync.el` (scope of `do-maintenance`)
- Commit: -

## Related

- Related phase: `phase-sync-smart-detection-20251217`
