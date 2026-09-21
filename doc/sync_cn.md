# Supertag 同步机制

> English: [sync.md](sync.md)

这份文档讲 Supertag 同步“怎么工作”，并把三件事分清楚：Org 文本进数据库的
增量同步、数据库在本机的保存与备份、用 Git 搬运 Org 文本。

## 三层机制，不要混在一起

| 层 | 搬什么 | 谁负责 | 失败时 |
|---|---|---|---|
| Org → 数据库 | 你的 Org 文本到本机数据库投影 | Supertag 自动同步 | 跳过本次，留下状态，不删原文 |
| 数据库本地保存/备份 | `supertag-db.el` 与每日快照 | Supertag 持久化 | 拒绝覆盖，保留旧文件与快照 |
| Git 文本同步 | 只搬 Org 文本 | `supertag-git.el` | 暂停等待或报错，不静默丢文本 |

Git 层**不是**数据库同步：它只提交 Org 文本，各台机器重新扫描文本、在本地重建
投影。只存在数据库里的东西（自动化规则、部分设置、标签投影的本地状态）不会因为
Git 而跨机器同步；数据库本身要靠它自己的备份机制另外保存。

## Org → 数据库（增量同步）

目录就绪后自动开始：`supertag-sync-auto-start`（默认开）在启动后等目录可用，
就绪即启动周期扫描；目录一直不可用就按重试间隔放弃并提示。

- **已保存的变化**：保存 Org 文件会把它加入待同步队列；周期扫描
  （`supertag-sync-auto-interval`，默认 900 秒）把自上次同步后变动的文件补进来，
  空闲后再由异步队列逐个处理。
- **增量检测**：每个文件上次同步的状态记在数据目录的状态文件里，扫描只处理新增
  或改动过的文件。
- **ID 前提**：只有带 Org ID（`:ID:` 属性）的标题才会成为节点；只读扫描不会替
  无 ID 的标题创建 ID，也不改写 Org 文件。先写正文没问题，要成为节点时再补 ID
  （capture 集成或 `M-x org-id-get-create`）。
- **全扫用途**：改了同步目录、换了机器或怀疑状态文件过时时，用
  `M-x supertag-sync-full-rescan` 从一份完整快照重建投影。

## 启用（第一台机器）

前提：本机有 git，提交身份（`user.name`/`user.email`）和远端认证（SSH key 或
凭据助手）已配好；`supertag-sync-directories` 只配一个目录，而且它必须是 Git
仓库顶层本身，不能是某个仓库里的子目录。

```emacs-lisp
;; init.el，必须在 (require 'supertag) 之前
(setq supertag-sync-directories '("~/Documents/notes/"))
(require 'supertag)
```

然后 `M-x supertag-git-setup`：它检查目录已在 Git 仓库中（不在就 `git init`）、
写入忽略规则、提交当前 Org 文本，并可以填写一个远端 URL（留空就是纯本地仓库）。
如果发现旧的本地数据（数据库、备份等）已经被 Git 跟踪，它会先问你是否停止跟踪，
文件都留在本地不删除。远端填写成功会顺带推送一次；推送失败只提示，重试留给自动同步。

打开自动同步：`M-x supertag-git-sync-mode`。这个模式**不持久化**：它只作用于当前
会话，重启 Emacs 后要再打开一次。想开机自动开启，就在 init 里、`(require 'supertag)`
之后调用 `(supertag-git-sync-mode 1)`。手动同步是 `M-x supertag-git-sync-now`。

## 第二台机器

`M-x supertag-git-clone`：克隆到空目录、把它设为**当前会话**的同步目录、重建
本机投影并保存本地数据库。新机器下次启动也要用同一目录，就把
`supertag-sync-directories` 写进 init（在 `(require 'supertag)` 之前）。之后同样
`M-x supertag-git-sync-mode`。两台机器各自维护自己的数据库文件，只有 Org 文本
经过 Git。

## Git 到底同步哪些文件

自动提交的范围很窄：

- **会提交**：同步目录下递归的 `*.org`，以及仓库根目录的 `.gitignore`。
- **不提交**：数据目录、`supertag-db.el`、备份目录、同步状态文件、presence 文件、
  `.gitattributes`；Emacs 的锁文件/自动保存/备份文件（`.#note.org`、`#note.org#`、
  `note.org~`）；普通附件同样不在自动提交范围内。

这两条说的是**自动提交**的范围，不是仓库内容的全部：仓库里手动跟踪的附件或其他
文件仍会随 `git fetch`/合并更新，Supertag 只是不替它们自动提交。

索引范围在提交前后都会被校验：暂存区里出现范围外的路径会直接拒绝提交，已暂存的
冲突标记也会拒绝，避免把本地数据或半成品带进历史。

## 时序、离线、冲突

- **自动提交**：保存 Org 后开始计时，停笔 `supertag-git-sync-commit-debounce`
  （默认 30 秒）才提交，连续改动会不断顺延。
- **自动拉取**：每 `supertag-git-sync-pull-interval`（默认 300 秒）一次
  `git fetch`；如果落后就合并，如果有本地领先提交就推送。Emacs 重新获得焦点时
  也会触发一次，但两次之间至少隔 `supertag-git-sync-focus-pull-min-interval`
  （默认 60 秒）。
- **离线/失败**：fetch 或 push 失败会提示一次（同一次离线不重复刷屏），本地提交
  保留；网络恢复后的下一轮会自动推送积压的提交。
