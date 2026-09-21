# ADR：一个事实只有一个 Owner

- Status: Accepted
- Date: 2026-08-12
- Related: `spec_ownership_separation_20260812.md`, `task001`

## Context

当前 `supertag--store` 同时保存 Org 解析结果、Schema/Field 等不可重建语义事实、Relation/Schema indexes 与 UI 配置。Node 的主权依赖 `standard-keys` 白名单；Tag membership 同时存在于 Org token、`node.:tags` 与 `:node-tag` relation；Reference 同时存在于 source link、reciprocal link、relation 和 node ref caches。继续完善双向同步只能增加补偿、回滚与迁移复杂度。

## Decision

org-supertag 的 authoritative facts 定义为不相交的两部分：

```text
A = O ⊎ S
```

- `O`：Org 拥有的 Document Facts。
- `S`：数据库拥有的 Semantic Facts。
- `P = π(O, S)`：可删除并重建的 Projection，不拥有事实。

强制不变量：

1. 一个事实只有一个 authoritative writer。
2. Document commands 先写 Org，保存成功后再投影。
3. Semantic commands 只写 Semantic Store。
4. Reindex 只读 Org、写 Projection，不修改 Org 或 Semantic Facts。
5. Backlink 是查询，不是第二条物理 link。
6. Query/View 只读 Projection 与 Semantic Facts，不取得 raw collection。
7. 物理上暂时保留当前 Elisp Store；先完成逻辑分离，不引入 SQLite 或 hypothetical backend seam。

## Ownership

### Org-owned

- Node ID、标题、正文和 heading/file 拓扑
- TODO、priority、schedule、deadline、Org properties
- Tag Occurrence
- 真实存在于正文中的 Document Link
- Org query block source text

### Semantic-owned

- Stable Semantic Tag、canonical name、unique aliases
- Schema、inheritance、field definitions、associations、field values
- Semantic Edge
- Automation、Board、persisted Query 与 View definitions

### Derived

- Document node/location projection
- Tag membership resolution、Tag descendants/display paths
- Document-link 与 field-reference indexes、Backlink
- Relation/schema/rule indexes
- Query results、rollup/formula results（除非显式定义 materialization owner）
- View Runtime state、completion candidates、sync scan state

## Rejected Alternatives

### Store 继续作为所有事实的单一真相源

拒绝：它与 Org 可直接编辑的产品承诺冲突，并把每个文件修改变成双向同步问题。

### 数据库接管标题和正文

拒绝：这会把产品改造成 database-native notes，走回 EKG 的产品边界。

### 保持双主权并增强事务/补偿

拒绝：补偿只能缓解失败，不能消除同一事实有多个作者导致的歧义。

### 立即迁移 SQLite

拒绝：当前问题是 ownership，不是 backend；直接迁移只会把混合 plist 搬进 SQL tables。

## Consequences

- `supertag--store` 不再被称为系统整体的 single source of truth；它是当前物理容器。
- Reindex 与 Semantic Restore 成为两个不同操作。
- Tag token 与 Semantic Tag identity 分离；rename 不再要求全库和全部 Org 文件原子重写。
- Document Link、field-reference 与 Semantic Edge 分离；Backlink 由查询派生。
- Consumer migration 完成前允许兼容 wrapper，但禁止新增 raw Store caller。
- 跨介质事务需求会显著减少；剩余真正跨介质操作再单独评估 journal。

## Rollback

本 ADR 可被后续 ADR supersede，但不得在没有数据迁移与用户主权说明的情况下恢复双主权。实现阶段按 task 独立提交；数据迁移均需 dry-run、备份和逆向 mapping。
