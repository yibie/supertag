# 虚拟列系统任务列表

## Milestone 1: 核心基础设施

### task001 [x] 虚拟列 Schema 定义 (COMPLETE)
**产出**: `supertag-virtual-column.el` 实现 CRUD API
**验证**: ✅ Demo 完整运行，所有功能正常工作
**影响范围**: 新增模块 `supertag-virtual-column.el`
**提交**: 
- 实现虚拟列定义存储、缓存管理、依赖追踪
- 经过 3 轮重构解决 docstring 加载问题
- 最终版本: 227 行，精简高效

### task002 [x] 惰性计算引擎骨架
**产出**: `supertag-virtual-column.el` 添加计算引擎
**验证**: `supertag-virtual-column-get` 实现缓存检查→计算→存储流程
**影响范围**: `supertag-virtual-column.el` 新增 ~150 行
**提交**: 实现惰性计算引擎、类型分发、循环依赖检测、刷新操作

### task003 [x] 多级缓存系统 + Rollup 实现
**产出**: 缓存数据结构 + 依赖追踪 + Rollup 计算
**验证**: Rollup 计算使用 `supertag-relation-find-by-from` 获取子节点并聚合
**影响范围**: `supertag-virtual-column.el` 扩展
**提交**: 实现完整的缓存机制、依赖图构建、Rollup 类型计算

### task004 [x] Formula 表达式解析器与计算引擎 (COMPLETE)
**产出**: `supertag-virtual-column.el` 添加完整公式解析器
**验证**: 
- `(supertag-formula-parse-string "(done / total) * 100")` 正确生成 AST
- `(supertag-formula-eval-string "2 + 3 * 4" "node1")` => 14
- 14 个单元测试覆盖 tokenizer、parser、evaluator
**功能**:
- 支持 +, -, *, / 运算符，正确优先级
- 支持括号分组
- 支持变量引用（字段名）
- 支持负数
- 除零保护
**新增代码**: ~150 行
**测试文件**: `test/formula-test.el`
**演示文件**: `test/demo-formula.el`

---

## Milestone 2: 虚拟列类型

### task005 [x] Rollup 类型实现 (MERGED into task003)
**产出**: 支持 SUM, COUNT, AVG, MAX, MIN, FIRST, LAST
**验证**: `(supertag-virtual-column-get node-id "total-effort")` 正确计算
**状态**: 已与 task003 合并实现，7 个聚合函数全部工作

### task006 [x] Formula 表达式解析器 (MERGED into task004)
**产出**: 自研递归下降解析器
**验证**: `(supertag-formula-parse-string "a + b * 2")` 生成正确 AST
**状态**: 已与 task004 合并实现，支持完整中缀表达式

### task007 [x] Formula 计算引擎 (MERGED into task004)
**产出**: AST 遍历求值器
**验证**: `(supertag-formula-eval-string "(done / total) * 100" "node1")` => 正确百分比
**状态**: 已与 task004 合并实现，含除零保护、变量解析

### task008 [x] Aggregate 类型 (COMPLETE)
**产出**: 跨节点聚合（如所有 #project 的总 effort）
**验证**: 
```elisp
(supertag-virtual-column-create
 (list :id "total-project-effort"
       :type :aggregate
       :params (list :tag "project" :field "effort" :function :sum)))
```
**影响范围**: `supertag-virtual-column.el` 新增 ~30 行
**实现**: 
- `supertag-virtual-column--compute-aggregate`: 核心计算函数
- 使用 `supertag-find-nodes-by-tag` 查询带标签的节点
- 复用 Rollup 的 7 个聚合函数
**测试**: `test/aggregate-test.el` (3 个 ERT 测试)
**演示**: `test/demo-aggregate.el`

### task009 [x] Reference 类型 (COMPLETE)
**产出**: 跨节点字段引用
**验证**: 
```elisp
(supertag-virtual-column-create
 (list :id "parent-deadline"
       :type :reference
       :params (list :relation "parent"
                     :field "deadline")))
```
**影响范围**: `supertag-virtual-column.el` 新增 ~20 行
**实现**: 
- `supertag-virtual-column--compute-reference`: 核心计算函数
- 使用 `supertag-relation-find-by-from` 查找相关节点
- 支持 `:index` 参数选择第 N 个关系（默认第一个）
**参数**:
- `:relation` - 关系类型（如 "parent"）
- `:field` - 要引用的字段名
- `:index` - 可选，选择第几个关系目标（0=第一个）
**测试**: `test/reference-test.el` (3 个 ERT 测试)
**演示**: `test/demo-reference.el`

---

## Milestone 3: UI 集成

### task010 [x] Schema View 快捷键绑定 (COMPLETE)
**产出**: `v c` 创建虚拟列，`v e` 编辑，`v d` 删除，`v l` 列表
**验证**: 在 Schema View 中按 `v` 前缀键可访问虚拟列命令
**影响范围**: `supertag-view-schema.el`
**实现**:
- 添加 `v` prefix keymap 包含 `c`, `e`, `d`, `l` 命令
- 更新帮助文档显示虚拟列快捷键
- 添加 `(require 'supertag-virtual-column)`

