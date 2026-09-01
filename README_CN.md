# Supertag – 在 Emacs 里，把你的 Org 文件变成结构化知识库

[中文](./README_CN.md) | [English](./README.md)

Supertag 把普通的 Org 标题变成一个**可结构化查询的知识库**。不依赖外部服务，不需要 Python，你的 `.org` 文件始终是纯文本——我们只是让它变聪明了。

> **从 Org-Supertag 升级？** 6.0 是不保留兼容别名、也不自动搬迁数据的
> 破坏性改名。启动前请先阅读 **[迁移到 Supertag](doc/MIGRATING-TO-SUPERTAG.md)**。

> **⚠️ 数据库仍在使用旧的 Tag 嵌套字段？**
> 用当前版本编辑字段前，请**先完成全局字段迁移**。全局字段模型现已强制启用；`supertag-use-global-fields` 已废弃，设置它不会改变读写路径。
> 具体步骤见 [`doc/GLOBAL-FIELD-MIGRATION-GUIDE_CN.md`](doc/GLOBAL-FIELD-MIGRATION-GUIDE_CN.md)。

> **为什么这很重要**：你有没有试过"找出所有还没读的论文"？或者"@小王负责的、本周到期的任务"？纯 Org-mode 做不到，除非你手动维护 PROPERTIES 抽屉再 grep。Supertag 让这件事变成点几下鼠标。

> **📖 准备开始？** 先读 **[Supertag 的一天](doc/A-DAY-WITH-SUPERTAG_CN.org)**——一个人的完整日常工作流，所有 Elisp 配置都可以 copy-paste，用 `C-c C-v C-t` 提取到你的配置里。(English: [A Day with Supertag](doc/A-DAY-WITH-SUPERTAG.org))

---

## 跟纯 Org-mode 比，到底方便在哪

| 没有 Supertag | 有 Supertag |
|---|---|
| 每个字段都要手写 `:PROPERTIES:` 抽屉 | 打一次 `#tag`，定义一次字段，之后在表格视图里填 |
| `grep` + 正则找"高优先级本周任务" | `M-x supertag-search`，结构化查询，秒出结果 |
| 不同笔记之间靠复制粘贴关联 | 输入 `[[` 后补全，只写一条正向 Org link，并显示上下文 Backlink |
| 每开一个新项目都要从零搭跟踪系统 | 定义一次 `#project` 的字段模板，终身复用 |
| "那个会议记录到底写在哪了？" | 按日期、参与人、决议查 `#meeting` |

**核心理念**：你继续像往常一样写 Org 文件。Supertag 在后台读取它们，构建结构化索引，然后给你一个"类数据库"的视图层——建立在你的纯文本之上。

---

## 安装与首次运行

```emacs-lisp
;; 用 straight.el 安装
(straight-use-package '(supertag :host github :repo "yibie/supertag"))
(require 'supertag)
```

然后在 Emacs 里：

1. **`M-x supertag-setup`** —— 引导式配置向导。它会报告当前状态，让你选择要同步的目录、选择 file-ID 来源（Org-roam、Denote 或两者都要）、设置持久化选项，并可选地执行首次扫描。
2. **`M-x supertag-menu`** —— 按「记录、整理、查找、维护」组织的任务菜单。用它来发现命令，而不是死记硬背。
3. **`M-x supertag-doctor`** —— 任何时候感觉不对劲都可以跑一下。它是一次完整的健康检查，并会引导你修复问题。

就这些。不需要 API key，不需要运行数据库服务器。**你现有的 Org 文件直接就能用。**

---

## 记住这一个命令就够了

**`M-x supertag-menu`** 按四类任务组织入口：**记录 Capture & Write**、**整理 Organize**、**查找 Find & View**、**维护 Maintain**。日常命令留在首屏，自动化、迁移、查询和显示等低频命令收进对应的 `More...` 二级菜单。这篇 README 如果你只记住一件事，记住它就够了。

最省事的快捷键方案是内置的全局 minor mode：

```emacs-lisp
(supertag-act-mode 1)  ; C-c s → 默认动作，C-c S → 上下文动作菜单
```

也可以用 `global-set-key` 把菜单绑到任何你喜欢的键上。

---

## File-node：兼容 Org-roam、Denote 或混合目录

这个设置只影响文件级节点；标题节点仍然照常使用 Org ID。

```emacs-lisp
;; 默认：识别文件开头的 :ID:（Org-roam 风格）
(setq supertag-file-id-source 'org-roam)

;; 识别 #+IDENTIFIER:（Denote 风格）
(setq supertag-file-id-source 'denote)

;; 混合目录：逐个文件自动识别两种格式
(setq supertag-file-id-source 'auto)

;; 完全不创建文件级节点
(setq supertag-file-id-source 'disabled)
```

