# change_ownership_separation_20260812

## 2026-08-24 — task029 Node identity / location boundary

- Fix `supertag-add-reference-and-create`：source ID 插入前把 region 转为 markers；source 不可拥有 relation 时在 target mutation 前失败；Org link 保存并 point projection 后必须确认 `:document-link/:org` relation 才报告成功。
- Add `supertag-service-node-identity.el`：统一生成/持久化 heading ID；从 Store-recorded file 直接搜索 in-file ID；只有 Store 完全未知的 legacy node 可进入 `org-id-find` compatibility fallback，已投影但文件/ID 损坏时 fail closed。
- Modify ordinary create、reference create、Capture、Completion、Concept、migration、direct navigation、Org id-link、Graph、Board 与 Automation：全部调用统一边界，不再直接查询或注册 Org ID location cache；删除误导的 `supertag-id-utils.el` 注释与 Org service middle-man wrapper。
- Add runtime boundary guard 与空 cache workflow regressions：覆盖 source 有/无 ID、projection false-success、ordinary create、capture、completion、concept、id-link、direct/Graph/Board navigation、Automation source resolution、missing Board node diagnostic 与 stale-cache refusal。

Behavior：Org 仍拥有 heading `:ID:` Document Fact，Store 只拥有可重建的 file projection。标准 `id:` link 保持兼容，但 runtime correctness 不再依赖 `org-id-locations`；已知 node 的 Store location 损坏会给出诊断，而不是跳到 cache 中的陈旧位置。

Risk：Store 尚未投影的 legacy heading 仍可通过 boundary 内的显式 `org-id-find` fallback 定位；该兼容路径受静态 guard 限制，不允许扩散回 feature modules。create-and-reference 在 link 已保存但 relation projection 失败时保留可见 Org edit/target node并报错，避免伪装跨文件事务或误报成功；后续 reproject 可收敛。

Verification：最终定向 identity/add-reference/tag-membership/concept/tag-path 90/90，identity 边界 16/16；完整 ERT 549 项中 547 通过、2 项既有 interactive dashboard 测试 skipped、0 unexpected；修改生产 Elisp 临时 byte compile 与隔离 package load 成功（仅仓库既有 warning）；`check-parens`、runtime Org ID boundary `rg` 审计与 `git diff --check` 通过；Standards/Spec 双路复审均无剩余 finding。

## 2026-08-12 — task018 统一 derived index cold rebuild contract

- Add `supertag-index-clear-all` / `supertag-index-rebuild-all`：以一个 generation 清空并重建 relation from/to、Semantic Tag token/display path/descendants、nodes-by-tag、global field lookup/order、resolved schema 与 Automation rule index；任一 builder 失败会再次清空全部派生状态并原样抛错，不暴露混合 generation。
- Add Store collection revision token：canonical entity/collection/field-value 写入递增 source revision；Tag、node membership、relation、resolved schema 与 rule 查询在 Store identity/revision 变化后 lazy cold rebuild。Relation CRUD 保留 O(1) 增量维护，raw canonical Store relation 写入也不能泄漏旧索引。
- Modify lifecycle：成功加载、空/失败加载、手动 migration、Org reindex 收尾、Tag merge/migration 与 transaction rollback 统一调用同一 rebuild boundary；删除 schema/relation 各自的 rollback hook 和初始化阶段的重复 schema rebuild。
- Modify nodes-by-tag：把原 `:nodes` O(N) 查询迁入冷构建 membership index，保留原 Store traversal 顺序；Tag resolver、display path 与 descendants 同样从热路径扫描改为索引查询。
- Modify Automation Sync、View API 注释和 performance baseline：所有直接 rule-index consumer 先确保 source generation；benchmark 区分 indexed Tag lookup 与仍为 O(N) 的全文扫描。

Behavior：加载、rollback、reindex 或显式 `M-x supertag-index-rebuild-all` 返回后，所有已加载的 Store-derived query cache 属于同一份 Store generation。`supertag-index-clear-all` 只删除可重建内存状态，不修改 Org、Semantic Facts 或 Document Projection。

Risk：Tag descendants 的冷构建当前显式为 O(T²)，只发生在 cold rebuild；只有实测 Vault 启动时间证明它成为瓶颈时才改为 child adjacency walk。UI node TTL、SVG、schema definition registry 与 virtual-column cache 不由 Store 事实直接重建，故不塞进本 contract；virtual-column 生命周期仍由 task025 收敛。

Verification：先写回归并确认缺少统一入口、同 Store relation 写入的 stale index 会失败；实现后 ownership ERT 26/26、transaction/Tag merge/Tag path/persistence/node/query 定向 ERT 158/158；只含 HEAD + task018 patch 的干净临时 worktree 全量 ERT 482/482；14 个修改生产 Elisp 与 performance benchmark byte compile 成功（仅仓库既有 warning）；全部修改 Elisp `check-parens` 与 `git diff --check` 通过。用户未提交的 dashboard/Archive/Board hook/textui 实验未进入 patch 或验证。

## 2026-08-12 — task017 Stable Semantic Tag cutover 与统一 resolver

- Modify Semantic Tag identity：新建 Tag 使用 UUID-derived `tag-<32hex>` 稳定 ID；canonical name、display path 与 alias 不再承担实体身份，所有 token claim 在 semantic write boundary 全局唯一。
- Add `supertag-tag-resolve-occurrence`：稳定 ID、canonical name、显式 `:extends` display path 与旧 alias 统一返回稳定 ID；零 owner 返回 nil，多 owner fail closed。Node `:tags` / `:node-tag` 只保存 derived stable membership，`:tag-occurrences` 保留 Org token。
- Modify Completion、picker、Capture、Automation、Query、Stream/Schema 与 Org service：UI 只显示并写入 canonical token/path，stable ID 通过 text property 或 operation 参数传递，不泄漏到 Org；rename 后旧 token 继续通过 alias 命中同一 Tag。
- Modify semantic rename：只更新 canonical name/alias，保留 ID、schema、field value、relation、Board、Automation、saved query、loaded view 与 Org 文件。Tag merge 同时支持 legacy fixture 与 stable participant，文件只写 canonical target token。
- Add `supertag-migration-run-stable-tags` apply：每次写入前重跑 task016 audit；unsafe 零备份/零写入，safe 时备份 live Store、已有磁盘 DB 与 query/view config，再在一个 Store transaction rekey 全部审计引用并重建 derived state；失败恢复 Store/runtime config 且保留备份。
- Add `supertag-migration-rewrite-tag-token`：默认只读审计 complete Vault snapshot，要求 old/new token 唯一指向同一 owner；prefix execution snapshot 受影响文件，只改 exact inline/`#+FILETAGS` occurrence 后 reindex，写入或 projection 失败时恢复文件并再次 reindex。

Behavior：Semantic Tag 的身份现在与显示名分离。用户重命名 Tag 后，已有 Org `#token` 不会被批量打开或改写，仍通过 alias 正确查询；只有用户明确运行独立 token migration 才会统一文本。嵌套关系仍只由 `:extends` 表达，斜杠只作为 completion 操作/display path。

Risk：当前 resolver 是显式 O(Tag) 单一扫描，避免在 task018 的统一 cold rebuild contract 前引入局部 cache 与第二套失效语义。一次性 Stable cutover 会修改多个 durable collection，因此仍要求 task016 完整 audit 与自动备份；任何 ambiguous alias、unresolved occurrence、missing owner 或 rebuild failure 都 fail closed。

