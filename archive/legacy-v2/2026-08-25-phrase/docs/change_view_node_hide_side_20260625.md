# change_view_node_hide_side_20260625

## 变更摘要
修复 `supertag-view-node--hide-side` 因缺少 `(interactive)` 导致按 `q` 时出现 `Wrong type argument: commandp` 的错误。

## 变更文件
- `supertag-view-node.el`

## 行为变化
- 为 `supertag-view-node--hide-side` 添加 `(interactive)`，使其可作为命令被 keymap 调用。
- 按 `q` 关闭 node 侧边栏不再报错。

## 验证
- `load-file supertag-view-node.el` 成功。
- 代码检查确认 `q` 键绑定指向一个 interactive command。
