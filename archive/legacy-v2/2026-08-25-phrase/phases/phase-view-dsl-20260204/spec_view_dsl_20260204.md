# spec_view_dsl_20260204

## Summary

本阶段目标：让 View DSL 成为自定义视图的主入口，支持“可嵌套 + 可绑定”的最小能力集，面向有动手能力的 Emacs 用户。

核心约束：
- 仅支持函数绑定（`lambda (ctx) ...`），不引入表达式字符串 DSL。
- 不做复杂样式体系；不做热更新/自动刷新。
- 提供统一的手动刷新命令。

## Goals

- DSL 作为主入口：用 20 行左右配置即可生成可用的嵌套视图。
- 支持嵌套：`widgets` 可递归包含 `:children`。
- 支持函数绑定：组件属性可由 `(lambda (ctx) ...)` 提供，读取 view context 中的数据（tag/nodes/virtual-columns/global fields）。
- 提供基础组件 + 容器组件的最小集合。
- 组件视觉风格与现有视图对齐：`card/panel` 采用 kanban 边框风格，`kv/toolbar/badge` 采用 table 风格对齐。
- 提供统一的手动刷新入口，确保数据变更后可重新渲染。

## Non-goals

- 不实现复杂样式系统（颜色/主题/布局引擎由用户自行扩展）。
- 不实现热更新/自动刷新。
- 不提供可视化编辑器或 GUI 向导。
- 不引入表达式/模板语言（仅函数绑定）。
- 不重构 view-table 或替换既有视图体系（尽量保持兼容）。

## User Flows

### Flow A：用户用 DSL 自定义视图
1. 用户写一段 DSL 配置（plist）并加载。
2. 通过 Schema 或命令选择该 view。
3. 视图渲染成功，显示嵌套结构。

### Flow B：用户绑定数据并手动刷新
1. 用户在 DSL 里为组件属性提供 `(lambda (ctx) ...)` 绑定。
2. 数据源更新（tag/nodes/fields/virtual columns）。
3. 用户执行统一刷新命令，视图重新渲染并反映新数据。

### Flow C：用户组合容器组件
1. 用户在 DSL 中使用容器组件（如 `section/stack/columns`）。
2. 子组件通过 `:children` 嵌套并显示。
3. 结构清晰且无需自定义布局代码。

## Edge Cases

- 绑定函数执行报错：应给出明确提示，不导致 Emacs 崩溃。
- 组件类型不存在：提示未知 widget 类型。
- 绑定函数返回 `nil` 或空列表：仍应安全渲染。
- `:children` 非 list：应失败并提示。
- 刷新时上下文缺失：应提示无法刷新或回退到最小渲染。

## Acceptance Criteria

- DSL 支持 `:children` 嵌套，渲染顺序与配置一致。
- DSL 支持函数绑定，且 `ctx` 可访问 tag/nodes/virtual columns/global fields。
- 提供最小容器组件集合（至少 `section` + `stack` + `columns`）。
- 提供统一刷新命令，能在数据变化后手动刷新视图。
- `doc/VIEW_FRAMEWORK_DEV_GUIDE.md` 提供 ≤20 行的嵌套 + 绑定示例。
- 既有 `define-supertag-view` 与旧组件 API 继续可用（或在文档中明确兼容边界）。
- 内存 Demo 在一个完整 Dashboard 中覆盖全部注册 Widget，button/link/editable-field 的结果可观察且不访问用户数据。
- DSL view 重复打开时不遗留 native field overlay；editable-field 不改变同行固定列边框的像素位置。
