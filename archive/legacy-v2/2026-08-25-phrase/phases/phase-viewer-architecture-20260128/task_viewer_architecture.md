# Viewer 架构任务列表

## 阶段信息

- **阶段名称**: phase-viewer-architecture-20260128
- **目标**: 为 org-supertag 构建可扩展的自定义 Viewer 系统
- **依赖**: 虚拟列系统 (phase-virtual-columns-20260128)
- **状态**: 规划中

## 文档索引

- `tech_refer_viewer_architecture.md` - 技术调研
- `spec_viewer_architecture.md` - 详细功能规格
- `task_viewer_architecture.md` - 本文件

## Milestone 1: 基础框架

### task001 [x] View Framework Core (COMPLETE)
**产出**: `supertag-view-framework.el` (300+ 行)
**验证**: ✅ 所有 API 函数通过测试
**实现**:
- ✅ `supertag-view-register` - 底层注册 API
- ✅ `supertag-view-unregister` - 注销
- ✅ `supertag-view-get/list/list-for-tag` - 查询
- ✅ `supertag-view-render` - 渲染
- ✅ `define-supertag-view` - 开发者宏（一行定义 view）
- ✅ 渲染工具包 - header, progress-bar, stat-row, separator
- ✅ 数据访问工具 - get-vc, get-global-field
- ✅ 交互式命令 - select-and-render, list-interactive
**测试**: `test/view-framework-test.el` (16+ 测试)
**示例**: `supertag-view-examples.el` (3 个示例 views)

### task002 [x] View Examples (COMPLETE)
**产出**: `supertag-view-examples.el` 示例集
**验证**: ✅ 使用 `define-supertag-view` 宏创建了 3 个示例
**实现**:
- ✅ `text-list` - 简单文本列表（基础示例）
- ✅ `stats-summary` - 统计摘要（工具函数示例）
- ✅ `progress-dashboard` - 进度看板（虚拟列集成示例）
- ✅ `supertag-view-examples-demo` - 演示函数
- ✅ `supertag-view-insert-template` - 开发者模板插入
**使用方法**:
- `M-x supertag-view-examples-demo` 查看演示
- `M-x supertag-view-insert-template` 插入模板

### task003 [x] View Selector Integration (COMPLETE)
**产出**: Schema View 中的 view 选择快捷键
**验证**: ✅ 按 `v v` 弹出 view 选择列表
**实现**:
- ✅ 在 `supertag-view-schema.el` 中添加 `v v` 绑定
- ✅ 创建 `supertag-view-select-from-schema` 函数
- ✅ 更新帮助文档
**依赖**: `supertag-view-framework.el`
**使用方法**:
- `M-x supertag-view-schema`
- 按 `v v` 选择 view
- 或 `M-x supertag-view-select-from-schema`

## Milestone 2: 内置 Viewers

### task004 [x] Progress Dashboard (COMPLETE)
**产出**: `supertag-view-progress-dashboard.el` (200+ lines)
**验证**: ✅ 完整功能，集成虚拟列
**功能**:
- 从数据库获取项目数据
- 集成虚拟列 (progress, total-tasks, done-tasks, total-effort)
- 进度条可视化 + 状态标记
- 统计摘要 + 表格格式
**演示**: `M-x supertag-view-progress-dashboard-demo`

### task005 [x] Effort Distribution (COMPLETE)
**产出**: `supertag-view-effort-distribution.el` (180+ lines)
**验证**: ✅ 完整功能，自动分组
**功能**:
- 按状态分组 (done, in-progress, todo)
- 按相关标签分组
- 文本条形图 + 百分比
- 洞察分析
**演示**: `M-x supertag-view-effort-distribution-demo`
**用户场景**: 个人工作量分析（Bob 的场景）

### task006 [x] Priority Matrix (COMPLETE)
**产出**: `supertag-view-priority-matrix.el` (220+ lines)
**验证**: ✅ 完整功能，自动分类
**功能**:
- Eisenhower 矩阵（DO, PLAN, DELEGATE, DELETE）
- 从 urgency/importance 字段计算
- 从 deadline/priority 智能推断
- 四象限按优先级排序
- 使用指南
**演示**: `M-x supertag-view-priority-matrix-demo`

## Milestone 3: 高级功能

