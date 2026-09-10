# Supertag 项目结构整理计划 v2

日期：2026-09-10。状态：**Supertag v2 结构整理已完成**。特性实现收拢、五横切归属、旧混合carrier退役、Menu函数体require豁免退出及现役入口/header元数据均已收口；当前25根生产文件＝19特性/适配入口＋5横切＋main（规划基线51见§4，逐片证据见§8，当前清单见§7.1）。本结论只关闭结构目标，不代表所有产品缺陷、测试债、私人旧加载路径或真实库/GUI/可选Runtime已解决；F1/F2及保留风险仍按§3/§9另行处理。最终运行与证据见§8 FINAL-CLOSEOUT。

## 1. 目的：合并特性碎片，不是再做一轮删代码

用户已明确：要消除的是**同一个特性按技术层拆在多个文件里，导致维护时来回跳转**的问题。目标不止是给每个旧文件标一个 owner，而是把零散的实现、命令、展示、配置和生命周期**合并到这个特性的主文件**；技术分层改为文件内部的节。

例如标签的规则、输入补全、增删改/预览、普通字体与 SVG 显示，集中到 `supertag-tag.el`；不再分别建立 tag-core、tag-ui、tag-style、tag-completion。节点的查找、新建、移动和标准 org-capture 接入集中到 `supertag-node.el`，不为每个命令再建一个文件。真正的共用机制仍由五个横切模块承载。

**主线是保留功能、合并承载文件、减少一次业务修改的跨文件跳转。** 清点是合并的依据，死代码删除只是过程中经证明的附带工作；不能用“归属已标完”“文件已换名”或删除行数代替合并成果。

- 本文件接管**后续项目结构整理的顺序与验收**；[PLAN_CN.md](PLAN_CN.md) 保留决定沿革、已完成事项和历史证据，不删、不重写。
- 产品与数据契约仍继承旧计划的后续有效决定，以及 [MODEL_CN.md](MODEL_CN.md) 的 M1–M8 纠偏；不把旧模型中“整个 DB 都可重建”等原提案当清理授权。
- 规划前按工作树中实际存在的文件固定清点基线：根目录 **51 个 `.el`**。实施后的实际数量与旧承载退场另记 §8；`git ls-files` 含已删除文件，不能据它把退役模块重新列入现状。
- 编写本计划及补充清点阶段只改文档；后续源码实施另记 §8。以下目标不是已经全部完成的改名，也不是一次性移动清单。执行前逐片确认白名单与接口兼容范围。

补充清点（2026-09-07）：在初稿之外，再做两轮独立核对——第一轮逐文件检查定义、配置、状态、注册与职责；第二轮反查根源码内的导入、调用、符号回调和生命周期。两轮均覆盖 51/51 文件，未漏列文件，但发现并补入下文的混合职责和共享状态约束。范围仅这 51 个根 `.el` 与本计划；不是测试/文档/归档目录清点，也不是冷加载或行为验收。动态私人配置与第三方消费者仍未知。

## 2. 不变的工作规则

> 文件按特性竖切，不按技术层横切（2026-09-06 已定）：阶段内碰到哪个模块，就把它散在 core/ops/services/ui/view 前缀里的文件合并成一个特性文件，文件内部用节分层，头部写明入口命令和依赖的横切模块。横切只保留 core-store / core-persistence / services-sync、service-org、view-framework。函数体内不再 require，依赖写在文件头。不单独做整仓搬家。

落到执行上：

1. **按用户能力选片，不按旧前缀选片。** 不开“清空所有 services 文件”“统一改文件名”这样的工单。
2. **一个特性集中到一个主文件。** 同片收拢它的计算、读写编排、命令、展示、配置和注册；文件内部用节分层，不换成新的 `tag-core/tag-service/tag-ui` 三层。有独立按钮、mode 或命令，不自动意味着需要独立文件。
3. **混合文件按职责取出，不整包改名。** `ui-commands`、`services-ui`、`view-helper` 不能分别换个名字继续充当杂物箱；一个旧文件所有职责都迁出后才删除。
4. **先厘清归属，再调整加载。** 不是把多个文件拼接后将所有 `require` 提到顶部。若因此形成 `特性 → service-org/sync → 同一特性` 的环，先处理反向依赖，再合并；不靠函数体 `require`、提前 `provide` 或吞掉加载错误过门。
5. **不增加永久横切例外。** 不新造 `core-utils`、`runtime`、`common-ui`、通用事件桥或另一套 writer。已有非白名单文件里的活能力必须保留，但旧文件只是过渡承载，不因此成为第六个横切模块。
6. **整理默认不改变行为。** 文件归属变化与命令、配置、数据格式、兼容接口的退役分开说明。现役公开符号不为文件名整齐而顺手改名；确需退役另列消费者与用户影响，不留下无期限兼容壳。
7. **一片完成再进下一片。** 可以在同一特性内拆小片，但要列出剩余职责；未迁完不能称整个特性已经竖切。共享文件同一时间只交一个写入者。
8. **小步施工不等于增加永久碎片。** 子片持续向同一个特性主文件合并，不先建 tag-style/move/capture 等小文件再留待以后合并。已有完整的 `view-node`、`view-stream` 等不因前缀相似就搬家；判断依据是实际集中程度，不是名字。
9. **现役测试保当前合同，不永久模拟已闭迁移。** 历史源码/测试与当时红绿继续由签名冻结承接；清理现役历史分支必须另定精确范围，逐项保留当前断言并集和真实消费者；有运行语义风险时补能揭露删错的反证。不按“旧ERT”批量删除，也不靠减少用例数证明成功；实际冷调用、compiled/special、回滚与保存投影保护仍须存在。

10. **验证按风险分级，不机械重复全门。** 已证实的机械接线或无效测试分支清理，执行方只做精确diff/原断言核对及受影响小套件，leader复用有效运行证据定向验收；不强制多方同门、两代反证或逐片全套。涉及加载/初始化、宏与special、共享状态、写盘/回滚或timer生命周期时，仍须对应冷调用、真实编译或业务故障控制，按影响决定消费者和全套范围。未知影响不直接当低风险；已完成额外证据保留，但不固化为每片义务（用户2026-09-09明确）。

### 五个横切模块的职责

| 保留文件 | 负责 | 不成为它的杂物 |
|---|---|---|
| `supertag-core-store.el` | Store 原语、事务与回滚、统一变更通知、派生索引的存储生命周期 | 用户命令、Org 编辑、特性自己的业务决策 |
| `supertag-core-persistence.el` | 稳定序列化、加载保存、版本门控衔接、锁、备份与恢复 | 用 reindex 代替非重建事实的保护 |
| `supertag-services-sync.el` | Org 解析与文档投影、增量/重建、同步队列及相应生命周期 | 查询块 UI、标签编辑 UI、Git 传输策略 |
| `supertag-service-org.el` | 活 Org buffer 的身份/定位、受控编辑与保存投影、共用写入/恢复机制 | Promote、标签等特性的完整用户交互流程 |
| `supertag-view-framework.el` | 视图注册/实例/刷新、公共绘制控件、选择与清理机制 | Node View、Stream、标签显示的特性状态和业务查询 |

这是目标职责，不是声称当前已符合。共享的事务、通知、索引和恢复不会因为原文件叫 `core-*` 就被删除。特性可以通过明确接口使用另一特性；“被多个调用者使用”不自动赋予它新的横切身份。

## 3. 从旧计划结转什么

### 已完成或被覆盖：作为回归基线，不再重复排工

| 旧内容                                                                 | v2 采用的当前结论                                                                                      |
|------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| 开头“field/schema 仍是运行时骨架”、A/C/E 等早期现状                    | 已过时。以后续决定 20 的迁移与字段退出、决定 13 的 3d 清理为准，不重做旧 field 剥离                    |
| D 的 M4 探针、快捷 Promote、find-node 新建模板；E/F 的旧命令与提及条件 | 决定 13 已承接并关闭，保留现有 Promote/链接/提及行为                                                   |
| 旧 `:queries` 保留项、K 的 DB 混合同步描述                             | 分别被决定 14 的 4b、决定 19 的 Org-only Git 覆盖                                                      |
| 迁移、多库、封存与旧命令清理                                           | 决定 20–22 已关闭；迁移 signal 回归、真实双库 activate 测试已由决定 22 补齐，不再照抄更早的“待补”      |
| Embark、AI 批次/取消/精确计划                                          | 决定 23、24 已关闭。文件级节点不作为 Embark 对象是保留决定，不是欠交付                                 |
| 语义卡 `[Add link]`                                                    | 决定 25 按产品选择撤回；只推荐、预览、跳转。普通 `supertag-add-link` 保留，不恢复被撤回的按钮与 helper |
| 独立 Capture 引擎、旧通用批量 CRUD                                     | 决定 26、27 已退役。标准 org-capture 接入与活标签 helper 保留；`ops-batch` 不再排片                    |

旧计划中“模块 M”是 Embark，“阶段 6M”是迁移；v2 使用特性名，不继续混用字母编号。历史测试计数、配置项数和文件数只说明当时结果，不用作固定完成率。

进入 v2 前的已验收基线是 CLEANUP-BATCH-1：默认 **33 套件，705 项 = 702 通过 + 3 项可选跳过，0 unexpected**。规划阶段没有重跑全套；实施时重新固定的 before/after 结果见 §8。

### 留下，但不混进纯结构切片

| 分类 | 内容 | 处理方式 |
|---|---|---|
| 文档/体验交付 | 5G-2 双语配置说明与真实库语义质量校准；查询块文档和 `(field …)` 语法说明 | 跟随所属特性另列交付，不把真实模型质量当文件合并已验证 |
| 验证留记 | 语义阅读位置/保存间隔的旧测试建议；打开中的 Discovery/Stream 切库行为；Git 异步、GUI、版本矩阵等 | 先核对后续测试是否已覆盖，再决定补测；不照抄为现存缺陷 |
| 需复核的旧缺口 | 共享 ID 定位器的正文/代码伪 ID；set-property 活文本 no-op 与持久化差异；文件级 FILETAGS；tag-merge 的 relation-name；旧链接激活 helper | 原报告是线索，不是今天仍失败的证明。独立复现后开 bug，不借搬文件修业务 |
| 已复现、待定向修复 | 共享 locator 在目标位于窄化范围外时可返回可见 sibling，导致错误 ID 导航 | H 的 production-before 临时 Org 控制已证，不是 H 新回归或批准的产品行为；另派共享身份边界定向修复，未验证的写链影响/数据损毁不推断。结构收口不掩盖该风险，见 §8 NODE-H |
| 需产品/兼容决定 | 标签 ID=名、别名与显式斜杠 ID、无实体父路径查询域；多库 Git；新 AI 召唤；更严格的单节点 Accept/共享 retry 草稿政策；旧 `:embeds` 持久化政策 | 不在结构整理中擅定，也不迁移真实数据 |

持续保留：未知旧字段/继承来源、迁移待办、非重建集合、冲突/备份/恢复；旧 Automation 规则只预览、用户手改。旧计划的非默认测试分类与归档依赖数量不是整批删除授权。

## 4. 合并目标：把当前承载收拢到特性主文件

下表保留实施前 51 个根源码的承载基线；已实施的迁属由 §8 覆盖，不把已退场文件重新列为现状。表内名称省略 `supertag-` 前缀和 `.el` 后缀；标“部分”的混合文件按节迁移，同一函数最终只有一个 owner。**目标列是合并终点，不是为每个小能力再分配一个文件。** 目标已有文件就复用；旧承载清空后删除，不留转发壳或平行实现。具体加载依赖必须核对，不能按表机械拼接。

### 4.1 特性主文件

| 特性 / 建议落点 | 规划时承载 | 整理要求与保留契约 |
|---|---|---|
| 标签 `tag` | `ops-tag`、`ops-tag-merge`、`core-tag-path`、`view-svg-tag`；`ui-completion` 的 Tag 算法/写入部分；`ops-node`、`ui-commands`、`services-ui`、`services-capture`、`view-helper` 的标签部分 | 同一文件内包含规则/路径、输入补全、成员修改、改名/删除预览、写入编排与普通/SVG 显示。Capture 名下的活标签写链及 helper 的 face/font-lock/style-mode/hooks 都在本特性收拢；不新增独立 tag-style 文件。共用 writer/parser 和 Tag/Link 补全接线按 §4.2 保留单一实现，不改标签身份政策 |
| 节点 `node` | `ops-node` 的节点操作/导航部分；`ui-commands`、`services-ui` 的 find/select/goto/create/move 部分；`services-capture` 的标准 finalize/opt-in/hook；service-org 中节点移动专属交互编排待核 | 查找、预览、新建、移动、标准 Capture 接入在一个主文件内分节；不新增 move/capture 文件。包括现有 reference-and-create 写链、移动的选区/返回上下文与原 payload、默认关闭的 org-capture 接入。底层投影维护与共用身份/保存/恢复分别留 Sync/service-org；标签成员和物理链接格式按实际职责承接 |
| 概念与 Promote `concept` | `concept`；`link` 中 `supertag-reference-promote--failure/--retry/-continue`；service-org 中 Promote 专属流程待核 | 收回专属 continuation 与阶段状态机；共享 reference retry、materializer、保存/投影机制仍按 Link/service-org 契约保留，不把整条链接写链迁入 Concept。共用创建模板不能因 Promote 使用它就全部私有化 |
| 查询 `query` | `services-query`、`services-note-query`、`core-scan`、`services-formula`、`query-block` | 查询语法、计算、构建/说明、Org 查询块入口与渲染归一个特性，内部节分层。Babel 执行、动态块 writer 与 Org 注册都保留；保留属性快照的可变结构隔离、公式旧语法及 resolver。Automation 调用窄计算接口，不反向加载调度器 |
| 链接与关系 `link` | `link` 去除 Promote 专属编排后的部分；`ops-relation` 的特性逻辑；`ops-node` 的物理链接格式部分待核 | 普通/命名链接、关系查询、材料化与恢复归既有特性；物理 id/Denote 格式和 pattern 仍须供底层无 UI 消费者使用，不强迫其加载 Link UI。Link CAPF 实现在本特性，Tag/Link 共用启停保持顺序和一次撤除。Sync 保留解析/投影编排；关系词汇、会话及专属协议注册已由 LINK-D 结束旧决定 12 的暂留，归入 Link。Sync 通过普通 provider 首次调用，空文件解析也会加载 Link；加载成本及兼容边界见 §8 |
| 提及 `mention` | `mention` | 已竖切，保持；仅在真实依赖迁移时同步消费者，不为了本轮重新拆装 |
| Automation `automation` | 原承载：`automation`、`automation-sync`、`automation-templates`、`services-scheduler`；A–C已收拢至`automation` | 规则、动作、Store 订阅、调度与停止清理在同一特性分节。scheduler 是内部活能力，不因旧命令退役删除；保留状态文件、注册接口和切库时序 |
| Node View / Stream | `view-node`、`view-stream`；`services-ui` 的对应状态构建部分 | 沿用两个现有文件，各自收回自己的读模型与交互，不为去掉 view 前缀改名。Stream 的源编辑 session、保存/撤销和返回窗口一起保留；公共绘制归 Framework，不再为 state/render/controller 各建文件 |
| Discovery / AI / 语义候选 | `discovery`、`ai`、`semantic` | 已竖切，保持。Discovery 的多选插回、来源 marker/窗口和失败续做也是现役职责，不当作纯只读列表。AI 与语义候选不合状态；语义卡保持只读 |
| 情景动作 / 菜单 | `embark`、`menu` | 是各自的动作分发特性，不是共享 writer；只适配已存在的业务入口，保留可选依赖与冷启动行为 |
| 对外只读接口 | `api` | 保留 query/node/schema/catalog/json 的外部入口与返回契约。它是桥接特性，不因文件名叫 API 就视作可删横切层，不恢复 DB 写入口 |
| 库选择与配置 `vault` | `supertag` 的库配置/guard/activate/reset 部分、`services-vault-selection`、`setup` | 以完整库生命周期为一片，不只是提取函数。模板需要的纯路径计算不能为了取默认路径而触发主入口初始化 |
| Git / 迁移 / 诊断 | `git`、`migrate`、`doctor` | 各为现役特性；不恢复 DB Git 合并，不删除旧数据读取/恢复，不因函数不再 interactive 而删除内部能力 |
| 包入口 | `supertag` 的其余装配部分 | 最终只负责配置接线、特性装配、启动/停止顺序，不继续积累业务流程；它不是新增的横切服务 |

### 4.2 横切内部与旧层的混合职责：明确去向，不整批合并

| 当前承载 | 目标归属 / 进入时机 |
|---|---|
| `core-state`、`core-notify`、`core-transform` 的事务部分 | 随实际触达的 Store 事务/事件切口并入 `core-store` 内部节。必须保留提交、真实回滚、通知次数和失败顺序；不是删除事务机制 |
| `core-index` | 可重建索引的存储/失效/重建生命周期归 `core-store`；特性专属查询语义归所属特性。先逐节区分，不把所有索引连同业务回调整包塞入 Store |
| `core-transform` 的 Org 行内标签解析 | 已由TAG-PARSER将四常量＋五函数逐字归既有 `tag`，输入、显示与Sync复用唯一实现，Transform无壳退役；Store不加载此parser。原候选Sync会使Tag顶层常量/首次matcher产生反向加载，故依实际Tag语法职责调整归属，不新增横切或加载平台，公共Org解析仍调用Org自身。旧轻载可用性、显式reload与测试分代变化见§8 |
| `core-async` | 随 Sync 队列切口归 `services-sync` 内部节；同时核 Git 的真实调用和停止/失败列表行为，不造第二条队列 |
| `core-change` | 已由STORE-D将31原form整体归 `core-store`，旧载体无壳退役；Link局部抑制/Store原条件及两个commit协议保留。早special/API/双订阅guard和reload兼容见§8，不因直接caller少删除Canonical能力或合并业务队列 |
| `service-node-identity` | 共用身份与定位归 `service-org`；保留文件节点、Denote 与真实 Org 结构规则，ORG-A已完成ServiceOrg自身及Tag bulk的加载前置切口，身份原体尚未迁入，ServiceOrg现有Org-ID集成生命周期原位保留；继续按实际依赖迁属，不通过复制定位器脱环 |
| `services-template` | 共用创建模板的读取/规范化/目标能力候选归 `service-org`；Concept、Find、Link 都是消费者。纯路径选择已随 Vault 定属；ORG-A只完成前置加载切口，模板原体尚未迁入，不另留永久 template-service 层 |
| `view-api` | 订阅/实例公共机制归 `view-framework`；节点/标签等业务读模型分回特性，底层读取使用既有 Store 接口，不造另一套通用读层 |
| `view-helper` | 标签文本编辑与显示/face/font-lock 一起收进 `tag` 的不同节，通用控件归 `view-framework`，共用 Org 定位/编辑原语归 `service-org`。按函数取出是为了消除旧容器，不是再拆一组 helper 文件 |
| `services-ui`、`ui-commands` | 随标签、节点、视图的主体合并逐节取出；Move 是 Node 内部节，sync-status/resync 等入口归 Sync。剩余职责清零后删除旧容器，不改名继续保留万能 UI 层 |
| `ui-completion` 的共用接线 | 同一个 mode 同时安装/撤除 Tag 与 Link CAPF，且保持 Link 优先及 Tag 的 post-self-insert hook；全局模式还处理已打开的 Org buffer。Tag 算法/写入归 Tags，Link 算法归 Link，模式启停只保留一个 owner：由入口装配或工单确定的一方调用另一方窄入口。不拆两套 mode，不新增永久 completion-service 层 |
| 白名单 `view-framework` 的业务选择器 | `supertag-view--read-tag` 枚举标签、读取选择、推导后代并构造输入，实际被 Stream 的交互入口调用。随 Tags 切片迁属业务选择，Framework 只留通用机制；保留返回形状及后代语义，不因它在白名单文件里就永久留下 Framework→Tag UI 的反向依赖 |
| 白名单 `services-sync` 的混合部分 | `supertag-tag-style` 是文本写入格式，`supertag-sync-legacy-tags-policy` 是读取/转换政策，都不是 SVG/font-lock 显示配置；即便同属标签相关代码，也须保留各自写入/解析责任，不因同名当作显示开关搬动。通用遍历/条件查询候选归 Store/Query；extractor 的优先级注册接口留 Sync。`supertag-sync-export-file` 及生成 Org 内容 helper 仍存在直接文件导出代码，先登记、再查消费者与权限契约，不因“Sync 已归位”漏查，也不凭本轮静态清点保留为第二 writer 或直接删除 |

特别约束：`ops-node/tag/relation` 同时服务投影维护与用户操作，不能整包合入包含 UI 的特性后，要求 Sync 再加载该 UI。先区分 Store 原语、Sync 投影维护和特性决策，再确定函数的实际落点。保留接口并不要求保留旧文件；移动接口也不等于改变数据所有权。

旧决定 22 的两处函数体 `require` 过渡豁免中，Sync 的链接跟随已在 LINK-D 迁入 Link 并删除旧 UI require 分支，改由既有真实 Node 依赖保证导航；Menu 的懒加载包装已由 MENU-LAZY 改为首次调用时登记原生 autoload，唯一 static-gate marker 豁免已移除（行为取舍见 §8）。可选特性继续用文件头依赖或原生 autoload 接线，不能靠全部强制加载破坏可选性。

### 4.3 两轮复核补出的接口与状态约束

- **同名不等于同实现。** `services-ui` 与 `ui-commands` 都定义 `supertag-ui-select-tag-on-node`：前者排序候选、无标签时 message 后返回 nil，后者沿现有 tags 顺序、无标签时报 user-error。Tags 工单须先锁入口/加载顺序及现有调用者的行为，再确定唯一实现；不能以“去重”为名任意选一份。本轮不裁定统一后的行为。
- **配置注册表只有一份。** `supertag--view-configs` 的存活注册状态归 Framework；Tags 负责引用改写决策。`ops-tag-merge` 目前不仅读表，还复制、修改并在失败时恢复同一表；迁属必须承接访问/恢复接口，不能在两个特性各建副本。其旧 `supertag-query-saved` 兼容变量另待工单核实外部消费者，不复活 query-library，也不据根内零外部命中删除。
- **业务状态随特性，Vault 只协调。** `services-ui` 的候选缓存/选择状态/reset 随 Node；Automation 的规则索引、业务队列与 scheduler 任务状态各保持其职责。Store 协调索引失效/回滚，不复制业务索引；Sync 文件队列也不与 Automation 队列合成一条。迁移 reset/cleanup 函数时，同片更新主入口按符号调用的切库清单与停止顺序。
- **条件接线不是已验证订阅。** 例如 `services-ui` 的 `supertag-register-listener` 条件分支在这 51 个根文件内未找到对应定义；core-index 还含旧 schema 的条件回调。它们是待工单核实的兼容接线，不能写成当前已验证机制，也不能据静态结果恢复旧模块或直接删除分支。
- **白名单是职责目标，不是整文件豁免。** Persistence 的数据目录比较/确认迁移/回退 UI、Doctor 的确认修复与保存仍是现有能力；与标签显示同名的写入格式、Framework 的业务选择器等必须逐节辨别。文件搬迁不能改变错误传播、保存副作用或恢复责任。

## 5. 执行主线：逐个特性合并，而非逐层清理

不设“先整理全部 core，再整理全部 services”的阶段，也不再把标签显示、节点移动、标准 Capture 各建成新模块。下列是**合并批次**；一个批次可分段交付，但所有子片向同一个主文件收拢。解决阻挡本片合并的横切依赖是本片的一部分，不扩成整仓底层重写，也不全部推迟到最后。

| 顺序 / 合并批次 | 主体合并成果 | 必须保留的行为 |
|---|---|---|
| 1 `V2-TAG` | `ops-tag`、`ops-tag-merge`、`core-tag-path`、`view-svg-tag` 的特性实现及各混合文件的标签段收进 `supertag-tag.el`；旧文件在剩余共用职责有落点后退场 | 标签输入/补全、成员写链、改名/删除预览、普通/SVG 显示与自动启用、取消/草稿/失败恢复、同一配置表改写；Tag/Link 补全顺序与 Stream 选择契约 |
| 2 `V2-NODE` | 节点操作、Find/create/move、标准 org-capture 接入收进 `supertag-node.el`；`ops-node`、`services-capture` 和旧 UI 容器的相应部分不再平行承载 | 身份/文件节点/Denote、无 ID 预览零写、创建与移动的保存/恢复、原生 finalize；共用定位/模板/writer 仍在既定横切，不被 Node 私有化 |
| 3 `V2-QUERY` | 查询读取、语法/公式、构建/说明和 Org 查询块合到 `supertag-query.el`，旧 query/formula/scan 分层文件的相应职责清零 | 低层查询不因合并被迫加载 UI；属性快照、空/缺失/多值、旧公式/resolver、Babel/dblock；Automation 使用同一计算接口 |
| 4 `V2-LINK-CONCEPT` | `ops-relation` 的链接特性逻辑收进已有 `supertag-link.el`；Link/service-org 中 Promote 专属编排收回已有 `supertag-concept.el`，不新建关系服务或 Promote-retry 文件 | 物理链接格式、材料化与保存/投影恢复、Promote continuation 和原 payload；单次事件及通知抑制。Canonical Change 只作为本片事件边界的附带调查，不代替主体合并 |
| 5 `V2-AUTOMATION`（主体结构已闭） | `automation-sync`、`automation-templates`、`services-scheduler` 已收进 `supertag-automation.el` 的内部节，见§8 A–C | 单次 Store 订阅、规则/业务队列/任务状态各自职责、last-run 持久化、timer 停止、切库重建；不新建通用 scheduler/runtime 层 |
| 6 `V2-VIEWS` | 各自读模型和交互回到已有 `view-node`、`view-stream` 等特性文件；`view-api`/`view-helper` 的公共机制进入 Framework，混合容器最终清空 | 控件与订阅只有一份，特性状态不并进 Framework；真实按钮/按键、阅读位置、Stream 编辑 session、关闭清理；Discovery/AI/Semantic 不作无关改名 |
| 7 `V2-VAULT-ENTRY` | 库选择、配置向导与切库生命周期收进 `supertag-vault.el`；`supertag.el` 留装配；核清旧容器的剩余职责，不以又一层转发文件收尾 | 保存→停旧任务→切路径→加载→重建顺序；纯路径选择不触发初始化；菜单/可选依赖接线与主入口冷加载保持 |

上述文件退场以职责与消费者已承接为前提；不是借计划直接授权删除能力。已内聚的 Git/Migrate/AI/Semantic/API/Doctor 等保持既有文件，不为达到一个预设总文件数强行合并。是否存在旧加载路径兼容义务，在每批工单中说明，不能假装改 `require`/`provide` 不影响外部调用者。

### 第一批如何交给 worker

第一批是 **标签特性合并 `V2-TAG`**，最终只有 `supertag-tag.el` 这个标签主文件。取消前稿“先新建 tag-style，再另做 Tag”的顺序。

1. 使用已经两轮核对的职责清单，冻结本批实际涉及的文件/函数/状态/注册与回归路径。工单先回答“哪些实现会合到 tag，哪些旧承载会消失”，不再从泛化死代码搜索开始。
2. 核对真实依赖与反向加载边：事务/索引、共用 parser、Org writer、Framework 的业务选择器和 Tag/Link mode 都要有落点；不复制实现、不提前 `provide`、不靠函数体 `require` 躲环。
3. 允许分段落地：先承接必要共用依赖并建立标签主体，再收回输入/写入编排，最后收回显示/注册并清掉旧承载。具体顺序由依赖图定；每段直接修改同一个 `supertag-tag.el`，不产生永久的 tag-style/tag-completion 文件。
4. 混合文件仍有别的职责就保留剩余部分，并列出待哪一批取走；Capture finalize 留给节点批次，但其标签写链必须在本批改用标签主文件。共享文件不并行写。
5. 每段验证行为与加载，整个标签批次同时验收“功能保持”和“文件收拢”；仅迁完显示、仅改 require 或仅标好 owner 不能关闭整个标签合并。

## 6. 每片的交付与验收

### 先验收是否真正减少了碎片

每个合并批次必须给出同一口径的 before → after，不能只报测试通过或删除行数：

| 检查项 | 要交出的结果 |
|---|---|
| 特性实现分布 | 原来分在哪些生产文件，最终集中在哪个主文件；仍跨文件的部分是否确属五个共用模块或另一个完整特性 |
| 旧承载退场 | 实际消失的旧文件、从混合文件迁出的节，以及仍未清空的容器和后续批次；新增主文件但旧实现照留不算合并 |
| 新旧文件净变化 | 本批新增/删除/保留的文件列表；中间子片可以暂时增加文件，但整个批次不能把旧碎片换成一批新碎片 |
| 修改路径 | 选本特性的代表性维护任务，列出 before/after 需要改动的文件。目标是业务变化主要落在主文件；不为美化数字把共用能力复制进去 |
| 阅读完整性 | 在主文件能读到配置、主要流程、命令、展示和生命周期；真正的共用依赖在头部可见，不靠跳多层包装才能看懂 |

例如标签批次至少核对补全/成员修改、改名预览和显示三个路径；不用“有单独显示命令”证明显示必须另有文件，也不因合并后文件变长就按技术层拆回去。

### 工单必须回答

- **特性与入口**：用户从哪个命令、Org hook、视图或外部接口进入？
- **合并前 → 合并后**：哪个主文件承接实现，哪些旧文件/技术层真正消失；混合文件精确到函数/状态/注册。
- **保留与放弃**：现役消费者、动态加载、配置、持久化、第三方接口各是什么；哪些外部来源未知。
- **依赖与生命周期**：初始化、订阅、timer、取消、保存、切库和退出由谁负责；移动后没有第二个 owner。
- **白名单、反证和回退**：只改哪些路径，什么测试会证明移错/删错，如何不破坏继承的未提交修改地撤回。

### 文件形状

按特性需要分节，不强求空节或统一大模板：配置与状态 → 纯计算/读取 → 写入编排 → 命令与展示 → 注册/生命周期。文件头必须列真实入口和依赖，不能只写 `see public definitions below` / `see top-level require forms`。

```elisp
;;; Commentary:
;; Feature: 本特性负责的用户能力与明确不负责的事情
;; Commands: 实际入口；无交互命令时写明 hook/API 入口
;; Dependencies: 实际使用的横切模块、其它特性与外部可选依赖
;;; Code:
;; require / declare-function / 必要 autoload 接线均在文件头说明
```

### 验证顺序

1. 查消费者与旧名称残留：区分现役代码、测试、文档、归档和未知外部调用；零静态命中不是唯一删除证明。
2. 用真实调用路径锁行为；新增退役/加载断言须能在 before 反证。纯搬移不伪造业务失败，before/after 行为等价控制与源码身份比较分开报告。
3. 受影响默认套件、独立冷加载、guidance；然后跑默认完整入口 `bash test/run-tests.sh`。按实际 manifest 核齐每个 Suite/Ran，不能把最后一套 Git 的计数当全套。
4. 文件迁属时同步 runner 的显式源加载、测试选择、声明/加载元数据和实际文档入口；不能弱化 selector、用已安装旧包或遗留 `.elc` 获得假绿。
5. 编译只在临时副本；报告 before/after 警告变化。保留缺失可选依赖的 skip 与 sandbox/native 差别，不声称真实 Runtime/模型/GUI/库验收。
6. 独立审查、`git diff --check`、精确文件库存比较、before/after 哈希与临时正反重放。删除以路径缺席表示，不用空文件冒充。

源码整理默认只改文件归属，不迁移用户数据、不读私人配置/真实库、不安装、不 commit/push、不碰 `.worktrees/`。现有 pane 的 worker 负责授权源码片，support 只读独立审查，leader 管计划、总验证和收口；共享文件禁止并行写。若后续工单需要例外，先明确请求。

## 7. 什么才算整理完成

