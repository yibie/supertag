# spec_logic_explainability_20251231

## Summary

以中文文档为事实来源，补全“逻辑层（Logic）”在 org-supertag 的**用户可感知价值**：让用户能用 `supertag-query` 写出可重复计算的语义结论（派生事实/语义视图），并能在自动化没有运行时看到“为什么没跑”。

同时修复一个高频痛点：自动化执行时消息过多（重复触发 + no-op 保存导致的噪音），让日常使用更安静、更爽快。

## Goals

- 用户能用“初中生也能懂”的方式理解 Data/Logic/Behavior 三层差异。
- 用户能用“逻辑层”得到可见的结果：派生事实/语义视图（当前入口以 `supertag-query` 为核心）。
- 用户能看到自动化为什么没跑：trigger miss / condition fail / disabled / error（至少可通过实验命令观察）。
- 默认减少自动化执行过程的日志噪音（需要时可开启 verbose）。
- 恢复 table view 里引用跳转快捷键：`C-o` 跳到引用节点，`o` 跳当前行节点。

## Non-goals

- 本阶段不引入完整的 Logic DSL（只做“当前最小落地”定义与实验工具）。
- 不做大规模模块重构（只做最小修复与文档澄清）。

## User Flows

### Flow A：用户写“逻辑层”（只读）

1. 用户在 Org 中插入 Query-Block：`M-x supertag-insert-query-block`
2. 写一个查询（例如：`ref` 且超过 N 天未完成）并执行
3. 得到一个结果表格/列表（这是逻辑层的输出：可重复计算、无副作用）

### Flow B：用户理解“自动化为什么没跑”

1. 用户把光标放在某条节点上
2. 运行实验命令 `M-x supertag-test-explain-current-node`
3. 看到：
   - Derived facts（逻辑层结论，例：stale reference）
   - Automation dry-run（哪些规则会跑/为什么没跑）

### Flow C：在 Table 里快速跳转

1. 用户打开 table view
2. 按 `o` 跳到当前行节点
3. 把光标放在 Refs 列的某个引用源上，按 `C-o` 跳到引用节点

## Edge Cases

- 自动化规则触发两次导致重复执行：需要确保默认只走一条事件入口。
- 规则动作是 no-op（例如 TODO 已经是目标状态）：不应保存文件/触发额外消息。
- 调试时仍需要完整日志：通过 `supertag-automation-verbose` / `supertag-sync-verbose` 开关恢复。

## Acceptance Criteria

- `doc/ONTOLOGY-ARCHITECTURE_cn.md` 包含“初中生 3 分钟版本”与“逻辑层如何落地/解释诊断入口”的说明。
- 自动化执行默认不再打印“Executing rule … / SKIP(…) … / Skip sync for internal modification …”这类常规消息。
- no-op TODO 更新不再触发保存与后续噪音。
- table view 的 `C-o` 引用跳转恢复可用，并在 `CHANGELOG.org` 里保持一致描述。

