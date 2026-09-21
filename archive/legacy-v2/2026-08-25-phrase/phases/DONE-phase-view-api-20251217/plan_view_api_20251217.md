# plan_view_api_20251217

## Milestones

1. 明确“UI 无关”的内部公开 Data API 边界与命名（tech-refer 定稿）。
2. 抽出独立模块（如 `supertag-view-api.el`）实现 Data API；view-table 仅作为消费者（行为不变）。
3. 将内建视图/调用点逐步迁移到新 Data API（含 view-table 自身）。
4. 提供 View 插件最小示例 + 文档 + 手动验证 checklist（示例 UI 不要求使用 table）。
5. 撤回 extractor 插件指南（仅撤文档与示例，保留代码能力）。
6. 增加 schema 注册机制（用户可注册/覆写 schema，并在 `supertag-init` 生效）。

## Scope

- 仅覆盖 view-table 的数据获取、行构建、列值计算这类接口整理。
- 不引入“自动迁移”的 DB schema 扩展机制（只提供注册/覆写入口）。

## Priorities

- P0：API 边界清晰、可迁移、不破坏现有视图行为。
- P1：提供一个真实的 View 插件示例（可视化可验证）。

## Risks & Dependencies

- 依赖：现有 store/ops/notify 的数据一致性与订阅机制。
- 风险：view-table 代码体量大，重构需增量推进，避免一次性大改。

## Rollback

- API wrapper 初期只新增不替换：若出现问题，可回退到直接调用旧 `--` 逻辑。
