# Supertag

> English: [README.md](README.md)

## V2 是怎么来的

我用 Emacs 和 Org。V1 里我给 Supertag 加了很多功能，每加一个，输入就多一层手续：先想这条笔记属于哪里，再决定标题、标签、要不要建节点。功能变多的同时，有一天我发现，自己开发系统的时间远远大于写笔记的时间，这跟初衷反过来了。

所以有了 V2。目标是一件事：提升记笔记时的愉悦感，让输入像按下了免打扰。

具体做法是取消 fields 和专用 supertag-capture。取消 fields，是因为定义、配置和维护的成本；结构化笔记本身没有问题。专用 capture 则让记录承担了太多填写。

`supertag-view-table` 也一起取消。它当时负责两件事，浏览某个标签下的节点，以及处理 fields 的值。浏览那部分由 `supertag-view-stream` 接手；处理 fields 的部分随 fields 取消，不再需要。

留下的是数据库那部分：搜索、关联发现和视图从它读取，不必反复直接扫描全部文件。Org properties 没有取消，它们仍是你源文件里的普通文本，已有属性和历史数据不会因此被删除。

## 流畅的输入

记录这一步现在用 Org 自己的 `M-x org-capture`。模板还是你的模板，先记下来，文件、标题、分类都可以晚点再想；Supertag 只在你需要时补上 ID 和标签。

我自己的差别在这儿：以前每记一条，我会先想它该进哪个文件、算什么类型、要不要现在建节点；现在先落下来，整理的时候再决定。两种方式都能工作，区别只是什么时候做决定，先分类再写，还是先写再整理。我更适合后者。

**自动补全。** 在 Org 正文里输入 `#`，会补全已有标签；继续输入一个新名字，也可以从 `[New]` 这一项直接创建。输入 `[[` 则会补全已有笔记的标题，也可以从补全列表新建一条笔记。完成之后，文件里留下的仍是普通的 `#tag` 或 Org ID 链接。

**嵌套标签。** 输入 `#emacs/package/elpa` 这样的路径，补全会按 `emacs › package › elpa` 建立层级。写回正文的是叶子标签 `#elpa`，父子关系由 Supertag 记录；之后查看 `emacs` 的 Stream 或执行包含子标签的查询，也会找到 `package` 和 `elpa` 下面的笔记。

有一点得说清楚：并非零初始配置。你的 `org-capture` 模板本身要指定目标文件；另外要在 init 里先写好同步目录再 `(require 'supertag)`，并跑一次首次扫描。这些做一次就够了，模板见 [doc/setup_cn.md](doc/setup_cn.md)。

关于「什么算一条笔记」：普通正文可以直接写，扫描不会替没有 ID 的标题创建 ID；只有带 Org ID（`:ID:` 属性）的标题才会进入节点。需要某个标题成为节点时，用 `M-x org-id-get-create` 手工补一个，或者让 org-capture 收尾时自动补（可选集成，同样见 [doc/setup_cn.md](doc/setup_cn.md)）。

## 方便的整理

整理发生在记录之后，而且随时可以停下。

**事后加标签。** `M-x supertag-add-tag` 给标题加 `#tag`，标签就是普通文本。

**把关键字转换成笔记。** 选中文字，或把光标放在标题上，执行 `M-x supertag-promote`，选一个模板关键词；它按对应模板新建节点或复用已有笔记，选区会被替换成普通 Org 链接。

promote 的定制是核心理念，配置只有两层：模板数据，以及把模板封成命令。

```emacs-lisp
(setq supertag-creation-templates
      '((:key "concept" :name "Concept"
         :target-file "~/Documents/notes/concepts.org"
         :tags ("concept"))))
;; supertag-define-promote-command 是宏，要写在 (require 'supertag) 之后才会展开。
(supertag-define-promote-command my/supertag-promote-concept "concept")
;; 之后 M-x my/supertag-promote-concept 就是把选中内容提升为概念节点
```

**建立联系。** 打开 Node View（`M-x supertag-view-node`），里面有一段未链接提及，列的是词面候选：别的笔记正文里出现了当前节点的标题或别名，但还没写成链接。每个来源有三个动作，Link 换掉这一次出现，Link all 换掉这个来源里的所有出现，Ignore in node 让你不再看到它。这一段只对概念节点显示，也就是位于你模板配置的目标文件里、带持久 ID 的那些标题；普通笔记节点不会出现这一段。

