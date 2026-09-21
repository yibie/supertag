# plan_ontology_architecture_20251226

## Milestones

1. 建立 phase 文档（spec/plan/task/change）。
2. 扫描现有模块与数据流，整理 Data/Logic/Behavior 映射与函数级混杂点清单。
3. 输出混杂点拆分建议与 `supertag-core-scan.el` 定位说明。
4. 产出实验脚本 `supertag-test.el`（逻辑解释 + automation dry-run）。
5. 产出架构视图文档并更新 change/task/CHANGE 索引。

## Scope

- 架构视图文档：`doc/ONTOLOGY-ARCHITECTURE_cn.md`。
- Phase 文档与变更索引：`.phrase/phases/phase-ontology-architecture-20251226/*` + `.phrase/docs/CHANGE.md`。

## Priorities

- P0: 三层定义与模块映射准确清晰。
- P1: 回答与 `supertag-automation` 规则的差异。
- P2: 给出最小落地边界/约束建议。

## Risks & Dependencies

- 逻辑/行为在现有代码中存在交叉，需在文档中明确“当前态”而非理想态。
- 模块命名可能在未来变更，需标注映射以当前代码为准。

## Rollback

- 删除新增文档与 phase 记录即可回退。