Verification：稳定创建/resolver/歧义、rename identity、旧 alias Query/Automation、完整 cutover mapping/backup、unsafe 零备份、rollback、显式 inline + `#+FILETAGS` rewrite/recovery、canonical Org writes 与 stable merge 均有回归；只含 HEAD + task017 patch 的干净临时 worktree 全量 ERT 477/477；14 个修改生产 Elisp 文件 byte compile 成功（仅仓库既有 warning），全部修改 Elisp `check-parens` 与 `git diff --check` 通过。用户未提交的 dashboard/textui 实验未进入 patch 或验证。

## 2026-08-12 — task016 Stable Semantic Tag ID dry-run

- Add `supertag-migration-audit-stable-tags`：确定性生成 name-based old ID → `tag-<32hex>` proposed stable ID、stable → old reverse mapping、canonical name 与 normalized alias owner 表；已经符合 stable shape 的 ID 保持不变。
- Add identity fail-closed gate：重复 alias/proposed ID、malformed Tag/alias、missing parent、inheritance cycle、missing membership/schema/Tag-field owner 与 unreadable saved query 全部进入 conflict；零 owner 或多 owner 的 Org occurrence 单列为 unresolved 并阻断 apply。
- Add complete reference mapping：覆盖 `:extends`、`:tag-field-associations`、legacy field bucket/Tag field default、node membership/occurrence、relation endpoints/新 relation ID、global Tag field default/value、Automation、Board、saved query 与 loaded view；真实 `(:type :tag :value ID)` query object 也进入映射。
- Add backup plan：完整 Store、当前数据库文件、collection counts、saved queries 与 loaded views 都生成 count/SHA-256 fingerprint 并标记 apply 前必须备份；task016 不创建备份、不写 Store/Org/config。
- Add ownership regressions：正常 fixture 证明两次报告完全相同且 9 类 mapping 齐全；冲突 fixture 同时证明 alias ambiguity、inheritance cycle 与 unknown occurrence fail closed。

Behavior：用户可运行 `M-x supertag-migration-audit-stable-tags` 在 `*supertag-migration*` 查看完整 proposed migration。只有 `:safe-to-apply t` 才说明 task017 可以进入真实备份/写入；task016 本身没有 apply 入口。

Risk：proposed ID 使用 namespaced SHA-256 前 128 bit，由 old ID 确定，确保同一 Store 的 dry-run 可重复；它只决定一次性 cutover identity，task017 后 canonical rename 不重新计算 ID。扫描与排序是显式一次性 O(Store references) 操作，不进入日常 query path。旧 `:fields` 仅作为不透明 Tag payload 保留，生产 schema mapping 只认 task014 已确立的 global collections。

Verification：红测先因 audit 命令不存在失败；实现后 ownership ERT 16/16，Tag merge/path 与 Query 定向 ERT 85/85，只含 HEAD + task016 patch 的干净临时 worktree 全量 ERT 468/468；`check-parens`、`git diff --check` 通过，修改生产文件 byte compile 成功且只有仓库既有 warning。当前用户工作树的完整 runner 为 466/468，两项额外失败来自未提交 dashboard 修改依赖未安装的 `textui`，其文件与测试不在 task016 patch，干净基线已证明 task016 全绿。

## 2026-08-12 — task015 Relation Ownership 分型

- Modify relation identity 与 validation：所有新 relation 明确记录 `:kind/:origin`；Document Link 与 Field Reference 可在同一 endpoints 上共存，后者再按 stable field-id 区分；legacy unowned `:reference` 保留为 `:legacy-reference`，不猜 owner。
- Reverse Field Reference ownership：global field value 成为唯一 authoritative fact；field set/remove 在同一 Store transaction 中先改值，再只 reconcile 该 field-id 的 Projection；删除 relation 不再回写 field 或修改 document node facts。
- Modify projection rebuild：batch reconcile 从 node `:ref-to` 重建 Document Link，并从 `:field-values` 的 `:node-reference` definitions 重建 Field Reference；stale/改型 field projection 被删除，Semantic Edge 保留。
- Modify Semantic Edge consumers：custom/Notion create 默认写入 `:semantic-edge/:semantic`；Query 可按 kind 过滤，Automation sync、relation rollup 与 virtual columns 只遍历 Semantic Edge；Table 删除重复且越权的 relation diff。
- Add issue044 与 ownership regressions：同一节点对同时保存三类 relation；删除并重建两个 Projection 不改变 Semantic Edge/field value；字段清空只删除自己的 Field Reference；Notion relation owner 明确。

Behavior：Org link、node-reference field 与 custom relation 不再因为 endpoints 相同而互相覆盖或删除。用户修改 reference field 后，global field value 先落盘语义 Store，Field Reference 只作为可重建查询投影收敛；Org reindex 不会删除 Semantic Edge。

Risk：旧版完全无 `:kind/:origin` 的 `:reference` 无法可靠判断来自 Org、field 或 generic semantic reference，因此保留为 `:legacy-reference`；新 Projection 可与它共存，Automation 不消费它。统一 load/rollback cold rebuild 与 legacy cleanup 仍属于 task018/task028，不在本任务新增第二套 index/backend。

Verification：红测先证明旧 query interface 无 kind 且三类 relation 不能共存；实现后 relation/field/query/Table/virtual/add-reference/ownership 定向 ERT 84/84，只含 HEAD + task015 patch 的干净临时树完整 ERT 466/466；7 个修改生产文件 byte compile 成功（仅既有 warning），`check-parens` 与 `git diff --check` 通过。当前工作树完整 runner 的两项额外失败来自用户未提交 dashboard 修改依赖未安装的 `textui`，该文件未进入 task015 patch，干净基线验证已通过。

## 2026-08-12 — task014 global field 唯一生产读写路径

- Delete field/schema/tag/relation、Table/Node/Kanban/Schema、Query/Capture/Org export 与 Automation 中的 `supertag-use-global-fields` 分支、legacy value/schema fallback 和 `:fields` 事件订阅；生产写入只进入 `:field-definitions`、`:tag-field-associations`、`:field-values`。
- Modify compatibility option：`supertag-use-global-fields` 保留为 obsolete variable 以避免旧配置报错，但任何值都不会重新打开 legacy 路径；新 Tag 直接携带 `:fields` 会 fail closed。
- Modify field identity：字段显示名修改只更新共享 global definition，稳定 field ID 与 node value 不移动；公共 resolver 先查 Tag schema，再查 global definition，使 Query、Automation trigger/evaluator 与 relation sync 按同一 ID 工作。
- Modify migration apply：force-write 在正式 audit 通过后，先把当前 live Store 原子序列化到 `backups/supertag-db-preglobal-fields-*.el`，再用一个 Store transaction 写 definition/association/value；失败回滚 global collections，备份与 legacy source 保留。
- Modify tests/docs：以同一 fixture 证明 Table/Node/Kanban/Automation cutover parity、legacy bucket 不增长、失败回滚、自动备份与 display rename 稳定 ID；迁移指南和自动化手册删除 opt-in/legacy 生产语义。

Behavior：当前版本无需也不接受字段模式切换。旧数据库先运行 `M-x supertag-migration-audit-global-fields`；只有 `:safe-to-apply t` 才可执行真实迁移。迁移后所有日常字段、schema、view、query、capture 和 automation 立即读取全局集合。

Risk：global field definition 为共享事实，同一 field ID 的显示名/类型修改会影响所有关联 Tag。legacy `:fields` root、持久化/merge/transaction 兼容 seam 暂留到 task028，但生产 API 不再读取或增长它。自动备份不会替代用户对整个 data directory 的外部备份。

