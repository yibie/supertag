# issue041 [ ] Reindex 把未知 Org Tag Occurrence 静默注册为 Semantic Tag

## Summary

普通 Org 文本中出现新的 `#token` 后，scanner 会调用 Tag creation path。一次 reindex
因此同时改变 Document Projection、Semantic Tag collection 与 node-tag relation，把文本
出现误当成 schema-bearing Semantic Tag 的注册行为。

## Environment

- org-supertag `main`，ownership-separation phase 的 task006 前
- Emacs 31.0.91 / ERT
- 普通 Org file sync、point sync 与 full reindex 共用的 projector path

## Reproduction

1. Store 中已有 Semantic Tag `reference`，但没有 `emerging`。
2. 在现有 node 标题或正文写入 `#emerging`。
3. 运行单文件同步或 full reindex。

Actual：Store 自动新增 `emerging` Tag entity 和 `:node-tag` relation；Semantic Fact
fingerprint 改变，用户没有执行任何 semantic creation command。

## Expected

- extractor 只报告 Org Tag Occurrence。
- projector 只读解析已存在 Semantic Tag；未知 token 进入 unresolved projection。
- 未知 token 仍可 query/completion，但只有显式 `[New]` 或 migration 才创建 Semantic Tag。
- reindex 前后 Semantic Tag/schema fingerprint 不变。

## Investigation

- `supertag-extractor--tags` 把原始 token 放进含义模糊的 node `:tags`。
- `supertag-db-add-with-hash` 随后把该字段当作 Semantic Tag IDs。
- `supertag--process-node-tags` 调用 `supertag--create-tag-entities`，使 projector 获得
  Semantic Tag writer 权限。
- completion 只读取 Semantic Tags，若直接停止创建则未知 occurrence 会从候选中消失。

## Root Cause

Tag Occurrence 与 Semantic Tag 共用 `:tags` 字段，解析、注册和 membership reconciliation
没有边界。scanner 因此无法表达“文本中存在，但语义上尚未注册”。

## Fix

- extractor 输出 `:tag-occurrences`。
- projector 只读解析现有 Tag ID / `:extends` display path，分别写 resolved `:tags` 与
  `:unresolved-tags`，并只为 resolved IDs reconcile node-tag relation。
- query 合并 resolved IDs 与 occurrence keys；completion 增加 `[Unresolved]` 候选，同时
  保留独立 `[New]` action。
- 一次性 bulk migration 继续显式从 occurrences 创建 Tags，不改变 migration 的授权语义。

## Verification

- ownership 回归证明新增 `#emerging` 后 node projection 完整、query 可见、无 Tag entity、
  无 node-tag relation且 Semantic Fact fingerprint 不变。
- completion 回归证明 `[Unresolved]` 与 `[New]` 同时存在，前者不被当作 exact Semantic Tag。
- ownership 4/4、extractor 22/22、tag-path 40/40；sync-worker/query/view-stream/
  smart-key/tag-merge 定向回归全部通过。
- `check-parens`、`git diff --check` 通过；干净临时 clone 全量 ERT 427/427 通过。

## User Confirmation

- [ ] 在真实 Vault 新增一个从未注册的 `#token` 后 reindex，确认 Schema/Tag 列表不自动新增实体。
- [ ] 在普通 Org buffer 输入该 token，确认补全同时显示 `[Unresolved]` 与独立 `[New]`。
- [ ] 搜索该 token，确认对应 node 仍可找到。

## Resolution Status

- Implementation completed: 2026-08-12
- Implemented By: Codex
- Commit: `fix: separate tag occurrences from semantic tags`
- Issue remains open until user confirmation.

## Related

- task006
- `supertag-services-sync.el`
- `supertag-ops-tag.el`
- `supertag-core-scan.el`
- `supertag-ui-completion.el`
- `test/ownership-separation-test.el`
- `test/tag-path-test.el`
