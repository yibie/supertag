# Supertag 查询指南

> English: [query.md](query.md)

查询是 S-expression，Org 里的两种块和 Lisp 入口共用同一套解析与执行：

- **Babel 代码块** `supertag-query-block`：手动执行，结果落进 Org 表格；
- **动态块** `supertag-query`：可刷新，运行 Org 刷新命令时重算（不会随数据变化自动更新）；
- `M-x supertag-query-build` 引导拼查询，`M-x supertag-query-describe-syntax` 看速查。

Lisp 入口：

```elisp
(supertag-query-node-ids QUERY)   ; 匹配的节点 ID 列表
(supertag-query-evaluate QUERY)   ; 含聚合修饰符的完整结果
(supertag-query-validate QUERY)   ; 只校验语法
```

## 写在 Org 里

### Babel 块（手动执行）

```org
#+BEGIN_SRC supertag-query-block :results raw
(and (tag "task") (todo "TODO"))
#+END_SRC
```

`M-x supertag-add-query-block` 先询问查询表达式，再插入一个 `#+BEGIN_SRC supertag-query-block :results raw` 模板。光标在块上按 `C-c C-c` 执行；
`supertag-query-block` 是唯一注册的查询块语言，`:results raw` 是该语言的默认值，
写不写都行。执行器随 Supertag 一起加载，不需要把它加进 `org-babel-load-languages`。

### 动态块（可刷新）

```org
#+BEGIN: supertag-query :query "(and (tag \"project\") (after \"-30d\"))" :sort modified :order desc :limit 20 :columns ("status" "priority")
#+END:
```

动态块没有 `#+RESULTS:` 容器，结果直接写在块内；它不会自己更新，只有你运行刷新命令时才
重算：块上的 `C-c C-c`、`org-dblock-update` 或 `org-update-all-dblocks`。

两者的区别：Babel 块由你手动执行、结果存到 `#+RESULTS:`；动态块由 Org 的刷新命令重算、
正文即结果。两种都接受同样的可选参数：

| 参数 | 说明 |
|---|---|
| `:sort` | `title`、`created`、`modified` 或属性名 |
| `:order` | `asc`（默认）或 `desc` |
| `:limit` | 正整数，排序后截断 |
| `:columns` | 显式属性列，覆盖自动推导的列 |

坏查询和坏参数不会打断 Org：块里渲染成一行 `Error: ...`。块里的日期支持
`<%today%>`、`<%yesterday%>`、`<%tomorrow%>` 变量。

## 结果长什么样

普通查询渲染成 Org 表格：`Node`（标题链接）和 `Tags` 两列固定，查询里
`(property ...)` 提到的属性各占一列；`:columns` 可以换成你指定的属性列。没有匹配时
写 `No results found.`。聚合查询只有一行 `Aggregate`；带 `group-by` 时是
`Group`/`Aggregate` 两列。

渲染出的链接属于生成内容：同步器不会把动态块正文和 `#+RESULTS:` 里的链接当作
文档链接。查询读的是**已同步进 Store 的属性**，未保存 buffer 里的改动还没投影，查不到。

## 布尔组合

```elisp
(and CONDITION...)   ; 交集
(or CONDITION...)    ; 并集
(not CONDITION...)   ; 排除这些条件的并集
```

```elisp
(and (tag "task")
     (not (property "status" "done")))
```

## 基本条件

| 条件 | 说明 |
|---|---|
| `(tag NAME)` | 带某标签的节点 |
| `(property KEY VALUE)` | Org 属性；键不区分大小写，值精确匹配。`field` 是旧的输入别名，新查询请用 `property` |
| `(term WORD)` | 在标题和正文里做不分大小写的子串匹配 |
| `(todo STATE...)` | 标题的 Org TODO 关键字；大小写敏感，多个任一匹配。`task` 是旧写法，仍可用 |
| `(priority PRIORITY...)` | 标题的优先级，多个任一匹配 |

`todo` 读的是标题状态，不是自定义属性；同理 `tag` 也不会当成同名属性。想查名为
`todo`、`tag` 的抽屉属性，写成 `(property "todo" "custom")`。

**未知的单字符串形式是属性简写**：

```elisp
(and (status "doing") (priority "A"))
;; (status "doing") 等于 (property "status" "doing")
```

简写恰好要求一个字符串参数；名字打错时得到的是空结果，而不是报错。内置算子优先于
简写——已知算子用错了参数数量或类型会直接报错。

## 日期条件

```elisp
(after DATE)  (before DATE)  (between START END)
(recent-days N)  (in-month "YYYY-MM")  (in-year "YYYY")
```

日期按节点的时间戳比较，接受绝对日期（`"2026-08-27"`、`"now"`）和相对写法
（`"-7d"`、`"+2w"`、`"-1m"`、`"1y"`）。

## 命名 Org 链接

Org 文本里的命名链接形如 `[[supports:target][说明]]`：`supports` 是关系名，`target` 是目标节点的 ID（不是标题）。查询这个关系用下面几个条件，`REL` 写关系名，字符串或符号都可以（如 `"supports"`、`work/tasks`）：

```elisp
(link REL TARGET-QUERY)          ; 有指向匹配 TARGET-QUERY 节点的命名链接的源节点
(exists-link REL TARGET-QUERY)   ; 与 link 同义
(reverse-link REL SOURCE-QUERY)  ; 被匹配 SOURCE-QUERY 的节点链接到的目标
(has-link REL)                   ; 至少有一条该关系的出链
(has-reverse-link REL)           ; 至少有一条该关系的入链
```

```elisp
(and (tag "project")
     (link work/tasks (property "status" "blocked")))
```

关系名不能为空。合法的遍历哪怕没有匹配，也只是返回空列表。

## 结果修饰符

修饰符写在 `and` 里面：

```elisp
(sort-by KEY [asc|desc])
(group-by KEY)
(sum KEY)  (count)  (avg KEY)  (min KEY)  (max KEY)
(first KEY)  (last KEY)  (unique-count KEY)  (concat KEY)
```

```elisp
(and (link work/tasks (tag "task"))
     (sort-by "modified" desc))
```

查询里的 `sort-by` 默认是 `desc`，与块头参数 `:order` 的默认 `asc` 不同；查询自带
`sort-by` 时以它为准，块头的 `:sort`/`:order` 让位。

普通列表查询用 `supertag-query-node-ids`；带聚合修饰符的查询用
`supertag-query-evaluate`（Babel 块和动态块会自动选）。

## 引导与速查

```text
M-x supertag-query-build
M-x supertag-query-describe-syntax
```

## 失败行为

- 已知算子的参数数量或类型不对：报错；
- 未知的单字符串形式：按属性简写处理，可能得到空结果；
- 其他形状（空算子、关键字算子、参数数量不对的简写）：报错；
- 合法查询没有匹配：空列表。

属性条件读的是 Store 里已同步的 Org 属性，不是未保存的文件内容。
