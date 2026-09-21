# tech-refer_view_api_20251217

## Background

当前 org-supertag 的长期目标是「DB 为唯一真相」。因此，“插件体系”的最佳落点是 **View 插件**（读侧能力扩展）：插件可以做任意 UI（table/卡片/仪表盘/graph），但**数据获取必须统一走一套内部公开 API**。`supertag-view-table.el` 是该 API 的现有消费者之一，并不是唯一 UI 形态。

## Problem Statement

- view-table 目前“数据获取/查询/行字段计算”的逻辑分散且以 `--` 内部函数为主，难以复用为稳定契约。
- 需要一套**UI 无关的内部公开 API**，让：
  - 内建视图有明确的调用边界；
  - 第三方 View 插件可构建完全自定义 UI；
  - 仍保持 DB 为唯一真相、事件/订阅机制一致。

## Options

### Option A: 在 `supertag-view-table.el` 内部直接“提升”一组 API

- 做法：保留现有实现，新增一组 `supertag-view-api-*`（或 `supertag-view-table-api-*`）函数作为稳定入口，内部再调用现有 `--` 函数。
- 优点：变更小；迁移渐进；短期成本低。
- 缺点：API 边界容易与 UI 细节纠缠，不利于“插件 UI 完全不依赖 table”的目标。

### Option B: 抽出独立模块 `supertag-view-api.el`（推荐）

- 做法：把“query objects / data provider / row building / subscriptions”等抽成独立模块，view-table 只负责 table UI 与交互；其他 UI（卡片/仪表盘/graph）也直接依赖该模块。
- 优点：层次更清晰；未来更易做版本化与兼容。
- 缺点：一次性重构成本更高；短期会触达更多调用点。

## Proposed Approach (本阶段建议)

采用 **Option B**：将数据层能力抽离为 `supertag-view-api.el`，并在 `supertag-view-table.el` 中保留向后兼容的 wrapper（最小化迁移风险）。

## Internal Public Data API (Draft)

本节定义本阶段要“固化”的 **UI 无关数据 API**：它是 org-supertag 内部公开（internal public）的契约面，供内建视图与第三方插件视图复用。  
目标不是一次性完美，而是先把目前散落在 `supertag-view-table.el` 的 data access 逻辑收敛为明确的入口。

### Core Concepts

- **Query Spec**：一个 plist，描述数据集合来源。形如：
  - `(:type :tag :value "foo")`
  - `(:type :behavior)`
  - `(:type :automation)`
  - `(:type :database)`
- **Entity**：由 `:type` 决定的实体（nodes/tags/databases/behaviors/automations...），返回值为 plist。
- **Field Value**：对 `:tag`（node in tag context）而言，列值可能来自：
  1) node 本身字段（如 `:title`/`:file`/`:tags`/`:olp`）
  2) field 系统（`supertag-field-get-with-default`/`supertag-field-set`）

### API Surface (v0)

> 命名建议：统一前缀 `supertag-view-api-`。本阶段先定义契约与职责边界；实现可在 task003 完成。

#### 1) Query & Entity Fetch

- `(supertag-view-api-list-entity-ids QUERY-SPEC) -> (list string)`  
  返回 QUERY-SPEC 对应的实体 ID 列表。用于 table/自定义 UI 的“数据集入口”。

- `(supertag-view-api-get-collection COLLECTION) -> hash-table`  
  返回底层 store 的 COLLECTION（只读使用）。用于需要遍历/聚合的 UI（例如 schema 浏览、关系反查）。

- `(supertag-view-api-get-entity TYPE ENTITY-ID) -> plist-or-nil`  
  按类型取单个实体数据（从 DB/Store 读取；不做写入）。
  - 兼容别名：允许 `:node/:tag/:automation/:behavior/:database` 等在内部映射到 `:nodes/:tags/:automations/:behaviors/:databases`。

- `(supertag-view-api-get-entities TYPE IDS) -> (list plist)`  
  批量读取（性能关键）：避免 UI 对每行每列重复读 DB。

#### 2) Tag/Node Helpers (常用的便捷入口)

- `(supertag-view-api-list-tags) -> (list string)`  
  返回 tag name 列表（用于 selector/补全）。

