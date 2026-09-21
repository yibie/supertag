# change_sync_smart_detection_20251217

- 2025-12-17 Add  
  - Files:  
    - `.phrase/phases/phase-sync-smart-detection-20251217/spec_sync_smart_detection_20251217.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/tech-refer_sync_smart_detection_20251217.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/plan_sync_smart_detection_20251217.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/task_sync_smart_detection_20251217.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/change_sync_smart_detection_20251217.md`  
  - Reason: 启动新 phase，以“mtime + hash”的文件级 smart detection 改进同步系统，减少伪变更导致的不必要 parse  
  - Related: `task001` (task_sync_smart_detection_20251217)

- 2025-12-17 Modify  
  - Files:  
    - `.phrase/phases/phase-sync-smart-detection-20251217/tech-refer_sync_smart_detection_20251217.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/task_sync_smart_detection_20251217.md`  
  - Reason: 完成 `task002` 的技术探索，明确 file-level state 的兼容结构（读旧写新、按需升级）以及“读一次文件即可完成 hash+parse 决策”的最低侵入实现路径，并标记任务完成  
  - Related: `task002` (task_sync_smart_detection_20251217)

- 2025-12-17 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/task_sync_smart_detection_20251217.md`  
  - Reason: 完成 `task003`，将 sync-state 的文件条目扩展为可包含 `mtime/size/content-hash/hash-algo` 的 plist，同时保持旧 time-only entry 可读，并调整 state 更新/mtime 检测函数以兼容新旧格式  
  - Related: `task003` (task_sync_smart_detection_20251217)

- 2025-12-17 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/task_sync_smart_detection_20251217.md`  
  - Reason: 完成 `task004`，在单文件处理入口实现“mtime 变化时用内容 hash 二次确认”的 smart detection，并通过 `supertag--parse-org-nodes-from-current-buffer` 实现 hash+parse 同 buffer（避免双读），同时新增相关 defcustom 开关与阈值/算法配置  
  - Related: `task004` (task_sync_smart_detection_20251217)

- 2025-12-17 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/task_sync_smart_detection_20251217.md`  
  - Reason: 完成 `task005`，为 smart detection 增加可观测性（`supertag-sync-smart-detection-verbose` 日志 + 记录最近一次判定的命令 `supertag-sync-smart-detection-describe-last-decision`），并补充手动验证清单  
  - Related: `task005` (task_sync_smart_detection_20251217)

- 2025-12-17 Add  
  - Files:  
    - `.phrase/docs/ISSUES.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/issue_sync_smart_detection_20251217.md`  
  - Reason: 记录用户反馈的 bug：`org-supertag-sync-directories` 变更后，sync-state 追踪文件集合未随之更新（issue001）  
  - Related: `issue001`

- 2025-12-17 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/task_sync_smart_detection_20251217.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/issue_sync_smart_detection_20251217.md`  
  - Reason: 修复 issue001（task006），增加 `supertag-sync--reconcile-state` 并在 `supertag-sync--check-and-sync` 与 `supertag-sync-full-rescan` 开头执行，对齐 sync-state 的追踪集合以响应 `org-supertag-sync-directories` 配置变更，同时提供手动命令 `supertag-sync-reconcile-state`  
  - Related: `task006`, `issue001`

- 2025-12-17 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/task_sync_smart_detection_20251217.md`  
  - Reason: 完成 `task007`，在启用 smart detection 且 `:content-hash` 为空时也计算 hash 以建立 baseline，避免必须依赖 mtime 变化才能写入 `:content-hash`  
  - Related: `task007` (task_sync_smart_detection_20251217)

- 2025-12-17 Fix  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/docs/ISSUES.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/issue_sync_smart_detection_20251217_do_maintenance.md`  
  - Reason: 修复 `supertag-sync--check-and-sync` 中 `do-maintenance` 作用域错误导致的 `(void-variable do-maintenance)`，并记录为 issue002  
  - Related: `issue002`

- 2025-12-17 Modify  
  - Files:  
    - `.phrase/phases/phase-sync-smart-detection-20251217/task_sync_smart_detection_20251217.md`  
    - `.phrase/docs/ISSUES.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/issue_sync_smart_detection_20251217.md`  
  - Reason: 标记 task001 完成并将 issue001 置为已解决（用户已确认 sync-state 追踪集合对齐）  
  - Related: `task001`, `issue001`

- 2025-12-17 Modify  
  - Files:  
    - `.phrase/docs/ISSUES.md`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/issue_sync_smart_detection_20251217_do_maintenance.md`  
  - Reason: 用户确认 `(void-variable do-maintenance)` 不再出现，关闭 issue002  
  - Related: `issue002`

- 2025-12-17 Modify  
  - Files:  
    - `.phrase/phases/DONE-phase-sync-smart-detection-20251217/*`  
  - Reason: 用户确认本阶段完成，将 phase 目录标记为 DONE（阶段结项）  
  - Related: `phase-sync-smart-detection-20251217`
- 2025-12-17 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-smart-detection-20251217/spec_sync_smart_detection_20251217.md`  
  - Reason: 将 `supertag-sync-smart-detection-enabled` 默认值改为启用（t），使 smart detection 默认生效，同时保留关闭开关以回退到 mtime-only 行为  
  - Related: `task004`, `task007`
