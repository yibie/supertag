# Spec: Viewer 架构功能规划

## 1. 概述

### 1.1 什么是 Viewer？

Viewer 是 org-supertag 的数据可视化组件，用于以特定方式展示标签数据。与通用的 Table View 不同，Viewer 专注于特定的数据展示场景（如进度看板、分布图表等）。

### 1.2 为什么需要 Viewer？

**现有问题**:
- Table View 过于通用，无法直观展示某些特定数据
- 用户需要频繁进行 mental math（如计算完成百分比）
- 缺乏高级管理层视角的汇总视图

**解决价值**:
- 一眼可见项目健康状况
- 自动化数据聚合和可视化
- 支持决策的数据洞察

### 1.3 目标用户

| 用户类型 | 使用场景 | 优先级 |
|---------|---------|--------|
| 项目经理 | 查看所有项目进度 | 高 |
| 个人用户 | 工作量分布分析 | 中 |
| 团队 lead | 资源分配概览 | 高 |
| 数据分析师 | 自定义统计报表 | 低 |

## 2. 用户场景

### 场景 1: 周会前的项目回顾

**人物**: 项目经理 Alice
**场景**: 每周五需要向管理层汇报项目进展
**当前痛点**: 
- 需要手动收集各项目数据
- 在多个 Org 文件间切换
- 计算完成百分比

**期望的 Viewer**:
```
Project Status Dashboard
========================

Project A        [████████░░] 80%  On Track
  Budget: $80K/$100K, Tasks: 16/20
  
Project B        [████░░░░░░] 40%  At Risk ⚠️
  Budget: $20K/$50K, Tasks: 4/10
  
Project C        [██████████] 100% Done ✓
  Budget: $30K/$30K, Tasks: 8/8
```

### 场景 2: 个人工作量分析

**人物**: 开发者 Bob
**场景**: 月底回顾时间分配
**当前痛点**:
- 不知道时间花在哪些类型任务上
- 难以评估工作效率

**期望的 Viewer**:
```
Effort Analysis - January 2026
==============================

By Project:
  Project A    ████████████████████ 45%
  Project B    ██████████████░░░░░░ 32%
  Misc         ███████░░░░░░░░░░░░░ 23%

By Status:
  Done         ████████████████████ 60%
  In Progress  ████████░░░░░░░░░░░░ 25%
  Blocked      ███░░░░░░░░░░░░░░░░░ 15%

Total Effort: 200 hours
```

### 场景 3: 任务优先级矩阵

**人物**: 团队 lead Carol
**场景**: 每天早上确定今日工作重点
**期望的 Viewer**:
```
Priority Matrix
===============

        Urgency
        Low    High
       ┌──────┬──────┐
I High │ Plan │  Do  │
M      │  5   │  8   │
P      ├──────┼──────┤
O Low  │Defer │Delegate│
R      │  12  │  3   │
T      └──────┴──────┘
```

## 3. 功能需求

### 3.1 必须实现 (MVP)

- [ ] Viewer 注册 API
- [ ] 内置 Progress Board
- [ ] 在 Schema View 中选择 Viewer (`v v`)
- [ ] 使用虚拟列作为数据源

### 3.2 应该实现 (Phase 2)

- [ ] Effort Distribution viewer
- [ ] 自定义 viewer 配置保存
- [ ] 基础 DSL
- [ ] 导出功能（文本/截图）

### 3.3 可以延后 (Future)

- [ ] 完整 DSL
- [ ] 交互式过滤/钻取
- [ ] 图表类型扩展
- [ ] 第三方 viewer 插件

## 4. 功能规格

### 4.1 Viewer 注册 API

```elisp
;; 基础注册
(supertag-viewer-register
 :id 'progress-board
 :name "Progress Board"
 :description "Project progress overview"
 :category :project-management
 :render-fn #'supertag-viewer--render-progress-board
 :valid-for '("project"))  ;; 适用于哪些 tag

;; 取消注册
(supertag-viewer-unregister 'progress-board)

;; 列出所有 viewers
(supertag-viewer-list)
;; => ((:id progress-board :name "Progress Board" ...))

;; 列出适用于特定 tag 的 viewers
(supertag-viewer-list-for-tag "project")
```

### 4.2 渲染接口

```elisp
;; 所有 render-fn 接收统一的 context
(defun supertag-viewer--render-progress-board (context)
  "Render progress board with CONTEXT."
  (let* ((tag (plist-get context :tag))
         (nodes (plist-get context :nodes))
         (virtual-columns (plist-get context :virtual-columns)))
    ;; 渲染逻辑
    ))
```

### 4.3 UI 集成

**Schema View 快捷键**:
```
v v    - 选择并打开 Viewer
```

**流程**:
1. 用户在 Schema View 选中一个 tag
2. 按 `v v`
3. 显示适用于该 tag 的 viewer 列表
4. 选择后在新 buffer 中打开

### 4.4 内置 Viewer: Progress Board

**输入**: tag (e.g., "project")
**输出**: 进度看板

