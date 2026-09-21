# issue003 [x] view note 无法显示 field / field value（tag 已设置）

## Summary

在 node view（view note）中，即便节点已经设置了 tag，也无法看到该 tag 对应的字段与字段值。表现为 Metadata 区域缺少字段行或字段值为空。

## Environment

- Repo: org-supertag
- Phase: `DONE-phase-view-note-fields-20251226`
- Emacs: （待补充）
- OS: （待补充）
- org-supertag commit: （待补充）

## Repro

1. 确保某个 tag 已在 schema 中定义字段（例如 `#note` 有字段 `use_for`）。
2. 在 Org note 中为某节点添加该 tag（`#note` 或 `#coding/语言`）。
3. 打开 `M-x supertag-view-node`。
4. 观察：Metadata 区域未显示字段/字段值。

## Expected vs Actual

- Expected
  - Node view 中显示该 tag 的字段与字段值（即便为空值也应有占位）。
- Actual
  - 字段列表为空或未出现，导致无法查看/编辑字段值。

## Investigation (Initial)

初步方向（待确认）：

- node view 依赖 `:relations`（node-tag）取 tag；若 relations 缺失/延迟，会导致 tag 列表为空。
- 全局字段模式下，字段值存储于 `:field-values`，但 view 更新监听仅覆盖 `:fields`。
- 旧数据/部分迁移导致 tag 字段信息只存在于 `:tags` 或 legacy `:fields`，视图未做回退。
- inline #tag 解析正则仅支持 ASCII/`-_`，例如 `#coding/语言` 会被截断为 `coding`，导致 tag 与字段关联失配；UI 高亮/插入规则更宽松，放大了不一致。

## Data Loss Risk Assessment

- Node view 渲染路径为只读，不会在渲染阶段删除 tag/field 或修改 store。
- `supertag-save-store` 持久化的是 `supertag--store`，缓存（schema/global field cache）不写入磁盘。
- 因此“视图未显示字段”本身不会触发字段/字段值丢失；只有显式的 ops/migration/cleanup 变更才会改写 store。
- tag 解析不一致会导致字段“不可见”，但不会直接删除底层数据；需要修复解析规则并重扫/修复关联。

## Fix (Implemented)

- 在 view state 与 node view 中新增 tag 回退逻辑：当 relations 缺失时改用 node 的 `:tags`。
- 监听 `:field-values` 变更以触发 node view 刷新。
- 统一 inline #tag 解析规则，支持中文与层级分隔符（例如 `/`）。

## Verification

- 在有 tag 的节点上打开 node view，应显示字段与字段值。
- 修改字段值后，node view 自动刷新并显示新值。
- 构造 relations 缺失场景（或临时禁用 relations），仍能显示字段。
- `(supertag--extract-inline-tags-from-string "#coding/语言")` 返回 `("coding/语言")`。
- 重新同步后，含 `#coding/语言` 的节点能显示对应字段。

## User Confirmation

- [x] 用户确认：阶段完成（含字段展示与解析修复）

## Resolved

- Resolved At: 2025-12-26
- Resolved By: 用户确认阶段完成
- Commit: -

## Related

- Related phase: `DONE-phase-view-note-fields-20251226`
- Related tasks: `task002`, `task004` (task_view_note_fields_20251226)
