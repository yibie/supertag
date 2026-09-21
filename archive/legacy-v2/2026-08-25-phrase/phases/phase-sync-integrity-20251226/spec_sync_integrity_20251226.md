# spec_sync_integrity_20251226

## Summary

重构同步机制，把“目录不可用”提升为一等状态，消除“不可用=删除”的边界情况，避免内存库被污染后写盘覆盖；同时保持原有文件删除语义与向后兼容。

## Goals & Non-goals

### Goals
- 明确同步快照的“可用/完整”状态，只有完整快照允许执行破坏性变更（orphan/删除）。
- 同步流程拆为清晰的“采样 → 对比 → 应用”，每步只做一件事。
- 保留现有用户行为：文件确实删除时依旧触发 orphan/清理。
- 在目录不可用时不改数据、不写盘污染。
- sync-state 与 `supertag-data-directory` 绑定（每 vault 独立），切换时强制重载避免错配。

### Non-goals
- 不改动节点/字段存储结构（`:nodes` / `:fields` / `:field-values`）。
- 不重写 UI/视图/捕获系统。
- 不引入复杂的分布式/事务框架。

## Compatibility Constraints

- 现有数据库格式不变；新增状态仅作为可选元数据，不影响旧数据读取。
- 兼容旧版 sync-state：缺失新字段时按“未知/不可用”处理，不触发破坏性变更。
- 文件删除语义保持不变：仅在快照完整时允许 orphan/清理。
- 启动/切换/自动保存路径保持既有行为，不引入新用户操作成本。

## Sync Snapshot State Machine

### State Model

- `unavailable`：至少一个同步目录不可访问或不存在（目录未挂载、权限不足、路径无效）。
- `partial`：目录可访问，但扫描不完整（读取失败/超时/错误）。
- `complete`：完整扫描成功，得到可用的全量快照。

### Snapshot Data (Optional Metadata)

- `:snapshot` 作为 `supertag-sync--state` 的可选元数据。  
  - `:status` (`unavailable` | `partial` | `complete`)  
  - `:observed-at` (time)  
  - `:scope` (有效同步目录列表)  
  - `:errors` (可选，记录扫描失败原因)  
  - `:files` (可选，全量快照文件列表或摘要)

### Allowed Operations by State

- `unavailable`：只记录状态，不执行采样/对比/应用，不触发任何破坏性变更。  
- `partial`：允许对可读文件做增量解析/更新；禁止删除、orphan 标记、sync-state 清理。  
- `complete`：允许全量对比与应用，包括删除、orphan、GC、sync-state 清理。

### Transitions

- `unavailable` → `partial/complete`：目录恢复可用后重新采样。  
- `partial` → `complete`：全量扫描成功。  
- `complete` → `partial`：扫描失败或返回不完整结果。  
- `partial/complete` → `unavailable`：目录再次不可用。

## User Flows

1. 启动时目录未挂载/不可用  
   - 同步记录“不可用”状态，不执行 orphan 标记；目录恢复后再同步。
2. 正常删除文件  
   - 快照完整时识别删除，保持现有 orphan/清理行为。
3. Vault 切换  
   - 在目录可用前不启动破坏性同步，避免误判删除。
4. 手动全量 rescan  
   - 仅在快照完整时写回变更。

## Edge Cases

- 目录部分挂载/暂时超时：视为不可用，不触发删除路径。
- 大量文件/慢盘：采样与对比分离，避免长时间阻塞。
- 旧版 sync-state：需要兼容读取，但不影响新状态机判断。
- 手动切换数据目录：必须重载对应 sync-state，禁止使用旧状态继续同步。

## Rollback Strategy

- 新状态机作为可开关分支；必要时可退回旧同步流程入口。
- 回滚不触发数据迁移：禁用新状态判断即可恢复旧行为。
- 出现异常时可暂时关闭自动同步，待目录可用后再手动全量 rescan。

## Additional UI Change

- Table view 的 Refs 列默认绑定为 `node-reference` 字段（固定列、可编辑）。
- 在启用全局字段模式时，自动创建/关联全局字段 `Refs`，便于直接编辑引用。
- Refs 列支持 `C-o` 跳转到引用目标节点。
- Refs 列显示内容与编辑默认合并 `add-reference` 创建的 `:reference` 关系。

## Feature Toggle & Entry

- 开关变量：`supertag-sync-snapshot-guard`（bool，默认 t）。  
- 关闭时走旧同步入口；开启时走新状态机入口。  
- 入口函数：`supertag-sync--check-and-sync` 做分发；旧逻辑下沉为 `supertag-sync--check-and-sync-legacy`。

## Acceptance Criteria

- 目录不可用时，不会批量将节点标记 orphan，也不会写盘覆盖数据。
- 目录可用且文件被删除时，保持现有行为（orphan/清理不变）。
- 恢复可用后同步能自动继续，且无数据丢失。
- 不破坏现有用户使用路径与数据格式。