Org-roam 与 Denote 文件放在同一同步目录时，使用 `auto`。链接由每个节点自己的身份决定：Org-ID 节点使用 `id:`，Denote 文件节点使用 `denote:`。文件没有所选的持久化身份时，它仍是普通 Org 文件；SuperTag 不会为它生成临时 ID。

修改设置后，执行 `M-x supertag-reindex-org`。

---

## 三个核心概念（2 分钟搞懂）

Supertag 只建立在三个简单想法上：

### 1. `#tag` 把标题变成一条记录

```org
* Attention Is All You Need #paper
```

`#paper` 标签的意思是"这个标题属于 'paper' 这个集合"。就像你在任何系统里打标签一样——只不过这个标签有超能力。

### 2. 标签可以定义字段（就像数据库的列）

`#paper` 这个标签打好之后，你就可以定义要追踪什么信息：

```
authors  →  文本
year     →  数字
venue    →  文本
status   →  选择（未读 / 阅读中/ 已读）
rating   →  数字（1–5）
```

这些字段**每个标签只需要定义一次**（在 Schema View 里，`M-x supertag-view-schema`）。之后，每一个打上 `#paper` 的节点自动拥有这些字段。

### 3. 视图让你浏览、填写、查询数据

- **表格视图** (`M-x supertag-view-table`)：像一个针对你标签节点的电子表格。点列头排序，过滤，批量编辑。
- **节点视图** (`M-x supertag-view-node`)：编辑单个节点的字段，带自动补全和校验。
- **看板视图** (`M-x supertag-view-kanban`)：拖拽式的看板，适合 `#task`、`#project`。
- **Stream View** (`M-x supertag-view-stream`)：把一个标签及其所有传递 `:extends` 后代节点显示为单列时间标题流。用 `n`/`p` 移动，按 `e` 打开完整源节点，按 `v` 进入 Node View 修改字段。

---

## 一步一步：你的第一个 5 分钟

假设你是一个研究者，论文散落在各种笔记里。

### 第一步：给论文打标签

光标移到任意 Org 标题，`M-x supertag-add-tag`，输入 `paper`：

```org
* Attention Is All You Need #paper
```

### 第二步：定义"论文"要追踪什么

`M-x supertag-view-schema` → 找到 `paper` → 添加字段：

| 字段 | 类型 |
|------|------|
| `authors` | 文本 |
| `year` | 数字 |
| `status` | 选择：未读、阅读中、已读 |
| `rating` | 数字 1–5 |

### 第三步：填数据

`M-x supertag-view-table` → 选择标签 `paper`。你会看到一张包含所有 `#paper` 节点的表格。点任意单元格即可编辑。按 `year` 排序找最新论文。按 `status = 未读` 过滤看阅读队列。

### 第四步：给更多论文打标签

找到其他论文标题，加上 `#paper`。它们会自动出现在表格里。

**搞定。你现在有了一个可查询的研究文献库。** 整个过程没有手写 PROPERTIES 抽屉，没有复制粘贴，没有手动整理。

---

## 真实工作流（附可复制的命令）

### 📚 学术阅读队列

```org
* Diffusion Models Survey #paper
* ViT Explained #paper
* CLIP Paper #paper
```

在 `#paper` 上定义字段：`authors`、`year`、`status`（未读/阅读中/已读）、`rating`。

**日常使用**：
1. `M-x supertag-view-table` → 选 `paper` → 按 `status` 排序
2. 过滤到 `未读` → 挑一篇 → 按 `o` 跳转到标题
3. 读完：点 `status` 格 → 选 `已读` → 打分

**为什么方便**：你按状态和评分找论文，而不是在 50 个标题里来回翻、逐个读标题。

### 📋 项目任务跟踪

```org
* 重写同步层 #task #project
* 修复认证 bug #task
* 部署 v2.1 #task
```

在 `#task` 上定义字段：`status`、`priority`、`due`、`assignee`。

**日常使用**：
1. `M-x supertag-view-kanban` → 选 `task` → 按 `status` 分列
2. 拖拽任务在不同列之间推进
3. `M-x supertag-search` → `(and (tag "task") (field "priority" "high"))` 找紧急项

**为什么方便**：你的任务分散在不同的 Org 文件里（会议记录、项目文件），但在一个看板上你看到全部。

### 📝 会议记录与决议追踪

```org
* 2024-11-15 迭代规划 #meeting
```

在 `#meeting` 上定义字段：`date`、`participants`、`decisions`、`action-items`。

