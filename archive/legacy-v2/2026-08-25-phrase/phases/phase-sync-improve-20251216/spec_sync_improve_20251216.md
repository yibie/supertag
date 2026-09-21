# spec_sync_improve_20251216: 同步服务改进（安全 / 可控 / 可观测）

## Summary

本阶段聚焦于改进 Org-supertag 的同步服务（`supertag-services-sync.el` 及相关模块），
目标是让“同步”变得更安全、更可控、更可观测，避免出现：

- Emacs 启动或执行一次同步就长时间卡死；
- 用户不清楚当前同步在干什么、是否可以安全终止；
- 默认配置对小仓库有效，但在大仓库或复杂环境下风险很高。

本阶段优先从“行为和配置”层面改进现有同步实现，而不是彻底重写。

## Goals

- 安全性
  - 默认行为在“普通用户 / 大仓库”场景下不会导致 Emacs 启动即卡死；
  - 自动同步（auto-sync）不会在用户不知情的情况下对大目录做重负载工作。
- 可控性
  - 用户可以通过少量明确的配置项（`defcustom`）控制是否自动启动、同步频率、监控目录范围；
  - 提供清晰的“手动同步”入口（如 `supertag-sync-full-rescan` / `supertag-sync-start-auto-sync`），并在文档中给出推荐用法。
- 可观测性
  - 同步过程有基础日志/状态反馈，用户能知道“现在在同步什么”、“大致进度如何”；
  - 在出现问题时，有简单的诊断/急停手段（如 emergency recovery / 停止定时器）。

## Non-goals

- 不在本阶段实现全新的同步架构（例如完全换成 file notification 或外部守护进程）；
- 不在本阶段调整核心数据模型（store/schema）语义，仅在必要时做兼容性修复；
- 不一次性解决所有性能问题，更偏向“避免最坏情况、让风险可控”。

## Known Pain Points / Context

- 当前版本中，当自动同步被启动（尤其是通过 `emacs-startup-hook`、`supertag-sync--auto-start-tick` 等路径）时，在某些环境下会出现：
  - Emacs 启动后显示 “Supertag: directories ready; starting auto-sync” 后长时间无响应；
  - 手动调用 `supertag-sync-start-auto-sync` 时卡死；
  - 重启 Emacs 时重复遇到同样问题，缺少快速的 emergency 停止入口。
- 同步行为与配置分散在多个变量与 hook 中（如 `supertag-sync-auto-start`、`org-supertag-sync-directories`、`emacs-startup-hook` 等），新用户难以一眼看出“当前到底会发生什么”。

## Acceptance Criteria

- 在默认配置下，Emacs 启动不会自动触发重型同步（尤其是对大目录），或至少提供明确且易用的方式关闭此行为；
- 有一份同步相关的文档（可以先从 `.phrase` spec 开始，后续再向 `doc/CONFIGURATION` 推广），说明：
  - 自动同步与手动同步的工作方式；
  - 推荐的配置模式（小库 / 大库 / 保守模式）；
  - 如何安全地启用或禁用 auto-sync；
  - 遇到卡顿时如何诊断与恢复。
- 在 `.phrase/phases/phase-sync-improve-20251216/task_sync_improve_20251216.md` 中有可执行的任务列表，并在 `change_*` 与 `.phrase/docs/CHANGE.md` 中可追溯。

## Current Sync Flow & Config（现状）

本小节仅描述当前实现状态，不代表理想设计，用于为改动提供基线。

### 启动路径与 Hook

