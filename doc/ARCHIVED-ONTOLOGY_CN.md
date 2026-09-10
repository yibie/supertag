> 本体/Policy 已封存，仅作历史参考。

## Ontology Policy

每个已部署 Action 现在必须由一个 fail-closed Policy 管理，完整覆盖
`interactive-user`、`automation`、`llm`、`external`。决策只有 `allow`、
`deny`、`confirm`、`propose-only`。在 Org heading 或 Node View 中执行
`M-x supertag-action-run`；只允许提案的 LLM 应调用
`supertag-ontology-action-propose`，不能直接执行。完整边界见
[`ONTOLOGY-POLICY-V11.md`](ONTOLOGY-POLICY-V11.md)。

## Ontology LLM Tools

只有在 Ontology 源码中显式声明 `:llm-tool t` 的 Function 或 Action，才会
进入 LLM 工具目录。Function 始终只读；Action 再根据 `llm` Policy 决策：
`allow` 可以执行，`confirm` 需要独立的一次性确认能力，`propose-only` 只能
返回临时提案，`deny` 完全不进入目录。使用 `M-x supertag-ui-tool-list` 检查
当前目录，或用 `M-x supertag-ui-tool-copy-catalog-json` 复制中立 JSON。完整
边界见 [`ONTOLOGY-LLM-TOOL-V12.md`](ONTOLOGY-LLM-TOOL-V12.md)。

---

### 用代码声明 Ontology

当某个标签/字段模式稳定下来后，可以改用 Elisp 声明，而不是在 Schema View 里
手工维护：

```emacs-lisp
(supertag-defontology work
  :version 1
  (field status :label "Status" :type options :options (idea active blocked done))
  (type project :label "Project" :fields (status))
  (type task    :label "Task"    :fields (status))
  (link tasks :label "Tasks" :inverse-label "Project"
        :from project :to task :from-cardinality many :to-cardinality one))
```

加载文件只注册声明。`M-x supertag-ontology-preview` 会对照实时 Store 给出部署
计划，每个操作被标为 **SAFE**（新增字段、类型、Link，改 label）、
**BEHAVIORAL**（Function、Action、Policy——apply 时要求显式批准）或
**DESTRUCTIVE**（字段类型变更、删除选项、收紧基数——没有配套迁移时 apply 直接
拒绝）。`M-x supertag-ontology-apply` 在一个事务中部署；重复部署未变化的声明
不会产生任何操作。

已部署的 Type 同时响应声明里的 key 和 label：上面的模块部署后，`#project` 与
`#Project` 都绑定到 Project；在 `type` 表单上加 `:aliases (proj 项目)` 可以再增加
写法。你在 Schema View 里手工加的别名会被保留。

之后类型化 Link 会强制检查端点类型和基数（`Link Tasks permits only one source
for target node …`），查询可以沿 Link 遍历：
`(and (tag "Project") (link work/tasks (field "status" "blocked")))`。Node View
会列出节点的类型化 Link；再加上 `function`、`action`、`policy` 表单后，还会显示
可计算的 Functions 和可执行的 Actions。可从 `examples/personal-work-ontology.el`
起步；完整语法见 `ONTOLOGY-LINK-WORKFLOW-V5.md` 与
`ONTOLOGY-FUNCTION-ACTION-V10.md`。

### Ontology 迁移

普通 Ontology 部署只接受安全增加和兼容更新。Field 类型转换、移除 Type/Field
关联、收紧 Link 基数等破坏性变更，必须配套显式的 `supertag-defmigration` 声明。
加载迁移文件只注册纯声明；Preview 不写 Store；Apply 则在一个事务中完成数据
动作、Schema 部署、派生关系对账和 Store-owned 已执行账本。

Preview 还会标出会悄悄清空数据的转换：当 `transform-field` 回调把已有值映射成
`nil` 时，计划里会出现 `WARNING :transform-clears-value` 和 `cleared=N` 计数。
要有意删除某个值，请返回 `supertag-ontology-migration-drop`。

Migration DSL v1 刻意只支持 `transform-field`、`detach-field` 与 `tighten-link`。
每一个破坏性操作都必须被精确覆盖；Type/全局 Field 删除、父类型或 Link 端点
改变、runtime rebinding 仍然直接拒绝，不提供模糊的 force 开关。详见
`ONTOLOGY-MIGRATION-V8.md` 与 `examples/ontology-migration-v8-example.el`。

旧 Embed 与 virtual-column 实现现为封存组件：默认包不加载、不初始化、也不展示
其入口。兼容维护时可显式加载 `supertag-ui-embed` 或
`supertag-virtual-column`，从而使用封存 UI；自动 Embed 保存 hook 还需显式加载并
初始化 `supertag-services-embed`。文档抽取仍会排除生成的 Embed 内容。

