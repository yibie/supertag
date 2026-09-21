# task_sync_improve_20251216

- task001 [x] 建立同步改进 phase 文档骨架  
  - 产出：`spec_sync_improve_20251216.md` / `plan_sync_improve_20251216.md` / `task_sync_improve_20251216.md` / `change_sync_improve_20251216.md`  
  - 验证方式：上述文件存在且围绕“同步服务改进（安全 / 可控 / 可观测）”的目标（手动检查）  
  - 影响范围：仅内部文档结构

- task002 [x] 梳理现有同步路径与配置项（现状文档）  
  - 产出：在 `spec_sync_improve_20251216.md` 中增加“Current Sync Flow & Config” 小节，标出：  
    - auto-sync 启动路径（如 `emacs-startup-hook` → `supertag-init` → `supertag-sync-schedule-auto-start`）；  
    - 核心命令（`supertag-sync-start-auto-sync` / `supertag-sync-stop-auto-sync` / `supertag-sync-full-rescan` 等）；  
    - 关键 `defcustom` 变量及其默认值。  
  - 验证方式：对照 `supertag-services-sync.el` 与 `org-supertag.el`，确认列出的路径与变量与代码一致（本次已完成）；后续改动同步更新本小节。  
  - 影响范围：内部文档，对行为无直接修改。

- task003 [x] 设计并记录更安全的同步默认行为  
  - 产出：在 `spec_sync_improve_20251216.md` 中明确：  
    - auto-sync 默认是否开启以及推荐的“手动同步模式 / 安全自动模式 / 高级自动模式”；  
    - 在大目录/未知环境下推荐的“保守默认配置”方向；  
    - 对现有用户的兼容策略（例如通过变量或迁移提示）和可能的 breaking change 风险提示。  
  - 验证方式：评审文档中“Safer Default Behavior Design” 小节是否覆盖“安全/可控”目标，后续实现与配置文档更新时以此为蓝本。  
  - 影响范围：文档与后续实现设计。

- task004 [x]（后续）根据 spec 调整代码与配置，并补充用户向文档  
  - 产出：  
    - 针对 auto-sync、定时器、hook 绑定的具体代码改动；  
    - 一份面向用户的同步配置文档草稿（可以是 `doc/CONFIGURATION-*` 或在现有 README/doc 中新增章节）。  
  - 验证方式：  
    1. 在实际环境中验证 Emacs 启动与手动同步行为可控且无明显卡死；  
    2. 对照 spec 检查实现是否符合既定目标；  
    3. 用户文档与代码行为一致。  
  - 影响范围：同步实现与用户配置体验（需谨慎迭代）。

- task005 [x] 为同步改进建立 tech-refer（架构与选项）  
  - 产出：=tech-refer_sync_improve_20251216.org=，梳理：  
    - 现有 store/notify/transaction/sync 的调用关系；  
    - =supertag-transform= 的实际使用情况与遗留性质；  
    - 借鉴 Vulpea 架构文档得到的“文件队列 + 批处理”思路；  
    - 针对本阶段的技术选项与初步决策（例如移除 =supertag-transform=、保留 =supertag-with-transaction=）。  
  - 验证方式：手动检查 tech-refer 是否覆盖以上要点，并与 =spec_sync_improve_20251216.md= 中的目标保持一致。  
  - 影响范围：仅内部技术决策文档，对行为无直接修改。

- task006 [x] 移除 =supertag-transform= 及相关引用，并校正文档叙述  
  - 产出：  
    - 在 =supertag-core-transform.el= 中移除未被使用的 =supertag-transform=、=supertag-batch-transform=、=supertag-transform-pattern= 及其辅助匹配函数，仅保留事务相关和纯辅助函数；  
    - 更新 =doc/COMPARE-NEW-OLD-ARCHITECTURE*.md= 中对“单一变更网关”的描述，使其改为围绕 ops + =supertag-with-transaction= 的真实路径；  
    - 确认代码中不再存在对 =supertag-transform= 的调用（除文档外）。  
  - 验证方式：  
    1. 使用 =rg \"supertag-transform\"= 确认仅剩工具函数引用（如 =supertag-transform-extract-inline-tags=）而不再有“全局变更网关”实现及描述；  
    2. 在本地 Emacs 中加载相关模块（至少 =supertag-core-transform.el= 和主要调用它的模块），确保无编译/加载错误；  
    3. 简单运行几个依赖 =supertag-with-transaction= 的操作（如节点创建/删除）确认行为未变。  
  - 影响范围：内部抽象与文档叙述，对外 API（ops 与 transaction）保持兼容。

