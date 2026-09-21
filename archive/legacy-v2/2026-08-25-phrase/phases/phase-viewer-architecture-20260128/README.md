# Phase: Viewer Architecture

## 阶段信息

- **名称**: phase-viewer-architecture-20260128
- **状态**: 规划中 / 等待启动
- **依赖**: [DONE-phase-virtual-columns-20260128](../DONE-phase-virtual-columns-20260128)

## 目标

为 org-supertag 构建可扩展的自定义 View 框架，让开发者能够轻松创建数据可视化组件。

## 什么是 View？

View（视图）是 org-supertag 的数据可视化组件，由开发者使用 `supertag-view-framework` 创建。与通用的 Table View 不同，自定义 View 专注于特定的数据展示场景：

- **Progress Dashboard** - 项目进度看板
- **Effort Distribution** - 工作量分布分析
- **Priority Matrix** - 任务优先级矩阵
- **自定义 Views** - 开发者定义的展示方式

**注意**: 这是一个开发者框架，不是面向最终用户的配置工具。

## 文档结构

```
phase-viewer-architecture-20260128/
├── README.md                         # 本文件
├── task_viewer_architecture.md       # 任务列表
├── tech_refer_viewer_architecture.md # 技术调研
└── spec_viewer_architecture.md       # 功能规格
```

## 快速导航

| 文档 | 内容 |
|------|------|
| [tech_refer_viewer_architecture.md](tech_refer_viewer_architecture.md) | 技术调研、方案对比、参考实现 |
| [spec_viewer_architecture.md](spec_viewer_architecture.md) | 用户场景、功能规格、API 设计、验收标准 |
| [task_viewer_architecture.md](task_viewer_architecture.md) | 详细任务列表、依赖关系、开发顺序 |

## 任务概览

### Milestone 1: 基础框架 (task001-003)
- Viewer 注册 API
- 示例 Text-List Viewer
- Viewer 选择器 (`v v`)

### Milestone 2: 内置 Viewers (task004-006)
- Progress Board
- Effort Distribution
- Priority Matrix

### Milestone 3: 高级功能 (task007-009)
- 配置持久化
- Widget 系统
- DSL

### Milestone 4: 测试与文档 (task010-012)
- 测试套件
- 演示
- 用户文档

## 与虚拟列系统的关系

```
┌─────────────────┐
│   Viewer Layer  │  ← 本阶段构建
│  (可视化展示)    │
└────────┬────────┘
         │
         │ 读取虚拟列计算值
         ↓
┌─────────────────┐
│ Virtual Columns │  ← 前一阶段已完成
│  (计算字段系统)  │
└────────┬────────┘
         │
         │ 计算
         ↓
┌─────────────────┐
│   Raw Data      │
│ (Nodes/Fields)  │
└─────────────────┘
```

## 建议的启动时机

1. ✅ 虚拟列系统稳定运行
2. ✅ 收集到用户反馈，确认 viewer 需求
3. ⏳ 有可用的开发资源

## 前一阶段成果

[DONE-phase-virtual-columns-20260128](../DONE-phase-virtual-columns-20260128) 已完成：
- 4 种虚拟列类型
- UI 集成
- 性能优化（比目标快 1000-10000 倍）
- 完整文档

---

**创建日期**: 2026-01-28
