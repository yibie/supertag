# change_query_syntax_alignment_20260813

## 2026-08-13 — task001 (task ...) 与 (priority ...) 操作符

- Modify `supertag-services-query.el`：parser 新增 `task`/`priority` 分支（零或
  多参数，零参数 = 无匹配）；executor 新增对应 AST 分支：`task` 大小写敏感
  匹配 node `:todo`、`priority` 大小写不敏感匹配 node `:priority`，均 O(N)
  扫描投影节点。
- Modify `doc/QUERY.md`：语法表新增两行。
- Modify `test/query-block-test.el`：新增 2 项定向 ERT（单/多参数、大小写、
  无状态节点、零参数、与 not 组合）。

Verification：`./test/run-tests.sh query` 31/31；修改文件 byte-compile 零新增
warning；`git diff --check` 通过。全量回归见 task009 验收。

## 2026-08-13 — task002 not 多参数

- Modify `supertag-services-query.el`：parser 的 `not` 从"恰好一个"放宽为
  "至少一个"（零参数仍报错），AST 节点 `:child` 改为 `:children`；executor
  改为排除全部子条件的并集（等价 `(not (or ...))`）；`--get-fields-from-ast`
  的 not 遍历同步适配。
- Modify `doc/QUERY.md`：not 行更新。
- Modify `test/query-block-test.el`：新增定向 ERT（多参数、单参数不变、
  零参数报错、与 task/priority 嵌套）。

Verification：`./test/run-tests.sh query` 32/32；`git diff --check` 通过。

## 2026-08-13 — task003 日期符号与 h/min 单位

- Modify `supertag-services-query.el`：`supertag-query--resolve-date-string`
  新增 today/yesterday/tomorrow 符号（decode-time 取本地日期，encode-time
  自动归一化 ±1 天溢出，解析为本地 00:00）与 `h`（3600s）/`min`（60s）
  相对单位；所有日期操作符（after/before/between/recent-days 等）受益。
- Modify `doc/QUERY.md`：日期格式表新增两行，并说明 today 的 00:00 边界语义。
- Modify `test/query-block-test.el`：新增 2 项定向 ERT（cl-letf 固定
  current-time，断言 00:00 边界、±1 天 86400s 间隔、h/min 偏移、既有单位回归）。

Verification：`./test/run-tests.sh query` 34/34；`git diff --check` 通过。

## 2026-08-13 — task004 sort-by 入语法

- Modify `supertag-services-query.el`：parser 新增 `sort-by` 分支（KEY +
  可选 asc/desc，缺省 desc）与结果修饰符机制——`and` 的 children 在解析时
  剥离修饰符到 `:modifiers`；`or` 中出现修饰符显式报错；executor 对裸
  `sort-by` 查询返回全量节点；新增 `supertag-query--apply-modifiers`/
  `--sort-node-ids`/`--sort-value`/`--value<`/`--numeric` 与公开
  `supertag-query-modifiers`；`supertag-query-node-ids` 执行后按序应用修饰符
  （排序保留"缺失键排最后"语义）。
- Modify `supertag-ui-query-block.el`：排序辅助函数（sort-value/numeric/
  value<）收缩为 services-query 委托，删除重复实现；`--headers-and-rows`
  检测语法内 sort-by 时跳过 header `:sort` 排序（语法内优先）。
- Modify `doc/QUERY.md`：语法表新增 sort-by 行。
- Modify `test/query-block-test.el`：新增 2 项定向 ERT（排序方向/默认
  desc/内置键与字段/缺失最后/裸 sort-by/与过滤组合/header 优先级）。

Verification：`./test/run-tests.sh query` 36/36；`git diff --check` 通过。

## 2026-08-13 — task005 动态变量日期三件套

- Modify `supertag-services-query.el`：新增公开 `supertag-query-expand`
  （`<%today%>/<%yesterday%>/<%tomorrow%>` → 裸符号 today/yesterday/
  tomorrow，保留外层引号）；parser 的 after/before/between 分支经新增
  `supertag-query--date-arg` 把 symbol 日期参数归一化为字符串。
- Modify `supertag-query-library.el`：`--read-query-sexp` 读取前展开变量。
- Modify `supertag-ui-query-block.el`：`--headers-and-rows` 读取前展开变量。
- Modify `doc/QUERY.md`：新增 Dynamic variables 节。
- Modify `test/query-block-test.el`：新增 1 项定向 ERT（带/不带引号替换、
  无关文本不受影响、parse 日期参数归一化）。

Verification：`./test/run-tests.sh query` 37/37；`git diff --check` 通过。

## 2026-08-13 — task006 聚合/分组尾部修饰符