**日常使用**：
1. `M-x supertag-capture` → 选 `meeting` 模板 → 填字段
2. 之后：`M-x supertag-search` → `(tag "meeting")` → 按日期范围过滤
3. "Q4 所有决议" 几秒找到

**为什么方便**：会议记录在它们的自然位置（项目文件里），但你跨所有文件统一查询。

---

## 每天都会用的命令

| 你想做什么 | 命令 | 效果 |
|---|---|---|
| 打标签 | `M-x supertag-add-tag` | 添加 `#tag` 到标题，节点自动出现在该标签的表格里 |
| 看一个标签的所有节点 | `M-x supertag-view-table` | 电子表格视图。可排序、过滤、直接编辑单元格 |
| 按时间浏览一个标签 | `M-x supertag-view-stream` | 单列标题流，包含传递 `:extends` 后代；按 `e` 打开完整源节点 |
| 编辑单个节点的字段 | `M-x supertag-view-node` | 表单视图，带自动补全、选择器和校验 |
| 一次填完节点字段 | `M-x supertag-edit-fields` | 依次询问一个 Tag 的全部字段，最后把改动一起提交 |
| 看板视图 | `M-x supertag-view-kanban` | 拖拽式看板，列之间移动 |
| 定义标签字段 | `M-x supertag-view-schema` | 增删字段、设置类型、配置继承关系 |
| 定义类型化关系 | Schema View 中按 `a l` | 声明 source/target Type、正反向名称与基数 |
| 连接类型化节点 | `M-x supertag-link-menu` | 只显示并创建符合当前节点 Type 的关系 |
| 用代码声明 Type、Field、Link | 在 Elisp 文件中写 `supertag-defontology`，然后 `M-x supertag-ontology-preview` / `M-x supertag-ontology-apply` | 加载只注册声明；preview 把每个变更标为 SAFE / BEHAVIORAL / DESTRUCTIVE；apply 在一个事务中部署 |
| 对节点执行 Action | `M-x supertag-action-run`（或在 Node View 按 `A`） | 先显示计划效果（`set-field status = "active" -> "done"`），再按该 Action 的 Policy 执行 |
| 合并重复标签 | Schema View 中用 `m m` 标记，再按 `m M` | 预览后合并到新/已有 tag；原子更新字段、节点、引用和 Org 文件 |
| 快速捕获新节点 | `M-x supertag-capture` | 模板化快速录入，自动写入 Org 文件 |
| 搜索 | `M-x supertag-search` | 结构化查询，结果可导出到文件 |
| 关联节点 | 输入 `[[` 后补全，或执行 `M-x supertag-reference-insert` | 复用已有节点或显式创建 concept，只写 source 的正向 Org link，target Backlink 自动派生 |
| 处理未链接提及 | 打开 Node View，使用 **Unlinked Mentions** | 将普通文字中的 title/alias 提及作为临时候选；可链接一次、链接来源节点内全部，或在该来源节点忽略 |
| 预览 Ontology 迁移 | `M-x supertag-ontology-migration-preview` | 将迁移声明与实时破坏性 Schema diff 对照，在写入前列出所有数据动作 |
| 执行 Ontology 迁移 | `M-x supertag-ontology-migration-apply` | 在一个事务中转换数据、部署破坏性 Schema、重建派生关系并写入已执行账本 |
| 将选中文本提升为概念 | `M-x supertag-promote-concept` | 创建/复用概念节点，从当前节点建立 reference，原文保持普通文本 |
| 确认 Agent 填写的字段值 | 在 Node View 按 `c` | 值不变，来源记为 human，⟨AI⟩ 角标消失 |
| 高亮概念提及 | `M-x supertag-concept-link-mode` | 将概念 title/alias 的提及显示为琥珀色语义高亮，不落库为链接 |
| 操作光标下的对象 | `M-x supertag-act` | 列出适用于当前 tag、node、field、mention、选区、link、button 或 table cell 的动作，默认动作排第一 |
| 直接执行默认动作 | `M-x supertag-act-dwim` | 不弹菜单，立即执行光标处对象的默认动作 |
| 重建 Org 索引 | `M-x supertag-reindex-org` | 从一个完整快照重建 Document Projection；绝不恢复 Semantic Facts |

除了单条命令，Supertag 还提供一套小巧的 S-expression 查询语言，可以组合标签、字段、日期、全文搜索和类型化 Link 遍历，例如
`(and (tag "task") (not (field "status" "done")))`，或 `(link work/tasks (field "status" "blocked"))`。可以把它写进 `supertag-query-block`
babel 代码块，用 `M-x supertag-query-save` 保存以便复用，或者用 `M-x supertag-query-build`
交互式构建。完整语法见 `doc/QUERY.md`（英文）。

可选快捷键示例：

