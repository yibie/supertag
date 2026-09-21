# task_foundation_20251216

- task001 [x] `/init`：建立 `.phrase` 结构并编写基础规范文档的第一部分  
  - 产出：  
    - `.phrase/docs/CHANGE.md`、`.phrase/docs/ISSUES.md` 基础索引  
    - `phase-foundation-20251216` 下的 `spec/plan/task/change` 基础文件  
    - `spec_foundation_20251216.md` 顶部三节（项目结构 / 编程约定 / Emacs package 开发工作流）  
  - 验证方式（手动）：  
    1. 打开 `.phrase/phases/phase-foundation-20251216/spec_foundation_20251216.md`；  
    2. 确认文档最前面的三节分别为“项目结构（代码与文档）”“编程约定（Emacs Lisp）”“Emacs package 开发推荐工作流”；  
    3. 确认 `CHANGE.md` 中已索引到当前 phase 的 `change_foundation_20251216.md`。  
  - 影响范围：仅内部文档结构与说明，无运行时代码变更

- task002 [ ] 补充与维护后续模块级 spec/tech-refer（待拆分）  
  - 产出：针对核心模块（如 `supertag-core-*`、`supertag-services-*`）的更细粒度文档  
  - 验证方式：在新增模块文档时，对应更新本文件与 `change_*`  
  - 影响范围：内部设计文档

- task003 [x] 在 `AGENTS.md` 开头加入简版项目说明  
  - 产出：`AGENTS.md` 第一部分增加“Org-supertag 项目说明（简版）”，涵盖代码结构、文档划分、编程约定与推荐开发工作流  
  - 验证方式（手动）：  
    1. 打开 `AGENTS.md`，确认新段落位于全文最前；  
    2. 核对内容与 `.phrase/phases/phase-foundation-20251216/spec_foundation_20251216.md` 中的三大部分在语义上保持一致但更简略；  
    3. 确认原有 Doc-Driven 开发流程说明仍然保留在其后。  
  - 影响范围：仅影响面向协作方/智能体的项目说明文本，不影响运行时代码

- task004 [x] 梳理并记录通用 Emacs package 开发最佳实践  
  - 产出：  
    - 在 `spec_foundation_20251216.md` 中新增“通用 Emacs package 开发最佳实践（本项目适用部分）”一节；  
    - 在 `AGENTS.md` 的项目说明中补充“通用 Emacs package 约定（本项目已部分遵守）”简版说明。  
  - 验证方式（手动）：  
    1. 打开 `org-supertag.el`，确认已包含标准 package 头、`lexical-binding` 与 `Package-Requires:` 等信息；  
    2. 打开 `spec_foundation_20251216.md`，确认新增小节覆盖头部、命名空间、配置（defgroup/defcustom）、autoload/启动行为和测试等方面；  
    3. 打开 `AGENTS.md`，确认通用约定部分为上述内容的精简版，并位于项目说明中。  
  - 影响范围：规范与文档，对现有行为无直接修改

- task005 [x] 在 `AGENTS.md` 第一部分显式引用 foundation spec  
  - 产出：在项目说明末尾增加一条“详细设计 / 长文版规范”说明，指向 `.phrase/phases/phase-foundation-20251216/spec_foundation_20251216.md`，用于引导智能体在需要时查看完整规范。  
  - 验证方式（手动）：  
    1. 打开 `AGENTS.md`，确认项目说明部分包含指向上述 spec 文件的文字引用；  
    2. 确认引用语义明确：本节为精简版，spec 为长文版，并提示更新时保持一致；  
    3. 确认原有 Doc-Driven 开发流程段落位置不变。  
  - 影响范围：仅影响协作说明与智能体导航，不影响运行时代码
