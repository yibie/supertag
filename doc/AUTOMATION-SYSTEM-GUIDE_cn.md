本文描述的 schema/table/kanban/search/capture 旧入口已归档，当前入口见 README。

# Automation System 2.0 - 用户指南和示例

## 🚀 概述

`supertag` Automation System 2.0 是一个现代化的、事件驱动的自动化框架。它将强大的自动化能力赋予每一个标签，让您能够构建真正智能、无需手动干预的 org-mode 工作流。

### 核心特性

- ✅ **统一的标签系统**：每一个标签都是一个功能完备的“数据库”，拥有自定义字段和自动化能力。
- ✅ **真正的事件驱动**：基于精确的数据变化实时响应，而非轮询扫描。
- ✅ **自动规则索引**：在后台自动为规则建立高性能索引，无需用户关心性能优化细节。
- ✅ **多重动作执行**：一条规则可以触发一系列按顺序执行的动作。
- ✅ **计划任务**：支持基于时间和周期的自动化，由集成的调度器驱动。
- ✅ **关系与计算**：支持双向关系与 query 的读时 aggregate。
- ✅ **公式字段**：在表格视图中实时计算和显示数据，无需持久化存储。
- ✅ **遗留互操作**：在必要时兼容部分旧存储/事件路径（下文会明确指出）。

## 🏗️ 统一架构 (Automation System 2.0)

新版本采用统一的模块架构：
- **统一 API 面**：`supertag-automation.el` 作为对外入口，提供规则 CRUD + 条件评估 + 动作执行。
- **同步事件桥**：`supertag-automation-sync.el` 将 store/commit 事件路由到规则引擎。
- **统一接口**：用户只需要学习一种规则形状（`:trigger/:condition/:actions`）。
- **索引驱动**：规则会被预先索引，避免每次事件都全量扫描规则。

新架构的核心是**简单**和**自动化**。我们废除了"普通标签"和"数据库标签"的区分，并用一个智能的"规则索引"代替了手动的"行为附加"流程。

### 架构优势

| 特性 | 旧版本 (1.0) | 新版本 (2.0) |
|------|-------------|-------------|
| **模块结构** | 分散的多个模块，存在循环依赖 | 统一的单一模块，消除依赖问题 |
| **规则管理** | 手动附加到标签，需要用户管理 | 自动索引，系统智能管理 |
| **性能** | O(n) 遍历所有规则 | O(1) 索引查找，高性能 |
| **API一致性** | 多套不同的API接口 | 统一的API接口，学习成本低 |
| **维护性** | 复杂的模块间关系 | 简单的内聚设计，易于维护 |

### 模块加载

```elisp
;; 新的统一模块加载方式
(require 'supertag-automation)  ; 规则引擎 + 对外 API
;; `supertag-automation-sync` 会按需在内部加载。

;; 可选（高级）：通过 `supertag-after-operation-hook` 触发自动化。
;; 默认 nil，用于避免双重触发（store 可能发出多条事件流）。
;; (setq supertag-automation-sync-use-commit-hooks t)
```

```mermaid
graph LR
    subgraph "旧版架构"
        A1[数据变化] --> B1[事件唤醒]
        B1 --> C1[遍历/过滤规则]
        C1 --> D1[执行]
    end
    
    subgraph "新版架构"
        A2[规则定义] --> B2[后台自动建立索引]
        C2[数据变化] --> D2[事件通知]
        D2 --> E2[O(1) 索引查询]
        E2 --> F2[精确条件评估]
        F2 --> G2[执行]
    end
    
    style B2 fill:#e8f5e8
    style E2 fill:#e8f5e8
    style G2 fill:#e1f5fe
```

## 📚 快速开始：创建您的第一条自动化规则

在新的体系下，您不再需要“附加”行为。您只需要**定义一条规则**，系统会自动处理剩下的一切。

*(注：以下所有示例都假设您已经通过 `supertag-tag-create` 和 `supertag-relation-create` 预先定义了所需要的标签（如 `#task`, `#project`）和关系。我们在此专注于自动化规则本身的创建。)*

**场景**: 当任何节点被添加 `#task` 标签时，自动将其 `TODO` 状态设置为 "TODO"。

```elisp
;; 创建一条自动化规则
(supertag-automation-create
 '(:name "auto-set-todo-on-task"
   ;; 触发器：当有节点被添加 "task" 标签时
   :trigger (:on-tag-added "task")
   ;; 动作列表：可以包含一个或多个动作
   :actions '((:action :update-todo-state
              :params (:state "TODO")))))
```

**这就完成了！**

#### 模拟效果

**操作前**:
```org
* 一个普通的标题
```

**操作**: 在 Org Mode 中，光标停留在标题上，运行 `M-x supertag-add-tag` 并选择/输入 `task`。

**操作后**:
```org
* TODO 一个普通的标题 #task
```
**效果分析**: 规则被 `:on-tag-added` 触发器激活，执行了 `:actions` 列表中的 `:update-todo-state` 动作，自动设置 headline 的 TODO 关键字。

> 注意：`supertag` 的标签是以内联 `#tag` 的形式呈现，并存储在 supertag 数据库中。
> `M-x supertag-add-tag` / `M-x supertag-remove-tag-from-node` 是推荐的变更方式；
> `org-set-tags-command` 修改的是 Org 原生的 `:tag:` 机制，与 supertag 标签不是一回事。

---

## 核心概念：关系 (Relations)

关系是 `supertag` 的核心能力之一，它负责在不同类型的数据（由标签定义）之间建立有意义的链接。例如，将“项目”笔记和“任务”笔记关联起来。

您可以使用 `supertag-relation-create` 函数来定义一个关系。

### 关系类型 (Relation Types)

定义关系时，最重要的属性是 `:type`，它决定了数据之间的关联方式（基数）。

| 类型 | 格式 | 描述 | 示例 |
| :--- | :--- | :--- | :--- |
| **一对一** | `:one-to-one` | 一个“源”节点最多只能关联一个“目标”节点。 | 一个 `User` 只能有一个 `Profile`。一个任务最多只能有一个“前置任务”。 |
| **一对多** | `:one-to-many` | 一个“源”节点可以关联**多个**“目标”节点，但每个“目标”节点只能被一个“源”节点关联。 | 一个 `#Project` 可以包含多个 `#Task`。一本 `#Notebook` 可以包含多篇 `#Note`。 |
| **多对多** | `:many-to-many` | “源”节点和“目标”节点之间可以任意相互关联，数量不限。 | 一篇 `#Article` 可以有多个 `#Keyword`；一个 `#Keyword` 也可以用于多篇 `#Article`。 |

### 已退出的关系行为

关系字段同步和可执行 rollup 已退出。新关系不能再请求 `:sync-fields`、rollup
配置或原来的 `:sync-field`／`:rollup` 关系类型。Store 中已有的相关元数据作为
惰性历史数据保留：加载或更新不会传播字段、重算值，也不会把它转换为 Org 属性。
汇总请使用 query 的读时 aggregate；其结果不会作为 rollup 写入持久数据。

---

## 核心概念：公式字段 (Formula Fields)