```emacs-lisp
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c n l") #'supertag-reference-insert)
  (define-key org-mode-map (kbd "C-c n p") #'supertag-promote-concept)
  (define-key org-mode-map (kbd "C-c n o") #'supertag-concept-open-at-point))
```

### Create-or-link 与上下文 Backlink

在普通 Org 正文中输入 `[[`，即可补全已有节点的 title 或 alias。没有精确
匹配时，补全列表才会出现显式的 `[Create new concept]` 项；仅仅输入文字不会
创建数据。选中后，临时写法会被替换为规范的物理 Org link，再由既有文档投影
流程生成 Backlink。系统不会向 target 文件写入一条反向链接。

中文等全角输入法可以直接输入 `【【` 代替 `[[`：两种写法触发同一套补全，
输入法自动配对出来的 `】】` 会在写入链接时一并消掉。可识别的括号对由
`supertag-reference-shorthand-openers` 决定，可以自行追加。

`M-x supertag-reference-insert` 提供不依赖弹窗的同一流程；存在选区时，选中文本
会作为初始标题。新 concept 默认追加到当前 vault 或匹配 sync root 下的
`concepts.org`，不再询问文件和位置；使用前缀参数可以显式选择目标，也可以
自定义 `supertag-concept-create-target-function` 接入 Org-roam、Denote 或其他
capture 系统。

Node View 现在分别显示当前节点的 **References** 与 **Backlinks**。每个条目都带
可跳转标题、文件与 outline path、关系类型，以及围绕 title/alias 提取的正文
片段。它们只是由现有 Store 数据即时生成的 Projection，不是第二套引用索引。

### 未链接提及（Unlinked Mentions）

Node View 还会在其他来源节点的普通正文中查找当前节点的 title 与 alias。未链接
提及只是候选，不会落库；只有用户执行 **Link** 或 **Link all in node** 后，才会
写成规范 Org ID Link，并沿既有投影流程成为 Backlink。已有 Org Link 与 literal/code
区域不会重复匹配；中文匹配也不会套用错误的 ASCII 词边界。

**Ignore in node** 会把 `SUPERTAG_IGNORE_MENTIONS` 写到来源 heading，因此忽略决定是
可检查、可同步的 Org 数据，而不是隐藏缓存。发现过程只使用小型、不可持久化的
解析缓存。完整边界见 `UNLINKED-MENTIONS.md`。

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

本阶段不会再实现一套 Transclusion。现有嵌入能力继续由
`supertag-ops-embed.el`、`supertag-services-embed.el` 与
`supertag-ui-embed.el` 统一拥有。

### Agent 填写的字段值与纯数据 API

设计字段的价值，在于有别人替你填。当 Agent（例如 superchat 通过它的 Supertag
桥接）写入一个字段时，值本身和手填的值存在同一个地方，旁边多一条**来源
（provenance）**记录：谁断言的（`:agent` 或 `:human`）、什么时候、用的哪个模型、
以及当时节点正文的 `:hash`。Node View 会给这类值加上 **⟨AI⟩** 角标；如果之后节点
正文改过，角标变成 **⟨AI · outdated⟩**；Table View 的单元格则标记 ⟨AI⟩ / ⟨AI?⟩。
在 Node View 的字段上按 `c` 即可确认：值不变，来源升级为 `:human`，角标消失。
你在 Node View、Table View 或看板里亲手编辑的值会记为 human；sync、automation
或旧代码写入的值没有来源记录，视为普通事实。

Agent 一侧通过 `supertag-api.el` 里的六个纯数据函数和 Supertag 对话：
`supertag-api-query`、`supertag-api-node`、`supertag-api-schema` 负责读；
`supertag-api-set-field`、`supertag-api-link`、`supertag-api-add-field` 负责写。
参数与返回值都是普通 Elisp 数据（字符串、数字、关键字、plist），
`supertag-api-json` 可把结果转成 JSON，`supertag-api-catalog` 声明每个函数的
效果（`:read` / `:write`）与参数，宿主据此把它们注册为 LLM 工具并套用自己的
授权模型。写操作走的是与 UI 相同的校验和事务；`set-field` 会把 Agent 的值绑定到
节点当前的 hash；`link` 只创建类型化 Link，不会伪造文档引用（那由 Org 正文拥有）。

```emacs-lisp
(supertag-api-set-field "node-id" "Status" "active" :model "claude-sonnet-5")
;; => (:node "node-id" :tag "project" :field "status" :name "Status"
;;     :value "active" :previous nil :changed t
;;     :provenance (:origin :agent :at "…" :model "claude-sonnet-5" :source-hash "…"))
```

### Concept mention 的行为边界

