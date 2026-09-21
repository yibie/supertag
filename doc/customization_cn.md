# Supertag 自定义项参考

> English: [customization.md](customization.md)

收录现役 `supertag*.el` 里的全部 defcustom（不含 `archive/`、`test/`、`scripts/` 与已退役模块），默认值直接取自源码；动态默认值在下面「默认值怎么来的」里说明。每节末尾给出对应源码文件，长默认值省略处请以源码为准。

## 目录

- [同步与库](#同步与库)
- [数据库与备份](#数据库与备份)
- [视图与调色板](#视图与调色板)
- [标签显示与补全](#标签显示与补全)
- [链接与上下文反链](#链接与上下文反链)
- [概念与未链接提及](#概念与未链接提及)
- [创建预设与采集](#创建预设与采集)
- [语义相似笔记](#语义相似笔记)
- [AI 属性提取](#AI 属性提取)
- [自动化与调度](#自动化与调度)
- [Git 文本同步](#Git 文本同步)
- [Discovery](#Discovery)
- [Embark 集成](#Embark 集成)

## 默认值怎么来的

- `supertag-data-directory` 默认 `~/.emacs.d/supertag/`；`supertag-db-file`、`supertag-db-backup-directory`、`supertag-sync-state-file` 都按它计算，所以实际路径随数据目录变化。
- `supertag-project-root` 按源文件位置推导，不用手写。
- 路径类默认值在加载（或激活某个库）时按当时的 `user-emacs-directory` 与库根算一次；事后改 `supertag-data-directory` 不会自动改写已算好的 `supertag-db-file`、`supertag-db-backup-directory`、`supertag-sync-state-file`，需要重设这些变量或重启。
- `supertag-view-node-palette`、`supertag-view-tag-cards-palette` 是缓冲区局部生效，不覆盖全局 `supertag-view-palette`。
- nil 的含义要看具体项：`supertag-sync-directories` 是「还没设置」，`supertag-creation-templates` 是「用内置预设」，`supertag-discovery-history-file` 是「不落盘」，`supertag-text-link-relation-types` 是「无预设类型」（会话显式接受的类型仍然有效）。

## 启用时机与注意

- `supertag-org-capture-auto-enable` 默认关闭；想接 org-capture 时再打开。
- `supertag-semantic-enabled` 默认关闭：先装并启动本地嵌入服务（默认 `http://localhost:11434`，模型 `bge-m3`），再跑一次 `M-x supertag-semantic-rebuild`。请求发往你配置的端点。
- `supertag-presence-enable` 会写一个跨机提示文件；数据库本身是单文件，用网盘同步属于「整文件、后写者赢」。
- `supertag-text-link-relation-types` 改完要跑 `supertag-text-link-refresh` 并重建索引。
- `supertag-creation-templates` 只放数据（文件、标签、属性、正文），不能放函数。
- `supertag-sync-auto-create-node` 与 `supertag-reference-backlink-include-timestamp` 是保留兼容项，不影响当前行为。
- 自动化只有在你创建规则后才会写回源 Org 文件；引擎默认在跑，但没有规则就没有动作。

## 同步与库

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-async-batch-size` | `1` | 一个空闲周期处理几个文件 |
| `supertag-async-idle-delay` | `0.5` | 队列中下一个任务前的空闲等待秒数 |
| `supertag-sync-auto-create-node` | `nil` | 已弃用，保留兼容：同步不会自造节点 ID，nil 就是当前行为 |
| `supertag-sync-auto-interval` | `900` | 自动同步的间隔秒数 |
| `supertag-sync-auto-start-initial-delay` | `3` | 启动后等几秒再尝试自动开始 |
| `supertag-sync-auto-start-max-retries` | `24` | 自动开始最多重试次数 |
| `supertag-sync-auto-start-retry-interval` | `5` | 自动开始失败后的重试间隔 |
| `supertag-sync-auto-start` | `t` | Emacs 启动后自动开始同步 |
| `supertag-sync-directories-mode` | `'unified` | 如何解释 `supertag-sync-directories`：`unified` 共用一个库，`vaults` 每个目录一个库 |
| `supertag-sync-directories` | `nil` | 要同步的根目录列表；nil 表示尚未设置。按 [setup_cn.md](setup_cn.md) 在 `(require 'supertag)` 之前设置（向导已退役） |
| `supertag-sync-exclude-directories` | `nil` | 同步时排除的目录；nil 表示不排除 |
| `supertag-sync-file-pattern` | `".org$"` | 参与同步的文件名正则（默认 `.org` 结尾） |
| `supertag-sync-hash-props` | `'(:raw-value :olp :tags :todo :priority :content :properties :parent-id)` | 算节点哈希时额外纳入的 Org 属性；只能追加，不能减少必需项 |
| `supertag-sync-idle-delay` | `1.0` | 空闲多少秒后触发自动同步 |
| `supertag-sync-import-org-tags` | `nil` | 是否把 Org 原生 `:tag:` 当标签导入；导入只读，不改文件 |
| `supertag-sync-max-delete-count` | `1000` | 单次 GC 允许删除的节点数上限，超过就中止 |
| `supertag-sync-max-delete-ratio` | `0.5` | 单次 GC 允许删除的比例上限，超过就中止 |
| `supertag-sync-node-creation-level` | `1` | 遗留项：全仓只有定义、没有读取，当前没有任何代码消费它；同步不会为无 ID 的标题自动造 ID |
| `supertag-sync-orphan-grace-seconds` | `3600` | 孤儿节点被删除前的宽限秒数（须持续处于无 file 状态） |
| `supertag-sync-quiet-when-idle` | `t` | 没有改动时不打印例行同步消息 |
| `supertag-sync-smart-detection-enabled` | `nil` | 用文件哈希跳过未改动文件 |
| `supertag-sync-smart-detection-verbose` | `nil` | 打印“跳过未改动文件”这类决策消息 |
| `supertag-sync-snapshot-guard` | `t` | 用快照状态保护删除等破坏性操作 |
| `supertag-sync-state-file` | `(expand-file-name "sync-state.el" supertag-data-directory)` | 同步状态文件（默认数据目录下 `sync-state.el`） |
| `supertag-active-sync-directory` | `nil` | `vaults` 模式下当前活动库的根目录 |
| `supertag-data-directory` | `(expand-file-name "supertag" user-emacs-directory)` | 数据目录（默认 `~/.emacs.d/supertag/`） |
| `supertag-vault-auto-switch` | `nil` | 按文件路径自动切换到匹配的库（会加载该库的数据库与状态） |
| `supertag-vault-modeline-indicator` | `t` | 在 mode line 显示当前库名 |
| `supertag-file-id-source` | `'org-roam` | 文件级 ID 来源：`org-roam`、`denote`、`auto` 或 `disabled` |
| `supertag-project-root` | `(file-name-directory (file-name-directory (or load-file-name buffer-file-name)))` | 项目根目录，按源文件位置推导 |

源码：[`../supertag-services-sync.el`](../supertag-services-sync.el)、[`../supertag-vault.el`](../supertag-vault.el)、[`../supertag.el`](../supertag.el)

## 数据库与备份

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-db-auto-migrate` | `t` | 加载到旧版本数据库时自动迁移 |
| `supertag-db-auto-save-interval` | `300` | 自动保存数据库的间隔秒数 |
| `supertag-db-backup-directory` | `(supertag-data-file "backups")` | 备份目录（默认数据目录下 `backups/`） |
| `supertag-db-backup-interval` | `86400` | 每日备份间隔秒数（默认 24 小时） |
| `supertag-db-backup-keep-days` | `3` | 每日备份保留天数 |
| `supertag-db-file` | `(supertag-data-file "supertag-db.el")` | 数据库文件（默认数据目录下 `supertag-db.el`） |
| `supertag-db-follow-interval` | `30` | 空闲时检查其他 Emacs 写入的更新版本；nil 表示不跟随 |
| `supertag-db-verify-after-save` | `t` | 保存后校验数据库文件 |
| `supertag-presence-enable` | `t` | 写一个跨机提示文件，供多机协同判断 |
| `supertag-presence-stale-seconds` | `300` | 超过该秒数的他机提示视为过期 |
| `supertag-change-bridge-debug` | `nil` | 打印旧变更桥的投递诊断日志 |

源码：[`../supertag-core-persistence.el`](../supertag-core-persistence.el)、[`../supertag-core-store.el`](../supertag-core-store.el)

## 视图与调色板

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-view-palette` | `'paper` | 视图默认调色板（默认 `paper`） |
| `supertag-view-node-auto-show` | `nil` | 自动显示 Node View 侧窗并跟随上下文 |
| `supertag-view-node-follow-idle-delay` | `0.08` | 跟随到另一个节点前等待的空闲秒数 |
| `supertag-view-node-palette` | `'paper` | Node View 缓冲区的局部调色板 |
| `supertag-view-node-side-size` | `0.33` | Node View 侧窗宽度比例 |
| `supertag-view-node-side` | `'right` | Node View 侧窗在左边还是右边 |
| `supertag-view-node-strip-todo-keywords` | `t` | 视图标题里是否去掉 TODO 关键字 |
| `supertag-view-node-todo-keywords` | `'("TODO" "DONE" "NEXT" ...)`（示意，长值省略；完整默认值见源码） | 要去掉的 TODO 关键字列表 |
| `supertag-view-tag-cards-favorite-groups` | `nil` | Tag Cards 里作为收藏分组显示的标签 ID |
| `supertag-view-tag-cards-manifesto` | `'("MAKE ROOM" "FOR THE UNEXPECTED." "Tags are fuel. The connections are computed for you: click any + row to narrow.")` | Tag Cards 报头下的三行文字 |
| `supertag-view-tag-cards-palette` | `'neon` | Tag Cards 的局部调色板 |

源码：[`../supertag-view-framework.el`](../supertag-view-framework.el)、[`../supertag-view-node.el`](../supertag-view-node.el)、[`../supertag-view-tag-cards.el`](../supertag-view-tag-cards.el)

## 标签显示与补全

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-batch-tag-insert-position` | `'end` | 批量打标签时插在开头还是结尾 |
| `supertag-capture-tag-position` | `'end` | 捕获生成的标题里标签插在开头还是结尾 |
| `supertag-completion-auto-enable` | `t` | 在 Org 缓冲区自动启用标签补全 |
| `supertag-view-style-auto-enable` | `t` | 打开 Org 缓冲区时自动启用行内标签样式 |
| `supertag-view-style-color-by-name` | `t` | 按标签名给行内标签上色 |
| `supertag-view-style-tag-face-properties` | `'(:underline t)` | 已注册行内标签的面属性（默认下划线） |
| `supertag-view-style-unresolved-tag-face-properties` | `'(:inherit shadow)` | 未注册 token 的面属性（默认继承 shadow） |

源码：[`../supertag-tag.el`](../supertag-tag.el)

## 链接与上下文反链

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-reference-backlink-include-timestamp` | `nil` | 兼容保留项，当前不影响行为 |
| `supertag-reference-context-before` | `72` | 匹配词之前显示多少字符 |
| `supertag-reference-context-length` | `220` | 上下文反链摘要的最大字符数 |
| `supertag-reference-shorthand-openers` | `'(("[[" . "]]") ("【【" . "】】"))` | create-or-link 简写的开闭符号对（默认 `[[` 与 `【【`） |
| `supertag-text-link-relation-types` | `nil` | 无预设的关系类型；当前会话显式接受的类型仍然有效（`supertag-link.el:80` 会把会话类型 append 进结果） |

源码：[`../supertag-link.el`](../supertag-link.el)

## 概念与未链接提及

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-concept-alias-separator-regexp` | `"[,，;；]"` | 拆 `SUPERTAG_ALIASES` 里别名的分隔正则 |
| `supertag-concept-default-file` | `nil` | 新建概念节点的默认文件；nil 时按同步目录、`org-directory`、当前文件目录依次推导 |
| `supertag-concept-min-term-length` | `2` | 概念提及的最短标题或别名长度 |
| `supertag-mention-context-after` | `120` | 提及之后显示多少字符 |
| `supertag-mention-context-before` | `64` | 提及之前显示多少字符 |
| `supertag-mention-max-results` | `300` | 未链接提及最多列多少个来源节点 |
| `supertag-mention-min-term-length` | `2` | 未链接提及的最短标题或别名长度 |
| `supertag-mention-protected-range-cache-size` | `128` | 提及扫描的临时 Org 解析缓存条数上限 |
| `supertag-mention-result-cache-size` | `64` | 提及结果缓存保留多少个目标查询 |

源码：[`../supertag-concept.el`](../supertag-concept.el)、[`../supertag-mention.el`](../supertag-mention.el)

## 创建预设与采集

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-org-capture-auto-enable` | `nil` | 是否启用 org-capture 集成（默认关闭） |
| `supertag-creation-templates` | `nil` | 创建预设，Add Link、Find Node 与 Promote 共用；nil 时用内置 Concept 预设 |
| `supertag-node-location-org-id-fallback` | `t` | Store 里没有的节点用 `org-id-find` 定位 |
| `supertag-org-id-find-auto-enable` | `t` | 让 `org-id-find` 先通过 Supertag Store 解析 ID |

源码：[`../supertag-service-org.el`](../supertag-service-org.el)、[`../supertag-node.el`](../supertag-node.el)

## 语义相似笔记

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-semantic-curl-program` | `"curl"` | 发嵌入请求用的外部程序 |
| `supertag-semantic-enabled` | `nil` | 相似笔记总开关；默认关闭，需要可用的嵌入服务 |
| `supertag-semantic-endpoint` | `"http://localhost:11434"` | 嵌入服务地址（默认本机 Ollama） |
| `supertag-semantic-max-chars` | `1500` | 参与嵌入的正文最大字符数 |
| `supertag-semantic-max-results` | `5` | 最多显示几个相似候选 |
| `supertag-semantic-min-similarity` | `0.4` | 相似度下限；目前只用合成笔记校准过 |
| `supertag-semantic-model` | `"bge-m3"` | 嵌入模型名（默认 `bge-m3`；换模型会重建索引） |
| `supertag-semantic-preview-lines` | `3` | 候选正文预览的行数 |
| `supertag-semantic-request-chars` | `6000` | 单次请求的近似字符预算，长节点可能超出 |
| `supertag-semantic-request-timeout` | `30` | 单次嵌入请求的超时秒数 |
| `supertag-semantic-save-interval` | `30` | 部分结果落盘的最小间隔秒数 |

源码：[`../supertag-semantic.el`](../supertag-semantic.el)

## AI 属性提取

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-ai-max-body-chars` | `8000` | 送去做属性提取的本文最大字符数 |
| `supertag-ai-prompts` | （内置 extract-properties 提示词，完整默认值见下方代码块与源码） | 提取用提示词；模板可用占位符 `%t`、`%p`、`%b` |
| `supertag-ai-timeout` | `60` | 属性提取请求的超时秒数 |

源码：[`../supertag-ai.el`](../supertag-ai.el)
完整默认值（照 `supertag-ai.el` 抄录；`:user` 里的换行在源码中是 `\n`）：

```emacs-lisp
(defcustom supertag-ai-prompts
  '((extract-properties
     :system "Extract only facts explicitly stated in the body. Do not invent facts or repeat existing properties with equal values. Return at most 12 entries as one JSON object with uppercase property names and values shaped as {\"value\": \"text\", \"source\": \"verbatim body quote\"}. Use null for source if absent from the body. Output only JSON, with no surrounding prose."
     :user "Title: %t\nExisting properties:\n%p\nBody:\n%b"))
  "Named extraction prompts.  User templates expand %t, %p and %b."
  :type '(alist :key-type symbol :value-type plist) :group 'supertag-ai)
```


## 自动化与调度

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-automation-verbose` | `nil` | 打印自动化的详细诊断日志 |
| `supertag-scheduler-check-interval` | `300` | 调度器检查待办任务的间隔秒数 |

源码：[`../supertag-automation.el`](../supertag-automation.el)

## Git 文本同步

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-git-sync-commit-debounce` | `30` | 最后一次改动后静默多久才自动提交 |
| `supertag-git-sync-focus-pull-min-interval` | `60` | 两次聚焦触发拉取之间的最小间隔秒数 |
| `supertag-git-sync-pull-interval` | `300` | 后台 fetch（必要时 merge）的间隔秒数 |

源码：[`../supertag-git.el`](../supertag-git.el)

## Discovery

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-discovery-history-file` | `nil` | 搜索历史写入哪个文件；nil 表示不落盘 |
| `supertag-discovery-history-max-items` | `100` | 保留多少条搜索历史 |
| `supertag-discovery-initial-sample-size` | `10` | Discovery 打开或刷新时显示的随机笔记条数 |

源码：[`../supertag-discovery.el`](../supertag-discovery.el)

## Embark 集成

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `supertag-embark-integration` | `t` | 加载 Embark 时注册 Supertag 的上下文动作 |

源码：[`../supertag-embark.el`](../supertag-embark.el)
