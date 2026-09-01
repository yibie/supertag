# Ontology Links v3

## 目标

这一版只完成一个边界：把“关系的定义”和“关系的事实”分开。

```text
Link Definition
  定义哪些类型可以相连，以及数量约束

Link Instance
  记录两个具体节点之间已经存在的连接
```

它没有引入第二套关系数据库，也没有把 Link Definition 塞进旧的
`:relations` 集合。

## 数据模型

### Link Definition

持久化在：

```elisp
:link-definitions
```

核心属性：

```elisp
(:id "linkdef-..."
 :name "Tasks"
 :from-tag-id "tag-project"
 :to-tag-id "tag-task"
 :from-cardinality :many
 :to-cardinality :one
 :inverse-name "Project"
 :managed-by :ontology)
```

含义：

- source 节点必须是 Project，或 Project 的子类型；
- target 节点必须是 Task，或 Task 的子类型；
- 一个 Project 可以连接多个 Task；
- 一个 Task 最多只能被一个 Project 通过该定义连接。

### Link Instance

仍然持久化在：

```elisp
:relations
```

实例形状：

```elisp
(:id "rel-..."
 :type :ontology-link
 :kind :semantic-edge
 :origin :semantic
 :link-definition-id "linkdef-..."
 :from "project-node-id"
 :to "task-node-id")
```

Link Definition ID 是实例身份的一部分。因此两个不同定义可以连接同一对
节点，而不会被错误地去重。

## Ontology-as-Code 声明

```elisp
(supertag-defontology work
  :version 1

  (type project
    :label "Project")

  (type task
    :label "Task")

  (link tasks
    :label "Tasks"
    :inverse-label "Project"
    :from project
    :to task
    :from-cardinality many
    :to-cardinality one))
```

加载声明只注册纯数据，不写 Store：

```elisp
(load "~/ontology/work.el")
```

预览并部署：

```text
M-x supertag-ontology-preview
M-x supertag-ontology-apply
```

Ontology 部署只创建或更新 Link Definition，不创建任何具体连接。

## 创建具体 Link

```elisp
(supertag-link-create
 "linkdef-runtime-id"
 "project-node-id"
 "task-node-id")
```

读取：

```elisp
(supertag-link-find "linkdef-runtime-id")
(supertag-link-targets "linkdef-runtime-id" "project-node-id")
(supertag-link-sources "linkdef-runtime-id" "task-node-id")
```

删除：

```elisp
(supertag-link-delete
 "linkdef-runtime-id"
 "project-node-id"
 "task-node-id")
```

## 不变量

1. Link Definition 只存在于 `:link-definitions`。
2. Link Instance 只存在于 `:relations`。
3. `:ontology-link` 实例必须引用一个存在的 Link Definition。
4. 两个端点必须满足 Link Definition 声明的类型。
5. 子类型节点可以满足父类型端点。
6. 创建实例时执行双端基数校验。
7. 有实例时，不能直接改变定义的端点类型或基数。
8. 有实例时，不能删除定义，除非明确级联删除。
9. 有 Link Definition 依赖时，不能直接删除端点 Tag。
10. Ontology 管理的定义不能被交互写入静默覆盖。
11. Stable Semantic Tag ID 迁移会在同一事务内改写 Link Definition 的
    source/target 类型引用。

## 当前边界

已实现：

- Link Definition 持久化；
- Ontology DSL 的 `(link ...)`；
- source/target 类型约束；
- 单继承下的子类型兼容；
- source/target 基数约束；
- 可选反向显示名称；
- Link 实例 CRUD；
- Relation 确定性身份；
- 删除与结构修改保护；
- View Data API 读取；
- 持久化与数据库往返；
- Stable Semantic Tag ID 迁移兼容；
- 23 个聚焦 ERT 测试源码。

未实现：

- Schema View 中的可视化 Link Definition 编辑器；
- 自动迁移已有非类型化 relation；
- 修改端点或收紧基数的 Migration DSL；
- Function、Action、Policy；
- 自动生成 LLM tools；
- 基于 Link 的高级 Query DSL。

## 验证说明

当前交付环境没有 Emacs 可执行文件，因此 ERT 测试已经编写，但没有在该
环境中运行。可以在本机项目根目录执行：

```bash
./tests/run-link-tests.sh
```

或：

```bash
emacs -Q --batch \
  -L . \
  -L tests \
  -l ert \
  -l tests/supertag-link-test.el \
  -f ert-run-tests-batch-and-exit
```
