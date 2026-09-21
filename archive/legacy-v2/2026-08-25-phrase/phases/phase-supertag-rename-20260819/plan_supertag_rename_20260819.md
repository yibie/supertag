# plan_supertag_rename_20260819

## Milestones

- M1 — task001：锁定文档、盘点公开破坏面与历史白名单。
- M2 — task002：迁移入口、Lisp 接口、数据目录保护与 Babel 语言。
- M3 — task003：迁移测试、README、指南、示例、文件名与品牌文本。
- M4 — task004：全量回归、剩余旧名审计、迁移说明与 phase 记录。
- M5 — task005：提交推送、GitHub 仓库改名、remote 与本地目录改名验证。

## Scope

- 入口：`org-supertag.el` → `supertag.el`，`provide/require` 同步。
- 公开接口：仍存的 `org-supertag-*` 配置、模式、Group、alias 全部改名或删除。
- 查询：Babel 语言与执行函数改为 `supertag-query-block`。
- 数据：默认目录改名；只增加旧默认目录冲突保护，不自动搬迁。
- 仓库：当前非历史材料、文件名、GitHub URL、remote、本地根目录统一改名。

## Priorities

1. 数据安全：任何改名都不能让旧数据库表现为空库。
2. 加载闭环：先让 `supertag.el` 与所有 require/test 使用新入口。
3. 公开接口闭环：代码、配置、Query Block 与文档同时切换。
4. 外部状态最后变更：质量门通过并推送后才改 GitHub 仓库。

## Risks & Dependencies

- 当前工作树已有用户修改；批量替换触及同一文件时必须保留原 diff。
- `org-supertag-sync-directories` 等变量跨入口、同步、Git 与测试，漏改会导致
  runtime void-variable。
- Query Block 名称同时存在于 Org Babel 注册、生成模板、文档和用户 Org 示例。
- 根目录改名会改变当前工作目录；放在最后一步，且改名后重新验证路径。
- GitHub 目标名必须在执行前确认可用，操作需要已登录且有管理权限的账户。

## Rollback

- 代码任务按 task 独立提交；GitHub 改名前可逐提交 revert。
- GitHub 改名失败不回滚已经验证的新代码；修正外部权限或名称后重试。
- 数据目录从不由代码移动；用户始终持有显式备份与人工回滚路径。