公式字段是 `supertag` 的一项创新功能，它允许您在表格视图中定义“虚拟列”，这些列的值是根据其他字段实时计算得出的。公式字段的计算结果**不会**存储在节点的属性中，它们只在表格视图被渲染时计算并显示。

### 如何定义公式字段

您可以在标签定义中，像声明普通字段一样声明公式字段，但其 `:type` 为 `:formula`，并包含一个 `:formula` 属性来定义计算表达式。

```elisp
(supertag-tag-create
 '(:id "task"
   :name "Task"
   :fields ((:name "due_date" :type :date)
            (:name "completed_date" :type :date)
            (:name "progress" :type :number)
            ;; 示例：用于显示的派生数值（不持久化）
            (:name "days_left" :type :formula
                   :formula "10 - progress")
            ;; 示例：计算完成百分比（基础算术）
            (:name "completion_percentage" :type :formula
                   :formula "(progress / 100) * 100"))))
```

### 公式语言与可用函数

公式字段使用统一的中缀语法，与表格公式字段、公式虚拟列、自动化公式字段共享同一个求值器。字段引用直接写字段名；算术为 `+ - * /`（支持括号），`/` 是浮点除法（除零得 0）。

- 示例：`"(done / total) * 100"` 读取当前节点的 `done` 与 `total` 字段值并计算百分比。
- 未知字段取 schema 默认值（未设置时 nil/0）。
- 旧的 `{{key}}` 占位符前缀公式（如 `"(- 10 {{:progress}})"`）会自动翻译为中缀语法，存量配置无需改动。

### 公式字段与自动化规则的区别

| 特性 | 公式字段 | 自动化规则 |
| :--- | :--- | :--- |
| **目的** | 在**视图中**实时显示计算结果 | 根据事件执行明确的持久化动作 |
| **触发时机** | 表格视图渲染时 | 数据变更事件（如属性变化、标签增删） |
| **数据持久化** | **不**存储结果 | 存储明确动作产生的结果 |
| **适用场景** | 不改变源数据的轻量显示计算 | 明确的事件驱动工作流 |

---

## 核心概念：计划任务 (Scheduled Tasks)

除了响应实时的数据变化，Automation System 2.0 还可以由时间驱动，执行预先安排好的计划任务。这背后由一个集成的、可靠的调度器服务 (`supertag-services-scheduler.el`) 提供支持。

您无需直接与调度器交互。您只需定义一个带有时间规则的 Automation，系统就会自动为您安排好一切。

### 如何定义计划任务

一个计划任务本质上是一个普通的 Automation 规则，但它必须遵循以下约定：

1.  **触发器 (`:trigger`)** 的值必须是 `:on-schedule`。
2.  **动作 (`:actions`)** 列表中的动作，其类型必须是 `:call-function`。因为计划任务没有单一的上下文节点，它需要调用一个更通用的函数来执行批量操作。
3.  必须提供一个 **`:schedule`** 属性来定义执行时间。

#### **时间表 (`:schedule`) 参数详解**

`:schedule` 属性是一个属性列表（plist），用于精确描述任务的执行时间。

| 参数 | 类型 | 描述 |
| :--- | :--- | :--- |
| **`:type`** | 关键字 | 计划任务的类型。目前支持 `:daily`（每日类型）。 |
| **`:time`** | 字符串 | 任务执行的时间，格式为 `"HH:MM"` (24小时制)。 |
| **`:days-of-week`**| 列表 (可选) | 一个由数字组成的列表，用于指定在一周中的哪几天执行。`0` 代表周日, `1` 代表周一, ..., `6` 代表周六。如果省略此参数，任务将在每天的指定时间执行。 |

### 完整示例：每周任务回顾

这是一个完整的、可直接使用的例子。

**场景**：每周五晚上8点，自动查找所有未完成的高优先级任务，并为它们添加一个 `#review` 标签，以便周末回顾。

```elisp
;; 1. 定义计划任务规则
(supertag-automation-create
 '(:name "weekly-review-high-priority-tasks"
   :trigger :on-schedule
   :schedule (:type :daily :time "20:00" :days-of-week '(5)) ; 5代表周五
   :actions '((:action :call-function
              :params (:function #'my-app-flag-tasks-for-review)))))

;; 2. 实现规则所调用的函数
(defun my-app-flag-tasks-for-review ()
  "查找所有未完成的高优先级任务，并添加review标签。"
  (interactive)
  (let ((tasks-to-review 
         (supertag-query-nodes
          '(and (has-tag "task")
                (not (property-equals :status "Done"))
                (property-equals :priority "High")))))
    (dolist (task tasks-to-review)
      (let ((task-id (plist-get task :id)))
        (supertag-node-add-tag task-id "review")
        (message "Task %s flagged for weekly review." (plist-get task :title))))
    (message "%d tasks flagged for review." (length tasks-to-review))))
```

### 激活调度器

**重要提示**：要让计划任务开始运行，您必须在您的 Emacs 配置文件（如 `init.el`）中，手动启动一次调度器服务。此操作只需执行一次。

```elisp
(supertag-scheduler-start)
```

一旦启动，调度器就会在后台持续运行，并在您指定的时间精确地执行您定义的计划任务。

---

## 📖 自动化规则参考手册

要创建自己的规则，您需要了解构成规则的三个核心部分：**触发器 (WHEN)**、**条件 (IF)** 和 **动作 (THEN)**。

### 1. 触发器 (Triggers) - `WHEN`

`trigger` 字段定义了“何时”检查这条规则。一个精确的触发器是高性能的基石。

| 触发器类型 | 格式 | 描述 |
| :--- | :--- | :--- |
| **任意变化** | `:on-change` | 当系统识别到 store 变化事件时触发（很宽；建议用条件缩小范围）。 |
| **属性/字段变化** | `:on-property-change` | 当 property/field/global-field 变化时触发（很宽；建议用 `property-changed` / `field-changed` 缩小范围）。 |
| **字段变化** | `:on-field-change` | 当全局字段值变化时触发。 |
| **标签添加时** | `(:on-tag-added "tag-name")` | 当一个节点被**首次**添加指定标签时触发。 |
| **标签移除时** | `(:on-tag-removed "tag-name")` | 当一个节点的指定标签被移除时触发。 |
| **计划任务** | `:on-schedule` | 基于时间的触发器，需要提供 `:schedule` 属性并启动调度器。 |
| **总是匹配 / 兜底** | `nil` / `:always` | 总是匹配（适用于“由 tag 触发本身就足够明确”的规则场景）。 |

说明：
- `:on-schedule` 由调度器 runner 执行，不依赖 store 变化事件匹配。
- 未知 trigger 会 fail closed（不匹配，不执行）。

### 2. 条件 (Conditions) - `IF`

`condition` 字段定义了规则要执行所必须满足的“前提条件”。它是一个 Lisp 风格的逻辑表达式。

