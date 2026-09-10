The legacy schema/table/kanban/search/capture entry points described here are archived; see README for the current workflow.

# Supertag 渐进式重构与优化计划

> 目标：不替换 Store、不重写 View、不改变持久化格式，先把所有权和提交语义收敛成唯一道路，再删除重复实现。每一步都必须保持仓库可运行、可回退，并用现有 contract tests 加少量静态 guard 证明边界真的收紧了。

> 实施状态：M0、M1、M2a（C1–C5）已完成并全量通过 569 tests、0 unexpected；当前下一步是 M2b legacy event bridge parity。本文其余 Phase 保持为后续计划，不表示已实施。

## 1. 成功标准

完成重构后，系统应满足七条可检查约束：

1. Document Fact 只由 Document Commands 修改；流程固定为“编辑 Org → 保存 → Projector”。
2. Projection 只由 Projector 内部写入；外部不能直接修改 node membership/document link projection。
3. Semantic Fact 只由 Semantic Commands 修改，不触碰 Org 文本。
4. 每个成功领域操作只产生一个 canonical committed change；rollback 不产生成功事件。
5. Index、View、Automation 都消费同一个 committed change contract。
6. Query Model 提供具体领域读取；Query Engine 独占 DSL、filter、sort、group/value semantics。
7. 每个兼容入口都有替代 API、调用数和删除 gate；不存在无限期 legacy path。

## 2. 明确不做什么

为了控制风险，本轮不做以下事情：

- 不引入 SQLite 或 Repository/Backend Adapter。当前只有一个内存 Store 和一种 canonical persistence，没有第二个 adapter，提前抽象只会增加转发层。
- 不把所有模块改名或重排目录。先修行为边界，再做机械命名。
- 不重写 `supertag-view-framework.el`。它已经是 lifecycle owner。
- 不改变 durable persistence schema，除非单独 migration 有明确需求。
- 不把 Org 文件系统写入伪装成 Store transaction。两者无法真正原子提交，应靠 owner 顺序和可恢复 migration 处理。
- 不追求一次删除全部 raw Store read。优先禁止跨边界 write；read 通过 Query Model 渐进迁移。

## 3. 目标模块与最小接口

### 3.1 Document Commands

职责：执行用户发起的文档事实修改，并保证 save-before-project。

已保留并加深的能力：

```elisp
(supertag-service-org-create-node-at-point)
(supertag-service-org-delete-node-at-point node-id)
(supertag-service-org-demote-node-at-point node-id)
(supertag-service-org-add-tag node-id tag-id)
(supertag-service-org-remove-tag node-id tag-id)
(supertag-service-org-replace-tag node-id old-tag-id new-tag-id)
```

