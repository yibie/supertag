# change_sync_improve_20251216

- 2026-07-22 Fix
  - Files:
    - `supertag-services-sync.el`
    - `test/extractor-test.el`
    - `test/sync-worker-regression-test.el`
  - Changes:
    - 将 Org major-mode 初始化下沉到公共 current-buffer parser，使 auto-sync
      的临时 buffer 能正确识别 `DOING` 等自定义 TODO 关键字；
    - full rescan 强制重解析哈希未变文件，使旧 DB 中的错误 title/todo/OLP
      可被重建；
    - 删除 file parser 包装层重复的 `org-mode` 初始化。
  - Verification: 新回归先红后绿；定向 ERT 23/23、完整 ERT 297/297，
    diff/check-parens/byte compile 通过。
  - Risk: full rescan 会按命令语义解析每个 scope 内文件，所需时间与 vault 大小成正比。
  - Related: `issue020`, `task020`

- 2026-07-22 Fix
  - Files:
    - `supertag-services-embed.el`
    - `test/embed-cache-test.el`
    - `test/run-tests.sh`
  - Changes:
    - `supertag-services-embed--render-node-to-file` 解析节点时绕过旧 element cache，
      仅在实际 delete/insert 期间屏蔽 modification hooks，并在 `unwind-protect` 中
      无条件 reset cache；
    - `save-buffer` 不再处于屏蔽范围，全局 after-save 回调不会把该状态传播到其他
      已打开 Org buffer；
    - 删除 `supertag-embed-sync-modified-blocks` 无直接写入却覆盖整条调用链的外层屏蔽；
    - 新增真实 render 调用链与动态作用域回归，并加入默认测试集。
  - Verification:
    - 修复前：2/2 回归失败，cache size 为 68453、实际 buffer size 为 67；
    - 修复后：embed 2/2、默认 ERT 291/291；shell syntax、check-parens、
      diff check、touched-file byte compile 通过。
  - Risk: 保留文本替换期间的 hook 屏蔽以兼容 `org-indent-mode`；用户命令、数据格式与
    embed 内容语义不变。
  - Related: `issue016`, `task019`

- 2026-01-21 Release  
  - Files:  
    - `org-supertag.el`  
  - Changes:  
    - 版本号更新为 5.6.3；创建 annotated tag `v5.6.3`。  
  - Related: `task018` (task_sync_improve_20251216)

- 2026-01-21 Modify  
  - Files:  
    - `README.md`  
    - `README_CN.md`  
    - `CHANGELOG.org`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 补充 smart scan 工作原理说明，并强调减少误触发导致数据库意外清空的风险；  
    - 在 CHANGELOG 记录 smart scan 常开与同步行为说明。  
  - Related: `task017` (task_sync_improve_20251216)

- 2026-01-21 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-improve-20251216/spec_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/plan_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 移除 `supertag-sync-smart-detection-*` 开关分支，`supertag-sync--process-single-file` 默认以内容 hash 决定是否解析；  
    - 在 spec 中明确 smart detection 行为不可配置，并在 plan/task 中记录该变更。  
  - Related: `task016` (task_sync_improve_20251216)

