# task_concept_mentions_20260708

- task001 [x] 建立 concept mentions phase 文档
  - 产出：`spec_concept_mentions_20260708.md`、`plan_concept_mentions_20260708.md`、`task_concept_mentions_20260708.md`、`change_concept_mentions_20260708.md`
  - 验证方式：文档包含 scope、任务、验收标准与风险边界
  - 影响范围：`.phrase/phases/phase-concept-mentions-20260708/`

- task002 [x] 实现 concept mention 核心模块
  - 产出：`supertag-concept.el`
  - 验证方式：batch test 覆盖 title/alias 索引、最长匹配、mention keymap 与 open-at-point
  - 影响范围：新增 concept/mention UI 层，不改 reference/tag 既有命令语义

- task003 [x] 实现 promote concept 命令
  - 产出：`supertag-promote-concept`
  - 验证方式：选区文本保持不变；当前 node 到 concept node 产生一条 reference；重复 promote 不重复 relation
  - 影响范围：`supertag-concept.el`，复用 node/relation ops

- task004 [x] 接入模块加载并补充用户文档
  - 产出：`org-supertag.el` require、README/README_CN 命令说明和可选 keybinding 示例
  - 验证方式：加载 `org-supertag.el` 后命令可用，且没有默认绑定 `M-RET`
  - 影响范围：`org-supertag.el`、`README.md`、`README_CN.md`

- task005 [x] 增加并运行 concept mention 测试
  - 产出：`test-concept-mention.el`
  - 验证方式：`emacs --batch -Q --eval '(package-initialize)' -L . -l test-concept-mention.el`
  - 影响范围：测试文件

- task006 [x] 回写 change 与全局 CHANGE 索引
  - 产出：勾选已完成任务，更新 phase change 与 `.phrase/docs/CHANGE.md`
  - 验证方式：change 条目能追溯到 task002-task005
  - 影响范围：`.phrase/`

- task007 [x] 修复 concept promote 与 mention 审查问题（issue012）
  - 产出：输入校验无副作用；concept 标记以 Org 文件为事实来源；非正文上下文不高亮；冲突 term 不任意跳转
  - 验证方式：新增四类 ERT 回归，并保持原有 concept/reference 测试通过
  - 影响范围：`supertag-concept.el`、`test-concept-mention.el`

- task008 [x] 更新中英文 README 的 concept 行为边界（issue012）
  - 产出：说明 promote、非正文排除、歧义 term 与 refresh 行为
  - 验证方式：中英文语义一致；Markdown diff check 通过
  - 影响范围：`README.md`、`README_CN.md`