Verification：ownership 回归先锁定 global-only 写入、四类 consumer parity、legacy 事件不再触发、rollback/backup 与稳定 ID；field-reference 单测补齐直接 sync dependency 后可独立运行。定向 ERT 125/125；只含 HEAD + task014 staged patch 的干净临时 clone 全量 ERT 465/465；20 个修改生产 Elisp 文件 byte compile 成功（仅既有 warning）；`check-parens`、`git diff --check` 通过。

## 2026-08-12 — task013 legacy/global field 正式 dry-run audit

- Add `supertag-migration-audit-global-fields`：只读生成排序后的 definition、association 与逐 node/field value parity；同一逻辑 Store 不受 hash insertion order 影响。
- Add ownership mapping：legacy value 可沿 `:extends` 使用父 Tag 字段；同一 sanitized field ID 的定义除 display name/ID 外必须一致，同一 node/field 的多个 legacy source value 也必须一致。
- Add fail-closed preflight：definition/association/global value 不同、malformed definition/association、同 ID display-name collision、重复 field ID、missing node/tag/definition、Tag 不属于 Node 与 undeclared legacy value 全部进入 conflict/orphan，`:safe-to-apply` 为 nil。
- Add coverage/backup report：明确 missing→create、equal/global-only→preserve、different/source collision/orphan→block；记录完整数据库备份要求、全部 collection counts、磁盘 SHA-256 与完整内存 Store SHA-256。
- Modify legacy migration command：默认 dry-run 复用正式 audit；force-write 在任何 conflict/orphan 时于首个 mutation 前报错，不再把不同 global value 计为普通 skipped。
- Modify migration guide/tests：先 audit、后启用 global model；回归覆盖重复报告、反向重插 hash 表、Store/数据库文件零变化、继承字段、malformed/冲突阻断与三类 orphan；删除 Smart Key 测试文件的提前 batch exit，让正式 runner 首次真正加载后续 embed/ownership suites。

Behavior：用户可直接执行 `M-x supertag-migration-audit-global-fields`，无需先启用 global fields。交互调用在 `*supertag-migration*` 按 section 输出完整报告；只有 `:safe-to-apply t` 才允许旧 apply 入口继续。

Risk：audit 是显式 O(definitions + associations + values) 操作，并为确定性报告做排序；它是一次性迁移 preflight，不进入日常读写路径。实际生产 cutover 与 legacy bucket 停止增长仍属于 task014。

Verification：回归先因 audit 入口不存在、force-write 不阻断而失败；实现后 ownership ERT 11/11，field/view/transaction 定向 ERT 71/71，runner tail suites 25/25；修正 runner 后干净临时 clone 全量 ERT 462/462（旧 449 项结果实际在 Smart Key 后提前退出）；修改文件 byte compile 成功且只有既有 warning，`check-parens`、`git diff --check` 通过。

## 2026-08-12 — task012 Node Projection 不再保存未知语义 key

- Delete `supertag--merge-node-properties` 与 `standard-keys` 推断：file/point reconcile 在文档变化时直接以最新 Org parse 替换 Document Projection；完整 reindex 即使 hash 未变也执行替换，因此不会遗留未知 key。
- Modify relation field sync：node 目标值进入既有 global `:field-values`，不再动态扩展 node plist；读取仍兼容旧 source top-level value，正式 legacy/global field dry-run 由 task013 负责。
- Modify relation rollup：结果只作为派生计算值返回，不再把动态 `:rollup-*` 写入 node/tag；统一 evaluator 与 materialization owner 仍由 task025 收敛。
- Modify regressions：删除 task005 的虚构 `:semantic-note` 保留契约，改为证明完整 Org replacement 与独立 field value preservation；新增 semantic field sync 和 non-materialized rollup 覆盖。

Behavior：reindex 会移除旧 node plist 中无法由 Org 重建的未知 extension key；真正的 typed semantic value 仍保存在 `:field-values`，不受 reindex 影响。没有新增第二套 `:node-annotations` collection。

Risk：依赖未声明 top-level node key 的第三方代码不再获得隐式持久化；应改用 field API。现存 legacy/global field 数据的批量映射、冲突与回滚不在本任务猜测处理，进入 task013 的只读审计。

Verification：红测先证明 file/point projector 会保留未知 key；实现后 node 15/15、sync-worker 14/14、ownership 7/7 通过；干净临时 clone 全量 ERT 449/449；修改文件 byte compile 成功（仅既有 warning），`check-parens`、`git diff --check` 通过。

## 2026-08-12 — task011 Tag membership 的 Org-first 写入

- Modify `supertag-service-org.el` / sync：唯一顺序改为 edit Org → save → current-node projection；heading 与 file-node 都从保存后的 `#tag` / `#+FILETAGS` 重建 occurrence、resolved membership 与 `:node-tag` relation。
- Modify UI、Automation、Completion 与 Capture：删除生产入口的 Store-first membership 写入，统一调用 Org service；显式 Semantic Tag creation 保持独立，Org 保存失败时允许保留 definition，但不产生 membership。
- Delete UI 中三份重复 add-tag transaction/文件写入分支与专用插入器；add/remove/change 的正文编辑、批量位置和 file-node 行为由共享 service 承担。
- Modify field lifecycle：复用提取后的 initialize/clear helpers，在 projection 成功后按 membership delta 处理既有字段行为；投影失败不提前改字段值。
- Modify save marker 与 node-local text edit：internal modification key 使用 canonical path 并在成功/失败后清理；remove/replace 只触及当前 node direct section，不再误改嵌套 child heading。
- Modify completion failure contract tests：已经保存的 Org 与新 Org ID 不因后续 Projection 失败而回滚；移除故障后 point reindex 可收敛。Semantic Tag definition 与 derived membership 不再作为一个跨介质事务处理。

Behavior：用户通过命令、补全、Capture 或 Automation 增删 Tag 时，文件保存成功前 Store membership 保持原样；保存成功后只投影目标 node，并产生一次 node change。保存失败时 buffer 保留可见的未保存编辑，磁盘与 Projection 不变。

Risk：选择补全或 Automation Tag action 现在会保存对应 Org buffer，这是保证 Org 主权的必要行为。多文件批量操作不伪装成跨文件原子事务；前面已成功保存的文件保持有效，失败文件仍保留未保存编辑。全局 Tag delete/rename 与 legacy migration 仍由各自迁移边界处理。

Verification：Org-first focused ERT 4/4、node/tag-path 定向 ERT 58/58、`check-parens` 与 `git diff --check` 通过；修改文件 byte-compile 成功（仅既有 warning）；干净临时 clone 全量 ERT 446/446 通过。

## 2026-08-12 — task010 旧 reciprocal link 确认式迁移

- Add read-only `supertag-migration-preview-reciprocal-links`：从一个 complete Vault snapshot 扫描实际 Org link occurrence；互相指向只生成候选，不推断 owner、不默认选择。
- Add `supertag-migrate-reciprocal-links`：逐条选择精确 direction/file/line occurrence，再进行第二次确认；空选择、拒绝确认、不完整 snapshot 与 stale preview 均零写入。
- Modify migration file safety：每个受影响 Org 文件先创建唯一相邻 `.<文件名>.supertag-migration-*.bak`；删除按文件内位置倒序执行，只重投影受影响文件；写入或投影失败时恢复全部文件、visiting buffers、Store transaction、sync/deferred state。
- Modify command discovery/docs/tests：Migration 菜单提供 preview/apply；中英文 README 与 Unreleased Changelog 说明不可推断边界、操作与恢复路径；新增 4 项稳定 ERT。

Behavior：用户先只读查看候选，再明确选择“删除 Source → Target (file:line)”条目并确认。系统只删除选中的物理 link；未选择内容保持原样，成功后 Backlink 由 relation index 重新派生。

