# issue043 [ ] Org reindex 契约失真且冷重建受文件顺序影响

## Summary

公开入口仍叫 `supertag-sync-full-rescan`，菜单、setup、Git clone fallback 与文档把它描述为
“重建数据库”。实际代码只能重建 Org 派生 Projection，无法恢复 Schema、field value、Board、
Automation 等 Semantic Facts；冷 Store 中 source 文件先于 target 文件时，Document Link 还会
因 target node 尚不存在而漏建。

## Environment

- org-supertag `main`，ownership-separation phase 的 task008 前
- Emacs 31.0.91 / ERT
- full reindex、setup 首次扫描、Git clone missing/corrupt database fallback

## Reproduction

1. 准备两个 Org 文件：source node 含指向 target node 的 `id:` link，source 文件排序在 target 前。
2. 保留 Semantic Tags、Schema、field values、Board、Automation 与 saved query，清空 Document
   nodes、node-tag relations 与 Document Links。
3. 执行旧的 `M-x supertag-sync-full-rescan`。
4. 另让任一同步目录不可读后再次执行。

Actual：命令名与文档暗示 whole-database rebuild；扫描时重新发现文件而非消费已判定的 snapshot；
单文件异常被吞掉后仍继续 validate/GC；source-before-target 的 link 可漏建；旧 guard 关闭时，
incomplete snapshot 仍允许 destructive cleanup。

## Expected

- 公开命令明确为 `M-x supertag-reindex-org`。
- 一次 reindex 只消费一个 complete snapshot，重建 Document Projection 与 derived indexes。
- snapshot partial/unavailable 时零写入、零删除，并返回可检查的 aborted report。
- 任一文件处理失败时，Store、sync state、deferred state 与 snapshot 回滚。
- Semantic Fact fingerprint 与所有 Org 文件内容不变。
- 旧命令仅作为兼容别名保留。

## Investigation

- `supertag-sync-full-rescan` 先构造 snapshot，随后又调用
  `supertag-scan-sync-directories` 并混入旧 sync-state 文件，出现第二套输入集合。
- 每个文件使用独立 `condition-case` 吞错，随后仍执行 validation 与 garbage collection。
- reference reconciliation 在每个 node upsert 时立即运行；尚未导入的 target 使 relation 跳过，
  批次结束后没有第二阶段 reconciliation，也没有统一重建 backlink caches。
- setup 调用不存在的 `supertag-sync-full-initialize`；Git fallback 与文档把 Projection Reindex
  描述成数据库恢复。

## Root Cause

所谓 full rescan 没有一个真实、单一的 Module contract：snapshot discovery、projection import、
relation join、derived index rebuild、maintenance 与 restore 文案散落在不同调用者，且把
Document Projection 与 Semantic Store 混称为“数据库”。

## Fix

- 新增唯一公开入口 `supertag-reindex-org`，旧 `supertag-sync-full-rescan` 保留为兼容别名。
- complete snapshot 的 `:files` 成为唯一输入；partial/unavailable 直接返回 aborted report。
- 全批次进入一个 Store transaction；所有文件导入后再统一 reconcile node-tag/Document Link，
  重建 relation indexes 与 backlink caches，再 validation/GC。
- 处理失败恢复 sync state、deferred state 与先前 snapshot；Store rollback hook 重建 relation indexes。
- 菜单、setup、Git clone fallback、README 与 sync guide 统一使用 Reindex/Semantic Restore 术语。

## Verification

- 新增回归覆盖冷 Projection 重建、Semantic Fact fingerprint/Org SHA-256 不变、
  incomplete snapshot 零处理、旧别名同 report，以及处理中途失败完整回滚。
- ownership + sync-worker + Git 定向 ERT 58/58 通过。
- relation + field-reference + tag-path + node 定向 ERT 62/62 通过。
- `check-parens`、`git diff --check` 通过；干净临时 clone 全量 ERT 429/429 通过；
  修改文件 byte-compile 成功，仅有既有 warning。

## User Confirmation

- [ ] 在真实 Vault 执行 `M-x supertag-reindex-org`，确认完成提示为 reindex 且 Git 中没有新增
  Org 文件修改。
- [ ] 确认 source 文件排序早于 target 文件的 Document Link 仍能显示 Backlink。
- [ ] 临时让一个同步目录不可访问后执行命令，确认提示 aborted；恢复目录后数据仍完整。

## Resolution Status

- Implementation completed: 2026-08-12
- Implemented By: Codex
- Commit: `fix: define org reindex contract`
- Issue remains open until user confirmation.

## Related

- task008
- `supertag-services-sync.el`
- `supertag-git.el`
- `supertag-setup.el`
- `test/ownership-separation-test.el`
- `test/sync-worker-regression-test.el`