| 条件类型 | 格式 | 描述 |
| :--- | :--- | :--- |
| **逻辑组合** | `(and ...)` `(or ...)` `(not ...)` | 用于组合多个条件，实现复杂的逻辑判断。 |
| **拥有标签** | `(has-tag "tag-name")` | 检查当前节点是否拥有指定的标签。 |
| **Org 本地属性** | `(property "STAGE" "ready")` | 精确匹配已保存并已同步的 Org 属性文本；属性名统一为大写，空字符串与属性缺失不同。 |
| **属性等于** | `(property-equals :prop-name "value")` | 检查节点的某个属性是否等于一个特定的值。 |
| **属性已改变**| `(property-changed :prop-name)` | 检查本次事件是否是由指定属性的变化引起的。 |
| **属性测试**| `(property-test :prop-name #'> 8)` | 使用一个函数来对属性值进行测试。 |
| **字段等于** | `(field-equals "field-name" "value")` | 把显示名或 ID 解析到稳定全局字段，再检查字段值。 |
| **字段发生变化** | `(field-changed "field-name")` | 把显示名或 ID 解析到稳定全局字段，再检查本次是否改变了它。 |
| **全局字段等于** | `(global-field-equals "field-id" "value")` | 检查全局字段值（field-id 为全局字段的 slug/id）。 |
| **全局字段发生变化** | `(global-field-changed "field-id")` | 检查本次事件是否改变了该全局字段。 |
| **全局字段测试** | `(global-field-test "field-id" #'pred ...)` | 使用函数测试全局字段值。 |

`property` 与 `field` 不同：它只读取 Org 属性的投影文本，不解析或回退到旧字段。
Query 与 Automation 条件读取已同步的数据库快照，不读取尚未保存的 Org 草稿。

真实 Org 变更保存并经增量同步处理后，可以触发一次匹配规则；未变化的投影是
no-op。`supertag-reindex-org` 则只负责重建投影：它可以刷新 query 结果，但不会
执行 Automation 动作，也不会把这些动作回写到 Org。

#### `:condition`（规则字段）

在规则 plist 中，`:condition` 是 **IF** 部分。它是可选字段，并且必须是 Lisp 列表形式：

```elisp
(supertag-automation-create
 '(:name "only-when-hours-changed"
   :trigger :on-property-change
   :condition (and (has-tag "task") (property-changed :hours))
   :actions '((:action :add-tag :params (:tag "touched")))))
```

- 可选：省略或设为 `nil` 表示永远通过（只要 `:trigger` 匹配就会执行）。
- 形式：引擎只支持一组内置谓词（`has-tag`、`property-equals` 等）以及 `and/or/not`（不是任意 `eval`）。
- 引号：`:condition (and ...)` 和 `:condition '(and ...)` 都可用；引擎会自动解开最外层的一次 `quote`。如果整个规则已经用 `'(...)` 引用，一般不需要再给 `:condition` 单独加 `'`。
- `property-changed` / `field-changed` 这类“依赖事件”的条件会读取事件的 `:path`（见下方“事件上下文”），因此要配合正确的 `:trigger`（如 `:on-property-change` / `:on-field-change`）使用。

> 本指南不定义“条件级公式 DSL”。复杂逻辑建议用现有条件组合，或迁移到 `:call-function` 动作中实现。

### 3. 动作 (Actions) - `THEN`

`actions` 字段（注意是复数）定义了当触发器和条件都满足时，系统应该按顺序执行的一个或多个动作。它是一个**动作列表**。

每个动作都是一个 `plist`，格式为 `(:action :action-type :params (...))`。

| 动作类型 (`:action-type`) | `:params` 参数 | 描述 |
| :--- | :--- | :--- |
| **`:update-property`** | `(:property :prop-name :value new-value)` | 在节点的活 Org 标题中更新属性，或用 `nil` 删除属性；保存成功后再刷新数据库表示。属性名可用 keyword 或 Org 字符串，支持的标量会转成单行文本；拒绝 `ID`、只读特殊属性、多行文本和结构值。 |
| **`:update-todo-state`** | `(:state "new-state")` | 更新当前节点的 TODO 状态 (例如 "DONE", "TODO")。这会直接修改标题的关键字，与 `:update-property` 不同。 |
| **`:add-tag`** | `(:tag "tag-name")` | 为当前节点添加一个新标签。 |
| **`:remove-tag`** | `(:tag "tag-name")` | 从当前节点移除一个标签。 |
| **`:call-function`** | `(:function #'your-function :args (...))` | 调用一个您自己定义的 Emacs Lisp 函数。这是实现复杂逻辑的“终极武器”。函数会接收 `(node-id context &rest args)` 参数。 |
| **`:create-node`** | `(:title "..." :tags '("...") :target-file "/absolute/path/to/notes.org")` | 在既有本地 Org 文件末尾追加带 ID 的一级标题，保存后再投影。`:tags` 写入 Org Tag Occurrence；只有已存在的 Semantic Tag 才会解析进数据库投影。标题保留 Org 原生语法。必须显式提供绝对目标路径；缺少目标的旧规则会失败，需手动补充。 |
| **`:update-field`** | `(:tag "tag-id" :field "field-name" :value v)` | 通过 Tag schema 解析字段，并更新该 node 的全局字段值。 |
| **`:case`** | `(:on (:field "层级") :branches '((:equals "20" :actions ((:action :update-field ...))) (:default t :actions ((:action :call-function ...)))))` | 根据 `:on` 解析出的值执行首个匹配分支。每个分支可使用 `:equals`、`:in`、`:match`（正则/函数）或 `:test` 进行匹配，并包含自己的 `:actions` 列表。通过 `:default t` 指定兜底分支。 |

#### 事件上下文（重要）

规则执行时会收到一个 `context` plist，描述当前事件：

- 值变化事件通常包含：
  - `:path` —— 结构化路径，描述“哪里发生了变化”
  - `:old` / `:new` —— 对应路径的旧值/新值
- 标签事件通常包含：
  - `:tag-event` —— `:added/:removed`（旧链路）或 `:add-tag/:remove-tag`（sync bridge）
  - `:tag` —— 标签名（字符串）

引擎常见的 `:path` 形态：

- 节点属性变化：`(:nodes NODE-ID :properties :some-prop)`
- 全局字段值变化：`(:field-values NODE-ID "field-id")`

`(property-changed ...)` 依赖 `:path` 足够精确（例如 `(:nodes NODE-ID :properties :hours)`），因此事件路由链路必须保留这种精度。

提示：一个常用的内置 helper 是 `supertag-service-org-move-node-to-file-action`，用于把节点 subtree 非交互式移动到目标文件：

```elisp
(:action :call-function
 :params (:function #'supertag-service-org-move-node-to-file-action
         :args ("~/org/archive.org" t 1)))
```

---

## 🎯 使用示例

### 示例1：功能强大的任务管理

这个例子将展示一些原生 Org Mode 难以或无法实现的功能，体现新系统的独特价值。

*(注：此示例假设已预定义了带有 `status`, `priority`, `hours` 字段的 `#task` 标签，以及一个名为 `depends_on` 的 `task` 到 `task` 的一对一关系。)*

#### 1. 创建真正“智能”的自动化规则

**规则 A：根据预估工时，自动设定优先级**

```elisp
(supertag-automation-create
 '(:name "auto-set-priority-by-effort"
   :trigger :on-property-change
   :condition (and
               (has-tag "task")
               (property-changed :hours)
               (property-test :hours #'> 8))
   :actions '((:action :update-property
              :params (:property :priority :value "High")))))
```
*(提示：把 `:on-property-change` 与 `property-changed`/`property-test` 搭配使用，可以让规则更精确。)*

