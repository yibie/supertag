# plan_foundation_20251216: 基础文档与规范 /init

## Milestones

1. 建立 `.phrase` 目录与基础 phase（foundation-20251216）
2. 编写基础规范 spec（项目结构 / 编程约定 / Emacs package 工作流）
3. 建立 `task` 与 `change` 记录，形成可追溯闭环

## Scope

- 仅涉及文档与规范梳理；
- 不修改现有 Elisp 代码行为；
- 不引入新的运行时依赖。

## Priorities

1. 先让新加入的开发者“看得懂项目在哪里改什么”；
2. 再逐步在后续 task 中细化各子模块的 spec / tech-refer；
3. 确保任何新 task 都可以挂在本 phase 下追溯。

## Risks & Dependencies

- 需要与现有 `.github/CONTRIBUTING.org` 和 README 系列保持一致；
- 如果未来开启新 phase，需要在 `.phrase/docs/CHANGE.md` 中增加索引并标记 DONE。

