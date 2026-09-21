# plan_sync_smart_detection_20251217: Sync Smart Detection 计划

## Milestones

1. 明确 smart detection 的状态模型与兼容策略（tech-refer）
2. 在 sync-state 中落地 file-level 状态（mtime/size/hash）
3. 在处理单文件时引入 smart detection（默认保持 mtime-only，可开关）
4. 增加最小可观测性与手动验证步骤

## Scope

- 仅改“是否需要 parse/导入”的决策逻辑，不改 sync 的队列/事务边界；
- 仅引入文件级 hash/size 状态；不改节点级 hash；
- 不引入外部依赖。

## Priorities

1. 正确性（不漏同步）
2. 兼容性（旧 state 可读）
3. 性能（避免双读、减少无效 parse）

## Risks & Dependencies

- 大文件 hash 的开销与 UI 卡顿风险
- state 结构演进的兼容性风险

