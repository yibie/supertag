The legacy schema/table/kanban/search/capture entry points described here are archived; see README for the current workflow.

# Supertag 最终架构：双业务事实与窄 Operational Fact 下的投影系统

> 状态：K3 已实施；C1–C5 与 M2b 完成；Canonical Change 已由
> `supertag-board-create` 作为唯一生产 tracer writer 启用，尚无生产
> Canonical consumer。
>
> 本文综合 [系统演化](./01-system-evolution.md)、[问题审计](./02-architecture-problems.md) 与 [渐进重构计划](./03-refactoring-plan.md)。它定义重构后的稳定架构契约，不要求一次完成所有物理文件重排。

## 1. 一句话架构

Supertag 是一个以 **Org 文档事实**、**语义事实**与窄定义的**操作事实**为权威，以 Store 承载语义/操作事实和可重建投影，并由 Query/Automation/View 消费统一提交结果的本地知识系统。

```text
Authoritative State = Document Facts ⊎ Semantic Facts ⊎ Operational Facts
Projection          = project(Document Facts, Semantic Facts)
```

Operational Fact 只指无法从前两类事实重建、且必须保留到显式处理完成的冲突/恢复记录；它不是 runtime state 的收容箱。系统不是“Store 为唯一真相”的 CRUD 应用，也不是“每次查询都重新解析 Org”的文本工具。它是双业务事实源、窄操作事实、单向投影、可重建索引和可验证持久化的组合。

## 2. 设计目标

### 2.1 必须实现

- 用户可继续直接编辑 Org，reindex 后结果确定；
- Tag/schema/field/semantic edge 等语义事实不会被文档扫描误删；
- 保存失败、投影失败、持久化失败时保留上一个正确状态；
- 一个领域操作只对下游可见一次；
- Query、Automation 和 View 对同一数据使用相同值语义；
- 新能力通过组合已有深模块增加，不通过复制生命周期或写入路径增加。

### 2.2 非目标

- 不引入 SQLite、远程数据库或通用 Repository；
- 不支持多主实时协同事务；
- 不保证 Org 文件写入与 Store 内存事务跨介质原子提交；
- 不在本轮更改持久化格式；
- 不创建第二套 View Runtime 或 Query DSL。

## 3. 架构公理

### A1. 事实所有权互斥

每个持久事实恰好有一个 owner：Document、Semantic，或窄定义的 Operational owner。Projection 无独立所有权。

### A2. 文档优先落盘

Document Command 必须先编辑并成功保存 Org，再更新 Projection。保存失败时 Store 不变。

### A3. Projection 可全量重建

删除所有 Projection 和 Derived Index 后，仅凭完整 Org snapshot 与 Semantic Facts 能恢复同一可观察结果。

### A4. Semantic Command 不写 Org

Semantic Fact 的变更不隐式改动用户文档。确实需要跨 owner 的操作必须建模为 migration/workflow，而不是一个假事务。

### A5. 权威方与变更范围正交

每次 change 分别声明 `authority`（`:document` / `:semantic` / `:operational`）和 `scope`（`:fact` / `:projection` / `:fact+projection`）。不得用一个枚举同时表达两件事。`:operational` 只允许不可重建的冲突/恢复事实；普通运行时状态仍使用 lifecycle notification，不进入领域 commit schema。

### A6. 领域提交只发布一次

成功 operation 产生一个 canonical committed change；rollback、no-op 不发布成功事件。

### A7. 下游不反向写底层

View 和 Automation 只能调用 Document/Semantic Commands，不能直接写 Store 或 Projection。

### A8. 兼容性必须可删除

每个 legacy bridge 必须有替代项、使用计数、期限与删除 gate。

## 4. 领域数据模型

### 4.1 Document Facts (`O`)

| 事实 | 物理来源 | 稳定身份/键 | 修改者 |
|---|---|---|---|
| Node existence | 带 ID 的 Org heading | Org ID | Document Command / 用户外部编辑 |
| title/body/topology/TODO | Org text | node ID + 文档位置 | Document Command / 用户外部编辑 |
| tag occurrence | Org tag text | occurrence + resolved Tag ID | Document Command / 用户外部编辑 |
| physical Org link | Org link text | source ID + link position/target | Document Command / 用户外部编辑 |

用户可绕过 Emacs 命令直接编辑文件，因此 Projector 必须始终能从完整文档事实恢复 Projection。

### 4.2 Semantic Facts (`S`)

| 事实 | Store collection（当前） | 修改者 |
|---|---|---|
| stable Tag identity/schema | `:tags` / field definitions | Semantic Command |
| global field value | `:field-values` | Semantic Command |
| semantic edge | semantic-owned `:relations` | Semantic Command |
| board/automation/query/view config | 对应 durable collection | Semantic Command |