- Modify `supertag-services-query.el`：parser 新增 sum/avg/min/max/first/
  last/unique-count/concat（单字段参数）、count（零参数）、group-by（单
  字段参数）分支，全部作为结果修饰符被 `and` 剥离到 `:modifiers`；
  `--apply-modifiers` 重写为固定管线 sort-by → group-by → aggregate，
  新增 `--aggregate-values`（count=记录数；sum/avg 非数值集返回 nil；
  其余委托 `supertag-rollup-apply`）与 `--group-values`（缺失键归入
  "__ungrouped__"）；新增公开入口 `supertag-query-evaluate`（返回完整
  结果：ID 列表/标量/分组 alist）；`supertag-query-node-ids` 对聚合修饰符
  显式报错；services-query 显式 require services-formula（无环）。
- Modify `doc/QUERY.md`：新增 Aggregation 节（语法采用单 form
  `(and ... (sum ...))`，与提案的双 form 示例不同——单 form 与解析器
  契约一致）。
- Modify `test/query-block-test.el`：新增 2 项定向 ERT（标量/分组表/
  count/非数值 nil/组合 guard/排序→聚合顺序）。

Verification：`./test/run-tests.sh query` 39/39；`git diff --check` 通过。

## 2026-08-13 — task007 query block 聚合结果渲染

- Modify `supertag-ui-query-block.el`：新增 `--aggregate-headers-and-rows`
  （标量 → 单列 "Aggregate" 一行；分组 → "Group"/"Aggregate" 两列）；
  `--headers-and-rows` 检测聚合修饰符时分流到聚合渲染（`supertag-query-evaluate`），
  非聚合路径不变。
- Modify `test/query-block-test.el`：新增 1 项定向 ERT（标量表/分组表形状
  与值断言）。

Verification：`./test/run-tests.sh query` 40/40；`git diff --check` 通过。

## 2026-08-13 — task008 Automation 条件语法直接切换

- Modify `supertag-automation.el`：新增纯转换函数
  `supertag-automation--condition-to-query`（旧条件 → 查询 sexp：
  has-tag/has-any-tag/has-all-tags/field-equals/global-field-equals/
  property-equals(string) 确定性转换；事件条件与 test 条件返回 nil）；
  `--evaluate-condition` 优先走查询引擎（新旧语法统一匹配集合），无查询
  对应物时走专用评估路径；`--eval-single-condition` 删除已迁移分支
  （has-tag/has-any-tag/has-all-tags/field-equals/global-field-equals），
  其 and/or/not 分支逐子条件分流（可转换子条件走查询引擎，事件子条件
  走专用评估器）——混合条件因此保持完整语义。
- Modify `doc/AUTOMATION-SYSTEM-GUIDE.md`：Conditions 节改为查询语法为主，
  事件条件为专用形式；注明旧形式确定性转换。
- Add `test/automation-condition-test.el` + `test/run-tests.sh`
  （automation-condition filter）：4 项 ERT（新旧语法同集合 parity、
  多 tag 转换 parity、事件/混合条件专用路径、nil/t 透传）。

Behavior：同一条查询在 query block 与 automation 条件中匹配同一节点集；
旧规则数据无需修改（评估时转换）；事件条件不受影响。

Verification：`./test/run-tests.sh automation-condition` 4/4、query 40/40；
`git diff --check` 通过。全量回归见 task009 验收。

## 2026-08-13 — task009 文档收尾与 phase 验收

- Add `doc/QUERY-SYNTAX-PROPOSAL.md`：状态更新为已落地，记录五个拍板结果。
- Modify `test/ownership-separation-test.el`：tag rename 测试的 has-tag
  断言改为统一条件语法（`--evaluate-condition '(tag ...)`），因为 task008
  删除了 has-tag 的旧评估分支。
- Modify `doc/QUERY.md`：全量新语法（task/priority/not 多参数/日期符号/
  h-min/sort-by/动态变量/聚合）已随各 task 收录。

Verification：干净临时 worktree（HEAD 最新 + 全部 phase 提交）全量 ERT
509/509；6 个修改 Elisp byte-compile 零新增 warning；`git diff --check` 通过。
Phase 关闭待用户验收。

## 2026-08-13 — task001 follow-up（验收实测发现）

- Modify `supertag-services-query.el`：priority executor 两侧归一化时剥除
  前导 `#`——扫描投影存 `"#A"`，查询写 `"A"`；此前 `(priority "A")` 对
  真实扫描数据恒不匹配。
- Modify `test/query-block-test.el`：新增 `"#A"` 投影 cookie 断言（带/不
  带 # 均匹配）。

来源：用户要求 emacs -Q 实操验收，样例文件扫描后暴露该差异。
Verification：干净 worktree 全量 ERT 509/509。

## 2026-08-13 — phase 关闭（用户验收通过）

用户以 emacs -Q 实操验收：10 个查询块全部返回正确；Tags 列空确认为正确
语义（heading 尾部 org tag 是 occurrence token，supertag 语义标签需 #tag
定义）；期间发现并修复 priority 井号投影差异（见 task001 follow-up）。
Phase 改名 DONE-phase-query-syntax-alignment-20260813。