- Promote 只接受 Org node 内的非空文本。它会复用唯一的同名标题节点或创建新节点，建立一条显式 reference，并保持选区原文不变；同名 file-node 不会被静默转换为 concept。
- Mention 只存在于显示层。Org link、code/verbatim、普通注释与 `COMMENT` 子树、keyword/drawer、source block 和表格都不会高亮。
- 多个 concept 共用 title 或 alias 时，该词存在歧义。SuperTag 不会根据 hash table 顺序任意选择目标；文本保持普通显示，promote 会明确报告冲突。

如果在 SuperTag 之外修改了 concept title 或 alias，请在已启用的 buffer 中执行 `M-x supertag-concept-refresh`。

### 光标处上下文动作

把光标放在 inline tag、node、field、concept mention、选区、Org link、Emacs button 或
table cell 上，执行 `M-x supertag-act` 即可从适用于该对象的动作中选择，默认动作排在第一位。
`M-x supertag-act-dwim` 则不弹菜单、立即执行默认动作。动作列表中始终保留完整
`supertag-menu` 的入口，光标下没有语义对象时也会直接回落到该菜单。安装了 Embark 的用户，
同样的对象也会成为 `embark-act` 的 target，执行动作时沿用最初检测到的完整对象。除非启用
`supertag-act-mode`，两个命令都不设置默认按键；启用后 `C-c s` 直接执行默认动作，`C-c S`
打开上下文动作菜单。完整命令目录仍通过 `M-x supertag-menu` 打开。

---

## 为什么不会增加负担

"结构化工具"最常见的担忧是：**"我会不会花更多时间在整理上，而不是真正工作？"**

Supertag 从三个层面避免这个问题：

### 1. 你的文件始终是纯 Org

你**永远不需要**通过 SuperTag 的视图来操作。正常写 Org。`#tag` 标记只是文本。如果你明天不用 SuperTag 了，你的文件是 100% 可读的 Org-mode——只不过多了一些 `#tag` 标记而已，丝毫不影响。

### 2. 字段定义一次，永久复用

你在 `#task` 上定义 `status`、`priority`、`due` 只需**一次**。之后每一个 `#task` 节点自动拥有这些字段。前期投入 30 秒，收益是永久性的。

### 3. 同步自动且安全

Supertag 按定时器读取你的文件（可通过 `doc/SYNC-CONFIGURATION.md` 配置）。只有显式命令和 View 才会写入 Org；sync 与 reindex 不修改 Org 文件。`M-x supertag-reindex-org` 只重建现有 Store 中的 Document Projection；不可重建的 Semantic Facts 必须从数据库备份或同步副本恢复。

### 算一笔账

**不用 SuperTag**——追踪论文：
- 手写 `:PROPERTIES:` 抽屉：`:authors:`、`:year:`、`:status:`
- 跨文件 `grep` `status.*unread`
- 不能排序，不能过滤，没有表格视图

**用 SuperTag**——追踪论文：
- 给标题加 `#paper`（每个 2 秒）
- Schema View 定义字段一次（30 秒）
- 表格视图：排序、过滤、编辑（即时）

**收益**：10 篇论文，省下约 5 分钟 PROPERTIES 打字时间，还白送一个实时更新的表格视图。100 篇论文，差距是小时级的。

---

## 进阶路线图

从简单开始，需要时再加能力：

| 当你熟悉了…… | 可以试试这个 |
|---|---|
| 标签和表格视图 | **自动化规则**——条件触发自动填字段 (`doc/AUTOMATION-SYSTEM-GUIDE_cn.md`) |
| 手动捕获 | **捕获模板**——预定义常用录入表单 (`doc/CAPTURE-GUIDE_cn.md`) |
| 基本查询 | **查询块**——在 Org 文件里嵌入动态查询结果 (`doc/ABOUT-QUERY-BLOCK_cn.md`) |
| 反复重建的标签/字段模式 | **用代码声明 Ontology**——一次声明 Type、Field 和类型化 Link，预览后部署 (`examples/personal-work-ontology.el`, `ONTOLOGY-LINK-WORKFLOW-V5.md`) |
| 已经稳定的 Ontology 模块 | **Ontology Migration DSL**——预览并安全执行破坏性模型升级 (`ONTOLOGY-MIGRATION-V8.md`) |
| 默认视图 | **自定义视图**——用原生按钮和可编辑字段构建声明式仪表盘 (`doc/VIEW_FRAMEWORK_DEV_GUIDE.md`) |
| 单资料库 | **多 Vault**——工作/个人分开管理 (`doc/SYNC-CONFIGURATION.md`) |
| 写插件 | **插件开发指南**——自定义抽取器和扩展 (`doc/SUPERTAG-PLUGIN-GUIDE_cn.md`) |

