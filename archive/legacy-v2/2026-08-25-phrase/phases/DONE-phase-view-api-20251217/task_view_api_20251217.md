# task_view_api_20251217

- task001 [x] 撤回 extractor 插件指南文档与 demo（保留代码能力）；验证：对外文档与示例文件已移除且无遗留死链。
- task002 [x] 固化 UI 无关的内部公开 Data API 清单与边界（tech-refer 补充接口列表）；验证：文档列出 API + 迁移策略。
- task003 [x] 抽出 `supertag-view-api.el`（或等价模块）实现内部公开 Data API（行为不变）；验证：现有 view-table 正常渲染、刷新、跳转。
- task004 [x] 迁移内建视图调用点到 Data API（增量）；验证：关键视图功能回归通过（手动 checklist）。
- task005 [x] 提供 View 插件示例 + 文档（UI 可不依赖 table）；验证：加载示例插件后可在 Emacs 打开新 view 并显示数据。
- task006 [x] 将插件指南升级为完整开发文档（read/write API + 数据约定 + 事务语义）；验证：文档中列出 API 清单与约定，并可用示例插件完成手动验证。
- task007 [x] 恢复 `doc/examples` 的示例文件；验证：`doc/examples/supertag-view-demo-dashboard.el` 存在且可按插件指南步骤加载运行。
- task008 [x] 增加 schema 注册机制（用户可自行注册/覆写）；验证：在用户配置中设置 `supertag-schema-registration-functions`，触发 `supertag-init` 后 `(supertag--get-schema :node)` 反映注册内容，且默认不配置时行为不变。