- task007 [x] 设计并记录文件级队列 + 批处理在 sync 中的具体落地方案  
  - 产出：在 `tech-refer_sync_improve_20251216.md` 和 `spec_sync_improve_20251216.md` 中补充：  
    - 内部状态与 API 草图（如 `supertag-sync--queue`、`supertag-sync-enqueue-file`、`supertag-sync-process-queue` 等）；  
    - 手动 sync / auto-sync 与队列的集成方式（谁发现文件、谁入队、谁消费）；  
    - 批大小、错误处理和基本日志/诊断约定。  
  - 验证方式：检查文档是否给出了清晰的调用关系和约束（队列如何与手动 sync / auto-sync / 事务配合），并与 `plan_sync_improve_20251216.md` 中的 Milestones 保持一致。  
  - 影响范围：技术设计与约束，不直接改动行为。

- task008 [x] 在 sync 服务中实现最小可用的文件级队列（仅接入手动 sync）  
  - 产出：  
    - 在 `supertag-services-sync.el` 中实现队列状态与基础 API（enqueue/dequeue/process）；  
    - 调整至少一个手动 sync 命令（例如 full rescan 或“同步已修改文件”）改为通过队列 + `supertag-with-transaction` 批量处理；  
    - 适当的 debug 日志或临时诊断命令（例如查看队列长度）。  
  - 验证方式：  
    1. 在中小规模仓库上手动触发 `supertag-sync-full-rescan`，观察 UI 是否更平稳（避免一次处理所有文件而长时间阻塞）；  
    2. 检查队列在多次调用、失败情况下是否能被正确清理或复用；  
    3. 确认现有自动同步行为（`supertag-sync--check-and-sync` 及相关定时器）暂不改变，仅手动 full rescan 路径走新队列。  
  - 影响范围：sync 实现细节，对用户行为有轻微但可预期的改善。

- task009 [x] 评估并规划 auto-sync 向队列模型迁移的方案  
  - 产出：在 `spec_sync_improve_20251216.md` 或 tech-refer 中新增一小节，说明：  
    - auto-sync 如何使用同一套队列/批处理接口；  
    - 在大仓库下如何限制每次 timer tick 处理的批大小；  
    - 如何保持 backward compatibility（例如提供可选开关或兼容模式）。  
  - 验证方式：检查 “Auto-sync Migration Plan” 小节是否覆盖以上要点，并与现有 auto-sync 现状描述一起形成清晰的迁移路线。  
  - 影响范围：规划与设计，不立即改代码。

- task010 [x] 技术调研与约束梳理：auto-sync 中 `supertag-sync--check-and-sync` 的重构空间  
  - 产出：在 `tech-refer_sync_improve_20251216.md` 中补充一小节，分析：  
    - `supertag-sync--check-and-sync` 现有各步骤的职责（state cleanup / modified-files 处理 / orphan 检查 / validate-nodes）；  
    - 哪些步骤适合迁移到“队列 + 批处理”路径，哪些应保持同步执行；  
    - 将 validate / orphan 检查放在每个 tick vs 定期/手动触发的利弊。  
  - 验证方式：自查 tech-refer，确认列出了至少两三种可行重构方案，并标注了风险点。  
  - 影响范围：仅技术分析，不改代码。

- task011 [x] 在 auto-sync 路径中引入受控的队列处理（第一阶段）  
  - 产出：  
    - 在 `supertag-services-sync.el` 中，为 `supertag-sync--check-and-sync` 增加队列交互（例如对 modified/new files 调用 `supertag-sync-enqueue-files`）；  
    - 引入一个内部开关或 defcustom（如 `supertag-sync-auto-use-queue`，默认 nil），在开启时通过 `supertag-sync-process-queue` 处理一小批文件，同时保留原有直接处理逻辑作为兼容路径；  
    - 保证处理统计和日志输出仍然准确。  
  - 验证方式：  
    1. 在小仓库启用该开关，观察 auto-sync 是否能分批处理，而关闭开关仍保持旧行为；  
    2. 检查 `supertag-sync--check-and-sync` 中 state cleanup / orphan 检查 / validate-nodes 行为未被意外改变。  
  - 影响范围：auto-sync 实现细节，默认行为可通过开关保持兼容。

