# change_view_api_20251217

> 倒序记录，每个完成的 task 至少一条；包含日期、文件/路径、Add|Modify|Delete、受影响函数、行为/风险说明。

- 2025-12-17 | Fix | 修复 `supertag-core-schema.el` 语法错误导致无法加载
  - Task: task008
  - Files: `supertag-core-schema.el`
  - Change: 修复多余的右括号导致的 `invalid-read-syntax \")\"`（加载/`eval-buffer` 时报错）。

- 2025-12-17 | Fix | 允许注册全新 schema 类型（避免 `Unknown schema type`）
  - Task: task008
  - Files: `supertag-core-schema.el`
  - Change: `supertag-schema-register` 在 `REPLACE` 为非 nil 时不再强制读取内建 schema，允许 `supertag-register-entity-type` 注册全新类型（如 `:my-entity`）。

- 2025-12-17 | Fix | 恢复 `doc/examples` 的 View 插件示例文件
  - Task: task007
  - Files: `doc/examples/supertag-view-demo-dashboard.el`
  - Reason: `doc/examples` 目录存在但示例文件丢失，导致插件指南中的验证步骤无法执行。
  - Verify: 按 `doc/ORG-SUPERTAG-PLUGIN-GUIDE.md` 的步骤 `(require 'supertag-view-demo-dashboard)` 并运行 `M-x supertag-view-demo-dashboard-open`。

- 2025-12-17 | Modify | schema 注册机制（用户可自行注册/覆写）
  - Task: task008
  - Files: `supertag-core-schema.el`, `org-supertag.el`, `doc/ORG-SUPERTAG-PLUGIN-GUIDE.md`, `doc/ORG-SUPERTAG-PLUGIN-GUIDE_cn.md`
  - Change: 增加 schema registry 与初始化时的注册入口（允许用户在启动时注入自定义 schema/实体类型），并补充插件开发文档的配置示例。
  - Risk: schema 变更可能影响数据校验/转换；默认不启用任何注册函数，保持现有行为。

- 2025-12-17 | Delete | extractor 插件指南（英文/中文）与 demo（`doc/` + `doc/examples/`）
  - Task: task001
  - Reason: extractor 能力保留为内部扩展点，但不再作为 org-supertag “插件体系”主路径对外呈现（插件主路径转向 View 插件）。
  - Risk: 用户侧参考文档减少；后续将用 View 插件指南替代。

- 2025-12-17 | Modify | `.phrase/phases/phase-view-api-20251217/spec_view_api_20251217.md`, `.phrase/phases/phase-view-api-20251217/tech-refer_view_api_20251217.md`, `.phrase/phases/phase-view-api-20251217/plan_view_api_20251217.md`, `.phrase/phases/phase-view-api-20251217/task_view_api_20251217.md`
  - Task: task002 (scope clarification)
  - Change: 将“view-table 作为唯一 UI 入口”澄清为“抽离 UI 无关 Data API”；插件可实现与 table 无关的任意 UI，但必须统一经由 Data API 取数。

- 2025-12-17 | Modify | `.phrase/phases/phase-view-api-20251217/tech-refer_view_api_20251217.md`
  - Task: task002
  - Change: 增补 “Internal Public Data API (Draft)”（Query Spec、entity fetch、tag/node helpers、field access、subscription）与迁移策略，明确 Data API 的职责边界（UI 无关、读为主、写入走 ops）。

- 2025-12-17 | Add | `supertag-view-api.el`
  - Task: task003
  - Change: 新增 UI 无关的 View Data API（query -> ids、entity fetch、tag helpers、field access、subscribe wrapper），作为 view-table 与未来自定义 UI 视图的统一取数入口。
  - Verify: 手动打开 `M-x supertag-view-table`（任意 tag），确认可渲染/刷新；并在 `*scratch*` 评估 `(supertag-view-api-list-tags)` 返回 tag 名称列表。

- 2025-12-17 | Modify | `supertag-view-table.el`
  - Task: task003
  - Touch: `supertag-view-table--get-entities`, `supertag-view-table--get-available-tags`, `supertag-tag-get-id-by-name`, `supertag-view-table--get-entity-data`, `supertag-view-table--get-cell-value`
  - Change: 将 view-table 的数据访问（IDs/标签列表/entity fetch/field read）迁移为调用 `supertag-view-api-*`，避免 UI 层散落直接读 store/scan/field 的实现细节。
  - Risk: 若第三方代码直接依赖旧的 `--` 细节，仍可工作（本次只替换内部实现，不改变对外命令）。

