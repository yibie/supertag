# plan_extractor_fix_20251216: Extractor 语法错误修复

## Milestones

1. 建立 extractor 修复专用 phase 文档（spec/plan/task/change）
2. 检查并修复 `supertag-core-extractor.el` 的语法错误
3. 在 Emacs 中做最小加载验证，并更新 task/change 记录

## Scope

- 仅修复 `supertag-core-extractor.el` 与其直接语法相关的问题；
- 不修改其它模块的行为，除非为消除编译/加载时的硬错误所必需；
- 不扩展 extractor 的功能（仅限保守修复）。

## Priorities

1. 先保证文件本身语法合法、可加载；
2. 再在必要范围内调整正则或宏调用以避免明显的运行时错误；
3. 后续若发现逻辑问题，可在新的 task/phase 中处理。

## Risks & Dependencies

- 依赖当前 Emacs 版本的解析行为（例如正则、`org-element` API 的变化）；
- 若发现与其它模块存在设计层面的耦合问题，应记录到新的 `spec`/`issue`，不要在本 phase 中混合处理。

