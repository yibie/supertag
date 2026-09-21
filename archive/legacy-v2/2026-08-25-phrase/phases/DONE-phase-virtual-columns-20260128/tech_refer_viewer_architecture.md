# Tech Refer: Viewer 架构技术调研

## 调研目标

为 org-supertag 设计一个可扩展的 Viewer 架构，支持用户自定义数据展示方式。

## 核心问题

1. 什么是 Viewer？与现有 Table View 的区别？
2. 如何设计注册机制？
3. 如何与虚拟列系统集成？
4. 配置 DSL 应该采用什么形式？

## 技术选项分析

### 选项1: 函数注册式（类似 major-mode）

```elisp
(supertag-viewer-register
 :id 'progress-board
 :name "Progress Board"
 :render-fn #'my-render-fn)
```

**优点**: 
- 简单直接
- 完全可编程
- Emacs 风格

**缺点**:
- 需要会写 Elisp
- 配置与代码混合

### 选项2: 声明式 DSL（类似 Org 的 #+关键字）

```elisp
(supertag-viewer-define
  :name "Project Dashboard"
  :type :dashboard
  :source (:tag "project")
  :layout ...)
```

**优点**:
- 用户友好
- 配置即代码
- 易于分享

**缺点**:
- DSL 设计复杂
- 需要解析器

### 选项3: 模板继承式（类似 HTML 模板）

```elisp
(defviewer project-board
  :extends 'base-table
  :columns '(title progress deadline)
  :transform #'calc-progress)
```

**优点**:
- 复用性强
- 层级清晰

**缺点**:
- 继承关系复杂

## 参考实现

### 参考1: Org-mode 的 Block 系统

```org
#+BEGIN: my-block :param value
...
#+END:
```

启示：动态块可以自定义渲染

### 参考2: Emacs Dashboard

插件 `dashboard` 使用 widgets 组合模式：
- banner
- recent files
- agenda

启示：widget-based 组合

### 参考3: Notion 的 View 系统

- Table View
- Board View (Kanban)
- Gallery View
- Calendar View
- Timeline View

启示：同一数据，多种视图

## Viewer 与现有组件的关系

```
Data Layer
├── Nodes (org headings)
├── Tags (#project, #task)
├── Relations (parent/child)
└── Virtual Columns (computed fields)

View Layer
├── Table View (现有) - 通用表格
├── Kanban View (现有) - 看板
└── Custom Viewers (新增) - 专用视图
    ├── Progress Board
    ├── Effort Distribution
    └── User-defined views
```

## 数据流设计

```
User selects viewer
       ↓
Viewer queries data (via virtual columns API)
       ↓
Data is transformed (aggregation, filtering)
       ↓
Render engine generates display
       ↓
User interacts (drill-down, refresh)
```

## 关键技术决策

### 决策1: 渲染方式

- **选项A**: 纯文本（类似 Table View）
- **选项B**: Org-mode 格式（可编辑）
- **选项C**: 专用 buffer（类似 Magit）

**倾向**: 选项C，提供更好的交互体验

### 决策2: 数据查询

- **选项A**: 直接使用 supertag-query
- **选项B**: 通过虚拟列抽象层
- **选项C**: 专用 viewer query DSL

**倾向**: 选项B，利用已建成的虚拟列系统

### 决策3: 配置存储

- **选项A**: 保存在 Emacs 变量（当前 session）
- **选项B**: 保存在 org-supertag 数据库
- **选项C**: 保存在用户配置文件

**倾向**: 选项B，便于跨设备同步

## 推荐的实现路径

### Phase 1: 基础框架
1. 创建 `supertag-viewer.el`
2. 实现注册/列表 API
3. 做一个最简单的 viewer（文本列表）

### Phase 2: 内置 Viewers
1. Progress Board
2. Effort Distribution
3. 验证框架可用性

### Phase 3: 高级功能
1. DSL 设计
2. 交互功能（钻取、过滤）
3. 分享/导入 viewer 配置

## 需要进一步调研的问题

1. 用户真的需要自定义 viewer 吗？还是几个内置模板就够了？
2. 性能考虑：大数据量下的渲染策略
3. 与现有 Table View 的关系：是替代还是共存？
4. 移动端/其他编辑器兼容性考虑

## 建议的下一步

1. 创建 `spec_viewer_architecture.md` - 详细功能规划
2. 用户调研 - 了解真实使用场景
3. 原型验证 - 做一个最简单的 viewer 验证思路

---

**调研日期**: 2026-01-28  
**状态**: 初步技术调研完成，需要进一步规划和验证
