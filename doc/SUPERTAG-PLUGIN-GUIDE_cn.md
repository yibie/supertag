本文描述的 schema/table/kanban/search/capture 旧入口已归档，当前入口见 README。

# SUPERTAG-PLUGIN-GUIDE（中文版）：完整插件开发文档

这份文档是 supertag 插件开发的事实来源（开发者指南）。

核心原则：

- Org 拥有 Document Facts；数据库拥有 Semantic Facts，并暂时物理保存可重建的 Projections；
- 插件的主要扩展点是 *视图（View）*（任意 UI），而不是 schema；
- 插件必须通过 **UI 无关的 View Data API**（`supertag-view-api.el`）读取数据；
- 写入必须通过 **ops** API，并通常使用 `supertag-with-transaction`。

内置 DSL 示例：

- `M-x supertag-view-dsl-example`

## 0）数据模型与约定

### 实体与存储

supertag 当前把 Semantic Facts、Document Projections 与 derived state
集中存放在一个 hash-table Store 中。Store 是物理容器，不是其中每个事实的 Owner。
完整定义见 `doc/OWNERSHIP-CONSTITUTION_cn.md`。

常见 collection：

- `:nodes` — 节点实体（plist）
- `:tags` — 标签实体（plist）
- `:relations` — 关系实体（plist）
- `:field-definitions` / `:tag-field-associations` / `:field-values` — 全局字段模型

### 实体表示

- 实体是 **plist**（property list），通常包含 `:id` 等关键字段；
- ID 是字符串；
- 字段 key 使用 keyword（例如 `:title`、`:file`、`:tags`）。

### 读写契约

- 读 API 返回的 plist，请当作不可变快照使用；
- Document Fact 通过 document command 写入，Semantic Fact 通过对应 ops 函数写入；两者都会触发 View 所需事件。

## 1）读取 API（View Data API）

View Data API 是 **内部公开（internal public）** 且 **UI 无关** 的数据读取契约。
插件不管用什么 UI，都应以它为读取入口。

文件：

- `supertag-view-api.el`

### Query Spec

很多函数使用 `QUERY-SPEC` plist，例如：

- `(:type :tag :value "foo")` → 取拥有 tag "foo" 的节点
- `(:type :nodes)` → 取全部 node ids
- `(:type :tags)` → 取全部 tag ids

### API 清单（只读）

**数据集入口**

- `(supertag-view-api-list-tags) -> (list string)`  
  返回所有 tag name（排序后）。

- `(supertag-view-api-tag-id TAG-NAME) -> string-or-nil`  
  tag name → tag id。

- `(supertag-view-api-list-entity-ids QUERY-SPEC) -> (list string)`  
  获取一个数据集的 ID 列表入口。

**实体读取**

- `(supertag-view-api-get-entity TYPE ID) -> plist-or-nil`  
  读取单个实体。`TYPE` 支持别名：` :node/:nodes`、`:tag/:tags` 等。

- `(supertag-view-api-get-entities TYPE IDS) -> (list plist)`  
  批量读取（性能建议优先用它）。

**底层 collection（兼容旧代码）**

- `(supertag-view-api-get-collection COLLECTION) -> hash-table`  
  这是返回底层 Store collection 的过渡 Interface。新插件不得使用；应调用具体
  query helper。若缺少所需读取能力，只在现有 query Module 中补最小领域查询。
  删除该入口由 ownership-separation `task026` 跟踪。

**字段读取**

- `(supertag-view-api-node-field-in-tag NODE-ID TAG-ID FIELD-NAME) -> value`  
  读取 node 在某个 tag 语境下的 field value。

**订阅**

- `(supertag-view-api-subscribe EVENT FN) -> unsubscribe-fn`  
  订阅变更事件。返回 `unsubscribe-fn`，插件应在 buffer 退出时调用它释放订阅。

## 2）写入 API（Ops 层）

插件不得直接修改 Store。Document Fact 走 document command，Semantic Fact 走 ops 函数。

### 事务（推荐）

多次写入应包在：

```elisp
(supertag-with-transaction
  ;; 多个 ops 写入
  ...)
```

目的：合并通知，减少 UI 抖动。

### 常用写入 API 清单

**Nodes**

- `(supertag-node-create PROPS) -> node-plist`  
- `(supertag-node-update NODE-ID UPDATER) -> node-plist-or-nil`  
- `(supertag-node-delete NODE-ID) -> deleted-node-or-nil`

**Tags**

- `(supertag-tag-create PROPS) -> tag-plist`  
- `(supertag-tag-update TAG-ID UPDATER) -> tag-plist-or-nil`  
- `(supertag-tag-delete TAG-ID) -> deleted-tag-or-nil`  
- `(supertag-tag-add-field TAG-ID FIELD-DEF) -> tag-plist`  
- `(supertag-tag-remove-field TAG-ID FIELD-NAME) -> tag-plist`

**Fields**

- `(supertag-field-set NODE-ID TAG-ID FIELD-NAME VALUE) -> VALUE`  
- `(supertag-field-set-many NODE-ID SPECS) -> plist`

**Relations**

- `(supertag-relation-add-reference FROM-ID TO-ID) -> t-or-nil`（只写 Store，不修改 Org）
- `(supertag-relation-delete RELATION-ID) -> deleted-relation-or-nil`

写入约定：

- ID 是字符串；
- UPDATER：输入旧 plist，返回新 plist（返回 nil 表示中止更新）；
- 多次写入优先用事务包裹。

## 2.5）Schema 注册（高级用法）

supertag 支持用户在初始化阶段注册/覆写 schema。
这主要面向高级场景（自定义实体类型或扩展校验/字段），不包含自动迁移机制。

推荐配置方式：

```elisp
(setq supertag-schema-registration-functions
      (list
       (lambda ()
         ;; 覆写/扩展已有 schema（默认是 merge）。
         (supertag-schema-register :node '(:my-field (:type :string :default "")))

         ;; 或注册一个全新的实体类型 + schema。
         (supertag-register-entity-type
          :my-entity
          '(:id (:type :string :required t)
            :name (:type :string :default "")))))))
```

## 3）事务系统（它实际意味着什么）

文件：

- `supertag-core-transform.el`

API：

- `(supertag-with-transaction ...)`

语义：

- 在事务 body 执行期间会**抑制通知**，结束后一次性发出 **batch 通知**；
- 会设置 `supertag--transaction-active` 并记录 transaction log；
- 目前重点在“合并通知/降低 UI 抖动”，不要在没有代码明确实现前假设完整 rollback 语义。

## 4）内置 DSL 示例

文件：

- `supertag-view-framework.el`

它演示：

- 使用声明式 Widget 配置定义 View；
- 使用嵌套 Widget 和函数形式的绑定；
- 通过公共 View Framework 注册 View。

## 5）手动验证 checklist

1. 执行 `M-x supertag-view-dsl-example`。
2. 执行 `M-x supertag-view-select-and-render`，输入 `demo` 标签并选择
   `DSL Example`。

3. 验证：

- 正常显示 Overview 区域；
- stats row 能反映 View context；
- progress bar 和 list 通过正常 Runtime 路径渲染。