---

## 数据存在哪里

| 什么数据 | 存在哪 | 格式 |
|---|---|---|
| 你的 Org 文件 | 你配置的目录 | 纯 `.org` 文本 |
| 结构化字段值 | `~/.emacs.d/supertag/supertag-db.el` | Emacs Lisp 数据 |
| 同步状态 | `~/.emacs.d/supertag/sync-state.el` | 文件 mtime 和 hash |
| 每日备份 | `~/.emacs.d/supertag/backups/` | 带时间戳的数据库快照 |

**Org 文件拥有文档事实；数据库拥有语义事实。** 标题、正文、文档拓扑、Org properties、Tag Occurrence 和真实 Org link 属于文档；稳定 Tag identity、Schema、field value、Semantic Edge、Board、Automation 以及持久 Query/View 定义属于数据库。当前数据库也保存 Org 内容的可重建 Projection，但这些副本没有独立主权。

`M-x supertag-reindex-org` 会从一个完整 Org 快照重建 node、Tag Occurrence、Document Link 及其派生索引；快照不完整时，它会中止且不修改 Store。它不是 whole-database reset，也不是 Semantic Restore，无法恢复不可重建的 Semantic Facts。没有备份或同步副本时丢失 `supertag-db.el`，就会永久丢失不可重建数据。完整规则见[《数据主权宪章》](doc/OWNERSHIP-CONSTITUTION_cn.md)。

---

## 多机同步

多机同步 `supertag-db.el` 有两种办法：**git 原生同步**（推荐——它真正懂合并），或者把数据目录放进同步文件夹服务（配置更简单，但"最后写入者赢"）。

### git 原生同步（推荐）

**机器 1**（第一次配置时）：

```
M-x supertag-git-setup
```

这会把你的 vault 纳入 git 管理：如果还没有仓库就初始化一个；如果数据库还没有被纳入仓库内，就把它搬迁到 `<repo-root>/.supertag/supertag-db.el`；并为 `supertag-db.el` 配置一个语义合并驱动，让不同机器上的并发编辑按字段合并，而不是互相覆盖。随后它会提示输入远端 URL——给它一个（任何空的 git 远端都行：GitHub、自建服务器、NAS）它就会创建首次提交并推送；留空则暂时保持本地状态（完全有效、受支持的状态——等有远端了再重新运行这个命令）。

**机器 2**（以及之后的每一台机器）：

```
M-x supertag-git-clone
```

给它同一个远端 URL 和一个本地目录。它会 clone、为*这台机器*配置合并驱动，并加载数据库。如果数据库缺失或无法读取，它只能从 clone 下来的 Org 文件重建 Document Projection；Semantic Facts 必须从数据库备份或同步副本恢复。

**每个 clone 都必须自己跑一遍配置。** `merge.supertag-db.driver` 存在 `.git/config` 里，git 从不同步这个文件——所以机器 2 上 `supertag-git-clone` 配置驱动这一步不是可有可无的杂务，正是它让*这台*机器的合并变成语义合并，而不是退化成 git 默认的按行文本合并（退化后是什么样子见下面"冲突"一节）。

**可选的自动化：** `M-x supertag-git-sync-mode` 会开启一个后台循环，自动 debounce 提交你的改动、按定时器和焦点事件 fetch/merge、并推送——包括在联网恢复后一次性追赶断网期间积累的提交，不需要等一次新的编辑来触发。不开这个模式，手动 `git pull`/`git push`（或 `magit-pull`/`magit-push`）效果完全一样；这个模式只是便利层，不是正确性所在。

需要跳过 debounce 立即同步时，执行 `M-x supertag-git-sync-now`。模式开启后，正常的 `C-x C-c` 会检查尚未落盘的 Store、受管 working tree 改动、正在运行的 Git 操作，以及相对最近一次 fetch 的 ahead commit。没有本地改动时直接退出，即使远端 ahead 也不在退出时主动同步；有本地改动时选择同步，成功后 Emacs 自动退出，同步失败或期间又有新改动则保持打开。你也可以明确选择保留可恢复的 working tree/local commit 后退出。低层 `kill-emacs` 会按 Emacs 自身约定绕过这项正常退出查询。

**冲突。** 数据库自身的编辑在常见情况下——两侧改的是不同节点或字段——会自动合并。当**同一个**字段在两侧被改成不同的值，或者纯 `.org` 正文在两侧改了同一行，git 会把那个文件留在真实的、未解决的冲突状态：对 `supertag-db.el` 本身，它会拒绝加载直到冲突解决（报错信息会点名文件并指向这里）；对 `.org` 文件，同步扫描器会跳过导入任何仍带冲突标记的文件，而不是把垃圾内容导入进来。不管哪种情况，`M-x supertag-doctor`（"8. Git Sync" 一节）都会列出具体哪些还没解决——像处理其他 git 冲突一样，手工解决或用 `magit`/`git checkout --merge`。

