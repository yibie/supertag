# task_ownership_separation_20260812

## M0 — Ownership & Safety

- task001 [x] 固定 Ownership Constitution、领域术语与迁移地图
  - 产出：`CONTEXT.md`、`doc/OWNERSHIP-CONSTITUTION_cn.md`、phase spec/plan/tech-refer/ADR/task/change，以及 README/ontology/plugin guide 的 ownership 表述修正
  - 验证方式：每个 durable predicate 恰好一个 owner；每个 derived predicate 有 rebuild source；Markdown link/术语检查与 `git diff --check`
  - 影响范围：仅文档，不修改 runtime 或用户数据
  - 完成：2026-08-12；验证结论见 `change_ownership_separation_20260812.md`

- task002 [x] 建立最小 Vault fixture 与 Semantic Fact fingerprint
  - 产出：两文件 fixture，覆盖 node、Tag Occurrence、schema、field value、Document Link、Semantic Edge、Board、Automation 与 saved query；提供重扫前后 semantic snapshot helper
  - 验证方式：fixture 可重复创建；snapshot 能检测任一 semantic collection 被修改或丢失
  - 影响范围：`test/`、测试 helper
  - 完成：2026-08-12；3 项 ownership ERT、新增文件 byte-compile、提交态临时 clone 全量 416 项 ERT 全部通过

- task003 [x] 正式声明 durable roots 并强化持久化验证
  - 产出：将 `:automations`、`:sync-conflicts` 等真实 durable roots 纳入 Store contract；保存重读验证覆盖全部 semantic-owned collections
  - 验证方式：注入 fields/boards/automations 丢失时保存验证失败；正常 canonical round-trip 通过
  - 影响范围：`supertag-core-store.el`、`supertag-core-persistence.el`、persistence tests
  - 完成：2026-08-12；定向 persistence/canonical ERT 51/51 通过；提交态临时 clone 全量 ERT 420/420 通过

- task004 [x] 修复 node delete 的 relation/field 清理完整性
  - 产出：node delete 通过 relation operations 清理关系，并同时清理 legacy `:fields` 与 global `:field-values`
  - 验证方式：删除后无 dangling relation、field value、from/to index entry；transaction rollback 可恢复
  - 影响范围：`supertag-ops-node.el`、relation/field tests
  - 完成：2026-08-12；定向 node/transaction/field-reference ERT 39/39 通过；提交态临时 clone 全量 ERT 422/422 通过

- task005 [x] 修正 Document Projector 的身份与增量 parity
  - 产出：ID-less heading 不再产生不可持久身份；hash 覆盖全部 Document Facts；point/full sync 使用同一 reconciliation
  - 验证方式：重复扫描不产生漂移 ID；只改 schedule/deadline/ref-to 也被发现；point/full 结果一致
  - 影响范围：`supertag-services-sync.el`、sync regression tests
  - 完成：2026-08-12；定向 sync/Stream/相关 consumer 回归通过；修改文件 byte-compile 成功；干净临时 clone 全量 ERT 426/426 通过

## M1 — One-way Document Projection

- task006 [x] 分开 Tag Occurrence 与 Semantic Tag
  - 产出：scanner 只记录 occurrence；未知 token 进入 unresolved projection/diagnostic，不再由 reindex 静默创建或修改 Semantic Tag
  - 验证方式：新 token 仍可 completion/query；reindex 不改变 semantic Tag/schema fingerprint
  - 影响范围：sync、tag resolution、completion/query fixtures
  - 完成：2026-08-12；定向 ownership/extractor/tag-path/sync/query/Stream/Smart Key/Tag merge 回归通过；干净临时 clone 全量 ERT 427/427 通过

- task007 [x] 将 Document Link 导入改为纯 Projection
  - 产出：document-link import 使用无 Org 副作用的写入路径；relation/projection 记录明确 kind/origin
  - 验证方式：reindex 前后所有 Org file hash 不变；link projection parity 通过
  - 影响范围：sync、relation ops/index、reference tests
  - 完成：2026-08-12；ownership 6/6、relation/field-reference/sync/node 定向回归 39/39；干净临时 clone 全量 ERT 427/427 通过

- task008 [x] 提供准确的 Org reindex 命令与契约
  - 产出：`supertag-reindex-org`；旧 full-rescan command 作为兼容入口并明确不是 Semantic Restore 或 whole-store reset
  - 验证方式：清空 Document Projection 后可重建；Semantic Fact fingerprint 不变；snapshot incomplete 时无删除
  - 影响范围：sync command、menu/setup/git fallback、README/docs、tests
  - 完成：2026-08-12；定向 ERT 58/58 与 62/62、干净临时 clone 全量 ERT 429/429 通过；修改文件 byte-compile 成功

