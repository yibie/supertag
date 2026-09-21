# task_automation_alignment_20260116

- task001 [x] 建立 automation-alignment phase 文档并登记 CHANGE 索引
  - 产出：`spec_automation_alignment_20260116.md` / `plan_automation_alignment_20260116.md` / `task_automation_alignment_20260116.md` / `change_automation_alignment_20260116.md`，并更新 `.phrase/docs/CHANGE.md`
  - 验证方式：上述文件存在且内容与“文档先行对齐 Automation 2.0”目标一致（手动检查）
  - 影响范围：仅内部文档结构

- task002 [x] 文档先行：重写 `doc/AUTOMATION-SYSTEM-GUIDE.md` 为可执行规范
  - 产出：
    - 明确事件模型与上下文结构（精确 `:path`、tag op 语义）
    - Trigger/Condition/Action/维护命令与现实现状一致
    - 移除条件 `:formula` 承诺，改用函数谓词示例（不引入新 DSL）
    - 提供最小验证与排错清单（trigger miss / condition fail / action no-op / error）
  - 验证方式：Guide 示例与引用函数在仓库中可定位且语义一致（手动检查 + `rg` 检查）
  - 影响范围：`doc/AUTOMATION-SYSTEM-GUIDE.md`

- task003 [x] 代码对齐：补齐事件上下文与语义一致性（不改 API/函数名）
  - 产出：
    - 同步链路与旧链路对“变化”的描述一致（property/field/tag 可定位）
    - tag op 语义统一（added/removed 等）
    - `property-changed/field-changed` 等条件可按 Guide 语义工作
  - 验证方式：按 Guide 的最小场景触发（tag added / property change / global field change）结果符合预期（手动验证）
  - 影响范围：`supertag-automation.el`、`supertag-automation-sync.el`

- task004 [x] 验证清单：整理最小端到端手动验证步骤
  - 产出：在 Guide 或 phase 文档中给出可重复的验证矩阵（变更类型 × trigger/condition/action）
  - 验证方式：按清单逐项执行，均能得到可观察结果或明确失败解释（手动验证）
  - 影响范围：文档

- task005 [x] 对齐中文 Guide：`doc/AUTOMATION-SYSTEM-GUIDE_cn.md` 与英文版一致
  - 产出：中文 Guide 同步英文版的关键事实（模块结构、触发器/条件/动作表、事件上下文、维护命令、debug 开关、最小验证矩阵），并移除条件 `:formula` 承诺
  - 验证方式：对照 `doc/AUTOMATION-SYSTEM-GUIDE.md`，中文 Guide 不再包含 `:formula`、`:on-relation-change`、`:on-create`、`supertag-automation-sync-all-properties`、`supertag-automation-debug` 等过期内容（手动检查 + `rg`）
  - 影响范围：`doc/AUTOMATION-SYSTEM-GUIDE_cn.md`

- task006 [x] 实现公式字段：Table View 渲染时计算 `:formula` 字段值
  - 产出：
    - 修复并完善 `supertag-services-formula.el`，提供可用的公式求值（支持 `{{:prop}}` 占位符与安全 helper）
    - `supertag-view-table.el` 在渲染单元格时识别字段类型为 `:formula` 并计算展示（不持久化）
  - 验证方式：
    - 定义一个 tag 字段 `(:type :formula :formula "(* (/ {{:progress}} 100) 100)")`，打开 table view 时该列能显示计算值
    - 修改 `:progress` 后刷新/重开表格，计算值随之变化，且不写入节点 `:properties`
  - 影响范围：`supertag-services-formula.el`、`supertag-view-table.el`

- task007 [x] 修复 automation async worker 报错 `changed-props` 未绑定
  - 产出：`supertag-automation-sync.el` 中 `supertag-automation-sync--process-node-change` 的 node-change fallback 保持在 `let*` 作用域内，避免 void-variable
  - 验证方式：触发一次不含 property/tag 变化的节点更新或 async sync，`*Messages*` 不再出现 `changed-props` 报错且规则能继续执行（手动验证）
  - 影响范围：`supertag-automation-sync.el`