**所有同步机器必须一起升级。** 6.0 起数据库文件采用新的磁盘格式（确定性、每实体一行——正是它让字段级 git 合并成为可能），只有 6.0+ 能读。一台还在 5.9.x 的机器拉取到 6.0 机器保存的数据库后，会*看起来*加载成功但库是空的——旧代码只读文件首行且不报错。它的保存守卫能防住实际数据丢失（空内存库拒绝覆盖非平凡文件），但在那台机器升级之前，一切看上去都"消失"了。所以：在任何一台机器用 6.0 保存之前，把共享这个 vault 的**每一台**机器都升级到 6.0+。升级本身自动完成（首次加载旧库时自动迁移，并在 `backups/` 留下 `supertag-db-premigrate-*` 与 `supertag-db-preformat6-*` 两类永不被自动清理的降级快照；想回退旧版，执行 `M-x supertag-restore`，从列表中选中对应快照、预览后确认恢复，然后立即退出 Emacs 并用旧版重新打开）。恢复命令会保留快照的旧格式；若另一 Emacs 实例持有数据库锁则拒绝覆盖，并先把当前状态（包括尚未落盘的修改）保存为唯一的 `backups/supertag-db-prerestore-*` 恢复点。`M-x supertag-doctor` 会报告当前磁盘格式与迁移快照数量。

### 同步文件夹服务（Dropbox / iCloud / Syncthing）

如果你不想用 git，也可以把 `~/.emacs.d/supertag/`（或你配置的 `supertag-db-file` 所在目录）放进 Dropbox / iCloud / Syncthing 之类的同步文件夹，让它跟着你在多台机器间走——请先了解其中的取舍：

**最安全的做法：同一时间只有一台机器在写。** `supertag-db.el` 是单个序列化文件。同步服务的工作方式是"整份文件复制，最后写入者赢"——它并不知道两个 Emacs 会话分别改动了文件的哪些部分，所以无法帮你合并。只要两台机器都保存过，后保存的会静默覆盖先保存的。可靠的做法是：**在机器 B 上开始编辑之前，先在机器 A 上彻底退出 Emacs（`C-x C-c`，而不是只关掉窗口）。**

即使你觉得自己在机器 A 上"只是看看，没有编辑"，这条建议依然成立：自动保存定时器（`supertag-db-auto-save-interval`，默认 300 秒）只要会话中有任何改动被标记为脏（dirty），就会在后台把数据库写入磁盘——所以一个开着的 Emacs 进程本身就是一个后台写入者，不管你有没有在主动敲键盘。

**5.9.0 的数据库锁并不能解决这个问题。** 从 5.9.0 起，Supertag 会对数据库文件加一个建议性的锁（`supertag-db-lock`），防止*同一台机器*上的两个 Emacs 实例互相踩踏。当前版本默认把本机锁放在 `temporary-file-directory/supertag-locks/`，不再把新锁写入网络/同步目录；它仍然只能保护"同机双开"，对跨机器场景没有意义。升级后，如果数据库旁还残留旧版本的 `.#supertag-db.el`，先确认没有旧版本 Emacs 正在使用该 vault，再删除这个陈旧锁文件即可。

**presence（在场）告警。** 为了至少给同步文件夹的用户一个提醒（这不是锁——同步服务动辄几分钟的传播延迟决定了它在物理上不可能是锁），Supertag 会在数据库文件旁边写一个很小的 `supertag-presence.json` 文件，记录"最后是哪台主机碰过它、什么时候"。当你加载数据库时，如果发现另一台主机大约在最近 5 分钟内（`supertag-presence-stale-seconds`）还活跃过，就会弹出一条醒目的告警，点名那台主机并说明风险。**看到告警后怎么办：** 如果你确定另一台机器已经退出 Emacs，可以放心继续——这条告警只出现一次，不会重复弹出，直到另一台主机再次声明 presence 为止。如果不确定，先去那台机器上退出 Emacs。随时可以用 `M-x supertag-doctor` 查看当前 presence 文件记录的主机、距今时长和判定结果（本机 / 异机活跃 / 异机过期）。将 `supertag-presence-enable` 设为 `nil` 可以完全关闭这个功能。

**不要同步 `sync-state.el` 和 `backups/`。** 这两者虽然和数据库放在同一个数据目录下，但都是本机专属的记录（`sync-state.el` 追踪的是*这台机器*文件系统的 mtime/hash；`backups/` 只是磁盘占用，没必要在多台机器间重复保留）。如果你的同步工具是整个数据目录一起同步，请在工具允许的范围内把这两个路径排除掉；就算被覆盖了，最坏结果也只是多做一次 Org reindex，不会丢数据。