**显示内容**:
- 项目名称
- 进度条（基于虚拟列计算）
- 关键指标（总任务、已完成、剩余工作量）
- 状态标记（正常/风险/延期）

**需要的虚拟列**:
```elisp
;; 假设用户已创建这些虚拟列
:progress     ; Formula: (done / total) * 100
:total-tasks  ; Rollup: count children
:done-tasks   ; Rollup: count done children
:total-effort ; Rollup: sum effort
```

**降级策略**:
如果虚拟列不存在，显示 "N/A" 并提示用户创建。

### 4.5 内置 Viewer: Effort Distribution

**输入**: tag + 分组维度
**输出**: 文本图表

**分组维度**:
- by-tag
- by-status
- by-priority
- by-assignee

**显示格式**:
```
Distribution by Status
======================
Done         ████████████████████ (120h, 60%)
In Progress  ████████░░░░░░░░░░░░ (50h, 25%)
Todo         █████░░░░░░░░░░░░░░░ (30h, 15%)
             └───────┬──────────┘
                Total: 200h
```

## 5. 与虚拟列的关系

### 5.1 数据依赖

Viewer 依赖虚拟列提供计算数据：

```
Viewer Layer
    ↓ (读取)
Virtual Columns
    ↓ (计算)
Raw Data (Nodes/Fields/Relations)
```

### 5.2 典型配置

**为 Progress Board 准备数据**:

```elisp
;; 1. 创建必要的虚拟列
(supertag-virtual-column-create
 (list :id "progress-percent"
       :name "Progress %"
       :type :formula
       :params (list :formula "(done / total) * 100")))

(supertag-virtual-column-create
 (list :id "total-effort"
       :name "Total Effort"
       :type :rollup
       :params (list :relation "children"
                     :field "effort"
                     :function :sum)))

;; 2. 打开 Progress Board
;; M-x supertag-view-schema
;; 选中 #project
;; 按 v v 选择 "Progress Board"
```

## 6. 配置 DSL (Phase 2)

### 6.1 基础语法

```elisp
(supertag-viewer-define
  :name "My Dashboard"
  :for "project"  ;; 适用于哪个 tag
  :widgets
  '((:type :header
     :title "Project Status")
    
    (:type :progress-bar
     :source (:virtual-column "progress-percent")
     :label "Completion")
    
    (:type :stats-row
     :items ((:vc "total-tasks" :label "Total")
             (:vc "done-tasks" :label "Done")
             (:vc "remaining-tasks" :label "Left")))
    
    (:type :table
     :columns ("title" "deadline" "progress-percent"))))
```

### 6.2 Widget 类型

| Widget | 用途 |
|--------|------|
| `:header` | 标题 |
| `:progress-bar` | 进度条 |
| `:stats-row` | 统计数字行 |
| `:table` | 数据表格 |
| `:chart-bar` | 条形图 |
| `:chart-pie` | 饼图（文本版）|

## 7. 验收标准

### 7.1 task014 - Viewer 注册 API

```elisp
;; 测试用例
(supertag-viewer-register 
 :id 'test-viewer
 :name "Test Viewer"
 :render-fn #'ignore)

(member 'test-viewer (mapcar #'car (supertag-viewer-list)))
;; => t

(supertag-viewer-unregister 'test-viewer)
(null (member 'test-viewer (mapcar #'car (supertag-viewer-list))))
;; => t
```

### 7.2 task016 - Progress Board

- [ ] 能显示至少 3 个项目
- [ ] 进度条基于虚拟列计算
- [ ] 显示总/已完成/剩余任务数
- [ ] 在无虚拟列时优雅降级

### 7.3 task015 - Viewer 选择器

- [ ] 按 `v v` 弹出选择列表
- [ ] 列表显示 viewer 名称和描述
- [ ] 选择后正确渲染

## 8. 开发计划

### Phase 1: 基础 (2-3 天)
- [ ] task014: Viewer 注册 API
- [ ] 创建一个最简单的 text-list viewer 验证框架

### Phase 2: 内置 Viewers (3-5 天)
- [ ] task016: Progress Board
- [ ] task017: Effort Distribution
- [ ] task015: Viewer 选择器

### Phase 3: DSL (可选, 5-7 天)
- [ ] task018: Viewer DSL

## 9. 风险评估

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| DSL 设计不当 | 中 | 高 | Phase 1 不做 DSL，先验证核心需求 |
| 性能问题 | 低 | 高 | 利用虚拟列缓存机制 |
| 用户需求不明确 | 中 | 中 | 先做 MVP 收集反馈 |

## 10. 待决策问题

1. **Viewer 是否支持嵌套？**（如看板中的卡片再显示子看板）
2. **是否支持 viewer 组合？**（一个页面显示多个 viewer）
3. **实时刷新还是手动刷新？**
4. **Viewer 配置存储在哪里？**（变量/数据库/Org 文件属性）

---

**状态**: 规划中  
**建议**: 先实现 MVP（task014 + 简单 viewer），验证用户需求后再继续
