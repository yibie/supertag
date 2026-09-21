# Tech Refer: 可视化配置 Viewer 的可行性研究

## 问题定义

目标：让用户通过图形界面（而非代码）创建和配置 Viewer。

约束：必须在 Emacs 环境中运行。

## 技术方案分析

### 方案 1: Widget-based 表单配置

使用 Emacs 的 `widget.el` 创建交互式表单。

**示例界面**:
```
Configure Viewer: My Dashboard
================================

Name: [My Dashboard        ]
Type: [Progress Board    [v]]
Applies to tag: [project    ]

[ ] Use virtual columns
    Virtual columns: [total-effort, progress, ...]

Widgets to display:
  [x] Progress bar
      Field: [progress      ]
  [ ] Statistics row
  [x] Data table

[ Save ] [ Cancel ] [ Preview ]
```

**实现方式**:
```elisp
(defun supertag-viewer-configure-widget ()
  "Open widget-based viewer configuration."
  (interactive)
  (switch-to-buffer "*Configure Viewer*")
  (kill-all-local-variables)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (widget-insert "Configure Viewer\n")
  (widget-insert "================\n\n")
  
  ;; Name field
  (widget-create 'editable-field
                 :size 40
                 :value "My Viewer"
                 :notify (lambda (widget &rest _)
                          (message "Name: %s" (widget-value widget)))
                 "Name: ")
  (widget-insert "\n\n")
  
  ;; Type selection
  (widget-create 'menu-choice
                 :value 'text-list
                 :notify (lambda (widget &rest _)
                          (message "Type: %s" (widget-value widget)))
                 '(item :tag "Text List" :value text-list)
                 '(item :tag "Progress Board" :value progress-board)
                 '(item :tag "Chart" :value chart))
  
  ;; Buttons
  (widget-insert "\n\n")
  (widget-create 'push-button
                 :notify (lambda (&rest _)
                          (message "Saving..."))
                 "Save")
  (widget-insert " ")
  (widget-create 'push-button
                 :notify (lambda (&rest _)
                          (kill-buffer))
                 "Cancel")
  
  (use-local-map widget-keymap)
  (widget-setup)
  (goto-char (point-min)))
```

**优点**:
- 纯 Emacs，无需外部依赖
- 表单验证容易
- 可以嵌入帮助文本

**缺点**:
- 界面相对简陋
- 复杂布局困难
- 用户仍需理解概念

**可行性**: ⭐⭐⭐⭐ 高

---

### 方案 2: Org-mode 结构化编辑

使用 Org mode 作为配置界面，结合结构编辑。

**示例**:
```org
* Viewer Configuration: My Dashboard

** Basic Info
- Name :: My Dashboard
- Type :: Progress Board
- Target Tag :: project

** Data Sources
- Virtual Columns :: total-effort, progress-percent, deadline

** Layout

*** Widget 1: Progress Bar
- Type :: progress-bar
- Field :: progress-percent
- Color :: green

*** Widget 2: Stats Row
- Type :: stats
- Items :: Total: $(total-effort), Done: $(done-count)

** Actions
[Save Configuration] [Preview] [Export]
```

**实现方式**:
- 创建 `supertag-viewer-configure-mode`
- 使用 Org 的表格和列表
- 通过按键触发操作（类似 Magit）
- 解析 Org 结构生成配置

**优点**:
- 用户熟悉的 Org 语法
- 可以内联文档
- 易于版本控制
- 支持导出

**缺点**:
- 不是真正的 GUI
- 需要学习特殊语法
- 验证较复杂

**可行性**: ⭐⭐⭐⭐ 高

---

### 方案 3: 专用 Major Mode (Magit 风格)

创建一个专门的 major mode，类似 Magit 的界面。

**示例界面**:
```
Viewer: My Dashboard (unsaved)
==============================

Basic Settings
  Name:       My Dashboard
  Type:       Progress Board [Change]
  Target:     #project       [Change]

Widgets
  1. Progress Bar [Edit] [Delete]
     Field: progress-percent
  2. Stats Row    [Edit] [Delete]
     Fields: total, done
  [Add Widget]

Actions
  p Preview    s Save    q Quit
```

