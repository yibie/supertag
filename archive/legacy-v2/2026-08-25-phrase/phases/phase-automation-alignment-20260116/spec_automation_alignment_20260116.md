# spec_automation_alignment_20260116

## Summary

本阶段目标：让 Automation 2.0 的文档与代码**严格对齐**，减少插件使用者的误解与试错成本。

工作方式：以 `doc/AUTOMATION-SYSTEM-GUIDE.md` 为事实来源（文档先行），先把规则系统的“事件模型 / Trigger / Condition / Action / 维护命令 / 排错路径”写成可验证规范，再把代码实现对齐到同一套术语与行为。

愿景对标：在 Emacs + org-mode 的边界内，朝 Notion 风格“可理解、可预测、可组合”的自动化体验靠近（但不对标 Notion 的 UI 与全量 rollup 形态）。

## Goals

- 文档与实现一一对应：Guide 中出现的 Trigger/Condition/Action/维护命令，均能在代码中找到对应入口与语义，不再需要读源码猜测。
- 事件模型可解释：规则引擎在执行时能明确“发生了什么变化”（例如精确到 property/field/tag），让 `property-changed` / `field-changed` 等条件语义可成立、可验证。
- 用户可验证：Guide 的示例与排错流程提供可执行的手动验证步骤，用户能自助判断 trigger miss / condition fail / action no-op。
- 保持对外 API 名称不变：不改公开的 API 与函数名；允许调整内部事件结构与实现细节以达成对齐。

## Non-goals

- 不做规则编辑/管理 UI（不新增规则面板、可视化编辑器、向导等交互）。
- 不扩展 Trigger/Condition/Action 的能力集合（本阶段聚焦对齐与修正，不新增类型）。
- 不做性能优化/基准测试（正确性、可预测性优先）。
- 不引入新的 DSL：Guide 将移除“条件 `:formula`”承诺，复杂条件改用既有函数谓词（如 `property-test` / `global-field-test` + `lambda`）。
- 不做 Notion 式 Rollup 全量对标：先明确 Emacs/org-mode 边界与本项目现有 rollup/sync 行为，仅保证“文档-代码一致”。
- 不考虑向后兼容（但仍要求对外 API/函数名不变）。

## User Flows

### Flow A：用户按 Guide 写规则并得到可预测效果

1. 用户在 init 中加载 automation（按 Guide 推荐方式）。
2. 用户用 `supertag-automation-create` 定义规则（包含 `:trigger/:condition/:actions`）。
3. 用户执行一次最小操作（例如给节点加 tag / 修改 property / 修改 global field）。
4. 用户观察到与 Guide 描述一致的动作效果（例如更新 TODO/state/property/tag）。

### Flow B：用户排查“规则为什么没跑”

1. 用户按 Guide 的排错清单检查：触发器是否匹配、条件是否失败、规则是否启用、动作是否 no-op。
2. 用户能从日志/诊断入口（若有）定位到具体层级：trigger miss / condition fail / action skipped / error。

### Flow C：明确 Notion 对标边界（避免误解）

1. 用户在 Guide 的“边界”章节看到：哪些能力属于 org-mode/Emacs 可实现范畴（例如更新 headline/todo/property/tag、调用函数、批量操作）。
2. 用户看到本阶段不承诺的部分（例如 UI 级 rule editor、Notion 数据库视图级 rollup 体验）。

## Edge Cases

- 同一变更从多个入口重复触发（例如 :store-changed vs commit hook）：必须明确默认策略，避免重复执行。
- 同步执行层丢失“精确变化路径”，导致 `property-changed/field-changed` 退化为猜测：需要补齐事件上下文。
- Tag 事件语义不一致（added/removed vs add-tag/remove-tag）：需要统一内部表示以便文档与实现一致。
- Action 是 no-op 时不应造成额外保存/触发链式事件（避免误导与噪音）。

## Acceptance Criteria

- `doc/AUTOMATION-SYSTEM-GUIDE.md`：
  - 删除/替换条件 `:formula` 相关承诺，改用函数谓词示例；
  - Trigger/Condition/Action/维护命令与真实实现一致；
  - 明确事件模型与上下文结构（包括精确 `:path` / tag op 语义）；
  - 给出可执行的最小验证与排错流程。
- 代码实现与 Guide 对齐（不改对外 API/函数名）：核心语义（trigger match、changed detection、tag op）在同步链路与旧链路一致可解释。
- phase 文档闭环：`task_*.md` 勾选、`change_*.md` 记录、`.phrase/docs/CHANGE.md` 索引完整。