- 每个已触达特性的主要实现确实收拢到一个主文件，技术层改为文件内部节；不是只标了 owner，也不是把 ops/services/ui/view 换一组前缀。
- 修改一个特性的常见行为不再需要遍历多份技术层文件；读主文件能理解完整流程，共用能力仍经五个横切复用。
- 旧技术层承载已迁属、退役，或作为**尚未完成的过渡项**明确列出；不能边留着旧层边宣称整体完成。已经完整的特性文件可以原名保留，不追求所有旧文件都消失。
- 没有新增 tag-style/move/capture 等人为碎片，也没有新的万能 UI/API/utils 容器；不以集中为理由把不同用户特性塞进一个巨型总文件。
- 主入口只装配，依赖写在文件头，两个旧函数体 require 豁免已按各自行为消除；可选依赖仍可选。
- 旧容器的函数、配置、hook、状态与持久化消费者逐项有去向；公开能力与真实写入/恢复契约没有因结构整理退化。
- 测试与文档随所属特性同步；历史计划、归档源码、恢复资料不作美化目录的附带删除。

结构整理按已批准工单逐段完成；以下现状清单与 §8 FINAL-CLOSEOUT 接管最终结构状态，§4 保留规划时的51文件基线，不把其中过渡描述当今天仍有待迁carrier。

### 7.1 最终现状与维护落点（2026-09-10）

| 归属 | 当前文件 | 代表维护路径与边界 |
|---|---|---|
| Tag | `supertag-tag.el` | 成员增删、rename/delete、路径/输入/CAPF、普通/SVG显示在本文件；Org writer与Store经现有横切复用 |
| Node | `supertag-node.el` | Find/select/create、move、导航、标准Capture、候选缓存与条件listener准备集中；身份/模板/保存机制经ServiceOrg |
| Query | `supertag-query.el` | 查询/条件计算、数据读适配、构建器/说明及Org块；不代替Sync/ServiceOrg writer |
| Link | `supertag-link.el` | 普通/命名关系、材料化/重试、链接格式与CAPF；共享恢复仍经ServiceOrg |
| Concept | `supertag-concept.el` | Promote编排/continuation、概念监视与UI；复用Link及共享writer |
| Automation | `supertag-automation.el` | 条件/动作/模板、Store订阅、调度与清理在同一特性；晚加载已知风险单列 |
| Vault | `supertag-vault.el` | 库配置/选择/激活、guard、Setup与main显式prepare；默认数据目录冲突恢复仍属Persistence |
| Node View / Stream | `supertag-view-node.el`、`supertag-view-stream.el` | 两个完整视图特性；各自读模型/交互/状态，公共控件经Framework，Stream编辑session不拆散 |
| Mention / Discovery | `supertag-mention.el`、`supertag-discovery.el` | 各自特性保持内聚；不因相同前缀重新拆分 |
| AI / Semantic | `supertag-ai.el`、`supertag-semantic.el` | 显式审核写入与只读相似候选分立；可选runtime/endpoint不强制加载 |
| Embark / Menu | `supertag-embark.el`、`supertag-menu.el` | 上下文动作适配与惰性菜单；无新业务writer或通用loader |
| API / Git / Migrate / Doctor | `supertag-api.el`、`supertag-git.el`、`supertag-migrate.el`、`supertag-doctor.el` | 各自外部只读接口、Org-only传输、迁移、诊断呈现；不为统一文件名强并 |
| Store（横切） | `supertag-core-store.el` | 状态/集合、事务与通知、派生索引、Canonical；旧State/Notify/Index/Change职责已合并 |
| Persistence（横切） | `supertag-core-persistence.el` | 序列化/加载保存、锁、origin/guard、备份及恢复授权链；带UI不是迁属理由 |
| Sync（横切） | `supertag-services-sync.el` | Org解析/投影、增量/重建、队列、验证/GC/缓存与文档导出；保原位公共helper不借零caller删API |
| Org（横切） | `supertag-service-org.el` | 共用身份/定位、模板、受控活buffer编辑、保存投影及恢复；旧Identity/Template已退役 |
| Framework（横切） | `supertag-view-framework.el` | 视图注册/实例/刷新/控件/绘制/清理；业务读模型归各自特性 |
| main | `supertag.el` | 配置接线、prepare、启动/退出/Org hook装配及启动前后诊断；不强迫装配文件只剩require |

- Tag/Node/Query等常见维护不再跨同特性的ops/services/ui技术层；真正共用机制仍在五横切，不复制成每特性一份。完整的Node View/Stream等保原名，不为数字再造文件。
- 旧carrier已由各片无壳退役；保留下来的公开函数名可仍含旧前缀，不等于第二实现或未清carrier。未知外部显式旧feature/file require不保证兼容，须按已接受的逐片新owner接入。
- 函数体require两项过渡豁免均退出，无新通用utils/runtime/loader层。Node/Vault/main的prepare和guarded能力是已验证加载合同，不按零caller或名字另开删除。
- 历史归档、旧计划、恢复兼容资料和非默认测试不在结构收口中清空。Sync collection变量拼写/nil槽、路径别名、恢复error/quit边界、缺迁移菜单、F1/F2/QD/Sibling/Automation晚load均不是“结构完成”顺带修好的功能。


## 8. 实施记录

### V2-TAG-A：建立标签主文件（2026-09-07，已验收）

- **合并成果**：`supertag-ops-tag.el` 与 `supertag-core-tag-path.el` 的实体/索引/操作及五个路径函数合入 `supertag-tag.el` 的内部节；两份旧源码真正删除，无转发壳或平行实现。根 `.el` **51 → 50**。
- **保留行为**：39 个原函数/变量定义与两段原实现逐字不变；19 个根消费者、10 个原测试消费者仅切换加载元数据。原六个路径 ERT 保留，新增两个独立冷加载 ERT。现役函数/配置名不改，不触及数据格式或 Org writer。
- **验证**：leader before 默认 33 套件 **705 = 702 通过 + 3 可选跳过**；after 默认 33 套件 **707 = 704 通过 + 3 可选跳过**，各有完整 33 个 Suite/Ran，0 unexpected。定向六套 67/67 → 69/69；Tag/Sync/主入口的独立冷加载与路径/别名控制 before/after 各 3/3；guidance 通过。
- **结构与编译**：39 定义与原六 ERT 字节核对、33 路径库存、临时正反重放通过；独立审查无必修。受影响生产文件临时编译 before/after 均 exit 0，106 条 `Warning:` 消息内容/数量一致，另有两侧均存在的 wrapper 提示；不称零警告。完整门为隔离 HOME 的 native 入口，定向门为 deny-network sandbox，不混同旧 Git 分环境证据。
- **兼容边界**：旧两个 feature/file 加载名不保留壳；私人/第三方显式 `require` 消费者未知，需自行切换到 `supertag-tag`。路径能力不再是仅依赖 subr-x 的独立文件，会加载现有 Tag 依赖链；冷加载验证无 UI/主入口初始化，不声称无依赖或绝对无副作用。非默认历史测试仅更新加载名，未重新验收其旧契约。
- **尚未完成**：标签补全/成员写入、合并与改名预览、普通/SVG 显示及混合容器中的标签段仍在旧承载。当前只减少了路径规则与实体/索引维护的一处文件分隔，主文件尚不能读到完整标签交互；后续继续收进**同一个 `supertag-tag.el`**，不另建小模块。整个 V2-TAG 及其余六批未关闭。
- **证据与限制**：leader `/private/tmp/supertag-tag-a-leader-3hq31rtg/REPORT.md`；worker `/private/tmp/supertag-tag-a-worker-1uz8sr81/REPORT.md`；独立审查路径由 leader 收据记录。保留精确 before/after、日志与可正反重放补丁，未提交。未读私人配置/真实库，未做真实 Runtime/模型/GUI/版本矩阵验证；不迁移用户数据，不重开旧产品问题。

### V2-TAG-B：合并与路径改名归属收拢（2026-09-07，已验收）

- **合并成果**：整个 `supertag-ops-tag-merge.el` 及其调用的两个跨文件文本 rename helper 收进既有 `supertag-tag.el`，旧 Merge 文件删除。根 `.el` **50 → 49**；没有 Tag→helper→View API 的加载回环，没有新增模块或兼容壳。
- **保留与变化**：原 Tag 39 定义、Merge 42 函数/状态/常量、两个 helper 共 **83 定义逐字保持**。同一 query/view 注册状态及原恢复策略保留，两个原 defvar 会随 Tag 更早绑定但不覆盖预置值。helper 其余实现只加明确 Tag 依赖与一个无初值前向声明；原初始化不变。普通交互改名另有现役链，本段未将 Merge 冒称为其 writer。
- **验证**：当前 API 业务 before 7/7；结构 before 在真实入口加载后因旧文件仍在而失败，after 转绿。最终定向六套 **77/77**；leader 默认完整 before **33 套 707 = 704 + 3 可选跳过**，after **33 套 715 = 712 + 3 可选跳过**，0 unexpected。原 10 ERT 保留，新增 5 业务及 3 冷加载/加载顺序 ERT。独立审查无必修/新增建议，状态覆盖与实际移出函数 owner 的反例被正确拒绝；库存/字节比对、正反回放、guidance、diffcheck 均过。
- **编译**：断开旧预加载后初次警告 12→14，暴露 helper 同文件晚定义变量；仅补无初值前向声明。最终临时编译 exit 0/0、12→12 消息一致，未顺改其它警告。初次与最终证据分别保留。
- **证据边界**：真实文件写入后故障回撤覆盖 disk/live/dirty/Store/query/view，但隔离了 hooks，非完整原生 save-hook→异步 Sync/vault 链；未验恢复自身失败、崩溃原子性、关系/Automation/Board 的非空恢复矩阵。历史旧字段测试仅更新加载名，私人/第三方旧 Merge `require` 未保壳且来源未知。早版夹具失败另存，正式业务绿为 `business-before-final.log`，不冒充业务缺陷红。
- **剩余与证据**：显示、输入/补全、成员写入和混合容器标签段继续合到同一 Tag 文件；整个 V2-TAG 尚未关闭。leader `/private/tmp/supertag-tag-b-leader-t4aszy1f/REPORT.md`；worker `/private/tmp/supertag-tag-b-worker-ih6xxshn/REPORT.md`；独立审查 `/private/tmp/supertag-tag-b-check.8xy4SW/`。后续连续推进，不逐段等待用户重新批准；不据此扩大产品、数据或兼容政策。

### V2-TAG-C：普通与 SVG 显示归入 Tag（2026-09-07，已验收）

- **合并成果**：helper 的普通样式、matcher、face、mode 与整份 SVG 的配置/几何/字体/色彩/cache/显示/主题响应集中到 `supertag-tag.el` 内部节；旧 `supertag-view-svg-tag.el` 真正删除。根 `.el` **49 → 48**。维护标签显示不再横跨 helper 与 SVG 两个承载，通用绘制、分隔符和未迁文本 helper 仍留原位，不另建 tag-style 文件。
- **保留与初始化**：135 个定义中 **134 逐字保持**，包括 B 的 83 个定义；唯一变化是 enable-existing 跳过已启用 mode。所有定义完成后，末尾统一装命名 hooks、调和已启用 buffer，再按 auto-enable 启用未启用 Org。手动开启与 auto=nil、SVG 偏好、mode 关闭、nongraphic 回退和预置配置保持；main 只删旧加载行，menu 保留真实懒入口与原命令名。原 SVG 10 + View 22 共 32 ERT 不变，新增 3 个独立冷加载控制。
- **验证**：同一生命周期控制在旧源 **2/2**，结构 before 在真实入口 `ENTRY-LOADED` 后因旧 SVG 承载残留而红。最终定向六套 **88/88**；完整 before 沿用字节一致的 B 最终基线 **33 套 715 = 712 + 3 可选跳过**，leader after 实跑 **33 套 718 = 715 + 3 可选跳过**，0 unexpected。真正 menu 冷调用、四配置组合、已有/只读 Org、非 Org、font-lock、theme、reload 与文本/dirty/disk/既存 Store 事实控制通过，A/B 冷加载保护未改。
- **编译与审查**：受影响生产文件在临时副本编译 exit 0/0；`Warning:` **46 → 45**，只减少旧 SVG keyword 前向变量警告，无新增，另有两侧既存 wrapper 提示。独立审查无必修；移除 active 调和的反例被正式 cold helper 拒绝，另透传观察实测 active/inactive 各刷新一次。非阻塞建议 S1：未来在触达样式测试时，把一次刷新计数纳入正式 ERT；当前最终 keyword 唯一断言不等于已经永久锁住调用次数，不因此重开本段。完整库存、guidance、diffcheck、精确正反回放均通过。
- **边界与剩余**：Tag 加载会更早安装显示 hooks、调和已开 Org 的内存样式，并非无副作用；没有正文或持久事实写入。图片/图形能力为明确 seam 桩，不称 GUI、版本矩阵或任意旧版本热升级。旧 SVG feature/file 不保壳，原 defgroup/keyword 符号保留；私人显式加载消费者未知。输入/补全、成员写链及混合容器的其它标签职责仍待收拢，整个 Tag 不关闭。
- **证据**：leader `/private/tmp/supertag-tag-c-leader-72tke1ox/REPORT.md`；worker `/private/tmp/supertag-tag-c-worker-mffw9tsp/REPORT.md`；独立探针 `/private/tmp/supertag-tag-c-check.U8kbSm/`、定向日志 `/private/tmp/supertag-tag-c-independent-targeted.log`。初稿 setup 失败与正式红/绿分开留存；采用 worker 最终 `after/`，不把 scratch 测试当最终字节。未提交、不改其它写链或产品决定；后续直接准备同一 Tag 主文件的成员写入段。

### V2-TAG-D1：成员写入闭环归入 Tag（2026-09-07，已验收）

- **合并成果**：Capture 的四个成员编排、Node ops 的四个 membership 操作、Org service 的九个 Tag 规则和 helper 的四个文本操作，共 **21 函数**收进 `supertag-tag.el`。成员修改不再横跨四个技术层承载；共用定位、保存、投影和恢复仍留 `service-org`，没有第二 writer。混合容器仍有其它职责，本段不删文件，根 `.el` **48 → 48**。
- **保留与加载**：原 C **135 定义**、原 **24 ERT**及剩余载体的定义逐字保持；迁入 **20/21** 原体不变。bulk 唯一必要变化：节点/位置验证通过后、任何实体创建/事务/文本修改或 saver 捕获之前，显式解析 saver 的 autoload；非 autoload 的 advice/替身不覆盖。头部窄 Org autoload 和 Node 四个旧入口的反向 autoload 保持冷加载，无 Tag→Sync/Org/UI 顶层加载环。新定义全部在原 C 显示接线前，标准 Capture 生命周期未搬。
- **验证**：写前新增业务 **16/16**；结构 before 真正 `D1-ENTRY-LOADED` 后因旧 owner 而红，后加冷控制不冒称写前执行。最终定向八套 **175 = 174 通过 + 1 可选跳过**；完整 before 沿用字节一致的 C **33 套 718 = 715 + 3 skip**，leader 最终 after 实跑 **33 套 729 = 726 + 3 skip**，0 unexpected。八个新 fresh 子进程控制与三项业务测试覆盖首次 bulk、alias/新路径、每节点一次保存/投影、heading/FILETAGS 替换删除、Node 两种加载顺序、解析失败及实际落盘后的补偿/补偿再次失败。guidance、原冷门、范围核验、正反重放均通过。
- **编译与独立审查**：初轮临时五文件编译 **20 → 21**，只新增 Sync occurrence 读取函数未声明；精确补一条无参 `declare-function`，不增加 autoload/require 或改函数体。最终编译 exit 0/0、**20 → 20** 消息一致。独立审查无必修；其行为/反证运行在单行声明前的稳定字节，最终另核声明、七路径及冻结，leader 最终全门不混用旧日志。非阻塞 S1 留记：将解析失败测试补成直接观察解析时事务/创建调用数及具体错误；当前顺序正确，已有提前解析删除反例使 cold bulk 精确失败，但“最终零写”本身不证明中途未创建又回滚。
- **范围与剩余**：真实临时 Org→投影→保存及命名故障缝，不外推完整 vault、任意用户 hook、GUI/版本矩阵或崩溃原子性。输入、显式命令、capture prompt、共享 CAPF/mode 与 placement 仍待收拢；两个同名 selector 的空态/加载顺序差异是待明确的兼容决策，未借 D1 偷改。整个 Tag 不关闭。
- **证据**：leader `/private/tmp/supertag-tag-d1-leader-b_rripwe/REPORT.md`；最终 worker `/private/tmp/supertag-tag-d1-final-7l2y_qh5/REPORT.md`；初轮 `/private/tmp/supertag-tag-d1-worker-jwy81wee/REPORT.md` 原封保留；独立 `/private/tmp/supertag-tag-d1-check.Y4npvx/`。累计七源码/测试路径加本计划冻结，未提交；原 C 冻结未动。

### V2-TAG-D2：标签输入与插入位置归入 Tag（2026-09-07，已验收）

- **合并成果**：UI 的三个输入函数、Capture 标签 prompt、View API 的排序 ID 列表及 helper 的五个 placement/bounds 函数，共 **10 定义**合入 `supertag-tag.el`。原 D1 **156 定义**与原 **19 ERT/测试 helper**不变，10 个迁入定义含 `cl-defun` 全部逐字保持；Tag 原有顶层执行顺序及显示尾接线未变。completion 只切换一处声明来源，仍未搬 mode。混合容器继续保留其它职责，根 `.el` **48 → 48**。
- **保留契约**：省略 TAG-IDS 与显式 nil 的 supplied-p 区别、canonical 显示名/稳定 ID、affixation、多选初始项/剩余候选、field 原 fallback 顺序保持；不把任意 alias 解析能力扩称为输入能力，不顺修旧 list fallback 限制。placement 无 drawer 时原来会插换行，保持文本/point/narrowing 行为，不冒充只读定位器；bounds 继续用同一 Tag matcher。Query 路径读取经头部窄 autoload 首用加载，独立 Tag 不预载 UI/Query/Sync/Org service。
- **验证**：生产 before 不变时新增业务 **26/26**；结构 **27 = 26 通过 + 1 owner 失败**，真实 `D2-ENTRY-LOADED` 后才红，最终测试字节与写前红输入相同。最终定向七套 **132 = 131 通过 + 1 可选跳过**；完整 before 沿用字节一致的 D1 **33 套 729 = 726 + 3 skip**，leader after 实跑 **33 套 737 = 734 + 3 skip**，0 unexpected。首次真实输入后 Query 已加载而 UI/Sync/Org service 未加载；随后加载旧承载仍保持十函数 owner 为 Tag。guidance、全部旧 cold/写链、库存与正反重放通过。
- **编译与审查**：临时六生产文件编译 exit 0/0，**23 → 23** 条 `Warning:` 内容/数量一致，另有既存 wrapper 提示；不称零警告。独立审查无必修/阻塞；supplied-p 改用 tag-ids 的临时命名反例被显式 nil 用例准确拒绝。初次探针漏 test load-path 的 setup 失败单独保留，不计产品红。
- **剩余与证据**：两个 selector、commands/options/menu、共享 Tag/Link CAPF/mode 未动，空态兼容选择仍不擅定。整个 Tag 尚未完成；下一段可完整收拢共享补全而不新增层。leader `/private/tmp/supertag-tag-d2-leader-facnw1y0/REPORT.md`；worker `/private/tmp/supertag-tag-d2-worker-dup31n9c/REPORT.md`；独立 `/private/tmp/supertag-tag-d2-check.KEnHPS/`。仅临时 Org/Store/输入边界验证，不外推任意第三方回调、真实 Runtime/模型/GUI/库或版本矩阵；七源码/测试路径加本计划冻结，旧冻结未动，未提交。

### V2-TAG-D3：补全算法与共享模式归入 Tag（2026-09-07，已验收）

- **合并成果**：`supertag-ui-completion.el` 的完整候选/提交/词界算法、配置、buffer-local hint、共享 Tag/Link 的 local/global mode 及旧 provide 后的 debug，共 **20 原定义**迁入 `supertag-tag.el`；旧 completion 文件真实删除，无壳、第二 mode 或 dispatcher。根 `.el` **48 → 47**。原 Tag **166 定义**、原显示尾和顶层执行相对顺序保持，20 迁入定义及四个 autoload cookie 原样。
- **加载与行为**：头部真实 seq/easy-mmode 依赖和窄 Query/Link autoload 取代旧整份加载链。Tag 独载不提前开启全局补全，也不预载 Link/Query/UI/Sync/Org service；原 main Step 11/12 及 delayed/late-init 保持。共享 CAPF 仍为 Link→Tag，首次真实 `#` 补全会先加载完整 Link 再返回 Tag 候选；这是实际保留边界，不声称只有 `[[` 才加载 Link。第三方 CAPF、一起撤除、配置预置、hint 隔离、table/live-prefix/退出状态与真实保存投影均保持。
- **验证**：写前新增业务 **32/32**；结构 before **35 = 32 通过 + 3 owner 失败**，均在真实 `D3-ENTRY-LOADED` 后失败。最终声明修订后的 leader 定向七套 **160/160**；before 全套沿用字节一致的 D2 **33 套 737 = 734 + 3 skip**，最终 after 重新实跑 **33 套 746 = 743 + 3 skip**，33 个 Suite/Ran 及默认顺序核齐，0 unexpected。guidance、runner 反例、A/B/C/D1/D2 冷加载保护均通过；不是把首轮日志当声明修后证据。
- **编译与独立审查**：首轮临时编译 **38 → 40**，只新增 main 对 Sync 配置变量的两条前向引用警告；最小补一个无初值 `defvar`，真实 defcustom/default 仍由 Sync 提供，无新 require/autoload/初始化赋值。最终三 before/两存活 after 生产文件在全根源码临时副本中编译 exit 0/0、**38 → 38** 条 `Warning:` 正文/数量一致，另有两侧既存 wrapper 提示。独立初轮审查实跑 160/160 与 hook 安装缺失反证；最终另核唯一声明和十二路径冻结，无必修/阻塞。主入口相对 before 仅删旧 require 加裸声明，其它函数不变。
- **证据与边界**：leader `/private/tmp/supertag-tag-d3-leader-n5b_xe87/REPORT.md`；最终 worker `/private/tmp/supertag-tag-d3-final-_tiesx90/REPORT.md`，初始 `/private/tmp/supertag-tag-d3-worker-lc627tyv/` 保留。独立初轮 `/private/tmp/supertag-tag-d3-review-20260907-72981-l8ajrq/`，最终声明 `/private/tmp/supertag-d3-declaration-review-20260907-81489-n0todz/`。十二源码/测试路径加本计划累计冻结并正反重放；八个测试加载消费者精确接线，历史业务不因此称已绿。新 cold Link 证明 existing 目标的真实 hook/table/exit/save/project，不外推所有新建节点冷启动失败路径；未验证 GUI、真实库/模型或私人第三方旧 feature 加载兼容。
- **剩余**：显式标签 commands/options/menu、两个同名 selector 的兼容选择、Framework 中供 Stream 使用的标签业务选择等仍待收拢，整个 V2-TAG 不关闭。旧 completion 加载名退役，公开函数/mode/config 名保留。用户新提出的两项补全体验问题另列 §9，不把结构保留测试通过当作产品体验已经满足。

### V2-TAG-D4：标签管理命令与 Stream 标签选择归入 Tag（2026-09-07，已验收）

- **合并成果**：UI Commands 的 collect/preview/rename/delete/cleanup 五个函数及两个插入位置配置、Framework 的标签选择函数、View API 的后代 reader 包装，共 **7 函数 + 2 配置**原体迁入 `supertag-tag.el`。原 Tag **186 定义**及原顶层执行顺序/显示尾保持，现 **195 定义**；三个旧承载只迁出相应定义及 cookie、补归属说明，其余职责原样。混合文件尚未清空，根 `.el` **47 → 47**，不为追求文件数删活能力。
- **接线与保留**：Tag 头部窄 autoload 两个 core-scan reader 与 Org 的 with-node-buffer；collector 经真实 Org provider 先加载 Sync 再执行 occurrence callback，无新 Sync 占位或 Tag→UI 顶层加载边。menu 只迁 rename/delete 两个 wrapper/provider 并校准声明参数；migrate 只改 rename autoload/provider 头，真实迁移调用/恢复不变。两个配置更早归 Tag，但预置值及旧 add-tag 消费保持；Stream 仍按原 `:value` 和后代读取逻辑，不重新解释 plist 的布尔字段。
- **验证**：生产未变时新增业务 tag-change **17/17**、Framework **23/23**；结构 before **39 = 35 通过 + 4 owner 失败**，均在真实入口 `ENTRY-LOADED` 后失败。最终 leader 定向七套 **180 = 179 通过 + 1 可选跳过**；完整 before 沿用字节一致的 D3 **33 套 746 = 743 + 3 skip**，after 实跑 **33 套 752 = 749 + 3 skip**，33 个 Suite/Ran 和默认顺序核齐，0 unexpected。四条 fresh Tag/menu/UI/owner 控制、真实 preview/取消/保存投影、orphan 选择及配置引用保护、真实 Org→reader→交互 Stream 父子孙显示均通过；原 **73 ERT/helper**保留。
- **证据校准**：一个新增测试最初把 beginning 位置预期写错；生产未改，迁移后用冻结 before 独立补跑 **1/1**，证实既有结果 `* Property #old/child Node`，才校准该新增断言。不是主仓写前绿，也不是新增产品规则；旧断言不变。最初测试语法错误仅为夹具构造失败，不计结构红。Tag/menu 实测必要 scan/Org/Sync 已载而 UI/commands/Framework 未载；UI 先载分支的软 selector 函数对象不变，有意加载旧承载的 owner 分支不冒充独载图。
- **编译与独立审查**：六个受影响生产文件在完整根源码临时副本中编译 exit 0/0，**27 → 27** 条 `Warning:` 正文/数量一致，另有既存 wrapper 提示，不称零警告。独立审查无必修/阻塞，独立定向 180=179+1skip、实际 raw/加载链/九路径冻结正反通过；未另做 mutation，不把普通绿概括成全部反证完备。guidance、完整库存、diffcheck、九源码/测试路径加本计划的十路径累计正反回放均通过。
- **剩余与证据**：add-tag/region、remove-tag-from-node 和两个同名 selector 留原位；空态及非空过滤兼容选择不擅定，F1/F2 不扩。scan reader 仍是原 owner 的显式惰性过渡依赖，整个 Tag 和 Framework 整理不关闭。leader `/private/tmp/supertag-tag-d4-leader-1c84c6vr/REPORT.md`；worker `/private/tmp/supertag-tag-d4-worker-9q1vaxtv/REPORT.md`；独立 `/private/tmp/supertag-d4-review-20260907-99576-87z9c0/` 与 `/private/tmp/supertag-tag-d4-independent.log`。仅隔离临时 Org/Store，未验证 GUI、真实库/模型、任意第三方配置/旧单文件消费者或跨文件原子恢复；旧冻结未动，未提交。

### V2-TAG-D5：添加标签命令与 region 收集归入 Tag（2026-09-07，已验收）

- **合并成果**：`supertag-add-tag` 与 `supertag-ui--get-nodes-in-region` 两原体从 UI Commands 迁入 Tag，**195 → 197 定义**。原 195 定义、顶层执行顺序、显示尾及原 **39 ERT/测试 helper**逐字保留；menu 只改 add 的声明和真实 wrapper provider。根 `.el` **47 → 47**，共享 Node、remove 和两个 selector 仍在旧承载。
- **加载与行为**：Tag 仅窄 autoload 两个共享 Node getter/marker，Sync 入口仅声明；真正 Commands provider 完成 Sync 加载后才执行 Node 辅助函数，不改变内部 fboundp 分支。单节点/menu 与 live-marker 批量路径仍会惰性加载 Commands，已投影批量可不加载；不是完全消除 UI 运行依赖。标题/正文/region 在 prompt 前的 ID 与投影差异、整数 region 边界、取消后已发生的身份副作用及 D1 保存/补偿全部保留。
- **验证**：生产未变时新增业务 **45/45**；结构 **49 = 45 通过 + 4 owner 失败**，各组首个子进程先 `D5-ENTRY-LOADED` 再红，不声称十场景全在写前执行。最终 worker、独立审查、leader 定向各 **207 = 206 通过 + 1 可选跳过**，十条 fresh 场景全部通过。完整 before 沿用字节一致的 D4 **33 套 752 = 749 + 3 skip**；leader after 实跑 **33 Suite/Ran、762 = 759 + 3 skip**，默认顺序核齐，0 unexpected。三个受影响生产文件在完整根源码临时副本中编译 exit 0/0，**26 → 26** 条 `Warning:` 正文/数量一致，另有既存 wrapper 提示，不称零警告或全根编译。
- **证据校准**：新增夹具曾误判 live-marker 不可定位、文件级 point-min 可成功及 nil roots 等于 scope 外；未改生产体求绿。最终用明确不同临时 root 校正 scope；迁移后冻结 before 补跑 **1/1**，独立原脚本及加强节点相等断言各 **1/1**，证实原拒绝/补偿边界。不是主仓写前产品红，也不概括为所有文件节点操作失败。详细初稿/正式日志归属见报告。
- **收口与剩余**：独立审查无必修/阻塞；guidance、全库存、diffcheck、四源码/测试路径加计划的五路径累计正反回放通过，staged 空、根 elc 为零。leader `/private/tmp/supertag-tag-d5-leader-v577dvab/REPORT.md`；worker `/private/tmp/supertag-tag-d5-worker-2w4zsaje/REPORT.md`；独立 `/private/tmp/supertag-d5-review-20260907-25098-xdd2vb/REPORT.md`。remove/两 selector 的空态及非空过滤兼容选择、F1/F2 仍待定，不总闭 Tag。仅隔离临时 Org/Store 验证，不外推真实库、GUI/模型、第三方配置或跨文件原子恢复；旧冻结未动，未提交。

### V2-TAG-D6：移除标签命令与唯一选择器归入 Tag（2026-09-08，已验收）

- **已确认的行为选择**：用户批准统一采用正常主入口的硬版 selector——直接读取节点原始 `:tags`，无节点或无标签时 `user-error`；不保留 standalone/reload `services-ui` 的 Query 过滤、预排序及空提示后返回 nil 分支。此前各段的“selector 尚未裁定”到此被覆盖，历史回执不改写。真实 read-tag 自身仍排序/去重，不据两版本传参顺序推断可见菜单次序变化；未新增畸形投影处理策略。
- **合并成果**：`supertag-remove-tag-from-node` 和硬版 `supertag-ui-select-tag-on-node` 两原体迁入 Tag，**197 → 199 定义**；两个旧承载中的三定义删除，其中软版是授权退役而非等价迁移。原 197 定义、执行顺序/显示尾、原 **79 ERT/helper**与两个测试全文前缀保持。menu 仅 remove 声明/wrapper provider 改 Tag；复用 D5 getter 与 D1 writer，无新加载层、策略开关、兼容壳或依赖。根 `.el` **47 → 47**。
- **验证**：生产未变时业务 Tag **52/52**、Embark **32 = 31 + 1 skip**。初次三项红中 menu 因夹具提前调用未加载 API 失败，该项不算产品红；修正为父进程投影字面快照后，迁移后冻结 before 的三合同测试 **0/3** 均在 ENTRY 后准确命中 owner 或 UI 软空差异。后来补的空 reference 控制另在冻结 before **1/1**，不混入写前计数。最终 worker、独立、leader 定向各 **216 = 215 + 1 skip**；完整 before 沿用字节一致 D5 **33 套 762 = 759 + 3 skip**，leader after 实跑 **33 Suite/Ran、771 = 768 + 3 skip**，0 unexpected。
- **保留边界与审查**：六个 fresh Tag/menu/UI/Commands/reload 场景保持唯一 owner；真实 heading/body/Embark node/reference 只移除所选关联，保留其它节点及 Tag 实体。输入后新草稿由原 remote 再检守卫拒绝。无 ID 的 remove 仍可能先写 live ID 而不投影，不承诺空操作全面零写。四受影响生产文件在完整根源码临时副本编译 exit 0/0，**31 → 31** 条 `Warning:` 正文/数量一致，非零警告。独立审查无必修，独立定向 216、冻结前三合同红及空 reference 1/1 已复现；未代称重跑全套/编译。
- **收口与后续**：六源码/测试路径加计划的七路径累计正反回放、guidance、全库存及 diffcheck 通过，staged 空、根 elc 为零。leader `/private/tmp/supertag-tag-d6-leader-w6_fmvqy/REPORT.md`；worker `/private/tmp/supertag-tag-d6-worker-4p7thym2/REPORT.md`；独立 `/private/tmp/supertag-d6-review.lbqOna/REPORT.md`。窄收尾清点仍发现 Sync 的标签写格式配置/helpers 与 View API 活标签读取包装待精确迁属，整个 Tag 尚未关闭；共享 parser、投影/legacy 读取与 Node/Capture 生命周期不混入标签片，F1/F2 继续只记录。仅隔离临时 Org/Store 验证，私人软返回消费者兼容变化已披露，不外推真实库/GUI/模型、版本矩阵或跨文件原子性；旧冻结未动，未提交。

