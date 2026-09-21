# change_extractor_plugins_20251216

- 2025-12-16 Add  
  - Files:  
    - `.phrase/phases/phase-extractor-plugins-20251216/spec_extractor_plugins_20251216.md`  
    - `.phrase/phases/phase-extractor-plugins-20251216/plan_extractor_plugins_20251216.md`  
    - `.phrase/phases/phase-extractor-plugins-20251216/tech-refer_extractor_plugins_20251216.md`  
    - `.phrase/phases/phase-extractor-plugins-20251216/task_extractor_plugins_20251216.md`  
    - `.phrase/phases/phase-extractor-plugins-20251216/change_extractor_plugins_20251216.md`  
  - Reason: 启动新的 phase，专注于构筑 org-supertag 的抽取器插件体系，并将上一阶段 sync tech-refer 中的“Read-Many, Write-Once”内容抽离为本阶段的基础背景  
  - Related: `task001` (task_extractor_plugins_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `.phrase/phases/phase-extractor-plugins-20251216/spec_extractor_plugins_20251216.md`  
    - `.phrase/phases/phase-extractor-plugins-20251216/tech-refer_extractor_plugins_20251216.md`  
    - `.phrase/phases/phase-extractor-plugins-20251216/task_extractor_plugins_20251216.md`  
  - Reason: 完成 `task003` 要求的设计工作，明确 per-headline extractor 的函数签名、registry 接口以及在 parse 流程中调用 pipeline 的时机与上下文结构，同时补充该体系对用户与开发者的价值描述  
  - Related: `task003` (task_extractor_plugins_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-extractor-plugins-20251216/task_extractor_plugins_20251216.md`  
  - Reason: 完成 `task004` 的初始实现，在 `supertag-services-sync.el` 中增设 per-headline extractor registry（`supertag-extractor-register` 等）与内建 `tags`/`properties` extractor，并将 `supertag--convert-element-to-node-plist` 改为构造基础 node plist 后通过 extractor pipeline 填充 `:tags` 和 `:properties`，保持单次 parse 与现有对外节点结构不变  
  - Related: `task004` (task_extractor_plugins_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `.phrase/phases/phase-extractor-plugins-20251216/task_extractor_plugins_20251216.md`  
  - Reason: 新增 `task005`，规划将剩余 per-headline 解析字段（content/olp、refs 以及核心结构字段等）逐步迁移为 extractor，实现“全部解析逻辑走插件 pipeline”的中长期目标，同时保持对现有节点结构与 sync 行为的兼容。  
  - Related: `task005` (task_extractor_plugins_20251216)

- 2025-12-16 Add  
  - Files:  
    - extractor 插件作者指南（后续在 view 插件体系阶段撤回文档，仅保留代码能力）  
    - `.phrase/phases/phase-extractor-plugins-20251216/task_extractor_plugins_20251216.md`  
  - Reason: 引入一份面向插件作者的 extractor 说明文档，描述内建 extractor、API 与 registry，以及可复制的自定义 extractor 示例，帮助用户在不修改核心同步代码的前提下扩展 per-headline 抽取逻辑。  
  - Related: `task006` (task_extractor_plugins_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-extractor-plugins-20251216/tech-refer_extractor_plugins_20251216.md`  
  - Reason: (earlier attempt, later superseded)  
  - Related: `task005` (task_extractor_plugins_20251216)

- 2026-06-10 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-extractor-plugins-20251216/task_extractor_plugins_20251216.md`  
  - Change: 完成 `task005` 的完整实现：  
    1) 在 `supertag-services-sync.el` 中建立完整的 extractor 插件体系（registry 变量 `supertag-extractor--registry`，注册/注销/列出的 API：`supertag-extractor-register`、`supertag-extractor-unregister`、`supertag-extractor-list`，以及 pipeline 调度器 `supertag-extractor--run`）；  
    2) 实现 7 个内建 extractor：`core-structure`（`:level`/`:todo`/`:priority`/`:scheduled`/`:deadline`/`:position`/`:pos`）、`title`（`:title`/`:raw-value`）、`olp`（`:olp`）、`tags`（`:tags`）、`properties`（`:properties`）、`content`（`:content`）、`refs`（`:ref-to`）；  
    3) 将 `supertag--convert-element-to-node-plist` 精简为 thin dispatcher：仅负责 ID 生成/校验与 `:file` 填充，其余所有字段通过 `supertag-extractor--run` 管道生成；  
    4) 通过 `supertag-extractor--setup-defaults` 在文件加载时自动注册所有内建 extractor；  
    5) 抽取逻辑与原有行为完全一致（复用相同的 helper 函数），输出 node plist 结构不变，parse 次数不增加。  
  - Affected functions: `supertag--convert-element-to-node-plist` 瘦身约 50 行；新增约 170 行提取器与 registry 代码。  
  - Related: `task005` (task_extractor_plugins_20251216)

- 2025-12-16 Add  
  - Files:  
    - extractor 插件作者指南与示例（后续在 view 插件体系阶段撤回文档与 demo，仅保留代码能力）  
    - `.phrase/phases/phase-extractor-plugins-20251216/task_extractor_plugins_20251216.md`  
  - Reason: 提供一个完整且可视化验证的 extractor 插件示例（含注册与演示命令），并补充插件作者指南文档，帮助用户用“加载文件→注册 extractor→在 headline 上可视化验证”的方式快速掌握插件构筑方法。  
  - Related: `task006` (task_extractor_plugins_20251216)

- 2025-12-16 Add  
  - Files:  
    - extractor 插件体系的中文说明（后续在 view 插件体系阶段撤回文档，仅保留代码能力）  
    - `.phrase/phases/phase-extractor-plugins-20251216/task_extractor_plugins_20251216.md`  
  - Reason: 增加 extractor 插件体系的中文版文档，并在英文版中增加入口链接，方便中文用户理解“插件构筑→注册→可视化验证”的完整流程。  
  - Related: `task007` (task_extractor_plugins_20251216)
