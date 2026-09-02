# Query 语法对齐提案（logseq v1 功能水平）

状态：✅ 已全部拍板并落地（phase-query-syntax-alignment-20260813，
task001-009 完成于 2026-08-13）。本文件保留拍板记录。

拍板结果（2026-08-13 用户确认）：
1. `today` = 当天 00:00 ✅
2. 动态变量 v1 = 日期三件套（<%today%>/<%yesterday%>/<%tomorrow%>）✅
3. 聚合形态 = 尾部修饰符 ✅（落地采用单 form：`(and ... (sum ...))`，
   而非本提案早期示例的双 form）
4. 聚合渲染 = 仅 query block ✅
5. Automation 条件一步切换，无长期兼容期 ✅（旧条件评估时确定性转换）

目标：让 supertag 的查询语法达到 logseq v1 simple/advanced query 的
日常功能水平。写侧已有 Automation 兜底，本提案只动读侧语法。

现状事实（代码核实）：

- 查询语法（`doc/QUERY.md`）：`and/or/not`、`tag`、`field`（精确相等）、
  `term`、`after/before/between`、`recent-days/in-month/in-year`。
- 数据已就绪：node projection 已含 `:todo`（org todo-keyword）与
  `:priority`（org priority cookie），extractor 在提取，无数据侧工作。
- 聚合：查询 parser/executor 已把聚合实现为结果修饰符，计算委托
  `supertag-rollup-apply`（count/sum/avg/min/max/first/last/
  unique-count/concat）。
- 排序：query block 的 `:sort/:order` header 参数，不在语法内。
- Automation trigger 分两层：事件类型（`:on-tag-added/:on-change/
  :on-schedule`）+ 条件语言（`has-tag/has-any-tag/field-equals/
  property-equals/property-changed` + `and/or/not`）。条件语言与查询语法
  是两套平行实现。

---

## 提案 A：simple query 补齐

### A1 `(task STATE...)` — todo 状态过滤

```elisp
(task "TODO")                     ;; 单个状态
(task "TODO" "DOING")             ;; 多参数 = OR
(and (task "TODO") (priority "A"))
```

- 语义：匹配 node `:todo` 字段等于任一参数（大小写敏感，与 org
  todo-keyword 一致）；无 todo 状态的 node（普通 heading）不匹配。
- 与 logseq 对齐：`(task now later)` 多参数 OR 语义一致。
- 改动面：query 语法 +1 操作符；执行时读 `:todo` plist 值。数据已就绪。
- 验证：todo 在/不在、多状态 OR、与 `(not (task ...))` 组合。

### A2 `(priority P...)` — 优先级过滤

```elisp
(priority "A")                    ;; [#A] cookie
(priority "A" "B")                ;; 多参数 = OR
```

- 语义：匹配 node `:priority` 字段（org 存 A/B/C，大小写不敏感匹配）。
- 改动面：同上，读 `:priority`。

### A3 日期符号与单位补齐

```elisp
(between "-7d" "today")
(after "yesterday")
(before "tomorrow")
(after "-4h")                     ;; 补 h 单位
(between "-30min" "now")          ;; 补 min 单位
```

- `today/yesterday/tomorrow` 解析为**当天 00:00**（`today` = 今天 00:00，
  `after "today"` 表示今天零点之后，与 logseq 的"journal 页引用"语义近似）。
- 相对单位补 `h`（小时）与 `min`（分钟）；月/年近似保持现状（30 天 / 365.25 天）。
- 改动面：`supertag-query--resolve-date-string` 扩展，全部日期操作符受益。
- 拍板点：`today` 是"今天 00:00"还是"明天 00:00"（即 `between today tomorrow`
  是否覆盖今天整天）？建议前者，文档写明。

### A4 `not` 多参数

```elisp
(not (tag "archived") (tag "done"))   ;; = (not (or (tag "archived") (tag "done")))
```

- logseq 语义：`(not a b)` 排除所有。单参数行为不变，向后兼容。
- 改动面：parser 放开 not 的参数校验。

### A5 `sort-by` 入语法

```elisp
(and (tag "task") (sort-by "created" desc))
(and (tag "book") (sort-by "pages" asc))
```

