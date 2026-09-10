The legacy schema/table/kanban/search/capture entry points described here are archived; see README for the current workflow.

# Supertag 当前架构问题审计

> 核心判断：问题真实、值得修，但不值得重写。系统已经有正确的所有权模型和数个可靠深模块；风险来自这些新边界尚未成为唯一入口。最严重的问题不是“大文件”，而是同一个事实可按不同顺序、经不同写入 API、触发不同事件被修改。

> 时点说明：本文记录 C1–C5 实施前的审计基线。Document create/delete/demote 的 P0 顺序问题现已由 `supertag-service-org.el` 的 Document-first commands 修复，并由 E-005/E-006 验证；其余遗留问题和 allowlist 仍是后续重构输入，不应把下文旧调用顺序误读为当前实现。

原审计基准是 [`OWNERSHIP-CONSTITUTION_cn.md`](../OWNERSHIP-CONSTITUTION_cn.md) 的 `A = O ⊎ S`、`P = π(O,S)`，以及当时代码实际行为。实施证据随后把权威集合修正为 `A = O ⊎ S ⊎ R`，其中 `R` 仅指 durable unresolved conflict/recovery facts；该修订不改变本文对 Document/Semantic 写入越界的判断。严重性定义：

- **P0**：可破坏事实所有权或失败原子性，应先阻止新增调用并修正；
- **P1**：持续制造重复语义和跨模块耦合，已明显增加改动风险；
- **P2**：结构债务或文档债务，短期不一定产生错误，但妨碍继续演化。

## 1. 三个预检问题

### 1.1 这是真问题还是想象的问题？

是真问题。代码中同时存在：Store-first 与 Org-first 删除顺序、多套 mutation API、两代 automation 事件路径、三套 filter/sort 实现，以及 UI 对 query 私有函数的调用。这些都不是目录审美问题，而是可定位到具体函数的行为差异。

### 1.2 有更简单的做法吗？

有。无需更换数据库、无需引入 Repository 层、无需重写全部 renderer。最短路径是：

1. 让 Document Commands 和 Semantic Commands 成为唯一公开写入口；
2. 用一个内部 commit kernel 产生一种 canonical change；
3. 保留现有 Projector、View Runtime、Index、Persistence；
4. 迁移调用者后删除旧通用入口。

### 1.3 会破坏什么？

直接删除旧 API 会破坏 automation、旧 query block、第三方调用和部分兼容测试。因此重构必须先加 contract/static guard，再做兼容桥，最后按调用数归零删除。第三篇给出具体迁移门槛。

## 2. P0：Document Fact 的写入顺序仍可被绕过