- `emacs-startup-hook` → `supertag-init`（`org-supertag.el`）
  - `supertag-init` 在 Emacs 启动后自动执行，主要步骤：
    0. （可选）若用户将 `org-supertag-sync-directories-mode` 设为 `vaults` 且配置了多个 `org-supertag-sync-directories`，则先选择默认 Vault（活动目录），并将 DB/state 路径切换到该 Vault（单活跃 Vault 模式）；
    1. `supertag-persistence-ensure-data-directory`：确保数据目录存在；
    2. `supertag--check-critical-config`：检查 Vault 配置或 `org-supertag-sync-directories` 是否配置、目录是否存在；
    3. `supertag-sync-load-state`：加载文件级同步状态表（`supertag-sync--state`）；
    4. `supertag-load-store`：从数据库文件加载内存 store；
    5. `supertag--validate-initialization`：根据 DB 文件大小、节点数量给出诊断消息；
    6. `supertag-ops-schema-rebuild-cache`：重建 schema 相关缓存；
    7. `supertag-setup-all-timers`：持久化层的自动保存 / 每日备份定时器；
    8. （关键）若 `supertag-sync-auto-start` 非 nil，则调用 `supertag-sync-schedule-auto-start` 安排自动同步；
    9. 初始化 embed 服务、scheduler、全局补全 mode 等。
- `org-mode-hook`（在 `org-supertag.el` 末尾）  
  - `supertag-vault-auto-activate`：当配置了多个 `org-supertag-sync-directories` 时，更新 mode line 的 vault 提示；当 `org-supertag-vault-auto-switch` 为 t 且 `org-supertag-sync-directories-mode` 为 `vaults` 时，才会按 `buffer-file-name` 自动切换活跃 Vault；  
  - `supertag-sync-setup-realtime-hooks`：为 Org buffer 配置实时同步相关的 hook（例如保存时触发），细节在 `supertag-services-sync.el` 中实现。
- `kill-emacs-hook` 中相关项：
  - `supertag-save-store`：保存内存 store 至 DB；
  - `supertag-cleanup-all-timers`：清理持久化相关定时器；
  - `supertag-sync-save-state`：保存同步状态；
  - `supertag-sync-stop-auto-sync`：停止 auto-sync 定时器。

### Auto-sync 与定时器

- 自动启动配置（`supertag-services-sync.el`）
  - `supertag-sync-auto-start`（默认 t）  
    控制 Emacs 启动后是否通过 `supertag-init` 自动安排 auto-sync。
  - `supertag-sync-auto-start-initial-delay`（默认 3 秒）  
    首次尝试 auto-sync 的延迟时间。
  - `supertag-sync-auto-start-retry-interval`（默认 5 秒）  
    当目录尚不可用时，重试 auto-sync 的间隔。
  - `supertag-sync-auto-start-max-retries`（默认 24）  
    最大重试次数（默认约 2 分钟）。
  - 内部状态：
    - `supertag-sync--auto-start-timer`：用于 auto-start 重试的定时器；
    - `supertag-sync--auto-start-retries-left`：剩余重试次数。
- Auto-start 流程：
  1. `supertag-init` 检查 `supertag-sync-auto-start`，为 t 时调用 `supertag-sync-schedule-auto-start`；
  2. `supertag-sync-schedule-auto-start`：
     - 取消已有 auto-start 定时器；
     - 设置重试计数；
     - 使用 `run-with-timer` 安排周期性调用 `supertag-sync--auto-start-tick`；
  3. `supertag-sync--auto-start-tick`：
     - 若 `supertag-sync-auto-start` 已关闭 → 取消定时器；
     - 若 `supertag-sync--dirs-ready-p`（所有配置目录存在）为真：
       - 取消 auto-start 定时器；
       - 打印 `"Supertag: directories ready; starting auto-sync"`；
       - 调用 `supertag-sync-start-auto-sync`；
     - 若重试次数用尽 → 取消定时器并提示目录不可用；
     - 否则递减重试计数，等待下一次 tick。