- task012 [x] 将队列处理升级为 auto-sync 的默认路径，并完善观测与回退机制  
  - 产出：  
    - 根据 task011 的实验结果，决定是否将队列处理开关默认打开（或改为仅在特定条件下启用，如 `org-supertag-sync-directories` 已配置且节点数/文件数达到某阈值）；  
    - 补充用于观测队列和批次行为的轻量命令或日志（例如显示队列长度、上一次 tick 处理的文件数）；  
    - 实现一个回退开关或“兼容模式”，在需要时可以暂时恢复旧的 auto-sync 行为。  
  - 验证方式：  
    1. 在中等规模仓库上测试默认配置，确认 auto-sync 不再出现明显长时间卡顿（结合队列与维护频率配置）；  
    2. 通过回退开关验证可以安全切回旧行为；  
    3. 对比 spec 中的 “Auto-sync Migration Plan”，确保最终实现与规划一致。  
  - 影响范围：auto-sync 默认行为与性能特征，需谨慎验证。

- task013 [x] 为 orphan/validate 引入可配置的低频维护机制  
  - 产出：  
    - 在 `supertag-services-sync.el` 中新增 `supertag-sync-maintenance-every-n-ticks` 与内部计数器 `supertag-sync--maintenance-counter`；  
    - 将 `supertag-sync--check-and-sync` 中的 `supertag-sync-validate-nodes` 调用和事后 `supertag-sync-garbage-collect-orphaned-nodes` 包装为“仅在 N 次 tick 触发一次”，N 可配置，为 1 时保持原有“每 tick 维护”的行为，nil 时完全依赖手动维护命令。  
  - 验证方式：  
    1. 在小/中等仓库上分别配置不同的 `supertag-sync-maintenance-every-n-ticks`（如 1 / 10 / nil），观察 auto-sync 的响应性和 orphan 清理情况；  
    2. 确认 `supertag-sync-cleanup-database` 等手动维护命令仍能用于随时触发一次完整的 orphan/validate；  
    3. 检查 `supertag-sync--check-and-sync` 其余步骤（state cleanup、队列处理等）未受影响。  
  - 影响范围：auto-sync 维护策略，可通过配置恢复旧行为。

- task014 [x] 修复 sync state 的时间比较错误（Invalid time specification）  
  - 产出：  
    - 修复 `supertag-sync-check-state` 在 state entry 为 plist 时错误传入 `time-less-p` 的问题，确保只比较合法的 time 值；  
    - 增加最小回归测试覆盖 plist 形式的 `:mtime`。  
  - 验证方式：  
    1. `emacs -Q --batch -L . -l test/supertag-services-sync-test.el -f ert-run-tests-batch-and-exit`；  
    2. 手动：加载 `org-supertag.el` 后调用 `M-x supertag-get-modified-files`，确认不再出现 `Invalid time specification`。  
  - 影响范围：sync state 检查逻辑（仅修复，行为更稳健）。

- task015 [x] 引入单活跃 Vault 模式（每 Vault 独立 DB/state）  
  - 产出：  
    - 复用用户配置 `org-supertag-sync-directories`（允许 `~`），并新增 `org-supertag-sync-directories-mode`（`unified`/`vaults`）控制是否启用 Vault 隔离；  
    - 启用 Vault 模式时：为每个 Vault 使用独立的 `supertag-db-file` / `supertag-sync-state-file`（存放于 `supertag-data-directory/vaults/`），sync 实际 scope 使用当前活跃 Vault 的根目录；  
    - 提供命令 `supertag-vault-activate`；在 `org-mode-hook` 中默认仅更新 mode line vault 提示，按 `buffer-file-name` 自动切换活跃 Vault 需要显式开启 `org-supertag-vault-auto-switch`；  
    - auto-sync 仅对当前活跃 Vault 生效（切换 Vault 时停止/重启 auto-sync）。  
  - 验证方式：  
    1. 配置两个 Vault（不同目录），分别打开目录下的 Org 文件，观察消息区提示 active vault 切换；  
    2. 确认不同 Vault 会生成不同的 DB 文件与 sync-state 文件（位于各自 `.../vaults/<id>/`）；  
    3. 在其中一个 Vault 下执行 `M-x supertag-sync-full-rescan`，确认只处理该 Vault 目录范围内的文件。  
  - 影响范围：初始化、持久化路径与 sync scope；默认（未配置 Vault）行为保持兼容。

