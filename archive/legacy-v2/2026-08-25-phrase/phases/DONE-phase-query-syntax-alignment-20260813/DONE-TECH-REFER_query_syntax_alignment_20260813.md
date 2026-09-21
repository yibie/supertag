# tech-refer_query_syntax_alignment_20260813

## Options（已讨论并拍板，2026-08-13）

| 决策点 | 选项 | 选择 | 理由 |
|---|---|---|---|
| `today` 语义 | 当天 00:00 / 明天 00:00 | 当天 00:00 | 用户拍板；`(after "today")` 直觉 = 今天开始 |
| 动态变量 v1 | 仅 `<%today%>` / 日期三件套 / +`<%current-file%>` | 日期三件套 | 同一替换器零增量；current-file 后续再议 |
| 聚合形态 | 尾部修饰符 / logseq 前缀式 `(sum f (query))` | 尾部修饰符 | 阅读顺序=执行顺序；对现有 parser 侵入最小 |
| 聚合渲染 | 仅 query block / Table+Stream 也要 | 仅 query block | Table 是节点列表视图，语义冲突；仪表盘属 dashboard widget |
| Automation 条件 | 兼容期双语法 / 一步切换 | 一步切换，存量旧语法确定性转换 | 用户拍板；转换函数保持纯函数便于验证 |

## Proposed Approach

### 查询侧（supertag-services-query.el）

- **操作符扩展**：`supertag-query--parse-sexp` 的 AST 节点新增 `:task`/`:priority`
  （`(task "A" "B")` → `(:type task :values (...))`），执行时对 node plist
  `:todo`/`:priority` 做 member 匹配（priority 大小写不敏感用 `upcase`
  归一化）。
- **not 多参数**：parser 对 `not` 的校验从"恰好一个"放宽为"至少一个"，
  执行等价于 `(not (or ...))`；零参数仍报错。
- **日期符号**：`supertag-query--resolve-date-string` 增加
  `today/yesterday/tomorrow` 分支（`encode-time 0 0 0` 当天/±1 天）与
  `h`/`min` 单位（3600/60 秒）。符号解析返回绝对时间值，下游不变。
- **sort-by 入语法**：AST 增加尾部修饰符层。过滤条件解析完成后，尾部
  `(sort-by K O)` 与聚合子句按出现顺序收集；执行器先过滤、再 sort、最后
  aggregate（复用 `supertag-query--apply-sorting` 与
  `supertag-query-aggregate`）。query block 的 `:sort` header 作为默认值，
  语法内 sort-by 优先。
- **聚合尾部修饰符**：`(sum F)` 等映射到 `supertag-rollup-apply` 词汇表；
  `(group-by F)` 映射 `supertag-query-aggregate` 的 `:group-by`。结果形状：
  无聚合 → node 列表（现状不变）；聚合无分组 → 标量；聚合+分组 →
  (分组键 . 聚合值) alist。新增公开入口 `supertag-query-evaluate`（返回
  完整结果）而非改动 `supertag-query-node-ids`（保持其纯 ID 契约）。
- **动态变量**：`supertag-query--expand-variables` 在 parse 前对查询文本
  做 `<%today%>`/`<%yesterday%>`/`<%tomorrow%>` → 日期符号的替换；
  query block 与 saved query 入口统一调用。

### Automation 侧（supertag-automation.el）

- **转换函数**（纯函数）：`supertag-automation--condition-to-query`
  把旧条件 AST 转换为查询 sexp：
  `(:and ...)`→`(and ...)`、`(:or ...)`→`(or ...)`、`(:not x)`→`(not x)`、
  `(:tag "x")`→`(tag "x")`、`(:has-any-tag a b)`→`(or (tag a) (tag b))`、
  `(:field-equals k v)`→`(field k v)`。
- **rule 规范化**：`supertag-automation--normalize-trigger` 对 `:condition`
  调用转换（旧语法输入转换，新语法原样保留）；`property-equals` 的
  keyword 分支与 `property-changed` 无查询对应物 → 条件 AST 中保留
  `:automation` 专用节点，评估器对这两种节点走专用路径，其余走
  `supertag-query--execute-ast`。
- **评估器**：`supertag-automation--evaluate-condition` 改为调用 query
  执行（节点级），专用节点 fallback。

## Interfaces & APIs

| 接口 | 形状 |
|---|---|
| 操作符 | `(task "TODO" "DOING")` `(priority "A" "B")` |
| 日期符号 | `"today" "yesterday" "tomorrow"`；单位 `d/w/m/y/h/min` |
| sort-by | `(sort-by "created" desc)`，order 省略 = desc |
| 聚合 | `(sum "pages")` `(count)` `(group-by "genre")`，仅尾部 |
| 变量 | `<%today%>` `<%yesterday%>` `<%tomorrow%>` |
| Automation 条件 | `:condition '(and (tag "p") (field "status" "stale"))` |

## Trade-offs

- 聚合放尾部：牺牲了 SQL/Datalog 用户"SELECT 在前"的熟悉感，换取 parser
  与文档的连续性（拍板已定）。
- `not` 多参数改变了错误信息（零参数仍报错），单参数零影响。
- Automation 一步切换：存量数据转换若覆盖不全，规则会不触发——转换函数
  配 parity 测试（转换前后触发集合一致）抵消风险。
- `today` 用本地时区：跨时区用户的"今天"边界随本地，与 org 惯例一致。

## Risks & Mitigations

- 尾部子句与过滤混淆 → parser 显式分段，错误位置报"聚合子句必须位于
  查询尾部"。
- 聚合改变结果形状 → 新公开入口隔离，`supertag-query-node-ids` 契约不变。
- Automation 转换遗漏 → parity 测试枚举全部旧条件类型。
