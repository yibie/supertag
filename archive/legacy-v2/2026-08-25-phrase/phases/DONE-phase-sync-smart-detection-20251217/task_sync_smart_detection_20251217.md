# task_sync_smart_detection_20251217

- task001 [x] 建立 smart detection phase 文档骨架  
  - 产出：本 phase 的 spec/plan/tech-refer/task/change 文件  
  - 验证方式：文件存在且内容围绕“mtime + hash 的文件级变更检测”目标（手动检查）  
  - 影响范围：仅文档

- task002 [x] 技术探索：状态模型与“读一次文件”实现方案  
  - 产出：补全 `tech-refer_sync_smart_detection_20251217.md` 的 Proposed Approach（状态结构、兼容策略、读一次实现；包含“现状与接入点”“推荐的 state 结构”“避免双读的最低侵入实现”“接入位置”等小节）  
  - 验证方式：对照 `supertag-services-sync.el` 的现有 `mtime` 状态逻辑（`supertag-sync-update-state` / `supertag-sync-check-state` / `supertag-get-modified-files` / `supertag--parse-org-nodes`），确认 smart detection 的状态扩展与“读一次文件”方案可在单文件处理入口处接入，且不需要改变队列/事务边界（手动检查）  
  - 影响范围：文档与设计

- task003 [x] 实现 sync-state 扩展（mtime/size/hash）并保持兼容  
  - 产出：在 `supertag-services-sync.el` 中将 sync-state 的每个文件条目从 “time-only” 扩展为 plist entry：`(:mtime :size :content-hash :hash-algo)`，并保持旧格式（value 为 time object）可读；同时更新 `supertag-sync-update-state`/`supertag-sync-check-state` 以支持新旧两种 entry。  
  - 验证方式：  
    1) 旧 state（value 为 time object）下 `supertag-sync-check-state` 仍能工作；  
    2) 新 state 由 `supertag-sync-save-state` 保存后可由 `supertag-sync-load-state` 回读，不报错；  
    3) 新 state 中 `:size` 可由 `file-attributes` 填充，`content-hash` 保持为 nil/旧值等待 `task004` 更新（手动检查）。  
  - 影响范围：sync-state 的 value 结构、状态更新与 mtime 判断逻辑。

- task004 [x] 实现文件级 smart detection（mtime 变化时 hash 二次确认）  
  - 产出：在 `supertag-services-sync.el` 的 `supertag-sync--process-single-file` 中加入 file-level smart detection：当 `supertag-sync-smart-detection-enabled` 为非 nil 且文件 `mtime` 变化时，在同一次 `with-temp-buffer` 读入文件后计算内容 hash；若 hash 与 state 中 `:content-hash` 一致则跳过 parse/import；否则在同一 buffer 内调用 `supertag--parse-org-nodes-from-current-buffer` 解析并导入，同时通过 `supertag-sync-update-state` 记录本次 `:content-hash`。  
  - 验证方式：  
    1) 对同一文件先完成一次导入（建立 baseline hash）；  
    2) 执行 `touch <file>`（内容不变，mtime 变化）→ 下次 sync 不应触发 parse/import；  
    3) 修改文件内容后保存 → 下次 sync 正常导入；  
    4) 代码路径中 smart detection 分支仅 `insert-file-contents` 一次，并在同一 buffer 中完成 hash + parse（手动检查）。  
  - 影响范围：单文件 sync 决策逻辑、sync-state 的 `:content-hash` 填充路径

- task005 [x] 增加可观测性与手动验证清单  
  - 产出：必要的 message/debug 输出 + 文档化的手动验证步骤  
  - 验证方式：用户可通过 echo area 的 smart detection 日志（由 `supertag-sync-smart-detection-verbose` 控制）以及 `M-x supertag-sync-smart-detection-describe-last-decision` 命令确认某个文件是“skip 还是 sync”  
  - 影响范围：日志与文档

## Manual Verification Checklist（task005）

建议在一个小测试目录中验证：

1. 配置并启用：
   - `(setq supertag-sync-smart-detection-enabled t)`
   - `(setq supertag-sync-smart-detection-verbose t)`（打开可观测日志）
   - 确保 `org-supertag-sync-directories` 包含该测试目录
2. 先跑一次 `M-x supertag-sync-full-rescan`（建立 baseline `:content-hash`）
3. 对某个已纳入同步范围的 `.org` 文件执行：`touch <file>`（内容不变但 mtime 变化）
4. 等待下一次 auto-sync tick，或手动触发一次同步（例如 `M-x supertag-sync-full-rescan`）
5. 预期观察：
   - echo area 出现：`skip (hash unchanged): <filename>`
6. 修改该文件内容并保存，再触发一次同步
7. 预期观察：
   - echo area 出现：`sync (hash changed): <filename>`
8. 可选：执行 `M-x supertag-sync-smart-detection-describe-last-decision`
   - 确认最近一次记录的 decision（skip/sync/fallback）与时间戳

- task006 [x] 修复 issue001：sync-state 随 `org-supertag-sync-directories` 变更对齐追踪集合  
  - 产出：实现一个 state reconcile 逻辑，在 full-rescan 与 auto-sync tick 中对 sync-state 执行：
    - 移除 out-of-scope 或已不存在文件的 state entry（untrack）；
    - 统一 key 为绝对路径（修复历史遗留的相对路径 key）；
    - 不删除 store 中节点（仅调整“追踪集合”）。
  - 验证方式：  
    1. 配置目录从 A 切换到 B，触发一次 `supertag-sync-full-rescan` 或等待一次 auto-sync tick；  
    2. `sync-state.el` 中不再出现目录 A 的文件条目，且会逐步纳入目录 B 的文件条目；  
    3. 不触发误删（untrack 仅影响 state，不删除节点）。  
  - 影响范围：sync-state 的“追踪集合对齐”逻辑与相关入口。

- task007 [x] 修复 smart detection 基线：首次建立 `:content-hash` 时不依赖 mtime 变化  
  - 产出：当启用 `supertag-sync-smart-detection-enabled` 且 state entry 中 `:content-hash` 为空时，在处理该文件时也计算并写入 `:content-hash`（即便 mtime 没变化），用于建立后续 skip 判断的 baseline。  
  - 验证方式：启用 smart detection 后跑一次 full-rescan/触发一次文件处理，确认 `sync-state.el` 对应文件条目出现非 nil 的 `:content-hash`。  
  - 影响范围：单文件 smart detection 决策条件与 state 填充路径。