Semantic Facts 不依赖某个 Tag token 此刻是否出现在文档中。reindex 不得创建普通 Semantic Tag；仅显式 migration 可从 occurrence 建立稳定 Tag。当前 Projector 已把 Tag entity creation 限制为 migration 路径，[`supertag-services-sync.el:1703`](../../supertag-services-sync.el#L1703)。

### 4.3 Operational Facts (`R`)

| 事实 | Store collection（当前） | 创建/终止 owner |
|---|---|---|
| unresolved sync conflict | `:sync-conflicts` | merge 产生确定性冲突记录；conflict resolution 显式解决或丢弃 |

该事实不能从 merge 后的 winner 反推出 ours/theirs/base，因此在解决前不可删除；持久化只负责保存它，不拥有冲突生成或解决语义。具体证据见 [`supertag-merge.el:433`](../../archive/git/supertag-merge.el#L433)、[`supertag-conflicts.el:431`](../../archive/git/supertag-conflicts.el#L431) 与 [`supertag-core-persistence.el:1194`](../../supertag-core-persistence.el#L1194)。新增 Operational Fact 必须另行证明同样的“不可重建 + 明确终止生命周期”，不得仅因数据难分类而使用该 authority。

### 4.4 Projections (`P`)

| Projection | 由什么推导 | 删除/重建 owner |
|---|---|---|
| node record | heading + ID + semantic resolution | Document Projector |
| node-tag membership | tag occurrence + stable Tag | Document Projector |
| document link relation | physical Org link | Document Projector |
| field-reference relation | semantic field value | Semantic relation reconciler |
| unresolved occurrence | Org token + 当前 semantic resolution | Document Projector |

Relation 的物理集合可共享，但每条 relation 必须携带可判定的 `kind/origin`，使 reconcile 只删除自己拥有的 projection。当前 relation 已有该方向的实现，[`supertag-ops-relation.el:324`](../../supertag-ops-relation.el#L324)。

### 4.5 Derived Index (`I`)

Index 是 Projection/Fact 的性能函数：

```text
I = index(O, S, P)
```

Index 不持久化为第二真相；revision 不匹配时失效；cold rebuild 必须得到与增量更新一致的查询结果。当前 generation rebuild 和 rollback hook 保留，[`supertag-core-index.el:187`](../../supertag-core-index.el#L187)、[`supertag-core-index.el:281`](../../supertag-core-index.el#L281)。

## 5. 模块地图与依赖规则

```text
┌──────────────── Interactive Commands / Renderers ────────────────┐
│                       │                         │                  │
│                       v                         v                  │
│              Document Commands             View Runtime          │
│                       │                         ^                  │
└───────────────────────┼─────────────────────────┼──────────────────┘
                        v                         │
                    Org files              Query Engine
                        │                         ^
                        v                         │
                Document Projector ───────> Query Model
                        │                         ^
                        v                         │
Semantic Commands ──> Mutation Kernel ───────────┘
                        │
              ┌─────────┴──────────┐
              v                    v
     revision/index invalidation  Canonical Committed Change
                                             │
                                             v
                                      Automation/View
```

允许的依赖：

- UI → Document/Semantic Commands、Query、View Runtime；
- Projector → extractor/resolver、private projection writer、Mutation Kernel；
- Semantic Commands → Mutation Kernel；
- Query Model → Store/Index read interface；
- Query Engine → Query Model；
- View Runtime → Query Model/Engine、Notify read side；
- Automation Runtime → Query Model/Engine、Document/Semantic Commands；
- Persistence → Store snapshot/restore、Index rebuild。

禁止的依赖：

- UI/View/Automation → raw Store write；
- Projector → Semantic Command；
- Semantic Command → Org edit；
- Ops → Automation private implementation；
- renderer → Query Engine 私有 comparator；
- Index → 领域写命令。

## 6. 深模块接口

### 6.1 Document Commands：拥有跨 buffer/file/projection 的顺序

公开交互命令名保持兼容；写入顺序由以下已实施的 Org service 接口拥有：

```elisp
(supertag-service-org-create-node-at-point)
(supertag-service-org-delete-node-at-point node-id)
(supertag-service-org-demote-node-at-point node-id)
(supertag-service-org-add-tag node-id tag-id)
(supertag-service-org-remove-tag node-id tag-id)
(supertag-service-org-replace-tag node-id old-tag-id new-tag-id)
```

统一算法：

```text
locate + validate
  -> edit buffer in recoverable change group
  -> save Org
  -> Projector reconcile saved fact
  -> return domain result
```

失败协议：

- edit/validation 失败：buffer、file、Store 均不变；
- save 失败：恢复/保留可撤销 buffer 状态，Store 不变；
- save 成功但 projection 失败：文件事实已提交；Projector transaction 回滚并保留旧 Projection；抛出携带 node/file/retry entry 的 `supertag-projection-error`；不得反向伪装文件保存失败。

最后一条很重要：文件系统与内存 Store 没有共同事务。正确恢复方法是按错误中的 retry entry 重跑幂等 Projector，或执行 complete reindex，而不是试图撤销已经成功写盘的用户文档。该错误/诊断本身是运行时状态，不会创建 Operational Fact；既有 Operational Fact 仅指必须持久到显式解决的冲突/恢复记录。

### 6.2 Node Identity：唯一定位 seam

继续由 `supertag-service-node-identity.el` 拥有运行时 identity lookup：

- Store 有健康 projection：使用 Store location；
- Store 有该 node 但 projection 损坏：fail closed；
- Store 完全缺少 node：仅兼容路径可查询 `org-id`；
- ensure-at-point 负责写 ID，但调用者仍负责 save/project。

当前代码已实现 Store-first/fail-closed 行为，[`supertag-service-node-identity.el:125`](../../supertag-service-node-identity.el#L125)。其他模块不得重新实现 fallback。

### 6.3 Document Projector：纯提取 + 有边界的 reconcile

外部入口：

```elisp
(supertag-project-saved-node node-ref)
(supertag-project-complete-snapshot files)
```

内部阶段：

```text
Extract -> Resolve -> Diff -> Reconcile projections -> Commit
```

不变量：

- Extract/Resolve 无 Store mutation；
- Diff 只比较 owner 属于 Document 的 projection；
- Reconcile 不写 semantic facts；
- complete snapshot 不完整则零 destructive change；
- point projection 与 complete projection 对同一 node 结果一致；
- operation 幂等。

当前 complete-snapshot guard 是实现基线，[`supertag-services-sync.el:2141`](../../supertag-services-sync.el#L2141)。现有 point sync 某些路径为一个 node 解析整文件，可在 correctness 收敛后单独优化，[`supertag-services-sync.el:2295`](../../supertag-services-sync.el#L2295)。

### 6.4 Semantic Commands：唯一 Semantic Fact writer

Semantic Commands 承担领域不变量，例如 Tag parent 不得形成环、node-reference field 要 reconcile field-reference relation、semantic edge 用确定性 identity 去重。

每个命令通过 Mutation Kernel 提交一个 `:authority :semantic` operation。它可以在同一 transaction 中更新由该语义事实派生的 projection，此时 `:scope` 为 `:fact+projection`；但不得编辑 Org。

跨 owner 的“彻底删除 Tag”改为显式 migration：

```text
Plan affected occurrences/files
  -> validate writable + capture recovery plan
  -> modify and save all Document Facts
  -> reproject successfully
  -> delete Semantic Tag if no references remain
```

任一文档阶段失败时，Semantic Tag 保留。该 workflow 返回部分进度和可重试计划，不声称跨文件原子性。

### 6.5 Mutation Kernel：事务和一次提交事实

Mutation Kernel 是内部深模块，不是新的 public data access layer。C5 骨架复用现有 first-touch rollback，但当前入口必须拥有最外层 transaction；若检测到 ambient transaction 会显式拒绝，避免在真正的 outer commit 前误发事件。subscriber 派生的新提交发生在前一 transaction 已完成之后，因此可安全进入 FIFO。未来若生产迁移确实需要 ambient transaction，必须先新增并验证通用 after-commit hook，不能暗中放宽该前置条件。

调用形状：

```elisp
(supertag-change-commit
 `(:authority :document
   :scope :projection
   :operation :node-projected
   :subject (:kind :node :id ,node-id)
   :cardinality :single
   :affected ((:collection :nodes :count 1))
   :metadata ,metadata)
 (lambda () ...))
```

Canonical Change 最小 schema：

```elisp
(:version 1
 :change-id "unique-id"
 :causation-id nil          ; automation 派生操作指向上游 change-id
 :authority :document       ; :semantic / :operational
 :scope :projection         ; :fact / :fact+projection
 :operation :node-projected
 :subject (:kind :node :id "node-id")
 :cardinality :single       ; :batch
 :affected ((:collection :nodes :count 1)
            (:collection :relations :count 3))
 :metadata (...))
```

Kernel 内部另有一个短命的 `CommitRecord`，保存 first-touch mutation 的 `(path old new)`，只服务于 rollback、revision/index invalidation 和迁移期 legacy bridge。它不进入 public event、不持久化、也不允许 Query/Automation 读取。公共 `Canonical Change` 是从该 record 与领域参数生成的有界摘要，不是 raw Store diff。

提交语义：

1. body 在 Kernel 自己拥有的最外层 Store transaction 内运行；ambient transaction 当前 fail closed；
2. first-touch log 提供 rollback 与 changed paths，但它是 Kernel 私有结构；
3. no-op 返回结果但不发布 change；
4. consistency-critical 的 revision 更新和索引失效属于提交协议，在事件发布前完成；
5. 可选的索引预热可以消费事件，但查询正确性不得依赖 subscriber 已运行；
6. 公共事件只包含有界的领域摘要；完整 reindex 用 `:cardinality :batch` 和计数，不复制巨大 path log；
7. transaction 完全结束后把一次 committed change 放入进程内 FIFO；dispatcher 同步排空队列；
8. subscriber 触发的新 commit 只入队，不重入当前 dispatch stack；
9. 每个 subscriber 单独隔离异常，一个失败不阻断其余 subscriber，也不回滚已提交 Store；
10. 同一 `change-id` 允许消费者做幂等去重；进程崩溃后没有 durable exactly-once 保证。

迁移期 bridge 从私有 `CommitRecord` 生成旧 `(path old new)` 事件，同时 Kernel 只发布一个公共 Canonical Change。bridge 不从有界公共摘要反推丢失的 old/new，也不能反向生成 Canonical Change。

### 6.6 Query Model：稳定、具体的读取表面

Query Model 提供领域名词，不暴露任意 collection：

```elisp
(supertag-query-node id)
(supertag-query-node-detail id)
(supertag-query-nodes-by-tag tag-id)
(supertag-query-relations criteria)
(supertag-query-field-value node-id field-id)
```

结果必须是调用者无需再次访问 Store 才能解释的稳定 read model。读取可以内部使用 Index，但 Index stale/missing 时语义不得变化。

现有 query 文件开头的 concrete reads 是迁移起点，[`supertag-services-query.el:22`](../../supertag-services-query.el#L22)。generic arbitrary collection query 不属于稳定接口。

### 6.7 Query Engine：唯一表达式与值语义

Query Engine 拥有：parse、validate、execute、filter、sort、group、aggregate，以及唯一的 null/number/date/string comparison。

```elisp
(supertag-query-parse form)                  ; -> AST / validation errors
(supertag-query-execute ast context)         ; -> Query Result
(supertag-query-transform result transforms) ; -> Query Result
```

`Query Result` 至少包含 rows、columns/schema、ordering/group metadata、diagnostics。Renderer 不读取 Store 补全行，也不调用 engine 私有 comparator。

persisted query/view 需要带语义版本。若统一 comparator 改变旧排序，可按版本迁移 config；不能按 renderer 永久保留三套语义。

### 6.8 Automation Runtime：唯一规则生命周期 owner

Runtime 拥有一个 canonical change subscription：

```text
Committed Change
  -> select candidate rules by authority/scope/operation
  -> evaluate conditions through Query Model/Engine
  -> recursion/idempotency guard
  -> dispatch Document or Semantic Command
  -> record outcome
```

约束：

- init 幂等，重复调用仍只有一个 subscription；
- cleanup 调用保存的 unsubscribe closure；
- action 不直接写 Store；
- rule execution 继承 parent `change-id`/causation-id 以检测递归；
- 同一 change/rule 至多执行一次；
- action failure 不回滚产生 trigger 的原 operation，但要保留可诊断结果。

当前重复订阅风险来自 init 忽略 unsubscribe，[`supertag-automation.el:1471`](../../supertag-automation.el#L1471)。迁移完成后删除 legacy queue 和 commit-hook 开关。

### 6.9 View Runtime：保留现有深接口

Runtime 继续拥有 registry、instance、open、render、subscribe、refresh、selection、cleanup 和错误回滚。Renderer 是 adapter，只负责特定视图的数据呈现与交互。

当前实现已有完整生命周期骨架，[`supertag-view-framework.el:32`](../../supertag-view-framework.el#L32)、[`supertag-view-framework.el:137`](../../supertag-view-framework.el#L137)、[`supertag-view-framework.el:387`](../../supertag-view-framework.el#L387)。允许拆私有 widget/config 文件，但对外仍只有一个 Runtime。

浅 `supertag-view-api.el` 在 Query Model 接口稳定、调用者迁移后删除，不替换为另一层同名转发。

### 6.10 Persistence：可验证的 durable snapshot

保留当前协议：确定性 canonical serialization → 同目录临时文件 → 重读并验证所有 durable roots → atomic rename。加载失败 fail closed，加载成功后 cold rebuild 全部派生索引。

持久化保存 `O` 吗？不保存；Org 文件本身承载 `O`。持久化保存 `S` 以及为启动性能保留的 `P` 快照，但 `P` 永远可由 reindex 覆盖。快照 schema 必须能区分 semantic fact 与 projection owner。

## 7. 关键运行流程

### 7.1 创建 Node

```text
UI
 -> Document Command validates heading/title
 -> create heading/ID in recoverable buffer change
 -> save-buffer
 -> project-saved-node
 -> commit :authority :document / :scope :projection / :node-projected
 -> Index/View/Automation observe one change
```

### 7.2 删除 Node

```text
UI confirmation
 -> locate through Node Identity
 -> delete subtree in recoverable buffer change
 -> save-buffer
 -> Projector removes node/document-owned relations
 -> one committed change
```

save 失败时 projection 未动。project 失败时文档删除已成立、旧 Projection 保持不变，并通过结构化错误允许重试；不另存一个 stale fact。

### 7.3 设置 global field value

```text
Semantic Command
 -> validate field/schema
 -> commit semantic field value
 -> reconcile field-reference projection in same Store transaction
 -> one committed change
 -> Automation evaluates once
```

不再由 field ops 手动调用 automation 私有函数。

### 7.4 完整 Reindex

```text
scan all configured files
 -> build complete immutable snapshot
 -> if incomplete: abort, Store unchanged
 -> resolve against current Semantic Facts
 -> replace only Document-owned projections in one batch commit
 -> cold rebuild derived indexes
 -> publish one batch committed change
```

### 7.5 打开/刷新 View

```text
View adapter describes query + renderer
 -> View Runtime owns instance/subscription
 -> Query Model/Engine returns Query Result
 -> renderer renders result
 -> committed change invalidates/refreshes runtime
 -> selection restored or cleanup on failure
```

## 8. 一致性与失败模型

| 边界 | 原子单位 | 失败后的正确状态 | 恢复动作 |
|---|---|---|---|
| Store mutation | 一个 Mutation Kernel transaction | 全回滚 | 重试 command |
| Org save | 一个文件保存 | Store 未开始变更 | 修复文件错误后重试 |
| save 后 point projection | 已保存文档是权威；旧 Projection 可能与其不一致 | 不撤销成功保存，不另存 stale fact | 按结构化错误重跑 point projection/reindex |
| complete reindex scan | 完整 snapshot | 不完整则 Store 不变 | 修复扫描错误后重跑 |
| persistence save | 一个 durable snapshot | 旧快照仍可加载 | 重试保存 |
| subscriber/automation | 每个 consumer execution | 原提交保持成功，consumer failure 可诊断 | 按 change-id 重试/人工处理 |
| multi-file Tag migration | 一个可恢复 workflow | Semantic Tag 保留；记录完成/未完成文件 | 从计划继续或补偿 |

系统采用“事实提交成功后，下游最终追平”的局部 eventual consistency；不伪造跨文件、跨 Store 的全局 ACID。

## 9. 兼容策略

### 9.1 事件桥

K2/C5 结束、M2b 尚未实施时没有生产 writer/subscriber，也没有抑制或重放
legacy event；当时 `supertag-core-change.el` 只验证新 contract，现有
`:store-changed` 行为完全不变。M2b 以这个基线实现了下列兼容形状，当前
K3 状态与验证见第 17 节：

```text
Kernel-managed write
  -> collect/suppress low-level immediate legacy event
  -> CommitRecord
  -> enqueue one delivery batch:
       [one Canonical Change, zero-or-more legacy :store-changed(path, old, new)]

Unmigrated direct Store write
  -> existing immediate legacy :store-changed behavior
  -> no Canonical Change（直到该 writer 被迁移）
```

M2b 中，Kernel 必须用动态收集上下文抑制自己 body 内原有的即时 `:store-changed`，否则 bridge 会双发。一个 delivery batch 原子入 FIFO，Canonical Change 排在本次 legacy path events 之前；subscriber 触发的嵌套 commit 追加到队尾。迁移期任何 consumer 只能选择 canonical 或 legacy topic 之一，不能同时订阅两者。

桥必须有计数器/调试输出，能列出 legacy subscriber 和每个 commit 派生的 path event 数。兼容测试逐项比较原 `(path old new)` 形状和顺序。Automation、View 等全部迁移后删除 bridge；禁止双向桥。

### 9.2 Public function 弃用

对 projection direct mutation、generic query builder、浅 View API：

1. 文档标记 deprecated 和 replacement；
2. runtime warning（每 session 一次）；
3. `rg` 扫描仓库、示例、测试、插件；
4. 经过约定发布窗口；
5. 调用数归零后删除。

### 9.3 Legacy data shape

nested field shape 只能在 durable data audit、备份、migration、reload verification 全部成功后删除。兼容 parser 可以读旧格式，但 canonical writer 只写新格式，最终让旧数据自然归零。

## 10. 可观测性

为诊断边界而记录，不做重型 telemetry：

- `change-id`、causation-id、authority、scope、operation、subject、affected count；
- projection error/retry 诊断；
- automation candidate/matched/executed/skipped/failed；
- legacy bridge subscriber/call count；
- index revision/rebuild generation；
- reindex snapshot file/node/error count；
- persistence snapshot version/verification result。

debug log 不记录完整正文或敏感 field value，默认关闭高频 path 明细。

## 11. 验证矩阵

| 架构公理 | 动态测试 | 静态 guard |
|---|---|---|
| A1 owner 互斥 | reindex preserves semantic/operational facts | Projector 禁止写 semantic/operational collection |
| A2 save-before-project | save failure leaves projection unchanged | UI 无 direct projection write |
| A3 projection 可重建 | incremental/cold rebuild parity | Projection collection 清单完整 |
| A4 semantic 不写 Org | semantic command buffer/file unchanged | Semantic 模块不 require Org write helper |
| A5 authority/scope 正交 | document/semantic/operational schema tests | 禁止旧 `:owner :document-projection` 混合枚举 |
| A6 一次提交 | canonical count = 1；rollback = 0；legacy bridge path parity | 领域写入不手动 notify |
| A7 下游不反写 | automation/view action contract | View/Automation 无 raw Store write |
| A8 兼容可删除 | bridge parity + warning tests | legacy allowlist 单调归零 |

必须保留现有 transaction、ownership、identity、query-model、automation、view-runtime、persistence 与 reindex 测试族。物理拆模块时替换测试依赖，不复制同一行为到每层。

## 12. 迁移发布顺序

```text
M0  Contract tests + static allowlist                                      DONE
M1  Document Commands save-before-project                                 DONE
M2a Mutation Kernel + private CommitRecord + Canonical Change（无生产 consumer） DONE
M2b Kernel 内抑制旧即时事件 + CommitRecord-to-legacy bridge（board tracer） DONE
M3  Semantic writes / Projector writes 全部接入 kernel
M4  Query Model/Engine + single value semantics
M5  Automation single subscription runtime
M6  删除 legacy paths、移动错位实现、更新文档/命名
```

发布 gate：每个里程碑单独通过 byte compile、相关 ERT、全量 ERT；涉及 durable
data 时额外执行 save/reload/cold-rebuild parity。任何里程碑都不得依赖下一个
里程碑才能恢复绿灯。M2a 先在无生产 consumer 的情况下验证
envelope/count/FIFO；M2b 随后通过 legacy parity gate，才把
`supertag-board-create` 作为第一个生产 writer 迁入 Kernel。

## 13. 首批代码任务（已完成）

第一实施批次固定为以下五个可独立提交的任务：

| 提交 | 状态 | 代码/证据 |
|---|---|---|
| C1 Document failure contracts | DONE | `test/document-command-ownership-test.el`；E-003 |
| C2 Boundary guard | DONE | `test/architecture-boundary-test.el`；E-004 |
| C3 Create save-before-project | DONE | `supertag-service-org-create-node-at-point`；E-005 |
| C4 Delete/demote save-before-project | DONE | recoverable edit/save/retry service；E-006 |
| C5 Canonical event skeleton | DONE | `supertag-core-change.el`；E-007；无生产 consumer |

C1–C5 的历史全量基线为 569 tests、0 unexpected、2 个交互式 dashboard
测试按设计 skipped。M2b 后续已通过 legacy bridge parity，并且仍未迁移
`supertag-field-set` 或任何生产 consumer；K3 结果见第 17 节。

第一批不移动大文件、不改持久化格式、不删除 legacy API。若当前 worktree 已有用户修改，逐 hunk 集成并保留，不覆盖无关变化。

### 13.1 C5 的最小验收用例

```text
success mutation       -> Store changed, canonical = 1
no-op mutation         -> Store unchanged, canonical = 0
body error             -> Store rollback, canonical = 0
subscriber A errors    -> subscriber B still runs, Store remains committed
subscriber commits C2  -> C2 queued after all C1 deliveries, no recursive dispatch
batch reindex summary  -> bounded affected counts, no public raw path list
```

C5 只建立一个内部 seam。不要同时重写 `supertag-core-notify.el`、所有 Ops 和 Automation；先用 adapter 接住现有 transaction/notify，再逐 writer 迁移。

## 14. 决策记录

### D1. 保留内存 Store，而非引入 Repository

原因：当前只有一个 data backend；Store 已被 persistence、transaction、index 深度使用。领域 writer/read model 已足够隔离调用者，再加 Repository 只会形成浅转发。

### D2. 保留双业务事实 + 窄 Operational Fact，而非宣布 Store 或 Org 单一真相

原因：Org 拥有文档内容，Store 中的 stable Tag/schema/field 等无法从 Org 完整恢复；unresolved sync conflict 又不能从 merge winner 或前两类事实重建。三者互斥所有权比“谁是唯一真相”更准确，但 Operational 集合必须保持窄且有终止生命周期。

### D3. Projection 失败采用重试，不回滚已保存 Org

原因：跨文件系统和内存无法可靠原子回滚；Projector 本身应幂等、可重建。

### D4. 保留一个 View Runtime

原因：现有 Runtime 已隐藏 lifecycle 复杂性；多个 renderer 是真实 adapter，满足至少两个实现才建立 seam 的条件。

### D5. Query Model 与 Query Engine 分开

原因：具体领域读取和用户查询语言有不同变化原因；Table、Query Block、Automation 至少三个消费者共享 Engine 语义，seam 有真实杠杆。

### D6. Canonical event 以非重入 FIFO 同步排空，consumer failure 隔离

原因：当前 Emacs 单进程模型优先保证确定顺序；直接递归 notify 会让 automation 派生提交重入当前 subscriber stack。FIFO 保持同步可预测性，同时把嵌套 commit 串行化。原 operation 已提交后，consumer 异常不能反向破坏事实；change-id/causation-id 为递归检测、重试和去重提供身份。该队列不是 durable event log，不承诺跨进程 exactly-once。

### D7. Legacy event 读取私有 CommitRecord，不污染公共 Change

原因：旧 callback 需要完整 `(path old new)`，而公共 Change 必须对大 batch 保持有界。迁移期由 Kernel 动态收集并抑制即时旧事件，commit 后 bridge 从私有 record 恢复原事件；这既避免双发，也不迫使新消费者依赖 Store 物理路径。bridge 删除后 record 仍可服务 rollback/index，但不再用于公共通知。

### D8. Operational authority 只收不可重建且有终止生命周期的事实

原因：`:sync-conflicts` 必须保存 ours/theirs/base 直到用户解决，merge winner 无法重建这些信息；把它归入 Semantic 会混淆业务语义，把它归入 Projection 又允许错误删除。反过来，retry error、queue、timer、dirty flag 等都可重建或只在进程内有意义，不能借 `:operational` 持久化。新增该 authority 的实例必须同时证明不可重建性、owner 和终止条件。

## 15. 六轮审查记录

本节记录实施前 Round 1–3 与实施后 Round 4–6。审查模型采用 **Linus 五层模型**：数据结构、特殊情况、复杂度、兼容性、实用性；并辅以 **深模块删除测试**，判断每个 seam 是隐藏复杂度还是只增加转发。Round 1–3 保留当时的推理轨迹；被实现证据推翻的结论由 Round 4 明确取代。

### Round 1：数据结构与所有权——已完成

**三个预检**：问题真实（当前公开命令确实存在 Store-first/Org-first 两种顺序）；最简单方案是收敛 writer 而不是更换 Store；直接删除旧 API 会破坏兼容，因此必须迁移后删除。

**发现的问题**：初稿的 change schema 使用 `:owner :document-projection / :semantic / :operational`，把“事实权威方”和“变更作用范围”压进同一枚举。field-reference relation 是由 Semantic Fact 派生的 Projection，必然需要新增特例。

**实际修订**：

- 将字段拆为 `authority` 与 `scope`（第二轮因证据扫描不完整而暂时删除 `operational`；该结论已由 Round 4 的 durable conflict 证据推翻）；
- 明确 semantic field value 与 field-reference projection 可在同一 Store transaction 中以 `fact+projection` 提交；
- 明确 consistency-critical 的 revision/index invalidation 在事件前完成，不能依赖 subscriber 保证查询正确性；
- 验证矩阵增加 authority/scope 正交测试与静态 guard。

**五层结论**：数据模型无额外 source of truth；跨 owner 操作仍被建模为 workflow；没有引入 Repository。第一轮通过。

### Round 2：特殊情况、复杂度与模块深度——已完成

**删除测试**：

- 删除 Mutation Kernel 会把 rollback、revision、event ordering 复制回每个 writer，因此它是深模块；
- 删除 View Runtime 会让每个 renderer 重新拥有 lifecycle，因此保留；
- 删除 View API 只减少转发，不损失隐藏能力，因此列入淘汰；
- 当时未识别到 `:sync-conflicts` 的完整 durable lifecycle，因此暂把 `:operational` 判为预留抽象；Round 4 已修正这一遗漏。

**发现的问题**：初稿把完整 changed paths 放进公共 event。point projection 很小，但 complete reindex 可能产生巨大 path list；下游若依赖 path 细节，batch 又会长出第二套协议。同步 subscriber 中再次 commit 还会递归进入 dispatch stack。

**实际修订**：

- 暂时删除当时未找到 owner 的 `:operational` authority；普通运行时 lifecycle 仍使用 notification；该删除结论由 Round 4 以更窄定义撤销；
- first-touch path log 留在 Kernel 内部，公共 event 改为 subject/cardinality/affected count 的有界领域摘要；
- single 与 batch 共用一种 schema；
- dispatcher 改为非重入 FIFO：嵌套 commit 入队，当前事件完成后再处理；
- 逐 subscriber 隔离异常，并明确没有跨进程 exactly-once 承诺。

**五层结论**：point/batch、nested automation、subscriber failure 不再要求分叉主流程；没有新增无第二实现的 adapter。第二轮通过。

### Round 3：兼容性、实用性与开工条件——已完成

**发现的问题**：第二轮后的公共 Change 已不含 raw paths，但初稿仍声称 legacy `:store-changed` 可由它直接派生。旧 callback 需要 `(path old new)`，信息已经丢失；若 Kernel body 继续让低层 Store 即时发旧事件，bridge 还会再次双发。另一个模糊点是 projection 失败后的“stale 状态”没有 owner，容易偷偷长成第三份持久事实。

**实际修订**：

- 定义 Kernel-private、短命、不持久化的 `CommitRecord` 保存 path/old/new；
- Kernel body 动态收集并抑制即时旧事件，成功后一个 delivery batch 先放 canonical、再放 legacy path events；
- 未迁移 direct Store writer 暂时维持原 legacy 行为，迁入 Kernel 后才获得 canonical event；
- consumer 迁移期只能选择一个 topic，bridge 增加 path parity、顺序和调用计数 gate；
- projection failure 改为结构化 `supertag-projection-error`，旧 Projection 由 transaction 保持，恢复依赖幂等重投影，不新增持久 stale fact；
- 把首批工作拆成 C1–C5，明确文件范围、失败测试、独立绿灯与 C5 最小验收用例。

**兼容性判断**：现有 Store、持久化格式、View Runtime 和 legacy subscriber 都可阶段性保留。最危险的 UI 命令先由 contract test 固化失败语义；event bridge 在任何生产 consumer 切换前先做 parity。

**实用性判断**：每个里程碑可独立编译、测试和回退；第一批不移动大文件、不改 durable schema、不要求下一个阶段才能运行。第三轮通过。

### Round 4：实施证据反查数据模型——已完成

**发现的问题**：实施前审查把“没找到 owner”等同于“没有 Operational Fact”。代码反例很具体：merge 用确定性 ID 产生 `:sync-conflicts`，persistence 保存该 collection，conflict resolution 在应用选择后原子删除记录。winner 无法重建 ours/theirs/base，所以它既不是 Projection，也不是普通 runtime state。

**实际修订**：

- 权威集合从 `O ⊎ S` 修正为 `O ⊎ S ⊎ R`；Projection 仍只由事实派生且没有 authority；
- `:operational` 仅接受不可重建、owner 明确、终止条件明确的冲突/恢复事实；
- retry error、FIFO、timer 等继续归 runtime lifecycle，不借机持久化；
- CONTEXT、KERNEL K2、schema、验证矩阵和本文件同步更新。

**五层结论**：这是修正错误分类，不是新增万能抽象；现有 durable shape 不变。第四轮通过。

### Round 5：接口深度、事务边界与特殊情况——已完成

**删除测试**：删除 Org service 命令会把 edit/save/project 顺序复制回 UI；删除 Canonical Change seam 会把 no-op 检测、CommitRecord 隔离、FIFO 和 subscriber failure policy 复制给每个 writer。两者都隐藏了多项真实复杂度，是深模块。

**发现的问题**：设计稿笼统声称 Kernel“复用 nested transaction”，但 C5 没有通用 outer after-commit hook。若在 ambient transaction 中直接返回并发布，随后 outer rollback 会留下虚假成功事件。

**实际修订**：

- C5 入口明确拥有最外层 transaction，ambient transaction fail closed；
- subscriber 派生 commit 发生在上一个 transaction 完成后，只排入 FIFO，不构成 ambient nesting；
- 将文档伪 API 替换为实际 `supertag-change-commit` envelope + body 签名；
- M2b 如需 ambient 支持，必须先单独实现并验证 after-commit hook。

**五层结论**：一个明确不支持的特殊情况优于一个错误支持的特殊情况；主流程无额外分叉。第五轮通过。

### Round 6：兼容性、可验证性与下一批开工条件——历史记录，已完成

**该轮检查结果**：仓库搜索当时只找到 `supertag-core-change.el` 自身定义，
没有生产 `require`、writer 或 subscriber；legacy `:store-changed` 实现未改。
C1–C5 的 focused/regression gate 全部通过，全量 ERT 为 569 tests、0
unexpected、2 个交互式 dashboard 测试按设计 skipped；production Elisp 在
临时副本中 byte-compile，静态 boundary guard、`check-parens`、`bash -n`
与 `git diff --check` 均通过。

**该轮结束时的剩余风险**：M2b bridge 尚未实现；C5 不支持 ambient
transaction；现有 allowlist 中的 legacy 越界仍需逐项归零。这三项都被显式留在
下一批，当时的代码没有假装完成。

**当时的实用性结论**：K2 可独立运行，不依赖未来 bridge 才保持兼容；下一批
只有在 legacy path parity、顺序和双发测试通过后，才能迁移第一个 production
writer。第六轮通过。

## 16. M2b 前开工状态（历史 gate）

以下记录是六轮审查结束、M2b 尚未实施时的开工 gate。六轮审查全部通过，
C1–C5 已实施并满足发布 gate；当时没有阻塞 M2b 设计与编码的问题，但尚未授权
把生产 writer/consumer 接入 Canonical Change。

| 开工问题 | 结论 |
|---|---|
| 事实 owner 是否唯一？ | 是：Document / Semantic / 窄 Operational；Projection 无独立权威 |
| 跨 owner 失败语义是否明确？ | 是：save-before-project；跨文件删除是可恢复 workflow，不是假事务 |
| 新 seam 是否有足够杠杆？ | 是：Kernel、Query Engine、View Runtime 均隐藏多个调用者共享的真实复杂度 |
| 兼容桥是否能实现且能删除？ | 是：私有 CommitRecord 保真；subscriber/path 计数归零后删除 |
| 第一批是否可独立验证？ | 是：C1–C5 分片通过，全量 569 tests 无 unexpected |
| 是否会破坏 durable format？ | 第一批不会 |

这道 gate 要求先证明 legacy `(path old new)` 形状/顺序一致且没有双发，再
迁移第一个 production writer；M2b 已按此顺序完成，结果见下一节。

## 17. K3 / M2b 实施状态

M2b 在一个纵向切片内完成临时单向 bridge 与第一个生产 tracer：

```text
Kernel-managed write
  -> suppress immediate legacy :store-changed
  -> private first-touch CommitRecord
  -> enqueue one complete FIFO batch
       [one Canonical Change, ordered legacy (path old new) events]
```

- `supertag-core-change.el` 是 commit、CommitRecord、整批 FIFO、topic 互斥和
  bridge diagnostics 的唯一权威；
- `supertag-core-notify.el` 只提供临时 legacy adapter，不从公共 Change
  反推 raw path，也不反向生成 Canonical Change；
- 同一 callback 不能同时订阅 Canonical 与 legacy `:store-changed`；
- 未迁移 writer 继续即时发布原 legacy event，不产生 Canonical Change；
- `supertag-board-create` 是唯一生产 Canonical writer，发布
  `:board-created` / `:semantic` / `:fact` / `:single`，随后桥接原
  legacy payload；
- 生产 Canonical consumer 仍为零，board update/delete 及其他 writer 未迁移；
- ambient Store transaction 仍 fail closed；M2b 没有偷偷加入通用
  after-commit hook、持久事件日志或 exactly-once 声明。

验收证据：

- focused Canonical/legacy ERT：11/11；
- transaction/automation/view/ownership/architecture 相关 gate：92 项，
  90 expected pass、0 unexpected、2 个既有交互测试 skip；
- 全量 ERT：573 项，571 expected pass、0 unexpected、同样 2 个 skip；
- 生产 caller/require 扫描：各 1 个，均只在 `supertag-board-ops.el`；
- 生产 Canonical subscriber：0；
- byte compile、`check-parens`、`bash -n`、`git diff --check`：通过。

任何后续
writer/consumer 迁移都必须重新评估；writer/consumer 迁移都必须重新经过 `plan`；能在 ambient transaction 中运行的
writer 必须先有单独确认和验证的 after-commit 设计。
