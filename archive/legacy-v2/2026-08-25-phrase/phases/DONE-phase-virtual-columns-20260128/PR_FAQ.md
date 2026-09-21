---
date: 2026-01-28
phase: virtual-columns
status: drafting
---

# PR/FAQ: 虚拟列与开放 Viewer 架构

## Press Release

### Headline
> Org-Supertag 发布虚拟列系统：让数据自己说话，5 分钟构建个性化项目看板

### Subtitle
> 从被动记录到主动洞察——支持 Rollup、Formula、自定义数据类型，_lazy 计算 + 智能缓存_，为高阶用户打造可扩展的知识工作空间。

### Date
Target: 2026 Q1

### Intro Paragraph
Org-Supertag 虚拟列系统是一套面向高阶用户的**计算型字段架构**。它允许用户在节点上定义**派生数据**——从简单的子任务求和，到复杂的跨节点公式计算，再到完全自定义的数据类型和可视化视图。无论你是想追踪项目进度、统计工作量分布，还是构建个性化的知识管理仪表板，虚拟列都能让你在**不离开 Emacs 生态**的前提下，获得类似 Airtable/Notion 的灵活计算能力。

### Problem Paragraph
高阶知识工作者在使用 Org-mode 管理复杂项目时，面临三大痛点：

1. **数据孤岛**：项目、任务、笔记分散在不同节点，无法自动聚合关键指标（如"项目总工作量"、"完成百分比"）
2. **重复劳动**：需要手动维护大量派生数据（如更新父任务的进度），容易出错且难以维护
3. **视图僵化**：内置的 Table/Kanban 视图无法满足个性化需求，想要甘特图、燃尽图、网络图等自定义视图时，只能望洋兴叹

### Solution Paragraph
虚拟列系统通过三层架构解决这些问题：

**计算层**：支持多种虚拟列类型——Rollup（父子聚合）、Formula（公式计算）、Aggregate（统计函数）、Reference（跨节点引用）。采用**惰性计算 + 智能缓存**策略，确保性能与实时性的平衡。

**类型层**：允许用户注册自定义数据类型，从简单的"进度百分比"到复杂的"时间序列数据"，扩展系统的数据表达能力。

**视图层**：开放 Viewer 注册机制，内置常用模板（Table、Kanban、Gantt），同时支持高级用户通过 Emacs Lisp 或 DSL 创建完全自定义的可视化视图。

### Company Leader Quote
> "我们设计虚拟列系统的初衷，是让 Emacs 用户不必在'强大的文本编辑'和'灵活的数据管理'之间做选择。 Org-mode 本身就是最好的结构化数据格式，我们只是让它'看得见、算得动、可扩展'。" 
> —— Org-Supertag 核心维护者

### How the Product/Service Works
**5 分钟快速上手**：

1. **定义虚拟列**：在 Schema View 中按 `v c` 创建虚拟列，选择类型（如 Rollup）
2. **配置计算逻辑**：指定数据来源（如子任务的 `effort` 字段）和计算方式（如 SUM）
3. **立即生效**：打开项目节点，实时看到"总工作量"自动计算
4. **创建视图**：按 `v v` 选择"项目进度看板"模板，或自定义 Viewer

**进阶用法**：
- 使用 Formula 类型编写 `(done-count / total-count) * 100` 计算完成率
- 注册自定义 Viewer 渲染燃尽图
- 通过 Emacs Lisp 访问虚拟列数据，与其他工具集成

### Customer Quote
> "以前我每周要花 30 分钟手动更新项目进度表。现在虚拟列自动汇总所有子任务的 effort 和状态，打开项目节点就能看到实时进度。我用 10 分钟写了一个简单的燃尽图 Viewer，现在团队周报直接截图就能用。"
> —— 某资深 Emacs 用户、项目经理

### How to Get Started
安装最新版 org-supertag 后，执行 `M-x supertag-virtual-column-demo` 体验 5 分钟快速上手教程，或访问 https://github.com/your-name/org-supertag/wiki/Virtual-Columns

---

## FAQ

### Internal FAQs

**Q: 虚拟列的计算性能如何？会不会拖慢 Emacs？**
A: 采用**惰性计算 + 多级缓存**架构：
- 首次访问时计算并缓存结果
- 监听依赖字段变更事件，智能标记脏数据
- 批量更新时延迟刷新，避免频繁重算
- 提供手动刷新命令，用户可完全控制

**Q: 与现有的 automation 系统如何协作？**
A: 虚拟列是**只读的派生数据**，automation 操作的是**原始数据**。两者解耦但互补：
- Automation 修改原始字段 → 触发虚拟列重新计算
- 虚拟列提供决策依据（如"阻塞任务数 > 3"时触发提醒 automation）

**Q: 自定义 Viewer 的安全性如何保证？**
A: Viewer 运行在 Emacs Lisp 环境中，遵循与现有代码相同的安全模型。我们不会引入外部 runtime（如 JavaScript），确保纯 Emacs 生态的可审计性。

**Q: 与现有的 org-ql、org-super-agenda 等工具的关系？**
A: 虚拟列是**数据增强层**，org-ql 是**查询层**。两者可以协同：
- 用 org-ql 筛选节点，用虚拟列展示计算字段
- 虚拟列提供的数据也可以被 org-ql 查询（通过 property）

### Customer FAQs

**Q: 我不懂编程，能用虚拟列吗？**
A: 可以！基础虚拟列（Rollup、简单 Formula）完全通过 UI 配置，无需代码。高级功能（自定义 Viewer、复杂 Formula）需要少量 Emacs Lisp 知识，但我们会提供模板和示例。

**Q: 虚拟列的数据存储在哪里？会不会导致 org 文件臃肿？**
A: 虚拟列是**计算型数据**，不存储在 org 文件中（除非用户选择导出）。数据缓存存储在 supertag 的数据库中，org 文件保持简洁。

**Q: 能否导出虚拟列数据到外部工具（如 Excel、Python）？**
A: 可以。所有虚拟列数据都可通过 `supertag-virtual-column-get` API 访问，支持导出为 CSV、JSON，或通过 org-table 直接展示。

**Q: 现有的 Table View 和 Kanban View 会支持虚拟列吗？**
A: 会！这是核心目标之一。Table View 将支持添加虚拟列作为动态列，Kanban View 将支持按虚拟列分组（如按"剩余工作量"分组）。
