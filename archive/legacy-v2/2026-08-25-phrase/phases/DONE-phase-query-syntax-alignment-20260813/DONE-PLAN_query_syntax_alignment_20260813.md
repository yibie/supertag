# plan_query_syntax_alignment_20260813

## Milestones

- M1 — simple query 补齐一（task001-002）：task/priority 操作符、not 多参数。
  数据侧零工作（`:todo`/`:priority` 已在 projection）。
- M2 — simple query 补齐二（task003-005）：日期符号与单位、sort-by 入语法、
  动态变量三件套。
- M3 — 聚合（task006-007）：尾部修饰符语法 + query block 渲染。
- M4 — Automation 条件统一与验收（task008-009）：条件语法直接切换 +
  文档收尾。

## Scope

- 全部改动集中于读侧：`supertag-services-query.el`（parser/executor/date
  resolver）、`supertag-ui-query-block.el`（渲染）、`supertag-automation.el`
  （条件评估与 rule 规范化）、文档与测试。
- 不触碰：写入路径（ops 层、org 投影）、字段匹配语义、视图渲染（除 query
  block 聚合渲染）、Store 结构。

## Priorities

1. 包 1（task001-002）：数据就绪、最小 diff、立刻可用
2. 包 2（task003-005）：日常模板工作流高频
3. 包 3（task006-007）：复用现有 aggregate 底层，无新引擎
4. 包 4（task008-009）：收敛性改动，含存量数据转换

## Risks & Dependencies

- task008 存量 Automation rule 的旧条件语法转换是最大风险点：转换必须
  确定性、可验证（转换前后触发语义一致），`property-changed` 类事件条件
  不受影响。
- 聚合尾部子句与过滤语法的解析边界：parser 需区分"过滤子句"与"尾部
  修饰符"，错误位置要显式报错。
- 日期符号 `today` 的 00:00 边界依赖 `decode-time/encode-time` 本地时区，
  测试用固定日期断言，避免跨时区脆弱。
- 依赖顺序：task008 依赖 task001-006 落地后的操作符全集（转换映射目标
  需要 `tag`/`field` 已存在——均已在位；新增操作符的自动化用法属后续）。

## Rollback

- 每包独立提交，可单独 revert。
- task008 的转换函数保留"旧语法 → 新语法"纯函数形式，便于验证与回退。