### V2-TAG-D7：写格式、token 合并与按标签读取归入 Tag（2026-09-08，已验收）

- **合并成果**：Sync 的 `supertag-tag-style` 配置、三个 token 合并/格式选择/格式化函数及 View API 的 `nodes-by-tag` 包装，五个原 form 收进 Tag，**199 → 204 定义**。原体、原顶层执行顺序/显示尾与原 **55 ERT/helper/测试全文前缀**保持；仅新增普通 Query provider 的窄 autoload/准确声明。两混合载体保留其余职责，根 `.el` **47 → 47**，不复制 parser、Query 索引或共享 renderer。
- **配置与真实行为**：配置随 Tag 更早绑定/注册，但仍属原 Sync group，inline 默认及 org/both/auto/显式 nil 预置值、后续加载/reload 和唯一 group 成员保持；不与普通/SVG 显示开关混同。四种 style 均经真实 create→save→project，核精确 headline、ID、body、稳定 Tag ID 等投影及 disk/live clean；未把夹具携带 NOTE 属性说成新增逐属性断言。七个 fresh 场景覆盖 Tag/Sync/View API 入口、配置与真实 Query 查询；Tag 首查后 Query 已加载而 Sync/UI 未加载。既有真实 Promote、Stream 父子孙及保存刷新控制另行承接，不冒称新增全 style Promote 矩阵。
- **红绿归属**：首轮 ID 抽屉空白断言错误属于新夹具失败，不算产品红；修正后生产未变时业务 **57/57**。最终测试字节的 owner before **59 = 57 通过 + 2 失败**，均真实 ENTRY 后命中旧 owner；每个分组只跑到首个失败 child，不称七场景全部写前红。独立审查另在冻结 before 复现两业务绿/两 owner 红，不混写前时序。新增四 ERT 后 tag-path **59/59**。
- **最终门与审查**：worker、独立与 leader 定向各 **241/241**；完整 before 沿用字节一致的 D6 **33 套 771 = 768 + 3 skip**，leader after 实跑 **33 Suite/Ran、775 = 772 + 3 可选跳过**，0 unexpected。三个受影响生产文件在完整 47 根源码临时副本编译 exit 0/0，**45 → 45** 条 `Warning:` 正文/数量一致，非零警告。定向为 deny-network 包装，完整门为隔离 HOME 的 native/local Git 夹具，不混称 sandbox 全套。独立审查无必修；guidance、库存及 diffcheck 通过，staged 空、根 elc 为零。
- **收口与剩余**：四源码/测试路径及加入本计划的五路径累计冻结、正反回放见本次 leader 收据。目录/身份读取及标签值显示的四个残留适配仍待同一 Tag 主文件收拢，不能因零根调用就删掉或忽略其归属；`node-field-in-tag` 实为 Query/Node 属性读取，共享颜色、parser/投影/legacy 读取、Node/Capture 生命周期保持其它 owner。整个 Tag 不关闭，F1/F2 仍仅记录，不借此授权补全 UX、旧 API 删除或新的横切文件。
- **证据与限制**：leader `/private/tmp/supertag-tag-d7-leader-3mo29p0g/REPORT.md`；worker `/private/tmp/supertag-tag-d7-worker-5j3wlflj/REPORT.md`；独立 `/private/tmp/supertag-d7-review.Mk5X05/REPORT.md`。只有隔离临时 Org/Store 与明确加载边证据，不外推私人配置/第三方消费者、真实库/GUI/模型、版本矩阵或跨文件原子性；D6 及旧冻结不动，未提交。

### V2-TAG-D8：目录、身份与标签值显示适配归入 Tag（2026-09-08，已验收）

- **合并成果**：View API 的 `list-tags/tag-id`、Services UI 的 `resolve-node-tags` 及 helper 的 `format-tag-value` 四原体归入 Tag，**204 → 208 定义**。原顶层执行顺序/显示尾、原 **59 ERT/helper/测试全文前缀**保持；三载体仅删定义/更新归属说明，Node View 全文只改一条 declare provider。根 `.el` **47 → 47**，保留公开符号，不据零根调用删除能力。
- **共享依赖边界**：Tag 头部仅新增三个无参颜色 getter 的窄 autoload/声明，共享颜色与主题算法仍在 helper，既有 Query provider 复用。真实 fresh 首次空/非空 formatter 后 helper/ViewAPI/Query 已加载，Sync/UI 未加载；纯读取分支只加载 Query。初始 Tag 仍无上述高层加载/DB 初始化，旧载体及 Tag reload 后四函数 owner 和预置 mode/配置保持。不把“没有顶层回边”说成首次调用没有加载成本，也不把共享 helper 认可为第六永久横切。
- **业务与红绿归属**：四项业务核真实目录、ID/canonical/alias 与 ID 优先、Query 过滤成员/输入守卫、完整颜色/face/分隔符属性。descriptor 选列桩、非法 alias 碰撞的合成 Store、混合成员投影明确分开，不冒称正常数据或 D6 raw selector 契约。前三次括号错误未执行 ERT；随后两条新空白输入预期与原行为不符，只改新断言，不作产品红。正式业务 before **63/63**；最终测试同字节的 owner before **67 = 63 通过 + 4 失败**，均 ENTRY 后命中旧 owner，未到达的后续冷分支不冒称写前已验证。独立冻结 before 另复现四业务绿/四 owner 红，不混写前时序。
- **最终门**：新增四业务和四 fresh ERT 后 tag-path **67/67**；worker、独立及 leader 定向各 **114/114**。完整 before 沿用字节一致 D7 **33 套 775 = 772 + 3 skip**，leader after 实跑 **33 Suite/Ran、783 = 780 + 3 可选跳过**，0 unexpected。五个受影响生产文件在完整 47 根源码临时副本编译 exit 0/0，**36 → 36** 条 `Warning:` 正文/数量一致，不称零警告。定向/编译为 deny-network 包装，完整门为隔离 HOME 的 native/local Git 夹具；guidance、全库存、diffcheck 通过，staged 空、根 elc 为零。
- **收口与后续**：独立审查无必修，六源码/测试路径及加入本计划的七路径累计冻结/正反回放见 leader 收据。常见标签维护路径已集中，但只读收尾仍列 Sync 的 `create-tag-entities/normalize-tag-id` 和后代/直接子标签适配待精确迁属裁定，不能因此宣称整个 Tag 归属已闭合。Node 索引/查询、共用 Org 解析、投影/legacy 政策、API 外部返回形状及通用颜色属于其它 owner；旧容器暂留不等于五横切目标完成。F1/F2 仍只记录，不扩补全产品或删除授权。
- **证据与限制**：leader `/private/tmp/supertag-tag-d8-leader-3fnl06o4/REPORT.md`；worker `/private/tmp/supertag-tag-d8-worker-vfzigegy/REPORT.md`；独立 `/private/tmp/supertag-d8-review.1GdLO0/REPORT.md`；归属收据 `/private/tmp/supertag-tag-close-receipt-5_ezo8_n/REPORT.md` 仅静态未跑门。真实颜色函数只在 frame background-mode 边界桩下验证，不称 GUI/主题版本矩阵；不外推私人配置/真实库/Runtime/模型、任意 advice 或崩溃原子性。D7 和旧冻结未动，未提交。

### V2-TAG-D9：实体确保与纯标签层级适配归入 Tag（2026-09-08，已验收）

- **合并成果**：Sync 的 `normalize-tag-id/create-tag-entities`、scan 的 `find-tag-descendants`、Query 的 `tag-children` 四原体归 Tag，**208 → 212 定义**。三个旧载体仅迁出定义/更新归属说明；Tag 仅删除已经同文件的 descendants 旧 autoload/declare，节点 membership 查询 provider 保留，无新加载层/require。原 208 定义、其余顶层顺序/显示尾与原 **67 ERT**逐字保持，根 `.el` **47 → 47**。
- **旧测试的唯一授权变化**：D4 cold helper 的 descendants `symbol-file` 期望仅从 scan 改 Tag；实际选择/plist、零事实修改、负向加载、reload 和 add 控制全部保持，未全字符串替换。before 业务及 owner 红阶段保留旧期望，after 才作此单点映射；最终测试与写前 red **不是全文相同**，两者只差这条已批准的 owner 字串。
- **行为与红绿**：真实实体确保保已有完整值、输入顺序/重复与无隐式父；后项非法时前项已创建仍保留，未加整批原子回撤。normalize 未知路径不建实体；descendants 与直接 children 的顺序、alias 和无实体父差异均按原行为固定，不统一模型。正式业务 before **70/70**，owner before **74 = 70 通过 + 4 失败**，各 child 在 ENTRY 后首个旧 owner 处失败；本片未发生新夹具预期修正。独立冻结 before 另复现三业务绿/四 owner 红，不冒称原主仓写前运行。
- **最终门**：新增三业务及四 fresh ERT 后 tag-path **74/74**；worker、独立、leader 定向各 **121/121**。完整 before 沿用字节一致 D8 **33 套 783 = 780 + 3 skip**，leader after 实跑 **33 Suite/Ran、790 = 787 + 3 可选跳过**，0 unexpected。四受影响生产文件在完整 47 根源码临时副本编译 exit 0/0，**49 → 49** 条 `Warning:` 正文/数量一致，不称零警告。Tag-only 四接口实际调用不加载 scan/Query/Sync；随后真实 Query/scan 仍返回原父节点/后代节点集合，不冒称节点查询也已迁 Tag。guidance、库存、diffcheck 通过，staged 空、根 elc 为零。
- **证据与限制**：五源码/测试路径及含本计划的六路径累计冻结/正反回放见 leader `/private/tmp/supertag-tag-d9-leader-7y21v48e/REPORT.md`；worker `/private/tmp/supertag-tag-d9-worker-ie0e0a9d/REPORT.md`；独立 `/private/tmp/supertag-d9-review.wkGhfg/REPORT.md`。定向/编译使用 deny-network 包装，完整门为隔离 HOME 的 native/local Git 夹具；没有新导入/导出生命周期或跨文件原子性验证，不外推 GUI/真实库/Runtime/模型、私人消费者/任意 advice 或版本矩阵。D8 及旧冻结不动，未提交。

### V2-TAG 主体合并批次收口（2026-09-08）

- **结构成果**：已确认的标签实体/路径、合并与恢复、输入/共享 CAPF 启停、成员写链、日常增删改/预览、普通/SVG 显示、写格式及读取适配集中到同一个 `supertag-tag.el`，技术分层改为内部节。新增该主文件，旧 `ops-tag/core-tag-path/ops-tag-merge/view-svg-tag/ui-completion` 五个专用承载删除，根源码 **51 → 47，净减 4**；不是通过删能力或另建 tag-core/tag-ui 达成。
- **关闭依据**：十二段实施/独立审查及最终全门承接历史证据；D9 补齐此前四个明确残留。worker 收据 `/private/tmp/supertag-tag-post-d9-receipt-y2s53h5h/REPORT.md` 与独立 `/private/tmp/supertag-tag-close-review.Wv764t/REPORT.md` 在已触达范围内未发现具体直接 Tag 业务漏迁；两份收尾判定仅静态定位，不冒称又跑了一遍全部行为。A 原始基线到 D9 的 **49 路径累计冻结**（含本计划）及精确正反回放记录在 D9 leader 收据；原始 before 字节须逐项匹配 A 库存，不按 HEAD 重建。最初 705 与最终 790 个默认测试是两时点证据，不作为项目完成率；编译仍按各段实际受影响文件比较，不拼成一次全仓零警告结论。
- **仍由其它 owner 承接**：Query 节点投影读取、Store 事务/索引、Sync/共享 Org 解析与投影/legacy 政策、Node 身份/创建/标准 Capture、Framework 颜色/控件和独立 API/Menu/Embark/Link 的契约不私有化到 Tag。相关旧容器仍须按后续批次整理，并非第六永久横切，也不是直接 Tag 业务漏迁。因此只关闭 **Tag 主体合并批次**，不关闭整个 v2、五横切终态或所有运行环境验收；旧分段“Tag 未关闭”保留其历史时点，由本条覆盖。
- **下一步**：依 §5 进入 V2-NODE 精确工单准备，不先做整仓底层搬家。F1/F2、无实体父语义统一、身份政策及旧产品缺口继续分轨，不借结构收口批准补全 UX 或新的删除政策。

### V2-NODE-A：节点实体与当前 buffer 导航归入 Node（2026-09-08，已验收）

- **归属**：新增最终特性主文件 `supertag-node.el`，集中校验、create/get/update/delete、当前位置导航与 set-location 七个原函数；四条 Tag membership autoload 随入，实际实现仍属 Tag。七函数、三项保留 Link 函数及四 autoload 原 form 逐字保持；relation 仅更新 getter 声明，contract 仅增加新测试文件，所有旧测试/Tag/共享 writer 与身份 provider 保持。
- **过渡边界**：`supertag-ops-node.el` 暂留 Link type/format/pattern 三个真实实现并依赖 Node，后续 Link 批次承接，不是空壳或永久横切。根 `.el` **47 → 48**，本段收益是节点实现唯一 owner，不宣称净减文件或整个 Node 已完成；Find/共享定位/Move/标准 Capture 仍待后片，继续入同一个 Node 主文件。
- **证据归属**：写前业务最终 **27/27**，旧 ops/Tag/Sync 三入口在 ENTRY 后精准 owner 红。初版把 updater 返回 nil 误作预期，实际返回 previous；只校准新增夹具。首次迁移脚本未改源码，`contract-after-first.log` 仍属 before，不能按文件名算 after。后加 cold 投影须预建实际 Semantic Tag 的校准及迁后新增 Node-only 例均未冒称写前业务证据。
- **验证**：worker、独立、leader 最终六套均 **230/230**；leader before 六套 **221/221**，完整 before 沿用字节一致 D9 **33/790 = 787 + 3 skip**。after 实跑 **33 Suite/Ran、799 = 796 + 3 可选 skip**，0 unexpected。两份旧生产文件/三份新生产文件分别在完整47/48根临时源码树编译，exit 0/0，**6 → 6** 条 Warning 正文/数量一致，不称全根编译或零警告。
- **实际保护与收据**：独立审查无必修；真 cold 验证加载图、原体 owner 与 reload不覆盖 Tag 实现；真实关系删除后故障验证节点/关系及可观察索引结果恢复（非未经 ensure 的原始缓存状态）；导航保护临时 Org/live/dirty/ID 事实，后续 node-sync-at-point 为实际投影而非 native save-hook 全链。guidance、库存/diffcheck、五源码测试路径及加计划的六路径累计正反通过，staged 空/根 elc0。详见 leader `/private/tmp/supertag-node-a-leader-odp2p1un/REPORT.md`、worker `/private/tmp/supertag-node-a-worker-tdfo0xua/REPORT.md`、独立 `/private/tmp/supertag-node-a-review.teqrR7/REPORT.md`。仅临时 Org/Store 与隔离测试；未验证真实库/GUI/版本矩阵、私人调用或崩溃原子性，F1/F2和 Tag 收口边界不变；未提交，旧冻结未动。

### V2-NODE-B：共享节点/文件定位编排归入 Node（2026-09-08，已验收）

- **归属与范围**：UI Commands 的 containing、ensure-node-synced、file-node-p、get-file-node、ensure-file-node-synced、find-node-marker 六原体归 Node，**7 → 13 定义**；七组普通 autoload/declare 连接原 scan/Sync provider，事务/identity/parser 不复制。Tag 仅两处 provider 的 autoload/declare 及注释改 owner，全部 **212 定义**保持；UI 其余职责/依赖保持，Link 仍消费 UI 的 reproject。根 **48 → 48**，不新建技术层。
- **加载与旧测试授权**：纯 getter/marker 不再为取得 Node 而预先加载 UI/Sync；真正同步时才执行原 provider。D5/D6 两个 cold helper 将“getter 前 Sync 已完成”改为“getter 真实 owner 是 Node、同步执行处验证 Sync”，包含 preflight 补齐的 D6 初始 autoload 检查。原 **9+74 ERT**、其它 helper/禁载/磁盘与 selector 合同保留，batch 的 Node 观察与 Sync 事件分表，测试没有提前调用谓词制造分支。Node 独载无 scan/Tag/Sync/UI，首次 file 查询可加载 scan→Tag，真实同步再加载 Sync；不称运行时完全无依赖。
- **before 与继承事实**：正式业务 before **109/109**（contract35+tag-path74），随后三入口 ENTRY 后 owner 红；后加精确 autoload/纯 getter/既有 file 短路断言仅属迁后证据。初稿误期待重复同步无外层 state 更新，原 quoted counters 保留先前正值；正式控制区分 processor 的 `(file hash)` 与外层 `(file)` 更新，原体未修。此处只记录继承事实，不将其定为未来产品要求。
- **实际验证**：worker、独立、leader 七套各 **289 = 288 + 1 可选 Runtime skip**；leader before **280 = 279 + 1 skip**，完整 before 沿用库存相同 Node-A **33/799 = 796 + 3 skip**。after 全套 **33 Suite/Ran、808 = 805 + 3 可选 skip**，0 unexpected；三受影响生产文件在完整48根临时源码树编译 exit 0/0，**28 → 28** 条 Warning 正文/数量一致。真实 saved S1/live S2、metadata marker/narrowing、原身份边界与重载函数对象控制通过；独立 cold 分支 control **1/1**，只去掉临时 in-scope autoload 后 **0/1** 精确在 ENTRY 后误走 fallback，不是 setup 红。
- **收据与后续**：独立审查无必修；guidance/diffcheck、完整范围外库存、五源码测试及加计划六路径正反通过，staged 空/root elc0。leader `/private/tmp/supertag-node-b-leader-v3q3d0ft/REPORT.md`；worker `/private/tmp/supertag-node-b-worker-anz2moc5/REPORT.md`；独立 `/private/tmp/supertag-node-b-review.FWMITv/REPORT.md`。仅隔离临时 Org/Store，完整门用 native/local Git 夹具，不外推真实库/GUI/版本矩阵/任意第三方或崩溃恢复；未提交，Node-A/Tag 旧冻结不动。Find/Move/标准 Capture 仍待后片，Node/v2/五横切未总闭，F1/F2未扩权。

### V2-NODE-C：Find 入口、预览/导航与候选缓存归入 Node（2026-09-08，已验收）

- **归属成果**：18 函数、1 预览宏和 2 缓存变量共 **21 原 form**归 Node，函数 **13 → 31**；旧 13 函数、原顶层顺序及两测试的 **18+20 ERT/helper**逐字保持。五普通 provider 用头部 autoload/declare，subr-x 真实加载；Menu 仅 Find 声明/wrapper、Discovery 仅恢复入口声明改 owner。UI 剩余 selector/NodeView builder/Move 等职责保留，根 **48 → 48**，不新建 Find/UI 技术层。
- **缓存与兼容边界**：两个 cache defvar 随 Node 更早绑定但不覆盖预置值，generic selectors 共享原 30 秒 TTL，Find 每次真实 Query 重建；reset/callback 同归 Node。原 guarded `register-listener` form 仍在 Services UI 原加载位置，Node-only 不注册；测试供应 listener 仅证明原位调用时机，不冒称当前已有 native Store 自动失效，也不换 subscribe。初始 Node 禁载与首次 Query/ViewAPI/模板/Org writer 的运行图分开，实际写入/身份/恢复继续复用共享 provider。
- **证据时序**：正式业务 before **23/23**；owner before **43 = 40 通过 + 3 ENTRY 后 owner 失败**。首次括号错误为 setup 失败，不算红；迁后 Menu 精确接线及后加四 cold 控制分别留证。Create cold 初稿误把尚无 Tag 实体的模板 token 当作已解析 membership，只校准新增断言为原 occurrence/unresolved/空 membership，不改生产或预建实体掩盖，属于 after-only 证据。原业务 before 测试仍是最终前缀。
- **实际门**：worker、独立、leader 八套各 **248/248**；leader before **238/238**，完整 before 沿用库存相同 NODE-B **33/808 = 805 + 3 skip**。after 实跑 **33 Suite/Ran、818 = 815 + 3 可选 skip**，0 unexpected；五受影响生产文件在完整 48 根临时树编译 exit 0/0，**22 → 23** 条 Warning。唯一多一次为原 `vertico-current-candidate` 可选函数告警：Find 迁 Node 后与留在 Services UI 的 generic selector 各报一次，原调用体未改、消息种类未增加；不称零警告或数量相同。独立真实 preview 后 error 控制 **1/1**，临时将恢复置空后 **0/1** 精确上下文红，非 setup。
- **收据与后续**：独立无必修；guidance、完整范围外库存、七源码测试及加计划八路径正反通过，staged 空/root elc0。leader `/private/tmp/supertag-node-c-leader-psjy_mmw/REPORT.md`；worker `/private/tmp/supertag-node-c-worker-qiwyb3sz/REPORT.md`；独立 `/private/tmp/supertag-node-c-review.9GVxzG/REPORT.md`。定向/编译 W/E 拒网隔离，full 为隔离 HOME 的 native/local Git；review 首次外层 sandbox 拒绝未运行测试，获准后的独立门才计数。真实临时 Org/Query/写入与模拟可选 UI 边界分开，不外推真实库/GUI/Runtime/第三方或崩溃原子性。Move/标准 Capture/通用 selector 仍待后片，Node/v2/五横切未总闭；F1/F2不扩权，旧冻结未动，未提交。

### V2-NODE-D：Move 命令与位置选择归入 Node（2026-09-08，已验收）

- **归属与边界**：Commands 七个 Move/region/源上下文函数、Services UI 两个位置选择函数共 **九原体**归 Node，函数 **31 → 40**。原 Node **34 定义**及顶层顺序、UI/Embark 原 **17+33 ERT/helper**保持；真实 Org-ID/Org-element 依赖和唯一普通 Move writer autoload/declare 在文件头。实际 writer/身份/保存/投影/retry/恢复 payload 仍属 service-org，Promote/Automation 共用入口不复制；Menu 无 Move 条目，Embark 生产 adapter/key 未改。根 **48 → 48**。
- **明确兼容变化**：原冷 Capture 未加载 Commands 时，两 Move 命令尚未定义，原 `fboundp` guard 跳过；迁后 Node 更早提供命令，已 opt-in 且配置 move-spec 的模板实际执行既有请求。保留原 Capture 体/guard/默认值，无 opt-in 或 nil move-spec 仍不 Move；这不是零加载语义变化。真实 org-capture/finalize 的 within-target/link/default 三分支及两个不移动控制，分别核 before 冷态、Commands 预载、after 冷态与预载。
- **证据时序**：warm 业务 before Move **56/56**、Embark **34+1skip**；Capture before **58/58**，owner before **60=58通过+2 ENTRY 后 owner失败**。最初 cold 括号错误仅 setup；新夹具误期待 bare Capture 的 ID 已落盘，按真实 before 校准为 disk 无 ID、live 有 ID/dirty、Store 已投影，不改生产或新定保存政策。迁后仅新增 cold 的 available nil→t 按授权映射，另两条 Node 首次真实 writer 控制是 after-only；旧 ERT 未改。
- **实际保护**：真 cold Node 禁载与首次普通 provider 执行分开，实际交互 Move→原 writer/identity/save/project，源/目标保存顺序、留链 stub ID、返回上下文均核。Node cold 的匹配 Org＋最小 Store 是显式定位输入，Embark 两 adapter 用真实重投影夹具；不将前者称 reindex。新增 payload 例用命名 service error seam 核对象身份透传，实际保存故障/回撤由继承 Move safety/position 控制承接。Capture save/project 数字是特定函数的透明观察，不等同所有 org-capture 底层写入；保留受影响文件已有草稿的原保存策略，不承诺跨文件原子性。
- **最终门**：worker、独立、leader 八套各 **347=346通过+1可选skip**，0 unexpected；leader before **337=336+1skip**，完整 before 沿用库存一致 NODE-C **33/818=815+3skip**。after 实跑 **33 Suite/Ran、828=825通过+3可选skip**、exit0；三受影响生产文件在完整48根临时源码树编译 exit0/0，**16 → 16** 条 Warning 正文/数量一致，不称全根编译或零警告。独审首次外层 sandbox 拒绝未运行测试，后续保留 W/E 的成功门才计数；独审未重复全33/编译。
- **收据与后续**：独立无必修；guidance、完整范围外库存、五源码测试及加计划六路径累计正反通过，staged 空/root elc0。leader `/private/tmp/supertag-node-d-leader-xo5hvvn_/REPORT.md`；worker `/private/tmp/supertag-node-d-worker-dryo09r9/REPORT.md`；独立 `/private/tmp/supertag-node-d-review.S1F9hf/REPORT.md`。定向/编译拒网隔离，full 是隔离 HOME 的 native/local Git；不外推真实库/GUI/Runtime/第三方/版本矩阵或崩溃恢复。仅关闭 NODE-D，标准 Capture 与通用 selector 等仍待后片；Node/v2/五横切未总闭，F1/F2未扩权，旧冻结未动，未提交。

### V2-NODE-E：标准 org-capture 集成归入 Node（2026-09-08，已验收）

- **归属与净变化**：四 Capture 函数、group、默认 nil 的 custom、原条件注册 tail 共 **七原 form**归 Node；原 **43 定义**及顶层相对顺序保持，函数 **40 → 44**。删除 `supertag-services-capture.el`，根 **48 → 47**，不留壳或恢复旧独立 Capture 引擎。main/Commands 仅删旧 require，Embark 再改对应依赖说明，生产 adapter/key 与共享 Tag/Sync/identity/Org writer/Move 恢复均不动。
- **加载与兼容**：内建 org-capture 在头部真实加载，三个 Tag 普通 autoload/declare 避开顶层回边；preset auto-enable=t 的注册前移到 Node 全部定义完成后的原 tail，默认 nil 与预置值保持。enable/disable/reload 不新增调和策略：nil reload 不主动移除手工残留 hook。初始业务 provider 禁载与首调用分开；首次 finalize 先 Sync→Tag，即便 property-only 也会加载 Tag，不称其必由 Tag 自身 autoload 触发。旧显式 require/load 路径兼容未知。
- **真实行为边界**：实际 Capture pending 中 disable 后正常 finalize 不再调用已摘 hook；显式保留的回调在有效 opt-in/活 marker 上仍能 finalize，但不重新 enable，disable 不是撤权。无效 marker 正式锁 error 类型与零事实变化，日志记录当前完整错误数据；不改为新的迟到 no-op。bare/property/legacy-field 保 live ID/属性与 Store 投影、零额外 save-buffer/原 disk；Tag/prompt 经真实原 writer 保存。新增例的 membership 非空与原测试的精确稳定 ID 断言分开，保存计数不冒称全部 org-capture 底层 IO。
- **测试与证据世代**：仅六处旧正向加载语句机械映射；identity 原 **25 定义（默认22项）**、Move UI25、Tag74及两历史测试正文/helper保持。新增七 ERT 只在 identity，after 文件32定义/默认29项。业务 before **28/28**，随后 **29=28通过+1 ENTRY后 owner失败**；初稿多余括号是 setup 错误。最终完整 before 输入仅旧 require 与七个新增 stage 参数 before→after 的授权映射，业务期待未改；两历史套只接线，不宣称旧业务已验。
- **最终门**：worker、独立、leader 七套各 **287=286通过+1可选skip**，0 unexpected；leader before **280=279+1skip**，完整 before 沿用库存一致的 NODE-D **33/828=825+3skip**。after 实跑 **33 Suite/Ran、835=832通过+3可选skip**、exit0。受影响编译目标 before5/after存活4，使用完整48/47根临时源码树，exit0/0；该过程 **36 → 36** 条 Warning 正文/数量一致，不称全根编译或零警告。leader额外两个 fresh preset nil/t 控制实测注册0/1次、注册时四函数已齐与旧载体history缺席；这是 after-only 补充，未计入正式ERT或独立门。
- **收据与后续**：独立无必修；guidance、完整范围外库存、十源码测试及加计划十一条路径正反通过，staged 空/root elc0。leader `/private/tmp/supertag-node-e-leader-oqlcjl2t/REPORT.md`；worker `/private/tmp/supertag-node-e-worker-foz15tv_/REPORT.md`；独立 `/private/tmp/supertag-node-e-independent-review/REPORT.md`。定向/编译 W/E 拒网隔离，完整门为隔离 HOME 的 native/local Git；不外推真实库/GUI/Runtime/任意第三方、版本矩阵或崩溃原子性。仅关闭 NODE-E，通用选择/引用创建/其它 Node 职责仍按后片收拢，Node/v2/五横切与F1/F2未扩权；旧冻结不动，未提交。

### V2-NODE-F：通用选择、引用创建与局部重投影归入 Node（2026-09-08，已验收）

- **归属成果**：Services UI 三函数与动态候选 defvar、Commands 的 reproject 函数共 **五原 form**归 Node；函数 **44 → 48**、定义 **49 → 54**。原 Node49定义/所有顶层相对顺序/Capture条件tail与两测试原 **23+25 ERT/helper/全文前缀**保持。旧carrier全文仅去相应原form，UI原位guarded监听不迁，无新require/provider/state或第三份缓存；根 **47 → 47**，不冒称载体已删除。
- **保留行为**：generic preview真实goto后error/quit仍保目标上下文、清自己的hook及恢复外层动态变量，不套Find总恢复；Ivy仅前端seam，具体窗口数/point为日志观察。multiple保unknown/顺序/真实Create与ordinary error后继续、quit传播，with-preview仍ignored。reference-create保live先Sync投影再save，实际保存前/后故障保不同部分状态；失败cache为日志观察，成功候选更新另有断言，不改成通用回撤/去重策略。reproject heading读live、file分支读saved title的区别、point/narrowing/disk保持。
- **证据世代**：生产未变时worker业务Find **29/29**、contract **49/49**，结构 **50=49通过+1 ENTRY后owner失败**。初始括号与错误property policy属新fixture失败，改成org-id并加强原saved-title/narrowing后才取正式before；重建输入显式标reconstructed。最终Find全文等正式before，Node-feature仅三个新增stage参数before→after，原测试不变。旧静态计数及leader附注曾误写node-feature23/compile16，GO前按native实际25/17校正，原日志未改；不算产品红。新增六Find/三Node例，after29/28定义，默认contract50。
- **最终门**：worker、独立、leader八套各 **339=338通过+1可选skip**；leader before **330=329+1skip**，完整before沿用库存一致NODE-E **33/835=832+3skip**。leader after实跑 **33 Suite/Ran、844=841通过+3可选skip**、0unexpected/exit0。三生产目标在完整47根临时树编译exit0/0，**17 → 16** 条Warning，唯一少一次既存Vertico可选函数告警；不是数量相同或零警告。新cold保初始禁载与真实首次Query/Sync创建分阶段，后续Node/UI reload唯一owner；before warm业务不冒称首provider冷测。
- **收据与后续**：独立无必修；guidance、范围外全库存、五源码测试及加计划六路径正反通过，staged空/root elc0。leader `/private/tmp/supertag-node-f-leader-i8oy5dop/REPORT.md`；worker `/private/tmp/supertag-node-f-worker-gdb8ptwr/REPORT.md`；独立 `/private/tmp/supertag-node-f-independent-review/REPORT.md`。定向/编译W/E拒网，full隔离HOME native/local Git；仅临时Org/Store/真实函数与明确输入/故障seam，不外推GUI/真实库/第三方、任意hook或崩溃恢复。只关闭NODE-F，四兼容helper仍仅下片候选；Node/v2/五横切和F1/F2未扩权，旧冻结不动，未提交。