- **未保存的 buffer**：如果远端合并会覆盖有未保存改动的文件，本次合并推迟，并点名
  是哪些文件把它挡住了；Supertag 不会替你保存、还原或关闭 buffer。保存后下一轮
  继续。工作区里已保存但还没提交的 Org 改动会先走一次提交，再拉取。
- **冲突**：合并出现未解决的 Org 冲突时会暂停自动同步，用 `smerge-mode` 打开第一个
  冲突文件（冲突文件不会被导入数据库）。解决、保存后执行 `M-x supertag-git-sync-now`
  继续。
- **边界**：这里没有“任意并发自动无损”的承诺。两台机器同时改同一段文本会交给 Git
  合并，解决不了就停下来等你；不想处理冲突，就让改动错开时间并勤同步。

## 数据库这一层

- 数据库默认在 `~/.emacs.d/supertag/`（`supertag-data-directory`）。有未保存改动时
  每 `supertag-db-auto-save-interval`（默认 300 秒）保存一次；写入后用
  `supertag-db-verify-after-save`（默认开）重新读取并比对，写坏了就中止，旧文件
  原样保留。
- 每天 `supertag-db-backup-interval`（默认 86400 秒）写一份快照，`backups/` 里保留
  `supertag-db-backup-keep-days`（默认 3）天。快照还原入口是 Lisp 函数
  `(supertag-restore)`（不是 `M-x` 命令）：列出每日、迁移前等快照，确认后先建恢复点
  再替换数据库。
- 载入与保存以较新的磁盘版本为先：磁盘版本更新而这个会话有未保存改动时，Supertag
  拒绝覆盖并提示；干净的会话每 `supertag-db-follow-interval`（默认 30 秒）检查一次，
  自动切到较新版本。`M-: (supertag-doctor)` 可以看数据库、守卫与冲突的现状。
- 多机同时开 Emacs 写同一个数据库文件不在保护范围内：presence 文件只是提醒（默认
  开启，`supertag-presence-enable`），它不是锁。用同步服务（Dropbox/iCloud）转发
  数据库文件同样是“整文件、后写者赢”，别在两台机器同时开着改。

## 关键配置

默认值取自源码；完整清单见 [customization_cn.md](customization_cn.md)。目录相关
变量要在 `(require 'supertag)` 之前设置；定时参数则在启动或打开相应模式之前配置
才有保证——已经跑着的计时器不会因为改值立刻重算，重启相关模式或 Emacs 后才按
新值走。

| 变量 | 默认值 | 作用 |
|---|---|---|
| `supertag-sync-directories` | `nil` | 要同步的 Org 根目录；Git 要求恰好一个 |
| `supertag-sync-auto-start` | `t` | 目录就绪后自动启动周期同步 |
| `supertag-sync-auto-interval` | `900` | 周期扫描间隔（秒） |
| `supertag-sync-idle-delay` | `1.0` | 空闲多久才跑周期同步 |
| `supertag-sync-exclude-directories` | `nil` | 排除的目录，优先于同步目录 |
| `supertag-sync-file-pattern` | `"\\.org$"` | 认哪些文件 |
| `supertag-sync-snapshot-guard` | `t` | 用快照守卫破坏性操作，目录不可用就跳过 |
| `supertag-db-auto-save-interval` | `300` | 数据库自动保存间隔（秒） |
| `supertag-db-backup-interval` | `86400` | 每日备份间隔（秒） |
| `supertag-db-backup-keep-days` | `3` | 每日备份保留天数 |
| `supertag-db-verify-after-save` | `t` | 写盘后重读比对，不一致则中止 |
| `supertag-db-follow-interval` | `30` | 跟随其他 Emacs 写入的新版本 |
| `supertag-git-sync-commit-debounce` | `30` | Git 自动提交前的停笔秒数 |
| `supertag-git-sync-pull-interval` | `300` | 自动 fetch 间隔（秒） |
| `supertag-git-sync-focus-pull-min-interval` | `60` | 焦点触发拉取的最小间隔（秒） |
| `supertag-presence-enable` | `t` | 写多机 presence 提醒文件 |

## 常用命令

| 命令 | 作用 |
|---|---|
| `M-x supertag-git-setup` | 配置当前 Org 根为 Git 仓库（初始化、忽略规则、首次提交，可选远端） |
| `M-x supertag-git-clone` | 在另一台机器克隆并重建投影 |
| `M-x supertag-git-sync-mode` | 打开/关闭本会话的自动提交与拉取（不持久） |
| `M-x supertag-git-sync-now` | 立即提交/拉取，或提交已解决的冲突 |
| `M-x supertag-sync-full-rescan` | 全量重扫，从一份完整快照重建投影（不改 Org） |
| `M-x supertag-sync-status` | 看同步状态与当前配置 |
| `M-x supertag-sync-cleanup-database` | 校验节点并清理孤儿（破坏性维护，先确认目录可用） |
| `M-x supertag-save-store` | 立即保存数据库 |
| `M-x supertag-vault-activate` | 多库模式下切换库（Git 同步开启时会拒绝） |

## 排障速记

- **自动同步没反应**：先看 `supertag-sync-directories` 是否已设置且目录存在，用
  `M-x supertag-sync-status` 确认。
- **Git 停在冲突**：解决、保存、`M-x supertag-git-sync-now`；`supertag-doctor`
  的报告里也会列出未解决的文件。
- **大量节点像是要消失**：快照守卫的删除比例/数量上限会拦住整批删除，先确认同步
  目录没有整体移动或不可见。
