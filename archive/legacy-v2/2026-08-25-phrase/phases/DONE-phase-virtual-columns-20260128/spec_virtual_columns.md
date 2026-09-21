# 虚拟列系统技术规格

## Summary
实现一套计算型字段架构，支持 Rollup、Formula、自定义数据类型，采用惰性计算+缓存策略，并与开放 Viewer 架构集成。

## Goals & Non-Goals

### Goals
- [ ] 支持基础虚拟列类型：Rollup、Formula、Aggregate、Reference
- [ ] 惰性计算 + 智能缓存机制
- [ ] 虚拟列数据可集成到现有 Table/Kanban View
- [ ] 5 分钟内可配置项目进度看板
- [ ] 可扩展的 Viewer 注册机制（配置式为主，脚本式为辅）

### Non-Goals
- [ ] 不引入外部 runtime（保持纯 Emacs Lisp）
- [ ] 不修改 org 文件格式（虚拟列不持久化到文件）
- [ ] 不支持双向绑定（虚拟列只读，不反向修改原始数据）
- [ ] 本期不实现实时协作（单用户场景）

## User Flows

### Flow 1: 创建 Rollup 虚拟列
```
用户操作                          系统反馈
─────────────────────────────────────────────────────────
在 Schema View 按 a c 创建子标签    显示创建对话框
选择 tag（如 #project）
按 v c 创建虚拟列                   提示选择虚拟列类型
选择 "Rollup"
配置：
  - 关系：children
  - 字段：effort
  - 函数：SUM
确认                               虚拟列创建成功
打开 project 节点                  显示 "总工作量: 42h"
```

### Flow 2: 创建 Formula 虚拟列
```
用户操作                          系统反馈
─────────────────────────────────────────────────────────
按 v c 创建虚拟列
选择 "Formula"
输入表达式：(done / total) * 100
指定变量映射：
  - done → rollup:completed-count
  - total → rollup:total-count
确认                               显示 "进度: 75%"
```

### Flow 3: 使用虚拟列创建自定义 Viewer
```
用户操作                          系统反馈
─────────────────────────────────────────────────────────
按 v v 打开 Viewer 选择器
选择 "Create Custom Viewer"
选择模板 "Project Dashboard"
配置显示的列：
  - 原始列：title, deadline
  - 虚拟列：total-effort, progress-percent
保存为 "My Project Board"
打开任意 project 节点              显示自定义看板
```

## Edge Cases

1. **循环依赖**：Formula A 引用 Formula B，B 又引用 A
   - 处理：计算时检测循环，报错并停止

2. **依赖节点被删除**：Rollup 依赖的子任务被删除
   - 处理：重新计算时跳过缺失节点，记录警告

3. **大数据量**：项目下有 1000+ 子任务
   - 处理：异步计算 + 进度指示器，避免阻塞 UI

4. **缓存失效风暴**：批量导入导致大量虚拟列失效
   - 处理：批处理模式，延迟刷新，提供手动刷新按钮

## Acceptance Criteria

- [ ] 用户可在 5 分钟内完成：创建 Rollup 列 → 查看聚合数据 → 添加到 Table View
- [ ] Formula 支持基础运算符：+ - * / ( ) 和常用函数：count, sum, avg, max, min
- [ ] 1000 个子任务的 Rollup 计算在 1 秒内完成（缓存命中）
- [ ] 提供至少 3 个内置 Viewer 模板：Progress Board、Effort Distribution、Timeline
- [ ] 虚拟列数据可通过 API `(supertag-virtual-column-get node-id column-id)` 访问