- task009 [x] 新 Reference 改为单一 forward Document Link
  - 依赖：复用并完成 `phase-sync-integrity-20251226/task013` 的旧 reciprocal 审计结论
  - 产出：新 reference 只修改 source Org；target Backlink 通过 `relations-to` 查询
  - 验证方式：新建 reference 只改变一个 Org 文件；Node View/Table Refs 显示 derived backlink
  - 影响范围：relation commands、UI commands、Node/Table views
  - 完成：2026-08-12；source/target 文件哈希、heading/file-node reproject、field-reference 零 Org 写入及三个 Backlink consumer 已由稳定 ERT 覆盖；干净临时 clone 全量 ERT 437/437 通过

- task010 [x] 提供旧 ambiguous reciprocal link 的确认式迁移
  - 产出：read-only preview、逐项选择、确认/abort、文件 snapshot；默认不删除
  - 验证方式：dry-run/abort 零写入；只处理用户确认条目；失败恢复文件
  - 影响范围：migration command、reference docs/tests
  - 完成：2026-08-12；read-only preview、空选择/拒绝确认零写入、confirmed-only 精确删除、投影中途失败恢复文件与 Store 均由 4 项稳定 ERT 覆盖；干净临时 clone 全量 ERT 441/441 通过

- task011 [x] 统一 Tag membership 的 Org-first 写入
  - 产出：add/remove/change Tag 及 Automation Tag action 先保存 Org，再 point reindex；Store 不提前写 membership
  - 验证方式：Org 写失败时 Projection 不变；成功后 occurrence/membership 收敛且事件只触发一次
  - 影响范围：UI commands、service-org、automation、completion、capture、sync
  - 完成：2026-08-12；UI/Automation/Completion/Capture 共用 save→point reindex 路径，heading 与 file-node 均由 Org occurrence 驱动；保存失败不写 Projection 且清理 internal-save marker，成功 membership/field lifecycle 收敛并只发一次 node event；4 项 Org-first ERT 与既有 Tag path 失败恢复语义覆盖，干净临时 clone 全量 ERT 446/446 通过

## M2 — Semantic Separation

- task012 [x] 从 node plist 迁出 Semantic Facts
  - 产出：只迁移实际存在的 DB-only node extension keys；删除 `standard-keys` unknown-key merge
  - 验证方式：Document node 可由 Org parse 完整替换；reindex 不丢 semantic annotations
  - 影响范围：node model、sync、persistence/migration tests
  - 完成：2026-08-12；审计未发现需要新建 `:node-annotations` 的独立权威事实；唯一生产 semantic extension writer（relation field sync）已迁至既有 `:field-values`，rollup 保持纯派生；file/point/full reindex 均删除 legacy unknown key 并保留 field value，定向 ERT 36/36、干净临时 clone 全量 ERT 449/449 通过

- task013 [x] 对 legacy/global fields 执行正式 dry-run audit
  - 产出：字段 definition/value mapping、冲突、孤立值、覆盖策略和备份报告；不写数据
  - 验证方式：逐 node/field parity report 可重复，冲突 fail closed
  - 影响范围：migration、field fixtures、docs
  - 完成：2026-08-12；新增确定性 `supertag-migration-audit-global-fields`，覆盖 definition/association mapping、`:extends` inherited values、逐 node/field parity、global-only preservation、冲突/orphan blocking 与磁盘/完整 Store backup SHA；旧 force-write 入口在任何冲突或 orphan 时零写入；ownership ERT 11/11、field/view/transaction 定向 ERT 71/71、修正 runner 后干净临时 clone 全量 ERT 462/462 通过

- task014 [x] 将 global field model 设为唯一生产读写路径
  - 产出：新写入仅进入 `:field-definitions/:tag-field-associations/:field-values`；legacy `:fields` 只保留 migration reader
  - 验证方式：Table/Node/Kanban/Automation 在迁移前后结果一致；legacy bucket 不再增长
  - 影响范围：field/schema ops、views、automation、migration
  - 完成：2026-08-12；删除生产 field/schema/view/query/capture/automation 的 legacy 分支与事件订阅，废弃且忽略 `supertag-use-global-fields`；真实迁移先保存 live-Store backup，再在单个 Store transaction 写入三个 global collections，失败恢复且 legacy source 不变；field display rename 保留稳定 ID/value，并由 Query/Automation/sync 共用 resolver；定向 ERT 125/125、干净临时 clone 全量 ERT 465/465、20 个修改生产文件 byte compile、`check-parens` 与 `git diff --check` 通过

- task015 [x] 分开 document-link、field-reference 与 semantic-edge
  - 产出：Document Link 和 field-reference 是 Projection；field value 拥有 reference field；custom/Notion relation 是 Semantic Edge
  - 验证方式：删除并重建前两类不影响 Semantic Edge；field value 改变后 edge projection 收敛
  - 影响范围：relation/field ops、query model、automation
  - 完成：2026-08-12；同节点对三类 relation 共存、Projection 删除/重建、field-owner 收敛与 Notion Semantic Edge 已由稳定 ERT 覆盖；完整验证结论见 `change_ownership_separation_20260812.md`