这些函数不是简单 wrapper。它们共同拥有：定位、buffer edit、用户可见错误、保存、Projector 调用、失败时 Store 不变。实现集中在 [`supertag-service-org.el:335`](../../supertag-service-org.el#L335) 起的同一 service，没有新建平行层。

### 3.2 Document Projector

职责：把 complete document snapshot 或一个已保存 node 的事实投影到 Store。

对外只需要两个入口：

```elisp
(supertag-project-saved-node node-ref)
(supertag-project-complete-snapshot files)
```

内部再分为 extractor、resolver、reconciler、projection writer。projection writer 是私有能力，允许写 `:nodes`、document-owned membership/document link；不得写 semantic Tag/schema/field value。

现有同步器的 snapshot guard 和 ownership-aware relation reconcile 直接保留，[`supertag-services-sync.el:1744`](../../supertag-services-sync.el#L1744)、[`supertag-services-sync.el:2141`](../../supertag-services-sync.el#L2141)。本轮只收敛入口，不先重写 2500 行同步器。

### 3.3 Semantic Commands

职责：修改稳定语义事实：Tag definition/schema、global field value、semantic edge、board、automation、persisted query/view。

接口按领域命名，而不是暴露 arbitrary collection：

```elisp
(supertag-semantic-create-tag ...)
(supertag-semantic-set-field-value node-id field-id value)
(supertag-semantic-create-edge from to type)
(supertag-semantic-save-view ...)
```

现有 `supertag-tag-*`、`supertag-field-*`、`supertag-relation-*` 不必一次改名。先让它们内部走统一 commit，并标注哪些是 semantic，哪些是 projector-private；最后再收窄 public surface。

### 3.4 Mutation Kernel（内部模块）

职责：为 Store 内的一组变更提供 transaction、rollback、revision/index invalidation 和一次 canonical event。它不是面向 UI 的 Repository。

最小内部协议：

```elisp
(supertag-change-commit
 `(:authority :document       ; 或 :semantic / :operational
   :scope :projection         ; 或 :fact / :fact+projection
   :operation :node-projected
   :subject (:kind :node :id ,node-id)
   :cardinality :single
   :affected ((:collection :nodes :count 1))
   :metadata ...)
 (lambda () ...store mutations...))
```

成功结果应规范化为：

```elisp
(:version 1
 :change-id "..."
 :causation-id nil
 :authority :document
 :scope :projection
 :operation :node-projected
 :subject (:kind :node :id "...")
 :cardinality :single
 :affected ((:collection :nodes :count 1))
 :metadata (...))
```

这里不把 field-level diff 暴露为公共 API。Kernel 内部保留短命的 `CommitRecord`，记录 first-touch `(path old new)` 供 rollback、index invalidation 和未来 legacy bridge 使用；公共 change 只包含有界的 subject/cardinality/affected 摘要。当前 C5 seam 必须拥有最外层 transaction，ambient transaction 明确拒绝；需要该能力时先实现独立 after-commit hook。关键是一次领域提交只有一个 canonical envelope。

### 3.5 Query Model 与 Query Engine

Query Model 是稳定领域读取接口：

```elisp
(supertag-query-node id)
(supertag-query-nodes-by-tag tag-id)
(supertag-query-node-detail id)
(supertag-query-relations ...)
```

Query Engine 拥有可配置查询语义：

```elisp
(supertag-query-parse form)
(supertag-query-execute ast context)
(supertag-query-transform result :filter ... :sort ... :group ...)
```

所有 null/number/date/string 比较只在 Query Engine 有一份实现。Query Block/Table 只把 UI 意图编译为 transform，不再调用 `--private` helper 或自行比较。现有 concrete reads 与 DSL 可以先在原文件内形成两个 section/private boundary，再物理拆文件，减少一次性 diff。

### 3.6 Automation Runtime

职责：拥有唯一 subscription、规则索引、递归保护、条件求值、action dispatch 和 cleanup。

运行协议：

```text
Canonical Change
  -> Automation Runtime
  -> rule match
  -> Query Model/Engine condition
  -> Document Command 或 Semantic Command action
```

Automation action 不能直接写 Store，也不能由 Ops 私下调用 automation private function。Runtime init 必须幂等，保存 unsubscribe closure；cleanup 必须实际 unsubscribe。

### 3.7 View Runtime

继续由 `supertag-view-framework.el` 统一拥有 open/render/refresh/subscribe/selection/cleanup。Renderer 只提供 adapter。Query 结果进入 View Runtime，view 不直接遍历 Store。

`supertag-view-api.el` 的浅转发能力迁入稳定 Query Model 后删除。framework 内部过大的 widget/config persistence 可在不增加外部接口的前提下拆成私有 implementation 文件。

### 3.8 Persistence 与 Derived Index

两者保持现状定位：

- Persistence 保存/验证全部 durable roots，原子替换；
- Derived Index 消费 committed change 做局部失效，或从 Store cold rebuild；
- 二者都不成为领域事实 owner。

## 4. 数据与调用方向

```text
用户文档动作
  -> Document Commands
  -> edit + save Org
  -> Document Projector
  -> Mutation Kernel (:authority :document, :scope :projection)

用户语义动作
  -> Semantic Commands
  -> Mutation Kernel (:authority :semantic, :scope :fact 或 :fact+projection)

Mutation Kernel
  -> Canonical Change
      -> Derived Index
      -> Query/View invalidation
      -> Automation Runtime
      -> Persistence dirty state
```

硬约束：

```text
Renderer -X-> Store mutation
Automation -X-> Store mutation
Projector -X-> Semantic Fact mutation
Semantic Command -X-> Org edit
Ops -X-> Automation private callback
```

## 5. 分阶段实施

每个阶段都按“小提交、每提交可运行”执行。下面的 commit 是逻辑提交，不要求机械照抄命名，但不能把多个阶段压成一个巨型提交。

### Phase 0：先把现有正确性变成门禁

#### Commit 0.1：补所有权 contract tests

新增/加固测试：

- create node：save 成功后只投影一次；
- create/delete/demote：save 失败时 Store projection 不变；
- projector 不修改 semantic Tag/field/edge；
- semantic command 不修改 Org buffer/file；
- rollback 不发送 canonical committed change。

现有 tag-membership、ownership、transaction、identity tests 可复用 fixture，不新造第二套测试架构。

#### Commit 0.2：增加静态边界 guard

使用简单 `rg`/ERT 源码扫描禁止新增：

- UI/View/Automation 中的 `supertag-store-put/remove/update/delete`；
- Ops 对 `supertag-automation-sync--*` 私有函数调用；
- renderer 对 `supertag-services-query--*` 私有函数调用；
- Projector 写入 semantic-owned collection。

初期对已有违规做 allowlist，并在每个后续 commit 缩短 allowlist。不要第一天要求全仓零 raw read。

验收：测试本身先能捕获一个人工构造的违规，再恢复绿灯。

### Phase 1：先修 Document Command 的失败顺序

#### Commit 1.1：创建与更新统一走 save-before-project

把 [`supertag-ui-commands.el:198`](../../supertag-ui-commands.el#L198) 的 Store 直写移入现有 Org service 流程。新建 heading 后：确保 ID、保存、按已保存位置投影。保存失败不产生 node projection。

#### Commit 1.2：删除与 demote 统一走 Document Command

替换 [`supertag-ui-commands.el:245`](../../supertag-ui-commands.el#L245) 和 [`supertag-ui-commands.el:281`](../../supertag-ui-commands.el#L281) 的 Store-first 顺序。

建议流程：

1. 捕获 subtree/point marker，进行 buffer edit；
2. `save-buffer`；
3. 通知 Projector reconcile 已删除 ID；
4. save 失败时用 `atomic-change-group`/buffer undo 恢复编辑，Store 未触碰。

不要尝试在 Store transaction 中包 `save-buffer`。

#### Commit 1.3：封闭 membership projection writer

将 `supertag-node-add-tag/remove-tag` 的 projection 写能力标记为 projector-private；迁移公开调用到 Org service。弃用 `supertag-ops-add-tag-to-node`，先 warning，再在调用数为零和版本窗口满足后删除。

验收：所有 Document Fact mutation contract tests 通过；静态 guard 中 UI direct projection allowlist 清零。

### Phase 2：统一 Mutation Kernel 与事件

#### Commit 2.1：定义 canonical change envelope

从现有 `supertag-ops-commit` 提取/重命名内部 kernel。保留 transaction 与 rollback 实现，先不搬动 Store 物理结构。给 operation 加正交的 `:authority` 和 `:scope`，拒绝未知值。

#### Commit 2.2：迁移 semantic writes

按小领域逐个迁移：Tag definition → field value → semantic edge → board/view/automation config。每迁移一个领域：

- 只产生一次 canonical event；
- revision/index 与 rollback 测试通过；
- 删除该领域的手动 notify/private automation callback。

`supertag-field-set` 是第一优先样本：移除 [`supertag-ops-field.el:88`](../../supertag-ops-field.el#L88) 对 automation 私有函数的直接调用。

#### Commit 2.3：加 legacy event bridge

临时 bridge：

```text
Kernel body
  -> 动态收集并抑制即时旧事件
  -> private CommitRecord
  -> one canonical change + legacy :store-changed(path, old, new)
```

bridge 从私有 CommitRecord 保真生成旧 path event，而不是从有界公共摘要反推 old/new。它单向工作，旧 path event 不得反向再生成 canonical event。尚未迁入 Kernel 的 direct Store writer 暂时维持旧行为；迁入后必须抑制原即时事件，避免 bridge 双发。记录 legacy subscriber/path event 数；所有下游迁移后删除 bridge。

#### Commit 2.4：迁移 projector writes

reconcile 一个 node 或一个 complete snapshot 分别形成清楚的 operation envelope。大 snapshot 可以包含多个 internal changes，但对消费者仍是一个 batch commit，避免 automation 对中间世界运行。

验收：领域写入测试断言恰好一个 canonical event；rollback/不变更新断言零成功事件；旧事件桥有独立兼容测试。

### Phase 3：拆 Query 职责，统一值语义

#### Commit 3.1：冻结 concrete Query Model

列出被当前调用者使用的 concrete functions，并为结果 shape 加 contract tests。禁止新增 arbitrary collection public query。

#### Commit 3.2：抽取唯一 value semantics

把 numeric/date/string/null normalization、comparison、stable sort 提取为 Query Engine 私有实现。分别用当前 Query DSL、Query Block、Table 的边界样本建立一张 parity test table。

#### Commit 3.3：迁移 Query Block 与 Table

Query Block header sort 和 Table filter/sort 编译为 Query Engine transform。删除 [`supertag-query-block.el:122`](../../supertag-query-block.el#L122) 对 private query helper 的调用，以及 Table 的重复 comparator。

#### Commit 3.4：拆物理文件

行为稳定后再拆：

```text
supertag-query-model.el
supertag-query-engine.el
supertag-query-value.el      ; 仅内部需要时
```

如果 `query-value` 只有一个 caller，就留在 engine 内，不为文件整齐增加浅 seam。

#### Commit 3.5：淘汰 generic builder 与 View API

对无仓库调用的 builder/get-all-data 发 deprecation warning，明确替代 API。迁移现有调用后删除浅 `supertag-view-api.el` 转发；renderer 依赖 Query Model/Engine 的稳定接口。

验收：三种 UI 对同一 dataset 的 filter/sort 结果一致；源码中无跨模块 `query--private` 调用。

### Phase 4：Automation 只保留一个 Runtime

#### Commit 4.1：修 subscription lifecycle

保存 `supertag-subscribe` 返回的 unsubscribe closure。`init` 先检查/清理旧 subscription，保证幂等；`cleanup` 取消订阅。删除 load-time 隐式重复初始化，或确保它只通过一个 lifecycle owner 运行。

#### Commit 4.2：切换 canonical change

Automation Runtime 只订阅 `:supertag-change-committed`。规则匹配使用 envelope 的 owner/operation/subject，不再从任意 Store path 猜 create/update/delete。

#### Commit 4.3：action 只调用领域命令

文档 action → Document Commands；语义 action → Semantic Commands。移除 field ops 对 automation private function 的反向调用。

#### Commit 4.4：删除旧模型

删除 deprecated async queue、commit hook feature flag 和 `:store-changed` automation subscriber。条件是：

- canonical event parity tests 全部通过；
- legacy callback 使用数为零；
- recursive automation/infinite-loop tests 通过。

验收：重复 init 仍只有一个 subscriber；cleanup 后 mutation 不触发 callback；一次 field update 只运行一次匹配规则。

### Phase 5：收尾和删除

#### Commit 5.1：移动错位实现

- inline Org tag parser 从 Transform 移入 Projector extractor；
- `ops-tag-merge -> view-helper` 的文件修改行为移入 Document Command；
- `services-embed -> ui-embed` 中非 UI 行为下沉到领域模块。

这里移动的是 ownership，不是为了得到漂亮依赖图。

#### Commit 5.2：清除 legacy data-shape 分支

先提供 audit 命令证明 durable data 中无 nested `:fields` legacy shape，再迁移/备份，最后删除 Store/rollback 特例。没有数据证据就不删。

#### Commit 5.3：删除 dead/deprecated API

满足全部删除 gate 后，逐个删除 wildcard transform、batch transform、generic query builder、View API 等。每次删除都运行 `rg`、compile、ERT 和 plugin compatibility check。

#### Commit 5.4：文档与命名归一

更新旧架构文档中的“Store 单一事实源”和过期规模。此时再决定是否机械改名 `services-sync` → `document-projector` 等；命名 commit 不混行为变更。

## 6. “删除门”而不是永久 deprecated

每个兼容入口都要记录：

| 字段 | 含义 |
|---|---|
| Legacy API/event/shape | 要淘汰的具体对象 |
| Replacement | 唯一替代项 |
| Internal callers | `rg`/静态分析得到的数量 |
| External window | 给用户配置/插件的兼容版本窗口 |
| Telemetry/warning | 如何发现仍在使用 |
| Delete gate | 何时允许真正删除 |

示例：

| Legacy | Replacement | 初始证据 | Delete gate |
|---|---|---|---|
| `supertag-ops-add-tag-to-node` | Document add-tag command | 仓库内仅定义命中 | 一个发布窗口 + 无测试/plugin 调用 |
| `:store-changed` automation path | canonical committed change | Automation 当前订阅 | 所有 subscriber 迁移、bridge 计数为零 |
| query builder | Query Model/Engine | 若干接口仅定义命中 | 替代示例发布、仓库/plugin 调用为零 |
| nested `:fields` | global field values | Store/rollback 特例 | durable data audit 为零且 migration 验证通过 |

## 7. 测试策略

### 7.1 在外部接口测试，不复制内部层测试

重构一个深模块时，测试应围绕它承诺的行为：

- Document Command：文件、buffer、projection 的最终状态和失败状态；
- Mutation Kernel：原子性、event count、event envelope；
- Query Engine：输入 dataset + transform → 确定结果；
- Automation Runtime：change → rule/action，包含递归与 cleanup；
- View Runtime：open/refresh/error/selection/cleanup。

迁移实现时优先替换旧测试，不要给每层复制同一行为测试，否则测试结构会冻结旧架构。

### 7.2 必跑测试族

- ownership / tag-membership；
- transaction rollback；
- node-identity boundary；
- query-model / query parity；
- automation sync / recursion；
- view-runtime lifecycle；
- persistence atomicity / durable roots；
- complete-snapshot reindex / derived-index cold rebuild。

### 7.3 静态指标

重构不是以文件数为成功标准，而看这些数字是否单调改善：

```text
跨 owner 的 Store write 数                 -> 0
Ops 调用 automation 私有函数数             -> 0
Renderer 调用 query 私有函数数              -> 0
Document projection 的公开 mutation 入口数  -> 0
Automation active subscription 数           -> 1
领域 operation 的 canonical event 数        -> 1
legacy allowlist 项数                        -> 0
```

## 8. 风险与回退

### 风险 A：改变事件粒度后 automation 少跑或多跑

处理：先双发 canonical + legacy，但只有旧消费者监听 legacy；用 event capture 对同一 fixture 比较实际 action。不要让两个 event 同时进入同一 Automation Runtime。

### 风险 B：save-before-project 改变交互体验

处理：保留 buffer marker/point/window state；在 save 成功后投影；错误时恢复 buffer edit 并给出原始文件错误。不要吞掉 save failure。

### 风险 C：Query 统一 comparator 改变旧排序

处理：先把当前三种实现的差异转成显式 fixture，由产品语义决定唯一答案；必要时给 persisted view config 加 version，而不是按 caller 保留三套比较器。

### 风险 D：外部配置依赖 public legacy function

处理：deprecation warning + replacement + 发布窗口；删除前扫描仓库示例、插件和文档。不要把“可能有人用”当作永久保留理由。

### 风险 E：大同步器拆分引入行为变化

处理：本轮只在内部标记 extractor/resolver/reconciler/writer 边界，先依赖现有 complete-snapshot contract。物理拆文件放到调用语义稳定之后。

## 9. 推荐执行顺序

```text
Contract tests / static guards
  -> Document save-before-project
  -> Canonical mutation/event
  -> Query value semantics
  -> Automation single runtime
  -> Legacy deletion and naming cleanup
```

这个顺序不是按“底层优先”排，而是按风险传播排：先堵住能破坏 owner 的写路径；再统一所有下游依赖的 commit 事实；之后才能安全拆 Query 和 Automation；最后删除兼容层。

## 10. 代码开工门槛

开始 Phase 1 前，必须同时满足：

- 最终架构文档明确 `O/S/P` owner 和写入方向；
- create/delete/demote 的失败语义已写成测试用例；
- canonical change envelope 的最小字段确定；
- legacy event bridge 是单向且有删除 gate；
- 明确不引入第二个 Store/Repository/View Runtime；
- 当前 worktree 的用户修改被识别并避开。

上述首批门槛已经满足，且 C1–C5 已完成。下一刀不是移动文件或直接迁移 consumer，而是为 M2b 建立 legacy `(path old new)` 形状/顺序/双发 parity tests；只有 bridge 独立保持绿灯后，才接入第一个 production writer。
