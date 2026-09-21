# spec_query_syntax_alignment_20260813

## Summary

将 org-supertag 查询语法提升到 logseq v1 simple/advanced query 的日常功能水平。
设计提案见 `doc/QUERY-SYNTAX-PROPOSAL.md`；五个拍板点（2026-08-13 用户确认）：

1. `today` 解析为当天 00:00
2. 动态变量 v1 = `<%today%>` `<%yesterday%>` `<%tomorrow%>` 三件套
3. 聚合采用尾部修饰符形态（非 logseq 前缀式）
4. 聚合结果仅 query block 渲染
5. Automation 条件语法直接切换为查询语法，不留长期兼容期（存量旧条件确定性转换）

## Goals & Non-goals

Goals（四个包）：

- 包 1：`(task ...)`、`(priority ...)` 操作符；`not` 多参数
- 包 2：`today/yesterday/tomorrow` 日期符号与 `h/min` 单位；`sort-by` 入语法；
  动态变量日期三件套
- 包 3：聚合/分组尾部修饰符（sum/count/avg/min/max/first/last/unique-count/
  concat + group-by）；query block 聚合结果渲染
- 包 4：Automation `:condition` 直接接受查询语法；旧条件语法确定性转换

Non-goals：

- 不引入 Datalog 引擎或语法（语义模型不同，见提案 E 路线讨论）
- 不改 `field` 的匹配语义（保持精确相等，不加引用子串匹配）
- Automation 事件条件（`:on-*` 事件类型、`property-changed`）不统一，
  保留 Automation 专用评估
- Table/Stream 视图不做聚合渲染
- `<%current-file%>` 等其余变量不在本 phase

## User Flows

- `(task "TODO" "DOING")` → 返回 todo 状态为二者之一的节点；无 todo 状态的
  普通 heading 不匹配；多参数为 OR
- `(priority "A")` → 返回 [#A] 节点（大小写不敏感）；多参数 OR
- `(not (tag "a") (tag "b"))` → 排除携带 a 或 b 的节点；单参数行为不变
- `(after "today")` → 今天 00:00 之后；`(between "yesterday" "today")` →
  昨天整天；`(after "-4h")`、`(after "-30min")` → 相对小时/分钟
- `(and (tag "task") (sort-by "created" desc))` → 结果按创建时间倒序；
  语法内 sort-by 优先于 query block 的 `:sort` header；缺失排序键的节点排最后
- `(and (task "TODO") (after "<%today%>"))` → 模板中 `<%today%>` 替换为
  今天 00:00 再执行
- `(and (tag "book")) (sum "pages")` → 一个数字；`... (group-by "genre")
  (sum "pages")` → (分组键 . 聚合值) 列表，query block 渲染为小表
- Automation rule：`:condition '(and (tag "project") (field "status"
  "stale"))` 与 query block 同一条语法，触发集合一致

## Edge Cases

- task/priority 多参数空列表：`(task)` → 无匹配（与 `(or)` 一致）
- priority 大小写：`(priority "a")` 匹配 `[#A]`
- today 边界：`(after "today")` 含今天 00:00 不含 00:00 之前；
  `(before "today")` 排除今天整天
- 聚合对缺失/非数值字段：沿用 `supertag-query-aggregate` 语义
  （sum 对非数值集合返回 nil，不报错）
- 聚合/排序子句出现在非尾部位置 → 显式报错
- 旧 Automation rule 数据（`:condition` 为旧语法）加载时确定性转换为
  新语法；`property-equals` keyword 分支与 `property-changed` 保留专用评估
- 动态变量仅替换完整 token，不误伤字段名中相似文本

## Acceptance Criteria

- 每个操作符至少一项定向 ERT + parity 断言；全量 ERT 通过（干净 worktree）
- `doc/QUERY.md` 收录全部新语法；AUTOMATION-SYSTEM-GUIDE 的 condition
  示例改为查询语法；`QUERY-SYNTAX-PROPOSAL.md` 标记拍板结果
- 修改文件 byte-compile 零新增 warning、`git diff --check` 通过
- 用户验收后关闭 phase
