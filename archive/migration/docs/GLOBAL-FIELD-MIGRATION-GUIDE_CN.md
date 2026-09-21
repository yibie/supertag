## Supertag – 全局字段数据库迁移指引

本指南说明如何把旧的「按 Tag 嵌套字段」模型迁移到「全局字段模型」。在新模型中，字段是有稳定 ID 的一等实体，不再由单个 Tag 独占。

> **重要：** 在执行任何迁移操作前，请先为当前 Supertag 数据目录做一次完整备份。

全局字段模型现已成为唯一生产读写路径。`supertag-use-global-fields` 已废弃；即使设为 `nil`，也不会重新打开旧存储。

### 1. 先执行只读审计

```elisp
(require 'supertag)
(require 'supertag-migration)
(supertag-migration-audit-global-fields)
```

交互调用会打开 `*supertag-migration*`。报告会逐项比较旧字段定义与全局定义、有序 Tag/字段关联、继承字段值、仅存在于全局模型的值、孤立值和备份预检。只有 `:safe-to-apply t` 才能继续；定义冲突、显示名歧义、同一 node/field 多值、孤立 owner 或畸形关联都会 fail closed。审计不会修改 Store 或数据库文件。

### 2. 运行 Dry-Run

先做一次「演练」迁移，不写入任何数据，只查看将要发生的变更：

```elisp
(require 'supertag)
(require 'supertag-migration)

;; 确认 dry-run 打开（默认即为 t）
(setq supertag-migration-dry-run t)

;; Dry-run：只扫描与记录，不写入
(supertag-migration-run-global-fields)
```

该命令复用同一审计结果。重点检查 definition/association mapping、逐 node/field parity、冲突、孤立项和备份 SHA-256。数据不变时，重复运行会得到与 hash-table 插入顺序无关的同一报告。

### 3. 确认备份后执行真实迁移（写入）

只有报告为 `:safe-to-apply t` 时才执行：

```elisp
(require 'supertag-migration)

;; 关闭 dry-run，或在调用时传入前缀参数 / FORCE-WRITE
(setq supertag-migration-dry-run nil)

;; 执行实际迁移（会写入到 store）
(supertag-migration-run-global-fields t)
```

这一步会：

- 将按 Tag 定义的字段去重合并，写入全局字段定义 `:field-definitions`。
- 为每个 Tag 生成有序的字段关联，写入 `:tag-field-associations`。
- 将旧的嵌套字段值（node → tag → field）重写为扁平的 `:field-values`（node-id → field-id → value）。
- 在 `*supertag-migration*` 里输出汇总统计和详细冲突信息。

写入入口会在修改前重新审计，发现冲突或孤立项就零写入退出；它不会自行选择覆盖方。第一次写入前还会把当前内存 Store 序列化到 `backups/supertag-db-preglobal-fields-*.el`，因此未保存到主数据库文件的内存状态也受保护。

### 4. 验证并继续使用全局字段模型

迁移完成后：

- 从配置中删除 `supertag-use-global-fields`；它已经废弃。
- 通过以下方式确认数据正确性：
  - 打开表格视图 / Node 视图 / 看板视图，检查字段展示是否正确且没有重复字段。
  - 修改某些字段值，确认已有的自动化规则（例如使用 `field-equals` / `field-changed` 的规则）能正常触发。
  - 执行你日常使用的查询与 capture 流程，看结果是否与预期一致。

如发现异常，可参考：

- `doc/global-field-migration-rfc.md` —— 全局字段设计与冲突处理策略。
- `doc/global-field-migration-plan.md` / `doc/global-field-migration-tasks.md` —— 分阶段迁移计划与任务清单。

迁移完成后，`:field-definitions`、`:tag-field-associations`、`:field-values` 立即成为唯一权威字段存储。旧 `:fields` 仅供迁移/兼容基础设施读取；日常 field、schema、view、query、capture 和 automation 都不会读取或继续增长它。
