# issue010 [x] persistence 显式 DB 候选被 snapshot 重复项降级

## Summary

`supertag-load-store FILE` 在 FILE 同时符合 snapshot 命名时，会因候选去重保留最后一次出现而把显式候选移到 configured/default/legacy 之后，可能静默加载错误数据库。

## Environment

- Repo: org-supertag
- Phase: `phase-sync-integrity-20251226`
- Branch: `main`
- Found at: `a58d4c8`
- Date: 2026-07-11

## Repro

1. 创建 configured DB，节点为 `CONFIGURED`。
2. 创建显式 DB `supertag-db-9999-99-99.el`，节点为 `EXPLICIT`。
3. 调用 `supertag-load-store` 并传入显式 DB。
4. 实际加载 configured DB；坏显式 DB 也不会出现在 `:load-failures`。

## Expected vs Actual

- Expected: 显式 FILE 始终是第一候选；失败时记录原因后再 fallback。
- Actual: `cl-delete-duplicates` 默认保留最后一个重复项，snapshot 重复项把显式 FILE 降到末尾。

## Investigation

- 原始候选：`explicit → configured → default → legacy → snapshot`。
- 当 explicit 与 snapshot 相同、configured 与 default 相同时，当前去重结果为 `default → legacy → snapshot`。
- loader 在第一个成功候选后停止，因此显式文件不会被尝试。
- 根因早于 PR #176/#177/#178；线上 merge 没有引入该行为。

## Fix

- 在 `cl-delete-duplicates` 增加 `:from-end t`，保留第一次出现的候选。
- 增加有效显式 DB 必须覆盖 configured DB 的直接回归测试。

## Verification

- [x] 坏显式 DB 记录到 `:load-failures` 并 fallback 到 configured DB。
- [x] 有效显式 DB 优先加载，不读取 configured DB。
- [x] persistence 5/5 ERT 通过。
- [x] concept mention 4/4、add-reference 4/4、inline-tag、denote-reference 与主包 batch load 通过。

## User Confirmation

- [x] 自动化回归直接验证显式 DB 加载路径与 fallback 行为。

## Resolved

- Resolved At: 2026-07-11
- Resolved By: Codex diagnosis and regression verification
- Commit: `7aa7d6b`

## Related

- Task: `task010`
- Existing test: `supertag-persistence-load-store-failover-keeps-working`
