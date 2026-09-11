# Supertag – 在 Emacs 里，把你的 Org 文件变成结构化知识库

<!-- P1 development -->
## 开发验证

首条替换读路径 `supertag-note-query-read-node` 返回隔离的节点/Org 属性投影，
由现有 Node View builder 直接消费。投影不证明 disk/live 相等；公开加载链仍有
旧 tag、relation 和业务依赖，本片不改 writer 或队列。

运行 `bash test/run-tests.sh` 执行 contract、compat 与具名 transition；
`bash test/run-tests.sh --guidance` 执行轻量指导检查。
历史 field/Board 断言须显式运行 `bash test/run-tests.sh archive`；
Board 与 Graph 两个 Web 前端已封存于 `archive/ext/`，手动 Board npm/build CI 任务随之退役。
本地 runner 不安装依赖。
范围及日志见[测试指南](test/README.md)。
本片不声称完整包隔离、fresh-package 安装、Embark 集成或其余整修包已经验收。
<!-- /P1 development -->

[中文](./README_CN.md) | [English](./README.md)

Supertag 帮你在 Org 中**写笔记、连接想法、找回旧内容**。用标题和正文记录，用标签组织，用链接关联。不需要先定义字段或设计表格，你的 `.org` 文件始终是纯文本。

> **从 Org-Supertag 升级？** 6.0 是不保留兼容别名、也不自动搬迁数据的
> 破坏性改名。启动前请先阅读 **[迁移到 Supertag](doc/MIGRATING-TO-SUPERTAG.md)**。

> **从书写开始**：先把想法写下来。需要整理时加一个标签，需要关联时插入链接；之后用 Stream 集中阅读，用 Discovery 搜索全库。

> **准备开始？** 按下方“安装与首次运行”和“真实工作流”操作。历史长篇指南 [Supertag 的一天](doc/A-DAY-WITH-SUPERTAG_CN.org) 仍包含已封存的视图与字段流程，不应照搬为当前配置。

---

## 跟纯 Org-mode 比，到底方便在哪

| 没有 Supertag | 有 Supertag |
|---|---|
| 同一主题的笔记散落在多个文件里 | 给标题加 `#tag`，在 Stream 中集中阅读 |
| 想不起旧笔记的标题或位置 | 打开 Discovery 随机阅读，按 `s` 搜索全库关键词 |
| 需要连接两段相关的想法 | 输入 `[[` 后补全，建立普通 Org 链接并查看反向引用 |
| 阅读时想补充几句话 | 在 Stream 按 `e` 编辑源笔记，或回到原文继续写 |

**核心理念**：先写内容，需要时再组织。Supertag 为纯文本提供标签浏览、链接和搜索；字段系统不再是产品目标。Org properties 是可选的原生文本，已有属性和历史数据不会因此被删除。

---

## 安装与首次运行

**可选依赖 Embark（推荐）：** 安装后可使用下面介绍的情景动作；SuperTag 本身不依赖 Embark。

**可选依赖 superchat：** 请先自行加载并配置 superchat，再使用 `supertag-ai-extract-properties`（Embark 节点键 `x`，或菜单 `e`）。superchat 中配置的模型会提取属性候选，在 Node View 的 **Property candidates** 节逐条审阅；Accept 经现有 writer 保存到 Org PROPERTIES，Skip 丢弃候选且零写入。Supertag 不自带 LLM 客户端，不安装 superchat 不影响其它功能。提示词可通过 `supertag-ai-prompts` 定制。

批量与取消：`supertag-ai-extract-tag-properties`（菜单 `w` → `E`）选一个标签后逐个提取其节点，本批次同一时刻只发一个请求（独立的既有 pending 请求可以共存并会被跳过）；批次结束打开 `*Supertag AI Plan*`，按文件列出全部候选（`k` 跳过一行，`a` 应用，`q` 退出）。应用只写你看到的那份计划：期间候选变了、或目标文件有未保存修改的节点，一律不写并计入汇总。`supertag-ai-cancel-extraction`（菜单 `w` → `C`）与节里的 [Cancel] 按钮取消单个节点；`supertag-ai-cancel-batch`（菜单 `w` → `B`）停止批次。无法解析的回复保留 [Show raw] 按钮，便于你在 superchat 里调整模型的 JSON 输出。


**可选能力：相似笔记。** 安装并启动 Ollama（或兼容 `/api/embed` 的服务），用 `ollama pull bge-m3` 准备模型，再开启 `supertag-semantic-enabled`。Node View 会在未链接提及之后自动显示 **Similar notes (candidates)**。它通过 `curl` 异步向 `supertag-semantic-endpoint`（默认 `http://localhost:11434`）发送 Store 投影中的标题、大纲路径和每节点最多 1500 字自有正文；不写 Org、不自动建链。卡片显示节点级相似度和原文预览，不声称精确命中某段，也不代表概念同一。

默认模型为 `bge-m3`。合成中文改写与中英互检探针中，`dengcao/Qwen3-Embedding-0.6B:Q8_0` 表现更好，中文为主的库推荐拉取该模型并修改 `supertag-semantic-model`；这只是合成数据证据，不保证真实库质量。模型改变会重建数据目录中的可丢弃 int8 side-car `supertag-semantic.el`。可按笔记调整 `supertag-semantic-min-similarity`（默认 0.4）和 `supertag-semantic-max-results`（默认 5）。维护菜单 **More maintenance → Data & setup** 提供 `supertag-semantic-rebuild`、`supertag-semantic-status`、`supertag-semantic-stop`；端点失败后本轮暂停，点击节内 [Retry] 或 rebuild 才再试。默认关闭，不增加包依赖。

```emacs-lisp
;; 用 straight.el 安装
(straight-use-package '(supertag :host github :repo "yibie/supertag"))
(require 'supertag)
```

然后在 Emacs 里：

1. **`M-x supertag-setup`** —— 引导式配置向导。它会报告当前状态，让你选择要同步的目录、选择 file-ID 来源（Org-roam、Denote 或两者都要）、设置持久化选项，并可选地执行首次扫描。
2. **`M-x supertag-menu`** —— 按「记录、整理、查找、维护」组织的任务菜单。用它来发现命令，而不是死记硬背。

就这些。不需要 API key，不需要运行数据库服务器。**你现有的 Org 文件直接就能用。**

---

