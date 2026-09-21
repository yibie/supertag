# change_concept_mentions_20260708

- 2026-07-11 Docs
  - Files: `README.md`, `README_CN.md`
  - Changes: 记录 concept promote 的持久化边界、mention 非正文排除、歧义 term 行为和手动 refresh 命令。
  - Verification: 中英文行为逐项一致；`git diff --check` 通过。
  - Related: `issue012`, `task008`

- 2026-07-11 Fix
  - Files: `supertag-concept.el`, `supertag-ui-commands.el`, `test-concept-mention.el`
  - Changes:
    - 空白 concept 在获取/创建 source ID 前拒绝；
    - concept marker 先写 Org 文件再同步 store，并为 heading marker 增加 direct-file fallback；
    - 使用 Org element context 排除 code/verbatim/comment/COMMENT heading 等非正文；
    - term 索引保留一对多冲突，歧义 term 不再任意跳转或 promote；
    - 新 concept 创建改为写 Org 后调用既有 node sync，不再手工复制 store plist。
  - Verification: concept 9/9、add-reference 4/4、field-reference 6/6、file-node 5/5、file-display 8/8、inline self-check、主包 batch load。
  - Related: `issue012`, `task007`

- 2026-07-08 Add
  - Files:
    - `supertag-concept.el`
    - `test-concept-mention.el`
  - Changes:
    - 增加 concept mention UI 层：用 concept node 的 title/alias 做动态 exact-match mention，高亮不继承 `org-link`，且 mention 不写入 Org link 或 DB relation。
    - 增加 `supertag-promote-concept`：选区文本保持原样，创建或复用 concept node，并只创建当前 node 到 concept node 的显式 reference。
    - 增加 ERT 覆盖 concept title/alias 索引、Org link 跳过、最长匹配、重复 promote 不重复 relation。
  - Verification:
    - `emacs --batch -Q --eval '(package-initialize)' -L . -l test-concept-mention.el`
  - Related: `task002`, `task003`, `task005` (task_concept_mentions_20260708)

- 2026-07-08 Modify
  - Files:
    - `org-supertag.el`
    - `README.md`
    - `README_CN.md`
  - Changes:
    - 在主入口加载 concept mention 模块。
    - 补充 mention/reference 的使用边界、命令说明和可选用户自定义按键示例；不设置默认 `M-RET` 绑定。
  - Verification:
    - `emacs --batch -Q --eval '(package-initialize)' -L . -l supertag-concept.el --eval '(message "loaded concept")'`
    - `emacs --batch -Q --eval '(package-initialize)' -L . -l test-inline-tag-filter.el`
    - `emacs --batch -Q --eval '(package-initialize)' -L . -l test-denote-reference.el`
    - `emacs --batch -Q --eval '(package-initialize)' -L . --eval '(setq org-id-locations-file "/private/tmp/org-supertag-test-home/.emacs.d/org-id-locations")' -l test-add-reference.el -f ert-run-tests-batch-and-exit`
  - Related: `task004`, `task006` (task_concept_mentions_20260708)

- 2026-07-08 Modify
  - Files:
    - `.phrase/phases/phase-concept-mentions-20260708/task_concept_mentions_20260708.md`
    - `.phrase/docs/CHANGE.md`
  - Changes:
    - 勾选完成 task001-task006，并把 concept mention phase change 纳入全局 CHANGE 索引。
  - Verification:
    - 文档条目可追溯到 phase task 与本文件 change 记录。
  - Related: `task006` (task_concept_mentions_20260708)

- 2026-07-08 Add
  - Files:
    - `.phrase/phases/phase-concept-mentions-20260708/spec_concept_mentions_20260708.md`
    - `.phrase/phases/phase-concept-mentions-20260708/plan_concept_mentions_20260708.md`
    - `.phrase/phases/phase-concept-mentions-20260708/task_concept_mentions_20260708.md`
    - `.phrase/phases/phase-concept-mentions-20260708/change_concept_mentions_20260708.md`
  - Changes:
    - 建立 CJK concept mention 功能的 phase 文档、任务边界和验收标准。
  - Related: `task001` (task_concept_mentions_20260708)
