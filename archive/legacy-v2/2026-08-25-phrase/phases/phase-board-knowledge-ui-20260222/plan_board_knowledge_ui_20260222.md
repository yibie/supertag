# plan_board_knowledge_ui_20260222

## Milestones
1. Milestone 1（P0）：字段预览 + 卡片内容展开。
2. Milestone 2（P0）：Group 视觉容器渲染与交互闭环。
3. Milestone 3（P0）：Node Palette tag 分组默认折叠。
4. Milestone 4（P1）：关系语义可视化与手动 auto-layout。
5. Milestone 5（P2）：板内搜索与高亮。

## Scope
- In: `ext/board-ui` 的节点渲染、画布分组渲染、节点面板交互。
- Out: Emacs 协议层大改、右键菜单动作体系、兼容性迁移方案。

## Priorities
- P0：第一阶段四项核心能力（字段、内容展开、Group、默认折叠）。
- P1：关系类型可视化、手动布局按钮。
- P2：效率工具（本期仅先保留“板内搜索与高亮”）。

## Risks & Dependencies
- 依赖后端/桥接提供可用于“完整笔记内容”的数据字段；如缺失需先补数据通道。
- Group 与 React Flow 父子节点特性整合时，需严格验证拖拽/连线行为不回归。
- 卡片显示完整内容可能导致性能压力，需限制渲染开销（懒加载或折叠默认态）。

## Rollback
- 如果完整内容渲染引起明显卡顿，可回退到“摘要预览 + 外链打开”。
- 如果 Group 交互影响主流程，可暂时保留只读渲染并关闭编辑能力。
