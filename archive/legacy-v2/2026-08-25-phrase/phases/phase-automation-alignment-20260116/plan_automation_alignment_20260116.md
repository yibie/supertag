# plan_automation_alignment_20260116

## Milestones

1. 建立 phase 文档（spec/plan/task/change），锁定非目标、边界与验收标准。
2. 文档先行：重写 `doc/AUTOMATION-SYSTEM-GUIDE.md` 为可执行规范（对齐现实现状与目标语义）。
3. 代码对齐：补齐事件上下文与语义一致性（尤其是 changed detection 与 tag op），保证与 Guide 描述一致。
4. 验证与收尾：用最小手动场景验证关键路径，并回写 phase `change_*` 与 `.phrase/docs/CHANGE.md` 索引。

## Scope

- 文档：
  - `doc/AUTOMATION-SYSTEM-GUIDE.md`（主事实来源）
  - 本 phase 文档：`spec_*` / `plan_*` / `task_*` / `change_*`
- 代码（仅对齐与修正，不新增能力集合）：
  - `supertag-automation.el`
  - `supertag-automation-sync.el`

## Priorities

- P0：Guide 与代码“说同一种话”（术语、语义、示例、维护命令一致）。
- P1：事件上下文精确可解释（变化路径可定位），让条件语义成立且可验证。
- P2：排错体验可用（最小日志/诊断入口与手动验证清单）。

## Risks & Dependencies

- 风险：文档先行会暴露实现缺口（尤其事件上下文/触发语义），可能需要调整内部事件数据结构。
- 依赖：store/commit 事件是否能稳定提供“精确变化路径”；若不稳定，需要在内部统一生成并透传。
- 约束：不改对外 API/函数名；不引入新 DSL；不做 UI。

## Rollback

- 文档回滚：恢复 Guide 旧章节/示例；保留 phase 文档作为历史记录。
- 代码回滚：回退事件上下文/触发语义相关变更，恢复当前行为。