- 与 query block 的 `:sort/:order` header 并存；**语法内优先**，header 保留。
- 保留现有"缺失排序键排最后"语义。
- 拍板点：`created/modified/title` 这类内置键与字段名在同一命名空间
  （现状 query block 就是如此），确认沿用。

### A6 动态变量 `<%today%>`（及变量集合）

```elisp
(and (task "TODO") (after "<%today%>"))
```

- v1 只做 `<%today%>`（journal/capture 模板最常用）。
- 候选扩展（后续再议）：`<%yesterday%>`、`<%tomorrow%>`、`<%current-tag%>`。
- 实现：查询文本在解析前做变量替换（同公式的 placeholder 翻译路径）。
- 拍板点：v1 是否只收 `<%today%>`？

---

## 提案 B：聚合入语法

对应 logseq advanced query 的 `:find (sum ?v)` 主力用途。复用现有
`supertag-rollup-apply` 词汇表（count/sum/avg/min/max/first/last/
unique-count/concat）。

### 语法形态：尾部修饰符

```elisp
;; 标量结果
(and (tag "book") (field "status" "reading")) (sum "pages")

;; 分组表
(and (tag "book")) (group-by "genre") (sum "pages")
```

- 聚合/分组子句只允许出现在查询**尾部**，不参与过滤。
- 有聚合时结果不再是 node 列表，而是标量或 (分组键 . 聚合值) 列表；
  query block 以单行表渲染。
- 缺失/非数值字段：沿用现有查询聚合修饰符语义
  （sum 对非数值集合返回 nil 而非报错）。
- 改动面：parser 允许尾部子句；执行器把过滤结果交给
  `supertag-query--apply-modifiers`，无需平行查询引擎。
- 拍板点：
  1. 尾部修饰符形态 vs logseq 的 `:find (sum ?v)` 前缀形态？（建议尾部，
     与现有 sexp 风格连续，且 logseq 的前缀形态是其 Datalog 历史包袱）
  2. 聚合结果在 Table/Stream 视图里怎么显示，还是仅 query block 支持？

---

## 提案 N：Automation trigger 条件统一

现状：trigger 的事件类型（`:on-tag-added` 等）与条件语言是两套；条件语言
（`has-tag/field-equals/...`）与查询语法也是两套。本提案只统一**状态条件**。

### 关键区分：事件条件 ≠ 状态条件

- **状态条件**（node 当前满足 X）：`has-tag`、`field-equals`、`property-equals`
  → 可用查询语法表达。
- **事件条件**（"发生了什么"）：`property-changed`、trigger 事件类型本身
  （`:on-tag-added`）→ 查询语法无法表达，保留 Automation 独有。

### 提案：`:condition` 直接接受查询语法

```elisp
;; 旧写法（保留，兼容期）
(:trigger :on-change
 :condition '(:and (:tag "project") (:field-equals "status" "stale")))

;; 新写法（同一条查询，两边通用）
(:trigger :on-change
 :condition '(and (tag "project") (field "status" "stale")))
```

- 实现：`:condition` 解析时按查询语法尝试；旧条件语法作为 fallback
  保留（内部转成同一 AST 或两套评估器并存一段时间）。
- 收益：用户在 query block 里验证过的查询可直接粘进 Automation 条件，
  心智模型收敛到一套语言。
- 语义映射（fallback 需要）：
  `has-tag`→`(tag ...)`、`has-any-tag`→`(or (tag ...) ...)`、
  `field-equals`→`(field ...)`、`property-equals` 的 keyword 分支
  （读 node 顶层 plist 属性）在查询语法中无对应 → 该分支保留旧语法。
- 拍板点：
  1. 兼容期策略：旧条件语法保留多久（建议：新语法先落地 + 文档标记，
     旧语法在 phase 内不删，观察一个版本）？
  2. `property-changed` 类事件条件不纳入本提案，确认？

---

## 建议顺序与拆包

| 包 | 内容 | 依赖 | 规模 |
|---|---|---|---|
| 包 1 | A1+A2+A4（task/priority/not 多参） | 无（数据就绪） | 小 |
| 包 2 | A3+A5+A6（日期符号/单位、sort-by、<%today%>） | 包 1 | 中 |
| 包 3 | B（聚合/分组语法） | 包 1 | 中 |
| 包 4 | N（Automation 条件统一） | 包 1-3 落地后 | 中 |

每个包独立验证、独立提交，符合 phase 原子任务规范。
