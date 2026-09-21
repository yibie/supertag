# issue012 [ ] concept promote 与 mention 审查缺陷

## Reproduction

- 空白选区执行 promote 会报错，但已通过 `org-id-get-create` 修改标题。
- 同名 file-node 会只在 store 中被标为 concept，Org 文件没有持久化 marker。
- inline code、verbatim、普通 comment 与 COMMENT heading 仍获得 mention 属性。
- 相同 title/alias 由 `maphash` 首个条目任意决定跳转目标。

## Root Cause

输入校验晚于节点定位副作用；concept marker 同时写 store/file 且 store 先写；上下文过滤依赖 face；term 索引把一对多关系压成一对一。

## Fix

- [x] 在任何节点/file 副作用前校验清洗后的 title。
- [x] 只复用可持久化 heading node，并在文件落盘后同步 store。
- [x] 使用 Org element context 过滤非正文。
- [x] 冲突 term 不生成可跳转 mention，promote 不任意复用。

## Verification

- [x] focused regression tests：9/9
- [x] concept/reference regressions：add-reference 4/4、field-reference 6/6、file-node 5/5、file-display 8/8

## User Confirmation

Pending real-buffer confirmation before closing issue012.

## Related

- Task: `task007`
