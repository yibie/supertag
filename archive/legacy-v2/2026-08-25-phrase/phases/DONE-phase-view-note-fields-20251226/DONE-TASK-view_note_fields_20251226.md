# task_view_note_fields_20251226

- task001 [x] 建立 view note fields phase 文档与 issue 记录  
  - 产出：`spec_view_note_fields_20251226.md` / `plan_view_note_fields_20251226.md` / `task_view_note_fields_20251226.md` / `change_view_note_fields_20251226.md` / `issue_view_note_fields_20251226.md`  
  - 验证方式：上述文件存在且内容与“view note 字段可见 + 安全风险评估”的目标一致（手动检查）  
  - 影响范围：仅内部文档结构

- task002 [x] 修复 node view 的 tag/field 解析与刷新逻辑  
  - 产出：  
    - 视图在 relations 缺失时回退到 node `:tags`；  
    - `store-changed` 监听覆盖 `:field-values`（全局字段模式）；  
    - 相关模块更新（`supertag-services-ui.el` / `supertag-view-node.el`）。  
  - 验证方式：  
    1. 打开有 tag 的 note，`M-x supertag-view-node` 能显示字段与字段值；  
    2. 修改字段值后视图自动刷新；  
    3. relations 缺失时（可用诊断或构造场景）仍能显示字段。  
  - 影响范围：Node View 与共享 view state（仅 UI 层读取逻辑）。

- task003 [x] 明确缓存/持久化风险并回写结论  
  - 产出：在 issue 文档中补充“缓存不一致是否导致字段/字段值丢失”的结论与证据链，必要时补充最小防护或提示。  
  - 验证方式：issue 文档中包含结论、风险边界与验证步骤。  
  - 影响范围：文档与风险说明（如有防护则涉及持久化逻辑）。  

- task004 [x] 修复 inline #tag 解析支持中文/层级分隔符  
  - 产出：统一 inline #tag 的解析规则，避免 `#coding/语言` 被截断为 `coding`；更新相关模块（`supertag-services-sync.el` / `supertag-core-transform.el` / `supertag-services-capture.el` / `supertag-migration.el`）。  
  - 验证方式：  
    1. `(supertag--extract-inline-tags-from-string "#coding/语言")` 返回 `("coding/语言")`；  
    2. `supertag-transform-extract-inline-tags` 同样返回完整 tag；  
    3. 重新同步后，含该 tag 的节点能显示对应字段。  
  - 影响范围：同步解析、捕获模板解析、迁移工具的 inline tag 规则。  
