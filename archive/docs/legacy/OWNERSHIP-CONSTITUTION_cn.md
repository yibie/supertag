本文描述的 schema/table/kanban/search/capture 旧入口已归档，当前入口见 README。

# Supertag 数据主权宪章

- Status: Historical / superseded as default architecture authority
- Date: 2026-08-12
- Scope: 数据所有权、写入方向、重建与恢复语义

## 说明

本宪章已退出默认架构裁决。后续模型讨论已作为本地开发记录保留；当前使用入口见[README](../../../README_CN.md)。
下文稳定Semantic Tag、schema、独立DB语义写者、固定Query/raw Store限制及命令名称
只描述旧模型，不约束新落点或恢复旧默认产品。一个事实一个owner、文档与
非重建数据保护继续有效；退出旧模型不允许删历史facts、备份或未解冲突。
旧迁移命令和.phase路径是历史来源，不是当前操作建议，不应照此运行真实库。

## 历史正文（原章节编号保留）

当时的模型是：

> Org 文档主权 + 数据库语义主权 + 可丢弃查询投影。

本文定义目标不变量。当前 Store 仍混装三类数据；迁移进度以
`.phrase/phases/phase-ownership-separation-20260812/` 为准。

## 1. 一个事实只有一个 Owner

权威事实由两个互不重叠的集合组成：

```text
A = O ⊎ S
P = π(O, S)
```

- `O`：Org 拥有的 Document Facts。
- `S`：数据库拥有的 Semantic Facts。
- `P`：由前两者计算出的 Projection；可以删除和重建，不拥有事实。

Store 是当前的物理容器，不是整个系统的单一真相源。一个值即使保存在 Store 中，
也可能只是 Org 内容的 Projection。

## 2. 所有权表

| 事实 | Owner | 数据库中的角色 |
|---|---|---|
| Node ID、标题、正文、heading/file 拓扑 | Org | Document Projection |
| TODO、priority、schedule、deadline、Org properties | Org | Document Projection |
| 正文中的 Tag Occurrence | Org | token 与 membership Projection |
| 真实存在于正文中的 Org link | Org | Document-link Projection |
| Semantic Tag 的稳定 ID、名称、alias | Semantic Store | Semantic Fact |
| Tag schema、inheritance、field definition/association/value | Semantic Store | Semantic Fact |
| Semantic Edge | Semantic Store | Semantic Fact |
| Board、Automation、持久 Query/View 定义 | Semantic Store | Semantic Fact |
| Backlink、Tag descendants/display paths、resolved schema | 无 | Derived Projection |
| relation/schema/rule index、query result、runtime state | 无 | Derived Projection |
| 未解决的同步冲突 | Operational durable store | 处理完成前不可丢弃 |

## 3. 写入规则

1. Document command 先修改并保存 Org，再重新投影受影响的文档。
2. Semantic command 只修改 Semantic Facts，并使相关 Projection 失效。
3. Reindex 只读 Org、写 Projection，不修改 Org 或 Semantic Facts。
4. Query 与 View 只读 Semantic Facts 和 Projection，不直接取得 raw Store collection。
5. Backlink 是对 Document Links 与 Semantic Edges 的查询结果，不向目标文档插入第二条物理 link。
6. Tag Occurrence 是文本 token；Semantic Tag 是稳定实体。重命名语义实体不要求原子重写全部 Org 文件。

## 4. Reindex 不是数据库恢复

公开命令 `M-x supertag-sync-full-rescan`（实现函数 `supertag-reindex-org`）会从一个完整 Org 快照重建现有 Store 内
Org 派生的 node、Tag Occurrence、Document Link 及其派生索引；快照不完整时
中止且不修改 Store。它不是 whole-store reset，也不能恢复 schema、field value、
Board、Automation 等不可重建的 Semantic Facts。内部代码直接调用 `supertag-reindex-org`；面向用户的文档只写公开命令。

目标 `Reindex` 契约只允许重建 Document Projection 和 derived indexes。
`Semantic Restore` 则从备份或同步副本恢复不可重建的 Semantic Facts。两者不得混称。

## 5. Derived Projection 生命周期

- Store-derived runtime index 只允许通过统一 clear/cold-rebuild contract 建立一个完整 generation。
- Store load、Document reindex 与 transaction rollback 返回前必须重建该 generation。
- 任一 rebuild 步骤失败时，全部相关 index/cache 保持清空并报告错误，禁止继续读取混合 generation。
- 清空或重建 derived state 不得修改 Org、Document Projection 或 Semantic Facts。
- UI-local、presentation 与非 Store-derived runtime cache 使用自己的生命周期，不因物理上都在内存而混入该 contract。

## 6. 迁移约束

- 物理存储暂时沿用现有 Elisp Store；本阶段不引入 SQLite 或假想 backend adapter。
- 数据迁移必须先 dry-run，输出映射、冲突和逆向恢复信息，再经确认执行。
- Stable Semantic Tag 切换前运行 `M-x supertag-migration-audit-stable-tags`；它只输出 old↔stable、alias、继承、schema、引用与备份计划，任何冲突或 unresolved occurrence 都阻断后续 apply，且命令本身不写数据。
- 审计通过后，以 prefix argument 运行 `M-x supertag-migration-run-stable-tags` 才会先备份 live Store、磁盘数据库与 query/view config，再事务性切换 Stable Tag；失败恢复 Store 与 runtime config，并保留备份。
- Semantic Tag rename 只修改 canonical name/alias，不改稳定 ID、引用集合或 Org 文件。需要统一文本 token 时，先运行 `M-x supertag-migration-rewrite-tag-token` 审计，再以 prefix argument 显式执行；它独立 snapshot 文件、改写精确 occurrence 并 reindex。
- 无法区分来源的旧 reciprocal links 默认保留，不自动删除。
- Consumer 逐个迁移到具体查询 Interface；迁移完成前兼容 wrapper 可以保留，但禁止新增 raw Store caller。
- 任何完整或部分扫描在输入快照不完整时都不得执行 orphan cleanup。

## 7. 相关文档

- 领域术语：`MODEL_CN.md` 第 2 节
- 决策记录：`.phrase/phases/phase-ownership-separation-20260812/adr_ownership_constitution_20260812.md`
- 当前/目标代码地图：`.phrase/phases/phase-ownership-separation-20260812/tech-refer_ownership_separation_20260812.md`
- 任务顺序：`.phrase/phases/phase-ownership-separation-20260812/task_ownership_separation_20260812.md`
