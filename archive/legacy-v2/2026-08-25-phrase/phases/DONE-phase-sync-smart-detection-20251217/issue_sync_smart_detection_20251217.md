# issue001 [x] sync-state 不会随 `org-supertag-sync-directories` 变更而更新追踪文件

## Summary

当用户修改 `org-supertag-sync-directories` 后，`sync-state.el` 中被追踪的文件集合没有按新的目录范围更新（旧目录中的文件仍被追踪/新目录中的文件未被纳入或未及时纳入），导致同步范围与用户配置不一致。

## Environment

- Repo: org-supertag
- Phase: `phase-sync-smart-detection-20251217`
- Emacs: （待补充）
- OS: （待补充）
- org-supertag commit: （待补充）

## Repro

1. 设置 `org-supertag-sync-directories` 为目录 A（包含若干 `.org` 文件）
2. 运行一次 `M-x supertag-sync-full-rescan`（或等待 auto-sync 跑完一轮）
3. 检查 `sync-state.el`：应追踪目录 A 下的文件（记录 mtime/size/hash entry）
4. 将 `org-supertag-sync-directories` 改为目录 B（与 A 不同）
5. 再触发一次同步（auto-sync tick 或 `M-x supertag-sync-full-rescan`）
6. 观察：`sync-state.el` 追踪的文件集合未按目录 B 更新（表现为仍包含 A，或缺少 B）。

## Expected vs Actual

- Expected
  - 当 `org-supertag-sync-directories` 变更后：
    - 超出新范围的文件应从 sync-state 中移除（untrack）；
    - 新范围内文件应被纳入并在后续 tick 中逐步建立状态（mtime/size/hash）。
- Actual
  - sync-state 中的追踪文件集合没有随配置变化而更新，导致 scope 不一致。

## Investigation (Initial)

当前同步逻辑涉及几个关键点（待进一步确认具体触发路径）：

- 目录范围判断：`supertag-sync--in-sync-scope-p`
- state 清理（移除 out-of-scope）：`supertag-sync--check-and-sync` 中的 `files-to-remove` 分支
- 新文件发现：`supertag-scan-sync-directories`
- state 写入：`supertag-sync-update-state` / `supertag-sync-save-state`

可能的原因方向（尚未结论）：

- state cleanup 仅在某些 tick/条件下运行，或被 quiet/early return 影响；
- key 归一化不一致（absolute path / directory-files-recursively 返回值格式）导致 `gethash`/`remhash` 未命中；
- `supertag-sync--in-sync-scope-p` 的 prefix 判断在部分路径格式（末尾 `/`）下存在边界问题；
- full-rescan 的实现路径与 auto-sync tick 的 state cleanup 路径不同，导致配置变更未被应用到 state。

## Fix (Planned)

已修复（见 `task006`）。

实现策略：

- 增加 sync-state reconcile：
  - 清理 out-of-scope 或已不存在文件的 state entry（untrack）；
  - 统一 key 为绝对路径（兼容历史遗留的相对路径 key）；
  - 不删除 store 中节点（只调整 state tracking 集合）。
- 在两个入口调用 reconcile：
  - `supertag-sync--check-and-sync`（每个 auto-sync tick 开头）
  - `supertag-sync-full-rescan`（full-rescan 开头）

## Verification

修复后应满足：

1. 目录从 A 切换到 B 后，下一次同步（tick 或 full-rescan）会使 state 集合与 B 对齐；
2. A 下文件不再出现在 state 中（untrack）；
3. B 下文件会被纳入 state，并能在后续 tick 中更新 mtime/size/hash；
4. 不引发误删节点（untrack 只影响 state，不删除 store 中节点）。

建议验证步骤（最小）：

1. `org-supertag-sync-directories` = A，跑一次 `M-x supertag-sync-full-rescan`；
2. 改为 B，再跑一次 `M-x supertag-sync-full-rescan`；
3. 打开 `sync-state.el` 检查：
   - A 下文件条目已被移除（untrack）；
   - B 下文件条目存在或在随后的 tick/rescan 中逐步写入。

## User Confirmation

- [x] 用户确认：修复后目录切换行为符合预期（观察到 sync-state 不再包含多余记录）

## Resolved

- Resolved At: 2025-12-17
- Resolved By: task006 (reconcile sync-state)
- Commit: -

## Related

- Related phase: `phase-sync-smart-detection-20251217`
- Related tasks: `task006` (task_sync_smart_detection_20251217)