- task016 [x] Stable Semantic Tag ID migration dry-run
  - 产出：old ID → stable ID、canonical name、unique aliases、inheritance/schema/reference mapping；只生成报告与备份计划
  - 验证方式：alias conflict、inheritance cycle、unresolved occurrence 均被检出；dry-run 零写入
  - 影响范围：tag migration、fixtures、docs
  - 完成：2026-08-12；新增确定性 `supertag-migration-audit-stable-tags`，以 namespaced SHA-256 前 128 bit 生成 `tag-<32hex>` proposed ID；报告覆盖 reverse/alias、`:extends`、global schema、membership/occurrence、relation、Tag field default/value、Automation、Board、saved query 与 loaded view，并给出完整 Store/磁盘/config fingerprint 备份计划；alias 一对多、继承环、missing owner 与 unresolved occurrence 全部 fail closed；ownership ERT 16/16、Tag/Query 定向 ERT 85/85、只含 HEAD + task016 patch 的干净临时 worktree 全量 ERT 468/468 通过

- task017 [x] 执行 Stable Semantic Tag 与 resolver 迁移
  - 产出：token → stable ID resolver、derived membership；rename 只改 canonical name/alias；Org token 改写为独立 migration
  - 验证方式：旧 token 通过 alias 继续解析；alias 一对多 fail closed；rename 不重写 node/relation/field/board/automation
  - 影响范围：tag/schema/relation/query/completion/migration
  - 完成：2026-08-12；新 Tag 使用 UUID-derived `tag-<32hex>` 稳定身份，统一 resolver 解析 ID/canonical/path/alias 且歧义 fail closed；task016 audit 通过后可先完整备份再事务性切换所有 Tag 引用，失败恢复；semantic rename 不写 Org，显式 token migration 独立审计、snapshot、精确改写并 reindex；干净临时 worktree 全量 ERT 477/477、14 个修改生产文件 byte compile、`check-parens` 与 `git diff --check` 通过

## M3 — Query Model

- task018 [x] 建立统一 cold rebuild contract
  - 产出：relation from/to、Tag descendants/display paths、nodes-by-tag、resolved schema、automation rule indexes 统一清空/重建入口
  - 验证方式：clear → cold rebuild 前后查询结果一致；load/rollback 后自动恢复
  - 影响范围：core-index、schema/automation caches、persistence/transaction hooks
  - 完成：2026-08-12；ownership ERT 26/26、跨模块定向 ERT 158/158、只含 HEAD + task018 patch 的干净临时 worktree 全量 ERT 482/482 通过；14 个修改生产 Elisp 与 performance benchmark byte compile 成功（仅仓库既有 warning），全部修改 Elisp `check-parens` 与 `git diff --check` 通过

- task019 [x] 在现有 query 模块提供具体、非泛化读取接口
  - 产出：node、Tag paths、nodes-by-tag、resolved fields、field value、relations from/to/among、node detail、board detail、node query 等真实查询
  - 验证方式：每个接口至少一个生产 consumer 和 parity test；不新增 arbitrary collection/path read
  - 影响范围：`supertag-services-query.el`、`supertag-view-api.el`、query tests
  - 完成：2026-08-12；query-model ERT 6/6、ownership 26/26；干净临时 worktree 全量 ERT 488/488；5 个修改文件 byte-compile 零新增 warning、check-parens、`git diff --check` 通过；`resolved-fields`/`relations-*` 的外部消费者按计划由 task021/task022 接入

- task020 [x] 迁移 Completion、Tag picker 与 Stream
  - 产出：统一消费 Tag display path 与 nodes-by-tag projection
  - 验证方式：nested/unresolved/duplicate/cycle cases、descendants、Stream date/title/tag order 无回归
  - 影响范围：completion、schema picker、Stream tests
  - 完成：2026-08-12；smart-key+tag-path 55/55、stream 定向回归、ownership 26/26、query-model 7/7、两个 completion self-check 通过；干净临时 worktree 全量 ERT 489/489；`get-all-tags` 改为 display-path 排序后三处既有测试全部通过

- task021 [x] 迁移 Node、Table 与 Kanban
  - 产出：统一 resolved fields、node field value、relations from/to 和 node detail；移除 view 内重复 join
  - 验证方式：field order/default/formula/reference/filter/sort/expanded row/selection parity
  - 影响范围：Node/Table/Kanban、services-ui、view tests
  - 完成：2026-08-13；view/table/kanban/node 定向 59/59、view-runtime 除隔离的 TextUI 实验外全过；干净临时 worktree 全量 ERT 489/489