**规则 B：当一个任务完成后，自动解锁下一个依赖它的任务**

```elisp
(supertag-automation-create
 '(:name "unlock-next-dependent-task"
   :trigger :on-property-change
   :condition (and (has-tag "task")
                   (property-equals :status "Done"))
   :actions '((:action :call-function
              :params (:function #'my-app-unlock-next-task)))))

;; 为上面的规则实现自定义函数
(defun my-app-unlock-next-task (node-id context)
  "找到下一个依赖于刚刚完成任务的节点，并将其状态从'Waiting'更新为'Todo'."
  (interactive)
  (let* ((completed-task-id node-id)
         (dependent-tasks (supertag-relation-get-reverse-related-nodes
                           completed-task-id "depends_on")))
    (dolist (task-info dependent-tasks)
      (let ((task-id (plist-get task-info :id))
            (task-data (supertag-node-get (plist-get task-info :id))))
        (when (equal (plist-get task-data :status) "Waiting")
          (supertag-node-update-property task-id :status "Todo")
          (message "Task %s unlocked, status set to TODO." (plist-get task-data :title)))))))
```

#### 2. 模拟效果

*   **智能优先级**:
    *   **操作前**: 节点 `#task` 的 `:priority:` 属性为 `Low`。
    *   **操作**: 将该节点的 `:hours:` 属性值从 `4` 修改为 `10`。
    *   **操作后**: 该节点的 `:priority:` 属性自动变为 `High`。

*   **依赖解锁**:
    *   **操作前**: “任务A”和“任务B”都是 `#task`。“任务B”通过 `depends_on` 关系依赖于“任务A”，且“任务B”的 `:status:` 为 `Waiting`。
    *   **操作**: 将“任务A”的 `:status:` 修改为 `Done`。
    *   **操作后**: “任务B”的 `:status:` 自动从 `Waiting` 变为 `Todo`。

### 示例：使用 `:case` 做层级映射

当您需要把某个字段的取值映射成另一字段时，不必再写多条规则或自定义函数。下面的规则监控 `#contact` 节点的“层级”字段，根据取值自动设置推荐的“联系频率”。如果遇到意料之外的层级，默认分支会给出兜底值，保证数据保持一致。

```elisp
(supertag-automation-create
 '(:name "contact-tier-frequency"
   :trigger :on-field-change
   ;; 在全局字段模型下，规则直接以字段为中心，
   ;; 这里的 field-changed 会映射到对应的全局字段。
   :condition '(and (has-tag "contact")
                    (field-changed "层级"))
   :actions
   '((:action :case
      :params
      (:on (:field "层级")
       :branches
       ((:equals "20"
         :actions ((:action :update-field
                            :params (:tag "contact" :field "联系频率" :value "30d"))))
        (:equals "50"
         :actions ((:action :update-field
                            :params (:tag "contact" :field "联系频率" :value "90d"))))
        (:equals "150"
         :actions ((:action :update-field
                            :params (:tag "contact" :field "联系频率" :value "180d"))))
        (:default t
         :actions ((:action :update-field
                            :params (:tag "contact" :field "联系频率" :value "90d"))))))))))
```

每个分支内都是独立的 `:actions` 列表，因而还能继续追加更多动作（例如加标签、更新属性或调用函数），从而把复杂分支逻辑收敛到单条自动化规则中。

### 字段为中心的规则（Field-Centric Rules）

全局字段模型始终启用：字段不再绑定在某个单一 tag 上，而是作为一等实体存在。自动化 DSL 支持写“以字段为中心”的规则——即规则主要由字段变化驱动，而不是由 tag 决定：

- `field-equals` / `field-changed` —— 把第一个字符串参数作为稳定全局字段 ID 或显示名解析。
- `global-field-equals` / `global-field-changed` —— 显式的全局字段版本，如果你希望语义完全清晰。

例如，下面这条规则会在任意节点的全局字段 `status` 变为 `"done"` 时触发，与节点上挂了哪些 tag 无关：

```elisp
(supertag-automation-create
 '(:name "status-done-anywhere"
   :trigger :on-field-change
   :condition '(field-equals "status" "done")
   :actions ((:action :call-function
              :params (:function
                       (lambda (node-id _ctx &rest _)
                         (message "节点 %s 的 status 变为 done" node-id)))))))
```

当然，你仍然可以把字段条件和 tag 条件组合起来，用于缩小规则的适用范围：

```elisp
:condition '(and (has-tag "task")
                 (field-equals "status" "doing"))
```

在内部实现上，`field-equals` / `field-changed` 按稳定全局字段 ID 建立索引，因此修改显示名不会搬动已有值，也不会让新规则与 `:field-values` 事件失联。

### 示例2：项目与任务联动

这个例子展示关系（Relation）与一条明确的 Automation 规则。

*(注：此示例假设已预定义带有 `status` 字段的 `#Project` 标签，以及一个名为 `tasks`、从 `Project` 到 `task` 的一对多关系。)*

#### 1. 创建自动化规则

当一个子任务的状态发生变化时，我们希望检查父项目是否所有任务都已完成。

```elisp
(supertag-automation-create
 '(:name "auto-complete-project"
   :trigger :on-property-change
   :condition (and (has-tag "task") (property-equals :status "Done"))
   :actions '((:action :call-function
              :params (:function #'my-app-check-project-completion)))))

;; 实现检查项目完成状态的函数
(defun my-app-check-project-completion (task-id context)
  "当一个任务完成后，检查其所属的项目是否所有任务都已完成。"
  (interactive)
  ;; 1. 找到这个task所属的project
  (when-let ((projects (supertag-relation-get-related-nodes task-id "tasks" :reverse t)))
    (let* ((project-id (plist-get (car projects) :id))
           (all-tasks (supertag-relation-get-related-nodes project-id "tasks"))
           (all-done t))
      ;; 2. 检查项目下的所有任务是否都已完成
      (dolist (task all-tasks)
        (unless (equal (plist-get (supertag-node-get (plist-get task :id)) :status) "Done")
          (setq all-done nil)))
      ;; 3. 如果所有任务都完成，则更新项目状态
      (when all-done
        (supertag-node-update-property project-id :status "Done")
        (message "All tasks in Project %s are done. Project status updated." project-id))))) 
```

#### 2. 模拟效果

*   **项目自动完成 (由本规则驱动)**:
    *   **操作前**: `#Project` 关联了两个 `#task`，一个是 `Done` 状态，另一个是 `Todo` 状态。
    *   **操作**: 将那个 `Todo` 状态的 `#task` 修改为 `Done`。
    *   **操作后**: `#Project` 的 `:status:` 自动变为 `Done`。

### 示例3：多重动作 (Multi-Action)

这是新自动化引擎强大能力的最佳体现：一条规则可以按顺序执行多个动作。

**场景**: 当一个任务的状态被设置为 `Done` 时，自动记录完成日期，为其打上 `#archived` 标签，并把节点移动到归档文件。