## 记住这一个命令就够了

**`M-x supertag-menu`** 按四类任务组织入口：**记录 Capture & Write**、**整理 Organize**、**查找 Find & View**、**维护 Maintain**。日常命令留在首屏，自动化、迁移、查询和显示等低频命令收进对应的 `More...` 二级菜单。这篇 README 如果你只记住一件事，记住它就够了。

Embark 是可选依赖（推荐）。可通过 `M-x package-install RET embark` 从 GNU ELPA 安装；装好后，`embark-act` 会在标题、#标签、id 链接、概念提及与选区上提供 Supertag 动作；标题上的 `x` 通过可选 superchat 提取属性候选。不安装也可通过 `supertag-menu` 与 M-x 使用全部命令。须在 Supertag 加载前将 `supertag-embark-integration` 设为 nil（或重启 Emacs）；已注册的集成在本次会话内保持有效。 Org 正文内以所在节点为对象，首标题前交给 Embark 原生对象。可写选区中 RET/`l` 添加链接，`t` 给区域内全部节点添加标签，`p` 将所选文字 Promote（沿用既有边界校验）。Stream、Discovery、Node View 节点卡片上 RET 回原文、`v` 打开 Node View；Node View 标签行支持 RET/`r`/`c`/`R`/`D` 标签动作。

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

修改设置后，执行 `M-x supertag-sync-full-rescan`。

---

## 三个核心概念（2 分钟搞懂）

Supertag 只建立在三个简单想法上：

### 1. 用 `#tag` 把相关笔记放在一起

```org
* Attention Is All You Need #paper
```

给论文笔记加上 `#paper`，就可以在同一个 Stream 中阅读它们，不必把它们搬到同一个文件。

### 2. 用正文记录，用链接关联

摘要、疑问、结论都可以直接写在标题下面，不需要先填写一组属性。用 `supertag-add-link` 连接已有笔记；需要查看引用和提及时，打开 Node View。

### 3. 在视图中阅读、搜索和继续写

- **节点视图** (`M-x supertag-view-node`)：只读查看节点的标签、引用与提及。
- **Stream View** (`M-x supertag-view-stream`)：把一个标签及其斜杠路径下的所有子标签（`#media` 含 `#media/book`）节点的完整集合显示为单列时间标题流。用 `n`/`p` 移动，按 `e` 编辑源标题及其自身正文（文件级节点显示整份文件），按 `v` 进入只读 Node View。`C-c C-c` 保存**整个源文件，包括其他已有草稿**，再投影节点并返回 Stream。`C-c C-k` 只撤销本会话尚未保存的编辑：原生 `C-x C-s` 成功保存后会成为新的取消基线，范围外编辑保留。保存失败保持编辑会话；保存后投影失败保留已落盘正文，并提供既有重试入口。

---

## 一步一步：你的第一个 5 分钟

1. 打开或新建 Org 文件，用 `supertag-add-tag` 添加标签；Stream 与 Discovery 都以源文本为准。
2. 在 Stream 或 Node View 按 `g` 刷新；在节点卡片按 `v` 打开 Node View。
3. 用 `supertag-discovery` 搜索笔记；在标题、标签、链接或选区使用 Embark，可调用加链接、打标签和 Promote。
4. 用 Org capture 模板新建笔记。需要版本化数据迁移时，先用 `supertag-migrate-preview` 预览，再用 `supertag-migrate-apply` 应用。

Table、Schema、Kanban、Board、Graph 入口已封存，不属于当前工作流。

---

## 真实工作流（附可复制的命令）

### 📚 学术阅读队列

```org
* Diffusion Models Survey #paper
* ViT Explained #paper
* CLIP Paper #paper
```

在标题下直接写阅读摘要、尚未理解的问题和自己的评论。

**日常使用**：
1. `M-x supertag-view-stream` → 选 `paper`；按 `g` 刷新，按 `v` 查看节点
2. 在条目上按 `e` 补充阅读笔记，`C-c C-c` 保存整个源文件（包括其他已有草稿）
3. 按 `v` 打开 Node View：属性、引用、提及与语义候选一处可见

**为什么方便**：集中阅读同一主题的笔记，按关键词找回内容，不必先录入评分和阅读状态。

### 📋 项目任务跟踪

```org
* 重写同步层 #task #project
* 修复认证 bug #task
* 部署 v2.1 #task
```

在正文中写清下一步；需要任务状态或时间安排时，可以继续使用原生 Org TODO 和时间戳。

**日常使用**：
1. `M-x supertag-view-stream` → 选 `task`，集中阅读任务笔记
2. 在 Stream 里按 e 编辑来源、g 刷新
3. 执行 `M-x supertag-discovery`，按 `s` 输入空格分隔关键词，阅读全部匹配笔记

**为什么方便**：你的任务分散在不同的 Org 文件里（会议记录、项目文件），但在一个 Stream 里你看到全部。

### 📝 会议记录与决议追踪

```org
* 2024-11-15 迭代规划 #meeting
```

把参会人、讨论和决议写在正文里，需要时用普通列表记录行动项。

**日常使用**：
1. 直接写 Org 标题，或使用已有的 `org-capture` 配置
2. 之后：执行 `M-x supertag-discovery`，按 `s` 搜索标题、标签、正文与 Org 属性值
3. 输入正文中实际出现的关键词，例如 `meeting 发布`；多个关键词需全部匹配

**为什么方便**：会议记录在它们的自然位置（项目文件里），但你跨所有文件统一查询。

---

## 每天都会用的命令