- Auto-sync 主循环：
  - `supertag-sync-start-auto-sync`（交互命令，`;;;###autoload`）：
    - 取消已有 sync 定时器 `supertag-sync--timer`；
    - 通过 `supertag-sync--cancel-idle-dispatch` 清理 pending idle 调度；
    - 确保 `supertag--store` 已初始化；
    - 使用 `run-with-timer` 创建周期定时器：
      - 首次延迟固定 2 秒；
      - 间隔为 `supertag-sync-auto-interval`（默认 900 秒 = 15 分钟，或用户提供的 INTERVAL）；
      - 定时器回调调用 `supertag-sync--queue-idle-dispatch`。
  - `supertag-sync--queue-idle-dispatch`：
    - 若尚无 idle timer，则用 `run-with-idle-timer` 安排在空闲时间调用 `supertag-sync--run-idle-dispatch`；
    - idle 延迟由 `supertag-sync-idle-delay` 控制（默认 1.0 秒）。
  - `supertag-sync--run-idle-dispatch`：
    - 清除 idle 状态；
    - 调用 `supertag-sync--check-and-sync` 执行同步。
  - `supertag-sync-stop-auto-sync`（交互命令）：
    - 取消 `supertag-sync--timer` 并清理 idle dispatch。

### 核心命令与同步行为

- 手动命令：
  - `supertag-sync-start-auto-sync`：显式启动自动同步定时器（可手动调用而不依赖 auto-start）。
  - `supertag-sync-stop-auto-sync`：显式停止自动同步。
  - `supertag-sync-full-rescan`：
    - 收集所有需要管理的文件：
      - `supertag-scan-sync-directories t`（扫描目录获取所有符合 pattern 的文件）；
      - 以及当前 sync-state 表中的文件；
    - 过滤仅保留在同步范围内且为常规文件的 path；
    - 绑定 `supertag-sync--is-full-rescan-p` 为 t；
    - 在 `supertag-with-transaction` 中遍历每个文件：
      - 调用 `supertag-sync--process-single-file`，对每个文件执行解析、导入、删除 orphan 等操作；
      - 记录统计信息（创建/更新/删除的节点数量及引用）。
- 核心内部函数：
  - `supertag-sync--check-and-sync`：
    - 前置检查：若 `org-supertag-sync-directories` 未配置，则给出警告并返回；
    - 安全性检查：若 DB 为空但 sync-state 有文件，提示可能的数据丢失并建议 full rescan；
    - 在 `supertag-with-transaction` 中执行：
      - 清理不再在 scope 中的文件（从 sync-state 中移除，必要时清理节点）；
      - 扫描新文件（`supertag-scan-sync-directories`）并将结果与已修改文件合并；
      - 对每个需要处理的文件调用 `supertag-sync--process-single-file`。
  - `supertag-sync--process-single-file`：  
    - 内置内容 hash 变更检测，hash 未变则跳过解析；该行为默认开启且不可配置。

### 关键配置项（defcustom）

- 目录与范围：
  - `org-supertag-sync-directories`：  
    同步监控的目录列表（绝对路径），是 auto-sync 和扫描的核心配置。若未设置，同步逻辑大多会提前返回并给出警告。
  - `supertag-sync-exclude-directories`：  
    排除同步的目录列表，优先级高于包含目录。
  - `supertag-sync-file-pattern`：  
    用于匹配要同步的文件（默认 `"\\.org$"`）。
- 同步节奏：
  - `supertag-sync-auto-interval`：  
    auto-sync 定时器的执行间隔（秒）。
  - `supertag-sync-idle-delay`：  
    idle timer 在执行实际 sync 前等待的空闲时间（秒）。
  - `supertag-sync-quiet-when-idle`：  
    当 sync 结果为空、且为 idle 触发时，是否静默输出。
- 自动启动：
  - `supertag-sync-auto-start` 及其 delay/retry 配置（见上文 Auto-sync 小节）。
- Tag 与迁移策略（和 sync 行为相关，但不在本阶段深入）：
  - `supertag-tag-style`：写回 Org headline 时如何处理标签（inline/org/both/auto）。
  - `supertag-sync-legacy-tags-policy`：如何处理旧的 Org 原生 `:tag:`。

上述现状说明将作为后续任务（如引入文件队列、调整 auto-start 默认值）的基线，后续改动需在本节基础上明确“行为变化点”。

## Safer Default Behavior Design（更安全的默认行为设计）

本小节在现状基础上，约定本阶段要达成的“默认行为”目标，用于指导后续实现与文档更新。

