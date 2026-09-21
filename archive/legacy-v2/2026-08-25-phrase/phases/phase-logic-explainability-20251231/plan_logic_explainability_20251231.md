# plan_logic_explainability_20251231

## Milestones

1. 建立 phase 文档（spec/plan/task/change）并补全用户视角说明。
2. 扫描自动化执行链路，修复重复触发与 no-op 保存造成的消息噪音。
3. 在用户文档中加入“逻辑层如何被使用/为什么爽快”的使用情景（中文）。
4. 恢复 table view 引用跳转键位并记录变更。

## Scope

- 文档：`doc/ONTOLOGY-ARCHITECTURE_cn.md` + 本 phase 文档。
- 代码：自动化/同步日志与 no-op 行为修复；table view 键位回滚。

## Priorities

- P0：减少噪音 + 去除重复触发（不影响功能）。
- P1：把“逻辑层对用户的价值/用法”说清楚，并提供可运行的解释入口（实验命令）。
- P2：保持文档与实际代码一致。

## Risks & Dependencies

- 自动化事件入口存在历史兼容路径（:store-changed vs after-operation-hook），需要明确默认策略。
- Org buffer 的保存/同步行为牵涉 after-save-hook，需要谨慎避免引入循环与误判。

## Rollback

- 代码回滚：恢复相关 message/钩子行为；文档回滚：删除新增章节与 phase 文件即可。

