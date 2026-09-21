# PR/FAQ：将 Org-Supertag 彻底迁移为 Supertag

- Status: Approved by user
- Date: 2026-08-19
- Scope: Emacs 包、公开接口、数据目录、Query Block、文档、本地目录与 GitHub 仓库的破坏性改名
- Non-goal: 本文定稿前不创建 phase、不拆任务、不修改代码、不操作 GitHub 仓库

## Press Release

### Supertag 以一个名字提供完整的个人语义知识系统

**从 6.0.0 起，项目、Emacs 包、公开接口、数据目录和 GitHub 仓库统一使用 `supertag`；旧的 `org-supertag` 名称不再作为兼容入口保留。**

Supertag 用户不再需要记住两套名字。安装声明使用 `supertag`，Emacs 加载 `(require 'supertag)`，配置变量和命令使用 `supertag-*`，Org Babel 查询语言使用 `supertag-query-block`，公开仓库位于 `yibie/supertag`。

### 问题

项目最初以 Org-Supertag 命名，但功能、命令和内部模块已经大规模迁移到 `supertag-*`。当前入口文件、少量配置变量、Customization Group、Query Block、文档、默认数据目录和 GitHub 地址仍保留旧名。

这种混合状态让用户无法凭一致规则推断安装方式和接口名称，也让文档、测试和后续 Agent 集成持续承担双重命名成本。继续添加兼容别名只会把一次明确的改名变成长期维护负担。

### 解决方案

6.0.0 完成一次明确的破坏性改名：

1. `org-supertag.el` 改为 `supertag.el`，只提供 `(provide 'supertag)`；
2. 所有仍在使用的 `org-supertag-*` 公开变量、模式、Group 和 Babel 接口改为 `supertag-*`；
3. 默认数据目录从 `~/.emacs.d/org-supertag/` 改为 `~/.emacs.d/supertag/`；
4. 安装说明、示例、测试、注释和用户文档统一使用 Supertag；
5. 项目本地目录改为 `supertag`，GitHub 公开仓库改为 `yibie/supertag`；
6. 不保留旧入口文件、变量 alias、命令 alias、旧 Babel 语言名或无操作兼容模式。

破坏性改名不等于允许数据风险。如果启动时只发现旧数据目录而没有新数据目录，Supertag 必须停止初始化并给出明确迁移说明，不能静默创建空库，让用户误以为数据已经丢失。

### 负责人引语

> “项目已经在实际使用中成为 Supertag。与其让新旧名称长期并存，不如在 6.0.0 正式建立唯一词汇，让用户、文档、代码和未来的 Agent 都只需要理解一个产品。”

### 产品如何工作

升级前，用户退出所有正在使用 Supertag 数据库的 Emacs 实例并备份数据目录。随后将旧数据目录显式改名为 `supertag`，更新包声明、`require`、配置变量和已有 Query Block，再安装新版本。

升级完成后，知识数据格式和 Org 节点内容保持不变；改变的是项目身份、加载入口、配置接口和承载数据库的目录名称。

GitHub 仓库只在代码、测试和公开文档已经使用新名称并成功推送后改名。改名完成后，本地 `origin` 更新为 `git@github.com:yibie/supertag.git`，再验证拉取与推送均使用新地址。

### 用户引语

> “升级时我只需要按迁移清单改一次；升级之后，安装、配置、命令和文档都叫 Supertag，不再需要判断哪里还应该加 `org-`。”

### 如何开始

用户按照 6.0.0 迁移说明备份数据、改名数据目录和更新 Emacs 配置，然后从 `yibie/supertag` 加载 `(require 'supertag)`。

## FAQ

### Customer FAQ

#### 1. 这是兼容改名还是破坏性改名？

是破坏性改名。旧的 `(require 'org-supertag)`、`org-supertag-*` 配置变量、旧 Query Block 语言名和兼容模式都会失效。

迁移指南会列出需要替换的公开名称，但运行时代码不提供旧名兼容层。

#### 2. 为什么不保留一个版本的 alias？

本次改名的目标是结束双重命名，而不是把它隐藏在兼容文件里。保留 alias 会继续扩大测试矩阵，也会让外部插件和新文档继续依赖已经弃用的接口。

6.0.0 本身就是适合承载破坏性变化的主版本边界。

#### 3. 原来的数据库会自动搬到新目录吗？

不会自动搬动。数据目录包含数据库、同步状态、备份和可能正在使用的锁文件，后台移动存在覆盖或并发写入风险。

用户必须先退出相关 Emacs 实例并备份，再把 `~/.emacs.d/org-supertag/` 显式改名为 `~/.emacs.d/supertag/`。如果程序发现旧目录存在而新目录不存在，它会停止并显示这一步，而不是启动空数据库。

#### 4. 数据库格式和 Org 文件内容会改变吗？

不会因为改名再次改变数据库实体格式。现有 Tag、Field、Relation、Node ID 和普通 Org 内容保持不变。

Org 文件中使用旧 Babel 语言名的源码块属于公开接口引用，需要改成 `supertag-query-block`。

#### 5. 现有 Emacs 配置需要修改什么？

