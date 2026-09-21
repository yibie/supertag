# spec_view_note_fields_20251226

## Summary

修复 view note（node view）在已设置 tag 的情况下仍不显示字段与字段值的问题，并明确缓存/持久化是否存在“状态不一致导致字段数据丢失”的风险。

## Goals & Non-goals

### Goals
- Node View 在有 tag 的情况下稳定显示字段与字段值（包含全局字段模型）。
- 当 node-tag relations 缺失或延迟时，视图可回退到 node 的 `:tags` 列表。
- 全局字段（`:field-values`）变更时，Node View 能自动刷新。
- 给出清晰的“缓存不一致是否会导致字段/字段值丢失”的结论与依据。

### Non-goals
- 不重构全局字段模型或同步系统。
- 不改变字段持久化结构（`:fields`/`:field-values`）或做大规模迁移。
- 不做 UI 版式重设计。

## User Flows

1. 用户为一个 note 添加 tag（例如 `#note` 或其它有字段的 tag）。
2. 打开 `M-x supertag-view-node`。
3. 视图显示该 tag 相关的字段与当前值；空值显示为默认/空值提示。
4. 在 table/node view 中修改字段值后，node view 自动刷新并显示新值。

## Edge Cases

- 旧数据或部分同步导致 node-tag relations 缺失：改用 node 的 `:tags` 作为回退来源。
- 某 tag 的字段定义缺失：仍显示 tag（或保持空状态提示），不抛错。
- 全局字段模型启用时（`supertag-use-global-fields`）的字段值事件路径为 `:field-values`。
- inline #tag 含中文或分隔符（如 `/`、`+`）时仍能被解析，避免 tag 被截断导致字段缺失。

## Acceptance Criteria

- 已设置 tag 的 node，在 node view 中能看到字段与字段值。
- 当 relations 缺失但 node `:tags` 存在时，node view 仍能显示字段。
- 修改全局字段值后，node view 自动刷新（无需手动 `g`）。
- Issue 文档中明确“缓存不一致是否会导致字段/字段值丢失”的结论与证据。
- `#coding/语言` 这类 tag 在解析后与存储一致，node view 能展示对应字段。