**实现方式**:
```elisp
(define-derived-mode supertag-viewer-configure-mode special-mode "Viewer-Cfg"
  "Major mode for configuring viewers."
  (setq buffer-read-only t))

(defun supertag-viewer-configure-render (config)
  "Render configuration interface."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "Viewer Configuration\n")
    (insert "====================\n\n")
    
    ;; Section headers with faces
    (insert (propertize "Basic Settings\n" 'face 'bold))
    (insert "  Name: ")
    (insert-button (plist-get config :name)
                   'action (lambda (_) (supertag-viewer--edit-name)))
    (insert "\n\n")
    
    ;; Action buttons
    (insert (propertize "Actions\n" 'face 'bold))
    (insert-button "[Preview]" 'action #'supertag-viewer--preview)
    (insert " ")
    (insert-button "[Save]" 'action #'supertag-viewer--save)))
```

**优点**:
- 专业、集成的体验
- 可以实时预览
- 键盘驱动，符合 Emacs 风格

**缺点**:
- 开发复杂度高
- 需要维护专用 mode

**可行性**: ⭐⭐⭐ 中

---

### 方案 4: 混合方案 (推荐)

结合多种方式，分层次满足需求：

**Level 1: 交互式向导** (新用户)
```
M-x supertag-viewer-create-wizard

Step 1/4: Choose viewer type
  1. Text List
  2. Progress Board
  3. Statistics
  4. Custom...

Select (1-4): _
```

**Level 2: Widget 配置** (中级用户)
```
M-x supertag-viewer-configure
[表单界面]
```

**Level 3: DSL/代码** (高级用户)
```elisp
(supertag-viewer-define ...)
```

---

## 用户交互流程设计

### 创建 Viewer 的完整流程

```
用户输入:
  M-x supertag-viewer-create

系统响应:
  ┌─────────────────────────────────┐
  │ Create New Viewer               │
  │                                 │
  │ Name: [Project Dashboard    ]   │
  │                                 │
  │ Type: [Progress Board      [v]] │
  │       - Text List               │
  │       - Progress Board          │
  │       - Statistics              │
  │       - Effort Chart            │
  │       - Custom...               │
  │                                 │
  │ For tag: [#project          [v]]│
  │                                 │
  │ [Advanced Settings...]          │
  │                                 │
  │    [Create]  [Cancel]           │
  └─────────────────────────────────┘

用户选择 "Progress Board":
  → 自动配置所需虚拟列提示
  → 显示预览
  → 保存
```

---

## 技术实现建议

### 阶段 1: Wizard (最简单)

先实现命令行向导：

```elisp
(defun supertag-viewer-create-wizard ()
  "Interactive wizard to create a viewer."
  (interactive)
  (let ((name (read-string "Viewer name: "))
        (type (completing-read "Type: " 
                              '("text-list" "progress" "stats")))
        (tag (completing-read "For tag: " available-tags)))
    ;; Create based on template
    (supertag-viewer-create-from-template name type tag)))
```

### 阶段 2: Widget 编辑器

当用户需要调整时：

```elisp
(defun supertag-viewer-edit (viewer-id)
  "Edit VIEWER-ID using widget interface."
  ...)
```

### 阶段 3: 实时预览

```elisp
(defun supertag-viewer-preview ()
  "Preview current configuration."
  ...)
```

---

## 对比总结

| 方案 | 开发难度 | 用户体验 | 维护成本 | 推荐度 |
|------|---------|---------|---------|--------|
| Widget 表单 | 中 | 中 | 低 | ⭐⭐⭐⭐ |
| Org 结构 | 中 | 中-高 | 低 | ⭐⭐⭐ |
| 专用 Mode | 高 | 高 | 高 | ⭐⭐ |
| 混合方案 | 中 | 高 | 中 | ⭐⭐⭐⭐⭐ |

## 推荐策略

### 短期 (当前阶段)
- 保持代码方式 (已完成)
- 提供优秀模板和示例

### 中期 (Milestone 2-3)
- 实现 Wizard (task015-016)
- 提供 Widget 编辑器

### 长期
- 专用配置 mode
- 可视化布局编辑器

---

**结论**: 是的，可视化配置完全可行。建议采用"混合方案"：
1. Wizard 适合快速创建
2. Widget 适合精细调整
3. 代码适合高级定制

**下一步**: 可以实现一个简单的 Wizard 来验证这个想法。