### 默认模式与用户心智

为避免“安装即自动扫全库、启动就卡死”的体验，同时尊重用户通过
`org-supertag-sync-directories` 显式指定同步范围这一事实，同步行为
分为三种清晰模式：

1. **手动同步模式（Manual-Only，推荐给大仓库/谨慎用户）**
   - 特点：
     - 启动时不自动开启 auto-sync 定时器（例如用户显式将 `supertag-sync-auto-start` 设为 nil）；  
     - 不对任何目录做隐式扫描或 full rescan；  
     - 用户通过显式命令触发同步（如 `supertag-sync-full-rescan` 或未来的更细粒度命令）。
   - 行为：
     - `supertag-init` 仍然负责加载数据库、sync-state、定时保存/备份等，但不再默认调用 `supertag-sync-schedule-auto-start`；  
     - 用户想开启自动同步时，需要在配置中显式设置变量或调用命令。

2. **安全自动模式（Safe Auto-Sync，配置了同步目录后的默认模式）**
   - 特点：
     - 用户通过设置 `org-supertag-sync-directories` 明确 opt-in 之后，在 `supertag-sync-auto-start` 为非 nil 时，才会在启动后自动安排 auto-sync；  
     - auto-sync 每次处理的工作量有限（例如通过队列和批大小控制），避免长时间阻塞；  
     - 对大目录或未知规模仓库，建议用户先以手动模式完成首轮 full rescan，再启用安全自动模式。
   - 行为（设计目标）：
     - 当用户将某个变量（例如 `supertag-sync-auto-start` 或更细粒度的选项）设为开启时：  
       - `supertag-sync-schedule-auto-start` 仍然使用延迟 + 重试机制，但应在文档中明确标注“适合中小规模仓库”；  
       - auto-sync 的 worker（`supertag-sync--check-and-sync` 或其队列化版本）应尽量按小批量工作，避免一次扫描/处理所有文件。

3. **高级自动模式（Aggressive / Expert）**
   - 特点：
     - 面向熟悉 org-supertag 的高级用户或较小仓库；  
     - 可以启用更频繁的同步、更大的批次甚至“全量扫描”，但应通过配置和文档明确标记风险。
   - 行为：
     - 通过 defcustom 或配置片段提供示例，但不作为默认推荐路径；  
     - 可结合 future queue 设计，为高级用户保留“强制立即处理全部队列”的命令或选项。

### 变量与默认值的方向性调整（设计意图）

结合上述模式，本阶段对配置的设计意图如下（具体实现放在后续 task）：

- `supertag-sync-auto-start`
  - 当前：默认 `t`，在 `supertag-init` 中被读取；仅当用户已经设置了 `org-supertag-sync-directories` 且这些目录存在时，auto-start 逻辑才真正生效。  
  - 目标：将其明确为“在已配置同步目录的前提下，是否自动启动安全 auto-sync”的开关：  
    - 保持默认值为 `t`，但在文档中强调：只有在用户显式配置了同步目录后才会实际自动同步；  
    - 对需要完全手动控制的大仓库或谨慎用户，推荐在个人配置中显式 `(setq supertag-sync-auto-start nil)` 以启用“手动同步模式”。

- `org-supertag-sync-directories`
  - 仍然是同步范围的核心配置，但需要：
    - 在初始化检查中明确告知：未配置 → 不会自动同步，只能手动调用 full rescan / 单文件同步；  
    - 在文档中给出几种典型配置（单目录、多目录、排除目录等）。

- 定时与 idle 配置（`supertag-sync-auto-interval`、`supertag-sync-idle-delay`）
  - 保持现有语义，但在配置文档中给出推荐区间：
    - 大仓库：更长的 interval、更大的 idle delay；  
    - 小仓库：可以适当缩短，但仍建议使用队列 + 批处理限制单次工作量。

### 行为变更边界与兼容性策略

