# spec_sync_smart_detection_20251217: Sync Smart Change Detection（mtime + hash）

## Summary

本阶段为 org-supertag 的同步系统补齐“文件级 smart detection”：

- 默认仍使用 `mtime` 做快速判断；
- 可选启用“二段式确认”：当 `mtime` 变化时，再用 `size/hash` 判断内容是否真的变化；
- 目标是减少“伪变更”（touch、某些同步工具、git checkout 等）导致的不必要 parse，从而提升大仓库下的响应性与稳定性。

## Goals

- 引入可选的文件级 smart detection：`mtime/size` →（必要时）`content-hash`；
- 保持“parse once per file”的原则，避免为了算 hash 额外读两遍文件；
- 将必要的文件级状态（mtime/size/hash）纳入 sync-state（或兼容性良好的附加状态）；
- 保持现有队列/批处理/事务边界不变，仅改变“是否需要 parse/导入”的决策；
- 提供可观测性：能看出一个文件是因 mtime 变化但 hash 未变而跳过的。

## Non-goals

- 不改动节点级 hash（`supertag-node-hash`）的语义；
- 不引入外部依赖（fswatch、sqlite 等）；
- 不在本阶段做 AST 级缓存复用（仅为未来保留接口/记录方向）。

## User Flows

### Auto-sync / 队列批处理

1. 文件发生外部修改（或 mtime 变化）
2. auto-sync tick/队列处理触发
3. smart detection 判断：
   - 如果内容 hash 未变化 → 跳过 parse & 导入，更新状态并记录一次“skip”信息
   - 如果 hash 变化 → 正常 parse & 导入

### Full rescan

- full rescan 仍可选择：
  - `force`：忽略 smart detection（始终 parse）
  - `smart`：对每个文件做 smart detection（默认可配置）

## Edge Cases

- 仅 mtime 变化但内容完全一致：应跳过 parse
- 文件 size 变化但内容 hash 仍一致（罕见）：以 hash 为准
- 大文件：hash 计算成本较高，需要可配置阈值/策略（至少在 tech-refer 评估）
- 文件编码/换行变化：hash 应反映真实内容变化（以字节内容为准）

## Acceptance Criteria

- 在开启 smart detection 时：
  - 对“touch 但内容不变”的文件不会触发 parse/导入；
  - 对真实内容变更仍能正确导入并更新节点；
  - 不出现额外的重复文件读取（同一次处理链路中尽量“读一次文件→算 hash→parse”）。
- 在关闭 smart detection 时：
  - 行为与当前版本一致（mtime 变更即认为需要处理）。

## Default

- 默认开启：smart detection 默认为启用状态（仍可通过 `supertag-sync-smart-detection-enabled` 关闭回退到 mtime-only）。
