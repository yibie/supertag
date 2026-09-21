# task_supertag_rename_20260819

## M1 — 规格与基线

- task001 [x] 锁定破坏性改名规格与仓库基线
  - 产出：Approved PR/FAQ、spec、plan、ADR、任务与 change 文档；记录旧名范围。
  - 验证方式：文档互相引用；FAQ 编号连续；`rg`/`git grep` 基线可复现。
  - 影响范围：`.phrase/docs/`、本 phase 文档。
  - 完成：2026-08-19；基线为 191 个 tracked 文件、1032 个匹配行，唯一运行时
    旧名文件入口为 `org-supertag.el`，历史 phase 文档纳入白名单而不重写。

## M2 — 运行时切换

- task002 [x] 迁移入口、公开 Lisp 接口、数据目录与 Babel
  - 产出：`supertag.el`；运行时 `supertag-*` 唯一接口；旧目录冲突保护；
    `supertag-query-block` 唯一 Babel 语言。
  - 验证方式：定向 ERT、干净 Emacs require、旧目录场景、旧入口缺失断言。
  - 影响范围：入口、sync/setup/git/search/query-block、相关 tests。
  - 完成：2026-08-19；入口改为 `supertag.el`，兼容文件与三个旧 alias 删除；
    persist/query/git 定向 ERT 117/117；隔离目录 `(require 'supertag)` 成功且
    `org-supertag` library 不存在。

## M3 — 仓库材料切换

- task003 [x] 迁移当前测试、README、指南、示例、文件名与品牌文本
  - 产出：当前材料只展示 Supertag；迁移指南包含完整用户替换清单。
  - 验证方式：文档链接/示例审计；非历史范围 `rg` 无旧名。
  - 影响范围：README、doc、test、`.github`、当前开发材料。
  - 完成：2026-08-19；README、当前指南、测试与源码品牌统一为 Supertag；
    5 个旧品牌文档文件改名；新增 `doc/MIGRATING-TO-SUPERTAG.md`，明确数据
    目录、加载入口、配置变量和 Babel block 的人工迁移步骤；先前的 Agent /
    Cowork PR/FAQ 同步改为 `pr_faq_agent_supertag_20260819.md` 并纳入版本控制。

## M4 — 质量门

- task004 [x] 全量回归与旧名称白名单审计
  - 产出：测试、byte-compile、diff check、旧名白名单和 change 索引结果。
  - 验证方式：`./test/run-tests.sh`、修改文件 byte-compile、`git diff --check`、
    `rg` 剩余命中逐条审查。
  - 影响范围：全仓库。
  - 完成：2026-08-19；全量 ERT 519 项为 517 通过、0 失败、2 个既有 demo
    skip；修改的顶层 Elisp 在隔离数据目录内 byte-compile 无 error；干净进程
    `(require 'supertag)` 成功且旧 library 不可发现；352 条旧名命中全部归入历史
    `.phrase`、Changelog、迁移指南、旧数据库/版本兼容代码与对应测试白名单。

## M5 — 外部命名

- task005 [x] 推送并迁移 GitHub、remote 与本地根目录
  - 产出：公开仓库 `yibie/supertag`；origin 与本地 checkout 使用新名称。
  - 验证方式：pull/push 成功；GitHub repo 元数据与 `git status` 显示同步。
  - 影响范围：GitHub 仓库、本地 remote、工作区根目录。
  - 完成：2026-08-19；5 个改名提交先推送到旧远端；GitHub 仓库改为
    `yibie/supertag`，origin 改为 `git@github.com:yibie/supertag.git`，checkout
    最终路径为 `/Users/chenyibin/Documents/emacs/package/supertag`；用户未提交改动已恢复。
