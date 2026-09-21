# spec_ownership_separation_20260812

## Summary

将 org-supertag 从“Org 投影、数据库语义事实与派生索引混装在同一个 Store”重构为：

> Org 文档主权 + 数据库语义主权 + 可丢弃查询投影。

本阶段先固定事实所有权和写入方向，再拆分 mixed ownership 数据，最后让 View、Query、Completion、Board 与 Automation 只消费具体查询接口。物理存储暂时继续使用现有 Elisp Store；SQLite 不在本阶段范围内。

## Goals & Non-goals

### Goals

- 每一个事实只有一个 authoritative owner。
- Document Fact 只能由 Org 文档拥有；数据库中的副本是 Projection。
- Semantic Fact 只能由 semantic write path 修改，不再伪装成 Org 文本。
- Reindex 只读取 Org、写入 Projection，不修改 Org 或 Semantic Facts。
- Backlink、Tag membership、document-link index、schema resolution 等结果可以删除后重建。
- Consumers 不再取得 raw Store collection，而是调用具体查询接口。
- 迁移过程保持现有 public commands、数据备份与逐任务回滚能力。

### Non-goals

- 不在本阶段引入 SQLite 或第二个 backend。
- 不把标题、正文、文档拓扑迁入数据库主权。
- 不自动删除无法区分来源的旧 reciprocal links。
- 不在 ownership seam 稳定前重写所有 View 或一次性替换 Store。
- 不承诺跨进程崩溃时的 Org + DB 分布式事务；先消除同一事实的双写。

## User Flows

### Reindex

1. 用户运行 Org reindex。
2. 系统读取 Org 文档并重建 Document Projection 与 derived indexes。
3. UI 显示处理摘要。
4. Schema、field values、boards、automations、saved queries 等 Semantic Facts 保持不变。
5. 任何目录不可用或快照不完整时，禁止 orphan、删除和 GC。

### Document edit

1. 用户通过 Org buffer、Stream edit 或 command 修改 Document Fact。
2. 系统先修改并保存 Org。
3. 保存成功后只重新投影受影响的文件或节点。
4. Org 写入失败时，Projection 不提前变化。
5. Tag add/remove/change、`#tag` completion、Capture prompt 与 Automation Tag action 均遵循同一顺序；`node.:tags` 与 `:node-tag` relation 只能由保存后的 Org occurrence 重新派生。
6. 显式创建 Semantic Tag 是独立的 semantic write；后续 Org 保存失败时可以保留该 Tag definition，但不得产生 membership。

### Semantic edit

1. 用户修改 schema、field value、Semantic Tag、Semantic Edge、Board 或 Automation。
2. 系统只提交 Semantic Fact。
3. 相关 Query Projection 失效并重建。
4. 系统不向 Org 插入伪装成事实的 reciprocal text。
5. 字段显示名修改保留稳定 field ID 与已有 node values；消费者通过 resolver 继续命中同一字段。
6. Semantic Tag rename 只修改 canonical name/alias，稳定 Tag ID、引用集合与 Org token 均保持不变；旧 token 继续通过 alias 解析。
7. Semantic commit 后，受影响的 Store-derived index 通过 collection revision 失效；下一次读取或统一 cold rebuild 只能看到一个完整 generation。

### Explicit Tag token migration

1. 用户先以 `M-x supertag-migration-rewrite-tag-token` 运行只读审计，确认旧、新 token 唯一解析到同一 Semantic Tag。
2. 系统要求 complete Vault snapshot，并拒绝含未保存 buffer、不可读文件或 owner 不一致的迁移。
3. 用户以 prefix argument 明确执行后，系统先 snapshot 全部受影响文件，再只改写精确 inline occurrence 与 `#+FILETAGS` token。
4. 改写成功后完整 reindex Document Projection；文件写入或 reindex 失败时恢复 snapshot 并重新投影。
5. 该操作不改变 Stable Semantic Tag identity 或其他 Semantic Facts。

### Reference navigation

1. Source document 保留一个真实 forward Document Link。
2. Target 侧通过查询看到 Backlink。
3. 旧 reciprocal link 只有在 preview 后经用户确认才迁移；默认保留。

### Legacy reciprocal migration

1. 用户先打开 read-only preview，查看参与互相指向的每一条物理 link occurrence。
2. 系统不推断哪条是旧自动 backlink，也不默认选择任何条目。
3. 用户逐条选择并二次确认后，系统只删除选中的精确 occurrence。
4. abort、空选择、过期 preview 或不完整 Vault snapshot 均零写入。
5. 每个受影响文件先创建相邻 snapshot；任一写入或重新投影失败时恢复全部文件与 Store。

