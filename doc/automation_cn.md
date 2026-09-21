# Supertag 自动化指南

> English: [automation.md](automation.md)

本文对应当前 `supertag-automation.el` 的行为。

## 模型

一条规则是三段数据，存在数据库的 `:automations` 集合里：

- **触发器（WHEN）**：什么时候跑；
- **条件（IF）**：这一次要不要跑，可以不写；
- **动作（THEN）**：按顺序做些什么。

引擎随着 Supertag 一起启动，但没有规则时它不会碰任何文件。事件规则随 Store
变更（同步进来的改动）触发，定时规则由调度器触发；动作可能写回源 Org 文件
（`:call-function` 里做什么由你决定）。一次动作执行期间不会再触发规则（有递归保护）。

## 用模板向导建规则（推荐）

1. `M-x supertag-automation-insert-template`；
2. 从列表里选一个模板，每个模板有一句说明；
3. 按提示逐项填参数：标签、TODO 关键字用补全，文件用文件名补全，其余直接输入；
4. 预览缓冲区里会显示将要创建的规则 plist，`y` 确认后才真正创建。

想先浏览有哪些模板，用 `M-x supertag-automation-list-templates`；`M-x supertag-menu`
里也有入口。规则名决定存储 ID（`auto-<规则名>`）：同名会替换已有规则，
向导遇到同名时会先问你是否继续。

当前模板（9 个）：

| 模板 | 触发 | 作用 |
|---|---|---|
| Tag added -> set TODO state | 加上某标签 | 把节点的 TODO 设为指定关键字（如加 `#done` 置为 DONE） |
| Tag added -> set a property | 加上某标签 | 把某属性设为固定值（如加 `#urgent` 设 PRIORITY=A） |
| Tag added -> add another tag | 加上某标签 | 再补一个标签（蕴含关系，如 `#bug` 蕴含 `#needs-triage`） |
| Tag removed -> remove a derived tag | 移除某标签 | 连带移除一个派生标签 |
| Property change -> update another property | 指定标签下的属性变化 | 把该节点另一个属性设为固定值 |
| Property equals value -> move node to file | 属性变化 | 属性等于某值时把节点移动到目标文件 |
| Property equals value -> add tag | 属性变化 | 属性等于某值时加一个标签 |
| Scheduled daily -> set property on tagged nodes | 每天定时 | 给带某标签的所有节点设一个属性 |
| Tag added -> create follow-up node | 加上某标签 | 新建一个标题、标签给定的节点（不会回链源节点） |

## 触发器、条件、动作

**触发器**（`:trigger`）：

- `(:on-tag-added "tag")`、`(:on-tag-removed "tag")`；
- `:on-property-change`——属性变化时；
- `:on-change`、`:always`——任意 Store 变更时；
- `:on-schedule`——定时，见下节；
- `:manual`——保留字，当前没有触发入口，实际不会自动跑。

**条件**（`:condition`，可选）：不写或写 `t` 就是无条件执行。它和查询块共用
S-expression，比如 `(property "STATUS" "ready")`、`(term "emacs")`、
`(recent-days 7)` 都可以直接写；旧写法也认：`(has-tag "task")`、
`(property-equals :status "ready")`、`(property-changed :status)`（后一种只在
`:on-property-change` 下有变化可查）、`(property-test :status #'string= "ready")`。
多个条件用 `and`、`or`、`not` 组合。查询运算符全集见 [query_cn.md](query_cn.md)。

**动作**（`:actions`，列表，顺序执行）：

| 动作 | 参数 | 说明 |
|---|---|---|
| `:update-property` | `:property` `:value` | 写 Org 属性并刷新投影 |
| `:update-todo-state` | `:state` | 设置 TODO 关键字 |
| `:add-tag` | `:tag` | 加标签，必要时先建立标签 |
| `:remove-tag` | `:tag` | 移除标签；标签无法解析时跳过并记日志 |
| `:create-node` | `:title` `:target-file`，可选 `:tags` | 新建节点 |
| `:move-node` | `:target-file`，可选 `:leave-link` `:target-level` | 移动节点；已在目标文件时跳过 |
| `:call-function` | `:function`，可选 `:args` | 函数收到 node-id、context 和 `:args` |
| `:case` | `:on` + `:branches` | 分支动作，见下 |

`:case` 的每个分支用 `:equals`／`:in`／`:match`／`:test` 之一匹配，`:actions`
放该分支的动作（`:do`、`:then` 是别名），另可给一个 `:default` 分支。分支
是一小段程序而不是几个标量参数，模板向导不生成它，需要时手写。

## 定时规则

用向导里的「Scheduled daily -> set property on tagged nodes」模板最省事：每天
在指定时间给带某标签的节点设一个属性。`:schedule` 目前只认 `:time "HH:MM"`
（24 小时制），可选 `:days-of-week`（1 到 7，周一为 1）。

要注意的是，注册时只挑出 `:call-function` 动作执行：定时规则里写别类动作不会跑
（`:call-function` 收到的 node-id 是 nil，context 里带 `:scheduled t`）。调度器随
Supertag 启动，默认每 300 秒检查一次（`supertag-scheduler-check-interval`）；上次
运行日期存在数据目录的 `scheduler-state.json`，所以一天不会重复跑，但 Emacs 关闭
期间错过的那天不会补跑。

## 手写一条规则

模板覆盖不到时就自己传 plist 给 `supertag-automation-create`。下面这条把
「URGENT 属性被设为 yes」变成「PRIORITY 设为 A」，在 `M-x ielm` 里求值一次：

```emacs-lisp
(setq my/urgent-rule
      (supertag-automation-create
       '(:name "urgent sets priority A"
         :trigger :on-property-change
         :condition (property-equals :urgent "yes")
         :actions ((:action :update-property
                    :params (:property :priority :value "A"))))))
```

规则存在数据库里，建一次就够，不需要每次启动重新创建。查看、停用、删除都用
Lisp 函数：

```emacs-lisp
(plist-get my/urgent-rule :id)                        ; 存储 ID
(supertag-automation-get-by-name "urgent sets priority A")
(supertag-automation-update (plist-get my/urgent-rule :id)
                            (lambda (rule) (plist-put rule :enabled nil)))
(supertag-automation-delete (plist-get my/urgent-rule :id))
```

`(supertag-automation-list)` 列出全部规则（可传筛选函数），每一项就是规则的完整
plist；把 `:enabled` 设为 `nil` 就不再执行。调试时打开 `supertag-automation-verbose`
（默认关闭）会输出规则匹配与执行的日志；规则每次写文件都走 Org 服务，出错会显示
在 `*Messages*`。