- 对新用户：
  - 默认安装后，若未配置 `org-supertag-sync-directories`，则不会自动同步任何内容，只能通过手动命令触发；  
  - 一旦用户显式配置了同步目录，即视为 opt-in 到“安全自动模式”，此时 auto-start 默认生效，但应保证每次同步工作量可控（结合队列与批处理）；  
  - 文档中需要明确指引：如何执行第一次 full rescan，以及在大仓库场景下如何改用“手动同步模式”（关闭 auto-start）。
- 对现有用户：
  - 若直接修改 `supertag-sync-auto-start` 的默认值为更保守，需要：
    - 在 CHANGELOG / 文档中标注 breaking change 风险；  
    - 提供简单迁移建议（例如在个人配置中显式 `(setq supertag-sync-auto-start t)` 保持旧行为）。  
  - 或者采用兼容策略：
    - 在首次加载新版本时检测某些迹象（如用户显式配置过该变量），仅对“未配置过”的用户采用新默认策略。

以上设计作为 task003 的“目标行为说明”，后续具体代码修改与用户文档更新需以此为依据，并在变更记录中明确指出哪些行为从“现状”小节发生了改变。

## File-Level Queue Direction（文件级队列方向性说明）

结合 tech-refer 中的探索，本阶段对“文件级队列 + 批处理”的方向性约定如下（具体实现由后续 task 落地）：

- 队列作为 sync 的“工作分发层”：
  - *Discovery*（发现需要处理的文件）：继续由现有的扫描与状态检查逻辑负责（如 `supertag-scan-sync-directories`、`supertag-get-modified-files` 等）；  
  - *Queuing*（入队）：新增内部队列（如 `supertag-sync--queue` 及帮助函数），负责对文件 path 去重并记录待处理项；  
  - *Processing*（消费）：通过一个明确的入口（如 `supertag-sync-process-queue`），每次取小批量文件，在 `supertag-with-transaction` 中统一处理。

- 与手动 / 自动同步的关系：
  - 手动命令（例如 `supertag-sync-full-rescan`）将改为：
    - 先发现目标文件集合；  
    - 再调用队列 API 入队；  
    - 然后以批处理方式消费队列，而不是一次性在一个大循环中处理所有文件。  
  - 自动同步（auto-sync）在逻辑上与手动命令共享同一套队列：
    - timer/idle 回调不直接处理所有需要同步的文件，而是只负责“发现 + 入队 + 处理一小批”；  
    - 剩余工作留给后续 tick/idle 周期，避免单次执行时间过长。

- 与 `supertag-with-transaction` 的配合：
  - 每个批次在一个事务中完成：解析文件 → 调用 extractor / ops → 更新 store；  
  - 批次结束时，由现有的通知与持久化逻辑负责一次性刷新 UI、标记 dirty 状态与调度保存；  
  - 出错时（例如单个文件解析失败），应通过 `condition-case` 捕获，记录错误并继续处理其它文件，避免整个批次中断（具体策略由实现时细化）。

该方向性说明为 task007/008 的实现提供框架约束，确保后续落地不会偏离“队列 + 批处理 + 事务”的整体思路。

## Auto-sync Migration Plan（auto-sync 向队列模型迁移规划）

在已有文件队列基础上，auto-sync 的迁移目标与步骤规划如下（本阶段仅规划，不直接改动实现）：

### 迁移目标

- 保持用户界面与主要命令不变：
  - 仍使用 `supertag-sync-start-auto-sync` / `supertag-sync-stop-auto-sync` 控制自动同步；
  - 仍通过 `supertag-sync-auto-interval` / `supertag-sync-idle-delay` 控制节奏；
  - 仍由启动路径 `supertag-init` + `supertag-sync-schedule-auto-start` 负责 auto-start。
- 将 auto-sync 的“工作执行方式”从“每次扫描+处理所有目标文件”逐步迁移到：
  - 每次 timer/idle tick 只完成“发现 + 入队 + 处理一小批”；
  - 剩余工作通过后续 tick 渐进完成，减少单次卡顿风险。

### 阶段性步骤

