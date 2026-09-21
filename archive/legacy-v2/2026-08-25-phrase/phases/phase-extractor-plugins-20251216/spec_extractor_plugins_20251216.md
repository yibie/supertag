# spec_extractor_plugins_20251216: 抽取器插件体系（Parse Once, Extract Many）

## Summary

本阶段聚焦于为 Org-supertag 构建一个清晰的“抽取器插件体系”，
让 per-headline 的数据抽取逻辑从当前内嵌式实现演进为真正的
extractor 插件系统，同时保持现有 sync/队列/事务架构不被破坏。

目标是靠近 Vulpea 文档中的“parse once, extract many, commit in
transaction” 模式：

- 单文件层面：一次 parse AST，多个 extractor 基于同一 parse 上下文工作；
- 批处理层面：通过 `supertag-with-transaction` 对多节点/多文件的更新做统一提交；
- 插件层面：允许未来在不改核心扫描/同步实现的前提下，按需增加新的抽取维度。

## Goals

- 梳理并抽象出“抽取器插件”的最小接口与生命周期（注册 → 参与解析 → 产出数据 → 写入 store/ops）；
- 在不破坏现有 `supertag--parse-org-nodes` 和 sync 流程的前提下，引入一层可选的 extractor 注册/调度机制；
- 保持“单文件只 parse 一次”的原则，并在必要时为未来 AST 复用铺路；
- 为后续更复杂的扩展（如自定义 schema、额外索引）提供稳定挂接点；
- 让普通用户可以通过配置启用/关闭一类抽取行为（如 tags / properties），让开发者可以通过插件 API 扩展 per-headline 抽取维度，而无需 fork 或侵入核心同步代码。

## Non-goals

- 不在本阶段重写整个 sync 或数据库架构（例如引入 SQL 后端等）；
- 不立即实现 AST 缓存或跨子系统的 AST 复用（仅在 tech-refer 中记录方向）；
- 不一次性改造所有现有 per-headline 逻辑，优先挑选一两个典型路径试点（如 tags/properties 提取）。

## Context: Read-Many, Write-Once（现状摘要）

基于上一阶段 sync 的技术探索，目前 org-supertag 已经具备部分
“多读一次写”的特征：

- 单文件层面：
  - `supertag--parse-org-nodes` 对每个文件只调用一次 `org-element-parse-buffer`，再通过 `supertag--map-headlines` 把所有 headline 转换为 node plist；
  - 单个文件的多节点写入通常发生在上层事务中（例如 full-rescan 或 auto-sync 中的 `supertag-with-transaction`）。
- 批处理层面：
  - full-rescan 和 auto-sync（含队列版）都使用 `supertag-with-transaction` 将一批文件/节点的更新在一次事务边界内提交；
  - 队列引入后，每个 batch 都在一次事务中完成，减少事务碎片化。

这为“parse once, extract many, commit in transactions”的插件体系提供了良好的基础。

## Future Directions (for this phase)

本阶段聚焦于下列改进，后续可根据实际进展拆分成更细的 task：

- 抽取器插件接口：
  - 设计一个 lightweight 的 extractor 注册 API（例如 `supertag-extractor-register` 风格），允许按 name / priority 注册插件；
  - 抽象“per-headline 抽取逻辑”的输入输出（AST 片段 / headline 元数据 → 有结构的数据）。
- 解析与调度：
  - 在 `supertag--parse-org-nodes` 或其附近引入一个“解析上下文”结构，将 parse 结果与文件级信息传给各 extractor；
  - 确保每个文件仍然只 parse 一次，extractor 在此基础上多次读取。
- 与 store/ops 的衔接：
  - 约定 extractor 只负责“提取数据”，具体写入逻辑由统一的 ops/pipe 负责，在 `supertag-with-transaction` 中统一提交；
  - 为未来调整事务粒度（tick 级 / 宏批次）保留空间。

具体的接口设计、过渡策略和试点范围将在本 phase 的 plan/tech-refer/task 中进一步细化。 

## High-level Design: Extractor API & Registry

在本 phase 内，抽取器插件体系的高层设计目标是：

- 为“per-headline 抽取逻辑”定义一个统一的、可扩展的接口；
- 提供一个 registry，使核心解析代码只依赖“调用一批 extractor”这一抽象，而不关心具体实现；
- 允许用户通过配置/变量控制 extractor 的启用与否，支持未来扩展第三方/用户自定义 extractor。

### 抽取器的基本接口

- 抽取器的最小单位是“per-headline extractor function”，签名形如：
  - `(ELEMENT FILE CTX) -> PLIST-PATCH`
  - 其中：
    - `ELEMENT`：当前 headline 的 org-element 节点；
    - `FILE`：当前文件的绝对路径（字符串）；
    - `CTX`：解析上下文结构（含全文件 AST、父节点信息、解析模式等，只读）；
    - 返回值 `PLIST-PATCH`：一个 plist 片段，包含本 extractor 负责的 key（如 `:tags`、`:properties` 等），由核心聚合逻辑 merge 到最终 node plist。
- 抽取器必须满足：
  - 无副作用（不写数据库、不写 buffer、不调用事务），只做纯粹的“读 AST → 产出数据”；
  - 在输入不变时输出稳定（方便测试和未来缓存）。

### Registry 与优先级

- 提供集中式注册/注销接口，典型形态：
  - `(supertag-extractor-register :name 'tags :priority 100 :fn #'supertag-extractor--tags)`
  - `(supertag-extractor-unregister 'tags)`
- Registry 负责维护一个有序列表：
  - 每个条目包含 `:name` / `:priority` / `:fn`（以及未来可扩展的 `:enabled-p` 等元数据）；
  - 解析时按 `:priority` 从小到大调用 extractor，并依次将其返回的 plist 补丁 merge 进当前 node；
  - 后注册的同名 extractor 可以覆盖原有注册（用于测试或用户自定义 override）。

### 解析流程中的调用时机

- 保持现有“单文件 parse 一次”的原则：
  - `supertag--parse-org-nodes` 仍然负责调用 `org-element-parse-buffer`，并遍历 headline；
  - 在遍历到单个 headline 时构造解析上下文 `CTX`，然后按 registry 中的 extractor 顺序调用；
  - 聚合所有 extractor 的输出，形成最终 node plist（同时保留当前已有的结构字段，如 `:file`、`:position` 等）。
- 针对 tags / properties 等现有逻辑：
  - 本 phase 内不改变对外节点结构，仅将部分内部实现重写为 extractor，并通过上述接口注册；
  - 确保迁移后，旧的查询与视图仍能在不改动的情况下工作。

### 面向用户与开发者的价值

- 对普通用户：
  - 可以通过变量/选项启用或禁用某类抽取器（例如“只建立 tag 索引，不抽取 properties”，或为特定项目开启某个自定义 extractor）；
  - 未来可通过插件包引入新的抽取能力，而不依赖 org-supertag 核心发布节奏。
- 对开发者：
  - 提供清晰的扩展点与约束：只要遵守 `(ELEMENT FILE CTX) -> PLIST-PATCH` 签名并保持纯函数，就可以在不接触 sync/事务/数据库实现的前提下扩展系统；
  - 降低修改核心解析代码的频率，降低回归风险；便于用 ERT 对单个 extractor 进行单元测试。