Risk：候选扫描是显式 O(Vault size) 操作；这是一次性迁移命令的可接受成本。互相指向不等于旧 backlink，因此候选仍需用户判断。备份默认保留在原文件旁，不自动清理。

Verification：4 项迁移 ERT 覆盖 preview 文件/Store hash 不变、空选择与拒绝确认零写入、只删除确认 occurrence、第二个文件投影失败后恢复首个文件的 Store 变更与全部文件字节；修改文件 byte-compile 与 `check-parens` 通过（仅既有 warning），`git diff --check` 通过，干净临时 clone 全量 ERT 441/441 通过。

## 2026-08-12 — task009 单一 forward Document Link 与派生 Backlink

- Modify document commands：`supertag-add-reference`、create variant 与 remove command 只在 source 的 direct content 写入/删除一条 Org link，保存后通过既有 Document Projector 收敛；target Org 不再打开、写入或补偿回滚。
- Delete reciprocal writer helpers 与 relation 层的 target marker/physical link/`:to-pos` 路径；`supertag-relation-add-reference`、node-reference field 与 Table edit 均成为 Store-only operation。
- Modify file-node Projection：`supertag-sync--parse-file-header` 提取首个 heading 之前的 top-level `id:`/`denote:` links，并将 `:ref-to` 纳入 file-node upsert，避免新 forward link 在下一次同步消失。
- Modify Backlink consumers：Node View 与共享 Node state 删除 raw `:relations` scan，和既有 Table View 一样统一调用 `supertag-relation-find-by-to`。
- Modify docs/tests：README、day-in-the-life、plugin API 与 Unreleased Changelog 明确 forward-only/derived Backlink 契约；add-reference、Denote 与 field-reference tests 进入稳定测试集。
- Complete `phase-sync-integrity-20251226/task013`：旧 reciprocal 与用户正向 link 语法不可区分，但该事实只阻塞自动删除，不再阻塞停止新增；遗留确认式迁移由 task010 负责。

Behavior：用户在 heading 或 file-node 执行 `M-x supertag-add-reference` 时，只有 source Org 出现一条 forward link；target Node/Table 通过反向 relation index 立即显示 Backlink。删除 reference 只删除 source link。字段引用与 relation API 不写任一 Org 文件。

Risk：旧 ambiguous reciprocal text 原样保留，因此在 task010 完成前可能同时投影成 legacy 反向 reference；系统不猜测 owner，也不自动清理。Document Link、field-reference 与 Semantic Edge 的完整分型仍由 task015 负责。

Verification：红测先证明旧实现会改写 target；实现后 add-reference/Denote/field-reference 14/14，reference/Node/Table/ownership 17/17，concept 9/9，干净临时 clone 全量 ERT 437/437 通过；修改文件 byte-compile 成功，仅有既有 warning；`git diff --check` 与 runner shell syntax 通过。

## 2026-08-12 — task008 准确的 Org Reindex Module

- Add `supertag-reindex-org`：只消费一个 complete Org snapshot，并返回 `complete`、`aborted` 或 `failed` report；snapshot partial/unavailable 时零写入、零删除。
- Modify batch projection：所有文件导入后统一 reconcile node-tag 与 Document Link，再重建 relation indexes/backlink caches；消除 source-before-target 的冷重建顺序依赖。
- Modify transaction boundary：file processing、relation join、validation 与 GC 共用一个 Store transaction；失败恢复 sync state、deferred state 与先前 snapshot。
- Keep `supertag-sync-full-rescan` as a compatibility alias；菜单、setup 与 Git clone fallback 统一调用新公开命令，并修复 setup 对不存在的 `supertag-sync-full-initialize` 的调用。
- Modify README、sync guide、Ownership Constitution 与 day-in-the-life 文档：Reindex 只重建 Document Projection，绝不等同于 whole-store reset 或 Semantic Restore。
- Add `issue043` 与三条 public-interface regressions：覆盖冷 Projection 重建、Semantic Fact/Org 文件不变、incomplete snapshot 零处理、legacy alias parity 和处理中途失败回滚。

Behavior：用户现在执行 `M-x supertag-reindex-org`；成功时重建 Org 派生 node、Tag Occurrence、Document Link 及 derived indexes，Semantic Facts 与 Org 文件不变。旧命令仍可用。Git clone 缺失/损坏数据库时只承诺恢复 Document Projection，并明确提示从备份恢复 Semantic Facts。

Risk：reindex 是显式 O(Vault size) 操作，并在批次末尾做一次 O(N+R) relation/cache rebuild；这是消除文件顺序特例的确定性成本。sync-state 保存发生在 Store transaction 成功之后；若本地 state 文件写入失败，重建结果仍有效，下次同步只会保守地重复处理文件。

Verification：新增 public-interface tests 先因 `void-function supertag-reindex-org` 红、实现后转绿；ownership/sync-worker/Git 定向 ERT 58/58，relation/field-reference/tag-path/node 定向 ERT 62/62；`check-parens`、`git diff --check` 通过；干净临时 clone 全量 ERT 429/429 通过；修改文件 byte-compile 成功，仅有既有 warning。

## 2026-08-12 — task007 Document Link 纯 Projection

- Add `supertag-relation-project-document-link`：scanner 使用只写 Store 的 Document Link 投影入口，不再调用会向 target Org 插入 reciprocal link 的 `supertag-relation-add-reference`。
- Add `supertag-relation-document-link-p`：新 Document Link relation 明确记录 `:kind :document-link` 与 `:origin :org`；只补齐已部分分类的记录，完全无 owner 的 legacy reference 保持不变。
- Modify orphan cleanup：Org reindex 只删除 `:document-link/:org` relation，不再把 field-reference 或其他明确归属的 reference 当作缺失 Org link 清除。
- Modify ownership tests：覆盖所有 fixture Org 文件 SHA-256 在 reindex 前后不变、from/to index parity、部分 legacy metadata 补齐、完全无 owner 记录保留，以及 field-reference cleanup isolation。
- Add `issue042`：记录 scanner 复用 reciprocal-link 写命令造成的 Org 双写、修复与真实 Vault 确认项。

Behavior：已有 Org forward link 在同步时只产生可重建 relation projection；不会修改 source/target Org 文件。交互式 reference 创建命令仍保留原行为，直到 task009 将其改成单一 forward Document Link。

Risk：legacy unowned reference 无论是否存在当前 Org occurrence 都不会被猜测或删除，以免误删字段或语义数据；task015 再执行正式分类迁移。清空 Projection 后的完整冷重建仍由 task008 负责。

Verification：两条回归测试先红后绿；ownership 6/6，reference/field-reference/sync-worker/node 定向回归共 39/39；`check-parens`、`git diff --check` 通过；修改文件 byte-compile 成功，仅有既有 warning；干净临时 clone 全量 ERT 427/427 通过。

## 2026-08-12 — task006 Tag Occurrence 与 Semantic Tag 分离

- Modify `supertag-services-sync.el`：extractor 将 Org token 写入 `:tag-occurrences`；Document Projector 只读解析已存在 Semantic Tag，将结果分别存为 resolved `:tags` 与 `:unresolved-tags`；普通 reindex 不再创建 Tag entity。
- Modify `supertag-ops-tag.el`：新增无副作用 occurrence resolver，支持真实 Tag ID 与现有 `:extends` display path；补全为未解析 occurrence 显示 `[Unresolved]`。
- Modify `supertag-core-scan.el`：Tag 查询复用 node 的 resolved Semantic Tag IDs 与原始 occurrence keys，使未知 token 在不注册 Semantic Tag 的前提下仍可查询。
- Modify `supertag-ui-completion.el`：补全合并 Semantic Tags 与 unresolved occurrence catalog，并保留独立 `[New]` action；选择 occurrence 只插入文本，只有显式选择 `[New]` 才创建 Semantic Tag。
- Modify extractor/ownership/tag-path tests：覆盖源字段、未知 occurrence 的 query/completion、无 node-tag relation 与 Semantic Fact fingerprint 不变。
- Add `issue041`：记录 reindex 静默注册 Semantic Tag 的根因、修复与真实 Vault 确认项。

