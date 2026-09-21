# 未链接提及的行为边界

> English: [mentions.md](mentions.md)

未链接提及补完「记录或链接」的流程，又不会过早把可能的引用变成已存储的事实。这一节只对概念节点显示——也就是位于你模板配置的目标文件里、带持久 ID 的那些标题；普通笔记节点不显示。

## 它在找什么

对 Node View 当前的节点，Supertag 在**来源节点自己的正文**里查找目标节点的标题和别名。
下面的内容不算候选：

- 已有的 Org 链接；
- source/example 块、固定宽度文本、行内代码、verbatim 区域。

如果某个来源节点已经链接到目标（哪怕是写在它的标题里），这个来源就整个跳过。中文不套用
ASCII 的词边界规则；ASCII 标识符照常按词边界处理。

## Node View 里长什么样

每个来源节点一张卡片：来源标题、第一次出现的摘录，以及来源里再次提及时一句弱化的
`+N more`。小节里的计数是来源节点的个数，`supertag-mention-max-results` 给这个数封顶，
所以单个来源不会占满整节。

每个候选项有三个动作：

- **Link**——把这张卡片对应的第一处出现替换成规范的 Org ID 链接；
- **Link all**——替换该来源节点里所有仍存在的出现；
- **Ignore in node**——在来源 heading 上写 `SUPERTAG_IGNORE_MENTIONS` Org 属性。

## 数据边界

- 候选是随时可弃的读模型：没有 `:unlinked-mentions` 集合，也没有第二套 Backlink 数据库；
  只有被接受的 Org 链接才经既有文档投影成为引用事实。
- 执行这三个动作的是 Node View 的内部动作，不是独立的 `M-x` 命令。
- 提及搜索使用一个临时的 Org 解析缓存和简单的文本预筛；缓存自动管理，可以用
  `supertag-mention-service-clear-cache` 以编程方式清掉，从不落盘。