### V2-NODE-G：四个兼容读取/创建入口归入 Node（2026-09-08，已验收）

- **归属与范围**：Commands 的 props reader、严格heading ID accessor、legacy heading creator、native title reader四非interactive原体归Node；函数 **48 → 52**、定义 **54 → 58**。原54定义/顶层相对顺序/Capture条件tail与node-feature原 **28 ERT/helper/全文前缀**保持。唯一新增普通Sync parser autoload/准确declare，真实Org/identity依赖复用；Commands全文仅去四raw，三个Sync命令与requires保持，根 **47 → 47**，不退整个carrier或新增技术层。
- **原策略与实际证据**：真实Org/默认extractor锁具体字段及native title与parsed title差异，priority=#A、deferred property表示按原Org识别，不做生产规范化。strict accessor仅heading写live ID，正文/前文拒绝、disk/Store/IDlocations原样。legacy create真ID→访问target→save→直接node-create/commit，原insert-pos、窄化、已有draft和部分状态保持；具体targetpoint/全trace部分是日志观察，不扩大断言。五命名save/commit前后故障均锁真实前序操作/错误与不同disk/live/Store结果，不统一F live-first或共享writer恢复。真实after-save控制只证enqueue（抑制timer），不是queue drain或任意user-hook覆盖。
- **冷链与before**：fresh Node初始禁载/普通parser autoload与首调Sync分开；ID-less也先加载Sync再nil，ID-bearing读可能初始化空Store collections，此前后值为cold日志观察，不称全程零内存写。warm初始化夹具另锁Store facts不变；reload保owner/cache/dynamic candidate/Capture配置。业务before **55/55**，结构 **56=55通过+1 ENTRY后owner失败**；首稿priority A误期望是新fixture失败，校准#A/deferred及加强title/token后才是正式before。最终输入仅两个新增stage before→after，原测试不改；新增六ERT后34定义、默认contract56。
- **最终门**：worker、独立、leader五套各 **220/220**，0unexpected；leader before **214/214**，完整before沿用库存一致NODE-F **33/844=841+3skip**。leader after实跑 **33 Suite/Ran、850=847通过+3可选skip**，exit0。两生产目标在完整47根临时树编译exit0/0，**16 → 16** 条Warning正文multiset一致，非零警告或全根编译。独审无必修，未代称重复全33/编译或新增mutation；guidance通过。
- **收据与后续**：完整范围外库存、三源码测试及加计划四路径正反通过，staged空/root elc0。leader `/private/tmp/supertag-node-g-leader-mvrkm6sg/REPORT.md`；worker `/private/tmp/supertag-node-g-worker-yb4dfgdx/REPORT.md`；独立 `/private/tmp/supertag-node-g-independent-review/REPORT.md`。窄收尾仍列parent-title读取与follow-id导航/Org整合归属待精确收拢/说明，尚不总闭Node；Query/View state/Sync/共享Org writer不据名称整体搬入。定向/compile W/E拒网，full隔离HOME native/local Git，非真实库/GUI/模型/任意extractor或崩溃原子承诺；F1/F2未扩，旧冻结未动，未提交。

### V2-NODE-H：父标题读取与按 ID 导航归入 Node（2026-09-08，已验收）

- **归属与保留**：parent-title/follow-id两非interactive原体归Node，函数 **52 → 54**、定义 **58 → 60**；原58定义/所有topform相对顺序/Capture条件tail与node-feature原 **34 ERT/helper/全文前缀**保持。仅新增准确`in-sync-scope-p (file)`普通autoload/declare，不是path-only谓词；ServiceOrg全文仅去两raw，Org-ID group/custom/advice/enable/disable/注册tail、requires与shared writer原样。根 **47 → 47**，Node-only不提前装advice或初始化policy。
- **原行为与风险**：真实父title/缺node-file-ID、point/narrowing/disk/Store、follow域内外/excluded/pattern及两层fallback通过；原Org入口是明确边界桩，advice通过真正ServiceOrg加载注册。parent在限制外/target在限制外均nil；**Child在窄化外时可误导航到Sibling**已在production-before观测，是共享locator待定向修复风险，不是H引入或批准的新产品行为，不推断未验证写链损毁。scope provider首调用真实执行、reveal/widen/错误传播/唯一advice与disabled reload保持，org-show-context原告警不顺改。
- **before与反证**：业务before **61/61**；结构 **62=61通过+1 ENTRY后owner失败**。首稿括号/窄化误期望/curved quoting与访问文件reread提示均新fixture历史，未改生产求绿；fixture2当时精确input缺失如实留记，不伪配后来文件。最终只有四个新增stage before→after。worker、独立各自control **1/1**、临时只删新增autoload后 **0/1**，真实域外返回t而Sync未加载，命中结果断言，不是autoloadp/setup假红。
- **最终门**：worker、独立、leader五套各 **226/226**；leader before **220/220**，完整before沿用库存一致G **33/850=847+3skip**。after实跑 **33 Suite/Ran、856=853通过+3可选skip**、0unexpected/exit0；两生产目标在完整47根临时树编译exit0/0，**18 → 18** 条Warning正文multiset一致，含原Org reveal/setf cl-find告警，不称全根编译/零警告。新增六ERT后40定义、默认contract62。独立未复跑full33/compile或历史before，实际域外mutation另有独立证据。
- **收据**：独立无必修；guidance、范围外完整库存、三源码测试及加计划四路径正反通过，staged空/root elc0。leader `/private/tmp/supertag-node-h-leader-cd8ttbzq/REPORT.md`；worker `/private/tmp/supertag-node-h-worker-q5avx5oj/REPORT.md`；独立 `/private/tmp/supertag-node-h-independent-review/REPORT.md`。W/E定向/编译拒网，full隔离HOME native/local Git；仅临时Org/Store/真实函数及明确seam，不外推GUI/真实库/Runtime/用户hooks/版本矩阵或崩溃原子性。旧冻结未动，未提交。

### V2-NODE 主体结构合并批次收口（A–H，2026-09-08）

- **关闭的是实现分布**：实体操作、共享节点/文件导航编排、Find/cache、Move用户流程、标准org-capture、generic选择/预览、兼容读取/创建、父标题与按ID导航集中到一个`supertag-node.el`，内部按职责分节。最后两项明确残留已承接，worker只读收据与独立窄归属复核均未见具体直接Node业务漏迁阻塞；不是只标owner，也没有另建node-core/move/capture层。
- **净变化与剩余承载**：本批新增Node，退标准Capture旧carrier，根 **47 → 48 → 47**；新增node-feature测试，完整库存 **619 → 620**。Commands的三Sync命令、ServicesUI的View state/通用适配/原位guarded listener、ViewAPI的Q读取/订阅、ServiceOrg的shared writer/identity/Org-ID生命周期与Concept流程、旧ops-node三Link格式体分别留各自owner；这些旧容器待后续相应特性整理，不据此重开Node或批准第六横切。guarded listener不是已证明native自动失效，shared locator窄化风险独立保留。
- **累计冻结**：以NODE-A真实before库存为锚，A–G已签收快照逐阶段衔接，首次涉及文件的原字节由已签成员提供并对A初始hash核准；缺席的新Node/测试也记录。A–H源码/测试21路径加本计划共 **22路径**累计diff，临时正向after22/22与逆向before22/22（含Capture删除恢复）通过；来源清单、hash与复跑脚本见本次leader的`node-batch-*`，不是相对Git HEAD或仅H增量。阶段门分别保留，最终完整门856/853+3skip不升级为真实库/GUI验收。
- **范围边界**：这不关闭整个v2/五横切，不等于所有旧文件可删或产品无缺陷。F1/F2仍只记录；已复现共享locator误导航另行定向处理，不以结构收口认可错误行为。未知第三方/私人闭包、完整版本/真实库/任意hook或跨文件原子性不保证。只读收尾来源 `/private/tmp/supertag-node-h-closeout-readonly-2ank4jk9/REPORT.md` 及其四carrier前收据；最终门/冻结/签收由leader承担。

### V2-QUERY-A：属性读取与组合查询归入 Query（2026-09-08，已验收）

- **归属与范围**：原 note-query 两函数、services-query 55函数共 **57 原体**收进 `supertag-query.el`，两个旧carrier真实删除，无兼容壳或新技术层。13个存活生产消费者只改加载元数据，Sync另补自有file getter普通provider；其余执行form/Node与Tag状态和tail逐字保持。根 **47 → 46**、完整库存 **620 → 619**；本片16生产、18原测试入口，加明确授权的归档反例脚本共 **35路径**，不搬Formula/scan/Org查询块主体。
- **加载与合同**：Query仅真实加载cl-lib/subr-x/Store，10个普通autoload/准确declare按需调用Node、Tag、scan、Relation及Formula；Sync明确声明并autoload原经Query间接带入的`find-nodes-by-file`。新Query独载不触发Tag/Node生命周期，首次provider可带入其原注册/索引成本；旧聚合Query原为重载，两代分别取证。保指定note-query快照隔离与其它旧API raw-return差异，不宣称全部查询深拷贝或取消原alias/字段/数值语义。旧feature显式加载与隐式依赖兼容变化如实披露，私人消费者未知。
- **测试授权与真实执行**：runner两条旧source load合一，默认33套与失败守卫不变。旧document独立cold改为隔离deps/HOME/source；D9仅query入口改为真实成员读取返回`("p")`后核Tag owner，其他入口时点与业务断言保持。17测试文件原 **342 ERT名称保留、after353**，其中19个旧form仅明确冷harness/owner/加载映射，新11例均在document-query-contract；非默认5文件只机械require，不称整文件业务通过。独立fresh非空关系、非count sum/avg及Sync真实parser/project/getter通过；worker与独立各自省略Sync新增autoload后命中真实`void-function`，不是metadata假红。
- **证据时序限制**：最初写前新夹具括号层级错误跳过了before业务分支，**72/72不能作为这些新增业务已执行的证明**。修正后冻结before **10/10**与after **11/11**是迁移后补测，未倒写成写前证据；原ENTRY owner红确实执行，另保纠正后的冻结owner红。bare sum0、真实and聚合及`__ungrouped__`按before事实校准新断言，未改生产。首轮contract73/73后，归档反例被旧Board的退役依赖先打断；第35路径授权改为runner副本外的真实最小archive源，ERT1/1通过后原守卫拒绝。双斜线fixture路径错误与修正、冻结before后补也分别留证，不计产品红。
- **最终门**：worker、独立、leader13套各 **351/351**、0unexpected；leader写前原门 **340/340**，完整before沿用库存一致H **33/856=853+3skip**。leader after实跑 **33 Suite/Ran、867=864通过+3可选skip**、exit0。受影响生产编译目标 **15 → 14**，在完整 **47 → 46** 根临时源码树编译exit0/0，**105 → 105** 条Warning正文multiset一致，不称全根编译或零警告。guidance与runner反例通过，独立未代称复跑full33/compile。
- **收据与剩余**：独立无必修；35源码测试及加本计划 **36路径**累计正逆回放通过，范围外库存不变、staged空/root elc0。leader `/private/tmp/supertag-query-a-leader-0yrp7pw0/REPORT.md`；worker `/private/tmp/supertag-query-a-worker-kz9d9afu/REPORT.md`；独立 `/private/tmp/supertag-query-a-independent-review/REPORT.md`。定向/编译W/E拒网，full隔离HOME native/local Git；不外推真实库/GUI/模型/第三方hook/版本矩阵。只关闭Query-A，Formula、scan适配、查询块与构建说明等仍待按特性收拢；不扩Sibling风险修复、F1/F2、五横切或整个v2，旧冻结未动，未提交。

### V2-QUERY-B：Formula 计算与 rollup 归入 Query（2026-09-08，已验收）

- **归属与净变化**：Formula 十个原函数归入 `supertag-query.el`，原 **57 → 67 函数**；其余顶层 form 与九组惰性 provider 的顺序/原体保持。删除 `supertag-services-formula.el`，不留壳或另建计算层；Automation 全文仅删重复 require。根 **46 → 45**、完整库存 **619 → 618**，无新增依赖、状态或生命周期。旧显式 require/load 路径不保兼容，私人消费者未知。
- **合同与测试映射**：保留 placeholder/prefix/infix、Store/实体/显式 resolver 三来源、原数值与空值规则、rollup 函数对象和错误返回差异；Automation 经同一 Query 计算入口，原 evaluator 错误捕获与 lookup 错误传播边界不改。旧 **19+8 ERT**逐字保留：property-consumers 只删旧 require，QA cold helper 唯一 owner 判断按历史 before/当前 after 分代，旧禁载和业务断言不削弱；QA 历史 before 不是 QB before。新增四个 Query ERT 与一个 Automation ERT，两个文件 **23+9 ERT**，runner/manifest/归档不改。
- **before 与反证**：初稿 Automation fixture 把字符串传给 plist API，**3/4** 属夹具失败，不算产品红；修正新增 fixture 后，生产三文件仍与 before 一致，真实业务 **4/4** 在迁移前通过。临时副本只改 Store 结果期待 **3 → 999**，精确业务断言红用于证明分支实际执行；独立 owner **0/1** 在真实 Query ENTRY 后失败，不是 setup。迁后业务4/4＋owner1/1；独审复跑冻结 before4/4、错期待与 owner 红，是审查时复证，不倒写成原写前执行。
- **实际门与边界**：worker、独立、leader 八套各 **147/147**、0unexpected；leader 原 before **142/142**，完整 before 沿用字节一致 Query-A **33/867=864+3skip**。leader after 实跑 **33 Suite/Ran、872=869通过+3可选skip**、exit0；生产编译目标 **3 → 2**，在完整 **46 → 45** 根临时源码树编译 exit0/0，**35 → 35** 条 Warning 正文 multiset 一致，不称全根编译或零警告。fresh Query 实际计算、加载图、reload、独立事实/文本/dirty保护通过；Automation 是真实 Org/投影的 warm 消费者控制，不冒称冷 Automation、库重载或完整 scheduler 生命周期。
- **收据与剩余**：独审无必修/新增建议；guidance、五源码测试及加本计划 **六路径**累计正逆回放通过，范围外库存不变、staged空/root elc0。leader `/private/tmp/supertag-query-b-leader-mfwtaq9b/REPORT.md`；worker `/private/tmp/supertag-query-b-worker-frzwhzjo/REPORT.md`；独立 `/private/tmp/supertag-query-b-independent-review/REPORT.md`。定向/编译W/E拒网，full隔离HOME native/local Git；不外推真实库/GUI/模型/第三方/任意hook或版本矩阵。只关闭 Query-B，scan适配、Org查询块与构建说明仍待按特性整理；不扩Sibling修复、F1/F2、五横切或整个v2，旧冻结不动，未提交。

### V2-QUERY-C：scan 投影读取适配归入 Query（2026-09-08，已验收）

- **归属与范围**：scan 六原函数归 Query，原 **67 → 73 函数**；删除 `supertag-core-scan.el`，无壳或新技术层。原三组本地化 provider 退场，新增四组普通 Tag/index autoload/准确声明，其余六组与全部非metadata form保持；不搬索引派生状态或eager Node/Tag/index依赖。Sync/Node/Tag准确getter接线、ServiceOrg同位require、ViewAPI/Automation templates去重复依赖；根 **45 → 44**、库存 **618 → 617**。旧显式scan加载路径退役，私人消费者未知。
- **授权时序与测试映射**：main原scan位置换轻Query并删后方重复require，原ops-node/Tag位置与init函数体不动。真实中途事件显示before scan完成时Node/Tag已载，after Query完成时二者未载，之后原ops-node→Node与Tag再加载；不是整个main零hook或零副作用。QA仅scan/file owner分历史before/当前after，整个QB helper/stage不动；NODE-B实际filegetter后不再承担scan→Tag加载成本；D9 scan入口与两个轻载/membership时点一起映射，真实membership后才Tag owners，reload仅去scan。原 **137现役＋42历史ERT**原体保留，两历史文件只机械require，不声称历史业务全绿；七新增QC例只在document，原23→30，runner/manifest不改。
- **真实合同**：本地literal/空词/大小写、严格开区间日期/nil边界、精确file与file-node类型差异/首个命中、返回cdr `eq` Store原对象均保留，不套detached reader合同。Tag ID/alias/后代与token读取真实调用，Store事实与派生索引失效/重建分开；普通ID样本不外推alias冲突政策。Node冷filelookup实际解析Query且不加载Tag/Sync；Tag输入先候选、再实际filter，不能拿加载当调用。Sync实际依赖已先载Query，after getter在调用前已是真定义，透明观察锁processor/投影/getter结果，**未制造省略autoload反证**。Org文本/dirty/disk与普通buffer文本、配置边界分别断言，不外推任意hook。
- **before与最终门**：worker真正写前业务 **6/6**，九生产cmp一致；临时只改ALPHA期待 `(a b)→(wrong)` 命中结果断言，ENTRY后owner独立 **0/1**，迁后 **6+1** 全绿。本片新fixture首版已通过，不套QA/QB历史失败；独审重放before6/6和两红为审查时复证。worker、独立、leader八套各 **295/295**，leader原before **288/288**；完整before继承签名QB **33/872=869+3skip**。leader after实跑 **33 Suite/Ran、879=876通过+3可选skip**、0unexpected/exit0；编译目标 **9 → 8**，完整 **45 → 44** 根临时树，exit0/0、**93 → 93** 条Warning正文multiset一致。leader首次编译命令漏 `-L` 导致依赖查找setup失败，修正命令后才取93基线，旧日志保留，不计产品红或零警告。
- **收据与剩余**：独审无必修/新增建议；guidance、14源码测试及加计划 **15路径**累计正逆通过，范围外库存不变，staged空/root elc0。leader `/private/tmp/supertag-query-c-leader-ye69bssy/REPORT.md`；worker `/private/tmp/supertag-query-c-worker-82zjfuq9/REPORT.md`；独立 `/private/tmp/supertag-query-c-independent-review/REPORT.md`。定向/编译W/E拒网，full隔离HOME native/local Git；不外推真实库/GUI/模型/第三方/版本矩阵。只关闭Query-C，Org查询块/构建说明与剩余读取归属待后片精确核定，不总闭Query/v2/五横切；F1/F2与Sibling风险不扩权，旧冻结未动、未提交。

### V2-QUERY-D：Org 查询块、展示与交互构建归入 Query（2026-09-08，已验收）

- **归属与净变化**：31函数＋2常量＋1注册共 **34原form**从 query-block 收进 Query；原 **73 → 104函数**，全部旧原体/执行form相对顺序保持，两枚autoload cookie与原注册位置保留。旧carrier真实删除，Babel语言和dispatch仍叫`supertag-query-block`；main删旧require、menu三入口改owner，两测试仅机械加载映射。根 **44 → 43**、库存 **617 → 616**；七源码/测试路径，不新增技术层或改DSL/writer。
- **加载变化与明确兼容损失**：Query新增真实顶层Org/org-table，三普通provider按需调用Link格式与Tag输入；原alist整cons去重及Org/Babel注册因此提前。**尚未加载Org且预置精确`(supertag-query-block . t)`时，缺失`ob-supertag-query-block`的失败由原来的“Query可用、随后block失败”提前为首次Query加载失败，feature/API均nil。** 这是补充授权并实测的可用性损失，不称等价、修复或长期认可的产品行为。精确失败有独立LOAD-ATTEMPT/EXPECTED-LOAD-FAILURE；另一个真正Org-first进程验证精确配置/reload正控，不能互相替代。
- **合同与红绿来源**：旧 **30＋6＋9=45 ERT/helper**与完整QA/B/C前缀不动，document新增11例（含一例精确失败观察，不是11种配置功能均正常）。实际Babel/dblock输出、重复更新、排序/非count/错误边界、menu Copy/Insert/Run/syntax与main中途注册实跑；显式测试保存前disk/Store/IDs不变，随后真实Sync只保手工引用、排除生成引用。初稿数值/顺序/menu夹具错误及最初 **9=8＋1** inherited失败保留；修订写前正控 **9/9**、精确失败观察 **1/1**、真实wrong-output活性红及ENTRY owner **0/1**分列。独审重放是后补复证；不把setup/replay脚本错误或失败观察绿称产品修复。
- **最终门与声明修订**：原稳定字节worker、独立、leader八套各 **308/308**；leader原before **297/297**，完整before继承签名QUERY-C **33/879=876＋3skip**。首轮leader full **33/890=887＋3skip**，编译 **38 → 39**，新增main的store-origin未声明告警；随后仅加无初值`defvar`，Persistence真实初始化/全部函数与测试原样。最终声明后leader重新实跑 **308/308**及 **33 Suite/Ran、890=887通过＋3可选skip**、0unexpected/exit0；受影响编译目标 **4 → 3**、完整 **44 → 43** 根临时树、exit0/0，Warning正文multiset **38 → 38**。这不是全根编译或零警告；独立最终仅声明/七路径冻结复核，未冒称重跑原308或full/compiler。
- **收据与边界**：guidance、范围外库存、七源码测试及加计划 **八路径**累计正逆回放通过，staged空/root elc0。leader `/private/tmp/supertag-query-d-leader-l0_pib0u/REPORT.md`；原worker `/private/tmp/supertag-query-d-worker-_68yk0ca/REPORT.md`、声明修订 `/private/tmp/supertag-query-d-declaration-lc68lswe/REPORT.md`；独审 `/private/tmp/supertag-query-d-independent-review/REPORT.md`。定向/编译W/E拒网，full隔离HOME native/local Git；真实临时Org与明确seam不外推私人preset、GUI、任意hook、真实库/模型或版本矩阵。只闭QUERY-D，剩余读取归属仍须窄收尾，不总闭Query/v2/五横切；F1/F2/Sibling未扩，旧冻结不动、未提交。

### V2-QUERY-E：数据集与实体读取适配归入 Query（2026-09-08，已验收）

- **原体与边界**：ViewAPI的list-entity-ids/get-entity/get-entities/node-field-in-tag四原体归Query，函数 **104 → 108**，原两常量/Org注册/全部既存topform顺序保持。仅新增准确`relation-get (id)`普通autoload/declare；Node仅改get-entity两处provider字符串，原60定义/生命周期不变。ViewAPI八require、provide及剩余plist-field/subscribe原体保留，不借搬读接口清空载体。五路径、根 **43 → 43**、库存 **616 → 616**；无新层、writer或状态。
- **真实读取与加载**：保原list/get单复数验证差异、automation按name排序与按id读取、relation嵌入ID、raw对象别名、batch次序/重复/nil/missing与属性键/空值/忽略tag-id规则，不套全量深复制或Tag成员合同。属性例是真Org保存投影后制造未保存草稿，再核读前后disk/live/dirty/Store/IDs；其它样本明确是Store seed。Relation首调与Node/Tag分别fresh，实际getter/结果/成本留证；worker及独立省略唯一autoload后均在非空读取处`void-function`，不是metadata/setup红。ViewNode:444为链接行读取渲染，非source edit。
- **旧测试与证据时序**：document旧 **41 ERT/全文前缀**及QA/B/C/D保持，新增7后48；Node旧 **40 ERT**原体保持，helper只两处各一次授权替换：精确provider→Query，实际node/menu Existing导航后核Query owner/nonautoload与ViewAPI feature/history缺席，其余禁载/点位/disk/source原断言不削弱。旧D跨文件45不再误称document数量。初稿节点次序、child显示路径与0ERT转义selector错误均留作夹具历史；正式写前新业务 **6/6**、原Node冷链 **3/3**、真实输出活性红和ENTRY owner红成立，迁后三生产body不为夹具改义；独审复跑属于后补复证。
- **最终门**：worker、独立、leader八套各 **205/205**、0unexpected；leader原before **198/198**，完整before继承签名D **33/890=887＋3skip**。after实跑 **33 Suite/Ran、897=894通过＋3可选skip**、exit0；三个生产目标在完整43根临时树编译exit0/0，Warning正文multiset **31 → 31**，含未使用tag-id及已有提示，不称全根编译/零警告。guidance、五源码测试及加本计划 **六路径**累计正逆通过，范围外库存不变、staged空/root elc0。
- **收据与限制**：leader `/private/tmp/supertag-query-e-leader-2b_bhtxp/REPORT.md`；worker `/private/tmp/supertag-query-e-worker-pqd1p3qb/REPORT.md`；独立 `/private/tmp/supertag-query-e-independent-review/REPORT.md`。定向/编译W/E拒网、full隔离HOME native/local Git；并非GUI、真实用户库、任意hook/第三方或版本矩阵。D的noOrg/exact-t首次Query失败及API损失仍未修，安全QE冷启动不是该配置正控；F1/F2/Sibling未扩权，旧冻结未动、未提交。

### V2-QUERY 主体结构合并批次收口（A–E，2026-09-08）

- **关闭的是特性实现分布**：属性/实体读取、DSL验证与执行、Formula/rollup、文本/日期/文件scan、Org查询块/真实dispatch、构建/语法说明与通用读取适配集中在一个`supertag-query.el`内部节。最后四项明确读取残留已承接；常见修改从表达式到结果/消费者适配可在Query主文件内追踪，没有另建query-core/query-ui。窄收尾未见新的具体直接Query业务漏迁，不以仅改owner或文件数量代替完成。
- **净变化与保留owner**：退note-query、services-query、Formula、scan、query-block五旧carrier，新增Query，根 **47 → 46 → 45 → 44 → 43 → 43**、完整库存 **620 → 616**。ServicesUI仍有Node View状态/文本与输入适配及原位guarded监听；ViewAPI保plist工具/订阅，外部API保独立参数/输出桥接；Tag/Node/Relation、Store索引、Sync投影和共享Org writer各留真实责任。旧技术容器待各自后续特性切口整理，不据零caller删能力或认定五横切目标已达成。
- **累计冻结**：从QUERY-A实际before库存锚定，已签A–D逐阶段衔接至E；每路径首次触达原字节核初始hash与签名成员。采用各阶段**最终manifest**，纳入A后加授权的`test/development-entrypoints-test.sh`，不误用最初34路径表漏项。源码/测试 **42路径＋计划=43路径**累计diff，临时正向after43/43、逆向before43/43全部字节/缺席通过；存在数 **42 → 38**，含新Query与五旧carrier删除恢复，非仅E增量或Git HEAD。`query-batch-*`保来源、签名/链、脚本与回放；阶段门各自保留，最终897不冒称全产品验收。
- **产品与验证仍有边界**：结构收口不等于查询行为无缺陷。D已明确的noOrg/exact-t缺ob loader导致更早Query失败/API不可用继续独立处理，不被本收口认可为期望政策；未知私人旧require、任意Org hook/版本/真实库/GUI及F1/F2/Sibling问题不在本次修复授权内。只关闭Query主体结构，不关闭整个v2/五横切。窄收尾来源 `/private/tmp/supertag-query-closeout-readonly-kojfs71t/REPORT.md`，最终门、累计冻结与签收由leader承担。

### V2-LINK-A：先解除 Link 的重加载依赖（2026-09-08，已验收）

- **前置切口，不冒称迁属完成**：Link四条ServiceOrg/Sync/Commands/helper eager require改为15个准确普通autoload/declare，保九个真实require及Org/CL宏依赖；goto声明准确归Node并移头部。session只有无初值前向声明，初始化仍Sync。原63函数中 **61逐字不变**，仅Add Link和source-save retry两处加显式autoload解析；其余配置/状态/error/执行顺序原样。两路径、根 **43 → 43**、签名库存 **616 → 616**；formatter三体与ops-node载体、Promote和共享writer尚未迁，不关闭Link/Concept。
- **两条真实入口**：Add Link在源验证成功后、目标resolve/create和session读取前解析Sync；原payload retry在首次session读取及find-file/save前解析。未调用validate/refresh业务来“顺便初始化”，热函数/advice不覆盖。真实cold public materialize可在保存前失败而尚未加载Sync，故retry不能借Add Link的前提；两处各有独立遗漏反证：Add命中真实resolve前顺序断言，retry命中原payload路径的`void-variable`，不混称两者都是直接变量错误。此为去除eager依赖所需前提，不将原代码宣称已有该故障。
- **测试与历史归属**：原 **44顶层ERT/65,728字节全文前缀**不动，新增六例后50；先前45文本声明包含一个嵌套ERT。新child不预绑定关键session，父仅创建/投影临时Org再传Store快照；ordinary/named/new/cancel、真实保存/投影、原payload、pending advice、helper/card/导航与preset分别留证。首次quit捕获/命名ref-to、次次drawer被误当无owner均是新夹具校准，正式写前业务 **5/5**、ENTRY加载边界红与真实输出活性红成立，不作既有产品修复；named取消可已加载Sync，不统一取消零加载。独审原稳定八套310、before5、after6、两遗漏及额外真实热retry1/1分别记录。
- **S1单符号测试纠偏**：新冷断言误用`supertag-global-completion-mode`，随后仅改为真实`global-supertag-ui-completion-mode`；生产及其它测试字节不动，原202成员冻结保留，新76成员累计原before另冻。worker修后50/50+guidance，独立最终boundary **1/1**及canonical变量置t的合成断言反证；后者没有真正启用mode，非GUI/生命周期证明。原独立310/热retry不冒称修后重跑。
- **最终门与编译**：leader before **304/304**，完整before继承签名Query-E **33/897=894＋3skip**；初稳定leader **310/310、33/903=900＋3skip**，S1最终字节再次实跑 **310/310、33 Suite/Ran、903=900通过＋3可选skip**，0unexpected/exit0。一个受影响Link目标在完整43根临时源树编译，before **10 → 初after7 → 最终7 Warning**：Node六条旧when-let及Link原unused choose-target保留，原随加载出现的Tag三条when-let不再出现；Tag源码未改，不说修了Tag告警或零警告/全根编译。wrapper cookie提示另列。
- **收据与边界**：guidance、范围外库存、两代码测试及加计划 **三路径**累计正逆通过，staged空/root elc0。leader `/private/tmp/supertag-link-a-leader-43o06y0p/REPORT.md`；原worker `/private/tmp/supertag-link-a-worker-396lejrp/REPORT.md`、S1 `/private/tmp/supertag-link-a-s1-worker-icrxaxa4/REPORT.md`；独审 `/private/tmp/supertag-link-a-independent-EZdmxE/REPORT.md`、S1 `/private/tmp/supertag-link-a-s1-review-7YMI81/REPORT.md`。定向/编译W/E拒网、full隔离HOME native/local Git，不外推真实用户库/GUI/任意hook/fset/版本矩阵或跨文件崩溃原子性。首次格式化的迁属仍下片；D3首#仍会调用Link，依赖成本下降不等于F1/F2已解决；Canonical、Sibling、QD exact-t/API损失均不扩权，旧冻结未动、未提交。

### V2-LINK-B：物理链接格式归入 Link，退役 ops-node（2026-09-08，已验收）