Behavior：Org 中出现 `#emerging` 不再等于创建 Semantic Tag；reindex 后它保留为 Document Projection diagnostic，可搜索、可补全，但 schema/Tag Store 不变。一次性显式 migration 与用户选择 `[New]` 的创建入口保留。

Risk：当前 unresolved occurrence catalog 仍通过 node projection 做 O(N) 收集；task019–020 建立具体 query/index 后再迁移，当前不新增第二套索引。Semantic Tag 后续新增后，需要受影响文件再次 reindex 才会把 occurrence 解析为 membership。

Verification：两条回归测试先红后绿；ownership 4/4、extractor 22/22、tag-path 40/40，并通过 sync-worker、query、view-stream、smart-key、tag-merge 定向回归；`check-parens`、`git diff --check` 通过；干净临时 clone 全量 ERT 427/427 通过。

## 2026-08-12 — task005 Document Projector identity 与增量 parity

- Modify `supertag-services-sync.el`：ID-less heading 在所有扫描/迁移模式中统一跳过；新增不可被 Customize 删减的 Document Fact hash keys；file/point sync 统一进入 `supertag-sync--reconcile-node`。
- Modify point parser：复制完整未保存 Org buffer 并复用 file parser，保留 outline path、file parent 与绝对位置；indirect Stream edit 从 base buffer 取得源文件。
- Modify reference reconciliation：统计 counters 不再控制 projection 行为；point sync 同样收敛 outgoing references。
- Modify `supertag-ui-commands.el`：显式创建 node 时先写 Org ID，再重新解析完整 heading，避免残缺 node plist。
- Modify `test/sync-worker-regression-test.el`：覆盖无漂移临时 ID、schedule/deadline/ref-to hash、point/file parity、semantic extension 保留与 explicit create。
- Add `issue040`：记录 Document Projector 身份、hash 和入口分叉的根因、修复与真实 Vault 确认项。

Behavior：后台扫描保持只读且不会为普通 heading 发明身份；用户显式创建 node 的入口不变。point sync 现在与 file sync 产生相同 Document Projection，并保留数据库语义扩展。

Risk：point sync 为保持上下文会解析当前完整 buffer，而非孤立 subtree；这是正确性优先的 O(file size) 路径，若真实 Vault 测量显示延迟再考虑 org-element 增量优化。旧 `supertag-sync-auto-create-node` 与 migration `ALLOW-NO-ID` 参数保留但不再生成临时身份。

Verification：新增四条 ERT 先红后绿；`sync-worker` 11/11、`view-stream` 9/9，extractor/tag-path/reference/field-reference/smart-key 定向测试通过；修改文件 byte-compile 成功；`check-parens`、`git diff --check` 通过；干净临时 clone 全量 ERT 426/426 通过。

## 2026-08-12 — task004 Transactional node delete cleanup

- Modify `supertag-ops-node.el`：删除 node 时不再直接扫描/remhash relations；统一调用 `supertag-relation-delete-for-node`，并在删除 node 前清理 legacy `:fields` 与 global `:field-values` per-node bucket；整个操作进入 `supertag-with-transaction`。
- Modify `supertag-core-transform.el`：transaction rollback 对 `:fields` / `:field-values` 的 per-node nested hash table 使用同一个 direct restore 分支，避免 canonical entity normalization 把 hash table 压成 plist。
- Modify `supertag-ops-relation.el`：transaction rollback 后复用 `supertag-index-rebuild-relations` 恢复 from/to derived indexes。
- Modify `test/node-ops-test.el`：覆盖 incoming/outgoing relations、两类 field store、from/to indexes 的成功清理，以及后置 hook 失败后的完整 rollback。
- Add `issue039`：记录旧删除路径的数据残留、根因、修复和真实 Vault 确认项。

Behavior：公开命令和返回值不变；成功删除不再遗留 field bucket、relation 或 index entry。失败删除恢复 node、surviving peer ref cache、relations、fields 与 indexes。

Risk：失败事务会执行一次 O(R) relation index rebuild；成功路径仍使用既有增量 index operations。未改变 Org headline 删除或 reciprocal link 文件行为。

Verification：新增两条 ERT 先红后绿；`./test/run-tests.sh node tx field-ref` 39/39 通过；修改文件 byte-compile 仅有既有 obsolete/docstring/forward declaration warning；`git diff --check` 通过；提交态临时 clone 全量 ERT 422/422 通过。

## 2026-08-12 — task003 Durable root contract 与完整保存验证

- Modify `supertag-core-store.el`：将 `:automations`、`:sync-conflicts` 纳入唯一 Store root contract；补齐 entity-plist collection 声明，并移除代码注释中的 Store 全局单一真相源表述。
- Modify `supertag-core-persistence.el`：保存后不再只比较 node count，而是按 `supertag--store-collections` 对每个 entity ID 的 canonical value 做 O(N) 内容比较；任一 durable collection 丢失、增删或同数量内容变化都会在替换旧数据库前中止。
- Modify root normalization：兼容 `boards`、`automations`、`sync-conflicts` 的非 keyword legacy root 名称。
- Modify persistence/canonical/conflict tests：复用 task002 fixture，覆盖正式 root 声明、所有已填充 durable roots 丢失、同数量内容变化、完整 round-trip、原数据库保留，以及 fresh Store 中空 `:sync-conflicts` contract。

Behavior：数据库文件格式不变；成功保存仍走原 canonical writer。验证失败现在会列出发生变化的 durable collections，并继续保留旧数据库文件。

Risk：启用默认 save verification 时增加一次 O(N) 内容比较；实现逐 entity 比较且不排序 whole collection，避免再构造一份完整 Store snapshot。空 collection 与 canonical 文件中的缺席等价。

Verification：`./test/run-tests.sh persist canon` 51/51、`./test/run-tests.sh ownership` 3/3、`./test/run-tests.sh conflicts` 25/25 通过；修改文件 byte-compile 仅有既有 docstring/obsolete warning，本 task 新函数无 warning；`git diff --check` 通过；提交态临时 clone 全量 ERT 420/420 通过。

## 2026-08-12 — task002 两文件 Vault fixture 与 Semantic Fact fingerprint

- Add `test/ownership-fixture.el`：动态创建两个确定性 Org 文件，并建立覆盖 node、Tag Occurrence、schema、field value、Document Link、Semantic Edge、Board、Automation 与 saved query 的隔离 Store。
- Add `supertag-ownership-test-semantic-snapshot` / `supertag-ownership-test-semantic-fingerprint`：复用 canonical serializer，只捕获 Semantic Facts，明确排除 Document nodes 与 Document Links。
- Add `test/ownership-separation-test.el`：验证 fixture 可重复创建、每个 semantic collection 的修改/丢失都会改变 fingerprint、Document Projection 变化不会误报。
- Modify `test/run-tests.sh`：将 ownership tests 加入稳定测试集，并提供 `ownership` filter。

Behavior：仅增加测试基础设施；runtime、数据库和用户 Org 文件不变。

