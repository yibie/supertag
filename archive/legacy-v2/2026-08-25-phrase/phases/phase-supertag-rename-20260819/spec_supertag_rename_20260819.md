# spec_supertag_rename_20260819

## Summary

将项目从 Org-Supertag 破坏性迁移为 Supertag。用户已于 2026-08-19 批准
`.phrase/docs/pr_faq_supertag_breaking_rename_20260819.md`：不保留旧入口、
Lisp alias、Babel alias 或兼容模式。

## Goals & Non-goals

Goals：

- 唯一 Emacs 包入口为 `supertag.el` / `(require 'supertag)`。
- 当前公开 Lisp 符号、Customization Group 与 Babel 语言统一使用
  `supertag-*` / `supertag-query-block`。
- 默认数据目录统一为 `~/.emacs.d/supertag/`；旧目录不能被静默忽略成空库。
- 当前 README、用户指南、开发指南、测试和示例只展示新名称。
- 本地 checkout 与 GitHub 仓库最终命名为 `supertag` / `yibie/supertag`。

Non-goals：

- 不改变数据库实体格式、Tag/Field/Relation/Node ID 或普通 Org 内容语义。
- 不提供旧入口文件、obsolete alias、旧 Babel 语言或自动数据搬迁。
- 不重写已经结项的 `.phrase/phases/DONE-*` 历史事实；历史记录可保留旧名。
- 不修改与改名无关的现有用户工作树内容。

## User Flows

### 新安装

1. 用户从 `yibie/supertag` 安装包。
2. 配置 `(use-package supertag)` 或 `(require 'supertag)`。
3. 设置 `supertag-sync-directories` 等 `supertag-*` 变量。
4. `M-x supertag-init` 正常启动。

### 破坏性升级

1. 用户退出所有使用该数据库的 Emacs 实例并备份旧数据目录。
2. 用户将 `~/.emacs.d/org-supertag/` 改名为 `~/.emacs.d/supertag/`。
3. 用户更新安装源、`require`、配置变量、Query Block 与写死路径。
4. Supertag 读取原有数据库，知识实体不变。

### 未迁移旧数据目录

1. 新默认目录不存在，但旧默认目录存在。
2. `supertag-init` 在创建或加载空库前停止。
3. 错误消息要求退出其他 Emacs、备份并人工改名目录。

### 新旧目录同时存在

1. 程序不猜测哪个目录是事实来源。
2. 初始化停止，要求用户整理目录或显式设置 `supertag-data-directory`。

## Edge Cases

- 用户显式设置自定义 `supertag-data-directory`：不检查默认新旧目录冲突。
- 旧目录存在但为空：仍视为待用户处理，程序不自动删除或覆盖。
- Org 文件保留旧 Babel 语言：执行时明确报告语言未注册，不走兼容入口。
- GitHub 旧 URL 可能重定向：当前文档和 remote 仍必须使用新 URL。
- 历史文档提及旧版本：只允许出现在迁移/Changelog/已结项 phase 等白名单。

## Acceptance Criteria

- 全新 Emacs 进程 `(require 'supertag)` 成功；项目不再提供
  `(require 'org-supertag)`。
- 运行时代码不定义当前 `org-supertag-*` 符号或旧 Babel 执行函数。
- `supertag-query-block` 定向测试与全量 ERT 通过。
- 新数据目录可加载、保存、备份、同步；旧目录场景按 User Flows 失败。
- 当前文档、示例和测试入口只使用新名称；剩余 `rg` 命中逐条在历史白名单。
- `git diff --check` 与修改文件 byte-compile 通过。
- GitHub 仓库为 `yibie/supertag`，本地 origin 使用新地址并成功 push。
