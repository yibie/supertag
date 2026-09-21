# change_file_node_navigation_20260625

## 变更摘要
修复 file-level node 从搜索结果/节点视图/表格视图跳转时，被当作 heading 处理而跳到第一个标题的问题。

## 变更文件
- `supertag-ops-node.el`
- `supertag-services-ui.el`
- `supertag-ui-search.el`
- `supertag-view-table.el`

## 行为变化
- 新增内部函数 `supertag-node--goto-location`，统一处理 node 跳转定位：
  - 若 node `:level` 为 `0`（file-level），跳转后 point 停留在文件顶部；
  - 若 node 是普通 heading，跳转后调用 `org-back-to-heading` 回到标题。
- `supertag-goto-node`（`supertag-services-ui.el`）改为调用该 helper。
- `supertag-search--find-node`（`supertag-ui-search.el`）改为调用该 helper。
- `supertag-view-table--goto-node-id`（`supertag-view-table.el`）改为调用该 helper。

## 验证
- `batch-byte-compile` 通过：
  - `supertag-ops-node.el`
  - `supertag-services-ui.el`
  - `supertag-ui-search.el`
  - `supertag-view-table.el`
- 代码路径检查：file-level node 跳转不再调用 `org-back-to-heading`。
