# plan_concept_mentions_20260708

## Milestones

1. 建立 phase 文档（spec/plan/task/change）。
2. 新增 `supertag-concept.el`，实现 concept title/alias 索引、mention 匹配、跳转和 promote 命令。
3. 将 concept 模块接入 `org-supertag.el`，但不增加默认快捷键。
4. 补充 README/README_CN 的命令与可选 keybinding 示例。
5. 增加 focused tests，覆盖 promote 副作用、mention 匹配、样式区分和“不自动落库”。
6. 运行相关 batch tests，回写 task/change/CHANGE。

## Scope

- 代码：`supertag-concept.el`、`org-supertag.el`。
- 文档：`README.md`、`README_CN.md`。
- 测试：`test-concept-mention.el`。
- Phase 记录：`.phrase/phases/phase-concept-mentions-20260708/*` + `.phrase/docs/CHANGE.md`。

## Priorities

- P0: 不破坏现有 Org `M-RET`、reference、inline tag 行为。
- P0: mention 不以真实 Org link 写回 buffer。
- P1: title/alias 匹配稳定、最长优先。
- P1: light/dark 下 mention 高亮清楚且不刺眼。
- P2: 后续可扩展 alias 编辑命令，但本阶段只保留最小可用接口。

## Risks & Dependencies

- `supertag-relation-add-reference` 会插入 reciprocal backlink；promote 使用它是有意行为，但 mention mode 严禁调用它。
- `supertag-add-reference-and-create` 会替换选区，不能复用为 promote 主体。
- 当前工作树已有 unrelated dirty/untracked 文件，提交时必须只 stage 本阶段文件。

## Rollback

- 删除 `supertag-concept.el` 和 load wiring。
- 删除/回退 README 命令说明。
- 删除 `test-concept-mention.el` 与本 phase 文档记录。
