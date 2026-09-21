# change_extractor_fix_20251216

- 2025-12-16 Add  
  - Files:  
    - `.phrase/phases/phase-extractor-fix-20251216/spec_extractor_fix_20251216.md`  
    - `.phrase/phases/phase-extractor-fix-20251216/plan_extractor_fix_20251216.md`  
    - `.phrase/phases/phase-extractor-fix-20251216/task_extractor_fix_20251216.md`  
    - `.phrase/phases/phase-extractor-fix-20251216/change_extractor_fix_20251216.md`  
  - Reason: 为修复 `supertag-core-extractor.el` 语法错误建立独立 phase 与文档闭环  
  - Related: `task001` (task_extractor_fix_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `supertag-core-extractor.el`  
    - `.phrase/phases/phase-extractor-fix-20251216/task_extractor_fix_20251216.md`  
  - Changes:  
    - 修正文件头部 `lexical-binding` modeline 结尾拼写；  
    - 修复 `supertag--extract-refs` 中 `when` 体括号错误，使 `push` 正确位于 `when` 内部；  
    - 修正 `supertag--extract-inline-tags-from-string` 中的正则字符串转义（确保 Emacs 正则分组生效）；  
    - 修复 `supertag--extract-inline-tags` 中 `cond` 分支和 `org-element-map` 的括号配对错误；  
    - 将 `supertag-extractor--content` 中用于移除 PROPERTIES 抽屉的实现改为专用 helper `supertag--remove-properties-drawer`，使用简单的行级 `string-match`/substring 逻辑替代复杂正则，既避免 `Unmatched ( or \\(` 类错误，也降低大内容下的卡顿风险。  
  - Notes: 由于当前环境无 Emacs，可执行验证需在本地 Emacs 中完成（见 `task002` 验证步骤），你刚反馈的 invalid-regexp 和 eval 卡顿均对应这一系列修复。  
  - Related: `task002` (task_extractor_fix_20251216)