- task022 [x] 迁移 Board 与 Graph
  - 产出：Board/Graph 使用 board detail、node summaries 与 relations-among
  - 验证方式：missing node、board-local/global edge、groups、viewport、WS DTO parity
  - 影响范围：board backend、graph UI、Board frontend contract tests
  - 完成：2026-08-13；query-model 的 board-detail/WS DTO parity 测试通过；干净临时 worktree 全量 ERT 489/489；无 frontend contract test（ext/ 无测试目录）

- task023 [x] 迁移 Query Block 与 Saved Query executor
  - 产出：只调用公开 node-query interface，不再调用私有 parser/executor/field getter
  - 验证方式：AND/OR/NOT、日期边界、term、field nil/default、Org output parity
  - 影响范围：query block、query library、query docs/tests
  - 完成：2026-08-13；query 定向 28/28（含 AND/OR/NOT、日期边界、field 渲染）；干净临时 worktree 全量 ERT 489/489

- task024 [x] 最后迁移 Automation 读取路径
  - 产出：rule index 从 query interface 重建；Document actions 与 Semantic actions 分别走对应写入模块
  - 验证方式：trigger 恰好一次、scheduler restart、recursion guard、tag/field/relation conditions parity
  - 影响范围：automation、automation-sync、scheduler/tests
  - 完成：2026-08-13；automation-scheduled self-check 通过、sync-worker/query-model/ownership 47/47；干净临时 worktree 全量 ERT 489/489

- task025 [x] 收敛 formula/rollup 语义
  - 产出：纯 evaluator 成为唯一计算实现；materialized result 明确 owner
  - 验证方式：Table、virtual column、Automation 对同一输入得到相同结果
  - 影响范围：formula、virtual column、automation、relation ops
  - 完成：2026-08-13；rollup 归约统一到 `supertag-rollup-apply`，Automation formula 委托共享服务；确认 rollup 无 materialization（全部派生，死代码写回分支已删）；{{}} 与表达式两种公式语法服务于不同配置表面，语法统一不在本 task 范围

- task026 [x] 封住 raw Store read seam
  - 产出：私有化/删除 `supertag-view-api-get-collection` 与 generic collection/path query；subscriptions 改为语义失效通知
  - 验证方式：`rg` 证明 UI/View/Completion/Automation 无 raw collection access；全量 parity suite 通过
  - 影响范围：view/query interface、all consumers、plugin guides
  - 完成：2026-08-13；`supertag-view-api-get-collection` 已删除；rg 审计 UI 层零 raw access（仅 automation ops CRUD 例外）；subscriptions 已用语义事件；干净临时 worktree 全量 ERT 490/490

## M4 — Durable Config & Cleanup

- task027 [x] 将 persisted Queries/Views 迁入 semantic store
  - 产出：正式 `:queries/:views` collections；Customize/export file 一次性导入与 delete/update semantics
  - 验证方式：重启、Tag rename、Git merge 后引用不复活、不丢失；迁移可回滚
  - 影响范围：query library、view framework、persistence/merge/migration
  - 完成：2026-08-13；:queries/:views 成为 durable roots；legacy defcustom 一次性导入（先存 Store 成功再清空，可回滚）；干净临时 worktree 全量 ERT 491/491

- task028 [x] 删除 legacy roots/interfaces 并完成 phase 验收
  - 产出：删除 legacy `:fields` 生产路径、无效 `:embeds` collection、raw Store interfaces 与误导 rebuild 文案
  - 验证方式：migration fixtures、backup restore、完整 ERT、byte compile、`git diff --check`；用户确认后关闭 phase
  - 影响范围：core/store/persistence、docs、all regression suites
  - 完成：2026-08-13；:embeds 从 durable roots 移除（无生产读写）；legacy :fields 生产写路径 task014 已删、仅 infra 保留；raw 接口 task026 已封；文案 task001 已修；干净临时 worktree 全量 ERT 491/491。**Phase 关闭待用户确认**

## Deferred Gate

- SQLite 不属于本 phase task。只有 task028 完成、出现经过测量的需求并证明第二个 implementation 真实存在后，才单独创建 ADR/phase。

## Maintenance

- task029 [x] 统一 heading identity 与 Store-first location contract
  - 关联：GitHub #186–#190
  - 产出：修复无 ID source 的 create-and-reference；新增 `supertag-service-node-identity.el`；迁移所有 runtime creation/navigation callers；删除业务模块的直接 Org ID cache lookup/registration
  - 验证方式：source 有/无 ID、relation projection failure、unownable source；空 cache 下 ordinary create/capture/completion/concept/id-link/direct/Graph/Board/Automation；静态 boundary guard；完整 ERT、临时 byte compile、`check-parens`、`git diff --check`
  - 完成：2026-08-24；详细结果见 `change_ownership_separation_20260812.md`