```elisp
(supertag-automation-create
 '(:name "process-completed-task"
   :trigger :on-property-change
   :condition (and (has-tag "task")
                   (property-equals :status "Done"))
   :actions
   '((:action :update-property
      :params (:property :completed_date :value (current-time)))
     (:action :add-tag
      :params (:tag "archived"))
     (:action :call-function
      :params (:function #'supertag-service-org-move-node-to-file-action
              :args ("~/org/archive.org" t 1))))))
```

#### 模拟效果

*   **操作前**: 一个 `#task` 节点，其 `:status:` 为 `Doing`，没有 `:completed_date:` 属性，也没有 `#archived` 标签。
*   **操作**: 将该节点的 `:status:` 修改为 `Done`。
*   **操作后**:
    1.  该节点新增了 `:completed_date:` 属性，其值为当前时间。
    2.  该节点被自动添加了 `#archived` 标签。
    3.  该节点 subtree 会被移动到 `~/org/archive.org`（并在原位置留下一个 `id:` 链接）。

---

## 🔧 核心理念回顾

经过我们的重构，系统的核心理念变得更加清晰：

1.  **标签是核心**：所有数据结构（字段）和行为（自动化）都围绕标签来组织。
2.  **规则是声明式**：您只需要在规则中用 `:trigger` 和 `:condition` “声明”它关心的事件和目标，系统会自动把它应用到正确的地方。
3.  **后台是智能的**：您无需关心性能。系统会自动为您的规则建立索引，确保即使有成百上千条规则，响应速度依然飞快。
4.  **无阶级之分**：任何标签，无论简单还是复杂，都可以拥

---

## 🔧 测试和调试自动化规则

### 手动测试单个规则

当您创建了自动化规则后，可以使用以下方法来测试和调试：

```elisp
;; 模拟触发规则
(supertag-rule-execute rule node-id context)

;; 重建规则索引
(supertag-rebuild-rule-index)

;; 查看当前索引状态
(hash-table-count supertag--rule-index)
```

### 最小验证矩阵（手动）

下面的矩阵提供一些“小而可重复”的场景，用于确认规则引擎的事件/索引/执行链路是否打通。
在加载 `supertag` 后，您可以在 `*scratch*` 里执行这些片段。

#### 1) 标签触发：`(:on-tag-added "task")`

```elisp
(supertag-automation-create
 '(:name "verify-tag-added"
   :trigger (:on-tag-added "task")
   :actions '((:action :add-tag :params (:tag "verified")))))

(let ((node-id (supertag-node-create :title "Verify tag-added" :tags nil)))
  (supertag-ops-add-tag-to-node node-id "task" :create-if-needed t)
  (message "tags=%S" (plist-get (supertag-node-get node-id) :tags)))
;; 预期：tags 包含 "task" 与 "verified"。
```

#### 2) 标签触发：`(:on-tag-removed "task")`

```elisp
(supertag-automation-create
 '(:name "verify-tag-removed"
   :trigger (:on-tag-removed "task")
   :actions '((:action :add-tag :params (:tag "removed-task")))))

(let ((node-id (supertag-node-create :title "Verify tag-removed" :tags '("task"))))
  (supertag-with-transaction
    (supertag-node-remove-tag node-id "task"))
  (message "tags=%S" (plist-get (supertag-node-get node-id) :tags)))
;; 预期：tags 包含 "removed-task"，且不包含 "task"。
```

#### 3) 属性变化 + `property-changed`

```elisp
(supertag-automation-create
 '(:name "verify-property-changed"
   :trigger :on-property-change
   :condition (property-changed :hours)
   :actions '((:action :update-property :params (:property :verified_hours :value t)))))

(let ((node-id (supertag-node-create :title "Verify property-changed" :tags nil)))
  (supertag-node-update-property node-id :hours 10)
  (message "verified_hours=%S"
           (supertag-node-get-property node-id :verified_hours)))
;; 预期：verified_hours 为非 nil。
```

#### 4) 属性测试（`property-test`）

```elisp
(supertag-automation-create
 '(:name "verify-property-test"
   :trigger :on-property-change
   :condition (property-test :hours #'> 8)
   :actions '((:action :add-tag :params (:tag "gt8")))))

(let ((node-id (supertag-node-create :title "Verify property-test" :tags nil)))
  (supertag-node-update-property node-id :hours 7)
  (supertag-node-update-property node-id :hours 9)
  (message "tags=%S" (plist-get (supertag-node-get node-id) :tags)))
;; 预期：在 9 这次更新后 tags 才包含 "gt8"。
```

### 调试技巧

- **添加日志**：使用 `message` 函数在规则中添加日志输出
- **检查触发条件**：确认规则的触发条件是否正确匹配
- **验证数据路径**：检查属性名称和数据路径是否正确

```elisp
;; 在自定义函数中添加调试信息
(defun my-debug-function (node-id context)
  (message "Debug: Processing node %s with context %s" node-id context)
  ;; 您的逻辑代码
  )

;; 检查节点属性
(supertag-node-get node-id)

;; 检查规则是否正确索引
;; - property key（keyword）：例如 :hours
;; - tag name（string）：例如 "task"
(gethash :hours supertag--rule-index)
(gethash "task" supertag--rule-index)
```

### 测试工作流

1. **创建测试节点**：创建用于测试的示例节点
2. **触发事件**：手动修改属性或添加标签来触发规则
3. **验证结果**：检查规则执行后的数据变化
4. **调试问题**：如果结果不符合预期，检查触发器、条件和动作

```elisp
;; 示例：测试任务优先级自动设置规则
(let ((test-node-id (supertag-node-create
                     :title "测试任务"
                     :tags '("task"))))
  ;; 触发规则
  (supertag-node-update-property test-node-id :hours 10)
  ;; 验证结果
  (let ((priority (supertag-node-get-property test-node-id :priority)))
    (message "Priority after update: %s" priority)))
```

---

## 📦 批量操作和维护

### 系统维护命令

Automation System 2.0 提供了一系列维护命令来确保系统的健康运行：

```elisp
;; 清理和重建索引
(supertag-automation-cleanup)
(supertag-automation-init)
(supertag-rebuild-rule-index)
```

### 批量数据操作

当您需要对大量数据执行相同的操作时，可以使用以下模式：

```elisp
;; 批量更新所有未完成任务的优先级
(defun batch-update-task-priority ()
  "将所有未完成的任务优先级设置为 Normal。"
  (interactive)
  (let ((tasks (supertag-query-nodes
                '(and (has-tag "task")
                      (not (property-equals :status "Done"))))))
    (dolist (task tasks)
      (let ((task-id (plist-get task :id)))
        (supertag-node-update-property task-id :priority "Normal")))
    (message "Updated %d tasks" (length tasks))))

;; 批量清理过期的归档任务
(defun batch-cleanup-archived-tasks ()
  "删除超过90天的已归档任务。"
  (interactive)
  (let* ((cutoff-date (time-subtract (current-time) (days-to-time 90)))
         (old-tasks (supertag-query-nodes
                     `(and (has-tag "task")
                           (has-tag "archived")
                           (property-test :completed_date
                                          (lambda (date)
                                            (time-less-p date ,cutoff-date)))))))
    (dolist (task old-tasks)
      (supertag-node-delete (plist-get task :id)))
    (message "Cleaned up %d old archived tasks" (length old-tasks))))
