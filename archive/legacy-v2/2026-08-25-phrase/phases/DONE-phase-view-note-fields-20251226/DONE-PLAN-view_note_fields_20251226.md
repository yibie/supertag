# plan_view_note_fields_20251226

## Milestones

1. 建立 phase 文档与 issue 记录（spec/plan/task/change + issue）。
2. 修复 node view 的 tag/field 解析路径（relations + node `:tags` 回退）。
3. 补齐 node view 对全局字段事件的刷新逻辑。
4. 统一 inline #tag 解析规则，支持中文/层级分隔符，避免 tag 截断。
5. 完成“缓存不一致是否导致字段/字段值丢失”的结论与验证记录。

## Scope

- Node view / view state 的 tag 解析与字段展示。
- 事件订阅（`store-changed`）对 `:field-values` 的刷新。
- 文档化的风险评估与验证步骤。

## Priorities

- P0: 视图能够稳定展示字段与字段值（核心问题）。
- P1: 自动刷新覆盖全局字段事件。
- P2: 形成明确的数据安全结论与可验证步骤。

## Risks & Dependencies

- 依赖 store 中 relation 与 node `:tags` 的一致性；需要回退机制避免空视图。
- 视图不可在渲染阶段修改 store，避免因缓存未完整加载导致误删。
- 若存在旧数据/迁移不完全，可能需要额外诊断（但不在本阶段做迁移）。
- inline #tag 的解析规则若与 UI 显示/插入不一致，会造成 tag 截断与字段缺失。

## Rollback

- 所有变更限定在 view/service 层；可通过回滚对应文件恢复旧行为。
