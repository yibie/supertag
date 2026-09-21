# 迁移与升级

> English: [migration.md](migration.md)

这份文档管两类迁移，按你的情况看对应部分：

- **数据升级（V1 → V2）**：旧数据库格式、已退役的 fields 数据。当前数据格式是
  **7.2.0**（源码里的 `supertag-data-version`）。
- **包改名（条件小节）**：只有包名仍是 `org-supertag` 的旧安装才需要处理。

如果你还在用旧包名 `org-supertag`，先按最后一节的「条件小节」处理包名、配置与旧数据
目录，再加载新包。

两类的共同底线：不会静默搬迁或合并数据；动手前先备份；会写回 Org 的动作都要你确认。

## 升级前：先备份

1. **Org 文件**。迁移里有一部分会把旧 fields 写回 Org 属性，先按你的习惯（Git、同步
   服务历史、备份）留一份。
2. **数据库**。默认在数据目录（`supertag-data-directory` 默认 `~/.emacs.d/supertag/`，
   文件见 `supertag-db-file`）。关掉所有可能在写库的 Emacs 之后再复制。
3. 记下当前数据版本：加载数据库后 `M-x supertag-migrate-status` 会报告它。

## 旧配置：删掉或替换

- **初始配置向导已退役**。`supertag-setup` 不再存在，按 [setup_cn.md](setup_cn.md)
  在 init 里配置。
- **`supertag-view-table` 已取消**。浏览某个标签下的节点改用
  `M-x supertag-view-stream`；它处理 fields 值的部分随 fields 一起退役。
- **专用 capture 已退役**。记录统一用标准的 `org-capture`；想让 capture 收尾时补 ID，
  加可选集成，见 [setup_cn.md](setup_cn.md)。
- **fields 值不再提供编辑入口**。旧值要么由 `supertag-migrate-apply` 写回 Org 属性，
  要么留在 preview 的原始记录里。
- **fields 相关配置已退役**（例如全局字段开关 `supertag-use-global-fields`，旧模块在
  `archive/` 里）。配置里留着这类 `setq` 不会报错，但也不会有任何作用。
- 其余选项与默认值见 [customization_cn.md](customization_cn.md)。

## 加载会自动迁移（并先快照）

`supertag-db-auto-migrate` 默认为 `t`。加载时如果版本低于当前且落在可迁移范围内
（见下一节），Supertag 会自动迁移：

1. 先把当前数据库**逐字节复制**一份快照到备份目录
   （`supertag-db-backup-directory`），并核对字节一致；
2. 在内存里跑版本链的数据库步骤（包括把旧 fields 来源抽成待处理的
   `:legacy-fields`，这些只动数据库、不碰 Org）；
3. 保存新数据库并打上当前版本号。出错时会用刚做的快照还原，错误写进
   `M-x supertag-migrate-status` 的报告里。

不想让它自动跑，就在 `(require 'supertag)` 之前 `(setq supertag-db-auto-migrate nil)`，
之后手动 `M-x supertag-migrate-run`。

已经是当前版本 7.2.0 的数据库不做迁移，也不会额外写快照；被拒绝的版本
（无版本戳、4.x、比当前新）同样不动数据。

## 哪些版本能直接迁移

| 你的数据版本 | 结果 |
|---|---|
| 5.0.0 到 7.2.0（本版本） | 可以迁移到 7.2.0 |
| 4.x 及更早 | 不能直接迁移；提示先用 supertag 6.x 升一次，再升到当前版本 |
| 没有 `:version` 戳 | 拒绝迁移，数据库不动；先确认是哪个版本写的，再手动处理 |
| 比 7.2.0 更新 | 拒绝迁移；这是数据库比程序新，应该升级 Supertag 而不是迁移数据 |

「能迁移」指版本链接受这段数据，不承诺每个版本、每种边界数据都无损：无法解释的
旧值会保留（preview 里的原始记录），冲突项留给你决定。

## 旧 fields 数据：四条命令

