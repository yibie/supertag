# task_extractor_plugins_20251216

- task001 [x] 建立 extractor 插件体系 phase 文档骨架  
  - 产出：`spec_extractor_plugins_20251216.md` / `plan_extractor_plugins_20251216.md` / `task_extractor_plugins_20251216.md` / `change_extractor_plugins_20251216.md` / `tech-refer_extractor_plugins_20251216.md`  
  - 验证方式：上述文件存在且围绕“抽取器插件体系（Parse Once, Extract Many）”的目标（手动检查）  
  - 影响范围：仅内部文档结构

- task002 [x] 提炼并文档化现有 per-headline 抽取逻辑的结构与边界  
  - 产出：在 `tech-refer_extractor_plugins_20251216.md` 中补充：  
    - 现有 `supertag--convert-element-to-node-plist` 中负责的抽取职责（tags/properties/links/outline path 等）；  
    - 解析函数与 ops 调用之间的边界（哪些属于“抽取”，哪些属于“写入/变更 store”）；  
    - 识别一两个适合作为 extractor 试点的子集（例如 tags + properties）。  
  - 验证方式：对照 `supertag-services-sync.el` / `supertag-core-scan.el` 等文件，确认文档描述与代码一致（尤其是 `supertag--convert-element-to-node-plist` 当前承担的职责）。  
  - 影响范围：仅文档与分析。

- task003 [x] 设计最小 extractor 插件 API 与注册机制  
  - 产出：在 `tech-refer_extractor_plugins_20251216.md` 与 `spec_extractor_plugins_20251216.md` 中明确：  
    - 抽取器的签名与输入输出（例如 `(ELEMENT FILE CTX) -> plist`）；  
    - 注册/注销接口（注册顺序、priority 等）；  
    - 在 parse 流程中调用 extractor pipeline 的时机与上下文结构。  
  - 验证方式：检查接口设计是否可以覆盖既有抽取逻辑（至少 tags/properties），并与 sync/事务约束不冲突（已在 `spec_extractor_plugins_20251216.md` 的 High-level Design 与 `tech-refer_extractor_plugins_20251216.md` 的 Extractor API Design 小节中给出，不需要改动现有 sync/事务描述）；  
  - 影响范围：设计与约束，为后续实现提供基础。

- task004 [x] 在解析路径中接入 extractor pipeline（试点一两个 extractor）  
  - 产出：  
    - 在核心解析路径（如 `supertag--parse-org-nodes` 或相关模块）引入对 extractor registry 的调用（已在 `supertag--convert-element-to-node-plist` 中通过 `supertag-extractor--run` 完成）；  
    - 将一部分现有 per-headline 逻辑（例如 tags 或 properties 抽取）迁移为 extractor 实现，并通过新 API 注册（已提供 `supertag-extractor--tags` / `supertag-extractor--properties` 并在 `supertag-services-sync.el` 顶层注册）；  
    - 保持现有对外行为一致（节点结构不变），并确保 parse 次数不增加（`supertag--parse-org-nodes` 仍然对每个文件只调用一次 `org-element-parse-buffer`，extractor 只在 per-headline 层做纯粹数据填充）。  
  - 验证方式：  
    1. 在测试仓库上比较迁移前后的节点数据与行为是否一致（依赖调用 `supertag--parse-org-nodes`、`supertag-node-sync-at-point` 的实际效果进行手动检查）；  
    2. 确认解析性能没有明显退化（代码路径上未新增额外 parse，仅增加 per-headline 的轻量函数调用）；  
    3. 后续可考虑补充 ert 或手动测试覆盖内建 tags/properties extractor 的主要路径。  
  - 影响范围：解析/抽取层实现，对 store/ops 的对外接口保持兼容。

- task005 [x] 将剩余 per-headline 解析字段逐步插件化  
  - 产出：在现有 extractor registry 基础上，补充内建 extractor，覆盖当前 `supertag--convert-element-to-node-plist` 中尚未插件化的字段（如 `:content` + `:olp`、`:ref-to`、以及核心结构字段如 `:level`/`:todo`/`:priority` 等），并相应瘦身 `supertag--convert-element-to-node-plist`，让其更偏向“调度器 + 最小骨架”；具体拆分范围和优先顺序先在 `tech-refer_extractor_plugins_20251216.md` 中补充一个小节进行规划。  
  - 验证方式：  
    1. 针对典型节点（含引用、inline tags、PROPERTIES 抽屉、native `:tag:`、多级 outline）的手动检查，确认插件化前后通过 `supertag--parse-org-nodes` 与 `supertag--parse-node-at-point` 得到的节点 plist 结构保持兼容；  
    2. 在小型测试仓库上跑 `supertag-sync-full-rescan`，对比迁移前后节点数量与关键字段（id/title/tags/properties/content/ref-to）的行为一致；  
    3. 关注解析时间和 UI 响应，确保没有因为插件化导致额外的 parse 调用或明显退化。  
  - 影响范围：解析/抽取层实现，进一步巩固“全部解析逻辑走 extractor pipeline”的结构，对 store/ops 接口保持兼容。

- task006 [x] 为 extractor 插件体系提供示例与说明文档  
  - 产出：  
    - 提供一份面向用户/开发者的 extractor 说明文档（后续已撤回对外文档呈现，仅保留代码能力）；  
    - 在文档中给出至少一个可复制的 extractor 示例代码片段，展示如何注册自定义 extractor（例如按标题模式打标或基于 :content 计算布尔标记）。  
  - 验证方式：  
    1. 手动检查说明文档是否覆盖概念/内建 extractor/注册 API/示例代码；  
    2. 加载 extractor demo 后，`(supertag-extractor-list)` 可见 demo extractor，并可通过 demo 命令可视化验证解析结果（该 demo 后续已撤回文件呈现）。  
  - 影响范围：仅文档与示例，帮助用户和插件作者理解并使用 extractor 插件体系。

- task007 [x] 提供 extractor 插件体系中文版文档  
  - 产出：新增 extractor 插件体系的中文版说明（后续已撤回对外文档呈现，仅保留代码能力）。  
  - 验证方式：手动检查中文说明内容完整、示例与英文版一致，并确保英文说明中包含入口链接（后续文档已撤回）。  
  - 影响范围：仅文档，降低中文用户理解与上手成本。