### task007 [x] 配置持久化 (COMPLETE)
**产出**: 配置保存/加载系统
**实现**:
- `supertag-view-config-register` - 注册配置（不含 render-fn）
- `supertag-view-config-get/list` - 查询配置
- `supertag-view-config-export-elisp` - 导出为 Elisp
- `supertag-view-config-save-to-file` - 保存到文件
- `supertag-view-config-load-from-file` - 从文件加载
**存储格式**: Elisp S-expression（可直接加载执行）
**影响范围**: `supertag-view-framework.el`

### task008 [x] Widget 系统 (COMPLETE)
**产出**: Widget 注册和渲染系统
**实现**:
- `supertag-widget-register` - 注册 widget 类型
- `supertag-widget-render` - 渲染 widget
- 内置 widgets: `:header`, `:text`, `:progress-bar`, `:stats-row`
- Widget 可以组合创建复杂视图
**集成**: 已整合到 `supertag-view-framework.el`

### task009 [x] Viewer DSL (基础) (COMPLETE)
**产出**: `supertag-view-define-from-config` 函数
**实现**:
- 从声明式配置创建 view
- 使用 widget 组合布局
- 配置可保存到 `supertag--view-configs`
- 支持 `:id`, `:name`, `:tag`, `:widgets`
**验证**:
```elisp
(supertag-view-define-from-config
 '(:id dsl-example
   :name "DSL Example"
   :tag "demo"
   :widgets ((:type :header :text "Title")
             (:type :progress-bar :value 65))))
```
**演示**: `M-x supertag-view-dsl-example`
**集成**: `supertag-view-framework.el`

## Milestone 4: 测试与文档 (COMPLETE)

### task010 [x] 测试套件 (COMPLETE)
**产出**: `test/view-framework-test.el` (199 行，16+ 测试)
**覆盖**: 注册、注销、查询、渲染、widgets、宏
**命令**: `M-x test-view-framework-manual` 手动测试

### task011 [x] 示例和演示 (COMPLETE)
**产出**: `supertag-view-examples.el` (151 行)
**包含**: 3 个示例 views + `supertag-view-insert-template`
**演示**: 
- `M-x supertag-view-examples-demo`
- `M-x supertag-view-progress-dashboard-demo`
- `M-x supertag-view-effort-distribution-demo`
- `M-x supertag-view-priority-matrix-demo`
- `M-x supertag-view-dsl-example`

### task012 [x] 开发者文档 (COMPLETE)
**产出**: 
- `doc/VIEW_FRAMEWORK_DEV_GUIDE.md` - 开发者指南
- `doc/VIEWER_CUSTOM_GUIDE.md` - 自定义 view 指南
- `PHASE_SUMMARY.md` - 阶段总结
- `tech_refer_viewer_architecture.md` - 技术调研
- `spec_viewer_architecture.md` - 功能规格

## 任务依赖图

```
task001 (注册 API)
    ├── task002 (Text-List Viewer) ──→ task010 (测试)
    ├── task003 (选择器)
    │
    ├── task004 (Progress Board) ───→ task011 (演示)
    ├── task005 (Effort Distribution)
    ├── task006 (Priority Matrix)
    │
    ├── task007 (配置持久化)
    │       └── task008 (Widget 系统)
    │               └── task009 (DSL)
    │
    └── task012 (文档)
```

## 建议的开发顺序

### Phase 1: 验证框架 (1-2 周)
1. task001 - 注册 API
2. task002 - Text-List Viewer（验证框架）
3. task003 - 选择器
4. task010 - 基础测试

### Phase 2: 内置 Viewers (2-3 周)
5. task004 - Progress Board
6. task005 - Effort Distribution
7. task006 - Priority Matrix
8. task011 - 演示

### Phase 3: 高级功能 (可选, 2-3 周)
9. task007 - 配置持久化
10. task008 - Widget 系统
11. task009 - DSL
12. task012 - 完整文档

## 风险评估

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| 用户需求不明确 | 中 | 高 | Phase 1 后收集反馈 |
| DSL 设计不当 | 中 | 高 | DSL 放到 Phase 3 |
| 性能问题 | 低 | 高 | 复用虚拟列缓存 |
| 与现有 UI 冲突 | 低 | 中 | 渐进式集成 |

## 待决策问题

1. **Viewer 是否支持嵌套？**（如看板中的卡片再显示子看板）
2. **是否支持 viewer 组合？**（一个页面显示多个 viewer）
3. **实时刷新还是手动刷新？**
4. **是否支持导出（图片/PDF）？**

---

**创建日期**: 2026-01-28  
**前一阶段**: DONE-phase-virtual-columns-20260128