所有权宪法要求 Document Command 执行：修改 Org、保存 Org、再投影；保存失败时 Projection 必须保持不变。Org service 已经正确实现了这个顺序，[`supertag-service-org.el:320`](../../supertag-service-org.el#L320)。但公开 UI 命令仍有相反路径。

### 2.1 创建 Node：写了 Org，却直接创建 Projection

`supertag-create-node` 在 heading 上确保 ID 后直接调用 `supertag-node-create`；新建 heading 分支也是插入文本、确保 ID、直接创建 Store node，[`supertag-ui-commands.el:198`](../../supertag-ui-commands.el#L198)。函数没有在成功保存后调用统一 Projector。

风险不是“可能忘记 save”这么简单：

- Store 中可能出现尚未持久化到 Org 的 node；
- 后续 reindex 会按磁盘事实删除或改写该 projection；
- create 路径与 tag mutation 的 Org-first 语义不一致。

### 2.2 删除 Node：先删除 Store，再删除并保存 Org

`supertag-delete-node` 的明确顺序是：

```text
supertag-node-delete -> delete-region -> save-buffer
```

证据见 [`supertag-ui-commands.el:245`](../../supertag-ui-commands.el#L245)。如果 `save-buffer` 因只读文件、磁盘错误、hook 异常而失败，Org 仍拥有这个节点，但 Projection 和相关 relation 已被删除。这里没有跨 Store/文件系统的共同事务可以回滚。

正确顺序应是：先在 buffer 中完成可恢复编辑，保存成功，再让 Projector 根据新文档事实做 projection reconciliation。若保存失败，Store 根本不应开始变更。

### 2.3 “退回普通标题”：删除 Projection 和 ID，却不保存/投影

`supertag-back-to-heading` 先 `supertag-node-delete`，再删除 Org 的 `ID` property，但没有 save 和统一重投影，[`supertag-ui-commands.el:281`](../../supertag-ui-commands.el#L281)。它同时写了两个 owner，却没有任何一个 owner 的完整命令协议。

### 2.4 删除 Tag everywhere：先删除语义与 Projection，最后修改文档

`supertag-ops-delete-tag-everywhere` 先遍历删除 relation/membership，再删除 Tag definition，最后才从 Org 文件移除 token，[`supertag-ops-tag.el:567`](../../supertag-ops-tag.el#L567)。任一文件修改失败都会得到“文档仍引用 Tag，但语义 Tag 已消失”的中间状态。

这个操作跨越两个 owner，本来就不能伪装成一个 Store transaction。应显式建模为可计划、可验证的 migration：先生成变更集和快照，修改并保存全部文档，完成后再删除 semantic Tag；失败时保留语义事实并报告未完成文件。

### 2.5 公开 projection mutation 让正确路径不具强制性

`supertag-ops-add-tag-to-node` 文档明确声明“不修改 buffer”，但它会直接更新 node tag 和 relation，[`supertag-ops-tag.el:622`](../../supertag-ops-tag.el#L622)。这与“Tag occurrence 属于 Org、membership 是 projection”冲突。

问题不是函数实现得不够谨慎，而是这个公开能力本身不应存在于 Document Command 之外。即使当前调用很少，只要它存在，未来代码就会继续绕过 owner。

## 3. P0：写入入口和事件语义没有真正统一

当前至少存在四种可写路径：

1. `supertag-store-put/remove` 等原始 Store API；
2. `supertag-update/delete` 等通用实体 API；
3. `supertag-transform` / `supertag-with-transaction`；
4. `supertag-ops-commit`。

`supertag-ops-commit` 位于 Store 文件中，既包装 operation result/hook，又发送 `:store-committed` 和 `:store-changed`，[`supertag-core-store.el:599`](../../supertag-core-store.el#L599)。但并非所有领域写入都经过它。

最直接的自证来自 automation 配置：`supertag-automation-sync-use-commit-hooks` 默认关闭，因为仍有 global field value 等 legacy direct Store updates 不经过 `supertag-ops-commit`，[`supertag-automation-sync.el:29`](../../supertag-automation-sync.el#L29)。

`supertag-field-set` 的注释声称通知由 unified commit system 处理，[`supertag-ops-field.el:58`](../../supertag-ops-field.el#L58)，实际代码却只进入 transaction，然后手动调用 automation 的私有函数 `supertag-automation-sync--process-global-field-change`，[`supertag-ops-field.el:65`](../../supertag-ops-field.el#L65)。这造成三个后果：

- transaction 原子性与“下游看见一次 commit”的语义脱节；
- automation 是否运行取决于写入走了哪条路径；
- Ops 反向依赖 Automation 私有实现。

按当前 checkout 执行 `rg -n '\(supertag-store-' -g 'supertag*.el' -g '!supertag-core-*.el'`，可得到 **215 个匹配行**，分布在 **23 个**顶层非 core 生产模块。不是每个调用都错误——其中包含合理的读操作——但这个数量证明 Store 尚未成为少数边界模块封装的实现细节。

## 4. P1：Automation 同时运行两代传播模型

Automation 当前保留了旧异步 queue、同步 event router、commit hook 选项、`:store-changed` subscription 和若干直接私有回调。

- legacy queue 被标记 deprecated，但仍完整存在，[`supertag-automation.el:1045`](../../supertag-automation.el#L1045)；
- Store change 被重新翻译后交给 sync engine，[`supertag-automation.el:1067`](../../supertag-automation.el#L1067)；
- init 每次都订阅 `:store-changed`，[`supertag-automation.el:1471`](../../supertag-automation.el#L1471)；
- subscribe 本来会返回 unsubscribe closure，[`supertag-core-notify.el:21`](../../supertag-core-notify.el#L21)，但 init 没保存它；cleanup 也没有取消订阅，[`supertag-automation.el:1494`](../../supertag-automation.el#L1494)；
- 文件加载末尾自动执行 init，[`supertag-automation.el:1504`](../../supertag-automation.el#L1504)。

因此重复交互调用 init 可能累积 subscriber；cleanup 之后 callback 仍驻留，只靠 enabled flag 避免部分行为。这是明确的生命周期所有权漏洞。

更深的问题是 Automation 不知道自己订阅的是“物理 Store path 发生变化”，还是“一个领域 operation 已提交”。前者太细，可能一次领域操作触发多次；后者当前又不能覆盖所有写入。没有 canonical change contract，去重、递归保护和失败策略都会变成特例。

## 5. P1：Query 文件包含四个不同抽象层

`supertag-services-query.el` 当前同时承担：

1. concrete Query Model：按 Tag、Node、Relation 读取领域对象，[`supertag-services-query.el:22`](../../supertag-services-query.el#L22)；
2. arbitrary collection query：对任意 Store collection 查询，[`supertag-services-query.el:216`](../../supertag-services-query.el#L216)；
3. S-expression Query DSL 的 parser/evaluator/modifier，[`supertag-services-query.el:247`](../../supertag-services-query.el#L247)；
4. view config filtering/sorting/grouping 和 builder，[`supertag-services-query.el:789`](../../supertag-services-query.el#L789)。

这不是单纯“1139 行太长”，而是变化原因不同：领域 read model 随 schema/ownership 变化，DSL 随语法变化，排序随 UI/value semantics 变化，builder 随配置 API 变化。把它们放在同一 public namespace，会迫使调用者挑选内部工具。

实际已经发生越界：`supertag-query-block.el` 包装并调用 query 模块的 `--sort-value`、`--numeric`、`--value<` 私有函数，[`supertag-query-block.el:122`](../../supertag-query-block.el#L122)。同时：

- Query Engine 有自己的 numeric/value comparison 和 sort；
- Query Block 为 header sort 再实现一套；
- Table View 又有自己的 filter/sort/compare，[`supertag-view-table.el:413`](../../supertag-view-table.el#L413)、[`supertag-view-table.el:461`](../../supertag-view-table.el#L461)。

同一个值在 query、query block 和 table 中可能得到不同 null、number/string、ascending/descending 顺序。这里应该只有一套 value semantics，由 Query Engine 返回已排序/过滤的 result，而 renderer 只表达用户意图。

## 6. P1：层名与真实依赖方向不一致

当前 require graph 没有语法级循环，这是好事；但命名所暗示的层次并不成立。静态依赖中可见：

```text
core-scan     -> ops-node, ops-tag
ops-embed     -> services-query
ops-node      -> service-node-identity
ops-tag-merge -> view-helper
services-embed-> ui-embed
services-ui   -> view-api
service-org   -> view-helper
```

其中最危险的不是 `core` 依赖 `ops` 这个名字不好看，而是底层模块为了完成任务开始调用上层 helper，导致 helper 隐含成为领域服务。`ops-tag-merge -> view-helper` 与 `services-embed -> ui-embed` 都说明行为被放在了错误 owner 中。

应按 domain capability 重画边界，而不是继续争论 `core/ops/service` 应该排第几层。只要 Document Projector、Semantic Commands、Query Engine、View Runtime 的方向清楚，文件前缀可以最后再处理。

## 7. P1：浅接口增加了导航成本，却没有隐藏复杂度

`supertag-view-api.el` 约 167 行、11 个 public function，多数只是把参数原样传给 query service，[`supertag-view-api.el:31`](../../supertag-view-api.el#L31)。它没有拥有缓存、一致性、事务、结果类型或兼容策略，调用者仍需理解 query 的数据形状。

按深模块的删除测试：删除这个文件并让调用者直接依赖稳定 Query Model，系统概念会减少，隐藏能力几乎不损失。因此它更像命名转发层，而不是 adapter。

相反，`supertag-view-framework.el` 应保留：它确实隐藏 registry、instance、subscribe、render rollback、refresh、selection 和 cleanup，[`supertag-view-framework.el:32`](../../supertag-view-framework.el#L32)、[`supertag-view-framework.el:137`](../../supertag-view-framework.el#L137)。删除它会把复杂状态机复制回每个 renderer。

## 8. P2：Store 与 Transform 内部仍携带历史数据形状

Store 的通用 path 模型通常只有 collection/id 两层，但 field value 是二层键，legacy nested `:fields` 又有特殊恢复逻辑，[`supertag-core-store.el:241`](../../supertag-core-store.el#L241)、[`supertag-core-store.el:287`](../../supertag-core-store.el#L287)。Transform rollback 也必须按 path shape 分发，[`supertag-core-transform.el:62`](../../supertag-core-transform.el#L62)。

这部分目前有 transaction tests 保护，不应贸然“清理得更漂亮”。但它应被标记为 migration compatibility，而不是永久领域模型。只有在持久化迁移证明旧 shape 已归零后，才能删除特例。

同一 Transform 文件后半还包含 inline Org tag parser，[`supertag-core-transform.el:258`](../../supertag-core-transform.el#L258)。解析 Org 语法与 transaction rollback 没有共同变化原因，应移动到 Projector/extractor 内部；这属于低风险的内聚性修复。

## 9. P2：部分公开能力很可能已经死亡

静态引用仅命中定义文件的接口包括：

- `supertag-transform-pattern`；
- `supertag-batch-transform`；
- `supertag-ops-add-tag-to-node`；
- query builder 的 `from/where/order-by/limit/execute`；
- `supertag-query-get-all-data`。

“仓库内无调用”不等于可以立刻删除——它们可能被用户配置或插件调用。但这已经足够触发 deprecation audit：记录 usage、发布 warning、给替代 API，再在明确版本边界删除。继续保留而不声明状态，只会让维护者误以为这些都是必须兼容的主路径。

## 10. P2：文档描述滞后于实际架构

[`COMPARE-NEW-OLD-ARCHITECHTURE_cn.md`](../COMPARE-NEW-OLD-ARCHITECHTURE_cn.md) 仍把 Store 描述为单一事实源，并引用约 14,165 行代码；当前 checkout 的顶层 `supertag*.el` 已有 41,924 行（`HEAD` 为 41,923），所有权宪法也明确 Store 同时容纳 semantic facts 与 document projections。

错误文档会产生真实代码后果：开发者按“Store 是唯一真相”新增 mutation 时，会自然绕过 Org-first 协议。因此架构文档不是总结材料，而是 API 设计约束的一部分。

## 11. 已经正确、不应被误伤的模块

问题审计必须明确保护范围：

### 11.1 Store-first Node Identity

`supertag-service-node-identity.el` 明确拥有运行时 node identity 解析，[`supertag-service-node-identity.el:1`](../../supertag-service-node-identity.el#L1)。Store 有 projection 但定位损坏时 fail closed；只有 Store 完全没有该节点时才允许兼容性的 `org-id` fallback，[`supertag-service-node-identity.el:125`](../../supertag-service-node-identity.el#L125)。这个 seam 应继续加深，不能把 fallback 重新散回 UI。

### 11.2 Complete-snapshot Reindex

同步器不拿半次扫描结果覆盖 Store，[`supertag-services-sync.el:2141`](../../supertag-services-sync.el#L2141)。这是 destructive reconciliation 的正确模型。

### 11.3 Generation-based Derived Index

索引按 revision/rebuild generation 管理，可在失败时整体清空，[`supertag-core-index.el:187`](../../supertag-core-index.el#L187)。不应为了“实时”把索引升级为第二事实源。

### 11.4 Unified View Runtime

Runtime 已经拥有 lifecycle。可以在内部拆 widget/config persistence，但不能给 Table/Stream/Kanban 再建平行 open/refresh/cleanup 框架。

### 11.5 Canonical Atomic Persistence

持久化会验证所有 durable collection，[`supertag-core-persistence.el:963`](../../supertag-core-persistence.el#L963)，并在验证临时快照后原子替换，[`supertag-core-persistence.el:1429`](../../supertag-core-persistence.el#L1429)。它代码较大，但接口深、失败语义清楚，不是优先拆分对象。

## 12. 根因，不是症状

把上面的问题压缩后，只有三个根因：

### 根因 A：所有权模型晚于大量 API 出现

旧 API 假设“Store 就是真相”，新模型区分 `O`、`S`、`P`。新模型已经写进同步器和测试，却没有撤销旧 API 的权限。

### 根因 B：新抽象增加了，但旧抽象没有退休

commit pipeline 出现后 direct Store update 还在；sync automation 出现后 legacy queue 还在；Query Model 出现后 generic builder 还在；View Runtime 出现后浅 View API 还在。

### 根因 C：兼容策略没有单独建模

legacy path、event、query builder 和 fallback 直接混在主实现中，没有 bridge 名称、使用计数和删除条件。于是“暂时兼容”自动变成永久复杂度。

## 13. 优先级与验收指标

| 优先级 | 问题 | 首要验收指标 |
|---|---|---|
| P0 | Document Command 顺序 | 保存失败时 Store projection 字节级/结构级不变 |
| P0 | 多写入/多事件入口 | 所有领域写入产生恰好一个 canonical committed change |
| P1 | Automation 双代模型 | 单一 subscription owner；init 幂等；cleanup 后零 callback |
| P1 | Query 职责与排序重复 | renderer 不调用 query 私有函数；value semantics 只有一份 |
| P1 | 伪分层依赖 | Projector/Semantic/Query/View 依赖方向通过静态 guard |
| P2 | legacy shape/dead API | 每个兼容入口都有调用数、替代项、删除 gate |
| P2 | 过时文档 | 文档统一使用 `O ⊎ S` / `P = π(O,S)` |

## 14. 最终判断

值得做，而且应从 P0 开始小步做。原因不是追求“更漂亮的架构”，而是当前同一次用户动作可能按不同入口得到不同持久化、事件与自动化结果。

也不值得重写。Store、transaction、Projector、Index、View Runtime、Persistence 已经承担了最难的正确性工作。最佳重构是收紧权力：把 Document Fact、Semantic Fact 和 Projection 的写入分别收敛到唯一 owner，让下游只消费一个提交事实，然后删除已经被替代的旧路。