- **归属与范围**：`node-link-type`、`node-format-link`、`node-link-pattern` 三原体按原序归入 `supertag-link.el`，原63函数及LINK-A两Sync前置/15provider/状态完整保留，现66函数；旧`supertag-ops-node.el`真实删除，无壳或新层。20生产、19测试共 **39路径**，根 **43→42**、签名库存 **616→615**。其它生产仅精确require/declare/头部归属；Node/Tag/Sync仍在原位置加载Node，Query普通formatter provider转Link，Relation仅纠正声明及实际optional参数。
- **加载与兼容**：Query首载不带Node/Link/Tag/Sync/UI；真实非空首行才加载Link/Node及既有Org/模板成本，不能称仍是小formatter文件的加载成本。Node/Tag/Sync独载没有新增eager Link；main Query先于Node、随后原Sync/Link位置不变。旧feature/file显式加载退役，公开formatter原名/原返回保留；**11个已知archive旧引用明确暂缓**，九个非默认测试仅机械require，不称零残留、历史全可用或私人第三方兼容。
- **精确测试映射**：S1最终add-link全文仅一个require例外，原50ERT保留、追加五例后55；denote-reference、identity、node-feature三文件显式导入Link，仅作用warm入口。Node首阶段保持禁载，原晚formatter阶段才load Link；Tag旧wrapper重执行仅require Node，保function cells/mode与真实会员/投影。QC真实after-load事件改Node、QD非空Run-now后formatter owner改Link；独立`SUPERTAG_LB_STAGE`区分本片before，未冒用旧QC/QD-before或改变负向断言。identity当前32定义/default29、Node40/document48/Tag74旧例与runner分类保持。
- **真实证据分代**：worker首次新夹具缺括号导致load失败，修正仅新append后，生产20文件cmp0时业务 **4/4**、原冷控制 **7/7**；成功Link ENTRY后旧owner红、真实返回错误期待红均有效。after新五例和旧映射控制均绿；省Query唯一autoload、保declare及真实Link后，执行到非空首行才`void-function`，不是metadata抢先红。独审复跑before4/7属迁后冻结重放；其首次缺document-fixture是setup失败，补同一fixture后7/7，不混成产品红。格式值/regexp与真实dirty Org、Store/ID零写控制和原writer回归分开，不升级为任意hook/跨文件原子保证。
- **最终门与编译**：leader before12套 **432/432**，worker/独立/leader最终同12套均 **437/437**；完整before继承同库存已签LINK-A **33/903=900+3skip**，leader after实跑 **33 Suite/Ran、908=905通过+3可选skip**，0unexpected/exit0。相同19个存活受影响目标，在完整43→42根临时源码树编译均exit0，**118→118 Warning，消息正文多重集合相同**；不是全部根文件目标编译或零警告。guidance/runner反例、staged空/root elc0通过。
- **收据与边界**：三原体、旧63及全部存活定义/状态、19测试精确映射由实际raw与整文件重建核实；代码39路径及加本计划 **40路径**累计正逆bytes/absence均通过。leader `/private/tmp/supertag-link-b-leader-1u3msdes/REPORT.md`；worker `/private/tmp/supertag-link-b-worker-1gzmvcif/REPORT.md`（337成员）；独审 `/private/tmp/supertag-link-b-independent-JwbWJ0/REPORT.md`。定向/编译W/E拒网、full隔离HOME native/local Git；root回放模板最初沿用Link-A来源标签仅工具元数据，纠正后相同输入重新回放，非产品红。仅关闭本片；Promote/关系边界、共享writer、F1/F2、Sibling及QD exact-t首次Query/API损失不扩权，Link/Concept/v2/五横切仍未总闭。旧冻结未动、未提交。

### V2-CONCEPT-A：Promote 续做与原 payload 编排归入 Concept（2026-09-08，已验收）

- **归属与范围**：Link 三个专属 failure/retry/continue 原体及六对 ServiceOrg 普通 provider 声明归入 Concept；Link **66→63**、Concept **20→23函数＋原1宏**，其余状态、执行顺序、公开 Promote cookie、Link 两处 Sync 前置与九个共享 provider 不变。四路径；根 **42→42**、签名库存 **615→615**。目标/候选专属管线仍在 ServiceOrg 待后片，共享 materializer/save/project/retry 不搬，不总闭 Concept/Link。
- **明确的加载面变化**：仅加载 Link 不再定义三续做函数或安装六个专属 provider，不留壳/反向 require。原符号在 Concept、公开 Promote 和同会话首 payload 协议保留；未知私人 Link-only 调用需加载 Concept，不承诺持久化/跨会话 payload 兼容。Concept 原重依赖仍实际加载 ServiceOrg/Sync/UI，本片不是把它变为轻模块。
- **保护与真实证据**：原 Promote **38 ERT**及整个文件前缀保留，新增六例后44；AddLink **55 ERT**整个文件仅 LA 一处表达式按独立 `SUPERTAG_CA_STAGE` 区分历史 before15/current9，S1/LB和旧负向守卫不变。fresh/reuse 公共 Promote 在目标真实落盘/投影后注入源保存失败，原首 payload 重试/重复保持ID、单链接、子节点与入链事实。真实保存后 hook 加草稿被 guard 拒绝；移除 hook 不足恢复，明确移除新增草稿后原 payload 才完成。六真实 provider cell 跨 reload 保留，其中**一项**加透明 advice 并实际计数，不说六项都加过 advice。
- **时序与最终门**：新夹具曾有 advice 词法绑定、ID抽屉空白期待失败，均留证且不算产品红；生产cmp0时最终业务 **6/6**、成功 ENTRY 后owner红及实际retry完成后错期待红有效，迁后7/7。独审冻结before6及两红属于迁后复证。leader before八套 **336/336**，worker/独审/leader最终各 **342/342**；完整before继承同库存已签LINK-B **33/908=905＋3skip**，leader after实跑 **33 Suite/Ran、914=911通过＋3可选skip**、0unexpected/exit0。两生产目标在完整42根临时树编译exit0/0，**10→10 Warning 正文multiset一致**，wrapper cookie提示另列，不称全根编译或零警告。
- **收据与边界**：独审无必修/新增建议；guidance、四代码测试及加计划**五路径**累计正逆bytes/presence通过，范围外库存不变、staged空/root elc0。leader `/private/tmp/supertag-concept-a-leader-e_488byf/REPORT.md`；worker `/private/tmp/supertag-concept-a-worker-_xc7s9k3/REPORT.md`（157成员）；独审 `/private/tmp/supertag-concept-a-independent-vqrCiS/REPORT.md`。定向/编译W/E拒网，full隔离HOME native/local Git；无GUI/真实库/模型/任意hook/跨文件崩溃原子保证。F1/F2、Sibling、QD exact-t/API损失及整个v2/五横切无扩权，旧冻结未动、未提交。

### V2-CONCEPT-B：专属候选、目标与守卫管线归入 Concept（2026-09-08，已验收）

- **归属与范围**：ServiceOrg 中14个原函数及原 supertag-promote-error 定义按原序归 Concept；ServiceOrg **60→46**、Concept **23→37函数＋原宏**。六个已本地化provider对删除，新增 **9个共享Org＋2个Sync普通provider** 的准确头部接线，不迁共享writer/宏或新增状态。原23函数、共享错误、Org-ID生命周期/执行尾部及Link/LA两前置保持；三路径、根 **42→42**、库存 **615→615**。
- **明确兼容变化**：ServiceOrg-only不再定义14专属函数或注册该error；加载Concept后同名函数/原消息和error层级可用，无反向require/壳。未知私人ServiceOrg-only调用需加载Concept，不承诺跨会话/持久化payload。Concept原重闭包仍加载ServiceOrg/Sync，不称11provider都经过冷autoload或首载成本下降。
- **测试与reload合同**：原 **44 ERT**经三处精确映射后作为完整前缀保留，追加四例后48，Link/AddLink55完全不动。CA两组六provider owner由独立CB-before或历史CA-before分代；require-only全六cell EQ保留，显式reload的before原EQ仍锁。当前本地defun重定义实测六EQ=nil，原native advice仍在；真实已存target/source guard在reload前后各 **1次**、原结果一致，不通过重装advice或缓存函数伪造EQ。
- **真实写链与红绿归属**：嵌套retained/child实际公共Promote，目标已落盘后注入旧位置save失败，首实际payload/state/operation重试完成并重复不写；原层级/标签/属性、子节点/源投影、入链/父正文和marker清理均保留。9共享Org＋2Sync透明调用从公共链成功返回后计数，Git未启只证notify wrapper；已有真实热provider不制造省略autoload红。本片正式写前业务 **8/8一次通过**，2生产cmp0、ENTRY owner红与真实retry返回后错期待红有效；迁后9/9。根规划mapped探针、其初稿括号错误、CA历史fixture与独审迁后before复证均不冒称本片原时间产品红。
- **最终门与收据**：leader before九套 **404/404**，worker/独立/leader最终各 **408/408**；完整before继承同库存已签CA **33/914=911＋3skip**，leader after实跑 **33 Suite/Ran、918=915通过＋3可选skip**、0unexpected/exit0。两个受影响目标在完整42根临时树编译exit0/0，**10→10 Warning正文multiset一致**（九条既有when-let、一次既有setf cl-find提示），wrapper cookie另列，非全根目标编译或零警告。guidance、三代码测试＋计划**四路径**累计正逆通过，staged空/root elc0。leader /private/tmp/supertag-concept-b-leader-n020ebf0/REPORT.md；worker /private/tmp/supertag-concept-b-worker-ehh6gxe2/REPORT.md（144成员）；独审 /private/tmp/supertag-concept-b-independent-rlbA1F/REPORT.md。定向/编译W/E拒网、full隔离HOME native/local Git；无真实库/GUI/任意hook/跨文件崩溃原子保证，旧冻结未动、未提交。

### V2-CONCEPT / Promote 主体结构合并批次收口（A–B，2026-09-08）

- **关闭的是专属实现分布**：概念规则/别名/识别显示与mode、Promote选择预览、候选/目标专属编辑、durable/source守卫、阶段retry和首payload续做都在 supertag-concept.el 内部节。A/B共收17原函数＋专属error，原Concept **20→37函数**；Link三体与ServiceOrg14体原承载已退出，常见维护不再横跨三个技术/特性文件。没有为减少文件数删除共享能力；根和完整库存仍 **42/615**。
- **保留真实其它owner**：Mention的通用候选/卡片/ignore、Link通用引用/materializer/recovery、共享Org定位/保存投影/Move、Sync解析和Node/View职责仍原位。模板默认Concept目标与共享规范化/创建被Node/Link/Concept共用，旧services-template待后续共享Org切口，不是批准第六横切。Concept原重加载成本、两个旧单feature加载面变化及任意私人调用仍有边界；结构收口不宣称产品零缺陷或任意热升级兼容。
- **累计证据与未决**：从A实际before **615库存**锚定，签名A302成员及当前B稳定worker144成员、A-final→B-before整库存链与每路径首次触达原hash复核；B首次触达的ServiceOrg使用A已签source-before，不误当不存在的新文件。源码/测试**五路径＋计划=六路径**累计diff，临时正向after6/6、逆向before6/6字节/存在性全部通过；不是仅B增量/HEAD。concept-batch-*保来源/脚本/签名链/回放，最终记录与本片门由leader负责。窄收尾 /private/tmp/supertag-concept-closeout-readonly-3wxdtfkt/REPORT.md 未见具体专属漏迁；只关闭Concept/Promote主体，Link关系边界、整个v2/五横切及F1/F2、Sibling、Canonical、QD exact-t/API损失不随此扩权。

### V2-LINK-C：Relation 实体与索引适配归入 Link（2026-09-08，已验收）

- **归属与范围**：旧 ops-relation 的26函数＋2个defvar＋1个defcustom共 **29原form** 整块归 Link，原63函数逐体保持，Link **63→89**；旧carrier真实删除，无壳或新层。Node1/Tag2/Sync7普通provider、Query4对owner重定向，main和七适配器退eager依赖；Link头部真实加载Org/事务/索引/sha1，Canonical局部抑制、原状态/错误/去重/事务和writer不改。ServicesUI仅额外落实原S1重复Query依赖注释清理。最终 **33路径＝14生产＋19测试**，根 **42→41**，签名库存 **615→614**，范围外不变。
- **兼容与旧保护**：仅加载Node/Tag/Sync不再顺带全部Relation API/状态，实际普通关系调用才加载Link现有Query/Node/template/Org闭包；不补无消费者CRUD provider，也不保证未知私人旧feature调用兼容。AddLink原 **55 ERT**及完整映射前缀保留，追加15后70；Node40、document48、storage10的原ERT保持，仅精确helper/加载表达式例外。QA/QD/QE独立LC分代，旧负向/历史before保留；storage仅Sync先证Link未载/七autoload，再真实非空投影后核原九CRUD，main原时点不动。十二非默认测试仅机械require，十一archive文件暂缓，不改变runner分类。
- **写前与增补时序**：原新夹具曾误用namespace映射类型及词法抑制绑定，校准后生产14cmp0时业务 **14/14**、mapped contract **102/102**，成功ENTRY后owner红与真实关系输出后错期待红成立。迁后新15/15、AddLink70通过，但原contract **99/102** 三例在Node冷helper造关系夹具时缺少project函数；这是直接测试消费者加载缺口，不是Node删除产品红。addendum1精确增加第33路径，仅在原冷态禁载/实体控制后、关系fixture前require Link；原回滚/索引/后续Tag与Sync禁载不动。该fixture从此明确warm，真实首次Node关系删除由新LC直接Store-seed另证。修订测试对冻结before/current各 **4/4** 为迁后复证，不冒称写前；原32阻塞态的 **887份文件**完整保留，最终另冻33路径。
- **真实行为与反证边界**：非空Relation CRUD/返回对象/错误状态、去重和历史tag清理、Tag两重键helper、实际Store/commit单通知与外层抑制恢复均锁原行为；helper证据不冒称公共文件原子回滚。省Node/Query provider在真实执行处void-function；Sync单处named省略仍被Query注册mask而绿，双供应者省略才得到真实候选缺失输出红，不伪称void-function。worker另有Tag、投影与Query-from命名读反证；独审复跑before/current各7、Node/Query及Sync单/双省略，来源分列。LA两Sync前置/S1/LB与CA-CB、原payload/writer保护不变。QD无Org exact-t四入口前后均在真实load阶段缺ob-loader，feature/API不可用；Org-first是另一正控，未观察本矩阵新事务窗口，不修或批准该继承问题。
- **最终门与冻结**：leader before十五套 **475/475**，worker/独审/leader最终各 **490/490**；full before继承同库存已签CB361的 **33/918＝915＋3skip**，leader after实跑 **33 Suite/Ran、933＝930通过＋3可选skip**，0unexpected/exit0。完整42/41根临时树中受影响 **14→13目标**编译exit0/0，**105→105 Warning正文multiset完全一致**，wrapper cookie另列，非全根目标编译/零警告。guidance、33代码测试及加计划 **34路径**累计正逆bytes/presence通过，staged空/root elc0；reader实际3830个前后顶层form及整文件授权重建通过。leader /private/tmp/supertag-link-c-leader-fkddbhjz/REPORT.md；最终worker /private/tmp/supertag-link-c-final-worker-xwx8_f08/REPORT.md（421签名成员）；独审 /private/tmp/supertag-link-c-independent-kSQHkx/REPORT.md。full隔离HOME native/local Git与定向/编译W/E拒网分列，旧冻结未动、未提交。
- **只闭本片**：Sync关系词汇/候选/会话接受及专属协议注册仍是§4明确暂留的 **11函数＋5配置状态**；不是LC漏做，也不等于已天然归五横切。只读收尾 /private/tmp/supertag-link-closeout-readonly-xas5mb7x/REPORT.md 列出后续精确切口；结束暂留须另立加载/单state/LA session及解析首用工单，当前仅准备、非GO。Sync投影、共享Org/Node/View/API/Mention保各自实际职责；Link主体/v2/五横切及F1/F2、Sibling、QD/Canonical其它政策、GUI/真实库/第三方或崩溃原子性均不扩权。

### V2-LINK-D：词汇、会话与 Org 协议注册归 Link（2026-09-08，已验收）

- **范围与保留**：Sync 的11函数＋5配置/state共16原form收进 Link，15逐字保持；follow仅去旧UI require分支，真实Node依赖与goto调用保留。Link原89函数保持，现100；四旧Sync provider与裸session声明退出，Sync仅新增refresh/type predicate两普通provider。注册不在load时运行，单一owned hash/session、原两LA前置与shared writer/payload不改。最终四路径，41根/614库存均不变。
- **加载和协议合同**：Link-only现在绑定默认nil session并提供真实词汇函数；Sync-only不再顺带提供candidates等全部API，首个真实refresh才解析Link。四个fresh空/plain-id header/nodes控制证明首次解析成本，即使没有命名链接也会加载Link。真实Org注册/打开目标、冲突全预检、只撤本人注册、第三方覆盖、preset/reload与accept失败session恢复通过；不升级为任意Org API部分失败的原子性。LA resolve实际Sync=nil，原advice计数/EQ及保存失败原payload重试保留，不冒称当前四provider仍是pending。
- **测试与来源**：旧AddLink70 ERT精确映射后追加11；Promote48只获准一个session表达式LD分代，其余禁载/CA历史/真实Concept闭包保留。正式写前业务10/10、mapped26/26及ENTRY owner/真实parser输出活性红成立。最初新registry断言误以为Org不新增原生协议、迁后两个新warm fixture缺导入，均仅校准新夹具。首次十套406=405＋1是范围外Promote旧观察遗漏；addendum1单式修订，root冻结原before/mapped-before/current各1/1属于迁后复证，旧638文件不改。refresh省略在实际首parse处void-function；type单省略被refresh载入mask而绿，加载后能力删除才红，两类证据不混。
- **QD边界**：无Org exact-t在before/current都于真实load阶段缺ob-loader，未到ENTRY，Link/Query/API/Store均nil；Sync现有Org/Query前置使预言的新parse-time失败窗口在该矩阵不可达。Org-first正控另证真实解析；这不修复或批准QD问题。辅助QD初稿混load-path被排除，校正后观察明确是迁后材料。
- **最终门**：worker、独审、leader十套各406/406；完整before继承同库存LC602的33/933=930＋3skip，leader after实跑 **33 Suite/Ran、944=941通过＋3可选skip**，0unexpected/exit0。两个目标在完整41根临时树编译exit0/0，**32→32 Warning正文multiset一致**，非全根目标编译或零警告。guidance、原体992个前后topform重核、四代码测试及加计划五路径累计正逆通过；staged空/root elc0。leader `/private/tmp/supertag-link-d-leader-5rn7orm7/REPORT.md`；最终worker `/private/tmp/supertag-link-d-final-worker-3mznu7q7/REPORT.md`（165成员）；独审 `/private/tmp/supertag-link-d-independent-4zIMVGva/REPORT.md`。定向/编译W/E拒网与full隔离HOME native/local Git分列，未读真实库/配置、未提交。

### V2-LINK 主体结构合并批次收口（A–D，2026-09-08）

- **关闭实现碎片**：普通/命名格式与pattern、CAPF/候选/动作、物理材料化和原payload恢复、Relation实体/索引适配、词汇/session/owned协议生命周期集中于 `supertag-link.el`。共收40函数，Promote专属三体由已闭Concept-A迁出，Link由初始63到100函数；旧ops-node与ops-relation真实退役，无新层或兼容壳。此前唯一明确暂留11＋5已消除，窄收据 `/private/tmp/supertag-link-final-closeout-readonly-r5pjrb2o/REPORT.md` 未见新的具名直接业务漏迁。
- **共享边界仍在**：Sync保Org元素提取、生成块排除、解析/投影/同步计数；Node/ServiceOrg保身份导航集成与共享writer；Concept、Mention、Query、View/API/Menu及Tag共享CAPF启停各保原owner。旧容器仍需后续各自整理，不为清空它们重开Link，也不宣称五横切/v2完成。首用加载成本、旧单feature可用面变化和第三方未知保留；F1/F2、Sibling、Canonical、QD及GUI/真实库/崩溃原子性无扩权。
- **累计冻结**：从LINK-A初始616库存/43根锚定，实核A/B与穿插的Concept-A/B、LC共五阶段2112签名成员，逐阶段整库存链及49路径首触达原hash相接；不是把Concept变更冒充本片实施。累计 **48代码测试＋计划=49路径**，临时正向after47存在/两缺席、逆向before49/49字节/存在性通过，根43→41、库存616→614。`link-batch-*`保来源、diff与回放；该完成范围仅Link主体结构。

### V2-AUTOMATION-A：事件适配归入 Automation（2026-09-08，已验收）

- **范围与保留**：旧 automation-sync 的25函数＋1group＋4defvar，共30原form，逐字并入 `supertag-automation.el`；原57函数/68定义及执行顺序保留，现82函数。迁入节位于shared special和原init/cleanup定义之后、唯一load-init调用之前，原engine reset仍在调用之后。删除旧carrier无壳，main仅删旧require；没有新增provider、第二queue/state或修改writer。八路径＝3生产＋5测试，完整库存 **614→613**、根 **41→40**。
- **加载与真实行为**：旧adapter-only的轻载可用面随feature退役；完整Automation会执行原index rebuild/订阅/init，私人旧require/闭包未知。真实cold首init一次、require-only不重init、显式reload再次init但只保一个订阅；preset adapter状态保留，engine enabled仍被原init设t。main真实完成顺序仍为Sync→Automation→Scheduler。真实Org保存→投影→Store事件→property-changed条件→动作再保存，锁两次save、disk/Store值和动态current-event恢复；Tag增删/禁用、严格异步阈值、同ID递归释放及两个reset职责均保留。共享timer/queue的handler.args与thunk两协议分别验原FIFO/错误行为，不声称混格式互通或cleanup等于reset。
- **测试及来源**：五处require精确映射，原 **9＋5＋48＋14＋7＝83 ERT**与原helpers/前缀保留；仅property-consumers追加7，历史retired-field不默认化。权威写前 `business-before-authorized` **6/6**、成功ENTRY后旧carrier断言红、真实两次写入后的错期待红成立；早期括号、Org空白及require观察夹具错误排除。名为mapped的旧日志并非映射输入执行，最终测试与保存的正式before输入逐字一致。独审冻结before6/6属于迁后复证。worker另在临时树编译Automation，新进程真实elc动态条件/写入 **1/1**；独审只重跑该签名elc，未重新编译，均不冒称旧独立adapter冷编译等价。
- **最终门与冻结**：leader before八套 **266/266**；worker、独审、leader after各 **273/273**。full before沿用同库存已签Link-D的33/944＝941＋3skip；leader after实跑 **33 Suite/Ran、951＝948通过＋3可选skip**，0unexpected/exit0。受影响 **3→2目标**在完整41/40根临时树编译exit0/0，**60→38 Warning正文、无新增**；减少9条重复obsolete及13条跨文件绑定/前向引用诊断，不宣称零警告、全根目标编译或生产体修复。guidance、原生reader前后合计732顶层form、八代码测试及加计划 **九路径**累计正逆bytes/presence通过；staged空/root elc0。leader `/private/tmp/supertag-automation-first-leader-4gi6us6g/REPORT.md`，worker `/private/tmp/supertag-automation-a-worker-4b_od1s8/REPORT.md`（506签名成员），独审 `/private/tmp/supertag-aua-independent-FDBRM9zE/REPORT.md`。定向/编译W/E拒网与full隔离HOME native/local Git分列，旧冻结未动、未提交。
- **仅关闭本片**：Scheduler和Automation模板仍待各自精确合并。Scheduler提前fboundp注册、预载非空Store与main稍后load的差别、旧field模板兼容须后片明确；没有新增注册补偿或修订调度策略。本片复用原Vault13，不声称新增完整双库业务实验；整个Automation、v2/五横切以及F1/F2、Sibling、Canonical、QD、GUI/真实库/第三方与崩溃原子性均不随此验收。

### V2-AUTOMATION-B：Scheduler 归入 Automation（2026-09-08，已验收）

- **范围与保留**：11函数＋1defcustom＋3defvar，共15原form，逐字并入 `supertag-automation.el`，位于原init/cleanup与事件适配定义之后、唯一load-init之前；原engine reset仍在init之后。原82函数/98定义、原执行顺序和共享writer不改，现93函数；仅新增真实json/persistence头部依赖。旧Scheduler源/feature退役无壳，main仅删require。六路径＝3生产＋3测试，库存 **613→612**、根 **40→39**；未知私人旧require/持久闭包不保证兼容。
- **明确接受的加载变化**：Scheduler定义更早存在，预载非空Store时原load-init会真实注册任务，standalone规则CRUD的原fboundp分支也更早成立。任务表仍为同一容器，但匹配ID的任务值/last-run可被原register覆盖；require-only不重init，显式reload仍原样重建，已存在timer不新建。不添加第二调度层或注册补偿。**main先加载Automation、后从磁盘加载Store的路径仍可能有规则/index而tasks为空**；实际观察 `(index index load start)`，本片保留而非修复此缺口。
- **真实控制与授权映射**：原property16＋vault13＋tag74＝**103 ERT**及helpers/前缀按精确授权保留；AUA三观察独立区分A历史before与AUB-before，Vault两require及D3一require改真实owner，没有泛化削弱禁载。新增property5、vault1：真实tick/CRUD、JSON与daily/interval边界、start/stop/reset及IO错误部分状态；真实持久规则A→B→A→B经原activate恢复，无返回后手动补注册，记录persist→stop→reset→load→register→start与实际输出。保存guard拒切保active库/timer；不把旧Vault手动补偿例说成自动恢复证据。
- **红绿与时序**：worker权威写前property **20/20**、vault **14/14**；ENTRY后旧owner红、真实tick输出后错期待红，以及省略load-init注册/activate注册两真实分支红成立。独审的before20＋14是迁后冻结重放，不冒称原时间。早期缺Sync guard夹具与自定义同进程组合污染失败保留并排除；默认runner分进程控制不改。三历史Scheduler加载入口明确暂缓，不声称旧名全库零残留或历史套件已绿。
- **最终门与leader纠偏**：leader写前八套 **325/325**；worker、独审及leader最终各 **331/331**。full before沿用同库存已签A的33/951＝948＋3skip；leader新独立目录顺序实跑 **33 Suite/Ran、957＝954通过＋3可选skip**，0unexpected/exit0，含native本地Git28/28。正式受影响 **3→2目标**在完整40/39根临时树编译，exit0/0，**39→39 Warning正文多重集合完全一致**；修后两目标elc实际存在并签hash，不称零警告或全根编译。此前leader重复启动并复用after日志、compile-after输入未完备的执行均不作为最终证据；其中后来W包装Git失败不混称native失败，不据此归因生产迁属。旧日志原样留存。
- **冻结与边界**：guidance通过，leader按完整JSON逐字重建生产/测试映射，worker688、A328及原工单59签名成员复核；六源码测试＋本计划 **七路径**累计正逆bytes/presence通过，staged空/root elc0。最终leader `/private/tmp/supertag-aub-leader-recovery-fbyhh3oq/REPORT.md`；worker `/private/tmp/supertag-automation-b-worker-btlfwz8a/REPORT.md`；独审 `/private/tmp/supertag-aub-independent-Yswo2cE7/REPORT.md`。定向/编译W拒网与full隔离HOME native/local Git分列，合成/临时Org证据不外推GUI、真实用户库、任意hook或崩溃原子性。仅关闭Scheduler片；Templates下一片仍须精确工单和独立GO，Automation主体、v2/五横切、F1/F2、Sibling、Canonical、QD及调度政策不随此关闭。

### V2-AUTOMATION-C：模板归入 Automation／主体结构收口（2026-09-08，已验收）

- **范围与保留**：Templates的14函数＋catalog常量，共15原form，含原注释/cookie逐字归 `supertag-automation.el`，位于Scheduler定义之后、唯一load-init之前；原93函数/113定义与原执行顺序保持，现107函数/128定义。仅增加真实subr-x头部依赖并更新Commands，Menu两声明/两wrapper feature精确接线，旧Templates carrier退役无壳。四路径＝3生产＋1测试，库存 **612→611**、根 **39→38**。原10ERT及helper/macro前缀只删一处冗余旧require；AUA/AUB代际和其它cold负向不改。
- **真实行为及接受的可用面变化**：catalog9和两个命令更早随完整Automation首载可用；原init仍一次，require-only保持对象/订阅，显式reload在before不重建独立Templates常量、current则重建catalog/build闭包，均执行原init且订阅仍一份。旧Templates→ServicesUI附带加载边消失，不等于Automation轻载或无副作用，私人旧feature/closure-EQ未知。真实Menu列表/实例化、Tag reader、pp预览、确认/取消及重名改名/替换保原实现；真实Tag事件属性保存、followup创建投影、持久命名daily callback经Scheduler/index到Org writer三链通过，不以手写输出或writer桩代执行。
- **旧field边界不修**：两模板都可真实create并保存/重读，保原trigger/actions；条件与事件不因此获得支持。实际property/tag事件无旧field写或移动目标，独立field条件为nil，property正例成立；直接unsupported `:update-field`返回并显示 **字符串** `Unknown action type: :update-field`，不是nil/error。现役move-node没有退役，也未绕过条件证明模板可用。独审 **S1非阻塞**：正式独立trigger负控用`:type`而engine读`:path`，其本身只覆盖unknown事件，不能单独证明合法property不匹配；后续真实事件/条件覆盖仍在。独审临时改为合法path并加入同事件property正控 **1/1**；本片稳定测试不改，该增强仅留建议、不冒正式ERT。
- **红绿与时序**：worker正式写前业务 **5/5**，成功ENTRY后旧owner红、真实writers打印AUTHOR=Ada/REVIEW=done/followup=1后错期待红成立；迁后新6/6。v1缺目标文件/Store guard/quit，v2虚构Query名/canonical顺序，v3返回形状，v4时钟表示等新夹具失败原样保留，v5才权威绿；不充迁属红。独审before5/5与两红是迁后复证。worker旧BSD patch/漏group计数是工具失败；leader和独审均独立git apply正逆四路径，未依赖其自定义逆向器作唯一证据。
- **最终门与本片冻结**：before定向/full沿用同代码库存已签B的 **331** 与 **33/957＝954＋3skip**；worker、独审、leader最终各 **337/337**。leader full实跑 **33 Suite/Ran、963＝960通过＋3可选skip**、0unexpected/exit0，含native本地Git28/28。完整39/38根临时树的受影响 **3→2目标**正式编译exit0/0，**40→40 Warning正文多重集合一致**，不称全根编译或零警告；两elc真实存在。guidance、完整JSON原体/前缀/范围核验、本片四代码测试＋计划 **五路径**正逆通过，staged空/root elc0。leader `/private/tmp/supertag-automation-c-leader-oeqetv59/REPORT.md`；worker `/private/tmp/supertag-automation-c-worker-rfc4amoi/REPORT.md`（279签名）；独审 `/private/tmp/supertag-auc-independent-pzWOmeO5/REPORT.md`。
- **Automation主体结构收据**：原adapter、Scheduler、Templates职责均已归同一特性文件；只读收据 `/private/tmp/supertag-automation-closeout-readonly-i9huu3zz/REPORT.md` 在定向范围未发现具名直接业务漏迁。main/Vault编排，Store/Sync/Org/Query/Tag/Node共享机制与Menu分派保各owner，不为清空旧容器扩范围。累计从A初始 **614库存/41根** 锚定，A328与B128旧签名、C279及原工单56逐项核验，A→B→C整库存/计划链和 **15路径首触达hash** 相接；累计 **14源码测试＋计划＝15路径** 临时正向after12存在/3删除、逆向before15字节/存在性一致，最终 **611库存/38根**，范围外不变。
- **只闭结构，不批产品等价**：A的双queue协议，B的提前真实注册/同ID last-run覆盖及main晚load仍未自动补注册，C的旧field/reload变化、旧单feature和私人持久闭包兼容风险均继续留记。三历史Scheduler入口暂缓，不宣称全仓旧名归零；F1/F2、Sibling、Canonical、QD、调度修复、GUI/真实用户库/任意hook与崩溃原子性未扩权。Automation主体结构已闭不等于整个v2或五横切目标达成。