至少需要修改：

- 包名与仓库地址；
- `(require 'org-supertag)`；
- 仍以 `org-supertag-*` 命名的配置变量；
- 旧兼容模式；
- `org-supertag-query-block` 和 `org-supertag-query` Babel 语言名；
- 写死的旧项目目录或数据目录路径。

最终迁移指南以代码盘点结果为准，不依靠这份概览作为完整替换清单。

#### 6. GitHub 旧地址会怎样？

仓库改名后，以 `https://github.com/yibie/supertag` 为唯一公开地址。是否存在 GitHub 自动重定向不能作为产品依赖；README、安装声明、徽章、贡献指南和本地 remote 都必须改到新地址。

#### 7. 本地 checkout 目录也会改名吗？

会。仓库根目录最终从 `org-supertag` 改为 `supertag`。测试和文档不能依赖开发者机器上的旧绝对路径。

### Internal FAQ

#### 8. 可以直接全局替换 `org-supertag` 为 `supertag` 吗？

不能只做盲目字符串替换。`rg` 用于建立完整清单和最终审计；机械文本可以批量替换，但以下情况必须分别处理：

- 主入口文件的加载与 `provide/require`；
- Lisp 符号、Customization Group 和 obsolete 标记；
- Org Babel 语言名及执行函数；
- 默认数据路径和旧目录检测；
- GitHub URL、本地绝对路径及文件名；
- 历史说明中需要保留旧名称以解释迁移的段落。

#### 9. 哪些旧名称允许在完成后继续出现？

运行时代码、当前文档示例、测试入口和安装说明中不允许继续出现旧名称。

只有迁移指南、Changelog 和解释历史版本的测试夹具可以明确提及 `org-supertag`。最终 `rg` 结果必须逐条落入这个白名单，不能只检查匹配数量。

#### 10. 如何防止把用户看到的旧数据目录当成空知识库？

初始化新默认目录之前，检查旧默认目录是否存在。当旧目录存在且新目录不存在时直接报错，提供备份、退出其他 Emacs 实例和目录改名步骤。

如果两个目录同时存在，程序不猜测哪个才是真的，要求用户显式设置 `supertag-data-directory` 或整理目录后重试。

#### 11. 如何处理当前工作树里的既有修改？

现有修改全部视为用户工作。重命名不得恢复、覆盖或顺手格式化这些文件；机械替换触及同一文件时，需要在替换后检查原有 diff 仍然存在。

不处理与改名无关的未跟踪文件，也不对压缩包等二进制内容执行替换。

#### 12. GitHub 仓库应该在什么时候改名？

最后改名。

先完成本地代码与文档迁移、通过质量门、提交并推送到旧仓库；然后执行 GitHub 仓库改名、更新本地 remote，再次拉取与推送验证新地址。这样公开仓库不会在迁移中途呈现入口和文档互相矛盾的状态。

#### 13. 如何验证迁移完成？

最小验证路径包括：

1. 全新 Emacs 进程可以从 `supertag.el` 执行 `(require 'supertag)` 并完成初始化；
2. `(require 'org-supertag)` 和旧公开变量不再由项目提供；
3. `supertag-query-block` 可以执行，旧 Babel 语言名不再注册；
4. 新数据目录可以正常加载、保存、备份和同步现有数据库；
5. 只存在旧数据目录时，启动明确失败并显示人工迁移步骤；
6. 现有测试、静态检查和最小安装测试通过；
7. `rg` 对旧名称的剩余命中全部属于迁移历史白名单；
8. GitHub 仓库显示为 `yibie/supertag`，本地 `origin` 使用新地址，最终 push 成功。

## Proposed Product Decisions Pending Review

1. Supertag 6.0.0 进行破坏性改名，不提供运行时兼容层。
2. 包入口、公开 Lisp 符号、Customization Group、Babel 语言、文档和仓库统一使用 `supertag`。
3. 默认数据目录改为 `~/.emacs.d/supertag/`，用户必须在升级前人工备份并改名旧目录。
4. 旧数据目录存在而新目录不存在时，初始化必须失败并给出迁移说明；两个目录同时存在时也不自动选择。
5. 数据库实体格式和普通 Org 知识内容不因品牌改名再次迁移。
6. 本地仓库目录改为 `supertag`，代码和测试不得依赖旧绝对路径。
7. `rg` 负责发现与审计；批量替换只用于机械文本，公开接口、路径和历史材料逐项判断。
8. GitHub 仓库在本地迁移完成、质量门通过并推送后，最后改名为 `yibie/supertag`。
9. 旧名称只允许出现在迁移指南、Changelog 和历史兼容测试夹具中。
10. 当前工作树中的用户修改必须完整保留，与改名无关的文件不进入本阶段。

## Review Gate

本文当前只用于用户审查，不视为 rename phase 已开启，也不授权代码修改或 GitHub 外部操作。

用户明确批准后，再创建独立的 `phase-supertag-rename-20260819/`，拆出 spec、plan、原子任务、迁移指南和验证步骤；实现完成并通过质量门后，才执行 GitHub 仓库改名。