Verification：`./test/run-tests.sh ownership` 3/3 通过；两个新增 Elisp 文件 byte-compile 无 warning；`git diff --check` 通过；从提交态创建的临时本地 clone 中运行 `./test/run-tests.sh all`，416/416 通过。当前工作树中用户未提交的 Dashboard/TextUI 实验未进入验证提交或本 task。

## 2026-08-12 — task001 Ownership Constitution 与迁移地图

- Add `CONTEXT.md`：固定 Document Fact、Semantic Fact、Projection、Tag Occurrence、Semantic Tag、Document Link、Semantic Edge、Backlink、Reindex 与 Semantic Restore 术语。
- Add `doc/OWNERSHIP-CONSTITUTION_cn.md`：规定一个事实一个 Owner、写入方向、Reindex/Semantic Restore 区别及迁移约束。
- Add phase `spec` / `plan` / `tech-refer` / `ADR` / `task`：记录当前代码地图、目标 Module Interface、28 个原子任务和依赖顺序。
- Modify `README.md`, `README_CN.md`：不再把 `supertag-sync-full-rescan` 描述为 whole-database rebuild。
- Modify `doc/ONTOLOGY-ARCHITECTURE_cn.md`：将 Store 修正为当前物理容器，并加入所有权轴和目标读写流。
- Modify plugin guides：raw Store collection 降为 legacy compatibility Interface，禁止新增 caller。

Behavior：仅文档变化；runtime、数据库和用户 Org 文件均不变。

Risk：文档描述的是分阶段迁移目标；当前 mixed Store 与 legacy raw read 仍存在，后续 task 不得把目标状态误当作已完成状态。

Verification：`git diff --check`；Ownership 文档链接存在；旧的正向 “Store is the single source of truth” 与 “full rescan rebuilds the database” 表述已移除。

## 2026-08-12 — task019 具体 Query Model 读取接口

- Add `supertag-services-query.el`：新增具体查询接口 `supertag-query-node`、`supertag-query-tag-paths`、`supertag-query-node-ids-by-tag`、`supertag-query-resolved-fields`、`supertag-query-field-value`、`supertag-query-relations-from/-to/-among`、`supertag-query-node-tags`、`supertag-query-node-detail`、`supertag-query-board-detail`；删除 "only S-expression engine, use core-scan" 的旧架构注释，改为 read boundary 定位。
- Modify `supertag-services-query.el`：`supertag-query-sexp` 更名 `supertag-query-node-ids` 并保留兼容 wrapper；移除 debug message。
- Modify `supertag-view-api.el`：`:nodes` get-entity、`nodes-by-tag`、`list-tags`、`list-tag-ids`、`node-field-in-tag` 改为消费具体 query 接口，不再 maphash raw `:tags`/`:relations` collection。
- Modify `supertag-services-ui.el`：`supertag-view--resolve-node-tags` 与 `supertag-view-build-node-state` 收缩为 `supertag-query-node-tags`/`supertag-query-node-detail` 的兼容包装。
- Modify `supertag-board.el`：board 数据序列化改走 `supertag-query-board-detail`，字段预览与 global edge 收集不再直接触碰 store/relation collection。
- Add `test/query-model-test.el`：6 项 parity 测试覆盖 node/tag read、resolved fields/values、relations from/to/among、node detail、board detail、node query sexp 兼容。
- Modify `test/run-tests.sh`：接入 `query-model` filter 与稳定测试集。

Behavior：读路径开始收敛到具体接口；`supertag-query-resolved-fields` 与 relations-from/to/among 目前由 node-detail/board-detail 内部组合消费，其外部消费者由 task021（Node/Table/Kanban）与 task022（Board/Graph）迁移时接入；未新增任意 collection/path 读取。

Risk：`supertag-query-sexp` 兼容 wrapper 覆盖 query-library/diagnostics 既有调用；task023 前该兼容入口保留。

Verification：query-model ERT 6/6、ownership 26/26 通过；干净临时 worktree（HEAD + task019 patch + query-model-test.el）全量 ERT 488/488；5 个修改文件 byte-compile 无 error/warning（仅仓库既有 obsolete/docstring 提示）、check-parens 与 `git diff --check` 通过；工作树中用户未提交的 Dashboard/TextUI 实验未进入本 task 提交。

## 2026-08-12 — task020 Completion、Tag picker 与 Stream 迁移

- Add `supertag-services-query.el`：新增具体投影读取 `supertag-query-tag-occurrences`（跨 projected nodes 收集唯一 Org Tag Occurrence token）。
- Modify `supertag-ui-completion.el`：`supertag-completion--get-all-tags` 改为消费 `supertag-query-tag-paths`（删除 raw `:tags` maphash 与 node 扫描 fallback）；`supertag-completion--get-node-tags` 改为 `supertag-query-node-tags`；`supertag-completion--get-all-tag-occurrences` 改为消费 `supertag-query-tag-occurrences`，函数名与 advice/cl-letf 兼容点全部保留。
- Modify `supertag-services-ui.el`：`supertag-ui-read-tag` 候选构建改为一次 `supertag-query-tag-paths` 查表（id→name），不再逐 ID `supertag-tag-get`；显式 TAG-IDS 路径保持原语义（不在 store 的虚拟 ID 仍原样展示）。
- Modify `test/query-model-test.el`：新增 completion helpers 与具体 query 接口的 parity 测试。
- Stream：task019 已通过 `supertag-view-api-nodes-by-tag`/`get-entities` 间接消费具体接口，本 task 无需改动。

Behavior：Completion、Tag picker、Stream 不再直读 raw collection；未解析 occurrence 仍进入 completion 候选（[Unresolved] 标记），显式 tag-ids 的虚拟 ID 兼容语义不变。

Risk：`get-all-tags` 顺序由 ID 排序改为 display-path 排序；completion 候选顺序变化但三处既有测试（inline-tag-filter self-check、completion-newtag self-check、tag-path cl-letf/order 断言）全部通过。

Verification：smart-key + tag-path 55/55、view-stream/table/kanban/node 定向回归、ownership 26/26、query-model 7/7 通过；`test-inline-tag-filter.el` 与 `test-completion-newtag.el` 两个 self-check 通过；干净临时 worktree（HEAD + task020 patch）全量 ERT 489/489；4 个修改文件 byte-compile 零新增 warning、check-parens 与 `git diff --check` 通过。

## 2026-08-13 — task021 Node、Table 与 Kanban 迁移

- Modify `supertag-services-query.el`：`supertag-query-field-value` 增加可选 RAW-P，raw 读取走 `supertag-field-get`（Kanban 分组需要无默认值的存储值）。
- Modify `supertag-view-node.el`：resolved fields、reference/语义关系从 `supertag-query-resolved-fields` 与 `supertag-query-relations-from/-to` 读取；字段值改走 `supertag-query-field-value`；`supertag-tag-get` 的 valid/deleted 判定保持不变（Tag 实体读取不在本 task 范围）。
- Modify `supertag-view-table.el`：field default 显示、refs-to/refs-from 与 cell 值改走具体 query 接口。
- Modify `supertag-view-kanban.el`：分组字段值改走 `supertag-query-field-value` raw 模式（保留 nil → "Uncategorized" 语义）；列定义改走 `supertag-query-resolved-fields`。

Behavior：Node/Table/Kanban 不再直接调用 field/relation ops getter；默认值、公式、引用与过滤/排序路径不变。

Risk：`supertag-query-field-value` 签名从 3 参扩为 3+1 可选参，向后兼容既有调用。

Verification：view-framework 82/82、view-runtime 22/24（2 个失败为工作树中用户未提交的 TextUI Dashboard 实验，已在 task001 备注中隔离）、view-node/table/kanban/node/query-model/ownership 定向 59/59；干净临时 worktree（HEAD + task021 patch）全量 ERT 489/489；4 个修改文件 byte-compile 零新增 warning、`git diff --check` 通过。

