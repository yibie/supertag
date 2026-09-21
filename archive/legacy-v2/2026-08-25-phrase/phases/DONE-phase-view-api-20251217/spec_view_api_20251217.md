# spec_view_api_20251217

## Summary

本阶段建立 org-supertag 的 **View 插件体系**方向：复用 `supertag-view-table.el` 目前已有的“数据库/Store 沟通能力”（数据层逻辑），将其整理为**内部公开 API**（与 UI 无关），让所有视图（内建/第三方）都通过同一套 API 与数据库/Store 沟通，并允许插件实现 *完全不同于 table* 的 UI。

> 说明：repo 里已存在 extractor 能力（用于 per-headline enrich），但它不再被视为 org-supertag 的“插件体系主路径”。本阶段将撤回相关 user-facing 文档（代码能力保留）。

## Goals

- 将 view-table 当前的数据层能力抽象为“内部公开 API”（UI 无关）：
  - 为内建视图提供稳定调用面；
  - 为未来 View 插件提供稳定契约；
  - DB 仍为唯一真相（不引入“绕过 DB 的读取层”）。
- 明确 View 插件边界：插件主要扩展 *视图*（query/columns/actions）。
- 提供最小 **schema 注册机制**：允许用户在初始化时注册/覆写 schema（用于自定义实体类型或扩展字段），但不引入自动迁移与复杂 normalize 管线。

## Non-goals

- 本阶段不做“schema 扩展插件 + 自动迁移”（类似 Vulpea 的“插件扩表+迁移”）。
- 本阶段不承诺一个完整的 UI 组件库；插件可自由实现 UI（table/卡片/仪表盘/graph 等），但数据必须经由内部公开 API 获取。
- 不重新设计同步/索引策略（除非与 view API 强耦合）。

## User Flows

### 内建视图（含 view-table）

1. 用户执行 `M-x supertag-view-table`（或其它内建视图命令）。
2. 视图通过内部公开 API 拉取数据（IDs/rows/fields）。
3. UI 渲染为表格/卡片等；支持刷新、跳转、过滤、排序等交互。

### 第三方 View 插件（UI 可完全不同）

1. 用户安装并加载插件（`require` 或 package 管理）。
2. 插件调用内部公开 API 获取数据，并渲染自己的 UI（可能完全不使用 table）。
3. 用户通过插件命令打开该视图（或从 view selector 选择）。

## Edge Cases

- 数据源返回缺失字段：视图应可降级显示，不应破坏整个 view-table。
- 大数据量：必须允许分页/限制（或至少具备增量渲染/可配置限制）。
- DB/Store 不可用：给出明确错误信息与恢复路径。

## Acceptance Criteria

- view-table 数据层 API 形成一组明确的内部公开函数（带 docstring）。
- 内建视图调用点统一走该 API（不再散落直接访问 store/ops 的路径）。
- 提供最小的 View 插件注册/打开示例（文档与手动验证步骤）。
- 提供 schema 注册入口（用户可在配置中注册），并在 `supertag-init` 期间生效（带最小手动验证步骤）。