| 你想做什么 | 命令 | 效果 |
|---|---|---|
| 打标签 | `M-x supertag-add-tag` | 添加 `#tag` 到标题，节点自动出现在该标签的表格里 |
| 看一个标签的所有节点（封存 UI） | 显式加载 `supertag-view-table`，再执行 `M-x supertag-view-table` | 旧电子表格视图；默认不加载、不展示入口 |
| 按时间浏览一个标签 | `M-x supertag-view-stream` | 完整标签及后代标题集合；`e` 编辑源节点，`C-c C-c` 保存整文件再投影，`C-c C-k` 撤销未保存会话编辑并保留原生成功保存 |
| 查看节点的 Org properties | `M-x supertag-view-node` | 只读显示已保存的投影属性、标签、引用与提及 |
| 定义类型化关系（封存 UI） | 显式加载 `supertag-view-schema`，再在 Schema View 中按 `a l` | 旧 schema 编辑器；不再是默认入口 |
| 添加或查看关系 | 执行 `M-x supertag-add-link`（前缀参数输入关系名），再打开 Node View | 普通链接保留 `id`/`denote`；`[[supports:NODE-ID]]` 等命名链接是保存的文本，可使用配置名称或本会话新输入名称 |
| 查找或明确新建节点 | `M-x supertag-find-node`；用 `C-u M-x supertag-find-node` 在另一窗口操作 | 已有节点只导航、不写入；无匹配时须明确选择 Create 并选择完整创建模板。Find 不在来源处插入链接，也不执行 Promote 监视 |
| 合并重复标签 | 在当前标签工作流中预览并合并；Schema View 已封存 | 预览后合并到新/已有 tag；Schema 改名经预览确认后复用 Org writer，逐文件写入 |
| 捕获新节点 | `M-x org-capture` | 使用标准 Org Capture；Supertag 模板可继续使用其内部收尾逻辑 |
| 重新发现笔记 | `M-x supertag-discovery` | 默认打开 10 条随机完整正文；`s` 搜索全库并显示全部关键词匹配，`g` 刷新，并可将已选普通引用插回起始笔记 |
| 关联节点 | 输入 `[[` 后补全，或执行 `M-x supertag-add-link` | 链接已有节点或显式按模板新建独立目标，只写 source 的正向 Org link，target Backlink 自动派生 |
| 处理未链接提及 | 打开 Node View，使用 **Unlinked Mentions** | 将普通文字中的 title/alias 提及作为临时候选；可链接一次、链接来源节点内全部，或在该来源节点忽略 |
| 按模板提升文本或标题 | `M-x supertag-promote` | 预览实际内容后明确复用/新建；选区替换为普通 Org 链接 |
| 高亮概念提及 | `M-x supertag-concept-link-mode` | 将概念 title/alias 的提及显示为琥珀色语义高亮，不落库为链接 |
| 光标处的情景动作 | `embark-act`（Embark，可选） | 识别对象并提供对应动作；RET 为默认动作 |
| 重建 Org 索引 | `M-x supertag-sync-full-rescan` | 从一个完整快照重建 Document Projection；绝不恢复 Semantic Facts |

Discovery 初始页是不排序、无重复的阅读抽样。可通过
`supertag-discovery-initial-sample-size` 调整默认的 10 条；关键词搜索始终显示
全部匹配，不受该设置限制。

需要把结果留在笔记中时，可使用 `supertag-query-block` 代码块，例如 `(tag "paper")`。通过 `M-x supertag-add-query-block` 插入，或用 `M-x supertag-query-build` 构建查询。进阶语法见 `doc/QUERY.md`；日常搜索不需要学习查询语言。

可选快捷键示例：

```emacs-lisp
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c n l") #'supertag-add-link)
  (define-key org-mode-map (kbd "C-c n p") #'supertag-promote)
  (define-key org-mode-map (kbd "C-c n o") #'supertag-concept-open-at-point))
```

### Create-or-link 与上下文 Backlink

在普通 Org 正文中输入 `[[`，即可补全已有节点的 title 或 alias。补全会为当前标题提供显式的 `[Create new node]` 项，即使已有同名节点也一样。选中该项会创建新的 ID；未匹配的直接输入还会经过一次明确的新建选择，仅输入文字不会创建数据。选中后，临时写法会被替换为规范的物理 Org link，再由既有文档投影流程生成 Backlink。系统不会向 target 文件写入一条反向链接。

中文等全角输入法可以直接输入 `【【` 代替 `[[`：两种写法触发同一套补全，输入法自动配对出来的 `】】` 会在写入链接时一并消掉。可识别的括号对由`supertag-reference-shorthand-openers` 决定，可以自行追加。

`M-x supertag-add-link` 提供同一流程；存在选区时保留选中文字作为链接说明，没有选区时使用目标标题。前缀参数会询问精确关系名。新输入的名称只注册在当前Emacs 会话，不写用户配置；已配置名称可在重启和重建后继续读取，未配置名称的冷启动自动发现属于后续里程碑。

新目标使用 `supertag-creation-templates`。每个纯数据 plist 提供 `:key`、`:name`、绝对 `:target-file`，并可带 `:tags`、`:properties` 和 `:body`。例如：

```emacs-lisp
(setq supertag-creation-templates
      '((:key "c" :name "Concept"
         :target-file "/path/to/vault/concepts.org"
         :tags ("concept")
         :properties (("STAGE" . "seed"))
         :body "初始正文。\n\n** 来源\n")))
```

默认模板落到有效 vault 的 `concepts.org`。即使标题同名，明确新建仍产生新 ID；选择已有目标时不会套用模板，也不会修改或搬移目标。

Node View 现在分别显示当前节点的 **References** 与 **Backlinks**。每个条目都带可跳转标题、文件与 outline path、关系类型，以及围绕 title/alias 提取的正文片段。它们只是由现有 Store 数据即时生成的 Projection，不是第二套引用索引。

### 未链接提及（Unlinked Mentions）

Node View 还会在其他来源节点的普通正文中查找当前节点的 title 与 alias。未链接提及只是候选，不会落库；只有用户执行 **Link** 或 **Link all in node** 后，才会写成规范 Org ID Link，并沿既有投影流程成为 Backlink。已有 Org Link 与 literal/code
区域不会重复匹配；中文匹配也不会套用错误的 ASCII 词边界。

**Ignore in node** 会把 `SUPERTAG_IGNORE_MENTIONS` 写到来源 heading，因此忽略决定是可检查、可同步的 Org 数据，而不是隐藏缓存。发现过程只使用小型、不可持久化的解析缓存。完整边界见 `UNLINKED-MENTIONS.md`。


## 为什么不会增加负担

"结构化工具"最常见的担忧是：**"我会不会花更多时间在整理上，而不是真正工作？"**

Supertag 从三个层面避免这个问题：

### 1. 你的文件始终是纯 Org

你**永远不需要**通过 SuperTag 的视图来操作。正常写 Org。`#tag` 标记只是文本。如果你明天不用 SuperTag 了，你的文件是 100% 可读的 Org-mode——只不过多了一些 `#tag` 标记而已，丝毫不影响。

