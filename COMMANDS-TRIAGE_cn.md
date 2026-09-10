# 命令清单去留（对照 MODEL_CN.md）

Status: 已确认命令决定的历史追踪；不是当前发行或删除清单
Date: 2026-09-04
Scope: `emacs --batch` 加载 `supertag.el` 后，`commandp` 且以 `supertag` 开头的全部符号

> 生成方式：批处理 Emacs 加载源码，遍历 obarray 取交互命令，共 287 条。归类按 [MODEL_CN.md](./MODEL_CN.md) 的决定机械套用，再手工修正边角。归类是给人看的草稿，不是决定。


## 阅读说明

“留”保留用户能力，不永久冻结旧API；“封存”不计默认保留；“删”不授权清除历史事实。
第3节原符号、第4节讨论和第5节目标入口不能作为整文件删除或当前API已发布的证明。
分类中的“未定0”仅描述当时命令表的分类，不代表未知协议、配置转换、检索隐私、
Embark情景等产品门已解决。

## 1. 汇总

面向用户的下一版本入口清单见 [第 5 节](#5-下一版本用户入口清单)。第 3 节保留原始符号用于追踪，第 5 节使用已确认的目标名称；这是设计清单，不是当前版本使用说明。

| 类别 | 数量 | 含义 |
|---|---|---|
| 留 | 31 | 本轮保留入口已确认，包含日常入口、视图局部操作和必要模式。Automation 整体保留；rollup 与字段同步除外 |
| 改 | 22 | 功能保留但需改造或改名：AI 元数据候选审核、标签改名、引用添加及解除引用、查询入口、find-node、discovery、promote，以及 Git 同步适配文本事实与本地缓存 |
| 删 | 125 | 随 field / schema / link definition 删除；数据库标签继承、数据库写入类命令及已确认不需要的交互入口删除 |
| 封存 | 93 | 代码保留，默认不接入下一版本：ontology 子系统（见 §2）；看板、Board、图视图、表格、虚拟列、embed 组件；搜索结果导出到已有或新文件的两个入口。保留源码不代表默认加载或提供可用入口 |
| 一次性 | 16 | 迁移与清理脚本，跑完即删 |
| 未定 | 0 | §9 全部决定已落，见 MODEL_CN.md |

节点视图和 stream 保留；原 search 改为 discovery，提供独立的发现与阅读入口。其他已封存视图不默认接入。

检索入口已明确：find-node 用于快速定位，并允许找不到时主动新建；原 search 改名为 supertag-discovery，打开即展示可阅读的随机笔记，用户按需添加筛选条件，无须先输入查询。stream 将节点存放位置与信息呈现解耦，呈现符合条件的完整集合，便于快速浏览和处理；discovery 打开时随机呈现一部分供阅读，主动筛选后显示全部匹配节点。两者保留独立入口，不因都支持筛选而合并。

复核说明：以上数量随已确认的归类更新。用户已确认本轮剩余命令的批量收敛方案；保留含局部操作及配置模式，不等同于日常命令数量。复核区分用户能力、重复命令入口与内部函数：移除交互入口不等于删除其仍被调用的内部能力。具体去留在用户确认后更新归类和数量。

2026-09-05 收尾审查已完成，批量建议、源码依据与待决定问题见第 4 节。第 4 节批量方案已获确认并回填上表和第 3 节；仅更新设计记录，未实施功能改动。

命名决定：添加类入口统一使用 supertag-add-*。最终引用入口为 `supertag-add-link`，承接现有 `supertag-reference-insert` 的统一能力并支持可选关系名；最终查询入口为 `supertag-add-query-block`，由 `supertag-insert-query-block` 改名。下表仍以原始 287 个符号为行标识，目标名写在理由中，不重复计数。旧 `supertag-add-reference` 的有限实现被替换，不是恢复两个引用入口。

当前纠偏：这三个同步/重建入口面向文档投影，不等于整个数据库是缓存。非重建事实、旧配置、未解冲突及其备份/恢复不能由重建取代；旧整库缓存论见写前历史副本，不再作为默认指导。命令退役须逐项处理，不据此删除持久化实现。

## 2. ontology 是什么，为什么封存而不删

它是**把标签系统写成配置文件**的东西。Tana 里点鼠标建的 supertag 定义，在这里改成写一个 Lisp 文件，然后"部署"进数据库。用一遍会经历这些：

  1. **写一个文件。** 内容大意是："有一种东西叫 Project，有一种东西叫 Task，都有 Status 和 Deadline 两个字段；一个 Project 有多个 Task。"用 `supertag-defontology` 包起来，示例在 `examples/personal-work-ontology.el`。
2. **跑 preview。** Supertag 拿文件和数据库里现有的标签比，列出"将新建标签 #project、#task，新建字段 Status、Deadline，新建一种链接 Tasks"，每条标上安全、行为或破坏。
3. **跑 apply。** 真的在数据库里建出标签和字段。从此标题后写 `#task`，节点就带那两个字段。这些标签在 UI 里变只读，要改就回文件改再部署。

到这里是它的本体：一个 schema 文件加一个部署命令，和 Rails 的 schema.rb、Django 的 models.py 是同一种东西，只不过管的是标签。后面几版往上叠：

- **链接定义**（v3、v5）："Project 有多个 Task"变成一种带名字的链接。在 Task 节点上 `l a` 选 Tasks 选一个 Project，数据库记一条边；Project 视图里反过来显示 Tasks。可以查"Status 是 blocked 的 Task 属于哪些 Project"。
- **迁移 DSL**（v8）：破坏性的 schema 改动必须配一个迁移声明才能部署。
- **函数**（v10）：文件里声明有名字的只读查询，比如"这个项目的逾期任务"，实现是一段 Elisp，节点视图里显示结果。
- **动作**（v10）：声明有名字的修改，比如"标记完成"就是"把 Status 设成 done"。节点视图里出现 [Run] 按钮。
- **策略**（v11）：规定谁能跑哪个动作。人直接跑，LLM 只能提议，自动化被拒。
- **工具目录**（v12）：把函数和动作导出成 OpenAI function calling 格式的 JSON 工具清单，设想喂给 LLM。目前终点是复制到剪贴板，没接任何模型。

已知状态：全部层都有代码且自洽；测试写了但从未在发布环境跑过；从声明里删掉一个类型会在 deploy 阶段报"不支持的操作"，迁移 DSL 也拒绝，所以已部署的东西删不掉。

**为什么封存而不删。** 它最重要的地方是把知识和行动放到了一起：一个标签不只是分类，还带着"对这类节点能做什么"。接上 LLM 之后，`#task` 就是 Tana 那种 AI Supertag，往后 AI Supertag 可以执行某些行为。这个方向是对的，而且已经完整实现，只差接入 LLM。所以代码整体保留，不接入主流程，作为以后的参考。它和现在模型的冲突只在一处：它的"知识"一侧建在字段和 schema 上，而模型把元数据放进了 Org PROPERTIES。将来若重启，"行动"一侧可以原样搬，"知识"一侧改成读属性。

从它借到模型里的三条规则，见 MODEL_CN.md §7。

## 3. 全表

| 类别 | 命令 | 理由 |
|---|---|---|
| 一次性 | `supertag-analyze-org-properties` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-cleanup-nil-tags` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-cleanup-orphaned-tags` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-db-migrate-and-normalize` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-db-purge-duplicate-tags` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-db-purge-invalid-nodes` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-export-all-fields-to-properties` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-migrate-database-to-new-arch` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-migration-add-ids-to-org-headings` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-migration-audit-global-fields` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-migration-audit-stable-tags` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-migration-rewrite-tag-token` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-migration-run-global-fields` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-migration-run-stable-tags` | 迁移/清理脚本，跑完即删 |
| 一次性 | `supertag-sync-cleanup-database` | 迁移/清理脚本，跑完即删 |
| 删 | `supertag-accept-fresh-store` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-async-retry-failed` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-automation-recalculate-all-rollups` | rollup 与字段同步删除，汇总值读时算，不落盘 |
| 删 | `supertag-automation-sync-all-fields` | rollup 与字段同步删除，汇总值读时算，不落盘 |
| 删 | `supertag-backup-database-now` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-batch-convert-properties-to-fields` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-clear-parent` | 数据库继承删除，层级用斜杠路径从名字派生 |
| 删 | `supertag-conflicts-resolve` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-conflicts-use-ours-all` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-conflicts-use-theirs-all` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-convert-properties-to-field` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-db-retry-lock` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-doctor` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-edit-field` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-edit-fields` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-global-field-edit-interactive` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-index-clear-all` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-index-rebuild-all` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-load-store` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-migrate-reciprocal-links` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-migration-execute-reciprocal-links` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-migration-preview-reciprocal-links` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-ops-schema-rebuild-cache` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-reindex-org` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-relation-cleanup-duplicates` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-relation-sync-all-fields` | rollup 与字段同步删除，汇总值读时算，不落盘 |
| 删 | `supertag-relation-update-all-rollups` | rollup 与字段同步删除，汇总值读时算，不落盘 |
| 删 | `supertag-restore` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-save-store` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-schema--add-child-tag-at-point` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--add-field-at-point` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--add-link-definition` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--add-new-tag` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--batch-delete-marked-items` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--batch-extends-marked-tags` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--bind-existing-field-at-point` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--cleanup-all-inherited-associations` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--cleanup-inherited-field-associations` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--delete-at-point` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--edit-field-definition-at-point` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--edit-link-definition-at-point` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--goto-tag` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--mark-item` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--move-field-down` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--move-field-up` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--rename-at-point` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--rename-field-at-point` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--show-help` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--unmark-all` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema--unmark-item` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema-apply-registrations` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema-merge-marked-tags` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema-rebuild-global-field-caches` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema-view-mode` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-schema-view-table-at-point` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-set-tag-parent` | 数据库继承删除，层级用斜杠路径从名字派生 |
| 删 | `supertag-start-auto-sync` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-stop-auto-sync` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-sync-check-now` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-sync-force-resync-file` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-sync-full-initialize` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-sync-reset-state` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-sync-start-auto-sync` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-sync-stop-auto-sync` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-tag-list-missing-fields` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-ui-link-definition-create` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-ui-link-definition-delete` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-ui-link-definition-edit` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-ui-quick-edit-field` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-update-node-at-point` | 数据库是缓存，没有写入命令。备份、恢复、冲突、锁、索引、手动保存加载都由"重建"取代；自动同步常开，不提供开关 |
| 删 | `supertag-view-schema` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 删 | `supertag-view-schema-set-extends` | 字段/schema/链接定义/虚拟列，随 field 系统删除 |
| 封存 | `supertag-action-run` | ontology 的动作与 LLM 工具目录，随 ontology 封存 |
| 封存 | `supertag-board-follow-mode` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-board-mode` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-graph-ui-follow-mode` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-graph-ui-mode` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-graph-ui-open` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-ontology-action-run` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-apply` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-clear-registry` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-goto-definition` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-initialize` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-load-files` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-migration-apply` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-migration-goto-definition` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-migration-load-files` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-migration-preview` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-migration-registry-clear` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-migration-status` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-migration-validate` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-preview` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-registry-clear` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-status` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ontology-validate` | ontology：知识与行动结合的完整实现，尚未接入 LLM，代码整体保留作参考 |
| 封存 | `supertag-ui-tool-copy-catalog-json` | ontology 的动作与 LLM 工具目录，随 ontology 封存 |
| 封存 | `supertag-ui-tool-list` | ontology 的动作与 LLM 工具目录，随 ontology 封存 |
| 封存 | `supertag-ui-tool-mode` | ontology 的动作与 LLM 工具目录，随 ontology 封存 |
| 封存 | `supertag-ui-tool-refresh` | ontology 的动作与 LLM 工具目录，随 ontology 封存 |
| 封存 | `supertag-view-config-save-to-store` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-dsl-example` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-framework-init` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-kanban` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-kanban-mode` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-kanban-move-card` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-kanban-move-card-left` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-kanban-move-card-right` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-kanban-next-card` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-kanban-previous-card` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-kanban-refresh` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-list-interactive` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-refresh` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-select-and-render` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-select-from-schema` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-style-mode` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-style-refresh` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-style-toggle` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table--adjust-image-column-width` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table--insert-image-path` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-add-column` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-add-table` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-automations` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-clear-filter` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-collapse-all-rows` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-delete-column` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-delete-named-view` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-edit-cell` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-expand-all-rows` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-filter` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-force-refresh` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-goto-node` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-goto-reference` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-help` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-mode` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-next-cell` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-next-line` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-previous-cell` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-previous-line` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-project-task-correlation` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-refresh` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-rename-column` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-save-current-view-as-named` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-select-tag` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-set-column-type` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-show-automations` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-show-tag` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-switch-table` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-switch-view` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-table-toggle-row-details` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-widget-backward` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-widget-forward` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-view-widget-mode` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-virtual-column-clear-cache` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-virtual-column-create-interactive` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-virtual-column-delete-interactive` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-virtual-column-edit-interactive` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-virtual-column-init` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-virtual-column-list-interactive` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 封存 | `supertag-virtual-column-refresh` | 看板、Board、图视图、表格、虚拟列整体封存，代码保留不接主流程 |
| 删 | `supertag-ui-add-semantic-relation` | 已确认：带关系的引用统一由 supertag-add-link 添加，删除旧独立入口 |
| 删 | `supertag-ui-remove-semantic-relation` | 已确认：删除旧独立入口，解除关系通过编辑对应的 Org 链接完成；属性键不表达关系 |
| 改 | `supertag-view-node-confirm-field-at-point` | 已确认：承接“提取属性”的候选接受动作，接受后经活 buffer 写入 Org PROPERTIES；旧 field 名称退出，最终实现符号待定 |
| 改 | `supertag-view-node-reject-field-at-point` | 已确认：承接“提取属性”的候选跳过动作，跳过不写属性、不产生待办；旧 field 名称退出，最终实现符号待定 |
| 改 | `supertag-view-node-review-ai-fields` | 已确认：节点 Embark 菜单提供“提取属性”，AI 从当前节点提出候选，逐条接受或跳过；不沿用旧 field 命名，最终实现符号待定 |
| 删 | `supertag-act` | 情景操作统一通过必需依赖 Embark 的 embark-act，不再提供独立菜单或无 Embark 的备用入口；内部对象识别与动作保留 |
| 删 | `supertag-act-dwim` | 情景操作并入 Embark，不再保留独立默认动作入口；必要内部动作保留 |
| 删 | `supertag-act-mode` | 删除为独立 act/dwim 入口设置快捷键的模式，统一使用 Embark 操作入口 |
| 改 | `supertag-add-reference` | 已确认改名为 supertag-add-link，作为最终统一链接添加入口：替换旧实现，承接 reference-insert 的选区、光标处、已有或新建目标能力及可选链接关系名；普通引用不增加必选关系步骤，关系只由链接类型表达 |
| 删 | `supertag-add-reference-and-create` | 已确认：引用入口统一使用 supertag-add-link，移除旧兼容入口；仍被调用的内部函数另行核实 |
| 留 | `supertag-add-tag` | 已确认：统一添加标签入口，支持当前节点及选区内多个节点；直接输入 # 的补全保留 |
| 删 | `supertag-automation-cleanup` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-automation-init` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-automation-sync--register-commit-hooks` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-automation-sync--unregister-commit-hooks` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-automation-sync-disable` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-automation-sync-enable` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-automation-sync-toggle-async` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-back-to-heading` | 已确认：删除撤销节点身份的专门入口；它删除 Org ID，并非返回起始节点的导航命令 |
| 删 | `supertag-capture` | 已确认：删除独立捕获入口，记录统一使用 org-capture |
| 删 | `supertag-capture-finalize-node-at-point` | 已确认删除交互入口：必要收尾由 org-capture 集成自动完成，内部调用保留或调整 |
| 删 | `supertag-capture-with-template` | 已确认：删除独立捕获模板入口，记录统一使用 org-capture；promote 模板保留 |
| 删 | `supertag-change-tag-at-point` | 旧独立入口退出；不据此禁止“更换当前标签”能力。后续按 WHERE/WHAT/ACTION 评估为 Embark 情景动作，最终符号与行为未定，本轮不恢复旧入口 |
| 删 | `supertag-complete-tag` | 已确认：退出独立补全入口，保留输入补全、add-tag 与 add-link；验证 TAB 和现有补全触发 |
| 删 | `supertag-completion-debug` | 已确认：退出日常入口，保留内部诊断或自动刷新能力；不是删除仍被调用的内部函数 |
| 留 | `supertag-concept-link-mode` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-concept-open-at-mouse` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-concept-open-at-point` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 删 | `supertag-concept-refresh` | 已确认：退出日常入口，保留内部诊断或自动刷新能力；不是删除仍被调用的内部函数 |
| 封存 | `supertag-convert-link-to-embed` | 已确认：embed 组件整体封存，保留代码，默认不接入下一版本 |
| 删 | `supertag-create-node` | 已确认删除交互入口：添加引用、标签等需要节点身份时自动补齐 Org ID；已有 ID 沿用，保留内部身份处理能力 |
| 删 | `supertag-db-inspect-file` | 已确认：退出日常入口，保留内部诊断或自动刷新能力；不是删除仍被调用的内部函数 |
| 删 | `supertag-delete-node` | 已确认：删除节点使用 Org 原生子树编辑，保存后同步投影；不保留专门删除命令 |
| 留 | `supertag-delete-tag-everywhere` | 已确认保留：全库移除指定标签，保留笔记；先预览文本改动，确认后经活 buffer 修改 Org 文本，数据库跟随重建 |
| 删 | `supertag-disable-org-capture-integration` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-disable-org-id-open-link-integration` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-embark-act` | 删除再打开 Supertag 菜单的包装入口，情景动作直接呈现在 Embark 中；必要动作适配函数保留 |
| 删 | `supertag-embark-act-dwim` | 不再作为独立用户入口，默认动作由 Embark 集成承接；必要内部适配保留 |
| 删 | `supertag-enable-org-capture-integration` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-enable-org-id-open-link-integration` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 改 | `supertag-find-node` | 已确认统一查找入口：默认当前窗口，前缀参数时在另一窗口预览、打开；minibuffer 提示当前方式及另一种用法。找不到时允许主动新建，沿用 promote-concept 的目标文件机制，直接放入对应文件 |
| 删 | `supertag-find-node-other-window` | 已确认删除独立入口，能力并入 supertag-find-node 的前缀参数用法，minibuffer 提供提示 |
| 改 | `supertag-git-clone` | 已确认保留 Git 同步能力：克隆后从 Org 文本建立本地缓存，改造现有数据库加载与语义恢复流程 |
| 改 | `supertag-git-setup` | 已确认保留 Git 同步设置：适配 Org 文本同步，改造旧数据库布局迁移、跟踪和语义合并配置 |
| 改 | `supertag-git-sync-mode` | 已确认保留自动 Git 同步：与数据库缓存同步区分，移除对权威数据库保存与语义合并的依赖；Org 文本 Git 冲突仍需处理 |
| 改 | `supertag-git-sync-now` | 已确认保留手动 Git 同步：同步 Org 文本、更新本地缓存，改造旧数据库保存门槛与语义合并流程 |
| 留 | `supertag-init` | 已确认：保留初始化/设置入口，不列日常笔记操作；实施时适配新模型，不默认接入封存组件 |
| 封存 | `supertag-insert-embed` | 已确认：嵌入有文档重组价值，但用户认为当前 Org 体验不够自然；embed 组件整体封存 |
| 改 | `supertag-insert-query-block` | 已确认改名为 supertag-add-query-block：统一查询入口，继续使用 Org Babel 源码块，结果位于 RESULTS 区域 |
| 删 | `supertag-insert-query-dblock` | 已确认删除动态块插入入口；已有动态块的读取和刷新兼容保留，不删除其渲染支持 |
| 删 | `supertag-link-add` | 已确认：带关系的引用并入最终入口 supertag-add-link，不保留独立入口 |
| 删 | `supertag-link-menu` | 已确认：引用入口统一，不保留独立 Link 菜单 |
| 删 | `supertag-link-remove` | 已确认：删除旧数据库关系移除入口，解除关系通过编辑对应的 Org 链接完成 |
| 删 | `supertag-mention-ignore-in-node` | 已确认：用户认为没有必要，不保留节点范围的忽略提及命令 |
| 留 | `supertag-mention-link` | 已确认保留：由用户确认一处候选提及，将其转成 Org 链接 |
| 留 | `supertag-mention-link-all-in-node` | 已确认保留：由用户主动将当前节点内同一概念的所有候选提及一次转成链接 |
| 删 | `supertag-mention-service-clear-cache` | 已确认删除交互入口：缓存由程序管理，保留必要内部清理与调试能力 |
| 留 | `supertag-move-node` | 已确认保留：无须预配置即可选择目标文件和位置，支持当前节点或选区内多个节点；作为用户工作流中替代 org-refile 的移动入口 |
| 留 | `supertag-move-node-and-link` | 已确认保留：移动节点并在原处留下链接，有独立价值；目标可任意选择，区别于按模板目标文件提升的 promote |
| 删 | `supertag-node-reference-and-create` | 已确认：删除旧引用字段的新建目标入口，引用目标创建由 supertag-add-link 承担 |
| 改 | `supertag-promote-concept` | 已确认改名为 supertag-promote，作为统一提升入口：按 org-capture 式选择键使用用户模板；模板配置目标文件、标签及可选初始内容，用户可为常用模板定义直接命令并绑定快捷键。共用提升逻辑，不默认增加分类命令；选区提升不搬移所在标题；复用文件外已有节点时，节点及正文移入模板目标文件，旧位置留下引用，保持读写连续性。模板机制尚未实施，见 MODEL_CN.md §9 |
| 删 | `supertag-rebuild-rule-index` | 已确认：退出日常交互入口，保留内部生命周期与必要配置；自动接入和清理，避免重复触发，不改变用户 capture 模板 |
| 删 | `supertag-reference-complete` | 已确认：退出独立补全入口，保留输入补全、add-tag 与 add-link；验证 TAB 和现有补全触发 |
| 删 | `supertag-reference-create-or-link` | 已确认：reference-insert 的旧别名退出独立入口，统一使用 supertag-add-link |
| 删 | `supertag-reference-insert` | 已确认旧名称退出独立入口，能力迁入最终命名 supertag-add-link；删除的是旧入口名，不是统一引用能力 |
| 删 | `supertag-reference-link-region` | 已确认：选区能力并入 supertag-add-link，不再独立暴露；必要内部调用另行调整 |
| 改 | `supertag-remove-reference` | 已确认保留解除引用动作：通过 Embark 对当前引用操作，去掉链接但保留可见文字；替换现有删除整个链接文本的行为 |
| 留 | `supertag-remove-tag-from-node` | 已确认保留：Embark 对当前标签提供从当前节点移除的动作，修改 Org 文本；区别于全库删除标签 |
| 改 | `supertag-rename-tag` | 已确认最终标签改名入口，动词在前；全库预览、确认后经活 buffer 修改 Org 标签文本，替换旧数据库改名实现 |
| 一次性 | `supertag-resolve-data-directories` | 已确认：旧数据目录迁移，不作为日常入口；实际迁移和退役前仍须核实旧数据，不在本轮执行 |
| 删 | `supertag-scheduler-list-tasks` | 已确认删除交互入口，必要任务检查保留为内部调试能力；调度器服务于 Automation，不是数据库缓存组件 |
| 删 | `supertag-scheduler-start` | 已确认删除交互入口，保留内部启动能力，调度器随功能自动启动，Automation 继续可用 |
| 删 | `supertag-scheduler-stop` | 已确认删除交互入口，保留内部停止和清理能力，调度器随功能自动停止 |
| 改 | `supertag-search` | 已确认重定位并改名为 supertag-discovery：打开即可阅读随机笔记，用户按需筛选；沿用当前 search 的关键词匹配方式，筛选后显示全部匹配节点；保留不同于 stream 的阅读体验 |
| 封存 | `supertag-search-export-results-to-file` | 已确认暂时封存：保留代码，默认不接入下一版本；discovery 仍保留将选中节点的引用插回出发位置 |
| 封存 | `supertag-search-export-results-to-new-file` | 已确认暂时封存：保留代码，默认不接入下一版本，不提供独立导出到新文件入口 |
| 改 | `supertag-search-insert-at-point` | 已确认改名为 supertag-discovery-insert-references，保留原能力与局部操作；保留浏览、选择及将引用插回原笔记的流程 |
| 改 | `supertag-search-mode` | 已确认改名为 supertag-discovery-mode，保留原能力与局部操作；保留浏览、选择及将引用插回原笔记的流程 |
| 改 | `supertag-search-next` | 已确认改名为 supertag-discovery-next，保留原能力与局部操作；保留浏览、选择及将引用插回原笔记的流程 |
| 改 | `supertag-search-prev` | 已确认改名为 supertag-discovery-previous，保留原能力与局部操作；保留浏览、选择及将引用插回原笔记的流程 |
| 改 | `supertag-search-quit` | 已确认改名为 supertag-discovery-quit，保留原能力与局部操作；保留浏览、选择及将引用插回原笔记的流程 |
| 改 | `supertag-search-toggle-mark` | 已确认改名为 supertag-discovery-toggle-mark，保留原能力与局部操作；保留浏览、选择及将引用插回原笔记的流程 |
| 改 | `supertag-search-visit-node` | 已确认改名为 supertag-discovery-open-node，保留原能力与局部操作；保留浏览、选择及将引用插回原笔记的流程 |
| 封存 | `supertag-services-embed-refresh-all` | 已确认：随 embed 组件封存，默认不接入其刷新、同步和初始化流程 |
| 删 | `supertag-svg-tag--clear-cache` | 已确认：退出日常入口，保留内部诊断或自动刷新能力；不是删除仍被调用的内部函数 |
| 删 | `supertag-svg-tag-mode-disable` | 已确认：合入 supertag-toggle-tag-style；内部启用和清理能力保留 |
| 删 | `supertag-svg-tag-mode-enable` | 已确认：合入 supertag-toggle-tag-style；内部启用和清理能力保留 |
| 改 | `supertag-svg-tag-mode-toggle` | 已确认改名为 supertag-toggle-tag-style，保留原能力与局部操作；长标签完整显示，不裁切或省略 |
| 留 | `supertag-sync-force-resync-current-file` | 数据库仅有的三个命令：全量重建、重建当前文件、看状态 |
| 留 | `supertag-sync-full-rescan` | 数据库仅有的三个命令：全量重建、重建当前文件、看状态 |
| 留 | `supertag-sync-status` | 数据库仅有的三个命令：全量重建、重建当前文件、看状态 |
| 删 | `supertag-tag-insert` | 已确认：添加标签统一使用 supertag-add-tag，删除重复入口，保留 # 补全 |
| 删 | `supertag-tag-rename` | 已确认旧名称退出交互入口，最终统一使用 supertag-rename-tag；保留全库文本改名能力 |
| 留 | `supertag-ui-completion-mode` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-vault-activate` | 已确认保留：切换当前笔记库，继续支持多个相互独立的库 |
| 留 | `supertag-vault-indicator-mode` | 已确认保留多库体验中的当前库提示，帮助用户识别正在使用的库 |
| 留 | `supertag-view-node` | 已确认：打开后跟随、关闭后停止；相关笔记先展示已有引用和未链接提及，再展示语义相似候选，明确区分已确认关联与待判断候选，不自动建链。无须额外查找命令，返回复用 Emacs 标记能力。具体检索和布局留待实施，见 MODEL_CN.md §9 |
| 留 | `supertag-view-node--hide-side` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 删 | `supertag-view-node-edit-at-point` | 已确认删除：仅编辑旧 :field-value，随旧字段界面退出；不是通用节点正文编辑 |
| 留 | `supertag-view-node-mode` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-view-node-refresh` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 删 | `supertag-view-node-toggle-auto-show` | 已确认：退出独立日常入口；Node View 打开后跟随、关闭后停止，自动显示归配置 |
| 留 | `supertag-view-stream` | 已确认独立保留：节点位置与呈现解耦，跨文件呈现符合条件的完整集合，支持快速浏览和处理；discovery 初始随机阅读，主动筛选后同样显示完整匹配集合 |
| 留 | `supertag-view-stream-edit` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-view-stream-edit-abort` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-view-stream-edit-finish` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-view-stream-edit-mode` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-view-stream-mode` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-view-stream-next-node` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-view-stream-open-node-view` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-view-stream-previous-node` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |
| 留 | `supertag-view-stream-quit` | 已确认：保留视图局部操作、模式或对象适配能力，不要求用户记忆独立命令；必要 interactive 和清理逻辑保留 |

## 4. 剩余入口收尾审查（2026-09-05）

状态：审查及批量取舍已确认；Git 冲突处理流程已确认，同名节点选择规则见下文。范围：审查时的“留 63、改 13”中尚未收敛的交互入口；不重新讨论封存项，不修改功能代码。代码中的 `interactive` 同时涵盖用户入口、视图局部按键、minor mode 和内部维护，不能把 76 个符号等同于 76 个需要用户记忆的入口。

### 4.1 已确认的批量收敛方案

| 分组 | 原命令（均以 supertag- 开头） | 建议 | 源码依据与保留边界 |
|---|---|---|---|
| Automation 生命周期 | automation-init、automation-cleanup、rebuild-rule-index | 删除日常交互入口，保留内部能力 | [supertag-automation.el](./supertag-automation.el) 加载时已初始化，索引有源状态检查；由生命周期与规则变化处理，用户不维护索引 |
| Automation 事件接入 | automation-sync--register-commit-hooks、automation-sync--unregister-commit-hooks、automation-sync-enable、automation-sync-disable、automation-sync-toggle-async | 删除日常交互入口，必要配置和内部接入保留 | [supertag-automation-sync.el](./supertag-automation-sync.el) 明确防止 store 订阅与 commit hook 双重触发；实施时选择一致事件路径，不能把两个通道都自动启用。异步执行是实现策略，不是用户任务 |
| Org 集成生命周期 | enable-org-capture-integration、disable-org-capture-integration、enable-org-id-open-link-integration、disable-org-id-open-link-integration | 删除成对日常入口，按配置与功能生命周期自动接入、清理 | [supertag-services-capture.el](./supertag-services-capture.el)、[supertag-service-org.el](./supertag-service-org.el) 分别注册 hook 与 advice；保留必要内部清理，不擅自改用户所有 capture 模板或处理库外节点 |
| 诊断与缓存 | completion-debug、db-inspect-file、svg-tag--clear-cache、concept-refresh | 转为内部诊断或自动刷新，不列日常命令 | [supertag-ui-completion.el](./supertag-ui-completion.el)、[supertag-core-persistence.el](./supertag-core-persistence.el)、[supertag-view-svg-tag.el](./supertag-view-svg-tag.el)、[supertag-concept.el](./supertag-concept.el)。db-inspect-file 检查的是数据库文件结构，不是某一 Org 文件的解析视图；主题变化和概念变化已有内部刷新调用 |
| SVG 显示开关 | svg-tag-mode-enable、svg-tag-mode-disable、svg-tag-mode-toggle | 只保留一个用户切换入口，启用/停用函数内部保留；最终名 toggle-tag-style | [supertag-view-svg-tag.el](./supertag-view-svg-tag.el) 的 toggle 已调用 enable/disable。完整显示长标签是已确认的独立修复要求，不因入口合并而遗漏 |
| 手动补全包装 | complete-tag、reference-complete | 已确认退出独立用户入口，保留 # 与 [[ 的补全、add-tag 与 add-link | [supertag-ui-completion.el](./supertag-ui-completion.el)、[supertag-ui-reference.el](./supertag-ui-reference.el)。前者转到 completion-at-point 或 org-cycle，后者转到补全或引用添加。实施时验证现有补全触发与 TAB 行为，不以“删命令”破坏输入 |
| 旧字段编辑 | view-node-edit-at-point | 已确认：删除旧入口 | [supertag-view-node.el](./supertag-view-node.el) 当前只处理 :field-value 并调用旧字段编辑器；不是通用节点正文编辑。随已确定的 field 系统删除，AI 属性候选审核仍保留 |
| 旧数据目录处理 | resolve-data-directories | 已确认：从“留”改为“一次性” | [supertag-core-persistence.el](./supertag-core-persistence.el) 实际比较新旧默认目录、确认重命名并可加载旧数据库。它有迁移价值，不是普通缓存清理，也不应未经迁移核实直接删代码或目录 |

以上方案已获用户逐项确认，不把“保留内部能力”误做成“全部函数移除 interactive”。局部按键和模式仍可能必须是 Emacs command；只有不再由交互路径调用的维护函数才适合取消交互声明。

### 4.2 保留能力，收敛为视图按键或配置

| 能力 | 涉及原命令 | 建议 |
|---|---|---|
| 初始化 | supertag-init | 保留一次性设置/初始化入口，不列日常操作；内部仍须按新模型改造，退出 field/schema、权威数据库及 embed 的旧初始化路径 |
| 补全、概念显示与当前库提示 | supertag-ui-completion-mode、supertag-concept-link-mode、supertag-vault-indicator-mode | 保留配置和模式生命周期，不要求用户每次进入笔记手动启动；不新增“启用/停用”两套日常入口 |
| 打开概念 | supertag-concept-open-at-point、supertag-concept-open-at-mouse | 保留键盘、鼠标和 Embark 的对象操作；鼠标事件函数是适配代码，不要求用户记它的名字 |
| node view | supertag-view-node、supertag-view-node--hide-side、supertag-view-node-refresh、supertag-view-node-mode | 保留一个打开/关闭入口，关闭和刷新作为局部操作；mode 保留。hide-side 仍用于清理订阅，不可只隐藏窗口而留下运行状态 |
| stream | supertag-view-stream、supertag-view-stream-mode、supertag-view-stream-next-node、supertag-view-stream-previous-node、supertag-view-stream-open-node-view、supertag-view-stream-edit、supertag-view-stream-edit-finish、supertag-view-stream-edit-abort、supertag-view-stream-edit-mode、supertag-view-stream-quit | 保留完整集合浏览与编辑往返。现有 n/p、e、v、q、编辑中的 C-c C-c/C-c C-k 已形成完整局部流程；不需要为减少符号数移除这些动作。建议取消编辑在帮助中写“取消本次修改”，明确其恢复原内容的效果 |
| discovery | supertag-search-mode、supertag-search-next、supertag-search-prev、supertag-search-quit、supertag-search-visit-node、supertag-search-toggle-mark、supertag-search-insert-at-point | 随 discovery 统一前缀，保留浏览、打开、选择、插回原笔记和退出。最终局部名称为 discovery-mode、discovery-next、discovery-previous、discovery-quit、discovery-open-node、discovery-toggle-mark、discovery-insert-references，均加 supertag- 前缀。不再新增并行 search 入口；导出入口保持封存 |

源码：[stream 浏览和编辑流程](./supertag-view-stream.el)、[search 原操作与结果插入](./supertag-ui-search.el)、[node view 开关与跟随](./supertag-view-node.el)。本节方案已确认，局部命名与行为尚未实施。

### 4.3 体验决定与剩余建议

1. **find-node 新建落点（已定）**：沿用 promote-concept 的目标文件机制，直接放在对应文件里，不再另设 move-node 式位置选择流程。复用落点不等于执行原地替换文本的 promote 操作；打开窗口继续遵循 find-node 前缀参数。
2. **discovery 筛选（已定，修订此前抽样边界）**：沿用当前 search：空格分隔关键词，每个词均须在标题、标签、正文或属性值之一匹配；不新增时间/文件筛选器。初始随机阅读，主动筛选后显示所有符合条件的节点，不再抽样。源码依据：supertag-ui-search.el 的 supertag-search--get-keywords 与 supertag-search-find-nodes。
3. **返回起始节点（已定）**：沿用 Emacs 已有标记与返回能力，不另造 Supertag 返回命令或导航系统。仍须支持回到起始节点原位置；实施时核实跨 buffer 和连续跳转时的标记保存，不要求为此增加固定面板或写作模式。
4. **node view 跟随（已定）**：用户打开后跟随当前节点，关闭后停止；自动显示作为配置，不设独立日常跟随命令。打开是用户召唤，不能在未打开时自行弹出相关检索。
5. **Git 文本冲突（已定）**：用户希望进入类似 Git 的 diff 页面排除冲突。接入已有冲突解决界面，展示冲突双方并允许编辑合并结果，不只提供只读差异；暂停当前库的自动 Git 同步，用户确认解决后再按 Git 流程继续。不自动选边、不另造合并器；流程已确认，具体工具接入留待实施。

6. **Promote 同名选择（已定）**：出现同名节点时询问用户，提供复用已有节点或按模板新建两种选择；选择视图必须显示已有节点内容，帮助辨别所指，不凭标题相同自动合并。用户将此与 unlinked mention 的人工确认原则联系起来。后续已确认：复用概念文件外节点时，将节点及正文移入模板目标文件，原位置只留下引用；不是直接引用其原位置，也不把 diary 整体设为概念文件。选区提升仍不搬移所在标题。已确认移动时沿用原 Org ID，无 ID 才补齐，已有引用仍指向同一节点。复用时保留正文和属性、添加模板标签、仅补缺失属性，不覆盖已有值或重复插入初始正文；全新节点应用完整模板。仅记录设计，尚未执行移动；实施时验证身份、引用及内容保全。

### 4.4 核查范围与限制

- Node View 阅读预览及上下文提取已确认：条目展示标题和相关正文；引用/提及取出现位置上下文，语义结果尽可能取相关段落，不将节点级相似假称段落精确命中。打开尽可能定位原文，预览不建链；实施时验证中文检索质量。不增加独立预览命令或依赖。五份参考及已确认要求见 MODEL_CN.md §9，分类计数不变。

- 本轮只读检查实现、内部调用、模式和菜单入口，未运行 ERT，也未改功能代码、用户配置、依赖或笔记数据。
- 原始表只有 287 个 supertag-* 交互符号：不是模块/依赖清单，也不含全部菜单包装、全局模式或非交互初始化。实施封存时还须检查 require、autoload、hook、菜单和打包引用，不能仅按表删除函数。
- 不能依靠变更后的 M-x 数量验证产品是否简化；验收应看统一入口是否承担原能力、局部操作是否完整、没有手工维护步骤，以及封存组件是否真正不再默认加载。
- 全部已确认的分类修正、批量收敛与改名已回填并重新计数：“留 31、改 22、删 125、封存 93、一次性 16”，总数 287。计数包含视图局部命令及必要模式，不代表最终日常入口数量。

## 5. 下一版本用户入口清单

状态：根据已确认决定整理的目标入口，不是完整已发布 API。使用目标名称；部分路径已有历史验收，其余仍待实现。“日常／情景／视图／设置”的分组便于理解，不意味着限制直接调用或新增一套菜单。封存、内部维护与一次性迁移不算用户入口。

### 5.1 日常主动入口：10 个

| 用户要做什么 | 最终命令 | 体验边界 |
|---|---|---|
| 找到或新建节点 | `supertag-find-node` | 精确定位；找不到时主动选择按模板新建。默认当前窗口，前缀参数在另一窗口打开，minibuffer 提示用法 |
| 添加引用 | `supertag-add-link` | 选区或光标处引用已有／新建目标；普通引用不强制询问关系名，可按需使用带类型链接表达关系；属性键不派生关系 |
| 添加标签 | `supertag-add-tag` | 当前节点或选区内多个节点；保留直接输入 # 的补全，必要时自动补齐 ID |
| 提升为概念 | `supertag-promote` | org-capture 式模板选择键，常用模板可自定义命令和快捷键；同名时显示内容并询问复用／新建 |
| 移动节点 | `supertag-move-node` | 无须预配置，选择任意目标文件与位置 |
| 移动并留链 | `supertag-move-node-and-link` | 移动后在原位置留下引用 |
| 查看当前节点及相关笔记 | `supertag-view-node` | 打开后跟随、关闭后停止；先引用与未链接提及，再语义相似候选；标题与相关正文可读，预览不建链 |
| 浏览和处理一个集合 | `supertag-view-stream` | 跨文件呈现符合条件的完整集合，支持节点编辑及返回，不要求先移动节点 |
| 重新发现旧笔记 | `supertag-discovery` | 打开即随机阅读；沿用 search 关键词筛选，筛选后展示全部匹配节点；可多选后插回原笔记 |
| 在笔记中放入查询 | `supertag-add-query-block` | 插入可编辑的 Org Babel 查询源块及 RESULTS；已有动态块仍可读取、刷新 |

Promote 的复用不是按同名自动合并：选区原处变链接、不搬移所在标题；复用文件外已有节点时，节点及正文移入模板目标文件，旧位置留链。沿用原 ID，无 ID 才补齐；保留正文和已有属性，添加模板标签、仅补缺失属性，不重复插入初始正文。新节点才应用完整模板。

### 5.2 情景菜单入口：Embark（具体设计留待后续）

Embark 承接此前 supertag-act 的作用：用户想操作时，通过可视化命令菜单发现和执行动作，无须强记命令名。原生 `embark-act` 作为入口、Embark 为必需依赖、识别对象不修改内容等已定方向不变；不另造第二层 Supertag 菜单。

用户已确认：具体设计必须留待后续，按照 WHERE → WHAT → ACTION 展开，而非先把保留命令映射成菜单。

- WHERE：光标所在对象是什么？通常以所在节点为对象；光标落在 #标签或具体 Org 链接处时，以该具体对象为目标。光标不在节点内的情景单独设计，不强行套用节点菜单；选区及其他边界一并在后续明确。
- WHAT：根据对象和当前情景，提供适用的命令。不是把全部保留命令放进所有菜单；“更换当前标签”可作为待评估动作，不因旧独立入口退出而禁止这项能力。
- ACTION：明确动作作用范围、执行结果及执行后位置，并检查是否符合用户预期。

以下仅为已确认保留能力的盘点，不是已定的对象—动作映射、菜单布局或按键规格。直接命令仍可按需要调用或绑定；具体菜单设计不能以此表代替。

| 可用能力（非最终菜单项） | 对应入口／能力 | 已确认效果与边界 |
|---|---|---|
| 解除当前引用 | `supertag-remove-reference` | 只去掉链接，保留可见文字 |
| 从当前节点移除标签 | `supertag-remove-tag-from-node` | 只改当前节点，不影响全库 |
| 将一处候选提及变为引用 | `supertag-mention-link` | 用户确认后写入 Org 链接 |
| 链接节点内同一概念的全部候选提及 | `supertag-mention-link-all-in-node` | 用户主动批量确认；不是后台自动建链 |
| 全库重命名标签 | `supertag-rename-tag` | 预览文本改动，确认后经活 buffer 修改 |
| 全库移除标签 | `supertag-delete-tag-everywhere` | 预览后移除标签，保留笔记 |
| 提取属性 | 最终 Elisp 符号待定，不沿用旧 field 名称 | AI 提出 Org 属性候选，逐条接受或跳过；仅接受的值写入 PROPERTIES |

打开概念的键盘／鼠标适配保留 `supertag-concept-open-at-point`、`supertag-concept-open-at-mouse`，不另设一套浏览入口。第 5.1 节中适用的直接操作也可供情景菜单调用。具体对象识别、动作映射和执行体验需要后续产品设计，不只是实施时核实。用户提出的 supertag-chang-tag 按“更换当前标签”候选能力记录，不据此确认拼写、恢复旧命令或新增最终符号。

### 5.3 视图内操作：不再作为入门命令清单

| 视图 | 保留的局部能力 | 最终局部命令（均加 supertag- 前缀） |
|---|---|---|
| Node View | 刷新、关闭、相关条目打开 | view-node-refresh、view-node--hide-side；条目打开的适配随实现核实，不新增独立全局命令 |
| Stream | 上下浏览、打开节点视图、编辑、完成／取消编辑、退出 | view-stream-next-node、view-stream-previous-node、view-stream-open-node-view、view-stream-edit、view-stream-edit-finish、view-stream-edit-abort、view-stream-quit |
| Discovery | 上下浏览、打开、选择／取消选择、插回引用、退出 | discovery-next、discovery-previous、discovery-open-node、discovery-toggle-mark、discovery-insert-references、discovery-quit |

保留视图所需 `supertag-view-node-mode`、`supertag-view-stream-mode`、`supertag-view-stream-edit-mode`、`supertag-discovery-mode`，由视图流程管理。不能为减少符号数删除局部按键所需的 interactive。

Stream 现有 n/p、e、v、q 和编辑中的 C-c C-c/C-c C-k 是保留流程的依据；取消编辑恢复最近成功保存后的编辑基线；范围外草稿与会话中新开的窗口受到保护。其他最终按键布局尚未全部确定，不在这里杜撰绑定。属性审核中的接受／跳过是局部动作，最终符号与布局待实现，不把旧 field 命令列为用户入口。浏览后的返回使用 Emacs 标记能力，不新增 Supertag 返回命令。

### 5.4 设置、库管理与同步

| 用途 | 保留入口 | 用户何时需要 |
|---|---|---|
| 初始化 | `supertag-init` | 设置笔记库与功能，不是每条笔记的准备步骤 |
| 切换独立笔记库 | `supertag-vault-activate` | 更换当前库，保持各库独立 |
| 切换标签显示样式 | `supertag-toggle-tag-style` | 一个入口切换；完整显示长标签，不更改存储文本 |
| Git 设置与克隆 | `supertag-git-setup`、`supertag-git-clone` | 配置或接入同步库；同步 Org 文本；文档投影可重建，非重建数据另受保护 |
| Git 同步 | `supertag-git-sync-now`、`supertag-git-sync-mode` | 手动同步或配置自动同步；冲突暂停当前库自动 Git 同步，进入可编辑冲突界面，用户解决后继续 |

必要配置模式保留 `supertag-ui-completion-mode`、`supertag-concept-link-mode`、`supertag-vault-indicator-mode`。配置一次并按生命周期工作，不要求用户每次进入笔记手动启动。Promote 模板选择键和自定义直达快捷键属于用户配置，不默认生成 Person／Contact／Project 全套公共命令。

### 5.5 文档投影恢复与检查：三个入口

| 用户需要 | 保留命令 |
|---|---|
| 查看同步状态 | `supertag-sync-status` |
| 重建当前文件缓存 | `supertag-sync-force-resync-current-file` |
| 全量重建缓存 | `supertag-sync-full-rescan` |

自动文本到缓存同步仍常开；这些是恢复／检查入口，不是日常维护要求。它与可配置的 Git 自动同步不是同一机制。重建投影不能解决 Org 文件之间的 Git 内容冲突，也不能替代非重建事实的恢复。

### 5.6 由既有能力承担，不新增入口

- 捕获使用 `org-capture`；正文、标题、子树删除与手工属性编辑沿用 Org；需要身份的动作自动补齐 ID。
- 候选相关笔记在用户打开 Node View 后出现，不另设“找相关笔记”或后台提醒入口。自动化规则仍由用户编写，必要调度与索引维护归内部，保留能力不恢复生命周期命令。
- 保留 `#` 与引用输入的补全，不另保留 complete-tag/reference-complete 包装。旧查询动态块兼容不是第二个插入入口。
- 不列入下一版本默认入口：封存组件及两个搜索导出入口、已删除旧别名／重复菜单、内部诊断维护函数、一次性迁移脚本。

### 5.7 清单边界与核对

本节覆盖第 3 节的 31 个“留”和 22 个“改”原符号所承担的能力；使用重命名后的入口，不重复计算新旧名称。10 个日常入口只是按任务分组，不是全部 commandp 符号总数，也不规定每位用户的使用频率。

剩余未定的是实施细节：AI 属性动作最终符号、部分局部按键、语义检索后端／中文质量／隐私与索引更新，以及迁移与兼容策略。不得据此声称源码已经符合清单，或自动采用远端模型。后续实施还须核对实际菜单、autoload、hook、依赖与旧快捷键引用；本次只完成文档整理。
