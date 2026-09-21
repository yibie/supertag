# task_board_knowledge_ui_20260222

- task001 [x] 在节点卡片增加“标签可展开字段预览”（按 tag/schema 渲染字段名与字段值）。  
  验证：点击标签后可展开看到字段和值；字段缺失时显示空占位，不报错。  
  影响范围：`ext/board-ui/components/BoardNode.tsx`，`ext/board-ui/components/BoardCanvas.tsx`，数据映射层。

- task002 [x] 在节点卡片增加“下拉展开完整笔记内容”能力，内容区设置最大高度并启用滚动。  
  验证：展开后展示完整内容，超长内容出现滚动条；刷新后默认折叠。  
  影响范围：`ext/board-ui/components/BoardNode.tsx`，节点数据结构与传递链路。

- task003 [x] 实现 Group 视觉容器在画布中的渲染与节点组织交互闭环。  
  验证：可见 Group 区域，节点可被组织到 Group 中并稳定显示。  
  影响范围：`ext/board-ui/components/BoardCanvas.tsx`，`ext/board-ui/store/types.ts`，相关渲染组件。

- task004 [x] 将 Node Palette 的 tag 分组默认状态改为“全部折叠”。  
  验证：首次打开 Palette 时所有 tag 组折叠；用户可单独展开。  
  影响范围：`ext/board-ui/components/NodePalette.tsx`。

- task005 [x] 第一阶段验收与回写：更新 change 文档与 CHANGE 索引，记录验证结论。  
  验证：`change_*` 记录完整，`.phrase/docs/CHANGE.md` 有索引，任务状态同步更新。  
  影响范围：`.phrase/phases/phase-board-knowledge-ui-20260222/`，`.phrase/docs/CHANGE.md`。