### 2. 不必先设计结构

可以只有标题和正文，之后再加标签或链接。Supertag 不要求你为每类笔记定义字段、维护必填项，或把所有笔记整理成相同的格式。

### 3. 同步自动且安全

Supertag 按定时器读取你的文件（可通过 `doc/SYNC-CONFIGURATION.md` 配置）。只有显式命令和 View 才会写入 Org；sync 与 reindex 不修改 Org 文件。`M-x supertag-sync-full-rescan` 只重建现有 Store 中的 Document Projection；不可重建的 Semantic Facts 必须从数据库备份或同步副本恢复。

### 从一篇阅读笔记开始

1. 写一个标题，加上 `#paper`。
2. 在正文中记下想法，给相关笔记插入链接。
3. 用 Stream 阅读同类笔记，按 `e` 继续写；用 Discovery 的 `s` 搜索全库。

这些步骤不需要字段定义，也不需要属性抽屉。

---

## 进阶路线图

从简单开始，需要时再加能力：

| 当你熟悉了…… | 可以试试这个 |
|---|---|
| 手动捕获 | **捕获模板**——复用常用笔记的正文骨架 (`doc/CAPTURE-GUIDE_cn.md`) |
| 基本查询 | **查询块**——在 Org 文件里嵌入动态查询结果 (`doc/ABOUT-QUERY-BLOCK_cn.md`) |
| 默认视图 | **Node View 与 Discovery**——打开节点即见引用、提及与语义候选；Discovery 多选笔记并插回 (`doc/VIEW_FRAMEWORK_DEV_GUIDE.md`) |
| 单资料库 | **多 Vault**——工作/个人分开管理 (`doc/SYNC-CONFIGURATION.md`) |
| 写插件 | **插件开发指南**——自定义抽取器和扩展 (`doc/SUPERTAG-PLUGIN-GUIDE_cn.md`) |

---

## 数据存在哪里

| 什么数据 | 存在哪 | 格式 |
|---|---|---|
| 你的 Org 文件 | 你配置的目录 | 纯 `.org` 文本 |
| 文档投影、标签身份及历史语义数据 | `~/.emacs.d/supertag/supertag-db.el` | Emacs Lisp 数据 |
| 同步状态 | `~/.emacs.d/supertag/sync-state.el` | 文件 mtime 和 hash |
| 每日备份 | `~/.emacs.d/supertag/backups/` | 带时间戳的数据库快照 |

**Org 文件拥有文档事实；数据库拥有语义事实。** 标题、正文、文档拓扑、Org properties、Tag Occurrence 和真实 Org link 属于文档。配置的精确链接类型（例如 `supports:`）投影为可重建的命名关系，并显示在两端 Node View 中；属性键不会派生关系。稳定 Tag identity、Schema、旧 Semantic Edge、Board、Automation 以及持久 Query/View 定义属于数据库。当前数据库也保存 Org 内容的可重建 Projection，但这些副本没有独立主权。