### V2-VIEWS-A：Node View 状态构建归位（2026-09-08，已验收）

- **精确范围**：`supertag-view-build-node-state(node-id)` 单个原defun从ServicesUI逐字归入现有NodeView，置`--build-view-state`前；Commands仅一declare owner改NodeView，ServicesUI仅头部/归属段变化。原NodeView39函数、状态/模式/执行form与全部require保持；ServicesUI其它两函数及原位guarded Node cache listener不改。四路径＝3生产＋1测试，库存 **611→611**、根 **38→38**；不为减少文件数吞并其它owner或新增层。
- **可用面与真实控制**：ServicesUI-only原来可调用builder、现在须显式加载NodeView，无反向require/autoload兼容壳；NodeView本来就有的Query/Node/Tag/Sync等加载成本和窗口hook保留。真实首次ServicesUI/NodeView分别在fresh子进程观察，cold前无Sync/document-fixture，之后加载fixture的业务阶段独立。原register-listener实际缺席；临时安装函数再reload只证明 **条件可用性seam**，不是现有native订阅API。require-only对象/hook保持；显式旧ServicesUI reload在before重定义builder、current不夺owner。
- **业务/测试保留**：原4ERT/helper/整个文件前缀逐字不动，新添4。真实临时Org/Tag/投影的三属性含空值、普通双向refs及named双向关系，builder ordinary ref-count=2不混named；无业务磁盘/live/Store写。只证明Query已detach的node/property隔离，不升级任意tags/ref字符串深复制契约。实际NodeView打开/保存→队列→订阅刷新、property键选择、重复open单订阅及kill释放/原点hook清理通过，原ZETA删除→ALPHA等控制保留；point201/window-start1只是本夹具观察，不承诺任意滚动/像素稳定。
- **证据时序**：worker新业务写前 **3/3**，成功VWA-owner-ENTRY后旧owner红，真实非空state/窗口保存刷新输出后改ref-count期待的活性红；after4/4。初版缺先创建Tag实体致tags=nil属于新夹具校准，不当产品红。独审before3/3、owner红及2对991输出红为迁后复证；父ERT原前缀已载fixture不冒child冷态，父子features隔离。所有原体及完整JSON/前缀由leader/独审核实。
- **最终门与冻结**：leader before五套 **302/302**；worker、独审、leader after各 **306/306**。full before沿用同代码库存已签Automation-C33/963＝960＋3skip；leader实跑 **33 Suite/Ran、967＝964通过＋3可选skip**，0unexpected/exit0，native本地Git28/28。完整38/38根临时树受影响 **3→3目标**编译exit0/0，**16→16 Warning正文多重集合一致**，不称全根目标编译或零警告。guidance与四代码测试＋计划 **五路径**累计正逆bytes/presence通过，staged空/root elc0。leader `/private/tmp/supertag-views-a-leader-h4hon16r/REPORT.md`；worker `/private/tmp/supertag-views-a-worker-j5li_2gc/REPORT.md`；独审 `/private/tmp/supertag-vwa-independent-CuYJY9Ea/REPORT.md`。W/E拒网定向/编译与隔离HOME native full分列。
- **继续VIEWS，不作主体关闭**：下片候选为ViewAPI两原函数归Framework并退旧carrier，公共绘制与投影位置适配另按owner处理；旧ServicesUI剩余算法/listener仍有明确暂留，不据零caller删除。下一片须精确接线和独立GO；不扩五横切/v2/F1F2/Sibling/QD、真实用户库/GUI/任意私人入口兼容或定位政策。

### V2-VIEWS-B：公共读取/订阅归 Framework，退 ViewAPI（2026-09-08，已验收）

- **范围与保留**：两原defun `supertag-view-api-node-base-field` / `supertag-view-api-subscribe` 逐字归Framework，旧ViewAPI真实删除、无壳。Framework新增真实notify依赖，保ServicesUI依赖与原38函数/registry/config/widget执行顺序；helper用真实Node→Query及subr-x承接原附带能力，不反向require Framework。ServicesUI、NodeView、Stream仅精确退旧require/元数据，NodeView A builder及原位条件listener不动。十路径＝6生产＋4测试，库存 **611→610**、根 **38→37**。旧151ERT及helper仅授权literal映射，Framework新添7例。
- **兼容/行为**：旧API-only加载及两符号可用面退役，须显式Framework；首次加载成本由原API提升到Framework/UI/Node/Tag/Query/Sync既有闭包，不称纯读取零副作用。Tag三颜色、Link三helper provider仍原owner。真实plist-get保持nil/missing/列表引用；notify实发keyword/path给两closure、LIFO及参数/真实unsubscribe保持；真实NodeView/Stream订阅随Store变化渲染并kill释放。两次Framework显式reload保持已有配置/注册/活订阅；require-only EQ与显式reload观察分列。临时register-listener只是条件seam，不称现役native API。helper真实位置读取/Org-link字符串与empty Link渲染不是点击导航/物理writer或GUI证据。
- **精准分代与阻塞**：QE历史与独立VWB-before/current分开；D4/D7/D8只指定reload/owner改动，早期Query/Tag禁载守卫保持。首轮漏列D2旧API reload，真实D2首次读取已成功，后reload file-missing属scope gap，非业务首读回归。addendum只给D2列表一处分代：before原四项/current删API、不替换Framework；十owner及全部冷负向不变。累计9规则10literal匹配。两历史 `test/tag-path-test.el` / `test/perf-benchmark.el` 旧API入口明确暂缓，不改分类、不声称零残留或私人入口兼容。
- **证据时序**：worker写前最终mapped九套 **342/342**，ENTRY后owner红及真实notify输出后错期待红；首次after仅 **338＝337通过＋1失败**，后三套未跑，不冒全绿。新7例通过。修后D2 original-before/mapped-before/current各1/1是迁后独立复证；旧292签名成员未动，最终216成员另冻。最初括号/注册/属性key假设属夹具校准，不是产品红。独审九套342/342、迁后before7/7、owner/notify红及D2 mapped-before1/1另列来源。
- **最终门与冻结**：worker、独审、leader最终九套各 **342/342**；leader full **33 Suite/Ran、974＝971通过＋3可选skip**，0unexpected/exit0；before full继承同代码基线已签A967，非B新跑。完整38→37源码临时树，受影响6→5目标真实编译exit0/0，**16→16 Warning正文多重集合相同**、实际6/5 elc，不称全根目标/零告警。W/E拒网定向/编译与隔离HOME native全套Git分环境。guidance、十代码测试路径正逆通过；加本计划十一累计路径在文档核对前完成正逆。root elc0/staged空。leader `/private/tmp/supertag-views-b-leader-ppz7zs4z/REPORT.md`；final worker `/private/tmp/supertag-views-b-addendum-worker-2g__wiet/REPORT.md`；独审 `/private/tmp/supertag-vwb-independent-6K30PNhZ/REPORT.md`。
- **仅闭B**：公共绘制37函数＋2常量候选归Framework，helper投影位置适配随后归Node再退carrier；不能把定位塞Framework或创建反向兼容shim。后片须承接B最终字节及新七例；尚非GO。VIEWS主体、五横切/v2/F1F2/Sibling/QD/真实用户库/GUI/任意第三方均未关闭或扩权。

### V2-VIEWS-C：公共绘制完整归 Framework（2026-09-08，已验收）

- **精确归属**：37原函数＋2常量逐字从helper归Framework，0迁入cookie，Framework原40函数/状态/registry/订阅/21widget注册顺序保持，现77函数；新增真实头部Org依赖。Tag3/Link3普通provider共6pair、5唯一symbol仅owner改Framework；NodeView删helper require保Framework，AI/semantic/mention原位置替换真实依赖及头部。helper只保原Node投影定位adapter和全部B依赖、无Framework反向shim。11路径＝8生产＋3测试，库存 **610→610**、根 **37→37**，不为删carrier吞定位职责。
- **测试与代际**：原Tag74＋AddLink81＋Framework30＝185顶层ERT及其它原文仅7精确映射；Framework新添8。VWC-before独立于LA/CA/LD/VWB等历史；B D2/addendum及QE无需改动、所有早期负向保留。B helper例只在首次颜色冷成本断言完成后才显式加载定位fixture，不能预热或据此声称Framework供应定位。helper-only绘制可用性退役，原定位可用；未知私人require/advice/reload不保证兼容。
- **真实控制与限制**：实际button-activate传原data/help/keymap，格式/face/text-property、非空header/card/footer；真实overlay范围/priority/category和重复清理，原enable no-op不补hook。真实side-window选择/point与恢复按原体，window-start仅日志观察，不外推滚动像素合同。真实两临时Org/ID目标：RET与mouse绑定调用原闭包→org-link-open-from-string→原文，不是原生鼠标事件/GUI验证。Tag颜色和Link卡片首用Framework更重加载成本实测，AI/Semantic/Mention渲染用明确输入/图片seam、不称模型网络。require-only EQ、显式helper reload不夺owner，原Framework配置/注册/订阅reload控制保留；图形环境桩不替换全部绘制。
- **红绿归属**：worker同一最终测试输入写前九套 **444＝442通过＋2可选skip**，新8/8；ENTRY后owner红、实际按钮输出后错期待红；迁后同九套及新8/8绿。独审九套444及冻结before8/8、owner/button红是迁后独立复证，未冒写前执行。所有原体/185精确映射前缀与实际11正逆bytes/presence通过。
- **leader最终门**：九套 **444＝442＋2skip**，guidance通过；full **33 Suite/Ran、982＝979通过＋3可选skip**，0unexpected/exit0，native本地Git28/28；before full继承同基线已签B974、非C重跑。完整37/37源码临时树、8/8真实目标与实际elc，编译exit0/0，**42→42 Warning正文多重集合一致**，不称零告警或全根目标。W/E拒网定向/编译与隔离HOME native full分环境。加本计划 **12路径**在文档核对前完成累计正逆；staged空/root elc0。leader `/private/tmp/supertag-views-c-leader-jcnmtjvk/REPORT.md`；worker `/private/tmp/supertag-views-c-worker-_36bwo8r/REPORT.md`；独审 `/private/tmp/supertag-vwc-independent-kV2cQ1E4/REPORT.md`。
- **仅闭C**：下一候选为保留定位原体归Node后退helper；不改Org locator/Sibling，不改Tag/Link绘制provider或QE、不无条件清空其它carrier。后片14测试literal仍须最终工单/独立GO。VIEWS主体、五横切/v2/F1F2/QD/Canonical、GUI/私人真实库/第三方尚不关闭或扩权。

### V2-VIEWS-D：定位适配归 Node，退 helper；VIEWS 主体结构收口（2026-09-08）

- **唯一原体与兼容**：`supertag-view-helper-find-node-location` 原defun归Node，复用既有Query普通provider，无新增provider；原Node114顶层form含54函数及Capture条件尾原体/顺序保留。helper真实删除无shim。ServiceOrg/Commands/Concept/main仅退旧require/元数据，Embark原位置明确require Node，Tag/Query加载延后至原ServiceOrg链。helper-only功能入口退役，不保证私人require/advice兼容。原定位仅读取投影:file/:position、缺省1/文件存在判定，不替换Org locator，不修Sibling/陈旧位置或创建/保存。
- **范围与测试**：9路径＝7生产＋2测试，库存 **610→609**、根 **37→36**。原Tag74＋Framework38＝112顶层ERT及其它原文仅14精准分代；Framework新添5。Node真正冷入口先保feature/history观察，再载Tag业务fixture；实际非空定位后核Query已解析，不以autoload/fboundp代执行。D1/D2/D8原次数/历史before、B/C绘制负向与QE保持；两历史入口继续明确暂缓、不改分类。
- **阻塞与增补**：原授权映射在无ERT冷子进程插入三should-not，Node ENTRY后void-function是测试片段/窄核遗漏，不是Node业务回归。写前八套 **438＝437＋1skip**；首次after仅 **245＝244通过＋1失败**、余四套和guidance未执行，新5例前后各绿。addendum只将原位置三负向改同义when/error，不加ERT或provider、不删含义。三临时feature合成反证各命中命名error，仅证守卫活性，不称真正加载UI。旧292成员证据未动，final446累计另冻；原before与后补复证分开。
- **独立与最终门**：worker、独审、leader最终八套各 **438＝437通过＋1可选skip**；独审迁后before5/5、ENTRY/真实非空输出/省Queryprovider真红和三合成守卫红来源分列。leader full **33 Suite/Ran、987＝984通过＋3可选skip**，0unexpected/exit0，native本地Git28/28；before full继承同基线已签C982、非D重跑。完整37→36源码临时树、受影响7→6真实编译目标/实际elc，exit0/0，**40→40 Warning正文多重集合一致**，不称全根编译或零警告。W/E拒网定向/编译与隔离HOME native full分环境。guidance、9源码测试及加本计划10路径正逆通过；staged空/root elc0。
- **A–D累计收口**：A NodeView builder、B两公共读/订阅、C37函数＋2常量绘制、D投影位置适配均有明确owner；两次窄收据未发现具名直接View业务漏迁。独立核旧A/B/C及D blocked/final共 **1564签名成员**，按原A库存611/首触达链累计24路径真实正逆，最终22存在/2删除，根38→36、库存611→609；已在文档核对前完成，签名待回执。不是将当前HEAD当before或回滚主仓。
- **保留边界**：ServicesUI余两文本/输入适配、Node候选缓存条件监听与Commands三Sync职责另归相应owner；Framework无ServicesUI业务调用不意味着require可直接删，该边仍承载重加载/条件注册时点。不能为清容器顺删活能力、修订注册时机或宣称五横切已完成。此处只闭VIEWS主体结构，不扩v2/F1F2/Sibling/QD/Canonical/GUI/任意私人或真实库合同。
- **证据**：leader `/private/tmp/supertag-views-d-leader-b9sgc7tg/REPORT.md`；final worker `/private/tmp/supertag-views-d-addendum-worker-p4jhnq_5/REPORT.md`；独审 `/private/tmp/supertag-vwd-independent-2W0X5aBP/REPORT.md`；结构收据 `/private/tmp/supertag-views-structure-receipt-hec1jg7l/REPORT.md`。累计回放与来源链由leader固定，最终文档独核后签名，不借本条批准下片实施。

### V2-VAULT-A：纯选择原体归 Vault（2026-09-08，已验收）

- **范围**：四原defun从services-vault-selection逐字归新`supertag-vault.el`，仅真实cl-lib/subr-x依赖，无状态/初始化/宏provider替代；旧carrier删除无壳，main/Template各唯一require替换。main两个有效目录wrapper与配置/guard/init时点、Sync原fboundp分支不改。5路径＝4生产＋AddLink测试，原81顶层ERT及完整文件前缀保持（82文本声明含嵌套），新增5；库存 **609→609**、根 **36→36**。
- **真实兼容与冷边**：旧selection-only feature退役，四符号由Vault真实定义，未知私人require不保证兼容。fresh Vault/Template不加载main/Sync/Node/Tag/Query；实际default-file与临时路径计算保持unified原对象返回及active/空值原算法。file-truename确有路径解析，不承诺任意文件系统零IO。Sync-first与Template-first实际Sync返回原两根；after-init-time=nil加载main后wrapper真实出现，Sync改为单根；后段重载/清理独立于前段纯载，不挪main wrapper/autoload或修Automation晚load缺口。
- **证据时序**：worker写前与迁后六套各 **307/307**，current新增5/5。成功ENTRY后owner红、实际路径输出后错期待红和Sync合成时点红等四反例准确命中；合成provider只证提前wrapper的分支风险，不是生产bug。独审六套307、迁后before5/current5及四红复证另列来源，未冒写前或full编译。807 worker成员及已签D345/主仓609末核稳定，原体/前缀与五路径正逆通过。
- **leader最终门**：六套 **307/307**、guidance绿；full **33 Suite/Ran、992＝989通过＋3可选skip**，0unexpected/exit0，native本地Git28/28；before full继承同基线D987、非A新跑。完整36/36源码临时树、受影响3/3真实目标及实际elc，exit0/0，**31→31 Warning正文多重集合一致**，不称全根编译或零警告。W/E拒网定向/编译与隔离HOME native full分环境。加本计划 **6路径**在文档核对前完成累计正逆；staged空/root elc0。
- **仅闭纯选择片**：下一候选八个目录计算原体进入同Vault，不迁配置初始化或两个有效目录wrapper；裸声明未初始化须新fresh未setq控制，旧VA预置base/data不能代证。未配置首调用可达性变化须明确授权；完整切库/Setup后续，不新增技术层，不修F1F2/Sibling/QD/调度或宣称Vault/v2已闭。leader `/private/tmp/supertag-vault-a-leader-c7jspfix/REPORT.md`；worker `/private/tmp/supertag-vault-a-worker-4dcxcepq/REPORT.md`；独审 `/private/tmp/supertag-va-independent-4wJvTaJ4/REPORT.md`。

### V2-VAULT-B：目录计算原体归 Vault（2026-09-08，已验收）

- **精确范围**：main连续八个目录计算defun逐字归Vault；旧Vault四函数/require/provide顺序保持，main其余顶层原文与两个有效目录wrapper、base捕获、配置/guard/init时点完全不动。新增四个无初值special声明：base-data-directory、data-directory、sync-directories-mode、sync-directories；不设nil、不require配置provider。3路径＝2生产＋AddLink仅append，旧86顶层ERT及全文前缀/VA五例保持，新6例，库存609/root36不变。
- **真实可达性**：八函数更早由Vault/Template可用，但非无配置安全API。fresh在任何setq前证明四变量仍未绑定；实际normalize-root缺base、fallback缺data、vaults模式缺directories三条void-variable按原读取执行，不吞错、不补初始化。真实动态绑定/目录归一化、id hash、最长根/同长顺序、路径解析fallback按原体；文件解析不称零IO。main原初始化及Sync两根→main wrapper后单根仍分段，显式reload代际不冒require-only EQ。
- **证据时序**：worker写前和迁后六套各313/313，新6/6；ENTRY owner红、真实非空计算输出错期待红及合成初始化守卫红准确。独审六套313、迁后before6/current6及三红另列来源；合成默认值污染只证守卫，不称生产bug。worker862及A246签名、main609末核与三路径正逆闭合。
- **leader最终门**：六套 **313/313**、guidance绿；full **33 Suite/Ran、998＝995通过＋3可选skip**，0unexpected/exit0，native本地Git28/28。before full继承同基线已签A992，非B新跑。完整36/36源码临时树、受影响2/2真实编译目标/实际elc，exit0/0，**31→31 Warning正文多重集合一致**，不称全根目标/零告警。W/E拒网定向/编译与隔离HOME native full分环境。加本计划 **4路径**文档核对前完成累计正逆，staged空/root elc0。
- **仅闭B**：后续guard候选四状态/五函数/宏归Vault，通过main原位置显式准备默认值、原init后安装watcher；早可达及Template-first显式Git clone捕获分支须完整工单/前后实证，不用initialized判断冒等价。配置base/custom、两个wrapper、Setup/切库政策不顺移，不总闭Vault/v2/F1F2/QD/Sibling/调度。leader `/private/tmp/supertag-vault-b-leader-s7umfokk/REPORT.md`；worker `/private/tmp/supertag-vault-b-worker-5ba6c1pb/REPORT.md`；独审 `/private/tmp/supertag-vb-independent-YdspcXh4/REPORT.md`。

### V2-VAULT-C：配置守卫归 Vault／compiled-main 必修闭合（2026-09-09，已验收）

- **原体与初始化边界**：四个原guard状态defvar完整嵌入Vault唯一`supertag-vault--prepare-guard-defaults`，main在原位置（initialized定义之后）显式调用；五函数＋with-allow宏原体归Vault。保Vault原12函数、四目录裸声明，新增九裸special；Git仅capture声明owner调整，clone原体不动。main原init后安装watcher、capture先于enabled检查与Persistence动态allow保持。5路径＝3生产＋2测试，库存609/root36不变，旧Vault14＋Git28＝42ERT完整前缀保持；C新增7＋3，R1再添1例compiled-main回归，最终Vault22/Git31。
- **明确兼容与真实控制**：Vault/Template首载只更早定义guard，不初始化四默认或安装watcher；未配置调用的原错误不修。Template-first显式本地Git clone更早命中既存capture分支，Git-only仍跳过，main已载而initialized=nil仍捕获；后续main准备不覆盖已捕获state引用。三路径均实际本地bare/seed clone与投影，非网络Git。真实watcher的set/let/allow、Persistence setter、预绑定/重复enable及退出恢复均控制；源级宏和独立guard-control.elc不能冒称已验证main编译单元。
- **R1是真实编译错误，不是告警清理**：初轮源码七套326/full1008虽绿，完整临时树编译31→34新增两处unused-lexical allow和prepare长doc；真实main.elc的apply/activate动态绑定被优化掉，watcher阻止apply。获批最小修复仅main头store-origin后裸`(defvar supertag--config-guard-allow)`、新prepare doc折行；原函数/宏/状态体不改。追加回归在修生产前用相同最终测试字节编译真实完整树、另一fresh进程load实际main.elc，MAIN-COMPILED-ENTRY后真实user-error红（Vault21通过＋1失败）；修后22/22。未给测试声明allow或桩宏/watcher/apply，子进程非零或缺结束marker均失败。新ERT真实执行apply，activate仅核bytecode身份；独审另解码两者allow varbind，不冒完整activate运行。
- **时序与独立证据**：原worker写前/迁后326和独审326、冻结before7＋3及四反例属原C字节；旧1142签名成员保持。R1 worker最终296＋本地Git31＝327、独审vault22/22；独审原故障冻结ENTRY后红与复用同字节elc解码是迁后复证，不冒写前或正式编译。新187签名、累计5路径及原C before/previous-after/current链核验通过。历史夹具/解码输出buffer及红日志字符串锚点校准单列工具证据，不当生产红。
- **leader最终门**：修后W/E六套 **296/296**、隔离HOME native本地Git **31/31**，合 **327/327**；guidance通过。修后full **33 Suite/Ran、1009＝1006通过＋3可选skip**、0unexpected/exit0；初轮1008另留，不混最终。before full继承已签B998，非C重跑。完整36/36源码临时树、Vault/main/Git三真实目标及实际elc，正式编译 **31→34→31**，修后Warning正文多重集合与before一致；不称零告警/全根目标。W/E拒网定向/编译与隔离HOME native full分环境。加本计划 **6路径**文档核对前完成累计正逆；staged空/root elc0，签名待文档回执。
- **仅闭C**：后续配置/runtime/indicator按原main位置显式准备，两个有效目录wrapper的定义与生成autoload provider时点须独立核验；Sync原两根→main后单根不得借搬文件改变。Setup后片，不扩Automation晚load/F1F2/QD/Sibling/私人配置或GUI合同，不总闭Vault/v2。leader `/private/tmp/supertag-vault-c-leader-gi28kkqx/REPORT.md`；R1 worker `/private/tmp/supertag-vc-r1-worker-y3hjhccz/REPORT.md`；R1独审 `/private/tmp/supertag-vc-r1-review-h6gmnn8g/REPORT.md`；原独审 `/private/tmp/supertag-vc-independent-lh_17nh4/REPORT.md`。

### V2-VAULT-D：配置／切库／指示器归 Vault（2026-09-09，已验收）

- **完整原体与原位准备**：19原form＝P1五配置、P2 current/bufferlocal/mode三体、P3两有效目录wrapper、九个直接runtime函数，全部逐字归Vault；三新增prepare不算迁入原体。main在原file-id前/后及原wrapper区间显式调用，C guard仍initialized之后、R1裸allow保持；原main装配/总init/hooks不动。Vault原18函数/guard宏及状态顺序保留，现30defun；九新增裸special、14 optional普通declare及mode声明，不增加optional autoload/ready/反向require main，Sync源码零改。三路径＝Vault/main/Vault测试，库存609/root36不变。
- **autoload与实际加载合同**：main原cookie改为仅生成器读取的显式指令，唯一有效目录wrapper仍provider `supertag`、interactive=nil、原doc；effective-root/三prepare无autoload。实际本地loaddefs生成仅main/Vault两输入、其余34排除，fresh加载产物后首次调用真正兑现main及两wrapper；误provider Vault或省main P3均在实际FIRST-CALL后失败，不是仅字符串检查。无autoload的纯Template/Vault仍不初始化配置/mode/wrapper，实际Sync先两根同对象、main后B单根。两嵌套wrapper运行owner实为main/main.elc，直接apply归Vault/Vault.elc；不强造symbol-file。
- **接受的早可达变化**：九runtime更早可用，但不隐式补main配置。实际generated activate(nil)两代均No vault selected，旧先载main、现不载；generated auto-activate在仅两根而未准备默认时，旧经main成功，现为`void-variable supertag-vault-modeline-indicator`且main未载。这是明确保留的首次调用前置变化，不称普遍兼容或已修该错误。预绑定值/配置属性/guard引用、require-only与main/Vault显式reload分列；真实Org指示器、local状态、单hook与auto=nil保留。真实persist→stop→reset→apply→sync-load→store-error仍留下B部分状态，allow恢复；不新增回滚或修Automation晚load。
- **测试与时序**：旧22ERT整个前缀仅R1编译owner一个表达式按独立VD-before/current映射，实际main.elc加载、两bytecode检查、真实watcher/apply与marker保留；新增13，最终35。worker同字节写前/迁后七套352及本地Git31，新13均绿；ENTRY owner红/真实Sync输出错期待红、生成首调用两遗漏红有效。v1语法、v2缺DONE/产物位置、v3九例和11例350是历史夹具阶段，不作最终13写前证据；原日志字节不改。独审七套352＋nativeGit31及before/current13、红均为独立迁后复证；1074 worker、C352/R1187签名与三路径回放通过。
- **leader最终门与编译边界**：七套 **352/352**＋隔离HOME native本地Git **31/31**＝**383/383**，guidance通过；full **33 Suite/Ran、1022＝1019通过＋3可选skip**，0unexpected/exit0，before full继承已签C1009。完整36/36源码临时树、Vault/main两真实目标及实际elc，正式编译 **31→31只表示数量相同**：删两custom-doc、增两make-variable-buffer-local not-toplevel，正文集合不同。保原准备位置，不抑警告或上提初始化。worker/独审仪表compiled证时序；另有R1未仪表真实apply；root再用官方未仪表elc真实双buffer setq/模式启停，local/default隔离通过，独审仅同hash解码确认两local调用未消失，不冒再次运行/编译。此与C动态allow被优化掉的真实故障不同，不外推版本/GUI。加本计划 **4路径**文档核对前完成累计正逆，staged空/root elc0，签名待回执。
- **仅闭D**：Setup向导仍独立旧载体，其main前置与真实Menu wrapper须下片明确接替，不能直接删require；尚未关闭Vault主体/v2/F1F2/QD/Sibling/任意私人配置和共享恢复政策。leader `/private/tmp/supertag-vault-d-leader-k0xrsvmj/REPORT.md`；worker `/private/tmp/supertag-vault-d-worker-4bzqltnj/REPORT.md`；独审 `/private/tmp/supertag-vd-independent-l3cjusft/REPORT.md`；编译local窄核 `/private/tmp/supertag-vd-locality-review-kazzce1y/REPORT.md`。

### V2-VAULT-E：Setup 向导归 Vault（2026-09-09，已验收）

- **合并与保留**：21 Setup 函数归 Vault，20 原体逐字保持，公开入口只在 interactive 后、原 quit catch 外增加 main 解析前置；旧 Vault72 form/30defun、guard/四准备边界及顺序不变。main/Sync源码零改；Menu仅setup声明和真实wrapper两literal，旧Setup载体真实删除，无壳。四路径＝三生产（含一删除）＋Vault测试；旧35ERT整个文件前缀零映射，新25，最终60。库存609→608、根36→35。
- **明确的入口兼容**：纯Vault/Template不初始化main；header仅未fboundp时安装ordinary TYPE=nil、interactive=t、精确provider=supertag的init stub，已有任意cell不覆盖。实际Setup在main缺席时先核cell类型/provider，再autoload-do-load且核main feature，不funcall init；main已载时跳过解析，不重载或再init。private/foreign/nonordinary/unbound及同型非autoload重入状态在prompt前拒绝，main加载error/quit在原取消catch外传播。这取代旧require-Setup的隐式main加载，非旧单feature/私人调用全面兼容；partial-main控制不是实际递归loader实跑。
- **实际控制而非新政策**：真实生成autoload及冷Menu命令均兑现Setup→main→原prompt，native pending advice/late-init真实init一次，二次进入不重做；两时点foreign及实际compiled guard保cell。session/snippet原live赋值、两次真实customize写及第二次失败部分盘/live状态、persist后quit仍留变更均保持，不把原取消文案解释成回滚。真实watcher拒绝、stable-ID临时Org扫描/非空Store、缺scan/拒绝/错误分支均控制；doc只实测临时树无文件分支，不承诺正向文档或所有私有路径。
- **时序与独审**：worker最终同字节新before/current25/25、七套377/377及native本地Git31/31，在生产cmp0后才迁属。先真实旧Setup/main/prompt ENTRY后owner红、实际session写后错期待红，omit-entry真实生成调用及naked-header foreign-EQ两反例成立。早期括号/provider/保存文件顺序夹具失败、24例中间态、589子集库存及两次patch工具失败另留，不作产品红/完整库存/成功回放。独审独立408/408、迁后冻结before25和反例复证与worker写前分列；840 worker、D289及22工单签名核清。
- **leader最终门与编译**：W/E七套 **377/377**＋隔离HOME native本地Git **31/31**＝**408/408**，guidance通过；full **33 Suite/Ran、1047＝1044通过＋3可选skip**，0unexpected/exit0，before full继承已签D1022。完整36→35源树，实际编译目标Vault/Setup/Menu三份→Vault/Menu两份，exit0；Warning **31→9**，不是零新增：删29条旧Setup编译预载main产生的obsolete宏告警，显露7条既有Menu AI/Semantic缺declare。另以两套冻结源分别fresh只编Menu，真实各1elc且 **7→7正文同集**，恰对应七新增；七provider/interactive/wrapper未变，窄核无必修，不借本片清告警。此与C曾损失动态绑定的真实故障不同。worker/独审fresh compiled入口、root正式目标编译与补充cold编译证据分列。
- **冻结与限制**：四源码/测试及本计划 **5路径**已在文档核对前实际正逆；签名待文档回执。main/旧冻结/范围外不漂移，staged空/root elc0；无真实用户库/配置、GUI/模型/任意hook或崩溃恢复验收。leader `/private/tmp/supertag-vault-e-leader-g_9nnwo7/REPORT.md`；worker `/private/tmp/supertag-vault-e-worker-8owf9ztv/REPORT.md`；独审 `/private/tmp/supertag-ve-independent-5w_38jpj/REPORT.md`；Menu窄核 `/private/tmp/supertag-ve-menu-warning-review-erxniqwk/REPORT.md`。

### V2-VAULT 主体结构收口（A–E，2026-09-09）