- `M-x supertag-migrate-status`——只读报告：数据版本、待处理字段、未解析的子标签
  关系、重复/非法节点、上次迁移的错误和快照路径。不删除任何东西。
- `M-x supertag-migrate-preview`——`*Supertag Field Migration*` 缓冲区里逐节点显示
  准备写入什么、哪些还在等待、哪些与 Org 里已有属性冲突、哪些因为空名/保留键/
  定位失败被跳过；原始记录也列在下面。它不改任何文件，也不改数据库。
- `M-x supertag-migrate-apply`——真正写 Org。运行时会先把尚未解析的子标签关系在
  数据库里处理掉（这段不改 Org），然后问
  「写入 N 键，待保存/待投影 M；保存并重投影？」；**只有你确认之后**才把属性写进
  源文件并重新投影，冲突的留给下一次，写成功的记录从待处理里退场。
- `M-x supertag-migrate-run`——只跑数据库版本链（就是自动迁移那步），不写 Org 属性。

fields 的数据路径就是这两条：先 preview 看清，再 apply 写回 Org；数据库快照和你的
Org 备份就是纯文本退路。

## 条件小节：仍在使用 `org-supertag` 的人

> 包名已经是 `supertag` 的可以跳过这一节。

**包与加载**。改名是破坏性的，不提供旧库别名或自动数据目录搬迁。改两处：

```emacs-lisp
;; 之前
(straight-use-package '(org-supertag :host github :repo "yibie/org-supertag"))
(require 'org-supertag)

;; 之后（同步目录要写在 require 之前；完整模板见 setup_cn.md）
(straight-use-package '(supertag :host github :repo "yibie/supertag"))
(setq supertag-sync-directories '("~/Documents/notes/"))
(require 'supertag)
```

**旧数据目录**。旧默认目录是 `~/.emacs.d/org-supertag/`，现在是
`~/.emacs.d/supertag/`。Supertag 不会静默搬迁，也不会把两处目录合并：先退出所有
Emacs、先备份，再明确选择。当前构建提供 `(supertag-resolve-data-directories)`（这是
Lisp 函数，不是 `M-x` 命令）：它展示新旧默认目录的对比、让你选择保留哪一个，并对
具体的重命名操作要求确认；没有被选中的目录会重命名为带日期的 `-retired-` 归档
（重名自动加数字后缀），不删除数据。你也可以照旧手工把目录改名，同样是先备份、
先退出 Emacs。

**配置改名**。搜索配置里的 `org-supertag`，按下表替换。旧名不再被读取：继续 `setq` 旧名通常不会
报错，但也不会有任何作用。

| 旧名 | 新名 |
|---|---|
| `org-supertag-data-directory` | `supertag-data-directory` |
| `org-supertag-sync-directories` | `supertag-sync-directories` |
| `org-supertag-sync-directories-mode` | `supertag-sync-directories-mode` |
| `org-supertag-active-sync-directory` | `supertag-active-sync-directory` |
| `org-supertag-vault-auto-switch` | `supertag-vault-auto-switch` |
| `org-supertag-vault-modeline-indicator` | `supertag-vault-modeline-indicator` |
| `org-supertag-file-id-source` | `supertag-file-id-source` |

**Babel 语言**。旧的 `org-supertag-query-block`、`org-supertag-query` 换成
`supertag-query-block`；已有的动态块仍然可以刷新。

## 升级后检查

1. 重新加载数据库，`M-x supertag-migrate-status` 确认版本已是 7.2.0、没有报错；
2. 如果报告还有待处理字段，`M-x supertag-migrate-preview` 看清单，再决定是否
   `M-x supertag-migrate-apply`；
3. 打开一两篇旧笔记，确认标题、标签和属性都对；跑一次常用查询或视图；
4. 改过包名或目录的，再确认数据目录指对了位置（`M-: (supertag-doctor)` 可以看现状）；
5. 确认之后，快照仍留在备份目录里，保留到你放心为止。
