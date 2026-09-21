# ADR: 虚拟列架构决策

## Status
Proposed

## Context
用户需要一种机制来定义**派生数据**——基于现有字段计算得出的值，而不是直接存储的值。这类似于数据库中的计算列、Airtable 的公式字段，或 Excel 的公式单元格。

## Decision

### 1. 虚拟列是只读的
**决策**: 虚拟列只能读取，不能通过虚拟列修改原始数据。

**理由**:
- 简化数据流：原始数据 → 虚拟列（单向）
- 避免循环依赖和一致性难题
- 符合函数式数据转换范式

**后果**: 用户必须通过原始字段或 automation 修改数据。

### 2. 惰性计算 + 缓存
**决策**: 虚拟列在首次访问时计算，结果缓存，依赖变化时标记为 dirty。

**理由**:
- 避免不必要的计算（大数据量场景）
- 平衡实时性和性能
- 允许批量更新时延迟刷新

**实现要点**:
```elisp
(defstruct supertag-virtual-column-cache
  value
  computed-at
  dependencies  ; 依赖的字段/节点列表
  dirty-flag)
```

### 3. 虚拟列不存储在 org 文件中
**决策**: 虚拟列数据存储在 supertag 数据库中，不写入 org 文件。

**理由**:
- 保持 org 文件简洁（纯文本优先）
- 虚拟列可随时重新计算
- 避免版本控制冲突

**例外**: 提供显式导出功能，可将虚拟列数据写入 org properties（用于外部工具）。

### 4. 混合 Viewer 架构
**决策**: 同时支持配置式（YAML/JSON 风格）和脚本式（Emacs Lisp）Viewer 定义。

**理由**:
- 配置式：降低门槛，80% 场景够用
- 脚本式：最大灵活性，高级用户需要
- 渐进复杂度：从模板开始，逐步自定义

**API 设计**:
```elisp
;; 配置式
(supertag-viewer-define-from-config
 '(:name "Simple Table"
   :type :table
   :columns ("title" (:virtual "progress"))))

;; 脚本式
(supertag-viewer-register
 :id 'custom-view
 :render-fn #'my-custom-render)
```

### 5. Formula 语法简化
**决策**: Formula 使用类 Lisp 语法（S-expression），而非类 Excel 语法。

**理由**:
- Emacs 用户熟悉 Lisp 语法
- 易于解析（Emacs 内置 `read`）
- 与 Elisp 生态无缝集成

**示例**:
```elisp
(+ effort (* urgency 2))                    ; 基础运算
(/ (count-where status "done") total 100)  ; 函数调用
```

## Alternatives Considered

| 方案 | 优点 | 缺点 | 决策 |
|------|------|------|------|
| 实时计算 | 数据最新 | 性能差，大数据量卡顿 | 拒绝 |
| 存储在 org 文件 | 纯文本完整 | 文件臃肿，冲突多 | 拒绝 |
| 类 Excel 公式 | 大众熟悉 | Emacs 用户不适应 | 拒绝 |
| 仅脚本式 Viewer | 最大灵活 | 门槛高 | 拒绝 |

## Consequences

### Positive
- 清晰的数据流模型
- 良好的性能和可扩展性
- 渐进式学习曲线

### Negative
- Formula 语法对非程序员有门槛
- 缓存一致性需要仔细测试
- 需要额外的导出步骤才能与外部工具共享虚拟列数据

## Related Decisions
- [Automation System](adr_automation.md): Automation 操作原始数据，虚拟列消费数据
- [Global Fields](adr_global_fields.md): 虚拟列可能依赖全局字段
