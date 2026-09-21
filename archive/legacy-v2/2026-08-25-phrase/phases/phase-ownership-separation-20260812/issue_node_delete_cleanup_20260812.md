# issue039 [ ] Node 删除遗留 global field values 与 relation indexes

## Summary

`supertag-node-delete` 直接删除 relation entity，只清理 legacy `:fields`，没有清理
global `:field-values`；直接删除还绕过 relation indexes 与 node reference cache 维护。

## Environment

- org-supertag `main`，ownership-separation phase 的 task004 前
- Emacs 31.0.91 / ERT
- 同时包含 incoming/outgoing relation、legacy field 与 global field value 的 node

## Reproduction

1. 创建 `victim` 与 `peer` node。
2. 创建 `victim → peer` 和 `peer → victim` relation。
3. 为 `victim` 写入 legacy `:fields` 和 global `:field-values`。
4. 调用 `supertag-node-delete "victim"`。

Actual：global field bucket 仍存在；relation entity 虽被删除，from/to index 仍保留旧 ID。
删除过程中若后置 hook 报错，node、relation 和 field 数据不会恢复。

## Expected

- node、两类 per-node field bucket 及其 incoming/outgoing relations 一起删除。
- relation 删除必须通过 relation operation，from/to indexes 与 ref cache 同步更新。
- 任一步失败时，node、relations、fields 和 derived indexes 全部恢复。

## Investigation

- `supertag-node-delete` 自己扫描 `:relations` 并直接调用
  `supertag-store-remove-entity`，绕过 `supertag-relation-delete`。
- 删除路径只处理 `:fields`，没有处理 `:field-values`。
- 函数声明“atomic”，实际没有进入 `supertag-with-transaction`。
- transaction 可以恢复 relation entities，但 relation indexes 不在 Store transaction log 中；
  per-node `:field-values` hash table 也不能经 canonical entity restore 路径恢复。

## Root Cause

node delete 复制了一套 relation 删除逻辑，并把 nested field bucket 与 derived index
误当成普通 Store entity；真实一致性边界没有集中到 relation operation 和 transaction
rollback invariant。

## Fix

- `supertag-node-delete` 在单一 transaction 中调用
  `supertag-relation-delete-for-node`，随后删除 `:fields`、`:field-values` 和 node。
- transaction restore 对 `:fields` 与 `:field-values` 的 per-node hash table 使用同一
  direct restore 分支，避免被 plist normalization 破坏。
- relation module 在 transaction rollback 后复用
  `supertag-index-rebuild-relations` 重建派生索引。

## Verification

- 两条回归测试先分别暴露 global field/index 残留和失败后 node 未恢复。
- 修复后 `./test/run-tests.sh node tx field-ref` 39/39 通过。
- 修改文件 byte-compile 仅有既有 obsolete/docstring/forward declaration warning；
  `git diff --check` 通过。
- 提交态干净临时 clone 全量 ERT 422/422 通过。

## User Confirmation

- [ ] 在真实 Vault 删除一个同时具有 field values 与 incoming/outgoing relations 的测试
  node，确认 Node/Table/Reference 视图没有残留。

## Resolution Status

- Implementation completed: 2026-08-12
- Implemented By: Codex
- Commit: `fix: make node deletion transactional`
- Issue remains open until user confirmation.

## Related

- task004
- `supertag-ops-node.el`
- `supertag-ops-relation.el`
- `supertag-core-transform.el`
- `test/node-ops-test.el`