如果需要，也可以直接通过 [[ 启动自动补全笔记标题来添加联系。

**顺带发现关联。** 可选装本地 Ollama 或兼容的嵌入服务，Node View 会列出语义相近的笔记，安装与隐私说明见后面的「可选：相似笔记」；`M-x supertag-mention-mode` 在正文里把已知概念的标题和别名标出来，只提示，不写链接。真要挪动笔记时，用 `M-x supertag-move-node`。

## 恰到好处的回顾

`M-x supertag-view-stream` 按标签（含子标签）把节点排开，适合顺着一个主题重读。

`M-x supertag-discovery` 则是随机翻出一批笔记的完整正文；想找某个话题时按 `s` 搜全库，看中的引用能插回出发的那条笔记。

回顾的时机由你决定，Supertag 不做复习安排。

## 先跑起来

```emacs-lisp
;; 用 straight.el 安装（这里假设你已经在用 straight）
(straight-use-package '(supertag :host github :repo "yibie/supertag"))
;; 在 require 之前设置：Supertag 加载时会给它装上 config guard。
(setq supertag-sync-directories '("~/Documents/notes/"))   ; 你放 Org 文件的目录
(require 'supertag)
```

要求 Emacs 29.1 与 Org 9.6 或更高（包元数据里写的下限）。

1. 在 init 里设置同步目录（在 `(require 'supertag)` 之前；文件级 ID 来源可选，随时可改），然后 `M-x supertag-sync-full-rescan` 一次；模板见 [doc/setup_cn.md](doc/setup_cn.md)。
2. `M-x supertag-menu`：按记录、整理、查找、维护分组的菜单，想不起命令名时从这儿找。

不需要 API key，也不用跑数据库服务器，你现有的 Org 文件直接用。

## 高级功能


### 可选：Git 备份与同步

可以用 Git 自动提交并推送同步目录里的 Org 文本，其他机器拉取后各自重建笔记；本地提交只是版本记录，不是远程备份。

数据库以及存在数据库里的规则、配置不随 Git 同步，要另留备份。第一台机器 `M-x supertag-git-setup` 建仓库，第二台 `M-x supertag-git-clone` 克隆并重建，之后用 `M-x supertag-git-sync-mode` 打开自动同步（不持久，重启后要再启用，或写进 init）；手动同步 `M-x supertag-git-sync-now`。完整机制与配置见 [doc/sync_cn.md](doc/sync_cn.md)。

### 相似笔记

可选功能，默认关闭。它需要本机有 curl、一个本地 Ollama 或兼容的嵌入服务，以及服务上已准备好嵌入模型（默认 `bge-m3`）。

```emacs-lisp
(setq supertag-semantic-endpoint "http://localhost:11434")
(setq supertag-semantic-model "bge-m3")
```

服务需兼容 `/api/embed`；`supertag-semantic-endpoint` 填根地址，不附加 `/api/embed`。

然后 `M-x supertag-semantic-rebuild`。它会先问你是否为以后的会话启用；同意后先探测服务和模型是否可用，探测成功才把这个选择写进配置——服务不通不会留下「已启用」。随后它在后台给节点建索引，Node View 里出现「相似」候选。`M-x supertag-semantic-status` 看进度，`M-x supertag-semantic-stop` 暂停，`M-x supertag-semantic-resume` 继续；换模型需要重建索引。

两点要留意。发送内容方面，每条发给服务的是标题、大纲路径和正文开头一小段（默认 1500 字符）；默认请求发往本机，把地址改成远程就等于把这些文本发到那台机器，用公用或第三方服务前先想清楚。行为边界方面，相似候选只是提示，不会自动建链接，也不会改写你的 Org 文件。

### Query

查询是一个 S-expression，可以写在 Org Babel 块、动态块里，也可以从 `M-x supertag-menu` 的查询入口执行。日常最常用的是按标签和 TODO 状态筛选：

```org
#+BEGIN_SRC supertag-query-block :results raw
(and (tag "task") (todo "TODO"))
#+END_SRC
```

条件之间用 `and`、`or`、`not` 组合，Org 属性用 `(property "KEY" "value")`。更完整的运算符和组合写法见 [doc/query_cn.md](doc/query_cn.md)。

### Automation

自动化由规则驱动，用现成模板建规则最省事：

1. `M-x supertag-automation-insert-template`，从列表里选一个模板；
2. 按提示填参数（例如哪个标签、设成什么值）；
3. 看预览，确认后创建。

想先看看有哪些模板，用 `M-x supertag-automation-list-templates`。

引擎默认在跑，但没有规则就不会改动文件；规则执行时会写回源 Org 文件。当前触发器、条件、动作和模板见 [doc/automation_cn.md](doc/automation_cn.md)。

## 命令清单

常用命令按用途分组。表里每一行都是可以直接 `M-x` 调用的命令（`org-capture` 是 Org 自带的）。

| 分组 | 命令 | 作用 |
|---|---|---|
| 记录与整理 | `org-capture` | Org 原生命令；按模板记录，配合 `:supertag t` 收尾可自动补 ID（见 [doc/setup_cn.md](doc/setup_cn.md)） |
| 记录与整理 | `supertag-menu` | 按任务分组的命令菜单，想不起命令名时从这里找 |
| 记录与整理 | `supertag-add-tag`、`supertag-remove-tag-from-node` | 给标题加标签、去标签 |
| 记录与整理 | `supertag-promote` | 把选中内容或光标所在标题按创建模板提升成节点 |
| 记录与整理 | `supertag-move-node`、`supertag-move-node-and-link` | 移动节点到其他文件；带 `-and-link` 的那个会在原处留下链接 |
| 记录与整理 | `supertag-add-link`、`supertag-find-node` | 插入节点链接；按标题查找并跳转节点 |
| 记录与整理 | `supertag-tag-rename`、`supertag-delete-tag-everywhere` | 重命名标签；在整库删除标签 |
| 查看与回顾 | `supertag-view-node` | 节点页：未链接提及、相似笔记等都在这里 |
| 查看与回顾 | `supertag-view-stream` | 按标签（含子标签）把节点排开 |
| 查看与回顾 | `supertag-discovery` | 随机翻出笔记；`s` 搜索全库，看中的引用能插回出发的笔记 |
| 查看与回顾 | `supertag-mention-mode` | 在正文里标出已知概念的标题与别名，只提示，不写链接 |
| 查询与自动化 | `supertag-add-query-block`、`supertag-query-build`、`supertag-query-describe-syntax` | 插入查询块；交互式拼查询；查看语法速查 |
| 查询与自动化 | `supertag-automation-insert-template`、`supertag-automation-list-templates` | 用模板建自动化规则；浏览模板（见 [doc/automation_cn.md](doc/automation_cn.md)） |
| 维护 | `supertag-sync-full-rescan` | 全量重扫；首次配置后跑一次 |
| 维护 | `supertag-semantic-rebuild`、`supertag-semantic-status`、`supertag-semantic-stop`、`supertag-semantic-resume` | 相似笔记（可选，默认关闭）：重建索引、看状态、暂停、继续 |
| 维护 | `supertag-migrate-status`、`supertag-migrate-preview` | 迁移状态报告；旧 fields 写回 Org 前的预览（见 [doc/migration_cn.md](doc/migration_cn.md)） |
| 维护 | `supertag-git-setup`、`supertag-git-clone`、`supertag-git-sync-mode`、`supertag-git-sync-now` | Git 备份与同步：建仓库 / 克隆并重建 / 开关自动同步 / 立即同步（见 [doc/sync_cn.md](doc/sync_cn.md)） |

## 自定义项清单 

下面是最常改的几项，默认值取自源码；完整清单按功能分组放在 [doc/customization_cn.md](doc/customization_cn.md)。

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-sync-directories` | `nil` | 要同步的目录；nil 表示还没设置，在 init 里于 `(require 'supertag)` 之前设置（向导已退役） |
| `supertag-file-id-source` | `'org-roam` | 文件级 ID 来源：`org-roam`、`denote`、`auto`、`disabled` |
| `supertag-sync-auto-interval` | `900` | 自动同步间隔（秒） |
| `supertag-sync-idle-delay` | `1.0` | 空闲多少秒后触发同步 |
| `supertag-db-backup-interval` | `86400` | 数据库每日备份间隔（秒）；保留天数见 `supertag-db-backup-keep-days` |
| `supertag-git-sync-commit-debounce` | `30` | Git 自动同步：停笔多少秒后提交；拉取间隔见 `supertag-git-sync-pull-interval` |
| `supertag-org-capture-auto-enable` | `nil` | org-capture 集成；默认关闭，需要时再开 |
| `supertag-creation-templates` | `nil` | 创建预设（Add Link、Find Node、Promote 共用）；nil 表示用内置 Concept 预设 |
| `supertag-view-style-color-by-name` | `t` | 行内标签按名字上色 |
| `supertag-view-node-side` | `'right` | Node View 侧窗在哪边 |
| `supertag-view-node-side-size` | `0.33` | Node View 侧窗宽度比例 |
| `supertag-discovery-initial-sample-size` | `10` | Discovery 随机显示的笔记条数 |
| `supertag-mention-max-results` | `300` | 未链接提及最多列多少个来源 |
| `supertag-semantic-enabled` | `nil` | 相似笔记开关；默认关闭，需要可用的嵌入服务 |


## 文档导航

- 初始配置：[doc/setup_cn.md](doc/setup_cn.md)
- 自动化规则：[doc/automation_cn.md](doc/automation_cn.md)
- 查询语法：[doc/query_cn.md](doc/query_cn.md)
- 同步与多机：[doc/sync_cn.md](doc/sync_cn.md)
- 迁移（包改名与 V1→V2 升级）：[doc/migration_cn.md](doc/migration_cn.md)
- 未链接提及的行为边界：[doc/mentions_cn.md](doc/mentions_cn.md)
- 自定义项（完整清单）：[doc/customization_cn.md](doc/customization_cn.md)
- 开发与测试：[test/README.md](test/README.md)
- 变更历史：[CHANGELOG.org](CHANGELOG.org)
- 历史文档与设计记录：[archive/docs/README.md](archive/docs/README.md)
