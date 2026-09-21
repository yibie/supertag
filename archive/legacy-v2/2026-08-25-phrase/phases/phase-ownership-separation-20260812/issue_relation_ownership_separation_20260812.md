# issue044 [ ] Reference relation 混合三个 owner，字段修改会误删 Document Link / Semantic Edge

## Summary

`:relations` 中的 `:reference` 同时表示 Org Document Link、node-reference field projection 与
数据库 Semantic Edge。字段写入只按 endpoints/type 查找和删除，因此清空一个字段可能删除
同一节点对之间的 Document Link 或 Semantic Edge；反向同步还会让 relation 覆盖 authoritative
field value。

## Environment

- org-supertag `main`，ownership-separation phase 的 task015 前
- Emacs 31.0.91 / ERT
- global field model 已由 task014 成为唯一生产读写路径

## Reproduction

1. Source node 通过 Org link 指向 Target node。
2. Source 的 `:node-reference` field 也指向同一个 Target。
3. 两个节点之间另有一个 custom/Notion relation。
4. 清空该 field，或删除 reference projection 后执行重建。

Actual：三类事实共享 `(from, to, :reference)` identity；字段同步删除全部匹配 relation，
relation getter 又会把 relation 集合反写到 field value。Automation/rollup 的无类型遍历也会
把 Document Projection 当成 Semantic Edge。

## Expected

- Document Link：`:kind :document-link`、`:origin :org`，由 Org `:ref-to` 重建。
- Field Reference：`:kind :field-reference`、`:origin :field-value`、稳定 `:field-id`，由 global
  field value 重建；删除 projection 不改变 field value。
- Semantic Edge：`:kind :semantic-edge`、`:origin :semantic`，custom/Notion create 默认写入。
- 三类 relation 可在同一节点对之间共存；任何一类的 reconcile 不修改另外两类。
- Automation、rollup 与 virtual relation column 只遍历 Semantic Edge。

## Investigation

- `supertag-field--sync-node-references` 删除 `supertag-relation-find-between ... :reference` 的
  全部结果，没有 field owner discriminator。
- `supertag-reference--update-field-cache` 从 relation 回写 global field value，主权方向颠倒。
- deterministic relation ID 只包含 `from/to/type`，无法同时表达两种 `:reference` projection。
- Table 在调用 field service 前又自行执行一次 relation diff；Automation 和 rollup 默认遍历
  所有 relation。

## Root Cause

物理 `:relations` collection 被误当成事实 owner；relation identity、写入路径和消费者只识别
`:type`，没有把 Document Fact、Semantic Fact 与 Projection 分开。

## Fix

- relation operation 统一写入/验证 `:kind` 与 `:origin`；reference identity 加入 kind，Field
  Reference 再加入 field-id，其他 relation 保留原 deterministic identity。
- field service 先原子写入 global field value，再只 reconcile 对应 field-id 的 projection；
  删除 relation 永不回写 field。
- full projection reconciliation 同时从 Org node facts 重建 Document Link、从 global values
  重建 Field Reference，并保留 Semantic Edge。
- custom/Notion relation 默认成为 Semantic Edge；legacy unowned `:reference` 保留为
  `:legacy-reference`，不猜 owner、不进入 Automation semantic traversal。
- 删除 Table 的第二套 reference diff；Query 增加可选 kind filter；Automation、relation rollup
  与 virtual column 显式查询 Semantic Edge。

## Verification

- 红测先因 relation query 不支持 kind、同节点对无法保存三类事实而失败。
- 回归覆盖删除/重建两个 Projection 后 Semantic Edge 与 authoritative field value 不变，以及
  field value 清空后只删除对应 Field Reference。
- Notion relation 回归确认自动记录 `:semantic-edge/:semantic`。
- 定向 relation/field/query/view/automation consumer ERT 84/84，通过只含 task015 patch 的干净
  临时树完整 ERT 466/466；7 个修改生产文件 byte compile、`check-parens` 与
  `git diff --check` 通过。

## User Confirmation

- [ ] 在真实 Vault 选择同时具有 Org link 与 node-reference field 的节点，清空字段后确认 Org
  link/Backlink 仍在。
- [ ] 执行 `M-x supertag-reindex-org`，确认 Field Reference 与 Document Link 收敛，custom/Notion
  relation 未被删除或计入字段引用。
- [ ] 确认现有 Automation/rollup 只沿显式 Semantic Edge 传播。

## Resolution Status

- Implementation completed: 2026-08-12
- Implemented By: Codex
- Commit: `fix: separate relation ownership domains`
- Issue remains open until user confirmation.

## Related

- task015
- `supertag-ops-relation.el`
- `supertag-ops-field.el`
- `supertag-services-sync.el`
- `test/test-field-node-reference.el`
