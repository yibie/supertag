# task_query_syntax_alignment_20260813

## M1 — simple query 补齐一

- task001 [x] `(task ...)` 与 `(priority ...)` 操作符
  - 产出：两个新 query 操作符，多参数 = OR；task 大小写敏感匹配 node `:todo`；priority 大小写不敏感匹配 node `:priority`；`doc/QUERY.md` 更新
  - 验证方式：定向 ERT（单/多参数、无状态节点不匹配、与 not 组合、大小写）+ 全量回归
  - 影响范围：`supertag-services-query.el`（parser/executor）、query docs/tests
  - 完成：2026-08-13；query 定向 31/31（含 2 项新增）；全量回归见 task009

- task002 [x] `not` 多参数
  - 产出：`(not a b ...)` = `(not (or a b ...))`；单参数行为不变
  - 验证方式：ERT 单/多参数、嵌套 not、与 tag/field 组合
  - 影响范围：parser、query docs/tests
  - 完成：2026-08-13；query 定向 32/32；AST `:child`→`:children` 三处同步适配

## M2 — simple query 补齐二

- task003 [x] 日期符号与 h/min 单位
  - 产出：`today/yesterday/tomorrow` 符号（today = 当天 00:00）；相对单位补 `h`/`min`；所有日期操作符（after/before/between/recent-days）受益
  - 验证方式：00:00 边界、跨天区间、-4h/-30min、非法单位报错；既有日期测试回归
  - 影响范围：`supertag-query--resolve-date-string`、query docs/tests
  - 完成：2026-08-13；query 定向 34/34（含 2 项新增）；encode-time 自动归一化天溢出

- task004 [x] `sort-by` 入语法
  - 产出：尾部 `(sort-by FIELD asc|desc)`（order 可省略默认 desc）；语法内优先于 query block `:sort` header；缺失排序键排最后
  - 验证方式：优先级、方向、内置键/字段名、与聚合子句共存顺序
  - 影响范围：parser/executor、`supertag-ui-query-block.el` 协调、docs/tests
  - 完成：2026-08-13；query 定向 36/36；排序核心提升到 services-query 并供 query block 复用

- task005 [x] 动态变量日期三件套
  - 产出：`<%today%>` `<%yesterday%>` `<%tomorrow%>` 在查询解析前替换为日期符号；替换覆盖 query block/saved query/library 入口
  - 验证方式：替换正确性、与日期操作符组合、不误伤普通文本
  - 影响范围：query 入口文本预处理、docs/tests
  - 完成：2026-08-13；query 定向 37/37；date 参数 symbol 归一化补齐

## M3 — 聚合

- task006 [x] 聚合/分组尾部修饰符
  - 产出：尾部 `(sum|count|avg|min|max|first|last|unique-count|concat FIELD)` 与 `(group-by FIELD)`；复用 `supertag-query-aggregate` + `supertag-rollup-apply`；结果形状 = 标量 或 (分组键 . 值) 列表；过滤语法不变
  - 验证方式：各函数、缺失/非数值语义、非法位置报错、与既有 filter/sort 回归
  - 影响范围：parser/executor 公开入口、docs/tests
  - 完成：2026-08-13；query 定向 39/39；语法采用单 form（与提案双 form 示例不同，已在文档与 change log 说明）

- task007 [x] query block 聚合结果渲染
  - 产出：聚合查询在 query block 渲染为标量行/分组小表；无聚合行为不变
  - 验证方式：Org output parity（无聚合）、聚合表格形状、与 :columns 并存
  - 影响范围：`supertag-ui-query-block.el`、docs/tests
  - 完成：2026-08-13；query 定向 40/40（含标量/分组表渲染断言）

## M4 — Automation 条件统一与验收

- task008 [x] Automation 条件语法直接切换
  - 产出：`:condition` 直接接受查询语法；旧条件语法（has-tag/has-any-tag/field-equals/property-equals）在 rule 规范化时确定性转换为查询语法；`property-equals` keyword 分支与 `property-changed` 保留专用评估路径；不留长期兼容期
  - 验证方式：转换 parity（新旧 rule 触发集合一致）、事件条件不变、trigger 恰好一次
  - 影响范围：automation condition evaluator、rule normalize、automation tests、AUTOMATION-SYSTEM-GUIDE
  - 完成：2026-08-13；automation-condition 定向 4/4；转换发生在评估时（纯函数），旧数据无需迁移

- task009 [x] 文档收尾与 phase 验收
  - 产出：`doc/QUERY.md` 全量新语法；`QUERY-SYNTAX-PROPOSAL.md` 标记拍板结果；change 索引；用户验收后关闭 phase
  - 验证方式：干净 worktree 完整 ERT、byte compile、`git diff --check`；用户确认
  - 影响范围：docs、all regression suites
  - 完成：2026-08-13；干净临时 worktree 全量 ERT 509/509；**Phase 关闭待用户验收**
