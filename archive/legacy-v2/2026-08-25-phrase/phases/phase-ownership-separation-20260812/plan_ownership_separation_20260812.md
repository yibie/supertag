# plan_ownership_separation_20260812

## Milestones

1. **M0 — Ownership & Safety**：固定所有权、建立 semantic fingerprint、补持久化与删除安全。
2. **M1 — One-way Document Projection**：让 scanner/reindex 成为无 Org 写入的单向投影。
3. **M2 — Semantic Separation**：拆 node mixed plist、global fields、relation kinds 与 stable Tag identity。
4. **M3 — Query Model**：建立可冷重建的具体查询接口并逐 consumer 迁移。
5. **M4 — Durable Config & Cleanup**：迁入 queries/views，删除 legacy roots 和 raw Store 出口。

## Scope

### M0 — task001–task005

- Ownership Constitution、领域术语、当前/目标代码地图。
- 测试 Vault 与 Semantic Fact fingerprint。
- durable roots / save verification。
- node delete 完整性。
- scanner identity、hash 与 point/full parity。

### M1 — task006–task011 + sync-integrity/task013

- Tag Occurrence 与 Semantic Tag 分离。
- Document Link 纯投影。
- 准确的 reindex 命令和语义。
- reciprocal backlink 兼容审计、forward-only 新写入和用户确认迁移。
- Tag membership 的 Org-first 写入。

### M2 — task012–task017

- Node projection 与 semantic annotations 分离。
- global field migration 与 legacy cutover。
- document-link / field-reference / semantic-edge 分型。
- Stable Semantic Tag ID、alias resolver 与 rename 语义。
- task017 已落实稳定 ID cutover、统一 resolver 与显式 Org token migration；M2 完成。

### M3 — task018–task026

- 统一 cold rebuild contract。
- 具体 Query Model interface。
- Completion/Stream、Node/Table/Kanban、Board/Graph、Query、Automation 分批迁移。
- formula/rollup 语义收敛。
- raw Store read closure。
- task018 已完成统一 clear/rebuild generation、load/rollback/reindex lifecycle 与 indexed Tag membership；下一步 task019 固定具体 Query Model interface。

### M4 — task027–task028

- Saved queries / persisted views 迁入正式 semantic collections。
- 删除 legacy `:fields`、无效 `:embeds`、旧 raw interfaces 与误导文案。

## Critical Path

```text
task001 → task002 → task003 → task005
        → task006 → task007 → task008
        → sync-integrity/task013 → task009 → task010
        → task012 → task014 → task015 → task016 → task017
        → task018 → task019
        → task020…task025 → task026
        → task027 → task028
```

## Priorities

- **P0**：Reindex 不修改源文档或 Semantic Facts；删除操作不遗留不可见数据。
- **P1**：消除 Tag membership、Reference、Node plist 的双主权。
- **P2**：封住 raw Store reads，集中 query joins 和 derived indexes。
- **P3**：迁移 persisted query/view config，清理 legacy storage。

## Risks & Dependencies

- 旧 reciprocal backlink 与用户正向链接语法相同，禁止自动删除；依赖既有 `phase-sync-integrity-20251226/task013`。
- Stable Tag ID 会影响 schema、relations、fields、automations、boards、saved queries 与 completion；必须先 dry-run 和备份。
- task016 已固定 dry-run gate：只有 deterministic old↔stable、unique alias、完整引用面与 backup fingerprint 均无冲突，task017 才允许进入写入路径。
- task018 已把 runtime resolver、Tag paths/descendants 与 membership 纳入统一 cold rebuild contract；descendant cold build 暂为 O(T²)，只有实测启动瓶颈时才升级 adjacency walk。
- Legacy/global field 两套读取语义并存；必须用 parity fixture 证明 cutover。
- 现有 View Data API 暴露 raw collections；必须逐 consumer 迁移，不能一次删除。
- Store transaction 只回滚内存 Store；本阶段优先减少跨介质双写，不先造 crash journal。

## Rollback

- 每个 task 单独提交，不跨任务混合数据迁移与 consumer 迁移。
- 所有数据迁移必须先 dry-run、生成 mapping/report，并创建可恢复备份。
- 旧 public command wrapper 保留到对应 milestone 验收；行为可按 consumer 单独退回。
- 旧 reciprocal links 默认保留，迁移只处理用户明确确认的条目。
- SQLite 不进入本阶段，因此无需 backend rollback。

## SQLite Gate

完成 task028 后才允许独立 ADR 评估 SQLite。只有出现经过测量的性能或约束需求，并且现有 query interface 已证明可承载第二个实现时，才创建 backend adapter。

## Maintenance extension — task029

- 修复 create-and-reference 在源 heading 首次生成 ID 时选区漂移、relation 未投影却报告成功的问题。
- 建立单一 heading identity / Store-first location boundary；Org ID cache 只保留为未投影节点的显式兼容 fallback。
- 将 creation、capture、completion、concept、navigation、Graph、Board 与 Automation 迁入边界，并用静态 guard 禁止 runtime business module 绕过。
- 验证方式：空 `org-id-locations` 的跨工作流 ERT、缺失文件/ID fail-closed、完整 ERT、临时 byte compile 与 `git diff --check`。
