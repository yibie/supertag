# issue042 [ ] Reindex 导入 Document Link 时向目标 Org 写入 reciprocal link

## Summary

scanner 解析 source Org 中的 forward `id:` link 后，复用了交互式 reference 写命令。
该命令除创建 relation 外，还会向 target Org 插入 reciprocal link 并保存文件。因此一个本应
只读 Org 的 reindex 会静默修改用户文档。

## Environment

- org-supertag `main`，ownership-separation phase 的 task007 前
- Emacs 31.0.91 / ERT
- file sync、point sync 与 full reindex 共用的 reference reconciliation path

## Reproduction

1. Source node 正文包含指向 target node 的一个真实 forward Document Link。
2. Target Org 中没有指向 source 的 reciprocal link。
3. 让 source node 进入同步 reconciliation，再执行单文件 sync 或 reindex。

Actual：scanner 创建 `:reference` relation 后，同时修改并保存 target Org，插入 reciprocal
link；relation 没有明确的 kind/origin。清理路径还会删除 source 的所有 `:reference`，
包括并非由 Org link 拥有的 reference。

## Expected

- reindex 只读取 Org，并写入 Document Projection。
- source 与 target 的文件内容和 hash 均不变。
- Document Link relation 明确为 `:kind :document-link`、`:origin :org`。
- 删除 Org occurrence 时只清理对应 Document Link projection，不影响 field-reference 或
  Semantic Edge。

## Investigation

- `supertag--process-node-references` 调用 `supertag-relation-add-reference`。
- `supertag-relation-add-reference` 同时创建 Store relation、定位 target Org、插入 reciprocal
  link、保存文件，并在文件失败时补偿删除 relation。
- `supertag--cleanup-orphaned-references` 只按 `:type :reference` 过滤，无法识别事实 owner。

## Root Cause

Document Projector 与交互式 reference command 共用同一个带 Org 写副作用的入口；同时
Document Link、field-reference 与 legacy reference 没有 ownership discriminator。

## Fix

- 新增无 Org 副作用的 `supertag-relation-project-document-link`，只通过 relation operation
  写 Projection，并记录 kind/origin。
- projector 只补齐已部分分类为 Document Link/Org 的记录；完全无 owner 的 legacy relation
  保持不变，遇到明确冲突的 owner 时 fail closed，不覆盖数据。
- orphan cleanup 只删除明确的 Org-owned Document Link。
- task007 先让 scanner 使用纯 Projection Interface；随后 task009 将
  `supertag-relation-add-reference` 也改为 Store-only，并让交互命令只写 source forward link。

## Verification

- 端到端 reindex 回归证明两个 fixture Org 文件的 SHA-256 均不变，relation 的 from/to
  indexes、kind/origin 与 created counter 一致，部分分类的 legacy relation 可原地补齐，
  完全无 owner 的记录保持不变且不重复计数。
- cleanup 回归证明移除 Org link 时 field-reference relation 仍存在。
- ownership 6/6；reference/field-reference/sync-worker/node 定向回归 39/39。
- `check-parens`、`git diff --check` 通过；修改文件 byte-compile 成功，仅有既有 warning；
  干净临时 clone 全量 ERT 427/427 通过。

## User Confirmation

- [ ] 在真实 Vault 选择只有一个 forward link、target 无 reciprocal link 的节点，执行 reindex，
  确认 Git/文件状态没有新增 Org 修改。
- [ ] 确认现有 link 查询与 Backlink 展示仍可找到 source/target。
- [ ] 删除 source 的 forward link 后重新同步，确认 Document Link 查询消失，字段引用仍正常。

## Resolution Status

- Implementation completed: 2026-08-12
- Implemented By: Codex
- Commit: `fix: project document links without org writes`
- Issue remains open until user confirmation.

## Related

- task007
- `supertag-ops-relation.el`
- `supertag-services-sync.el`
- `test/ownership-separation-test.el`