- 纯选择/目录计算、guard、配置/indicator/切库和Setup已集中同一个Vault。main保原位prepare调用与总启动/退出装配，不重复实现；Template默认目标、Sync扫描、Git导入和Persistence安全各保实际共享owner。不为清空carrier上提初始化、迁移共享writer或删零caller能力；定向收据未见新的具名直接Vault漏迁。
- 累计来源为A初始 **609项**、A/B/C含R1/D **1127签名成员**及逐路径首触达链；加E和本计划共 **11路径**，独立临时正向/逆向均已实际字节/缺席通过，存在 **10→9**。新增Vault、删除旧selection及Setup；本批根 **36→35**。单片E五路径与主体十一条来源/replay分列，签名仍待文档回执后固定。
- 仅关闭Vault主体结构，七个特性主体批次收拢不等于五横切或整个v2完成。ServicesUI剩余适配/条件监听、Commands的Sync命令和Store/Org等共享过渡承载后续按实际owner处理，不重新拆特性。下一Sync命令片目前只有候选，须基线/工单/GO后实施。早可用/未配置错误、D生成入口前置、E私人cell/旧Setup可用性，及F1/F2/QD/Sibling/调度晚load/field/reload等保留边界不扩修。收尾只读依据 `/private/tmp/supertag-vault-closeout-readonly-af1mvvjh/REPORT.md`，不冒运行总验收。

### V2-SYNC-A：显式重同步／状态命令归 Sync（2026-09-09，已验收）

- **原体与载体退场**：三个完整函数 `supertag-sync-force-resync-file`、`supertag-sync-force-resync-current-file`、`supertag-sync-status` 及两cookie归既有Sync；原187顶层form保持为190中的相同有序子序列。普通file函数仍非交互命令，不新增provider/state/writer。旧Commands真实删除，无壳；八生产精确接线，Menu cleanup/status两个真实wrapper改owner，E Setup仍Vault。原18路径加Promote增补共19，库存608→607、根35→34。
- **精确测试与加载变化**：十测试23literal及storage追加12控制保持；原264顶层ERT只做获批映射。漏列的Promote两处ServiceOrg预载观察经addendum1独立SYA-before正/current负，48ERT及其余字节、Link初始feature/history负向、Sync/Concept owner/error和CA/CB/LD历史保留；不补生产导入。Concept首载不再借Commands预载ServiceOrg，实际writer首次调用仍按原provider；不称ServicesUI条件监听/广加载等价。Move两warm successor明确为Node后实际ServiceOrg，不推广到旧cold。
- **真实业务与证据时序**：最终新增12例写前已通过；在8生产cmp0时取得真实ENTRY owner红、真实Changed投影/state后的错误期待红，完整14套before640＝638通过＋2可选skip。原迁后链至Promote为548＝544通过＋2失败＋2skip，未跑AddLink/guidance；root另独立48＝46＋2在ENTRY后复现。两失败是旧加载观察漏列，不作writer产品红；addendum冻结before/current各2例为迁后复证，不能重写原写前时序。新fixture括号/路径/marker/计数校准、interleaved日志UTF8解码另列工具来源。原quoted mutable counter重用保持；remhash在transaction前、process在内、update/save在后，分别以真实中途process和后段state-write故障核Store/index/state/disk部分状态，不宣称跨文件原子回滚。
- **最终门、独审与冻结**：最终worker与root各W/E14套 **640＝638通过＋2可选skip**，guidance通过；root隔离HOME native full **33 Suite/Ran、1059＝1056通过＋3可选skip**、0unexpected/exit0，before full继承已签E1047，不冒称重跑。完整35→34临时源树、8→7真实编译目标和对应elc，Warning **53→53正文多重集合相同**，并非零告警。独审另跑640、迁后before12与Promote2+2、owner/真实输出红；不称独审full/编译或guidance。root原19代码／测试正逆及加本计划 **20路径正逆已完成**；旧blocked633、最终worker330、原authority86/addendum8和E336来源/字节核验通过。签名仅待文档回执。定向W/E拒网与native full分环境，Embark/AI两个skip不冒真实端点。
- **只闭本片**：core-async队列仍是下一精确候选，ServicesUI的层级/type适配及Node条件监听保对应边界，不为清carrier加准备函数或无依据删能力。Sync/Store/Org五横切与整个v2尚未完成；F1/F2/QD/Sibling、私人旧require和GUI/真实库/任意hook/崩溃恢复政策不扩。root `/private/tmp/supertag-sync-a-leader-ao3fc38q/REPORT.md`；最终worker `/private/tmp/supertag-sync-a-add1-worker-20h__8mn/REPORT.md`，原blocked `/private/tmp/supertag-sync-a-worker-y1olzaby/REPORT.md`；独审 `/private/tmp/supertag-sya-independent-70EJDfBC/REPORT.md`。

### V2-SYNC-B：文件异步队列归 Sync（2026-09-09，已验收）

- **原体及精确范围**：原core-async连续13定义（6函数、4状态、2配置、1group）置于Sync原require位置；Sync190→202顶层form，除该require外原文/顺序及A三命令/两cookie不变，无新provider/state/init。Git仅删旧依赖文字和require，真实Sync依赖保留；旧async源码/feature无壳退役。四路径＝三生产含删除＋sync-worker测试，旧26顶层/16ERT/2helper整文件前缀不改，仅追加constant/helper与10ERT；库存607→606、根34→33。
- **保持真实队列合同**：四状态与两配置预绑定、require-only/显式reload分列；旧轻载入口变完整Sync，未知私人old-require兼容不承诺。实际idle timer对象/回调及批量worker确定性执行，不冒自然idle-loop。A/B/A去重、失败重投、pop后error继续/quit中断、同步reenqueue均保；真实start先清首次Git投递，再重新project-files才消费。clear/stop不清idle timer，reset只清原两hash，不顺修生命周期或合并Automation队列。真实临时Org→Sync事务/投影/index/state后注入state-save失败，保Changed Store、旧状态盘字节及failed/retry；不称任意processor零写或跨文件原子恢复。独立单点删除init清队列赋值，真实Git→start后准确断言红。
- **QD失败窗口实测**：before/current的Sync与Git在无Org且精确语言t配置时，均真实file-missing `ob-supertag-query-block`，Org/Query未provide、六queue函数/六变量未定义；Org-first两入口成功且processor仍nil。这里绿是**准确观察继承失败**，不是模块成功加载；本例没有观察到前后部分可用性差异，不能外推所有加载失败都等价，也不fake-provide或修Query策略。初稿8/10误期待无Org成功，仅校准新fixture，三生产仍cmp0；不是本片产品红。
- **写前、独审与最终门**：最终同字节新before10/10、真实ENTRY后owner红与真实Alpha投影后的输出红，在三生产cmp0后固定；before/current各W/E五套 **279/279**＋native本地Git **31/31**，guidance通过。独审另跑279＋31、guidance，迁后before10及owner/output红复证；不冒其亲历写前或跑full/compiler。root同字节定向 **310/310**；native full **33 Suite/Ran、1069＝1066通过＋3可选skip**、0unexpected/exit0，before full继承已签A1059。真实完整34→33源树，编译3→2目标/对应elc，Warning **30→30正文多重集合相同**。root launcher完成定向/编译/Git后空数组在shell报错，full尚未启动；保留原工具失败，直接无selector续跑全门成功，非ERT或产品失败。
- **冻结与剩余**：root四代码/测试路径及本计划 **五路径正逆已完成**，含删除缺席/恢复；340 worker、59工单、A311来源与主仓首尾核验通过，签名待文档回执。仅关闭SYNC-B，不无条件总闭Sync/五横切/v2；State＋Notify→Store目前仅精确准备，须下片基线/工单/GO，Transform/Canonical及ServicesUI残留不顺改。F1/F2/QD/Sibling、私人配置/GUI/模型/任意hook/所有失败窗口仍在范围外。root `/private/tmp/supertag-sync-b-leader-opRnSUkp/REPORT.md`；worker `/private/tmp/supertag-sync-b-worker-bf089lpc/REPORT.md`；独审 `/private/tmp/supertag-syb-independent-f9cjc550/REPORT.md`。A段“async下一候选”保留其历史时点，由本段更新。

### V2-STORE-A：State＋Notify 归 Store（2026-09-09，已验收）

- **原体与范围**：State7＋Notify7共14原form按原依赖执行顺序连续归Store；原Store36→48顶层form，cl-lib/ht仍先加载，无新provider/state/init或反向require。十生产路径含两旧源码删除，其余八文件仅13精确literal；Transform事务/Org parser、Index/Canonical算法不动。Sync仅取消旧State require及相应头注释，原SYB队列、全部投影/事务/生命周期原体顺序保留。库存606→604、根33→31；旧State/Notify feature无壳退役，公开函数/宏/变量原名保留，私人轻载路径兼容未知。
- **测试与真实边界**：storage旧22ERT整文件前缀＋AUC旧16ERT保持，AUC仅一处独立STA-before/current provider映射；storage追加7。真实cold owner与提前加载宏provider后的lexical业务控制分开；预绑定状态/订阅表、require-only、显式Store reload/native advice/旧unsubscribe closure实跑。普通/path通知、error/quit、嵌套pending和手动flush保原行为，不把内部pending被cleanup丢弃说成完整事务通知保证。实际非空Canonical commit及局部legacy抑制不替换writer。新回滚例证明真实Store恢复/Index可观察失效与惰性查询重建；其hook被隔离后装计数器，不冒称该例执行了Index原注册rebuild-all callback。
- **时序与独审**：最终同字节写前新增7/7、五套256/256、guidance通过，十生产cmp0后取得ENTRY owner红及真实恢复Old后的错期待红。早期括号/setup和lexical body在真实macro provider前被读取的夹具错误不作产品红；中间before-new4不是最终输入。worker审计脚本误覆自身inventory后另留历史mapped副本并恢复原606，与root before逐字核对，未用中间测试库存冒原基线。独审另跑256/256、guidance、迁后before7/7及两红；独立移除Canonical局部抑制后真实commit命中输出红，首个括号变异无ENTRY仅属工具失败。
- **消费者与最终门**：root W/E五套 **256/256**，包含Sync保存/投影与SYB队列、Automation真实写入和Framework订阅消费者，不只运行Store新7例。native隔离HOME full **33 Suite/Ran、1076＝1073通过＋3可选skip**，0unexpected/exit0，含本地Git31/31；before full继承已签SYB1069、未重跑。完整33→31临时源树、10→8受影响实际编译目标及对应elc，**67→67 Warning正文多重集合相同**，不是全根编译或零告警。另以两代官方编译树真实Sync/Store/Transform/Automation `.elc` 跑相同12条保留消费者控制，迁后补跑before/current各12/12；不计入新增ERT/full总数，与worker/独审的专用compiled lexical caller例分别留证。
- **冻结与剩余**：十二源码/测试路径及加本计划 **十三路径正逆已完成**，包括两删除缺席/恢复；436 worker、81工单、SYB242来源与主仓首尾核验通过。签名待文档回执。只闭STORE-A，不总闭Store/Sync或五横切/v2；事务5form仍在Transform，下一片须以A最终字节重基和独立GO，parser/Canonical/Index注册不顺搬。GUI/真实用户库/任意hook/崩溃恢复及F1/F2/QD/Sibling等不扩。root `/private/tmp/supertag-store-a-leader-h7batry6/REPORT.md`；worker `/private/tmp/supertag-store-a-worker-zs1f57k0/REPORT.md`；独审 `/private/tmp/supertag-sta-independent-txcdmk36/REPORT.md`。

### V2-STORE-B：事务与回滚归 Store（2026-09-09，已验收）

- **原体与范围**：三事务/回滚函数、rollback-hook状态和事务宏共5原form整体置Store原provide前；Store48→53、Transform19→14，原public符号/special/局部宏变量/原文顺序不改。Transform保4常量＋5函数Org parser及原require/provide，不退carrier。仅Store/Transform/storage测试三路径，库存604/根31不变；旧storage29ERT完整前缀含STA7保留，追加6，不改任何旧测试literal或其它历史stage。
- **兼容与真实Index边界**：Store-only提前提供事务函数/宏/hook；require-only与显式Store/Transform reload的函数cell重定义方向分代实测，预绑定值及native advice保留，不泛化私人热升级。初版工单误称Index先require Store，在GO前以R1纠正：Index实际仅require cl-lib，可在Store/Transform均未载时先注册hook。两个fresh顺序都实证原callback、预绑定和唯一注册；原rebuild-all在真实回滚后透传完成1，计数在lazy查询前检查。Index注册/算法仍原位，不以A隔离hook计数替代本片真实callback证据。
- **写前与独审**：最终同字节before6/6及五套262/262/guidance在两生产cmp0时取得；ENTRY owner红、真实恢复索引后的错期待红及callback省略红分列。早期child已DONE但parent尾空格marker/错误stats名称导致失败，仅新运输夹具错误，不作产品红。独审另跑262/guidance、迁后before6/owner/output红；独立省掉事务cleanup的hook调用，实际attempts/completed为0，在lazy读前准确断言红，与worker在callback处省原体不同。真实error/quit、hook普通error继续/quit中断、第二次restore故障后的b恢复/a仍变化保原部分状态，不许诺所有失败全原子。
- **最终门及编译**：root W/E五消费者套件 **262/262**，含Sync/SYB保存投影队列、Automation真实写入、Framework订阅；native隔离HOME full **33 Suite/Ran、1082＝1079通过＋3可选skip**，0unexpected/exit0，含本地Git31/31；before full继承已签A1076。完整31→31临时源树、两受影响实际目标/两elc，**6→6 Warning正文多重集合一致**。另在两代树保留这两elc并分别补编译Sync/Automation/Node/Tag/ServiceOrg/Canonical六个宏消费者，实际新增6elc、**87→87正文同集**；其混合源码/字节码树用相同12条既有Sync消费者前后各12/12，都是迁后补跑，不计1082或新ERT，也不是全31根编译。worker/独审的专用fresh lexical caller另证current仅Store.elc＋caller、无Org/Transform，before真实Transform；两类compiled证据不混。
- **冻结与剩余**：code3及加本计划 **final4正逆已完成**；302 worker、109原工单＋4项R1、A329来源和主仓首尾核验通过，仅最终签名待文档回执。旧错误工单/authority不覆写，GO明确使用WORKER.r1.md。仅闭STORE-B，Index派生机制仍为下片候选，必须精确授权首写revision/rollback注册提前及原轻入口退役；不顺迁Query/Tag/Automation业务、不总闭Store/Sync/五横切/v2。GUI/真实用户库/任意hook/所有恢复矩阵、F1/F2/QD/Sibling等不扩。root `/private/tmp/supertag-store-b-leader-xubso3f5/REPORT.md`；worker `/private/tmp/supertag-store-b-worker-gr1iv0lr/REPORT.md`；独审 `/private/tmp/supertag-stb-independent-dymwalb8/REPORT.md`。A段事务暂留是其历史时点，由本段更新。

### V2-STORE-C：派生索引归 Store（2026-09-09，已验收）

- **原体与范围**：Index连续28原form＝19函数、7派生状态、原裸Store声明及原rollback注册，逐字置Store事务块后、provide前；原Store53去一条现已内部的声明后为80，旧Index载体真实删除，无壳。九生产18literal：六consumer去精确Index require并保既有Store依赖，Query两普通provider仅改owner为Store；Query本来就require Store，不称新增lazy索引入口。Tag/Automation自有索引、Query业务、Sync/parser/Canonical算法均不迁不复制。库存604→603、根31→30。
- **接受的加载兼容**：Store-only从首写记录revision并更早注册真实rollback callback；不保证原绝对计数基数或旧Index-only轻载兼容。七state/Store预绑定保留；原add-hook前插callback，custom hook原list保持同一cdr而非整表EQ。require-only与显式Store reload的原函数重定义/advice效果分代；不重置用户值或增ready。from/to/between均原样ensure-relations，早期摘要“不ensure”已纠正。真实非空关系、对象引用/type过滤、恰+1增量与缺一次维护后的fallback重建、节点rank/去重和Query读取原样控制。
- **旧测试与新证据**：storage原35ERT/47顶层form仅两program常量中的五精确literal分代，全部旧ERT原体不变，追加7。STA/STB历史Index-first/空hook与STC-current真实Store入口区分，原negative、callback在lazy查询前计数、compiled及partial restore保持。真实原callback省略在调用计数0时红；optional六能力临时binding只证明真实core rebuild的guard顺序/error清理，不冒真实Tag/Automation缓存重建，其真实消费者由14套另列。新STC实际fresh elc证明单层error/quit事务与callback2，不称该caller含nested；嵌套覆盖归保留STA/STB用例。
- **写前与独审来源**：worker生产九路径cmp0时固定最终测试输入，新增before7/7、14套534/534及guidance通过，ENTRY后owner/非空Query实际输出错期待/真实hook省略三红均在迁属前。初稿多余括号造成7setup失败，不作业务红；报告早期634加总口误以真实Ran合计534为准。独审另跑534/guidance、迁后冻结before7/current7及owner/output红；独立删除原两行add-hook，在非空回滚后、lazy读前calls=0有效红，初稿仅删首行的reader失败另留。source/compiled和合成/真实特性证据分列，未重写旧签名报告。
- **最终门与冻结**：root W/E **14套534/534**、guidance通过，含真实Sync/SYB保存投影队列、Automation、Tag/Link/Query、Persistence/Migrate/Mention及Framework消费者，不只Store新例。native隔离HOME full **33 Suite/Ran、1089＝1086通过＋3可选skip**，0unexpected/exit0，含本地Git31/31；before full继承已签B1082。完整31→30临时源树、九→八实际编译目标/对应非空elc，**65→65 Warning正文多重集合相同**，不是全根编译或零告警。root code10及加本计划 **final11正逆已完成**，含删除缺席/恢复；worker384、工单198及父B361来源与主仓首尾通过，仅最终签名待文档回执。
- **仅闭C**：八非默认旧Index直接加载入口按工单暂缓，旧名不兼容/残留不冒全历史绿。Canonical只有下一切口准备，Transform仍保Org解析，Store/Sync/五横切及整个v2未总闭；不扩F1/F2/QD/Sibling/Automation晚load、GUI/真实用户库/任意hook或所有失败原子性。root `/private/tmp/supertag-store-c-leader-p3kz1090/REPORT.md`；worker `/private/tmp/supertag-store-c-worker-wia9dijl/REPORT.md`；独审 `/private/tmp/supertag-stc-independent-vgwi8202/REPORT.md`。B段Index暂留为其历史时点，由本段更新。

### V2-STORE-D：Canonical Change 归 Store（2026-09-09，已验收）

- **原体与范围**：旧Change连续31原form（3常量、10状态、1配置、17函数）逐字置Store原Index注册之后、provide之前，去掉已同源的外部声明；Store80−1+31＝110。仅Store、删除Change及storage测试三路径，无新增require/provider/ready/初始化调度；原Link special声明、通知条件、事务/索引算法和Sync/Automation队列不改。库存603→602、根30→29；旧Change真实退役无壳，保全部原公开符号。
- **兼容与订阅合同**：Store-only更早提供Canonical API/special/debug及跨legacy双订阅guard，原仅Store允许的预绑定同callback legacy订阅现在由原guard拒绝；其他callback/topic仍可用。工单R1在GO前纠正“拒绝重复”的错误：同一Canonical callback仍append、重复投递，任一退订closure通过delq删除全部EQ项，各自幂等；仅跨legacy双订阅拒绝。require-only保cell，显式Store reload现在重定义Canonical；预绑定10special/debug与native advice/旧closure真实运行，defconst重置不作全state EQ承诺。纯Store不因此载Org/Transform/特性/入口或自动投递。
- **真实行为与证据层次**：48ERT＝旧42完整映射前缀＋6新增；只改STA两处provider条件，独立STD-before沿已签C，STA/STB/STC各自历史保持，STC7及旧compiled/真实callback断言完整。真实多path first-touch/noop/envelope、Canonical→legacy顺序、outer订阅者提交inner的FIFO/causation/快照、body error/quit回滚与投递期error/quit部分状态分开。已pop批次余部不重放、后继queue须后续drain，不改恢复政策。新fresh实际elc执行单层外事务Canonical commit及局部special/失败回滚，无测试special补丁，不冒新nested证明；旧STA/STB嵌套覆盖另列。Sync/Automation真实消费者不是因此改成Canonical writer。
- **真实时序与独审**：最终同字节新before6/6绿后，owner/输出/省局部抑制三红在06:33取得，随后十套before于06:37完成；均在生产两路径cmp0及迁属之前。worker报告一句叙述顺序不准，以日志/command与migration记录为准，不覆盖已签原报告。新draft括号与Python audit语法错未进入有效产品红。独审另跑497/guidance、迁后冻结before6/current6与owner/output红，独立将drain非重入条件取消后真实outer/inner顺序错误，命中业务断言；不是变量合成或setup红。其fresh compiled是自有临时编译，不称root正式compiler/full。
- **最终门与单片冻结**：root W/E十套 **497/497**、guidance通过，覆盖真实Sync/SYB保存投影队列、Automation、Tag/Link/Query/View及Persistence消费者；native隔离HOME full **33 Suite/Ran、1095＝1092通过＋3可选skip**，0unexpected/exit0，含本地Git31/31。before full继承已签C1089，不冒重跑。完整30→29临时源树、两before/一after实际目标和非空elc，**7→7 Warning正文多重集合相同**，非全根编译或零警告。code3及加本计划 **final4正逆已完成**；worker309、原authority160/R1四成员及父C403、主仓首尾核验通过，最终签名待文档回执。root `/private/tmp/supertag-store-d-leader-bo9yyp9l/REPORT.md`；worker `/private/tmp/supertag-store-d-worker-r7r_kk0v/REPORT.md`；独审 `/private/tmp/supertag-std-independent-1srs91mj/REPORT.md`。

### V2-STORE A–D 主体结构收口（2026-09-09）

- A状态/普通通知、B事务回滚、C派生索引、D Canonical均集中于 `supertag-core-store.el` 内部节；旧State/Notify/Index/Change四载体退役。实际机制、条件回调和两种commit协议保留；没有通过零caller删除能力或把特性索引/业务队列合成通用平台。候选收据 `/private/tmp/supertag-store-candidate-closeout-kaoylwfo/REPORT.md` 原本仅基于冻结与D候选；root实际after/native等于批准候选，D运行/独审与本次来源回放另行完成，不冒该只读收据运行过门。
- 以前三片已签A329/B361/C403共 **1093签名成员**、A初始 **606库存** 为依据，逐片核首触达before及相邻before/after链。A–D源码/测试加本计划累计 **20路径** 已在临时目录实际正向/逆向字节与缺席回放，存在 **20→16**，主仓库存 **606→602**、根 **33→29**；不以当前Git HEAD或末片before冒批次初始基线。D单片final4与批次20分别留证，签名待文档回执。
- **只闭Store主体结构，不闭五横切/v2或产品缺口。** Sync的解析/投影/队列、Tag/Automation业务状态、Persistence磁盘持久化/恢复与ServiceOrg文档writer仍由实际owner负责。Org parser不属Store漏迁；依九体实际Tag语法职责与Tag顶层常量/已开Org matcher回边，将§4.2原Sync候选修订为Tag唯一owner，避免新增加载平台；该批次收口时仅有只读生产/测试候选，Transform暂留；随后TAG-PARSER按独立工单/GO完成，见下节，未修改词法或删冷负向。旧非默认Index/Canonical入口暂缓、私人old-require/reload兼容、F1/F2/QD/Sibling/调度晚load、GUI/真实用户库/任意hook/崩溃与全恢复矩阵均未扩修。

### V2-TAG-PARSER：共享行内标签解析归 Tag（2026-09-09，已验收）

- **范围与原体**：四常量＋五函数九原form及间隔注释连续归Tag真实header之后、所有旧定义/常量消费/显示接线之前；Tag270−1＋9＝278，其他原form/state/config/tail完整同序。八生产路径中Transform真实删除，其余六consumer仅精确require/元数据调整；Sync仍经原Tag依赖使用同一parser，不增Tag→Sync回边、provider、常量副本或通用层。库存602→601、根29→28；Node/Persistence不因本片反向require Tag，旧轻载时parser立即可达的合同退役，显式首用Tag才承担其原显示/依赖成本，私人旧feature调用未知。
- **旧测试与代际**：storage原48ERT和Tag原74ERT保留；storage只改11个获批literal，STA/STB历史分代、STC7/STD6、旧负向及真实compiled/回调保持，Tag整文件前缀后追加8。TP09/10仅将current已退Transform辅助reload改为require Store，原真实Store reload/EQ/advice/callback观察不动，不称二者reload等价；另实测真正parser owner的require/显式reload、四常量重置与函数cell。独立TP阶段不会把历史before改写为现状。
- **真实运行**：新增八例覆盖非空词法结果、真实Org AST/secondary对象过滤及绝对位置、窄化/point、已开Org普通font-lock、Node/Persistence首载后真实parser调用、require/reload及Sync真实文件级ID/FILETAGS/标题/正文解析。空文件原本零matcher调用如实记录；此新增Sync例是只读解析，真实保存/投影/队列/回滚另由saved-projection、Automation、Link等消费者套件承接。before/current各真实编译provider＋lexical caller，再fresh执行elc及非空Sync解析；其它依赖可仍为源码，不冒全树字节码、GUI或任意用户hook验证。
- **时序与反证校准**：同字节final新before8/8在07:20:27完成，owner/输出/边界红在07:20:29–31取得，完整before十二套558/558于07:24:55结束，均早于迁属且八生产cmp0；随后current8及十二套558/558通过。初版Python运输AttributeError未启动子进程，不算产品红；header观察与compiled清理加强发生在最终输入固定前。独审另跑558/guidance、迁后before8/current8与真实elc。S1仅校准报告：原边界变异连捕获编号一起破坏，实际输出nil而非多匹配；独审另保留group2的单点边界变异，真实多出embedded/fragment并命中原业务断言。旧签名/源码/测试不为措辞改写。
- **最终门与冻结**：root W/E十二套 **558/558**、guidance通过；native隔离HOME full **33 Suite/Ran、1103＝1100通过＋3可选skip**，0unexpected/exit0，含本地Git31/31。before full继承已签STORE-D1095，不冒重跑；完整29→28临时源树、八→七实际受影响编译目标及非空elc，**89→89 Warning正文多重集合相同**，不是全根编译或零警告。code10与加本计划 **final11正逆已完成**，字节/删除缺席及主仓601首尾核验通过；worker398、authority205、父D397保持，签名待文档回执。
- **收口边界**：仅完成此共享Tag语法切口，不重开已闭Store/Tag主体，也不总闭Sync、五横切或v2。该片收口时共享Org身份/模板与ServiceOrg加载切口仅只读准备；随后ORG-A完成加载前置，身份/模板原体仍未迁入，见下节；不改变F1/F2、QD、Sibling、恢复/词法政策、历史套件分类或私人兼容。root `/private/tmp/supertag-tag-parser-leader-300gdw5i/REPORT.md`；worker `/private/tmp/supertag-tag-parser-worker-e58dqhrw/REPORT.md`；独审 `/private/tmp/supertag-tp-independent-b0tqgskg/REPORT.md`。

### V2-ORG-A：共享 Org 加载前置与 R1 冷调用修复（2026-09-09，已验收）

- **范围与依赖**：六源码/测试路径，库存601、根28不变。ServiceOrg撤去Node/Sync/Tag/Query eager导入，保留真实Org/Store宏等依赖，以七个普通autoload/declare和原special声明承接。`--with-node-buffer`在原节点/文件/位置验证后、callback及动态绑定前解析实际Sync provider；Tag bulk在原saver解析后、transaction/create/cell捕获前解析既有header provider。不调用解析器或投影来伪造准备，不增加ready/层或复制writer。Migrate补真实Tag require，保独立非空status/extends读取。身份/模板原体、Org-ID advice生命周期和writer/恢复策略均未迁改。
- **加载变化与旧保护**：ServiceOrg-only不再预载Node/Tag/Query/Sync，真实首用会加载既有闭包，加载错误因此后移；非法节点/位置仍先拒绝，绕行writer已有live ID/dirty等部分状态不擅改。property仅ORGA01独立分代：实际完成事件由Sync→Automation改为Automation→Sync；main源代码require顺序未改，旧AUA/AUB历史和全部冷负向保留。原119ERT＝Tag82＋Migrate16＋property21；原ORG-A追加14，R1再追加1，Tag最终96/Migrate17/property21。R1保故障稳定Tag95整文件前缀，测试债没有夹带清理。
- **R1是实物故障，不是告警整理**：初轮root十二套659/659、full1117＝1114＋3skip仍绿，但正式三目标编译28→26出现新的`org-element-timestamp-parser`未知函数告警。root在真实ServiceOrg-only source及官方elc均于ENTRY后复现void-function；初始独审“无生产必修”因此更新，旧签名报告保留，不拿659掩盖错误。R1仅Dependencies补OrgElement、Org后真实require OrgElement；原timestamp函数及两resolver不改，ServiceOrg65→76→77。正式同一追加ERT先在故障稳定source与新实际elc双红，再在修后双绿；正timestamp为t，非法/range为nil，调用前后仍无Node/Tag/Query/Sync/main。原eager before另以冻结源补跑，明确为迁后复证。
- **证据时序与独审**：初轮最终新14绿与两红早于完整before十二套结束，全部在生产迁属前；worker的repo-before三测试hash是最终业务写前输入，不冒最初TP测试基线，累计before取独立六文件原本。初始夹具/运输失败与R1后处理错误文本括号校准不算产品红。原独审另跑659/14及五项真实分支红；R1独审另跑修后15/15与guidance，同输入故障source/新elc双红、修后双绿和原before补证，累计6/增量2自有回放通过。原659不冒修后重跑；本机Org-ID宿主函数缺席，native wrapper advice真实执行不外推host导航。
- **最终门与正式elc**：root修后同字节W/E十二消费者 **660/660**、guidance通过，覆盖真实Sync保存/投影、Automation/Link/Promote/Move、Migrate/身份/View，不只冷owner控制。native隔离HOME完整 **33 Suite/Ran、1118＝1115通过＋3可选skip**，0unexpected/exit0，含本地Git31。原ORG-A before full沿已签TP1103，故障中间代1117另列。完整28→28临时源树、三→三真实编译目标及非空elc，正式告警 **28→26（故障代）→25（修后）**；最终相对原before少三次既有when-let告警、无新增，不称同集或零告警。root另在fresh进程执行原官方before与最终官方ServiceOrg.elc，三输入均正确；修后Sync仍nil，source哈希不变。该补跑与worker/独审专用编译分列，其他依赖可仍为源码。
- **冻结与后续**：累计code6、R1增量2及加本计划 **final7正逆已完成**，字节/存在性与主仓首尾一致；原worker760、初root315、authority194、TP376和新R1 authority118/worker313保持，最终签名待文档回执。仅收口ORG-A及R1，不总闭共享Org/Sync/五横切/v2，不扩F1/F2/QD/Sibling、日期/恢复政策、GUI/真实库或私人兼容。下一步按用户要求先恢复独立测试债盘点：保现役行为和依赖合同，已闭迁移历史由冻结证据承接；另定精确清理片，不无条件永久保留旧ERT，也不据旧或零caller直接删除能力。身份/模板下一片尚未GO。

root `/private/tmp/supertag-org-a-r1-leader-54lozss6/REPORT.md`；初轮 `/private/tmp/supertag-org-a-leader-2mm1uw8g/initial-stage.json`；R1 worker `/private/tmp/supertag-org-a-r1-worker-wd68o08f/REPORT.md`；R1独审 `/private/tmp/supertag-orga-r1-final-review-22uhp62z/REPORT.md`。

### TEST-STB-A：事务测试只保当前合同（2026-09-09，已完成门与独审）