- 2025-12-17 | Modify | `supertag-view-api.el`
  - Task: task004
  - Change: 补充 `supertag-view-api-get-collection`（只读）与 type/collection 的别名映射，支持 schema/关系等 UI 读取路径统一走 Data API。

- 2025-12-17 | Modify | `supertag-services-ui.el`
  - Task: task004
  - Touch: `supertag-goto-node`, `supertag-view-build-node-state`
  - Change: shared node state builder 与跳转逻辑改为通过 `supertag-view-api` 读取 node/relations/field 值，避免 UI/service 直接依赖 store 实现细节。

- 2025-12-17 | Modify | `supertag-view-node.el`
  - Task: task004
  - Touch: `supertag-view-node--subscribe-to-events`, `supertag-view-node--get-referenced-by`, `supertag-view-node--insert-node-link-line`
  - Change: node view 的订阅与数据读取改为调用 `supertag-view-api-*`（订阅/relations/node fetch），保持 UI 与数据层边界一致。

- 2025-12-17 | Modify | `supertag-view-kanban.el`
  - Task: task004
  - Touch: `supertag-view-kanban--get-all-tags`, `supertag-view-kanban--subscribe-updates`
  - Change: kanban 的 tag 列表读取与订阅改为走 `supertag-view-api-*`。

- 2025-12-17 | Modify | `supertag-view-schema.el`
  - Task: task004
  - Touch: `supertag-schema--get-own-fields`, `supertag-schema--bind-existing-field-at-point`, `supertag-schema--debug-tag-data`
  - Change: schema view 对 global field 相关 collection 的读取改为走 `supertag-view-api-get-collection`（只读）。

- 2025-12-17 | Modify | `supertag-view-helper.el`
  - Task: task004
  - Touch: `supertag-view-helper-format-field-value`, `supertag-view-helper-find-node-location`
  - Change: node reference 的 title 解析与 node 定位读取改为使用 `supertag-view-api-get-entity`。

- 2025-12-17 | Modify | `.phrase/phases/phase-view-api-20251217/tech-refer_view_api_20251217.md`
  - Task: task004
  - Change: 更新 Data API 清单，补充 `supertag-view-api-get-collection` 与别名映射说明。

- 2025-12-17 | Add | `doc/ORG-SUPERTAG-PLUGIN-GUIDE.md`, `doc/ORG-SUPERTAG-PLUGIN-GUIDE_cn.md`, `doc/examples/supertag-view-demo-dashboard.el`
  - Task: task005
  - Change: 新增“插件主路径=View 插件（UI 无关 Data API）”的对外指南与一个完整可运行示例（自定义 dashboard UI，不依赖 table）。
  - Verify:
    - `(add-to-list 'load-path \"/path/to/org-supertag/doc/examples/\")`
    - `(require 'supertag-view-demo-dashboard)`
    - `M-x supertag-view-demo-dashboard-open`（选择 tag 后应出现 `*Supertag Demo Dashboard*`）
    - 修改任意节点后观察 dashboard 自动刷新，或按 `g` 手动刷新。

- 2025-12-17 | Modify | `.phrase/phases/phase-extractor-plugins-20251216/change_extractor_plugins_20251216.md`, `.phrase/phases/phase-extractor-plugins-20251216/task_extractor_plugins_20251216.md`
  - Task: task001 (cleanup follow-up)
  - Change: 移除对已撤回 extractor 插件指南文件名的引用，避免历史文档指向不存在的路径；明确 extractor 仅保留为内部能力，插件主路径改为 View 插件指南。

- 2025-12-17 | Modify | `doc/ORG-SUPERTAG-PLUGIN-GUIDE.md`, `doc/ORG-SUPERTAG-PLUGIN-GUIDE_cn.md`
  - Task: task006
  - Change: 将插件指南升级为完整开发文档：补充数据模型/约定、read API 清单与数据约定、write ops API 清单与数据约定、以及 `supertag-with-transaction` 的实际语义说明。
  - Verify: 参考 `doc/examples/supertag-view-demo-dashboard.el` 的手动验证步骤（打开 dashboard、RET 跳转、更新后刷新）。
