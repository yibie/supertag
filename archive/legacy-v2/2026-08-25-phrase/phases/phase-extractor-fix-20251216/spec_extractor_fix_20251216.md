# spec_extractor_fix_20251216: 修复 supertag-core-extractor 语法错误

## Summary

本阶段聚焦于修复 `supertag-core-extractor.el` 中影响加载/运行的语法错误，
确保该模块可以在 Emacs 中正常加载，并作为 Org-Supertag 提取管线的一部分稳定工作。

## Goals

- 找出并修复 `supertag-core-extractor.el` 中的语法错误（reader error / 未闭合括号等）；
- 在 Emacs 中成功加载该文件（或通过 `org-supertag.el` 间接加载）无报错；
- 不改变现有对外 API 或行为语义（仅限语法/显而易见的笔误修复）。

## Non-goals

- 不在本阶段重构 extractor 设计或接口；
- 不新增新的提取字段或修改数据模型结构；
- 不大幅调整测试框架，仅做最小验证（batch load 或简单函数调用）。

## Acceptance Criteria

- `supertag-core-extractor.el` 可以在 Emacs 中成功 `load-file`，且不会触发语法错误；
- 通过最小手动验证，核心提取函数（如 `supertag-extractor-setup-defaults`）可被调用且不会抛出立即错误；
- 对应 `task` 条目被标记完成，并在本 phase 的 `change_*` 与 `.phrase/docs/CHANGE.md` 中可追溯。