`M-x supertag-sync-full-rescan` 会从一个完整 Org 快照重建 node、Tag Occurrence、Document Link 及其派生索引；快照不完整时，它会中止且不修改 Store。它不是 whole-database reset，也不是 Semantic Restore，无法恢复不可重建的 Semantic Facts。没有备份或同步副本时丢失 `supertag-db.el`，就会永久丢失不可重建数据。完整规则见[《数据主权宪章》。

---

## 多机同步

Git 同步只传输 Org 文本，每台机器从文档重建本地投影缓存；数据库、备份、锁和 presence 文件不由 Git 同步。

### 多库隔离

Supertag 的各个库彼此隔离。自动切库只在通过 Org mode hook 打开 Org 文件时触发，默认关闭。切换前必须先保存当前库；保存失败或已开启 Git 同步模式时会拒绝切换。切库会清理临时候选、Automation 队列、延迟同步、scheduler 任务、AI 候选和迁移诊断。

scheduler 与 discovery 历史文件按当前库的数据目录动态计算。自动切库不会重新加载已经打开的 Org buffer；Node View 中若旧 ID 不属于当前库，刷新时显示空态，选取当前库节点后再显示内容。

### Git Org 文本同步

先配置唯一的 `supertag-sync-directories` 根，再运行 `M-x supertag-git-setup`。它在该根初始化仓库（如需要）、写根 `.gitignore`，只提交 `*.org`（含子目录）和根 `.gitignore`，并可选配置 origin URL、推送；URL 留空则仅在本地使用。数据库留在 `supertag-data-directory`，不搬迁、不安装合并驱动。

旧仓若已经跟踪数据库或 `.gitattributes`，setup 会询问一次，然后仅从 Git 索引移除这些路径；磁盘文件和历史不删除。`supertag-git-sync-now` 只提示运行 setup，不擅自取消跟踪。索引中已有无关暂存文件时，自动提交拒绝并保留它们。

其它机器运行 `M-x supertag-git-clone`，输入远端 URL 和空本地目录。它设置 Org 同步根，一律从克隆的 Org 文本重建并保存本地投影，不加载仓内数据库。非文档数据不通过本特性传输。

`M-x supertag-git-sync-mode` 开启 Org 保存后的 debounce 提交、定时/焦点 fetch 与 merge、push。离线提交保留在本地，联网后续推；push 被拒绝时 fetch/merge 后仅重试一次。`M-x supertag-git-sync-now` 跳过 debounce。成功 pull 后仅将新增/修改的 Org 文件入既有队列，删除文件沿用 orphan 生命周期（`:file=nil`，保留宽限期后由既有 GC 处理），周期扫描仍作兜底。

**Org 冲突：** mode 保持开启，模式行出现 `!`，pull/debounce timers 暂停；首个冲突文件以 Emacs 内置 `smerge-mode` 打开。解决文本并保存后，运行 `supertag-git-sync-now`，才会暂存已解决文件、完成 merge commit、刷新本地投影、恢复 timers 并 push。仍有 marker 或冲突 buffer 未保存则继续暂停，不自动选边。启动时仓库已有冲突也进入相同状态。`M-: (supertag-doctor)` 列出根、仍跟踪的缓存与冲突文件。

正常退出 Emacs 时可选择先同步尚未送出的 Org 改动，或明确保留在本地后退出。数据库保存独立于 Git 传输。

### 同步文件夹服务（Dropbox / iCloud / Syncthing）

如果你不想用 git，也可以把 `~/.emacs.d/supertag/`（或你配置的 `supertag-db-file` 所在目录）放进 Dropbox / iCloud / Syncthing 之类的同步文件夹，让它跟着你在多台机器间走——请先了解其中的取舍：

**最安全的做法：同一时间只有一台机器在写。** `supertag-db.el` 是单个序列化文件。同步服务的工作方式是"整份文件复制，最后写入者赢"——它并不知道两个 Emacs 会话分别改动了文件的哪些部分，所以无法帮你合并。只要两台机器都保存过，后保存的会静默覆盖先保存的。可靠的做法是：**在机器 B 上开始编辑之前，先在机器 A 上彻底退出 Emacs（`C-x C-c`，而不是只关掉窗口）。**

即使你觉得自己在机器 A 上"只是看看，没有编辑"，这条建议依然成立：自动保存定时器（`supertag-db-auto-save-interval`，默认 300 秒）只要会话中有任何改动被标记为脏（dirty），就会在后台把数据库写入磁盘——所以一个开着的 Emacs 进程本身就是一个后台写入者，不管你有没有在主动敲键盘。

**5.9.0 的数据库锁并不能解决这个问题。** 从 5.9.0 起，Supertag 会对数据库文件加一个建议性的锁（`supertag-db-lock`），防止*同一台机器*上的两个 Emacs 实例互相踩踏。当前版本默认把本机锁放在 `temporary-file-directory/supertag-locks/`，不再把新锁写入网络/同步目录；它仍然只能保护"同机双开"，对跨机器场景没有意义。升级后，如果数据库旁还残留旧版本的 `.#supertag-db.el`，先确认没有旧版本 Emacs 正在使用该 vault，再删除这个陈旧锁文件即可。

**presence（在场）告警。** 为了至少给同步文件夹的用户一个提醒（这不是锁——同步服务动辄几分钟的传播延迟决定了它在物理上不可能是锁），Supertag 会在数据库文件旁边写一个很小的 `supertag-presence.json` 文件，记录"最后是哪台主机碰过它、什么时候"。当你加载数据库时，如果发现另一台主机大约在最近 5 分钟内（`supertag-presence-stale-seconds`）还活跃过，就会弹出一条醒目的告警，点名那台主机并说明风险。**看到告警后怎么办：** 如果你确定另一台机器已经退出 Emacs，可以放心继续——这条告警只出现一次，不会重复弹出，直到另一台主机再次声明 presence 为止。如果不确定，先去那台机器上退出 Emacs。随时可以用 `M-: (supertag-doctor)` 查看当前 presence 文件记录的主机、距今时长和判定结果（本机 / 异机活跃 / 异机过期）。将 `supertag-presence-enable` 设为 `nil` 可以完全关闭这个功能。

**不要同步 `sync-state.el` 和 `backups/`。** 这两者虽然和数据库放在同一个数据目录下，但都是本机专属的记录（`sync-state.el` 追踪的是*这台机器*文件系统的 mtime/hash；`backups/` 只是磁盘占用，没必要在多台机器间重复保留）。如果你的同步工具是整个数据目录一起同步，请在工具允许的范围内把这两个路径排除掉；就算被覆盖了，最坏结果也只是多做一次 Org reindex，不会丢数据。

这只是权宜之计，不是最终方案——真正的多机同步需要一个懂"合并"的传输层，而这正是上面的 git 原生同步做的事。如果你要的是多机并发编辑，请直接用它；同步文件夹服务能给你的，永远只是上面的单写者纪律。

---

## 从旧版本迁移

加载受支持的 5.x/6.x 数据库时，自动升级到数据版本 7.1.0。任何迁移变更之前，

SuperTag 都先把数据库复制到 `backups/supertag-db-premigrate-<old-version>-*.el`，再逐字节核验快照。仅修改数据库的转换把旧字段保留为待迁移记录，不改 Org 文件。5.0 之前的版本请先用 SuperTag 6.x 升级。

旧版继承关系（`:extends` 记录）会自动直接解析并写入对应标签实体的 `:extends` 字段，无需改名、无需确认；解析不到父标签、会成环、或标签已有不同 `:extends` 的记录，会继续保留在 `M-x supertag-migrate-status` 的 `:unresolved-extends` 里，并各自带上原因。

1. 运行 `M-x supertag-migrate-preview`，审阅旧字段、活 Org 冲突，以及仍未解析的父子 `:extends` 关系。
2. 运行 `M-x supertag-migrate-apply` 并确认变更，复用既有 Org writer 保存；受影响 buffer 中的活草稿也会一起保存。冲突及无法导出的记录继续保留，可用 `M-x supertag-migrate-status` 查看。请先完成 apply，再清理孤儿标签。

待导出提示只在版本迁移完成当次显示。若关闭自动迁移，可用 `M-x supertag-migrate-run` 显式执行同一条带快照核验的数据库迁移。

---

## 常见问题速查

| 问题 | 解决方法 |
|---|---|
| Org 派生节点或链接看起来过期 | `M-x supertag-sync-full-rescan` |
| 自动同步没启动 | 检查 `supertag-sync-directories` 是否正确配置 |
| 某个文件没同步 | `M-x supertag-sync-status`（按需检查文件） |
| 旧版数据库字段值不见了 | reindex 不能恢复这些历史 Semantic Facts；请从数据库备份或同步副本恢复。Org properties 则以源文件为准 |
| 同步导致 Emacs 卡顿 | 参见 `doc/SYNC-CONFIGURATION.md` 的性能调优 |

---

## 与其他工具的关系

| 工具 | Supertag 的定位 |
|---|---|
| **Org-roam** | Org-roam 是笔记关联图谱；SuperTag 是结构化表格。可以共存。 |
| **Notion** | Notion 把数据锁在云端。SuperTag 离线，数据在你自己的文件里。 |
| **Obsidian** | Obisidian 是另一个编辑器。SuperTag 原生在 Emacs 里，不用切换工具。 |
| **org-ql** | org-ql 提供 Org 查询。Supertag 的日常入口侧重标签阅读、笔记链接、Node View 与 Discovery 搜索；Org properties 仍保存在源文件中。 |

---

### 可选 Agent 集成与纯数据 API

Agent 集成不是书写的前提。历史字段的来源记录仍随 `:legacy-fields` 保留，不因产品方向调整而删除；这不代表当前默认工作流提供字段系统。

Agent 一侧通过 `supertag-api.el` 里的五个纯数据函数和 Supertag 对话：`supertag-api-query`、`supertag-api-node`、`supertag-api-schema`、`supertag-api-catalog`、`supertag-api-json`。参数与返回值都是普通 Elisp 数据（字符串、数字、关键字、plist）；`supertag-api-json` 可把结果转成 JSON，`supertag-api-catalog` 声明每个函数的效果与参数，宿主据此把它们注册为 LLM 工具并套用自己的授权模型。写入经 Node View 与 Org writer，不再有 API 写函数。

### Concept mention 的行为边界

- `supertag-promote` 按键选择共享的 `supertag-creation-templates`。有选区时，只将选中文本替换成普通 Org 链接，不搬走所在标题；没有选区时操作当前标题。同名候选展示实际内容，必须明确选择复用或新建，不自动合并。
- 新建应用完整模板（文件、标签、属性、初始正文）。复用保留 ID、子树、已有属性和正文，只追加标签、补缺失属性；外部标题移入模板文件，旧处留下普通链接，而非 Move 的带 ID stub。复用不重复插入初始正文。
- 监视仅包含当前模板目标文件中已有持久 Org ID 的标题，与其来自手工、Find、Add Link 或 Promote 无关。无 ID 标题不参与监视；确认执行需要身份的操作时由文档 writer 补 ID，读取、预览和取消不补。删除/改目标后，旧文件没有其他模板引用才退出监视；文件、历史 marker 属性和链接全部保留。
- Mention 只存在于显示层。Org link、code/verbatim、普通注释与 `COMMENT` 子树、keyword/drawer、source block 和表格都不会高亮。
- 多个被监视节点共用 title 或 alias 时，文本保持普通显示。生成的 Embed 内容也不参与提及；只有显式链接动作才写链接。

日常使用建议按用途装配命令，而不是每次选择模板。以下命令由用户定义，并非内置命令；定义后可通过 `M-x` 或快捷键调用：

```emacs-lisp
;; Run after your normal Supertag configuration. Adjust these destinations.
(require 'supertag-concept)
(setq supertag-creation-templates
      (list
       (list :key "concept" :name "Concept"
             :target-file (expand-file-name "concepts.org" org-directory)
             :tags '("concept"))
       (list :key "person" :name "Person"
             :target-file (expand-file-name "people.org" org-directory)
             :tags '("person"))
       (list :key "quote" :name "Quote"
             :target-file (expand-file-name "quotes.org" org-directory)
             :tags '("quote"))))

(supertag-define-promote-command supertag-promote-concept "concept")
(supertag-define-promote-command supertag-promote-person "person")
(supertag-define-promote-command supertag-promote-quote "quote")

(define-key org-mode-map (kbd "C-c n c") #'supertag-promote-concept)
(define-key org-mode-map (kbd "C-c n P") #'supertag-promote-person)
(define-key org-mode-map (kbd "C-c n q") #'supertag-promote-quote)
```

这些命令跳过模板选择，但保留复用/新建选择和保存确认。通用 `supertag-promote` 仍可临时选择其他模板。模板仅作为目标文件、标签、属性和初始正文的配置，命令共用同一提升实现。示例中的 `setq` 会替换整个共享模板列表（也影响 Add Link 和 Find Node）；已有配置请合并条目而非直接覆盖，并自行调整文件与快捷键。模板 key 在命令执行时查找，后续修改配置不必重新定义命令。

默认模板仍指向 `concepts.org`。确认后会保存受影响的整个文件，包含已有草稿；确认前取消不写入。跨文件 Promote 不承诺原子性：目标已经保存后，旧位置留链或当前选区保存失败不会删除目标。结构化错误包含阶段、身份和可调用的 `:retry`/`:retry-args`，应重试该操作而非再次执行 Promote。保存失败保留草稿，投影失败保留已落盘文本；恢复状态只在当前进程中保留，不是崩溃恢复日志。

在投影视图卡片上，`t`/`r` 可远程加减标签；Stream 标题行的 `#tag` 支持 RET/r/c/R/D，目标文件有未保存编辑时会拒绝远程写。

### 光标处上下文动作

安装可选的 Embark 后，在对象上执行 `embark-act`。RET 选择默认动作，也可用 `embark-dwim` 直接执行默认动作。

| 对象 | RET 默认动作 | 其它键 |
|---|---|---|
| Org 标题或正文 | 打开/关闭 Node View（`v` 同效；无 ID 时不会补 ID） | `t` 添加标签，`r` 移除标签，`l` 添加链接，`d` 选择并删除链接，`m` 移动，`M` 移动并留链接，`p` Promote，`x` 提取属性（可选 superchat） |
| #标签 | 打开该标签的 Stream | `r` 从当前节点移除，`c` 更换当前节点的该标签，`R` 全库重命名，`D` 全库删除；全库操作先预览确认 |
| id 链接 | 打开链接 | `d` 删除当前完整链接（含描述文字），保存并更新投影 |
| 概念提及 | 打开概念节点 | `l` 将这处提及写成链接 |
| 节点引用 | 跳转到引用的节点 | `v` 打开 Node View |
| 可写 Org 选区 | 添加链接 | `l` 添加链接，`t` 给区域内节点添加标签，`p` Promote 所选文字 |

识别对象不会写入 ID。标题上的 #标签优先于标题；其它 Org 链接交给 Embark 的 Org 集成。用 `embark-cycle` 可切换到 Org 原生对象。雏形只覆盖这些位置，完整命令仍通过 `supertag-menu` 和 M-x 使用。

---



## 延伸阅读

- **📖 Supertag 的一天**（中文）：`doc/A-DAY-WITH-SUPERTAG_CN.org` — 完整工作流教程，含可 tangle 的 Elisp 配置
- **📖 A Day with Supertag** (English)：`doc/A-DAY-WITH-SUPERTAG.org`
- **同步配置**：`doc/SYNC-CONFIGURATION.md`
- **自动化规则**：`doc/AUTOMATION-SYSTEM-GUIDE_cn.md`
- **捕获系统**：`doc/CAPTURE-GUIDE_cn.md`
- **虚拟列**：`doc/VIRTUAL_COLUMNS.md`
- **插件开发**：`doc/SUPERTAG-PLUGIN-GUIDE_cn.md`
- **视图框架**：`doc/VIEW_FRAMEWORK_DEV_GUIDE.md`
- **新旧架构对比**：`doc/COMPARE-NEW-OLD-ARCHITECHTURE_cn.md`

---

Supertag 以 GPLv3 自由软件协议开发。欢迎在 GitHub 上贡献代码、提交 bug 或功能请求。

## 配置变量

以下表格由加载后的源码生成，用途取自源码 docstring 首句。

;; 108 defcustoms

**supertag-ai.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-ai-max-body-chars` | `8000` | Maximum number of own-body characters sent for extraction. |
| `supertag-ai-prompts` | `list of 1 entries, see docstring` | Named extraction prompts. |
| `supertag-ai-timeout` | `60` | Runtime request timeout in seconds. |

**supertag-automation.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-automation-verbose` | `nil` | When non-nil, log verbose automation diagnostics. |

**supertag-concept.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-concept-alias-separator-regexp` | `"[,，;；]"` | Regexp used to split concept aliases stored in SUPERTAG_ALIASES. |
| `supertag-concept-default-file` | `nil` | Default Org file used for newly created concept nodes. |
| `supertag-concept-min-term-length` | `2` | Minimum character length for a concept title or alias mention. |

**supertag-core-async.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-async-batch-size` | `1` | Number of files to process in a single idle cycle. |
| `supertag-async-idle-delay` | `0.5` | Seconds of idle time to wait before processing the next job in the queue. |

**supertag-core-change.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-change-bridge-debug` | `nil` | When non-nil, log bounded legacy bridge delivery diagnostics. |

**supertag-core-persistence.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-db-auto-migrate` | `t` | When non-nil, automatically migrate an out-of-date database after load. |
| `supertag-db-auto-save-interval` | `300` | Auto-save interval in seconds. |
| `supertag-db-backup-directory` | `"<data-directory>/backups"` | Directory for database backups. |
| `supertag-db-backup-interval` | `86400` | Daily backup interval in seconds (default: 24 hours). |
| `supertag-db-backup-keep-days` | `3` | Number of days to keep daily backups. |
| `supertag-db-file` | `"<data-directory>/supertag-db.el"` | Database file path. |
| `supertag-db-lock` | `t` | When non-nil, protect the database from concurrent multi-instance access. |
| `supertag-db-lock-directory` | `string of 64 chars, see docstring` | Directory for local database advisory lock files. |
| `supertag-db-verify-after-save` | `t` | When non-nil, verify the database file after saving. |
| `supertag-presence-enable` | `t` | When non-nil, write and check an advisory presence file for cross-machine awareness. |
| `supertag-presence-stale-seconds` | `300` | Age in seconds beyond which a foreign presence record is ignored. |

**supertag-discovery.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-discovery-history-file` | `nil` | File to store Discovery history. |
| `supertag-discovery-history-max-items` | `100` | Maximum number of keywords to keep in history. |
| `supertag-discovery-initial-sample-size` | `10` | Number of notes shown when Discovery opens or refreshes its sample. |

**supertag-embark.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-embark-integration` | `t` | Register Supertag contextual actions when optional Embark is loaded. |

**supertag-git.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-git-sync-commit-debounce` | `30` | Seconds of quiet after the LAST detected change before `supertag-git-sync-mode' auto-commits. |
| `supertag-git-sync-focus-pull-min-interval` | `60` | Minimum seconds between two focus-triggered pulls (rate limit). |
| `supertag-git-sync-pull-interval` | `300` | Seconds between automatic background `git fetch' (+ merge if behind) attempts while `supertag-git-sync-mode' is enabled. |

**supertag-link.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-reference-context-before` | `72` | Preferred number of characters shown before the matched reference term. |
| `supertag-reference-context-length` | `220` | Maximum number of characters in one contextual backlink excerpt. |
| `supertag-reference-shorthand-openers` | `(("[[" . "]]") ("【【" . "】】"))` | Opener/closer pairs that start a create-or-link shorthand. |

**supertag-mention.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-mention-context-after` | `120` | Maximum source characters shown after an unlinked mention. |
| `supertag-mention-context-before` | `64` | Maximum source characters shown before an unlinked mention. |
| `supertag-mention-max-results` | `300` | Maximum unlinked mention candidates returned for one target node. |
| `supertag-mention-min-term-length` | `2` | Minimum title or alias length considered for unlinked mentions. |
| `supertag-mention-protected-range-cache-size` | `128` | Maximum ephemeral Org parse results retained by the mention scanner. |
| `supertag-mention-result-cache-size` | `64` | Maximum target queries retained by the disposable mention result cache. |

**supertag-ops-relation.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-reference-backlink-include-timestamp` | `nil` | Legacy option retained for compatibility. |

**supertag-semantic.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-semantic-curl-program` | `"curl"` | Program used for asynchronous embedding HTTP requests. |
| `supertag-semantic-enabled` | `nil` | Whether to show and compute semantic candidates. |
| `supertag-semantic-endpoint` | `"http://localhost:11434"` | Base URL of an Ollama-compatible /api/embed endpoint. |
| `supertag-semantic-max-chars` | `1500` | Maximum own-body characters embedded after the title and outline path. |
| `supertag-semantic-max-results` | `5` | Maximum similar-note candidates shown. |
| `supertag-semantic-min-similarity` | `0.4` | Minimum similarity, calibrated only on synthetic notes so far. |
| `supertag-semantic-model` | `"bge-m3"` | Embedding model available at the endpoint. |
| `supertag-semantic-preview-lines` | `3` | Maximum lines of a candidate's own-body preview. |
| `supertag-semantic-request-chars` | `6000` | Approximate text-character budget per request; one longer node may exceed it. |
| `supertag-semantic-save-interval` | `30` | Minimum seconds between partial side-car saves; a drained queue saves immediately. |

**supertag-service-node-identity.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-node-location-org-id-fallback` | `t` | When non-nil, use `org-id-find' for nodes absent from the Store. |

**supertag-service-org.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-org-id-find-auto-enable` | `t` | When non-nil, let `org-id-find` resolve IDs via the Supertag Store first. |

**supertag-services-capture.el**

Supertag 独立 Capture 引擎已退役。记录统一使用标准 `org-capture`；
按模板显式启用的 Supertag 接入仍保留，默认不启用。

| Variable | Default | Purpose |
|---|---|---|
| `supertag-org-capture-auto-enable` | `nil` | When non-nil, enable Supertag integration with `org-capture'. |

**supertag-services-scheduler.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-scheduler-check-interval` | `300` | Interval in seconds for master timer to check for pending tasks. |

**supertag-services-sync.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-sync-auto-create-node` | `nil` | Deprecated compatibility option; sync never invents heading IDs. |
| `supertag-sync-auto-interval` | `900` | Interval in seconds for automatic synchronization. |
| `supertag-sync-auto-start` | `t` | Automatically start Supertag auto-sync after Emacs startup. |
| `supertag-sync-auto-start-initial-delay` | `3` | Seconds to wait after startup before the first auto-start attempt. |
| `supertag-sync-auto-start-max-retries` | `24` | Maximum number of auto-start retries before giving up. |
| `supertag-sync-auto-start-retry-interval` | `5` | Seconds between auto-start retry attempts when directories are not yet available. |
| `supertag-sync-directories` | `nil` | List of directories to monitor for automatic synchronization. |
| `supertag-sync-directories-mode` | `unified` | How to interpret `supertag-sync-directories`. |
| `supertag-sync-exclude-directories` | `nil` | List of directories to exclude from synchronization. |
| `supertag-sync-file-pattern` | `".org$"` | Regular expression for matching files to synchronize. |
| `supertag-sync-hash-props` | `list of 8 entries, see docstring` | Additional properties to include when calculating node hashes. |
| `supertag-sync-idle-delay` | `1.0` | Seconds of idle time required before automatic sync runs. |
| `supertag-sync-import-org-tags` | `nil` | When non-nil, import Org native `:tag:` syntax as tag occurrences. |
| `supertag-sync-max-delete-count` | `1000` | Maximum number of nodes allowed to be deleted in a single GC pass. |
| `supertag-sync-max-delete-ratio` | `0.5` | Maximum allowed ratio of nodes to delete in a single GC pass. |
| `supertag-sync-node-creation-level` | `1` | Minimum heading level for automatic node creation. |
| `supertag-sync-orphan-grace-seconds` | `3600` | Grace period in seconds before deleting orphaned nodes. |
| `supertag-sync-quiet-when-idle` | `t` | If non-nil, suppress routine sync summary/diagnostic messages when no changes were detected. |
| `supertag-sync-smart-detection-enabled` | `nil` | If non-nil, enable smart detection to skip unchanged files during sync. |
| `supertag-sync-smart-detection-verbose` | `nil` | If non-nil, show messages about smart detection decisions during sync. |
| `supertag-sync-snapshot-guard` | `t` | When non-nil, sync uses snapshot state to guard destructive operations. |
| `supertag-sync-state-file` | `"<data-directory>/sync-state.el"` | File to store sync state data. |
| `supertag-text-link-relation-types` | `nil` | Exact non-empty Org link types that project as named relations. |

**supertag-services-template.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-creation-templates` | `nil` | Creation presets shared by Add Link, Find Node and Promote. |

**supertag-ui-commands.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-batch-tag-insert-position` | `end` | Where to insert tags when adding tags in batch mode. |
| `supertag-capture-tag-position` | `end` | Where to place tags when creating a headline via capture. |

**supertag-ui-completion.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-completion-auto-enable` | `t` | Whether to automatically enable tag completion in org-mode buffers. |

**supertag-view-helper.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-view-style-auto-enable` | `t` | Whether to automatically enable supertag-view-style-mode in org buffers. |
| `supertag-view-style-tag-face-properties` | `(:foreground "snow3")` | Face properties for inline supertags. |
| `supertag-view-style-unresolved-tag-face-properties` | `(:inherit shadow :underline t)` | Face properties for inline tag tokens with no registered tag. |

**supertag-view-node.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-view-node-auto-show` | `nil` | Whether to automatically show the Node View side window and follow context. |
| `supertag-view-node-side` | `right` | Side where the Node View side window appears. |
| `supertag-view-node-side-size` | `0.33` | Default size of the Node View side window. |
| `supertag-view-node-strip-todo-keywords` | `t` | Whether to strip TODO keywords from node titles in view buffers. |
| `supertag-view-node-todo-keywords` | `list of 11 entries, see docstring` | List of TODO keywords to strip from node titles. |

**supertag-view-svg-tag.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-svg-tag-color-alpha` | `1.0` | Opacity of the colored style background (0 = invisible, 1 = opaque). |
| `supertag-svg-tag-enable` | `t` | When non-nil, render #tags as SVG pill badges. |
| `supertag-svg-tag-font-family` | `nil` | Explicit SVG font family, or nil to use the default face family. |
| `supertag-svg-tag-font-scale` | `0.68` | Font size scale factor relative to the frame character height. |
| `supertag-svg-tag-font-weight` | `"500"` | Font weight used inside SVG tags (e.g. "normal", "500", "bold"). |
| `supertag-svg-tag-min-column-em` | `0.6` | Minimum width per display column, in units of the SVG font size. |
| `supertag-svg-tag-padding-x` | `8` | Horizontal padding (px) inside the SVG tag. |
| `supertag-svg-tag-radius` | `100` | Corner radius (px) of SVG tag badges. |
| `supertag-svg-tag-show-hash` | `nil` | When non-nil, include the leading '#' in the SVG badge. |
| `supertag-svg-tag-stroke-width` | `0` | Stroke width for SVG tag borders. |
| `supertag-svg-tag-style` | `colored` | Visual style of SVG tags. |

**supertag.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-active-sync-directory` | `nil` | Active vault root directory when `supertag-sync-directories` lists multiple roots. |
| `supertag-data-directory` | `"<user-emacs-directory>/supertag"` | Directory for storing Supertag data. |
| `supertag-file-id-source` | `org-roam` | Policy for recognizing stable file node IDs. |
| `supertag-project-root` | `directory of supertag.el at load time` | The root directory of the supertag project. |
| `supertag-vault-auto-switch` | `nil` | When non-nil, automatically switch the active vault for Org buffers. |
| `supertag-vault-modeline-indicator` | `t` | When non-nil, show the matched vault name in the mode line for Org buffers. |
