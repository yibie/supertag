# issue011 [ ] file-node 身份与链接语义耦合

## Summary

无文件级 ID 的 Org 文件会获得未写回文件的随机 UUID；重复解析产生重复 file-node。全局 `org-supertag-file-id-source` 同时控制身份读取、链接解析和输出，而 relation backlink 仍硬编码 `id:`，导致 Denote 链接不一致。

## Evidence

- 同一无 ID 文件连续 upsert 两次得到两个 UUID，store 中出现两个 level-0 节点。
- 旧实现会向 target 物化 reciprocal link，并把 Document Link 与 Backlink 混成两份 Org 事实。
- Org-roam 与 Denote 的 backlink 都是由索引/搜索派生，不要求写物理反向链接。

## Decision

1. file-node 必须来自持久化身份；无身份文件不是 file-node。
2. 身份 adapter 返回 node ID 与 link type，存入节点。
3. link codec 根据节点自身 metadata 工作，不读取全局兼容模式。
4. 新写入立即停止物化 reciprocal backlink；旧的 ambiguous links 默认保留，只能确认式迁移。

## Verification

- [x] 无 ID 文件重复同步不创建 file-node。
- [x] Org-ID 与 Denote file-node 可在同一 store 生成正确链接。
- [x] 新 reference 只写 source 的 forward link，target Backlink 由 relation index 派生。
- [x] 旧 ambiguous link 默认保留；迁移边界与 task010 的确认式流程已经明确。
- [x] 旧 ambiguous link 可只读预览并逐 occurrence 确认迁移；默认/abort 零写入，失败恢复文件与 Store。

## Migration Blocker

旧 reciprocal backlink 与用户手写的正向 Org link 完全同形，不能安全自动删除。
这不再阻塞停止新增物化 backlink：task013 已让新写入 forward-only，并将反向展示改为查询。
遗留文本的 preview、逐项确认与文件回滚已由 ownership task010 完成。

## Fix

- `supertag-add-reference` 与 remove/create variant 只修改并保存 source Org，再调用 Document Projector；target 文件不再打开或写入。
- `supertag-relation-add-reference`、node-reference field 与 Table edit 只写 relation/field state。
- file-node projector读取首个 heading 之前的 top-level links，避免 forward link 在下一次同步消失。
- Node View、Table View 与共享 Node state 的 Backlink 统一查询 `supertag-relation-find-by-to`。

## Verification

- source/target 分文件 SHA-256 回归证明 add/remove 只改变 source；target 无 reciprocal text。
- heading、file-node、Org-ID/Denote、node-reference field 与 derived Backlink consumers 均有稳定 ERT。
- 旧 ambiguous link 未被扫描、删除或改写。

## User Confirmation

- [ ] 在真实 Vault 新建 reference，确认 Git diff 只有 source Org 文件。
- [ ] 在 target Node/Table View 确认 Backlink 可见，再删除 source link 确认其消失。
- [ ] 在真实 Vault 运行 preview，按用户判断选择旧 backlink，并确认未选 link 保持原样。

## Related

- Tasks: `task011`, `task012`, `task013`
