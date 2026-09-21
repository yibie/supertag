# change_supertag_rename_20260819

## 2026-08-19 — task001 锁定破坏性改名规格与仓库基线

- Modify `.phrase/docs/pr_faq_supertag_breaking_rename_20260819.md`：用户批准，
  状态更新为 Approved。
- Add phase spec/plan/task/ADR/change：锁定唯一 `supertag` 命名、零兼容层、
  人工数据目录迁移、旧目录失败保护与 GitHub 最后改名顺序。
- Baseline：`git grep` 得到 191 个 tracked 文件、1032 个旧名匹配行；历史
  `.phrase` phase 文档保留原始事实，当前 runtime/docs/tests 进入迁移范围。

Verification：PR/FAQ FAQ 编号 1-13 连续；phase 文档互相一致；
`git diff --check` 通过。

## 2026-08-19 — task002 运行时破坏性切换

- Rename `org-supertag.el` → `supertag.el`：包版本更新为 6.0.0，唯一 feature
  为 `supertag`；所有现存配置、vault、search mode 与 warning group 改为
  `supertag-*`。
- Delete `supertag-compat.el`；Delete interactive search、view style 与旧 Babel
  execute alias，不提供运行时兼容入口。
- Modify `supertag-ui-query-block.el`：唯一 Babel 语言与执行函数改为
  `supertag-query-block` / `org-babel-execute:supertag-query-block`。
- Modify `supertag-core-persistence.el`：默认数据与本机锁目录改为 `supertag`；
  新增旧默认目录检查，只报错，不移动或删除数据。
- Modify sync/setup/git/search/query/tests：公开变量、`require`、library 定位和
  测试调用统一改名。
- Add persistence ERT：旧目录单独存在、双目录冲突、自定义目录三条路径。

Verification：`./test/run-tests.sh persist query git` 117/117；隔离
`user-emacs-directory` 的 `(require 'supertag)` 成功，且
`(locate-library "org-supertag")` 返回 nil；`git diff --check` 通过。

## 2026-08-19 — task003 当前仓库材料切换

- Rename 5 个仍带旧品牌的开发/用户文档文件，所有当前 README、指南、源码
  标题/提示、测试描述与开发说明统一使用 Supertag。
- Add `doc/MIGRATING-TO-SUPERTAG.md`：记录默认数据目录人工改名、安装/require、
  7 个剩余公开配置与 Babel 语言的 before/after 清单；不提供自动迁移。
- Modify `CONTEXT.md` 与 Board UI DnD MIME type，使当前领域名与前端协议同样
  使用 `supertag`。
- Modify `test/force-reload-test.el`：从脚本位置推导仓库根，删除开发者机器的
  checkout 绝对路径。
- Rename ignored draft `pr_faq_agent_org_supertag_20260819.md` →
  `pr_faq_agent_supertag_20260819.md`，将当前 Agent/Cowork 产品定义纳入跟踪，
  并删除“改名留待以后”的过时范围说明。

Verification：非历史/迁移白名单范围的 `git grep` 只剩 README 中指向旧名称的
升级提示；`git diff --check` 通过。

## 2026-08-19 — task004 全量质量门与白名单审计

- Run `./test/run-tests.sh`：519 tests，517 expected pass，0 unexpected，2 个
  既有 dashboard demo skip。
- Byte-compile 本次改动的现存顶层 Elisp：使用隔离的
  `user-emacs-directory`、数据目录与临时 `.elc` 输出，无 compile error；只保留
  仓库既有 Emacs 31 obsolete/docstring/free-variable warnings。
- Isolated smoke：`(require 'supertag)` 成功，`(featurep 'supertag)` 为真，
  `(locate-library "org-supertag")` 为 nil。
- Audit：全仓库 352 条旧名匹配；其中 `.phrase` 历史/改名规格 239 条，外部
  113 条分别为 Changelog 79、迁移指南 14、legacy DB migration 9、persistence
  guard/version 5、对应测试 4、README 升级提示 2。排除这些白名单后为 0。
- `git diff --check` 通过；用户原有 TextUI、路径修复与未跟踪文件仍未提交。

## 2026-08-19 — task005 外部与本地命名迁移

- `git pull --rebase` 确认旧远端无新增提交；5 个改名提交成功 push。
- GitHub repository rename：`yibie/org-supertag` → `yibie/supertag`；核验
  default branch `main`、当前账号 ADMIN、公开 URL 为
  `https://github.com/yibie/supertag`。
- Modify origin：fetch/push 均为 `git@github.com:yibie/supertag.git`。
- Rename local checkout：
  `/Users/chenyibin/Documents/emacs/package/org-supertag` →
  `/Users/chenyibin/Documents/emacs/package/supertag`；目标存在时拒绝覆盖。
- Preserve user work：两份 tracked 修改仅在 pull 期间进入临时 stash，随后无冲突
  恢复并删除 stash；三个 untracked 文件始终未移动出工作树、未提交。
- `bd sync` 已执行但仓库不存在 Beads 数据库；未擅自运行 `bd init`。
