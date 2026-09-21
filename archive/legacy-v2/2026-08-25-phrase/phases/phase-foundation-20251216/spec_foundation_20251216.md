# spec_foundation_20251216: Org-supertag 内部开发基础规范

## Summary

本规范用于为 Org-supertag 建立一个“可长期演进的内部开发入口”，
优先回答三个问题：

1. 项目结构（代码和文档）是如何划分的？
2. 编程约定（命名、风格、模块边界）是什么？
3. Emacs package 开发时，推荐的日常工作流是什么？

本文件应作为后续内部开发文档的第一部分被优先阅读和维护。

## 项目结构（代码与文档）

### 代码结构（Emacs Lisp）

- `org-supertag.el`  
  - 包入口与用户-facing 配置变量/命令（如 sync 目录、全局开关等）；
  - 推荐作为阅读代码的起点，理解用户如何加载与启用包。
- `supertag-core-*` 系列  
  - 纯数据与领域逻辑：扫描、状态管理、持久化、schema、transform 等；
  - 原则：不直接做 UI / 交互，只处理“输入 Org 结构 / 输出内部数据结构”的工作；
  - 适合写单元测试与可复用逻辑。
- `supertag-services-*` 系列  
  - 在 core 之上提供对用户场景友好的服务：capture、query、scheduler、sync、formula 等；
  - 面向“用例”，负责把多个 core 组合起来；
  - 在不影响核心数据模型的前提下，可以相对独立演进。
- `supertag-ops-*` 系列  
  - 面向“运维/工具型操作”的接口：schema 操作、tag 操作、relation 操作、batch 等；
  - 多用于迁移、批处理和数据修复任务。
- `supertag-ui-*` / `supertag-view-*` 系列  
  - UI 命令与视图：搜索界面、表格、看板、节点视图、查询块 UI 等；
  - 原则：只做交互和展示，核心逻辑尽量下沉到 core/services；
  - 与 Emacs UI 行为关系密切，适合通过手动步骤验证。
- `supertag-migration*` / `supertag-automation*` 系列  
  - 数据结构迁移和自动化系统相关逻辑；
  - 需要严格遵守文档中的迁移步骤，避免破坏用户数据。
- `archive/`  
  - 旧版本/实验性代码的归档，不建议再直接依赖；
  - 如需重新启用其中逻辑，应先在 `.phrase` 中写清 Decision/adr，再恢复。
- `scripts/`  
  - 开发者使用的小工具脚本（例如恢复 heading IDs 等），默认不对普通用户暴露。
- 测试文件  
  - 当前存在 `test_extractor.el`，后续可在 `Tests/` 或 `tests/` 结构下逐步补齐镜像测试。

### 文档结构

- 顶层 README：`README.md` / `README_CN.md`  
  - 面向最终用户，介绍功能、安装、快速开始和重要迁移步骤；
  - 不承担内部架构/设计细节。
- 详细用户指南：`doc/*.md`  
  - 专注于具体子系统（如 Capture、Automation、Query Block、Completion 等）的使用手册；
  - 中文/英文版本通常成对出现。
- 贡献指南：`.github/CONTRIBUTING.org`  
  - 定义 Elisp 代码风格、测试约定和提交规范；
  - 所有内部开发规范需要与该文件保持一致或在冲突时以其为准。
- 内部开发文档：`.phrase/`  
  - `docs/`：全局索引（如 `CHANGE.md` / `ISSUES.md`）；
  - `phases/phase-*/`：按里程碑拆分的 spec/plan/task/change/issue 等；
  - 当前文档所在的 `phase-foundation-20251216` 用于整理基础规范与开发入口。

## 编程约定（Emacs Lisp）

- 通用风格（参考 `.github/CONTRIBUTING.org`）
  - 使用 2 空格缩进，保持良好括号对齐；
  - 函数与变量命名使用有意义的英文单词，避免不必要缩写；
  - 每个对外函数需要清晰的 docstring，说明参数、返回值和典型用法；
  - 复杂逻辑块附近应有简短英文注释说明意图。
- 命名前缀
  - 面向用户的入口/命令：使用 `supertag-` 或 `org-supertag-` 前缀，保持与现有代码一致；
  - 内部 helper 可以使用更细前缀（如 `supertag-core-...` / `supertag-services-...`），保持模块边界。
- 模块边界
  - core 层尽量保持无 UI / 无副作用（除了必要的 IO），以便测试；
  - services 层负责 orchestrate 多个 core 模块，避免在 UI 中拼装复杂业务逻辑；
  - UI/view 层负责键绑定、交互和展示，将业务决策留给 core/services；
  - migration/ops 层所有操作都应有“可恢复/回滚”思路，并在文档中说明风险。