- 2025-12-18 Add  
  - Files:  
    - `org-supertag.el`  
    - `supertag-services-sync.el`  
    - `README.md`  
    - `README_CN.md`  
    - `.phrase/phases/phase-sync-improve-20251216/spec_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 复用 `org-supertag-sync-directories`，新增 `org-supertag-sync-directories-mode`（`unified`/`vaults`）以支持单活跃 Vault 隔离模式（每目录独立 DB/state）；  
    - Vault 模式下为每个 Vault 使用独立的 DB 与 sync-state（在 `supertag-data-directory/vaults/` 下），sync scope 仅覆盖当前活跃 Vault 根目录，从而隔离多仓库数据；  
    - 切换 Vault 时停止并重启 auto-sync，仅同步当前活跃 Vault；默认不随文件自动切换活跃 Vault（`org-supertag-vault-auto-switch` 默认 nil），但会在 mode line 显示 `ST[<vault>]` 提示当前文件所属 Vault；  
    - 对保存触发的实时同步路径做了 `file-truename` 规范化，避免 `~`/符号链接导致的 scope 匹配不稳定。  
  - Related: `task015` (task_sync_improve_20251216)

- 2025-12-17 Fix  
  - Files:  
    - `supertag-services-sync.el`  
    - `test/supertag-services-sync-test.el`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 修复 `supertag-sync-check-state` 在 state entry 为 plist（如 `(:mtime ...)`）时，确保只将 `:mtime` 作为 time 值参与比较，避免 `time-less-p` 抛出 `Invalid time specification`；  
    - 增加最小 ERT 回归测试，覆盖 plist 形式的 `:mtime` 场景。  
  - Related: `task014` (task_sync_improve_20251216)

- 2025-12-16 Add  
  - Files:  
    - `.phrase/phases/phase-sync-improve-20251216/spec_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/plan_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/change_sync_improve_20251216.md`  
  - Reason: 为“同步服务改进（安全 / 可控 / 可观测）”建立独立 phase 与任务骨架  
  - Related: `task001` (task_sync_improve_20251216)

- 2025-12-16 Add  
  - Files:  
    - `.phrase/phases/phase-sync-improve-20251216/tech-refer_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Reason: 在规划进一步改动前，补充同步架构与 =supertag-transform= 相关的技术探索，明确现状与可选方案，为后续 plan 与实现提供依据  
  - Related: `task005` (task_sync_improve_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `supertag-core-transform.el`  
    - `doc/COMPARE-NEW-OLD-ARCHITECTURE.md`  
    - `doc/COMPARE-NEW-OLD-ARCHITECHTURE_cn.md`  
  - Changes:  
    - 移除未被实际使用的 =supertag-transform=、批量 transform 与路径匹配相关函数，仅保留事务宏 =supertag-with-transaction= 以及纯辅助函数 =supertag-transform-extract-inline-tags=；  
    - 将架构对比文档中对“所有状态变更必须通过 `supertag-transform`”的描述，更新为“通过 ops 函数 + `supertag-with-transaction` 提交到统一 store”，使文档与当前实现一致。  
  - Notes: 功能层面不应有行为变化，后续需在本地 Emacs 中加载相关模块及执行若干事务性操作进行确认。  
  - Related: `task006` (task_sync_improve_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `.phrase/phases/phase-sync-improve-20251216/spec_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 在 spec 中新增 “Current Sync Flow & Config” 小节，系统梳理当前版本的同步启动路径（`emacs-startup-hook` → `supertag-init` → auto-start）、auto-sync 定时器与 idle 调度、核心命令（`supertag-sync-start-auto-sync` / `supertag-sync-stop-auto-sync` / `supertag-sync-full-rescan`）以及关键配置项；  
    - 将 `task002` 标记为已完成，并说明该小节今后作为 sync 行为变更的基线。  
  - Related: `task002` (task_sync_improve_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `.phrase/phases/phase-sync-improve-20251216/spec_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 在 spec 中新增 “Safer Default Behavior Design” 小节，定义“手动同步模式 / 安全自动模式 / 高级自动模式”三层行为，并明确对 `supertag-sync-auto-start` 默认值、sync 目录配置和定时/idle 参数的设计意图与兼容性策略；  
    - 将 `task003` 标记为已完成，并细化其产出和验证方式。  
  - Related: `task003` (task_sync_improve_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `.phrase/phases/phase-sync-improve-20251216/tech-refer_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/spec_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 在 tech-refer 中补充/整理文件级队列 + 批处理设计，明确队列状态、API 草图、与手动 sync / auto-sync 的集成、以及错误处理和观测建议；  
    - 在 spec 中新增 “File-Level Queue Direction” 小节，确保 phase 层面对队列引入的方向性和边界有清晰描述；  
    - 将 `task007` 标记为已完成，说明其产出和验证方式。  
  - Related: `task007` (task_sync_improve_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `.phrase/phases/phase-sync-improve-20251216/tech-refer_sync_improve_20251216.md`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 在 tech-refer 中新增 “Analysis: `supertag-sync--check-and-sync` Structure & Refactor Space” 小节，详细拆解该函数的职责分层（预检查、state cleanup、modified/new 文件处理、orphan 检查、validate 与报告），并评估哪些部分适合队列化、哪些应保持同步；  
    - 将 task010 标记为已完成，明确其产出为上述分析和若干可选重构方案。  
  - Related: `task010` (task_sync_improve_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 新增 defcustom `supertag-sync-auto-use-queue`，用于控制 auto-sync 是否使用文件队列；  
    - 在 `supertag-sync--check-and-sync` 中，当 `supertag-sync-auto-use-queue` 为非 nil 且存在 `modified-files` 时，不再直接遍历所有文件调用 `supertag-sync--process-single-file`，而是：  
      - 将 modified/new files 入队（`supertag-sync-enqueue-files`）；  
      - 通过 `supertag-sync-process-queue` 处理一批队列中的文件，并根据 counters 变化标记 `state-changed`；  
      - 保留原有排序与逐文件处理逻辑作为开关关闭时的兼容路径。  
  - Notes: 当前更改仅在用户显式开启 `supertag-sync-auto-use-queue` 时生效，默认行为与之前版本一致；orphan 检查与 validate 逻辑暂保持不变。  
  - Related: `task011` (task_sync_improve_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 将 `supertag-sync-auto-use-queue` 的默认值调整为 t，使 auto-sync 在配置了同步目录的情况下默认走队列化路径；  
    - 新增 `supertag-sync-queue-length` 交互命令，用于查看当前待处理队列长度，便于用户观测 auto-sync 工作量；  
    - 更新 task012 状态，表明队列已成为 auto-sync 的默认路径，同时保留通过将 `supertag-sync-auto-use-queue` 设为 nil 的回退方案。  
  - Related: `task012` (task_sync_improve_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 新增 defcustom `supertag-sync-maintenance-every-n-ticks` 与内部计数器 `supertag-sync--maintenance-counter`，用于控制自动同步中深度维护（`supertag-sync-validate-nodes` + `supertag-sync-garbage-collect-orphaned-nodes`）的频率；  
    - 将 `supertag-sync--check-and-sync` 中的 validate 调用与 GC 封装在 `do-maintenance` 条件下，仅在 tick 计数满足 N 的倍数时执行，N 为 1 时保持原有“每 tick 维护”的行为，nil 时关闭自动维护；  
    - 在 task 文件中记录该行为变更及推荐的验证方式。  
  - Related: `task013` (task_sync_improve_20251216)

- 2025-12-16 Modify  
  - Files:  
    - `supertag-services-sync.el`  
    - `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md`  
  - Changes:  
    - 在 sync 服务中新增文件级队列状态和基础 API（`supertag-sync--queue`、`supertag-sync-max-batch-size`、`supertag-sync-enqueue-file(s)`、`supertag-sync--dequeue-batch`、`supertag-sync-queue-empty-p`、`supertag-sync-process-queue`）；  
    - 将 `supertag-sync-full-rescan` 的实现改为：先收集目标文件，再通过队列 + `supertag-sync-process-queue` 分批处理，而不是在单个事务中一次性遍历所有文件；  
    - 保持 auto-sync 主循环 `supertag-sync--check-and-sync` 的行为不变，只影响手动 full rescan 路径。  
  - Notes: 当前队列实现仅用于手动 full rescan 的内部管线，后续可根据评估结果逐步接入 auto-sync。  
  - Related: `task008` (task_sync_improve_20251216)