## 2026-08-13 — task022 Board 与 Graph 迁移

- Modify `supertag-board.el`：`supertag-board--send-node-list`（palette）改为消费 `supertag-query-nodes` 带 stringp/data filter，不再 maphash raw `:nodes`；board-data DTO 保持 task019 的 `supertag-query-board-detail` 路径。
- Modify `supertag-graph-ui.el`：`supertag-graph-ui--get-nodes` 改走 `supertag-query-nodes`；`supertag-graph-ui--get-links` 改为 `supertag-query-relations-among`（全部节点 ID 诱导子图，语义与原 "both endpoints exist" 过滤等价）；`supertag-graph-ui--get-parent-child-links` 分组改走 `supertag-query-nodes`（file/level/pos 读取不变）；`supertag-graph-ui--jump-to-node` 改走 `supertag-query-node`。
- Board ops（`supertag-board-ops.el`）是 Board semantic collection 的存储层，保持直读 `:boards`，不经过 query 层（避免层间反转）。

Behavior：Graph/Board 序列化输出格式不变；WS DTO 不变。

Risk：`get-links` 从单次 maphash 改为 per-node outgoing 查索引（同为 O(E)），无性能回归。

Verification：query-model/ownership 定向通过、view-runtime 除隔离 TextUI 实验外全过；干净临时 worktree（HEAD + task022 patch）全量 ERT 489/489；2 个修改文件 byte-compile 零新增 warning、check-parens 与 `git diff --check` 通过。

## 2026-08-13 — task023 Query Block 与 Saved Query executor 迁移

- Add `supertag-services-query.el`：新增公开接口 `supertag-query-fields`（查询引用字段提取，供表格列头）、`supertag-query-validate`（用引擎解析器校验并返回 sexp）、`supertag-query-date-valid-p`（日期解析器校验）。
- Modify `supertag-ui-query-block.el`：`--headers-and-rows` 改走 `supertag-query-node-ids` + `supertag-query-fields`；`--sort-value` 与 `--row` 的全局字段值改走 `supertag-query-field-value` raw 模式（nil tag 上下文）。
- Modify `supertag-query-library.el`：render/read/condition-builder/date-reader 全部改走公开接口，不再调用 `supertag-query--parse-sexp/-execute-ast/-get-fields-from-ast/-get-node-field-value/-resolve-date-string`；文件头注释同步更新。
- Modify `test/run-tests.sh`：多个 filter 组合时按文件路径去重，修复 `query query-model` 同时传入导致 ERT "redefined" 的加载错误。

Behavior：查询语义不变；解析次数从 1 次增为最多 2 次（O(size) 可忽略）。

Risk：`supertag-query-field-value` raw 模式与旧 `--get-node-field-value` 等价（resolve-id nil + global store 原始值）。

Verification：query-block/query-library/query-model 28/28 通过；干净临时 worktree（HEAD + task023 patch）全量 ERT 489/489；3 个修改 Elisp byte-compile 零新增 warning、check-parens 与 `git diff --check` 通过。

## 2026-08-13 — task024 Automation 读取路径迁移

- Add `supertag-services-query.el`：新增具体读取 `supertag-query-automations`（automation rule 列表，可带 filter，名字升序）。
- Modify `supertag-automation.el`：`supertag-automation-list` 收缩为 `supertag-query-automations` 消费点（rule index cold rebuild 随之从 query interface 取源）；条件/动作中的 node 读取改走 `supertag-query-node`；`update-field` 动作的当前值读取改走 `supertag-query-field-value` raw；关系同步读取改走 `supertag-query-relations-from`；`--get-field-value` 全局字段读取改走 `supertag-query-field-value`。写入路径保持既有模块归属：Document Tag 动作走 service-org，Semantic field 动作走 field ops。
- Modify `supertag-automation-sync.el`：`--get-affected-node-ids` 改走 `supertag-query-nodes` 带同语义 filter；node 读取改走 `supertag-query-node`；`--get-field-value` 的 node 分支改走 `supertag-query-field-value` raw。

Behavior：触发恰好一次、recursion guard、tag/field/relation condition 语义不变。

Risk：无；所有替换均为 1:1 等价映射。

Verification：`test-automation-scheduled.el` self-check 通过（scheduled rule 触发 + days-of-week filter）；sync-worker/query-model/ownership 定向 47/47；干净临时 worktree（HEAD + task024 patch）全量 ERT 489/489；3 个修改文件 byte-compile 零新增 warning、`git diff --check` 通过（automation 两文件的 check-parens 报错为仓库既有 false positive，与本次修改无关）。

## 2026-08-13 — task025 formula/rollup 语义收敛

- Add `supertag-services-formula.el`：新增 `supertag-rollup-apply`，为 Table/Virtual Column/Automation/Relation 共用的唯一 rollup 归约，词汇表为 count/sum/avg(average)/min/max/first/last/unique-count/concat/function-object，兼容 VC 的 `:keyword` 与 Automation 的 `'symbol` 两种写法。
- Modify `supertag-virtual-column.el`：`--compute-rollup` 与 `--compute-aggregate` 的 pcase 归约替换为 `supertag-rollup-apply`。
- Modify `supertag-automation.el`：`--apply-rollup-function` 收缩为共享归约调用；`--evaluate-formula` 改为委托 `supertag-formula-evaluate`（保留 error→0 容错）；删除 `supertag-automation-calculate-rollup` 中永远不执行的 `supertag-node-update-property` fboundp 写回分支。
- Modify `supertag-ops-relation.el`：`supertag-relation-calculate-rollup` 的 `(funcall rollup-function values)` 改为 `supertag-rollup-apply`（同时修复了传 symbol 名时 funcall 会报错的潜在缺陷）。
- Modify `test/formula-test.el`：新增共享归约 parity 测试（关键词/符号两种词汇、空列表语义）。

Behavior：materialized rollup 结果不存在——全部 rollup 都是派生投影（VC 缓存仅会话内、不持久化）；此前 fboundp 写回分支是死代码，删除后语义不变。

Risk：Automation `average` 空列表结果从 0.0 变为 0（数值相等，无实际影响）；`{{...}}` 公式中数字字段值的 literal 嵌入与旧 string 嵌入在算术语义下等价，字符串字段行为更正确。

Verification：formula/aggregate/vc/view-table 定向 42/42；干净临时 worktree（HEAD + task025 patch）全量 ERT 490/490；4 个修改 Elisp byte-compile 零新增 warning、`git diff --check` 通过。

## 2026-08-13 — task026 封住 raw Store read seam

