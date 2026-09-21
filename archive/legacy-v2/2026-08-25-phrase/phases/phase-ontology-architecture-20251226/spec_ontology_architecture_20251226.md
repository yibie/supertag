# spec_ontology_architecture_20251226

## Summary

产出 org-supertag 本体三层（数据/逻辑/行为）架构视图文档，基于现有代码结构给出模块映射、职责边界和运行流，补充函数级混杂点清单与拆分建议，并明确与用户自定义 `supertag-automation` 规则的差异；提供 `supertag-test.el` 实验脚本用于体验逻辑/行为分离。

## Goals & Non-goals

### Goals
- 提供清晰的三层定义（Data / Logic / Behavior）与“可做/不可做”的边界约束。
- 基于现有模块（core/services/ops/ui/automation）给出映射表与混杂点说明。
- 回答“本体三层变化与 `supertag-automation` 规则的不同”。
- 提供函数级混杂点清单与最小拆分建议，解释 `supertag-core-scan.el` 的定位。
- 提供 `supertag-test.el` 实验脚本（逻辑解释 + 自动化 dry-run 预览）。
- 文档优先中文，落地到 `doc/`。

### Non-goals
- 不实现 Logic DSL 或新增 runtime 机制。
- 不做模块重构或代码迁移。
- 不补充英文版文档。

## User Flows

1. 开发者打开架构视图文档，理解数据/逻辑/行为三层定义与职责边界。
2. 开发者根据映射表判断新功能应落在哪一层，避免跨层耦合。
3. 用户/开发者查阅“与 automation 规则的区别”章节，明确当前规则系统的定位。

## Edge Cases

- 逻辑能力目前部分散落在 automation 条件、公式与 query 中：文档需指出混杂点并标注“当前态”。
- UI/服务层对 query/公式的调用属于行为层入口，但本体逻辑仍保持只读语义。
- 旧数据或全局字段模型切换不会影响本次文档内容，避免引入不必要的迁移讨论。

## Acceptance Criteria

- `doc/ONTOLOGY-ARCHITECTURE_cn.md` 存在并包含：三层定义、模块映射表、运行流/边界、与 `supertag-automation` 的差异说明。
- `supertag-test.el` 提供可手动加载的实验命令，包含逻辑解释与自动化 dry-run 预览能力。
- 当前 phase 文档更新完成，`task001`/`task002`/`task003`/`task004` 标记完成。