```

### 数据导入导出

```elisp
;; 批量导入任务数据
(defun import-tasks-from-csv (csv-file)
  "从 CSV 文件批量导入任务。"
  (interactive "fCSV file: ")
  (with-temp-buffer
    (insert-file-contents csv-file)
    (let ((lines (split-string (buffer-string) "\n" t)))
      (dolist (line (cdr lines)) ; 跳过标题行
        (let* ((fields (split-string line ","))
               (title (nth 0 fields))
               (priority (nth 1 fields))
               (hours (string-to-number (nth 2 fields))))
          (let ((node-id (supertag-node-create :title title :tags '("task"))))
            (supertag-node-update-property node-id :priority priority)
            (supertag-node-update-property node-id :hours hours)))))
    (message "Tasks imported successfully")))

;; 导出项目报告
(defun export-project-summary (project-tag output-file)
  "导出项目摘要报告到文件。"
  (interactive "sProject tag: \nFOutput file: ")
  (let* ((projects (supertag-query-nodes `(has-tag ,project-tag)))
         (report-lines '("Project Summary Report" "=========================")))
    (dolist (project projects)
      (let* ((project-id (plist-get project :id))
             (title (plist-get project :title))
             (total-hours (supertag-node-get-property project-id :total_hours))
             (status (supertag-node-get-property project-id :status)))
        (push (format "Project: %s | Status: %s | Hours: %s"
                      title status total-hours) report-lines)))
    (with-temp-file output-file
      (insert (string-join (reverse report-lines) "\n")))
    (message "Report exported to %s" output-file)))
```
��


---

## ⚡ 性能监控和优化

### 索引系统工作原理

Automation System 2.0 的核心性能优势来自于智能索引系统：

- **规则索引**：规则根据触发源自动建立索引
- **O(1) 查找**：无需遍历所有规则，实现常数时间查找
- **精确匹配**：支持属性变化和标签变化的精确匹配
- **自动维护**：索引在后台自动创建和更新

```elisp
;; 查看索引状态
(defun supertag-check-index-status ()
  "检查规则索引的状态和统计信息。"
  (interactive)
  (let ((entry-count (hash-table-count supertag--rule-index))
        (by-type (make-hash-table :test 'eq)))
    (maphash (lambda (key _value)
               (let ((tkey (cond
                            ((keywordp key) :keyword)
                            ((stringp key) :string)
                            ((symbolp key) :symbol)
                            (t :other))))
                 (puthash tkey (1+ (gethash tkey by-type 0)) by-type)))
             supertag--rule-index)
    (message "Index entries: %d" entry-count)
    (maphash (lambda (type count)
               (message "  %s: %d" type count))
             by-type)))

;; 测试规则查找性能
(defun supertag-benchmark-rule-lookup (iterations)
  "基准测试规则查找性能。"
  (interactive "nIterations: ")
  (let ((start-time (current-time))
        (test-key :status))
    (dotimes (i iterations)
      (gethash test-key supertag--rule-index))
    (let ((elapsed (float-time (time-subtract (current-time) start-time))))
      (message "Performed %d lookups in %.4f seconds (%.2f μs per lookup)" 
               iterations elapsed (* (/ elapsed iterations) 1000000)))))
```

### 性能最佳实践

#### 1. 触发器优化

```elisp
;; 注意：`:trigger` 必须拼写正确且能匹配当前事件，否则规则不会执行。
;; （例如写成 `:on-field-chang` 会被视为未知 trigger，从而不会触发。）

;; 好的做法：使用具体的触发器
(supertag-automation-create
 '(:name "specific-trigger"
   :trigger (:on-tag-added "task")  ; 具体的标签触发器
   :actions '((:action :update-property :params (:property :status :value "Todo")))))

;; 避免的做法：过于通用的触发器
(supertag-automation-create
 '(:name "generic-trigger"
   :trigger :on-property-change  ; 通用触发器，需要额外的条件过滤
   :condition (has-tag "task")
   :actions '((:action :update-property :params (:property :status :value "Todo")))))
```

#### 2. 条件逻辑优化

```elisp
;; 好的做法：将最容易失败的条件放在前面
(supertag-automation-create
 '(:name "optimized-conditions"
   :trigger :on-property-change
   :condition (and 
               (property-equals :priority "High")  ; 具体值匹配，快速失败
               (has-tag "task")                    ; 标签检查
               (property-test :hours #'> 8))  ; 数值测试放最后
   :actions '((:action :add-tag :params (:tag "urgent")))))
```

#### 3. 避免循环依赖

```elisp
;; 危险：可能导致无限循环
(supertag-automation-create
 '(:name "potential-loop"
   :trigger :on-property-change
   :condition (property-equals :status "Done")
   :actions '((:action :call-function
              :params (:function #'my-app-mark-completed-and-archive)))))  ; 不加保护会自触发

;; 示例函数（可按需加入保护逻辑）
(defun my-app-mark-completed-and-archive (node-id _context)
  "设置完成时间并归档（示例）。"
  (supertag-node-update-property node-id :completed_date (current-time))
  (supertag-node-update-property node-id :status "Archived"))

;; 安全的做法：通过条件防止重复触发
(supertag-automation-create
 '(:name "safe-completion"
   :trigger :on-property-change
   :condition (and (property-equals :status "Done")
                   (property-test :completed_date #'null))  ; 防止重复触发
   :actions '((:action :call-function
              :params (:function #'my-app-mark-completed))))))

(defun my-app-mark-completed (node-id _context)
  "只设置一次 :completed_date（示例）。"
  (supertag-node-update-property node-id :completed_date (current-time)))
```

### 性能监控工具

```elisp
;; 规则执行统计
(defvar supertag--rule-stats (make-hash-table :test 'equal)
  "规则执行统计信息。")

(defun supertag-track-rule-execution (rule-name execution-time)
  "记录规则执行统计。"
  (let ((stats (gethash rule-name supertag--rule-stats '(:count 0 :total-time 0))))
    (puthash rule-name 
             `(:count ,(1+ (plist-get stats :count))
               :total-time ,(+ (plist-get stats :total-time) execution-time))
             supertag--rule-stats)))

(defun supertag-show-performance-report ()
  "显示规则执行性能报告。"
  (interactive)
  (let ((report '()))
    (maphash (lambda (rule-name stats)
               (let* ((count (plist-get stats :count))
                      (total-time (plist-get stats :total-time))
                      (avg-time (/ total-time count)))
                 (push `(,rule-name ,count ,total-time ,avg-time) report)))
             supertag--rule-stats)
    (setq report (sort report (lambda (a b) (> (nth 2 a) (nth 2 b)))))
    (with-output-to-temp-buffer "*Supertag Performance Report*"
      (princ "Rule Performance Report\n")
      (princ "======================\n\n")
      (princ "Rule Name | Executions | Total Time | Avg Time\n")
      (princ "---------|------------|------------|----------\n")
      (dolist (entry report)
        (princ (format "%s | %d | %.4fs | %.4fs\n"
                       (nth 0 entry) (nth 1 entry) 
                       (nth 2 entry) (nth 3 entry)))))))
```

### 大规模数据优化

当处理大量节点时，考虑以下优化策略：

```elisp
;; 使用事务进行批量操作
(defun batch-update-with-transaction (node-ids update-func)
  "在事务中批量更新节点，提高性能。"
  (supertag-with-transaction
    (dolist (node-id node-ids)
      (funcall update-func node-id))))

;; 延迟计算和缓存
(defvar supertag--computation-cache (make-hash-table :test 'equal))

(defun expensive-computation-with-cache (key compute-func)
  "带缓存的昂贵计算。"
  (or (gethash key supertag--computation-cache)
      (let ((result (funcall compute-func)))
        (puthash key result supertag--computation-cache)
        result)))
```

---

## 🚨 错误处理和故障排除

### 常见问题及解决方案

#### 问题 1：规则没有执行

**症状**：定义了自动化规则，但在触发条件满足时规则没有执行。

**可能原因**：
- 触发器不匹配实际的事件
- 条件逻辑不满足
- 规则没有正确索引

**诊断步骤**：
```elisp
;; 1. 检查规则是否正确索引
;; - property key（keyword）：例如 :hours
;; - tag name（string）：例如 "task"
(gethash :hours supertag--rule-index)
(gethash "task" supertag--rule-index)

;; 2. 检查触发器类型是否正确
(supertag-check-index-status)

;; 3. 测试条件逻辑
(let ((node-id "test-node-id"))
  (and (has-tag "task")
       (property-equals :status "Done")))
```

**解决方案**：
- 确认触发器格式正确（如 `:on-tag-added` vs `(:on-tag-added "task")`）
- 使用更具体的触发器
- 检查条件中的属性名称和值是否正确
- 重建规则索引：`(supertag-rebuild-rule-index)`

#### 问题 2：性能问题

**症状**：系统响应缓慢，特别是在数据变化时。

**可能原因**：
- 使用了过于通用的触发器
- 条件逻辑过于复杂
- 在 `:call-function` 中执行耗时操作
- 循环依赖导致的重复触发

**诊断步骤**：
```elisp
;; 检查性能报告
(supertag-show-performance-report)

;; 基准测试规则查找
(supertag-benchmark-rule-lookup 10000)

;; 检查规则数量分布
(supertag-check-index-status)
```

**解决方案**：
- 使用具体的触发器而非通用触发器
- 优化条件逻辑，将快速失败的条件放在前面
- 将耗时操作移到异步任务中
- 检查并消除循环依赖

#### 问题 3：数据不一致

**症状**：某些属性值不正确，或者规则结果与预期不符。

**可能原因**：
- 并发修改导致的竞态条件
- 规则动作中的逻辑错误
- 规则执行顺序问题

**诊断步骤**：
```elisp
;; 检查节点属性
(supertag-node-get node-id)

;; 验证关系数据
(supertag-relation-get-related-nodes node-id "relation-name")
```

**解决方案**：
- 使用事务确保原子性操作
- 避免在自动化规则中直接修改存储
- 定期运行数据一致性检查
- 使用同步机制处理并发访问

### 调试模式

启用调试模式以获取更详细的日志信息：

```elisp
;; 启用 automation 的 verbose 诊断日志（常规 trace、SKIP/no-op 等）
(setq supertag-automation-verbose t)

;; 可选：打印 sync bridge 的字段事件日志
(setq supertag-debug-log-field-events t)
```

### 系统健康检查

定期运行系统健康检查以确保数据完整性：

```elisp
(defun supertag-system-health-check ()
  "执行系统健康检查。"
  (interactive)
  (let ((issues '()))
    ;; 检查规则索引完整性
    (unless (hash-table-p supertag--rule-index)
      (push "Rule index is not properly initialized" issues))
    
    ;; 检查关系一致性
    (maphash
     (lambda (_ relation)
       (let ((relation-name (plist-get relation :name)))
         (unless (supertag-relation-validate relation-name)
           (push (format "Relation %s has consistency issues" relation-name) issues))))
     (supertag-store-get-collection :relations))
    
    ;; 报告结果
    (if issues
        (message "Health check found %d issues: %s" (length issues) (string-join issues "; "))
      (message "System health check passed successfully"))))
```

---

## 🔄 从 Behavior System 1.0 迁移

### API 映射关系

| 1.0 API | 2.0 API | 说明 |
|---------|---------|------|
| `supertag-behavior-create` | `supertag-automation-create` | 统一创建接口 |
| `supertag-behavior-attach` | *自动索引* | 无需手动附加 |
| `supertag-behavior-register` | `supertag-automation-create` | 现代化接口 |
| `supertag-behavior-detach` | `supertag-automation-delete` | 删除规则 |

### 配置结构变化

#### 1.0 配置格式：
```elisp
(supertag-behavior-register
 "task"
 '(:trigger :on-property-change
   :condition (property-equals :status "Done")
   :action (:update-property :completed_date (current-time))))
```

#### 2.0 配置格式：
```elisp
(supertag-automation-create
 '(:name "complete-task-behavior"
   :trigger :on-property-change
   :condition (and (has-tag "task")
                   (property-equals :status "Done"))
   :actions '((:action :update-property
              :params (:property :completed_date :value (current-time))))))
```

### 迁移步骤

#### 步骤 1：更新 require 语句

```elisp
;; 旧版本
(require 'supertag-ops-behavior)
(require 'supertag-automation-engine)

;; 新版本
(require 'supertag-automation)  ; 统一模块
```

#### 步骤 2：转换规则定义

```elisp
;; 迁移脚本示例
(defun migrate-behavior-to-automation ()
  "将旧版本的行为规则迁移到新的自动化系统。"
  (interactive)
  ;; 1. 收集所有旧规则
  (let ((old-behaviors (supertag-behavior-list)))  ; 旧版 API 占位
    (dolist (behavior old-behaviors)
      (let ((tag (plist-get behavior :tag))
            (trigger (plist-get behavior :trigger))
            (condition (plist-get behavior :condition))
            (action (plist-get behavior :action)))
        ;; 2. 转换为新格式
        (supertag-automation-create
         `(:name ,(format "migrated-%s-behavior" tag)
           :trigger ,trigger
           :condition (and (has-tag ,tag) ,condition)  ; 添加标签条件
           :actions (,(list :action (car action) :params (cdr action)))))  ; 转换动作格式
        ;; 3. 删除旧规则
        (supertag-behavior-delete behavior)))
    (message "Migrated %d behaviors to automation rules" (length old-behaviors))))
```

#### 步骤 3：测试验证

```elisp
;; 验证迁移结果
(defun verify-migration ()
  "验证迁移后的规则是否正常工作。"
  (interactive)
  ;; 创建测试节点
  (let ((test-node (supertag-node-create :title "Migration Test" :tags '("task"))))
    ;; 触发规则
    (supertag-node-update-property test-node :status "Done")
    ;; 检查结果
    (let ((completed-date (supertag-node-get-property test-node :completed_date)))
      (if completed-date
          (message "Migration successful: completed_date = %s" completed-date)
        (message "Migration failed: no completed_date set")))
    ;; 清理测试节点
    (supertag-node-delete test-node)))
```

### 兼容性注意事项

1. **单一动作 vs 多重动作**：1.0 使用 `:action`，2.0 使用 `:actions` 列表
2. **自动索引**：2.0 不再需要手动附加行为到标签
3. **触发器格式**：某些触发器格式有所变化
4. **条件增强**：需要显式添加标签条件 `(has-tag "tag-name")`

---

## 🎯 最佳实践指南

### 规则设计原则

#### 1. 单一职责原则
每个规则只处理一种特定场景，避免在一个规则中处理多种不同的逻辑。

```elisp
;; 好的做法：分离关注点
(supertag-automation-create
 '(:name "set-task-todo"
   :trigger (:on-tag-added "task")
   :actions '((:action :update-property :params (:property :status :value "Todo")))))

(supertag-automation-create
 '(:name "set-task-priority"
   :trigger (:on-tag-added "task")
   :actions '((:action :update-property :params (:property :priority :value "Normal")))))

;; 避免的做法：在一个规则中处理多种逻辑
(supertag-automation-create
 '(:name "setup-task-everything"
   :trigger (:on-tag-added "task")
   :actions '((:action :update-property :params (:property :status :value "Todo"))
              (:action :update-property :params (:property :priority :value "Normal"))
              (:action :call-function :params (:function #'complex-task-setup)))))
```

#### 2. 明确命名
使用描述性的规则名称，清楚地表达规则的用途。

```elisp
;; 好的做法：描述性命名
(supertag-automation-create
 '(:name "auto-archive-completed-tasks"
   :trigger :on-property-change
   :condition (and (has-tag "task") (property-equals :status "Done"))
   :actions '((:action :add-tag :params (:tag "archived")))))

;; 避免的做法：模糊命名
(supertag-automation-create
 '(:name "rule1"
   :trigger :on-property-change
   :condition (and (has-tag "task") (property-equals :status "Done"))
   :actions '((:action :add-tag :params (:tag "archived")))))
```

#### 3. 精确触发
使用最具体的触发器类型，避免过度使用通用触发器。

```elisp
;; 好的做法：精确触发器
(supertag-automation-create
 '(:name "handle-project-completion"
   :trigger (:on-tag-added "completed")
   :condition (has-tag "project")
   :actions '((:action :call-function :params (:function #'celebrate-project-completion)))))

;; 避免的做法：过于通用的触发器
(supertag-automation-create
 '(:name "handle-any-change"
   :trigger :on-property-change
   :condition (and (has-tag "project") (property-equals :status "completed"))
   :actions '((:action :call-function :params (:function #'celebrate-project-completion)))))
```

#### 4. 简化条件
避免过于复杂的逻辑嵌套，将复杂逻辑移到自定义函数中。

```elisp
;; 好的做法：简化条件
(supertag-automation-create
 '(:name "flag-urgent-tasks"
   :trigger :on-property-change
   :condition (and (has-tag "task")
                   (property-equals :priority "High")
                   (property-test :hours #'> 8)
                   (not (property-equals :status "Done")))
   :actions '((:action :add-tag :params (:tag "urgent")))))

;; 避免的做法：复杂的嵌套条件
(supertag-automation-create
 '(:name "complex-urgent-check"
   :trigger :on-property-change
   :condition (and (has-tag "task")
                   (property-equals :priority "High")
                   (property-test :hours #'> 8)
                   (not (property-equals :status "Done")))
   :actions '((:action :add-tag :params (:tag "urgent")))))
```

### 性能优化技巧

#### 1. 条件优化顺序
将最容易失败的条件放在前面，实现快速短路。

```elisp
;; 好的做法：快速失败的条件在前
(supertag-automation-create
 '(:name "high-priority-task-alert"
   :trigger :on-property-change
   :condition (and 
               (property-equals :priority "Critical")  ; 最具选择性的条件
               (has-tag "task")                        ; 标签检查
               (not (property-equals :status "Done"))  ; 状态检查
               (property-test :hours #'> 8))  ; 数值测试放最后
   :actions '((:action :call-function :params (:function #'send-urgent-alert)))))
```

#### 2. 批量操作
对于需要处理大量数据的操作，使用批量处理模式。

```elisp
;; 好的做法：批量处理
(defun batch-update-project-status ()
  "批量更新项目状态。"
  (let ((projects-to-update (supertag-query-nodes
                            '(and (has-tag "project")
                                  (property-equals :all-tasks-done t)))))
    (supertag-with-transaction
      (dolist (project projects-to-update)
        (supertag-node-update-property (plist-get project :id) :status "Completed")))))

;; 避免的做法：逐个处理
(supertag-automation-create
 '(:name "update-each-project"
   :trigger :on-property-change
   :condition (and (has-tag "project") (property-equals :all-tasks-done t))
   :actions '((:action :update-property :params (:property :status :value "Completed")))))
```

### 数据建模最佳实践

#### 1. 合理的标签层次
设计清晰的标签层次结构，避免过度复杂的嵌套。

```elisp
;; 好的做法：清晰的层次
;; 基础标签：task, project, note
;; 状态标签：todo, doing, done, archived
;; 优先级标签：low, normal, high, critical

;; 避免的做法：过度复杂的嵌套
;; task-personal-work-high-priority-urgent-due-tomorrow
```

#### 2. 标准化的字段命名
使用一致的字段命名约定。

```elisp
;; 好的做法：标准化命名
;; 日期字段：created_date, due_date, completed_date
;; 状态字段：status, priority, progress
;; 关系字段：parent_id, assigned_to, depends_on

;; 避免的做法：不一致的命名
;; create_time, dueDate, finished_at, stat, prio, prog
```

### 维护和监控

#### 1. 定期健康检查
建立定期的系统健康检查机制。

```elisp
;; 每日健康检查
(supertag-automation-create
 '(:name "daily-health-check"
   :trigger :on-schedule
   :schedule (:type :daily :time "02:00")
   :actions '((:action :call-function :params (:function #'supertag-system-health-check)))))
```

#### 2. 监控规则执行
跟踪规则执行的性能和频率。

```elisp
;; 性能监控报告
(supertag-automation-create
 '(:name "weekly-performance-report"
   :trigger :on-schedule
   :schedule (:type :daily :time "09:00" :days-of-week '(1))  ; 每周一
   :actions '((:action :call-function :params (:function #'supertag-show-performance-report)))))
```

#### 3. 数据备份策略
定期备份重要的配置和数据。

```elisp
(defun backup-supertag-configuration ()
  "备份 Supertag 配置。"
  (interactive)
  (let ((backup-file (format "supertag-backup-%s.el" 
                            (format-time-string "%Y%m%d-%H%M%S"))))
    (with-temp-file backup-file
      (insert ";; Supertag Configuration Backup\n")
      (insert ";; Generated: " (current-time-string) "\n\n")
      ;; 备份标签定义
      (insert "(setq supertag-tags-backup\n")
      (pp (supertag-query '(:tags)) (current-buffer))
      (insert ")\n\n")
      ;; 备份关系定义
      (insert "(setq supertag-relations-backup\n")
      (pp (supertag-query '(:relations)) (current-buffer))
      (insert ")\n\n")
      ;; 备份自动化规则
      (insert "(setq supertag-automation-rules-backup\n")
      (pp (supertag-automation-list) (current-buffer))
      (insert ")\n"))
    (message "Configuration backed up to %s" backup-file)))
```
