The legacy schema/table/kanban/search/capture entry points described here are archived; see README for the current workflow.

# Supertag 架构演化：从几个简单事实到复杂系统

> 结论先行：Supertag 的复杂度并不是一次设计出来的。它从“Org 标题 + ID + Tag + Property + Link”这几个简单事实出发，依次补上内存 Store、事务、查询、同步、派生索引、持久化、自动化和 View Runtime。大部分复杂度都有真实需求和演化依据；真正值得警惕的不是模块数量，而是新抽象建立后，旧入口仍可绕过它。

本文只回答“系统如何长成今天这样”。问题判断见 [02-architecture-problems.md](./02-architecture-problems.md)，重构方案见 [03-refactoring-plan.md](./03-refactoring-plan.md)。

## 1. 最小模型：Org 文档事实与语义事实

系统最初可还原为五个朴素概念：

1. Org heading 是人编辑的内容单元；
2. `ID` 给 heading 稳定身份；
3. Tag 表达类型；
4. Property/field 表达结构化值；
5. Org link 或 relation 连接两个节点。

今天的代码虽然已经很大，底层仍然围绕这些概念组织。Store 的根集合明确区分了 `:nodes`、`:tags`、`:relations`、`:field-values`、`:views`、`:automations` 等数据，[`supertag-core-store.el:21`](../../supertag-core-store.el#L21)；Store 再用统一的 collection/entity API 提供存取能力，[`supertag-core-store.el:97`](../../supertag-core-store.el#L97)。

后来的所有权模型把这组直觉形式化为：

```text
A = O ⊎ S ⊎ R
P = π(O, S)
```

- `O`（Document Facts）：ID、标题、正文、层级、TODO、Tag occurrence、物理 Org link；
- `S`（Semantic Facts）：稳定 Tag、schema、field value、semantic edge、board、automation、持久化 query/view；
- `R`（Operational Facts）：无法从 O/S 重建、必须保存到显式处理完成的冲突/恢复事实；当前实例是 `:sync-conflicts`；
- `P`（Projection）：从 `O` 与 `S` 投影出的 node、membership、document-link 等可重建数据。

这不是后来硬套的理论。同步器确实把文本中的 tag occurrence 解析成稳定语义 Tag，并记录无法解析的 occurrence，[`supertag-services-sync.el:842`](../../supertag-services-sync.el#L842)；relation 也明确以 `kind/origin` 区分 document link、field reference 和 semantic edge，[`supertag-ops-relation.el:324`](../../supertag-ops-relation.el#L324)。

## 2. 第一层：用一个小 Store 统一数据形状

第一个关键抽象不是数据库，而是一个内存 Store：所有实体进入具名 collection，调用者按 collection 和 id 读取。它让“Tag、Node、Relation 看起来完全不同”的问题，先收敛为同一种物理存储模型。

当前实现仍保留这条主线：

- `supertag-store-get-collection` / `supertag-store-get` 是低层读取接口，[`supertag-core-store.el:97`](../../supertag-core-store.el#L97)；
- `supertag-get` / `supertag-update` / `supertag-delete` 是较通用的实体接口，[`supertag-core-store.el:496`](../../supertag-core-store.el#L496)；
- field value 因为是 `(node-id, field-id)` 二元身份，采用二层结构，[`supertag-core-store.el:241`](../../supertag-core-store.el#L241)。

这个抽象的杠杆很高：持久化、查询、索引和事务都可以围绕同一物理形状工作。但它只统一了“怎么存”，没有回答“谁有权写”。这个缺口后来成为当前架构的主要问题。

## 3. 第二层：把任意更新变成可回滚变换

当系统开始同时更新 node、relation 和 field value，单次 `put` 已不够。`supertag-core-transform.el` 引入了两个小概念：

```elisp
(supertag-transform path fn)
(supertag-with-transaction ...)
```

基本 transform 读取旧值、计算新值并写回，[`supertag-core-transform.el:19`](../../supertag-core-transform.el#L19)；事务记录 first-touch 旧值，在异常时逆序恢复，并支持嵌套事务与通知延迟刷新，[`supertag-core-transform.el:154`](../../supertag-core-transform.el#L154)。索引模块还注册 rollback hook，使数据回滚时派生索引不会停留在错误状态，[`supertag-core-index.el:281`](../../supertag-core-index.el#L281)。

这一步把“多次写入”组合成一个原子操作，是复杂系统能继续增长的基础。2026-07-13 的提交 `b561ca9` 专门把此前名义上的 transaction 补成了真实 rollback；这说明事务不是预先设计的装饰，而是被实际失败场景逼出来的边界。

## 4. 第三层：Ops 和 Services 把物理 Store 翻译成领域动作

纯 Store API 无法表达“创建关系”和“给节点加 Tag”的不变量，于是系统在其上建立 Ops：

- node create/update/delete 和 membership 位于 [`supertag-ops-node.el:52`](../../supertag-ops-node.el#L52)；
- relation 使用确定性 ID 去重，并同步索引，[`supertag-ops-relation.el:208`](../../supertag-ops-relation.el#L208)；
- semantic edge、document link、field reference 共享 relation 物理模型，但通过 `kind/origin` 保留所有权差异，[`supertag-ops-relation.el:324`](../../supertag-ops-relation.el#L324)。

Services 再组合 Ops，面向用户场景提供更深接口。例如 Org service 的 tag mutation 路径不是直接更新 membership，而是：编辑 Org buffer、保存文件、再投影 Store，[`supertag-service-org.el:320`](../../supertag-service-org.el#L320)、[`supertag-service-org.el:381`](../../supertag-service-org.el#L381)。调用者不需要知道保存、内部修改标记、field 生命周期和重投影细节。

这里已经出现了成熟的“深模块”：接口小，隐藏的正确性工作多。

## 5. 第四层：同步器成为 Document Projector

Org 是可被外部编辑的文本，Store 不能靠命令路径保持一致，因此系统需要 Projector。同步器的职责逐步扩大为：

1. 扫描 Org 文件；
2. 提取 heading、ID、tag occurrence、property 和 link；
3. 解析稳定 Tag；
4. 与 Store 中的 projection 做 reconcile；
5. 删除来源消失的 document-owned projection；
6. 保留 semantic facts。

节点 reconcile 的核心位于 [`supertag-services-sync.el:842`](../../supertag-services-sync.el#L842)，document link 的 ownership-aware reconcile 位于 [`supertag-services-sync.el:1744`](../../supertag-services-sync.el#L1744)。完整 reindex 先建立 complete snapshot，再在事务中替换 projection；扫描不完整会中止，避免用部分世界删除正确数据，[`supertag-services-sync.el:2141`](../../supertag-services-sync.el#L2141)。

这一步非常关键：系统从“命令执行器”变成了“可从源事实恢复的投影系统”。Store 中的 node/membership 不再必须被当作第二份真相。

## 6. 第五层：先用扫描获得正确语义，再按证据加索引

查询层并不是一开始就追求复杂索引。历史上，2025-09-17 的 `520edd1` 明确用 scan-based query 替换复杂索引：先把查询语义做对，再优化热点。这是非常健康的演化顺序。

当规模证明扫描成为瓶颈后，2026-03-03 的 `648ca7d` 才加入 relation/tag 派生索引。当前索引用 Store revision 判断新鲜度，[`supertag-core-index.el:38`](../../supertag-core-index.el#L38)，集中维护 relation/tag 反向查询结构，[`supertag-core-index.el:104`](../../supertag-core-index.el#L104)，并把 clear/rebuild 作为一个 generation 操作，[`supertag-core-index.el:187`](../../supertag-core-index.el#L187)。

因此索引的正确定位是：

```text
Store facts -> Derived indexes -> Faster reads
```

而不是第二份权威数据。失败时清空整代索引并退回可重建状态，比修补若干可能互相矛盾的 bucket 更简单。

## 7. 第六层：查询从 Store 遍历发展为 Query Model 和 DSL

需求随后分成两类：

- 稳定、具体的领域读取，例如按 Tag 查 node、读取 node detail；
- 用户可配置的查询表达式、过滤、排序、分组和 view 配置。

目前两类能力都集中在 `supertag-services-query.el`：文件开头的 concrete reads 是面向调用者的 Query Model，[`supertag-services-query.el:22`](../../supertag-services-query.el#L22)；后半部分逐步长出了 S-expression parser/evaluator，[`supertag-services-query.el:247`](../../supertag-services-query.el#L247)，以及通用 view filtering/sorting/builder，[`supertag-services-query.el:789`](../../supertag-services-query.el#L789)。

它说明系统通过复用一个读模型支持了 UI、View 和 Automation；也说明增长已经越过一个模块能维持内聚性的临界点。后者属于结构问题，不否定前者的演化价值。

## 8. 第七层：事件把写入结果连接到索引、自动化和视图

随着下游消费者增加，写操作不能逐个调用所有后续模块。`supertag-ops-commit` 把 operation 包起来，产生 operation result、调用 after-operation hook，并发出 Store 事件，[`supertag-core-store.el:599`](../../supertag-core-store.el#L599)。通知系统用 topic/subscriber 解耦生产者和消费者，而且 subscribe 会返回 unsubscribe closure，[`supertag-core-notify.el:21`](../../supertag-core-notify.el#L21)。

自动化在事件之上匹配条件并执行 action；View Runtime 则订阅变更并刷新实例。这个方向是合理的：上游发布“发生了什么”，下游自行决定反应。但当前同时保留旧事件、commit hook 和直接回调，导致同一事实有多种传播方式，问题详见第二篇。

## 9. 第八层：View Framework 从多个页面收敛为一个 Runtime

Table、Node、Stream、Kanban 等视图最初各自容易拥有打开、刷新、选择、清理、订阅等生命周期。2026-08-04 的 `3e652a7` 把这些公共职责收敛到统一 Runtime：

- registry/runtime instance：[ `supertag-view-framework.el:32`](../../supertag-view-framework.el#L32)；
- register/open/render/subscribe/display 与失败回滚：[ `supertag-view-framework.el:75`](../../supertag-view-framework.el#L75)、[`supertag-view-framework.el:137`](../../supertag-view-framework.el#L137)；
- refresh state 与 selection 恢复：[ `supertag-view-framework.el:387`](../../supertag-view-framework.el#L387)；
- renderer 通过 adapter 接入，不另建生命周期。

这是当前代码中最典型的组合式复杂系统：每个 renderer 只处理自己的视觉语义，Runtime 统一处理横切生命周期。历史提交当时通过了 381/381 ERT，也证明收敛不是只改了目录名。

## 10. 第九层：持久化把内存模型变成可验证快照

持久化没有把 Lisp object 直接随意 dump 到文件，而是建立确定性、逐实体的 canonical 格式，[`supertag-core-persistence.el:996`](../../supertag-core-persistence.el#L996)。保存流程在同目录生成临时文件、重新读取并验证全部 durable roots，成功后才原子 rename，[`supertag-core-persistence.el:1429`](../../supertag-core-persistence.el#L1429)；加载失败时 fail closed，成功后统一重建派生索引，[`supertag-core-persistence.el:1725`](../../supertag-core-persistence.el#L1725)。

这把“能保存”提升为“不会用半写快照覆盖上一份正确状态”。与 transaction、complete snapshot reindex、generation index 一起，它们构成系统的失败安全骨架。

## 11. 历史演化证据

以下数据由当前仓库 `git log`、`git show --stat` 与各里程碑提交下的 `git ls-tree`/行数统计得到。它不是按目录名猜测架构，而是代码实际增长轨迹。

| 时间/提交 | 规模（顶层 `supertag*.el`） | 架构变化 | 设计含义 |
|---|---:|---|---|
| 2025-09-06 `441e51c` | 34 文件 / 12,490 行 | 5.0 纯 Elisp 重写，移除 Python 路径，建立 store/transform/ops/services/ui | 先统一执行模型，减少跨语言状态 |
| 2025-09-17 `520edd1` | 37 / 13,956 | scan-based query 替代复杂索引 | 用简单正确实现确定查询语义 |
| 2025-10-14 `a5fa5e3` | 39 / 16,374 | 统一 commit pipeline 与同步自动化 | 下游开始依赖变更事件 |
| 2026-03-03 `648ca7d` | 53 / 27,269 | 加入 relation/tag 派生索引 | 性能证据出现后再引入缓存复杂度 |
| 2026-07-13 `b561ca9` | 57 / 30,668 | transaction 获得真实 rollback | 失败原子性成为一等约束 |
| 2026-08-04 `3e652a7` | 63 / 37,826 | View lifecycle 收敛为统一 Runtime | 删除多个 renderer 的并行状态机 |
| 2026-08-12 `941e4bf` | 64 / 38,772 | 所有权宪法落地 | 正式区分 Document Fact、Semantic Fact、Projection |
| 2026-08-24 `b7d0445` | 65 / 41,896 | Store-first node identity boundary | 身份解析从多处 Org 回退收敛到一个 seam |
| 2026-08-24 `50b37f7`（HEAD） | 65 / 41,923 | create-and-reference relation-safe | 最新修复继续把 relation 不变量留在领域操作内 |

最有代表性的 `441e51c` 是“大删大建”：提交统计约为 16,710 insertions、31,840 deletions。复杂系统并非线性堆代码；曾经通过删除错误边界重建过一次。

## 12. 当前分层地图

按职责而不是文件前缀，系统可画成：

```text
Interactive Commands / Renderers
          |               |
          v               v
 Document Commands    View Runtime
          |               ^
          v               |
      Org files       Query Model / Engine
          |               ^
          v               |
 Document Projector ------+
          |
          v
 Semantic/Projection Operations
          |
          v
 Transaction + Store + Canonical Event
          |
    +-----+------+----------------+
    v            v                v
 Derived Index  Persistence    Automation
```

当前 checkout（含进入本任务前已有的未提交修改）有 65 个顶层 Elisp 文件、41,924 行；`HEAD` 是 41,923 行。按主要职责粗分：core 约 5k、ops 约 4k、services 约 6.5k、views 约 8.1k、automation 约 2.5k，另有 persistence、migration、git/merge 等独立复杂域。规模本身不是罪证；真正的架构质量取决于箭头是否单向、接口是否能隐藏下层复杂度。

## 13. 演化中已经形成的正确原则

当前系统值得保留的不是文件布局，而是以下经代码与测试证明的原则：

1. **先简单后优化**：scan query 在索引之前；索引只是可重建 projection。
2. **失败时保持旧正确状态**：事务 rollback、complete snapshot、atomic persistence。
3. **源事实只有一个 owner**：Org-first mutation 与 `O ⊎ S` 所有权模型。
4. **生命周期只应有一个 owner**：View Runtime 收敛打开、刷新、订阅与清理。
5. **身份解析必须 fail closed**：Store 有 projection 但已损坏时，不偷偷用 Org fallback 掩盖错误，[`supertag-service-node-identity.el:125`](../../supertag-service-node-identity.el#L125)。
6. **复杂性应藏在深模块内**：调用 Org service 的人不需要手动排序“编辑、保存、投影”；调用 persistence 的人不需要手动验证临时快照。

因此下一步不应推倒重来。应当让已经存在的正确模型成为唯一道路，并删除仍能绕行的旧路。

## 14. 复核方式

历史规模与模块依赖可用以下只读命令复核：

```sh
git show --stat 441e51c
git show --stat 520ed1
git show --stat b561ca9
git show --stat 3e652a7
find . -maxdepth 1 -type f -name 'supertag*.el' | wc -l
find . -maxdepth 1 -type f -name 'supertag*.el' -exec wc -l {} +
rg '^\(require ' -g 'supertag*.el'
```

这些证据共同支持本文的核心判断：Supertag 的复杂能力来自一系列小模型的组合；现在的问题是组合关系需要再次收敛，而不是模型本身需要被全部替换。
