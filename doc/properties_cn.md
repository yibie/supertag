# 属性提示与补全

> English: [properties.md](properties.md)

属性是 Org 抽屉里的纯文本。抽屉本身不说明一个键只能取固定几个值还是可以随便填，也不说明
有哪些值。Supertag 在你打字的地方，也就是抽屉里，回答这两个问题。

## 闭合键与开放键

**闭合键**的允许值按 Org 的方式声明：一个不带 `:ETC` 的 `KEY_ALL` 属性。Org 从三处读取
声明，离得近的优先：

```org
:PROPERTIES:
:STATUS_ALL: todo doing done
:END:
```

```org
#+PROPERTY: STATUS_ALL todo doing done
```

```elisp
(setq org-global-properties '(("STATUS_ALL" . "todo doing done")))
```

其余的键都是**开放键**。以 `:ETC` 结尾的声明也算开放：那些值只是建议。

闭合是一种约定。在抽屉里打字不会被拦住；提示会指出不在选项内的值，仅此而已。Org 自己的
`org-set-property`（`C-c C-x p`）则要求必须从声明的选项里选。

Supertag 自己不保存任何声明。一个键是否闭合只由 Org 的 `KEY_ALL` 决定，数据库里不记录。

## 提示

光标在属性行的任意位置时，回显区显示键名、类型和选项：

| 行 | 提示 |
|---|---|
| `:STATUS: done` | `STATUS · closed · todo doing done` |
| `:STATUS: active` | `STATUS · closed · todo doing done · active is not an option` |
| `:COUNTRY: 日本` | `COUNTRY · open · 日本 \| 法国` |
| `:WEBSITE: https://…` | `WEBSITE · open` |

- 闭合键按声明的顺序列出选项。
- 开放键列出库里用过不止一次的值，用得多的在前，最多
  `supertag-property-hint-max-values` 个。值从不重复的键只显示类型。
- 由程序维护的键（`ID`、`CREATED`、`SUPERTAG_*`，以及
  `supertag-property-system-key-regexp` 匹配的其余键）不提示。你自己写的节点别名
  `SUPERTAG_ALIASES` 不算在内。

提示是一个 ElDoc 来源，所以 Supertag 会在 Org buffer 里打开 ElDoc。光标不在属性行上时，
回显区不受影响。

## 补全

候选由 Corfu 显示。

**值。** 在 `:KEY: ` 之后，闭合键按声明顺序给出选项。开放键给出所有用过的值，用得多的
在前，每个值旁边是使用它的节点数。

**键。** 在抽屉里新起一行，打 `:` 和开头几个字母，从用过的键里补全。与当前标题有相同
标签的节点用过的键排在前面。每个候选旁显示类型和使用它的节点数，如
`STATUS  closed · 15`。抽屉里已有的键和由程序维护的键不出现。`SUPERTAG_ALIASES` 即使
还没有节点用过也会给出，排在用过的键后面。选中一个键后会补上 `: `，并接着给出它的值。

Supertag 运行时，Org 自己的 `C-c C-x p`（`org-set-property`）在每个文件里都会给出
`SUPERTAG_ALIASES`；否则 Org 只在已经写过它的文件里才给出。把
`supertag-property-hints` 设为 nil 也不影响这一条。

**空值。** 一次编辑之后，空值会立刻给出候选：打完 `:KEY:` 后的空格、把值删掉、或选中
一个键。光标只是经过空值时什么都不显示。这只针对闭合键和有重复值的开放键；网址这类自由
文本的键不会弹出。如果你用自己的命令编辑，把它们加进
`supertag-property-popup-commands`。

## 属性值里的链接

Org 把属性值当作纯文本，写在里面的链接对 Org 来说不是链接。Supertag 仍然会读它：

```org
:PROPERTIES:
:ID:        a1b2
:SEE:       [[id:c3d4][另一条笔记]]
:REFERENCE: [[chai:20261006T164701][一本书]] [[chai:20260927T052022][另一本书]]
:END:
```

- 指向节点的链接（`id:`、`denote:`）是这个节点的一条引用，和写在正文里的一样，会出现在
  目标的反向链接里，不需要任何配置。
- 其它类型的链接，只有类型列在 `supertag-property-link-types` 里才会被记录：

  ```elisp
  (setq supertag-property-link-types '("chai" "https"))
  ```

  一个值里可以有多个链接，每个都连同它所在的键一起记录。

要找出哪些节点链接到某个目标，用查询条件 `links-to`，或在 Lisp 里调
`supertag-property-links-to`：

```elisp
(links-to "chai:20261006T164701")
```

链接如果还指向目标内部的某个位置，如 `chai:20261006T164701::42`，用较短的写法也能查到。

库里已有的笔记在下次保存时会重新读取。改了 `supertag-property-link-types` 之后，运行
`M-x supertag-reindex-org` 让其余笔记生效。

## 创建时间

标题的 `CREATED` 属性就是它的创建时间。标题第一次获得标签时，Supertag 会写入这个属性
（`supertag-created-time-format`）；Stream、`created` 查询条件和卡片都按它排序。

- 值可以是普通写法（`2026-10-12 18:11`），也可以是 Org 时间戳
  （`[2026-10-12 Mon 18:11]`）。只有日期、没有时刻时按零点算。
- 修改这个属性会移动节点；保存文件后生效。
- 没有这个属性的标题，保留 Supertag 第一次扫描到它的时间。
- 旧版本扫描过的笔记，在所在文件下次保存时取得日期；`M-x supertag-reindex-org`
  可以一次应用到所有文件。

## 同一个键在不同标签下含义不同时

一个抽屉里只有一个 `STATUS`，而 `STATUS_ALL` 按文件或子树生效，不按标签。如果书和任务都
需要状态而选项不同，就给它们不同的键名，比如 `BOOK_STATUS` 和 `STATUS`，再分别声明。
Supertag 不从前缀推导任何东西，它只是一个名字。

## 关闭

在 Supertag 启动前把 `supertag-property-hints` 设为 nil。只想在某个 buffer 里开关，用
`M-x supertag-property-mode`。

## 写配置时

`supertag-property-usage` 返回库里用了哪些键、各用了多少次、有哪些值；
`supertag-property-names` 返回所有属性名；`supertag-property-key-info` 返回光标处某个键
的类型和取值。请用这几个函数，不要直接读节点集合。
