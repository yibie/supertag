# 虚拟列系统开发计划

## Milestones

### Milestone 1: 核心基础设施（Week 1-2）
**目标**：虚拟列存储、计算引擎、缓存机制

**Deliverables**:
- [ ] 虚拟列 schema 定义 (`supertag-virtual-column-create/get/update/delete`)
- [ ] 惰性计算引擎 (`supertag-virtual-column--compute`)
- [ ] 多级缓存系统 (`supertag-virtual-column--cache-get/put/invalidate`)
- [ ] 依赖追踪 (`supertag-virtual-column--track-dependencies`)

**验证方式**:
```elisp
;; 测试 Rollup 计算
(let ((vc (supertag-virtual-column-create
           '(:name "total-effort"
             :type :rollup
             :params (:relation "children" :field "effort" :function :sum)))))
  (supertag-virtual-column-get "node-123" (plist-get vc :id)))
;; => 42
```

### Milestone 2: 虚拟列类型实现（Week 3-4）
**目标**：Rollup、Formula、Aggregate、Reference

**Deliverables**:
- [ ] Rollup 类型：支持 SUM, COUNT, AVG, MAX, MIN
- [ ] Formula 类型：表达式解析器（支持基础运算符和函数）
- [ ] Aggregate 类型：跨节点统计
- [ ] Reference 类型：跨节点字段引用

**验证方式**:
- 创建包含 100 个子任务的测试项目，Rollup 计算 < 100ms
- Formula 支持 `(+ a (* b 2))` 复杂表达式

### Milestone 3: UI 集成（Week 5-6）
**目标**：Schema View 集成、Table View 支持

**Deliverables**:
- [ ] Schema View 快捷键 `v c` 创建虚拟列
- [ ] Table View 显示虚拟列（动态列）
- [ ] 虚拟列配置 UI（类似 field 编辑界面）
- [ ] 缓存刷新按钮

**验证方式**:
- 5 分钟完成：创建 Rollup → 查看数据 → 添加到 Table View

### Milestone 4: Viewer 架构（Week 7-8）
**目标**：开放 Viewer 注册、内置模板

**Deliverables**:
- [ ] Viewer 注册 API (`supertag-viewer-register`)
- [ ] 内置模板：Progress Board、Effort Distribution、Timeline
- [ ] 自定义 Viewer DSL（简化配置）
- [ ] Viewer 选择器 (`v v`)

**验证方式**:
```elisp
;; 注册自定义 Viewer
(supertag-viewer-register
 :id 'my-dashboard
 :name "My Dashboard"
 :render-fn #'my-render-fn)
```

## Scope

### In Scope
- 4 种核心虚拟列类型
- Table/Kanban View 集成
- 3 个内置 Viewer 模板
- 配置式 Viewer 定义
- 缓存和性能优化

### Out of Scope (Future)
- 双向绑定（虚拟列修改原始数据）
- 实时协作（多用户同时编辑）
- 外部 Viewer runtime（JavaScript/Python）
- 机器学习驱动的智能虚拟列

## Priorities

| Priority | Feature | Rationale |
|----------|---------|-----------|
| P0 | Rollup + Formula | 解决 80% 用户场景 |
| P0 | Table View 集成 | 立即可用性 |
| P1 | 缓存机制 | 性能保障 |
| P1 | Progress Board Viewer | 演示价值 |
| P2 | Aggregate + Reference | 进阶需求 |
| P2 | Effort Distribution | 补充场景 |
| P3 | Timeline/Gantt | 复杂可视化 |
| P3 | Custom Viewer DSL | 高级用户 |

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Formula 表达式解析复杂 | Medium | High | 使用现有库 `calc` 或简化语法 |
| 循环依赖检测遗漏 | Low | High | 完善的单元测试，计算时检测 |
| 性能不达标（大数据量） | Medium | Medium | 早期性能测试，异步计算 |
| 与现有 automation 冲突 | Low | High | 明确边界，automation 只写原始数据 |

## Rollback Plan

若需回滚：
1. 虚拟列数据可导出为普通 properties（提供迁移脚本）
2. Viewer 回退到内置 Table/Kanban
3. 保留 schema 定义，仅禁用计算引擎