- task016 [x] 取消 smart sync detection 开关，改为默认启用  
  - 产出：  
    - 在 `supertag-services-sync.el` 中移除 `supertag-sync-smart-detection-*` 分支与日志开关，smart detection 常开；  
    - 在 `spec_sync_improve_20251216.md` 中补充：`supertag-sync--process-single-file` 的 smart detection 行为不可配置；  
    - 在 `change_sync_improve_20251216.md` 记录变更条目。  
  - 验证方式：  
    1. `rg -n "smart-detection" supertag-services-sync.el` 确认无开关残留；  
    2. 手动执行 `M-x supertag-sync-full-rescan`，确认同步正常且无报错。  
  - 影响范围：同步解析路径；移除用户对 smart detection 的显式开关能力。

- task017 [x] 在 README 与 CHANGELOG 记录 smart scan 行为  
  - 产出：  
    - `README.md` 与 `README_CN.md` 增加 smart scan 工作原理说明，强调避免误触发导致数据库意外清空；  
    - `CHANGELOG.org` 记录 smart scan 常开与行为说明；  
    - 在 `change_sync_improve_20251216.md` 记录变更条目。  
  - 验证方式：  
    1. 手动检查 README/README_CN 的“配置”段落已包含 smart scan 说明；  
    2. 检查 `CHANGELOG.org` 顶部条目包含该变更。  
  - 影响范围：用户文档与版本记录。

- task018 [x] 发布 v5.6.3  
  - 产出：  
    - 更新 `org-supertag.el` 的 `Version` 字段为 5.6.3；  
    - 创建 annotated tag `v5.6.3`；  
    - 在 `change_sync_improve_20251216.md` 记录变更条目。  
  - 验证方式：  
    1. `rg -n "Version: 5.6.3" org-supertag.el`；  
    2. `git tag -n9 v5.6.3` 能看到标注信息。  
  - 影响范围：发布版本元数据与 tag。

- task019 [x] 修复 embed 跨 buffer 写入后的 Org element cache 失效
  - 产出：
    - 在 `supertag-services-embed--render-node-to-file` 的真实写入边界保证 cache reset；
    - 保留 `inhibit-modification-hooks`，避免复活既有 Doom/`org-indent-mode` 冲突；
    - 新增并接入 `test/embed-cache-test.el`。
  - 验证方式：
    1. 修复前 `./test/run-tests.sh embed` 因 cache buffer size/tick 不一致失败；
    2. 修复后 embed 回归与默认测试集通过；
    3. `bash -n test/run-tests.sh` 与 touched-file byte compile 通过。
  - 影响范围：embed 保存同步写入、Org element cache 一致性；不改变用户命令或数据格式。

- task020 [x] 修复后台同步将 TODO 关键字并入 node title
  - 产出：
    - `supertag--parse-org-nodes-from-current-buffer` 自行初始化无 hook 的 `org-mode` parser context；
    - `supertag-sync-full-rescan` 即使 content hash 未变也强制重解析，用于修复旧 DB 污染；
    - 新增自定义 `DOING` 解析与 unchanged-file full-rescan 回归测试。
  - 验证方式：
    1. 修复前两条新回归分别得到 `:todo nil` 和“未调用 parser”；
    2. `./test/run-tests.sh extractor sync-worker`：23/23 通过；
    3. `./test/run-tests.sh all`：297/297 通过；
    4. `git diff --check`、`check-parens` 与 touched-file byte compile 通过。
  - 影响范围：Org 文件同步解析与手动 full rescan；不改变用户 TODO 配置或 node 数据格式。
  - Related: `issue020`