## Edge Cases

- 未解析的 Tag Occurrence 可以存在，但不得静默绑定到错误的 Semantic Tag。
- 未解析 occurrence 必须继续可查询并出现在补全中；它与显式创建 Semantic Tag 的 `[New]` action 是两个不同选择。
- Semantic Tag alias 必须全局唯一；冲突时 fail closed。
- Stable Tag apply 前必须通过只读 audit：old↔stable、alias、inheritance、schema 与所有 durable/runtime reference mapping 完整；任何 unresolved occurrence 或 missing owner 都阻断写入。
- Stable Tag apply 必须先创建 live Store、磁盘数据库与 query/view config 备份，并在同一 Store transaction 内改写所有已审计引用；derived rebuild 失败必须恢复 Store 与 runtime config。
- Semantic Tag rename 与 Org token migration 必须是两个独立操作；rename 不得隐式打开或批量保存 Org 文件。
- ID-less heading 不得产生下次扫描会漂移的临时身份。
- ID-less heading 在用户显式创建持久 Org ID 前保持普通 heading，并被 Document Projector 跳过。
- Document Link、field-reference 与 Semantic Edge 必须可区分来源。
- Node 删除必须处理 global field values、relations 与 derived indexes。
- Legacy field apply 必须先生成 live-Store backup；冲突、孤立项或写入失败不得留下部分 global 数据。
- Reindex 不得把缺失文档解释为“允许删除”，除非 sync snapshot 明确为 complete。
- `SUPERTAG_ALIASES` 当前是 Org concept property；不能直接充当未来的 Semantic Tag alias registry。
- Saved query 与 exported view config 在迁入 semantic store 前，必须明确其外部持久化 owner。
- Derived index rebuild 任一步失败时，relation、Tag、membership、schema 与 rule cache 必须全部为空，不得暴露一半新、一半旧的 generation。
- UI TTL/SVG cache、schema definition registry 与 virtual-column runtime cache 不属于 Store-derived cold rebuild；不得为了“统一”而混入错误生命周期。

## Acceptance Criteria

- Ownership Constitution 明确 Document Fact、Semantic Fact、Projection 和 operational state。
- Reindex 前后 Semantic Fact fingerprint 完全一致。
- Reindex 不修改任何 Org buffer 或文件。
- Document Projection 与 Query Projection 均可清空并冷重建。
- 一个统一入口可清空并重建 relation from/to、Tag token/display path/descendants、nodes-by-tag、global field lookup/order、resolved schema 与 Automation rule index；前后公开查询结果一致且不修改 Semantic Fact fingerprint。
- Store 成功/空/失败加载和 transaction rollback 返回后自动建立同一 derived generation；rebuild 失败时全部 cache fail closed。
- 一个新 reference 只有一个物理 forward Document Link；Backlink 由查询产生。
- Tag membership 命令必须先保存 Org，再单点 reindex；保存失败时 occurrence/membership Projection 不变，成功时 node change 事件只触发一次。
- 旧 reciprocal migration 只处理用户明确确认的 occurrence；dry-run/abort 零写入，失败可恢复。
- Node projection 不再依赖 unknown-key merge 保存 Semantic Facts。
- Semantic Tag 使用稳定 ID；rename 不要求重写所有引用集合和 Org 文件。
- Stable Tag dry-run 对同一逻辑 Store 产生相同报告，并保持 Store、Org、数据库文件、saved queries 与 loaded views 字节/值不变。
- Stable Tag apply 后 node membership、schema、relation、Tag field、Board、Automation、saved query 与 loaded view 均引用稳定 ID；旧 token 通过 alias 继续解析。
- 显式 Org token migration 只改写同一 Semantic Tag 的 alias，失败可恢复，前后 Semantic Fact fingerprint 完全一致。
- UI、View、Completion、Board、Query 与 Automation 不再读取 raw collection hash table。
- Legacy `:fields` 不再有生产 reader/writer；只保留 migration/低层兼容 seam，并在 task028 完成可验证迁移后删除。
- 字段定义、Tag 关联和值只写入 `:field-definitions`、`:tag-field-associations`、`:field-values`；旧开关不能改变该路径。
- `:boards`、`:automations`、queries、views 与 unresolved conflicts 受到 durable contract 保护。
- 完整 ERT、byte compile、migration fixtures 和 `git diff --check` 通过。