- `(supertag-view-api-tag-id TAG-NAME) -> string-or-nil`  
  name -> id 映射。

- `(supertag-view-api-nodes-by-tag TAG-NAME) -> (list string)`  
  等价于目前 view-table 内的 `:tag` query（对插件更直观）。

#### 3) Cell/Field Access (用于“列值计算”，但 UI 无关)

- `(supertag-view-api-node-base-field NODE KEY) -> value`  
  读取 node 的基础字段（例如 `:title`、`:file`、`:tags`、`:olp`）。

- `(supertag-view-api-node-field-in-tag NODE-ID TAG-ID FIELD-NAME) -> value`  
  读取某 node 在 tag 语境下的 field 值（当前主要来源：`supertag-field-get-with-default`）。

> 说明：对 plugin UI 而言，“列/卡片/图表”都可能需要读取 field；该 API 不做格式化（格式化是 UI 职责）。

#### 4) Change Subscription (可选，但建议纳入同一层)

- `(supertag-view-api-subscribe EVENT FN &optional TOKEN) -> token`  
  订阅数据变化（例如 node-updated/database-updated）。  
  现状实现可直接委托给 `supertag-subscribe`，但 API 层提供统一入口以便未来支持 unsubscribe 与 token 管理。

- `(supertag-view-api-unsubscribe TOKEN) -> nil`（若现有 notify 层支持）  
  释放订阅，避免 view 插件造成泄漏。

### Non-goals (Data API v0)

- **不负责写入**：写入仍通过 ops（如 `supertag-field-set`、`supertag-node-update`、`supertag-database-update`）并在事务中提交。
- **不负责 UI 格式化**：比如 org link 渲染、日期格式、列宽布局等属于 UI 层。

### Migration Strategy

1. 在 `supertag-view-api.el` 以最小封装实现上述 API，内部调用现有 `supertag-node-get` / `supertag-store-get-entity` / `supertag-index-get-nodes-by-tag` / `supertag-field-get-with-default` 等。
2. 修改 `supertag-view-table.el`：将 `supertag-view-table--get-entities`、`supertag-view-table--get-entity-data`、`supertag-view-table--get-available-tags`、以及 tag field 读取逻辑迁移为调用 `supertag-view-api-*`（行为不变）。
3. 为第三方 UI 提供一个最小示例：完全不使用 table，只用 Data API 拉一组 nodes 并以自定义 buffer 渲染。

### API 边界（建议）

将“视图系统”的职责拆成三层概念：

1) **Data API（内部公开）**：提供“query -> ids/rows/fields + subscriptions”的稳定函数集合（UI 无关）。  
2) **View Definition（插件侧）**：描述一个视图如何取数/过滤/排序/动作（可选）。  
3) **UI（任意实现）**：table 是一种 UI；插件也可以是卡片/仪表盘/graph/side panel。

### View 插件最小契约（建议）

插件可以选择仅使用 Data API 自建 UI；也可以提供 view definition（用于统一 selector/配置），例如：

- `:name` / `:title`
- `:query`（返回 entity-ids 或 rows；必须可在 DB 为真相的前提下实现）
- `:columns`（列定义：key、name、getter、formatter、width、sort-key）
- `:actions`（例如 RET 跳转、o 打开、f 过滤等）

并通过一个注册函数加入 registry。

## UI 组件化：是否需要？

结论（建议）：本阶段不做“通用 UI 组件库”，而做**UI 无关的数据层 + 可选最小约定**：

- 核心只保证 Data API（query/订阅/字段读取）稳定；
- table UI 作为参考实现继续演进，但不是插件必须依赖的 UI；
- 若需要复用交互，可逐步将“过滤/排序/动作”抽成可复用的辅助函数，而非绑定某个 UI。

## Risks & Mitigations

- 风险：API 过早稳定导致后续演进困难。  
  - 缓解：明确“内部公开”（非外部承诺）与版本策略；必要时提供兼容层。
- 风险：性能（大数据量/频繁刷新）。  
  - 缓解：数据 API 支持 limit/paging；尽量避免每格重复访问 DB（批量读取）。