- **真正减少的维护义务**：仅改 `test/storage-save-boundary-test.el` 三个授权literal；STB program退出五代历史的35处stage读取，固定当前Store/Tag合同。两条已收敛的索引入口合为 `supertag-storage-stb-index-rollback`，较强入口的冷负向和hook-list EQ一并保留；没有把复杂度搬进新helper。STB六例变五例、全文件48变47，另外46旧ERT及child/其它program逐字同序；28生产源码与其余600库存项未变。旧STB历史由原冻结重放，新测试不再负责驱动退休载体。
- **保护没有按“老测试”退出**：真实Store冷负向、预绑定对象/custom hook同tail、require EQ与显式load重定义、native advice及error/quit/nested/部分restore均保留。实际index回滚先检查attempts/completed，再进入lazy查询；新编Store与lexical caller两elc，fresh真正加载并执行，不以macroexpand或文件存在冒充。保留的部分恢复状态只是诊断边界，不是批准理想产品政策。
- **清理前后证据**：root当前生产清理前STB6/6、五消费者275/275；worker清理前6/6、清理后5/5，后五套274/274。独审另跑当前源清理前6/后5及五套274，均为独立迁后复证，不冒旧STB源码或写前运行。前后各三类反证有效：省真实rollback callback在lazy读前红；真load换require命中cell EQ；省provider special声明但保global nil，在两个真实elc加载后由caller报pending，非setup/void-variable，也不声称到达后面的special断言。
- **root最终门**：W/E五消费者 **274/274**，包含实际Sync保存投影/队列与Automation，guidance通过；隔离HOME native完整 **33套、1117＝1114通过＋3可选skip**，0unexpected/exit0，内含本地Git31。before full沿已签ORG-A/R1的1118，一例差额来自重复入口收敛。28源逐字相同，**正式生产编译未重跑**，沿父签名三目标最终25告警；本片另有真实Store/caller新elc执行，二者分列，不写成实测25→25。code1及加本计划final2的正逆回放在文档核对前完成；最终签名待回执。
- **仅闭本片**：不总闭测试债，不改其它STA/STC/STD/Tag/property历史、ORG-A/R1真冷回归或ORGA01；不扩身份/模板、F1/F2/QD/Sibling、GUI/私人兼容或五横切/v2。下一候选STA只读准备与实施GO分开。root `/private/tmp/supertag-test-stb-leader-llewzxw5/REPORT.md`；worker `/private/tmp/supertag-test-stb-worker-lu_nopp8/REPORT.md`；独审 `/private/tmp/supertag-test-stb-independent-W7VPmn5O/REPORT.md`。

### TEST-STA-A：普通通知测试只保当前合同（2026-09-09，已完成门与独审）

- **范围与收益**：仅storage中一个授权program literal，14解码规则共18匹配，退出STA/STB/STC/STD/TAG_PARSER五代35处stage读取，固定当前Store/Canonical合同；连同literal内一行旧节注释删除，不是额外函数改动。实际after program422、child424、七ERT459起；worker沿before行号的轻微偏移不改源码。七STA/全部47ERT、child和其它62form逐字同序，已清理STB五例及其它program完整保持；没有为了减用例数删保护或新造helper/stage。28生产和测试外600库存不变。
- **现役保护与反证**：预绑定state的EQ/equal原强度、require EQ/真正Store load、native advice、跨reload旧closure、普通通知重复/退订/error/quit、抑制/事务/Canonical及实际新elc均保留。light两次off间无emit，不单独证明第一次即时移除；notifications/compiled一次off后真emit另承接。五类反证前后各六次有效：off两case真实输出红、preset载入后EQ红、load→require身份红、Store成功ENTRY后Org冷负向红、两真实elc加载后caller报pending missing。后一项非setup/未绑定，不套前片pending，也不声称已到后面的special lost。
- **分代与最终门**：root当前源清理前STA7/7、五消费者274/274；worker前后STA各7、改后五套274/guidance，before五套明确引用root；独审另跑前后7及五套274、前后五类反证，属于迁后复证。root改后W/E五消费者 **274/274**、guidance通过，覆盖真实Sync保存投影/队列与Automation；native隔离HOME完整 **33套、1117＝1114通过＋3可选skip**，零unexpected/exit0，内含本地Git31。before full沿已签TEST-STB-A1117，不冒本片重跑。
- **编译与冻结边界**：28生产源全同，正式生产compiler未重跑，沿ORG-A/R1三目标最终25警告；另实际新编Store/caller并fresh加载执行，原caller业务前后同hash，不等同全树编译。worker498/authority53/baseline61/父179首尾核验，code1及加本计划final2已在文档核对前完成正逆；最终签名待回执。不总闭测试债或v2，不改通知/恢复政策、ORG-A/R1/ORGA01或其它候选；下一D7仅只读准备。root `/private/tmp/supertag-test-sta-leader-pynedl3b/REPORT.md`；worker `/private/tmp/supertag-test-sta-worker-ia9yumpv/REPORT.md`；独审 `/private/tmp/supertag-test-sta-independent-hVm7Gnsg/REPORT.md`。

### TEST-D7-A：标签写格式冷测试去重（2026-09-09，已完成门与独审）

- **三literal、保强入口**：仅Tag测试的D7 loader、reload列表和第二ERT改名/去重复调用。两处VWB历史读取归零；当前较弱api/nil调用由原tag/nil承接，后者额外保feature/history、DB未创建及Query autoload负向。Tag五preset与Sync/both不合并，两个ERT/全文件96ERT不变，fresh child七→六；95其它ERT、127其它form、真实query/facts/d7-check/cleanup逐字同序。不是删公开API或重做嵌套标签UX，28生产与其余600库存项不变。
- **当前合同边界**：parent真实Org投影夹具与fresh child分开，child本来预载Org；Tag冷负向在装快照及真实查询前，Sync-first可已热Query。四次真实p/c/g/p与missing/empty读取、Store facts相等、准确Query owner、Sync→Tag两次真实load及单注册均保留。DB缺席只证查询前，不冒reload全程零磁盘；此测试没有函数cell重定义合同，不要求load→require必红。四style真实writer及原ORG-A/R1 source/elc另由原套件保护。
- **两代实证与最终门**：root当前清理前两ERT/七child及六套202/guidance通过；worker亲跑前两/七、后两/六及after六套202，before六套准确引用root。独审另跑两代和六套202，默认preset正控与四类反证均独立复证：ENTRY后配置值红、实际eager Query后冷负向红、真实p对impossible期望红、首Tag load正常/第二次load后重复group计数红。root改后W/E六套 **202/202**、guidance通过；native隔离HOME完整 **33套、1117＝1114通过＋3可选skip**，零unexpected/exit0，内含本地Git31；before full沿已签STA1117，不冒重跑。
- **冻结与限度**：code1及加本计划final2在文档核对前已实际正逆，worker354/authority51/baseline7/父191首尾通过，最终签名待回执。正式production compiler未重跑，28同源沿ORG-A/R1三目标最终25；原R1源码/实际elc在Tag门继续执行，不冒D7新增compiled矩阵。工具UTF-8摘要与猜错日志名不算产品红；只闭本片，不总闭测试债、F1/F2或v2，property候选仅只读。root `/private/tmp/supertag-test-d7-leader-0huowm2m/REPORT.md`；worker `/private/tmp/supertag-test-d7-worker-iqvvjqfn/REPORT.md`；独审 `/private/tmp/supertag-test-d7-independent-aKm6JsSC/REPORT.md`。

### TEST-PROPERTY-A：事件／调度测试只保当前合同（2026-09-09，已完成门与独审）

- **精确范围**：仅property-consumers三个整ERT literal，退出旧adapter-only、Scheduler-only及手工注册补偿分支；21ERT/31form与三个独立child不减，18其它ERT/28其它form、共同child和整个ORGA01逐字同序。指定三例AUB读取3→0，全文件6→3；AUA/ORGA、main-order及JSON剩余历史保持，不称全部阶段清零。28生产及其余600库存项原样，没有新helper、stage或产品改动。
- **当前合同与反证**：保真实首载init/subscription、预绑定registry和adapter、require EQ、实际timer及第二次load、非空tick、捕获旧runner在update后读新actions、disable/delete和原错误边界。五类六探针在清理前后均有效：省init注册先命中functionp，不冒tick输出红；另省实际funcall才在真实tick后输出nil；旧actions快照在实际update/旧runner调用后出old而非updated，不冒后续disable/delete故障矩阵。registry EQ、batch7与第二次真实load订阅2分别红。共享child原先预载Org，调度call-function不代Org writer；原aua-dynamic-write及Sync保存投影/队列、Vault消费者另实跑。main晚load无补注册仍保留，不借清理修调度政策。
- **证据来源与最终门**：root写前当前源三例3/3、七消费者355/355；worker亲跑前后各3/3及改后七套355/guidance，写前七套明确引用root。独审另跑355、迁后两代各3及六探针，非重新经历写前。worker初版stale私有括号错误在ENTRY前，排除；有效stale-r1先于实际测试修改。root未执行的lexical-let隔离稿与工具读取/audit错误另留，不作产品红。root改后W/E **七套355/355**、guidance通过；native隔离HOME完整 **33套、1117＝1114通过＋3可选skip**，零unexpected/exit0，内含本地Git31；before full继承已签D7，不冒本片写前重跑。
- **冻结与限度**：code1及加本计划final2在文档核对前已实际正逆，worker579、authority66、baseline40、准备纠偏3及父D7 108首尾通过，最终签名待文档回执。正式production compiler未重跑，28同源沿ORG-A/R1三目标最终25；原消费者中的专用elc/动态控制仍执行，不冒本三例新增compiled矩阵或实测25→25。只闭本片，不总闭测试债/Automation/v2，不扩field、F1/F2/QD/Sibling、GUI或私人兼容；下一D8仅只读候选。root `/private/tmp/supertag-test-property-leader-kwwt_du4/REPORT.md`；worker `/private/tmp/supertag-test-property-worker-26zgvfc4/REPORT.md`；独审 `/private/tmp/supertag-test-property-independent-soKPANeN/REPORT.md`。

### TEST-D8-A：Tag adapter 冷测试退出退休载体历史（2026-09-09，已完成门与独审）

- **范围与收益**：仅Tag测试七literal，D8 helper固定现役Node-first/Tag-first、Framework颜色owner及ServicesUI→Tag reload，最后一个ERT准确更名node-first。D8内VWB3/VWC2/VWD3共八stage读取退出，四ERT/四child全部保留；129form/96ERT不变，95其它ERT/127其它form、已签D7及R1逐字同序。不是合并Node-first与Tag-first，也不是删除formatter/旧公开符号；28生产与其余600库存项不变。
- **保留当前合同**：Node实际load后ENTRY和Tag/helper/Framework未载检查仍在child requireTag/snapshot之前；parent已真实写Org/reindex，二者不混。三个Tag-first保完整feature/history/DB/autoload负向；真实Query canonical/stable/alias、empty的muted、nonempty的emphasis/border及完整文字属性、Store facts/disk均保留。三个getter owner不冒每case实际调用三者；facts/disk检查不扩大至后续reload全生命周期。ServicesUI→Tag两个真实load/每次owners与cleanup不变，不新增Node reload或cell身份合同，child原Org预载/图形seam不冒GUI。
- **前后与反证来源**：root写前四例/四child及七420通过；worker亲跑前后各4、改后七420/guidance，写前七套准确引用root。独审另跑七420、迁后冻结前后各4及各五探针。Node eager在ENTRY后原冷负向红；缺emphasis在真实formatter调用及Framework END1后autoload失败，缺border因第二次兑现为END2，不是单次void-function或元数据前置红。另真实非空正文相同而face颜色不同、真实Query返回canonical对impossible期望均红。未运行只省Tag autoload方案，不冒其mask已实证；无setup红计入本片有效证据。
- **最终门与冻结**：root W/E **七套420/420**、guidance通过，覆盖真实Node/Link/Sync保存投影与Framework消费者；native隔离HOME完整 **33套、1117＝1114通过＋3可选skip**，零unexpected/exit0，内含本地Git31。before full沿已签PROPERTY，不冒重跑；原D7六child与R1 source/elc在Tag门继续通过。28源同字节，正式production compiler未重跑，继承ORG-A/R1三目标最终25，不新测25→25或冒D8新增compiled矩阵。code1及加本计划final2在文档核对前已实际正逆，worker451/authority58/baseline7/父185首尾通过，最终签名待回执。
- **只闭所列切片**：首五测试债建议已有逐片实施与独审，D8最终签名仍待此文档回执；不代表三个文件所有历史或整仓测试债清空。有限只读收据 `/private/tmp/supertag-test-five-closeout-v6fjcot8/REPORT.md` 只核冻结文本，未重跑各片；所列property JSON单条件仅后续候选，非GO。不扩F1/F2/QD/Sibling、writer/调度/恢复、私人兼容、身份/模板或整个v2。root `/private/tmp/supertag-test-d8-leader-ezy0qp4z/REPORT.md`；worker `/private/tmp/supertag-test-d8-worker-1s729po8/REPORT.md`；独审 `/private/tmp/supertag-test-d8-independent-NRe0fDtK/REPORT.md`。

### TEST-JSON-A：退出一个退休 Scheduler 测试条件（2026-09-09，定向验收完成）

- 仅 `property-consumers-test.el` 一个 literal；AUB读取3→2，31form/21ERT与目标JSON/timer正文保留，其它30form/20ERT、共同child、ORGA01及main晚load原样。生产28源不变。
- 按用户风险分级要求，必要门采用worker已完成的 **property-consumers 21/21**，目标真实JSON/timer流程至ENTRY/DONE。root核精确目标hash、全文单行差异和运行证据，不重复测试、全套、编译或另开独审/文档轮。增补到达前已完成的七套355、guidance及两代JSON错期待红只记实际额外证据，不作为小改强制门；父D8 full1117及ORG-A/R1编译final25仅继承。
- 测试及本计划的可逆diff保存在root；最终回放/验收见 `acceptance.json`。只闭此条件，不清空property历史或全部测试债，不恢复身份/模板迁属。root `/private/tmp/supertag-test-json-leader-5br3mnq2/REPORT.md`；最终交接 `/private/tmp/supertag-test-json-handoff-gj0_ue5_/REPORT.md`。

### ORG-IDENTITY：共享身份/定位归 ServiceOrg（2026-09-09，定向及分段全门完成）

- 13函数＋group/custom共15原form原样迁入ServiceOrg，旧identity carrier退役；八生产精确接线，无新增provider、不改locator/Sibling、writer或现有Org-ID生命周期。Node/Tag/Link首载更早加载ServiceOrg/Template/Vault；私人load/advice兼容未知，不称零副作用。
- 七测试28精确映射及identity新增两ERT；D1改为真实尚冷Sync解析失败，精确命名错误/hit1/create0/事务nil及零写保留，不冒称旧saver首次加载合同等价。Framework首次ServiceOrg tuple实测；R1 source/elc与真实写链保留。Org-ID控制是宿主函数存在性seam＋native advice，不称本机缺席的Org命令实跑。
- worker写前268、迁后定向298及guidance通过。root接收162签名及十五路径回放；整树临时正式编译before28/after27目标均exit0、123→123相同告警正文多重集，与历史局部25不同口径。
- root全门发现两处遗漏：Promote cb-owner仍禁ServiceOrg；Git-only原禁Template且预期capture不可用。前者仅修当前表达式；后者新增第16测试路径，两处当前预期调整，保历史VC与所有真实clone断言。Git→Node→ServiceOrg→Template/Vault提前可用使原可选capture分支执行，已实证本地clone capture恰一次、磁盘/Store/重建及稍后main不重复；这是兼容变化，不仅owner改名。源码未返修。
- 默认33套以三段日志完成：第一次至Promote失败、修正后从Promote续至Git失败、最后Git31/31。合计 **1119=1116通过＋3可选skip，0unexpected**，不是一次整批全绿；未重复已通过套件。原失败日志保留。最终16源码/测试路径＋本计划的累计回放与签收见root验收文件；仅收口身份迁属，不总闭共享Org/v2。下一项为共享模板，不处理测试债或产品缺陷。

root `/private/tmp/supertag-org-identity-leader-vx5egj5s/`；worker `/private/tmp/supertag-org-identity-worker-npvaz5vx/REPORT.md`。

### ORG-TEMPLATE：共享创建模板归 ServiceOrg（2026-09-09，验收完成）

- 五生产路径、九原form（七函数＋group/custom）原样迁入ServiceOrg，旧Template无壳退役；Node provider接线及Link/Concept冗余require精确调整。五测试11个具名form映射，未新增或删除ERT；原模板策略、writer、locator、身份/ORG-A/R1及Vault/main准备时点保持。
- 明确接受旧Template-only轻载退役：ServiceOrg入口建立Store默认状态、加载Org并触及原Org-ID注册；显式reload成本不等价，私人回调兼容不外推。真正Vault-only轻载不变。候选fresh前后hook差异由不含项目的builtin Org/element/id正控精确解释；仅模板分支在builtin准备后取项目加载快照，独立真正fresh事实仍保留，不称整体无副作用。
- worker写前模板16/16、ENTRY旧owner红；稳定五消费者355/355＋Promote/identity/ORG-A R1具名19/19、guidance通过，root复用不重复。root一次默认33套 **1119=1116通过＋3可选skip** 全通过；两完整临时源码树正式编译 **27→26目标，123→123同告警正文多重集**。worker报告root源码28→27为计数口径偏差，以实际root *.el目标清单27→26为准，不与局部编译25混用。
- root独立核173签名、主仓十路径与正逆字节/absence，最终十源码/测试＋计划十一累计回放见验收文件。仅关闭模板迁属；共享Org并非全部v2完成，ServicesUI残留/注册和剩余边界继续处理。F1/F2/QD/Sibling/Automation晚load不扩修。

root `/private/tmp/supertag-org-template-leader-kga9mhmw/`；worker `/private/tmp/supertag-org-template-worker-rh6vo6fs/REPORT.md`。

### SERVICES-UI：残余适配与 Node 条件准备（2026-09-10，验收完成）

- **范围与归属**：两原体 `supertag-ui--adjust-content-level` / `supertag-ui--sanitize-type-input` 分别原样归 ServiceOrg / Framework，ServicesUI无壳退役；Node承接单一prepared位及可选listener准备。10生产＋8测试＋runner单literal，共19路径，另root更新本计划共20路径。现有ERT与suite分类不变；四新增positive保护absent/late/reload、error/quit与两adapter合同。
- **最小加载接线**：Framework/Concept各Query→Tag→Sync→prepare，NodeView Query→Sync→prepare；main/Embark通过此前依赖保证、不重复接线。共三处prepare、八行显式项目require；Node尾部不调用、不反向加载Framework。普通成功一次，provider缺席亦完成，forced重复同callback；首次error/quit不置位，已完成后forced失败保留完成，reset仅清缓存。仍是provider存在性seam，不是native Store订阅，不声称修复自动失效；旧ServicesUI require/load兼容退役，显式重复准备改用Node接口。
- **精确测试修订**：按当前positive消费者映射，保negative与历史分支。root恢复候选遗漏的D8首项 `d8-owners`，prepare后与真实Tag reload后各检查一次，仅三段映射去冗余progn/局部缩进。运行时核manifest发现三个新Node ERT名不匹配原 `^supertag-node-feature-`，root只修这三个新增名字、body不动，不改suite；已选旧列表的全门不重启，另实跑新增3/3，Framework第四项在其44项套件中通过。
- **真实验证与编译**：worker精确9form的7controls、17Elisp reader与runner bash-n通过并复用；随后7独立完整项目冷进程全部通过：Node-only不prepare，完整Node reload保nil/t与cache/stamp identity；Framework/Concept/NodeView首载准备，main经Framework、Embark经NodeView普通once，absent→late不补注册、forced两次同callback。内建Org已预载、项目feature冷，不外推为无内建预载。root核25生产SHA与cold/编译快照一致；完整临时树正式编译 **26→25目标、两边exit0、123→123同告警正文多重集**，主仓不生成elc。两边相同的compile harness lexical-binding提示单列，不混入项目告警。
- **默认全门分段完成，不冒一次全绿**：33套当前 **1123=1120通过＋3可选skip**。首次contract142/143，一项真实save-hook队列断言红；同环境before/after都红，仅把TMPDIR由 `/var/folders` 别名换成规范 `/private/tmp` 后两边具名测试都绿，复用其余142。续至add-link89/92，三例直接native子Emacs绕过EMACS_BIN的-L而缺ht；补继承EMACSLOADPATH后具名3/3绿，产品/断言零改，继续余套至Git31绿。上述三个新增Node ERT另实跑计入总数，entrypoint反证另补exit0。初次失败日志保留，不重跑已绿全套；现有Sync scope路径别名边界另记、不顺修。
- **依赖与隔离**：旧tmp候选/验收附件/依赖缺失，前片只由交接与计划继承，未冒复验旧签名。用户明确授权读取nova-emacs下两依赖，root只复制straight/build的ht.el/dash.el到tmp并记SHA，未加载配置或真实库、未联网安装。非Git用拒网sandbox/tmp HOME；Git用native隔离HOME、global=/dev/null、nosystem、file-only，不冒拒网Git或真实远端。隐藏curl存在性对应可选服务跳过，不冒真实服务覆盖。
- **收口边界**：root20路径含计划最终正逆字节/absence回放与回执完成。仅关闭本片；Menu函数体require、Sync/Persistence归属审计及最终横切仍待推进，整个v2未完成，F1/F2/QD/Sibling/Automation晚load不扩修。

root `/private/tmp/supertag-services-ui-leader-skmfksfb/REPORT.md`；worker `/private/tmp/supertag-services-ui-worker-ss1ZkPIF/REPORT.md`；真实cold `/private/tmp/supertag-services-ui-cold-zk1OqB4d/REPORT.md`。最终20路径以root `final-scope-map.json` 为准；worker最终候选与原修订候选保留未覆盖。

### MENU-LAZY：菜单原生惰性接线与 require 豁免退出（2026-09-10，验收完成）

- **精确范围**：Menu macro/说明、静态门唯一marker豁免删除、contract追加新menu-lazy-test、新测试文件，共4路径；root计划更新共5路径。32个wrapper声明到文件末尾逐字保留，全部按键、wrapper命令名、参数与 `call-interactively` 保持；31个现役target可定位，唯一缺失的tag-ID迁移module/target不顺修。
- **实现与收益**：wrapper首次调用时仅target未绑定且owner未provide才登记原生autoload，由call-interactively触发加载；Menu-only/完整Menu reload不预建业务target绑定、不加载业务owner。消除函数体require及唯一静态豁免，不以load或新loader平台绕规则。保原prefix/返回值、原loader error/quit传播、owner已provide且target未绑定时unavailable。
- **明确接受的接口取舍**：已有函数/alias/autoload优先，不再强制canonical owner加载或覆盖已有stub；cold文件不定义target时接受native failed-to-define错误及stub/retry状态，不做消息匹配转换；定义target但未provide owner可由autoload成功，缺文件仍file-missing但留下stub。不是声称require与autoload完全等价，不为坏provider兼容增加新状态或吞错误。
- **风险比例验证**：worker新增7项实际ERT＋13具名真实Menu消费者 **20/20、0 unexpected、两组exit0**，无返修，root复用。Query menu-add/menu-build/menu-syntax三child均实达ENTRY/DONE/PASS；Node/Tag/SVG/Automation/Vault/Sync现役控制保留。Discovery项是既有target stub合同，不冒实际全业务。root当前静态O门exit0；完整临时树正式编译 **25→25目标、123→123同warning正文多重集、两边exit0**；另真实compiled Menu→compiled Query语法窗口/完整Menu reload保target identity/已provide缺命令unavailable，1/1通过。主仓无elc，不重跑ServicesUI全门或旧native probe，不把本片定向20项冒全仓运行。
- **收口与剩余**：root5路径含新建缺席的精确正逆字节回放及签名回执完成。Menu函数体require包关闭；Sync余通用遍历/查询/导出、Persistence UI/recovery仍需归属审计（可保原位），后续横切/入口/header/计划整体验证尚未完成，整个v2不关闭。F1/F2/QD/Sibling/Automation晚load及缺失迁移菜单均不扩修。

root `/private/tmp/supertag-menu-leader-8s7zzfwp/REPORT.md`；worker `/private/tmp/supertag-menu-worker-qAnEalRy/REPORT.md`；原候选 `/private/tmp/supertag-menu-candidate-YSuoVMWy/REPORT.md`。最终含计划以root `final-map.json` / `final.diff` 为准。

### SYNC/PERSISTENCE-OWNERSHIP：余 helper 与恢复权限归属（2026-09-10，审计完成、保原位）

- **两包结论**：36个主审符号、17个冻结输入；root核当前/冻结SHA一致，并抽查Sync导出/遍历和Persistence改名/持锁恢复路径。没有值得实施的迁属候选，生产/测试改动0、项目测试/机制probe/编译/门执行0；仅root记录本计划，不为保留现状再跑门。
- **Sync保留**：活 `supertag-traverse-nodes` 供validate/GC/relations/reference-cache投影写链，含:type过滤、nil callback槽和GC安全阈值影响，不作为无策略Store工具迁出；公共collection traversal、condition查询及import/export无已识别外部root caller不等于API可删。整文件Org导出和生成helper仍为Sync文档投影权限，Query只供文件查询；不迁入Query/Framework/Persistence，也不冒无损roundtrip。
- **Persistence保留**：默认/legacy目录判定、comparison、启动IO前阻止、精确rename确认/error逆序回退，与快照枚举/解析、持锁prerestore/替换加载、accept-fresh授权、origin/save guard及backup rotation保护是同一恢复责任链。Doctor负责呈现与调度，不取得改名/替换/锁算法；不因含UI而拆到Framework，不把目录冲突恢复混成Vault选择或schema migration。
- **明确限制**：traverse-collection的 `collection_path` 拼写问题仅静态记录，condition保nil槽；rename只捕error非quit，restore替换后load失败靠prerestore恢复点、不冒全故障原子回滚。refuse-save当前未识别caller，save实际message skipped；db-inspect原始reader、旧内存backup/restore不是现役disk恢复合同。默认测试明确排除的恢复项不冒最近全门已执行，未知第三方/动态调用未扫描。上述问题及路径别名均未修/删/迁。
- **结构状态**：这两个已批准归属审计包关闭，保留项有明确owner与风险，不是继续暂挂迁属。最终横切/入口/header/计划与整体验证仍待完成，整个v2尚未收口。

worker `/private/tmp/supertag-ownership-audit-kqOQTO1z/REPORT.md`；36符号表 `ownership-map.json`，输入 `input-map.json`。root回执 `/private/tmp/supertag-ownership-leader-6x6ysodn/REPORT.md`。

### FINAL-CLOSEOUT：最终横切、入口/header与整体验证（2026-09-10，v2结构目标完成）

- **覆盖与归属**：当前25根生产文件＝5横切＋19特性/适配入口＋main，全部具明确owner，当前维护落点见§7.1。基线51→当前25是本计划累计整理口径；最终片自身25→25、无新增/删除生产文件。reader清单213个require均顶层、函数体require0、真实命名实现owner重复0；autoload/declare/prepare/template与可选能力按真实加载时点区分，不把声明或保留旧API名当重复owner。main三函数保装配/启动诊断，无待迁业务carrier或新通用层。
- **最终精确范围**：19生产路径的header/comments及三处reader可见元数据；其余6根文件原样。两处docstring改真实Vault/Store owner，Embark remove-tag声明来源ServiceOrg→Tag，参数及实际require/autoload/prepare/hooks/命令不动。Framework说明经root纠正为Node由Tag带入、prepare仍在Sync后。main effective-sync-directories cookie仍指必要prepare入口main，缺迁移target/明确历史来源/兼容恢复说明保留。root另外修test/README现役runner说明及本计划，共21路径；历史virtual-column guide不改。
- **行为不扩张**：before-root与最终after-root精确归一化上述三个元数据后 **25/25 reader forms一致**；无业务执行体/测试断言/选择器变化。无需为header多跑cold，复用ServicesUI7真实项目cold/reload与Menu20定向/compiled路径的已验收合同。旧Sync/Persistence两审计的保原位结论承接，不再开迁属。
- **最终一次默认完整运行**：`bash test/run-tests.sh` 单次完成全部 **33套，1130=1127通过＋3可选skip，0 unexpected，exit0**；Menu7与修名前缀后的Node3均由当前manifest实际选择，不是拼接旧suite计数。runner反证在同次执行中PASS；`--guidance` 含静态O门、文档链接/命令/CI入口检查，exit0。52个manifest/测试/runner验证输入哈希在完成时核对未变。
- **正式编译与唯一排版返修**：完整临时源树25→25，两边exit0。首轮123→123但告警正文不等：旧Store docstring过宽消失，新Persistence primary-owner行过宽新增；root仅将该新增docstring句子换行，重做最终after完整编译并复用before，最终 **123→122，新增告警0、只减少1条旧docstring过宽**。原首轮证据保留；换行不改执行体，最终25文件精确元数据归一化再次PASS。全门期间这一docstring换行不改变所测代码路径，不为排版重启全门；最终正式编译与source哈希以换行后为准。
- **隔离/证据口径**：仅复用用户授权的nova-emacs ht.el/dash.el临时源码及SHA，不加载私人配置/真实库、不联网安装。canonical TMPDIR、独立HOME/CFFIXED/XDG、EMACSLOADPATH使native子Emacs继承合法依赖；非Git进程拒网，Git为native临时本地仓、global=/dev/null、nosystem、file-only，不冒真实远端/拒网Git。三skip分别为可选Embark完整集成、AI Runtime、Semantic真实endpoint；不冒GUI/模型/版本矩阵覆盖。旧已丢失tmp历史签名只按交接/计划继承，不冒重新验签。
- **最终收口**：root核最终25源码/21改动路径、精确diff与新增行空白，21路径正逆字节回放和compact签名回执完成；只在tmp回放，不还原主仓，不stage/commit。§7结构完成条件满足；F1/F2/QD/Sibling/Automation晚load、Sync collection typo/条件nil槽/路径别名、恢复error/quit与prerestore边界、缺迁移菜单、测试债及未知私人旧require等仍独立保留，结构完成不等于这些产品问题消失。

最终root `/private/tmp/supertag-v2-final-leader-73hgnsbu/REPORT.md`，验收 `acceptance.json`、默认门 `final-gates-summary.json`、编译 `compile-summary.json`、最终21路径 `final-map.json` / `final.diff`、`RECEIPT.sha256`。worker覆盖候选 `/private/tmp/supertag-final-map-5uduWSiU/REPORT.md`；实际实施 `/private/tmp/supertag-final-apply-3N9rSdOK/REPORT.md`，两者保留，root最终docstring换行单列、不覆盖旧冻结。

## 9. 用户新增补全问题：记录后单独讨论，不打断结构迁属

2026-09-07，用户要求先记录、不马上打断当前实现。以下是待讨论/定向复核项，**不是本轮新增实现授权，也不是 D3 新回归结论**。

- **F1：为什么 `#` 的首次补全加载 Link？** 当前共享 CAPF 为 Link→Tag，Link 的语法检查位于其 provider 内，故首次调用先加载 Link 才拒绝非链接前缀；旧 completion 则更早直接 require Link。D3 已实测并保留此边界。后续再决定是否需要按语法分别触发加载，不据此立即交换优先级、拆 mode 或新增 dispatcher。
- **F2：原来的嵌套标签补全体验为何看似消失？** 旧计划决定 14 的 4e 已将 `:extends` 继承改成由标签名的 `/` 路径推导，完整路径名及无隐式父实体能力仍在；稳定 ID/别名并未因此全部移除。旧测试记录过“搜叶名、展示父路径”等交互，当前补全候选采用完整规范名，这个变化早于 V2-D3。**简化层级存储不必然要求取消层级友好的补全。** 待明确用户想保留的叶名搜索、父路径浏览/续选与创建方式后，在现路径模型上定向复核；区分 basic 前缀与实际补全前端配置，不将历史非默认测试当当前失败证据，也不擅自恢复 `:extends` 或裁定 ID=名。

来源与边界：旧 `PLAN_CN.md` 决定 14/模块 C；D3 开工前冻结的 completion、当前路径契约测试与历史 `tag-path-test`，详见 leader `FOLLOWUPS.md`。上述历史追溯没有读取用户配置/真实库或重跑历史套件；无实体父路径查询域等既有问题仍按 §3 独立处理，不夹带进搬文件工单。