### task011 [x] 虚拟列创建/编辑 UI (COMPLETE)
**产出**: 交互式命令 `supertag-virtual-column-create-interactive` 等
**验证**: 
- `v c` 创建时提示选择类型、输入参数
- Rollup: 提示 relation/field/function
- Formula: 提示输入公式
- Aggregate: 提示 tag/field/function
- Reference: 提示 relation/field/index
**影响范围**: `supertag-virtual-column.el` 新增 ~80 行 UI 函数
**实现**:
- `supertag-virtual-column-create-interactive`
- `supertag-virtual-column-edit-interactive`
- `supertag-virtual-column-delete-interactive`
- `supertag-virtual-column-list-interactive`
- 类型特定的参数读取函数

### task012 [x] Table View 虚拟列支持 (COMPLETE)
**产出**: 动态列渲染虚拟列数据
**验证**: Table View 自动显示虚拟列，计算值正确
**影响范围**: `supertag-view-table.el`
**实现**:
- `supertag-view-table--get-virtual-columns`: 获取虚拟列作为列定义
- 修改 `supertag-view-table--get-columns-for-tag`: 添加虚拟列到列列表
- 修改 `supertag-view-table--get-cell-value`: 处理 `:virtual-column` 类型，使用 `supertag-virtual-column-get`
- 添加 `(require 'supertag-virtual-column)`

### task013 [x] 缓存刷新 UI (COMPLETE)
**产出**: `g` 刷新，`G` 强制刷新
**验证**: 
- `g` 正常刷新，保留虚拟列缓存
- `G` 强制刷新，先清除虚拟列缓存再刷新
**影响范围**: `supertag-view-table.el`
**实现**:
- `supertag-view-table-force-refresh`: 新函数，清除缓存后刷新
- 添加 `G` 键绑定
- 更新帮助文档

---

## Milestone 4: Viewer 架构 (PAUSED - 需要进一步规划)

**状态**: 技术调研和规格设计已完成，等待后续阶段实现
**原因**: Viewer 是独立复杂功能，需要专门的设计验证和用户反馈
**已完成规划文档**:
- `tech_refer_viewer_architecture.md` - 技术调研
- `spec_viewer_architecture.md` - 详细功能规格

### task014 [ ] Viewer 注册 API
**产出**: `supertag-viewer-register` 实现
**依赖**: 需先验证 MVP 用户需求
**规格**: 见 `spec_viewer_architecture.md` Section 4.1

### task015 [ ] Viewer 选择器 (`v v`)
**产出**: 交互式 Viewer 选择界面
**依赖**: task014
**规格**: 见 `spec_viewer_architecture.md` Section 4.3

### task016 [ ] 内置 Viewer: Progress Board
**产出**: 项目进度看板模板
**规格**: 见 `spec_viewer_architecture.md` Section 4.4
**用户场景**: 周会项目回顾（Alice 的场景）

### task017 [ ] 内置 Viewer: Effort Distribution
**产出**: 工作量分布可视化
**规格**: 见 `spec_viewer_architecture.md` Section 4.5
**用户场景**: 个人工作量分析（Bob 的场景）

### task018 [ ] Viewer DSL
**产出**: 声明式配置支持
**优先级**: 低（Phase 3）
**规格**: 见 `spec_viewer_architecture.md` Section 6

---

## 测试与文档

### task019 [x] 单元测试套件
**产出**: `test/virtual-column-test.el` + `test/run-tests.sh`
**验证**: 覆盖 Schema CRUD、Cache 操作、Rollup 函数
**影响范围**: 新增测试文件
**提交**: 12 个 ERT 测试用例，含手动测试辅助函数

### task020 [x] 性能基准测试 (COMPLETE)
**产出**: `test/virtual-column-benchmark.el` 性能测试套件
**验证**: 
- Rollup cache miss (1000 nodes): 目标 < 5000 ms
- Rollup cache hit (1000 nodes): 目标 < 1000 ms
**测试函数**:
- `supertag-benchmark-rollup-1000` - 基准 1000 节点测试
- `supertag-benchmark-rollup-scaling` - 扩展性测试 (100-2000 节点)
- `supertag-benchmark-formula-suite` - 公式复杂度测试
- `supertag-benchmark-run-all` - 完整测试报告
**实现**:
- Mock 数据生成器（无需数据库）
- 时间测量宏
- 缓存命中/未命中对比
- 自动 PASS/FAIL 判定

### task021 [x] 用户文档 (COMPLETE)
**产出**: `doc/VIRTUAL_COLUMNS.md` (11KB，完整用户手册)
**验证**: ✅ 包含所有章节：概述、四种类型详解、快速上手、API 参考、UI 指南、性能数据、最佳实践、故障排除
**影响范围**: 新增完整用户文档，可供最终用户使用
**文档结构**:
1. 概述与核心特性
2. 四种虚拟列类型详解（含对比表格）
3. 快速上手指南（交互式 + 编程式）
4. API 参考（所有核心函数）
5. UI 使用指南（Schema/Table View）
6. 性能数据（基准测试结果）
7. 最佳实践（命名、缓存、优化）
8. 故障排除（常见问题 + 调试技巧）
9. 文件位置索引

### task022 [ ] 5 分钟演示视频/动图
**产出**: GIF 或简短视频展示完整流程
**验证**: 从创建到查看项目进度看板 ≤ 5 分钟
**影响范围**: README 或 Wiki