1. **进队列，但保留现有处理逻辑（过渡阶段）**
   - 在 `supertag-sync--check-and-sync` 中：
     - 保留现有清理 sync-state、验证 DB 状态的逻辑；  
     - 对 `modified-files` 和新发现的文件，除了直接处理外，同时调用 `supertag-sync-enqueue-files` 入队（仅作为观察队列行为的过渡步骤）。  
   - 目的：在不改变行为的前提下，观察队列在实际环境中的大小与演化模式，为下一步“只走队列”提供信心。

2. **将 auto-sync 的文件处理改为“只通过队列”**
   - 调整 `supertag-sync--check-and-sync`：
     - 仍负责：
       - 清理不在 scope 中的文件（state cleanup）；
       - 扫描新文件、识别修改文件；  
     - 但不再直接对每个 file 调用 `supertag-sync--process-single-file`，而是：
       - 对需要处理的文件调用 `supertag-sync-enqueue-files`；  
       - 调用一次 `supertag-sync-process-queue`，仅处理一批队列中的文件。  
   - 这样，每个 timer/idle tick 的工作量自然限制在 `supertag-sync-max-batch-size` 以内，避免单次长时间阻塞。

3. **为 auto-sync 引入简单观测与调优钩子**
   - 在 auto-sync 路径中补充最小观测点：
     - 可选 debug 命令或变量，用于查看队列长度（例如 `supertag-sync-queue-empty-p` 的包装命令）；  
     - 在非 quiet 模式下，定期打印“本次 tick 处理了多少文件 / 当前队列长度”的诊断信息。
   - 如有需要，为大仓库用户提供额外 defcustom：
     - 限制 auto-sync 每次允许处理的最大批次数（例如 per tick 只调用若干次 `supertag-sync-process-queue`）；  
     - 或在队列长度超过一定阈值时，提示用户考虑手动 full rescan 或临时关闭 auto-sync。

4. **文档与配置层面的同步更新**
   - 在对外配置文档（未来的 `doc/CONFIGURATION-*`）中：
     - 明确 auto-sync 目前基于队列 + 批处理，每个 tick 的工作量受 `supertag-sync-max-batch-size` 控制；  
     - 给出针对大仓库 / 小仓库的推荐设置（batch size、interval、idle delay）；  
     - 说明如何通过队列观测命令诊断“为什么同步还没完成”。

5. **保守回退与兼容性**
   - 保留一个“兼容模式”或调试开关（例如 defcustom 或内部变量），在必要时允许：
     - 暂时回退到旧的“每次直接处理所有 modified-files”路径，用于调试或紧急情况；  
   - 在 CHANGELOG 中记录：
     - auto-sync 工作方式从“同步处理所有文件”迁移为“队列化批处理”的差异；  
     - 对用户的预期影响（同步变得更平滑，但可能不再在单次 tick 内处理完所有 backlog）。

以上规划作为 task009 的产出，为后续实际调整 `supertag-sync--check-and-sync` 和相关 timer/idle 逻辑提供路线图，同时保证有明确的兼容与观测策略。

## Live Org Buffer Cache Invariant

由全局保存 hook 发起的跨 buffer 写入必须遵守以下约束：

- 不得把 `inhibit-modification-hooks` 动态传播到 `save-buffer`、全局保存回调或其他 buffer；
- 若为兼容 `org-indent-mode` 必须屏蔽 modification hooks，只允许覆盖实际文本替换；
- 屏蔽期间不得读取旧 element cache，退出时必须无条件执行 `org-element-cache-reset`；
- 不以全局关闭 `org-element-use-cache` 作为规避方案。

## Org Parser Context Invariant

- 可被多个同步路径调用的 parser 必须自行确保 current buffer 是 `org-mode`，
  不得假定调用者已完成 major-mode 初始化。
- parser 必须使用当前 Org TODO 配置，将 TODO 关键字保存到 `:todo`，
  不得并入 `:title`、`:raw-value` 或 `:olp`。
- `supertag-sync-full-rescan` 必须忽略 content-hash 快速路径，以便在 parser 规则
  修复或配置更正后重建持久化数据。