这只是权宜之计，不是最终方案——真正的多机同步需要一个懂"合并"的传输层，而这正是上面的 git 原生同步做的事。如果你要的是多机并发编辑，请直接用它；同步文件夹服务能给你的，永远只是上面的单写者纪律。

---

## 从旧版本迁移

> **⚠️ 5.9.x → 6.0.0**：数据库文件格式已变更（见上文"多机同步"）——升级自动完成，但之后想降级需要恢复备份快照。用 `M-x supertag-restore` 选中并恢复升级前的快照，然后立即退出 Emacs 并用旧版重新打开。多机共享 vault 的用户必须所有机器一起升级。

> **⚠️ 旧嵌套字段 → 当前版本**：编辑字段前，请先完成[全局字段迁移](doc/GLOBAL-FIELD-MIGRATION-GUIDE_CN.md)。当前版本始终使用全局字段模型。

### 从 SuperTag 4.x 升级

```emacs-lisp
;; 1. 备份数据目录 (~/.emacs.d/supertag/)
;; 2. 加载并运行迁移
M-x load-file RET supertag-migration.el RET
M-x supertag-migrate-database-to-new-arch RET
```

### 从纯 Org 文件开始

无需迁移。给标题加 `#tag`，定义字段，开始使用视图。你现有的文件原样兼容。

### 旧 reciprocal reference link

旧版 Supertag 可能同时在 source 与 target 文件插入同一 reference。这类自动生成的
link 与用户手写 link 完全同形，因此系统绝不自动删除。先运行
`M-x supertag-migration-preview-reciprocal-links`，只读查看每一条互相指向的物理 link；
确定其中某条已经多余后，再运行 `M-x supertag-migrate-reciprocal-links`，逐条选择并二次
确认。默认不选择任何条目，abort 零写入。每个被改文件都会留下相邻的
`.<文件名>.supertag-migration-*.bak` 快照；重新投影失败时，全部文件自动恢复。

---

## 常见问题速查

| 问题 | 解决方法 |
|---|---|
| 不知道从哪查起 | `M-x supertag-doctor` —— 8 个板块的健康检查，并引导你逐项修复 |
| Org 派生节点或链接看起来过期 | `M-x supertag-reindex-org` |
| 自动同步没启动 | 检查 `supertag-sync-directories` 是否正确配置 |
| 某个文件没同步 | `M-x supertag-sync-analyze-file` |
| 字段值不见了 | reindex 不能恢复 Semantic Facts；请从数据库备份或同步副本恢复 |
| 同步导致 Emacs 卡顿 | 参见 `doc/SYNC-CONFIGURATION.md` 的性能调优 |

---

## 与其他工具的关系

| 工具 | Supertag 的定位 |
|---|---|
| **Org-roam** | Org-roam 是笔记关联图谱；SuperTag 是结构化表格。可以共存。 |
| **Notion** | Notion 把数据锁在云端。SuperTag 离线，数据在你自己的文件里。 |
| **Obsidian** | Obisidian 是另一个编辑器。SuperTag 原生在 Emacs 里，不用切换工具。 |
| **org-ql** | org-ql 查询 Org 内联属性。SuperTag 把字段数据单独存储，不污染 Org 文件，还支持视图和自动化。 |

---

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

## 延伸阅读

- **📖 Supertag 的一天**（中文）：`doc/A-DAY-WITH-SUPERTAG_CN.org` — 完整工作流教程，含可 tangle 的 Elisp 配置
- **📖 A Day with Supertag** (English)：`doc/A-DAY-WITH-SUPERTAG.org`
- **同步配置**：`doc/SYNC-CONFIGURATION.md`
- **自动化规则**：`doc/AUTOMATION-SYSTEM-GUIDE_cn.md`
- **捕获系统**：`doc/CAPTURE-GUIDE_cn.md`
- **虚拟列**：`doc/VIRTUAL_COLUMNS.md`
- **插件开发**：`doc/SUPERTAG-PLUGIN-GUIDE_cn.md`
- **架构深度解析**：`doc/ONTOLOGY-ARCHITECTURE_cn.md`
- **视图框架**：`doc/VIEW_FRAMEWORK_DEV_GUIDE.md`
- **新旧架构对比**：`doc/COMPARE-NEW-OLD-ARCHITECHTURE_cn.md`

---

Supertag 以 GPLv3 自由软件协议开发。欢迎在 GitHub 上贡献代码、提交 bug 或功能请求。