## Emacs package 开发推荐工作流

- 日常开发节奏（以一个小特性/修复为例）
  1. 在 `.phrase` 的当前 phase 中为需求/问题补充 `spec_*` 或 `issue_*` 简要说明；
  2. 在 `task_*` 中拆出 `taskNNN`，写明产出与验证方式；
  3. 根据任务修改对应模块（优先从 core/services 开始，最后再改 UI）；
  4. 如有可能，补充或更新对应的测试文件（例如 `test_extractor.el` 或未来的模块测试）；
  5. 在 Emacs 中通过交互命令进行手动验证（例如运行 `M-x supertag-sync-full-rescan`、打开视图等）；
  6. 更新 `task_*` 勾选项，并在 `change_*` 和 `.phrase/docs/CHANGE.md` 中记录变更。
- 推荐工具链
  - 使用本地 Emacs 直接加载当前工作副本（如 `(load-file "~/path/to/org-supertag/org-supertag.el")`）进行调试；
  - 通过 `M-x eval-buffer` / `M-x eval-defun` 快速迭代单个函数；
  - 使用 `ert` 编写和运行单元测试（可在后续 phase 中建立统一的测试入口）。
- 提交与发布
  - 提交信息遵循 `.github/CONTRIBUTING.org` 中的 Conventional Commit 风格，如：`feat(view): add kanban filter`；
  - 在准备发布版本时，优先更新 `CHANGELOG.org` 和相关用户文档，再在 `.phrase` 中记录对应 phase 的 DONE 状态。

## 通用 Emacs package 开发最佳实践（本项目适用部分）

- 文件头与编译环境
  - 使用标准 package 头部注释，包括简短说明、版权、Author、Version、URL 和 `Package-Requires:` 等；
  - 在第一行启用 `lexical-binding`（本项目已在 `org-supertag.el` 中启用）；
  - 保持 `;;; Commentary:` 和 `;;; Code:` / `;;; org-supertag.el ends here` 结构完整。
- 命名空间与依赖
  - 所有对外符号（命令、变量、minor mode 等）使用统一前缀（本项目为 `org-supertag-` / `supertag-`），避免污染全局命名空间；
  - 在文件头的 `Package-Requires:` 中声明依赖（如 `emacs`/`org`/`ht` 等），运行时避免直接依赖过时库（如旧版 `cl`），优先使用 `cl-lib`。
- 可配置项与自定义
  - 使用 `defgroup` 定义本包的自定义组（本项目已有 `org-supertag` 组）；
  - 使用 `defcustom` 暴露可配置选项（如数据目录、项目根路径等），而不是要求用户直接 `setq` 内部变量；
  - 为每个对外配置项提供清晰 docstring，包括默认值含义和典型设置方式。
- 自动加载与启动行为
  - 为面向用户的命令/入口函数添加 `;;;###autoload`（后续可按模块逐步补充），以便包管理器懒加载；
  - 避免在加载文件时执行重型逻辑，尽量将初始化放入显式命令或 minor mode 中（如本项目的 `supertag-init`）；
  - 若需要在 `emacs-startup-hook` 或 `org-mode-hook` 中自动启用功能，必须在文档中清楚说明其行为与关闭方式。
- 测试与质量保证
  - 使用 `ert` 编写可重复的单元测试，将测试放入独立文件（当前已有 `test_extractor.el`，后续可扩展为完整测试套件）；
  - 优先为 core 层的纯函数和数据结构编写测试，再向 services/UI 扩展；
  - 引入新依赖或修改核心行为时，应在提交前至少进行一次 `ert` 测试运行和手动交互验证。

## Goals

- 为日常开发者提供一个 5 分钟内可读完的“项目地图”；
- 在不改变现有对外文档（README / doc/*）语义的前提下，总结内部约定；
- 与仓库现有规范（如 `.github/CONTRIBUTING.org`）兼容，并在冲突时以现有规范为准。

## Non-goals

- 不尝试在本次 `/init` 中重构目录或大规模重命名；
- 不在本次变更中引入新的构建/发布流程；
- 不覆盖外部用户文档的结构（只做内部开发视角的补充）。

## Acceptance Criteria

- 有一份可用的基础规范文档，首段明确：
  - 代码/文档的物理结构；
  - Emacs Lisp 代码的主要风格约定；
  - Emacs package 日常开发的推荐节奏（工作流）；
- 对应任务在 `task_foundation_20251216.md` 中标记完成，并在 `change_foundation_20251216.md` 中可追溯；
- 不引入对现有用户行为的破坏性变更。
