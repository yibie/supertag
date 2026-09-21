# plan_sync_improve_20251216: 同步服务改进计划

## Milestones

1. 梳理现有同步路径与配置项（文档化现状）
2. 在 tech-refer 中确定“文件队列 + 批处理”的目标设计，并对齐 =supertag-with-transaction= 的角色
3. 基于设计实现最小可用的文件级队列（先用于手动 sync，再视情况接入 auto-sync）
4. 定义并实现更安全的默认行为（尤其是自动同步的默认开关与启动路径）
5. 规划 auto-sync 向队列模型迁移的方案，并分阶段落地
6. 改进可观测性和诊断手段（日志、命令、emergency recovery）
7. 更新配置文档与示例（推荐几套同步配置模式）
8. 保证全局保存 hook 发起的跨 buffer Org 写入不会绕过 element cache 失效通知
9. 保证所有文件同步入口在 Org parser context 中解析，并让 full rescan 可修复已持久化的错误结果

## Scope

- 主要关注 `supertag-services-sync.el` 及与同步密切相关的配置（包括 auto-start 逻辑、定时器和目录扫描）；
- 在必要时可以调整 `org-supertag.el` 中与 sync/init 相关的 hook 绑定，但应保持用户可 opt-out；
- 统一 smart detection 默认行为并清理遗留开关，保持同步解析路径一致；
- 可以提出并实现小范围的重构（例如拆分“同步核心逻辑”和“自动启动管理”），但避免大手术。
- embed 必须继续兼容现有 `org-indent-mode` 环境；若写入时屏蔽 modification hooks，写入边界必须显式重置 Org element cache。
- 公共 Org parser 不得依赖调用者的 major mode；`supertag-sync-full-rescan` 不得因 content hash 未变而跳过重解析。

## Priorities

1. 先避免“Emacs 启动/手动开启 auto-sync 立即卡死”的最坏体验（通过 safer 默认行为和明确的 auto-start 开关）；
2. 其次通过文件级队列 + 批处理，让同步过程在大仓库下也具备基本的可控性（批大小、可观测队列长度）；
3. 再通过日志、诊断命令和 emergency 工具提升可观测性；
4. 最后用配置文档沉淀几套“推荐同步模式”，方便不同规模的用户按需选择。

## Risks & Dependencies

- 与用户现有配置可能存在行为变化（例如将 auto-start 默认改为更保守的值），需要在文档中清楚解释；
- 某些问题可能源于外部环境（如网络文件系统、大量文件或特别复杂的 Org 文档），需要通过日志/文档引导用户自查；
- 与后续架构演进（例如引入文件监控/增量同步）存在潜在耦合，需要在本阶段 spec 中记录好决策与边界。