- Add `supertag-services-query.el`：新增具体读取 `supertag-query-tags`（(id . tag-plist) 对）、`supertag-query-tag-children`（显式直接子 tag）、`supertag-query-field-definitions`/`-ids`、`supertag-query-tag-field-associations`、`supertag-query-relations`（带 filter）。
- Delete `supertag-view-api.el` 的 `supertag-view-api-get-collection`（全库零 caller）；`list-entity-ids` 的通用分支改走具体读取（:nodes/:tags/:relations/:automations），legacy :embeds/:behaviors/:databases 返回空；`get-entity` 的 :tags/:relations 走 ops getter、:automations 走 `supertag-query-automations` id 过滤（避免 require automation 造成 require 环）。
- Modify `supertag-ui-search.el`、`supertag-concept.el`、`supertag-services-ui.el`（node candidates）：maphash raw `:nodes` 改为 `supertag-query-nodes` 同语义 filter。
- Modify `supertag-view-schema.el`：schema 树/own-fields/绑定字段/选父 tag 全部改走具体读取；`supertag-query-tags` 保持 (id . plist) 形状与防御性 :id 补齐。
- Modify `supertag-ui-commands.el`：ghost tag 扫描移入 ops 层 `supertag-tag-find-ghosts`（`supertag-ops-tag.el`），UI 命令只消费结果。
- Modify `supertag-services-capture.el`、`supertag-automation-templates.el`、`supertag-query-library.el`：`(mapcar #'car (supertag-query :tags))` 全部改为 `supertag-view-api-list-tag-ids`；field 名候选改走 `supertag-query-field-definitions`。
- Modify `supertag-automation.el`：recalculate-all-rollups 与 sync-all-fields 改走 `supertag-query-relations` filter；`supertag-automation-get` 保留为 :automations ops 层 CRUD（与 board-ops 同类）。
- Subscriptions：UI/Board/Graph 已订阅 `:store-changed` 等语义 keyword 事件（task019 前的现状审计确认），无需改动；细粒度语义失效的进一步优化不在本 task 范围。

Behavior：查询结果与顺序语义不变（tag id 列表统一为排序输出）。

Risk：`get-entity :automations` 从 O(1) 变为 O(N)（automation 数量极小）；view-api 不再 require automation，消除了 view-api→automation→service-org→view-helper→view-api 的 require 环。

Verification：`rg` 证明 UI/View/Completion/Automation 无 `supertag-store-get-collection/entity`、无 `supertag-view-api-get-collection`、无 generic `supertag-query :...` 调用（剩余调用仅在 services-query 自身、migration、diagnostics 等 infra 层与 `supertag-automation-get` ops CRUD）；干净临时 worktree（HEAD + task026 patch）全量 ERT 490/490；12 个修改文件 byte-compile 零新增 warning、`git diff --check` 通过。

## 2026-08-13 — task027 Queries/Views 迁入 semantic store

- Add `supertag-core-store.el`：`:queries` 与 `:views` 加入 durable root collections（自动获得 task003 的保存/重读验证与 canonical 序列化）。
- Modify `supertag-query-library.el`：`supertag-query-saved` defcustom 降级为一次性导入源；新增 `supertag-query-saved-list`（Store 读取，懒触发导入）与 `supertag-query-saved--maybe-import-legacy`（Store 空 + defcustom 非空时事务性导入，先 `supertag-save-store` 成功再清空 defcustom，失败回滚保留 legacy 值）；`supertag-query-save` 改写入 `:queries`（store-put-entity + save-store）；所有读取路径（map-forms/completing-read/annotate/saved-query-string）改走 Store。
- Modify `supertag-view-framework.el`：新增 `supertag-view-config-save-to-store`（排除不可序列化的 `:render-fn`）与 `supertag-view-config-restore-from-store`；`supertag-view-framework-init` 清空后从 `:views` 恢复。
- Modify `test/query-library-test.el`：saved-query 测试从 custom-file 契约改为 Store 契约，新增 legacy 导入幂等测试；run-saved 渲染测试 cl-letf save-store 避免触盘。

Behavior：重启后 saved queries 与 view configs 从 Store 恢复；Tag rename/Git merge 走 semantic store 既有机制；迁移失败可回滚（defcustom 未清空）。

Risk：`supertag-query-saved-list` 是带幂等副作用的读取（导入守卫严格：Store 空 + defcustom 非空），ownership fixture 直接引用 defcustom 的测试不受影响（不触发导入）。

Verification：query/query-model 定向 29/29、ownership 26/26；干净临时 worktree（HEAD + task027 patch）全量 ERT 491/491；4 个修改文件 byte-compile 零新增 warning、`git diff --check` 通过。

## 2026-08-13 — task028 legacy roots/interfaces 清理与 phase 验收

- Modify `supertag-core-store.el`：从 durable roots 与 canonical collections 移除 `:embeds`（审计确认无任何生产读写：embed 操作全部作用于 buffer/文件）；旧库文件的 `:embeds` 行仍由 loader 兼容读入，下次保存不再写出。
- 审计确认：legacy `:fields` 生产写路径已在 task014 全部删除，现存引用仅在 core-store/core-transform/migration/conflicts 等迁移与冲突恢复 infra（保留以支持老库升级）；raw Store 接口（`supertag-view-api-get-collection`、UI 层 generic query）已在 task026 封死；误导性 rebuild 文案已在 task001 修正，README 现准确区分 reindex-org 与 Semantic Restore。

Behavior：保存的数据库不再包含 `:embeds`；老库加载不受影响。

Risk：极低；`supertag--canonicalize-store-root` 的 legacy 键名归一化保留，仅影响写出。

Verification：embed/ownership/persist/canon 定向 79/79；干净临时 worktree（HEAD + task028 patch）全量 ERT 491/491；修改文件 byte-compile 零新增 warning、`git diff --check` 通过。Phase 关闭待用户确认（Deferred Gate：SQLite 不属本 phase，task028 完成后单独 ADR/phase）。

## 2026-08-13 — task025 续：公式语法统一（中缀为唯一实现）

- Modify `supertag-services-formula.el`：parser/evaluator（tokenize/parse/eval/eval-string）从 virtual-column 迁入本模块，成为公式唯一实现；新增 legacy 翻译层 `supertag-formula--translate-placeholders` / `--prefix-to-infix` / `--canonicalize`（`{{:key}}` 占位符 + 二元前缀算术自动翻译为中缀）；`supertag-formula-evaluate` 统一入口（resolver 可插拔：Table 保留 tag 上下文 field-getter，其余走全局字段模型带 schema 默认值）；删除基于 `eval` 的占位符沙盒与无使用的 `get-property`/`days-until` helper；`supertag-formula-eval` 增加可选 resolver。
- Modify `supertag-virtual-column.el`：parser 区块迁出；`--compute-formula` 改调统一入口 `supertag-formula-evaluate`（变量解析从"字段名直查 0 默认"改为全局字段模型 + schema 默认，修复字段 rename 后 VC 公式查不到值的缺陷）。
- Modify `supertag-ops-relation.el`：load-time `require 'supertag-services-formula` 改为 calculate-rollup 内懒 require，断开 services-formula ↔ services-query ↔ ops-relation 的 require 环；services-formula 现在 load-time 零 supertag 依赖，resolver 在求值时懒 require ops-field。
- Modify `doc/AUTOMATION-SYSTEM-GUIDE.md`/`_cn.md`：公式示例与语言说明改为中缀语法；`doc/ONTOLOGY-ARCHITECTURE_cn.md` 的"两种公式实现并存"表述更新为统一实现。
- Modify `test/formula-test.el`：新增 legacy 翻译、中缀透传、双语法同一结果 parity 测试。

Behavior：三种消费方（Table/VC/Automation）对同一公式文本给出相同结果；存量 `{{}}` 公式无需改动（自动翻译，仅支持二元算术子集，超出子集报错并提示中缀写法）；`/` 为浮点除法（旧 eval 整数除法的截断行为被修正，如 `(* (/ {{:progress}} 100) 100)` 旧结果恒 0，现正确返回 progress）。

Risk：legacy 公式中使用了 `get-property`/`days-until` 或变长参数的会报错（全库无使用记录）；Automation formula 的变量解析从 entity plist 改为全局字段模型（与 Table/VC 收敛，符合 task025 验收）。

Verification：formula/aggregate/vc/view-table/view-node/query/ownership/smart-key 定向 114/114；干净临时 worktree（HEAD + 本 patch）全量 ERT 494/494；5 个修改 Elisp byte-compile 零新增 warning、check-parens 与 `git diff --check` 通过。
