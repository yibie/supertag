# task_extractor_fix_20251216

- task001 [x] 建立 extractor 修复 phase 的基础文档  
  - 产出：`spec_extractor_fix_20251216.md` / `plan_extractor_fix_20251216.md` / `task_extractor_fix_20251216.md` / `change_extractor_fix_20251216.md`  
  - 验证方式：上述文件存在且内容与“仅修复语法错误”的目标一致（手动检查）  
  - 影响范围：仅内部文档结构

- task002 [x] 修复 `supertag-core-extractor.el` 的语法错误  
  - 产出：修正后的 `supertag-core-extractor.el`（括号/when 结构等语法问题修复），必要时对明显错误的正则转义进行修正  
  - 验证方式：  
    1.（本环境）静态检查：确保括号结构平衡、`when`/`cond` 等结构语法正确，正则字符串转义合法；  
    2.（建议你本地）在 Emacs 中执行 `(load-file \"supertag-core-extractor.el\")` 或通过 `(load-file \"org-supertag.el\")` 间接加载；  
    3. 确认加载过程中无 reader/编译语法错误；  
    4. 调用 `supertag-extractor-setup-defaults` 不抛出立即错误。  
  - 影响范围：仅影响 extractor 模块实现，不改变对外 API。

- task003 [ ]（可选）为 extractor 核心函数补充最小 `ert` 测试  
  - 产出：新增或扩展测试文件（例如新建针对 extractor 的测试），覆盖至少一个简单 headline 的提取流程  
  - 验证方式：运行相关 `ert` 测试并通过  
  - 影响范围：测试代码与 CI，暂不强制在本阶段内完成
