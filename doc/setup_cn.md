# 开始使用（初始配置模板）

> English: [setup.md](setup.md)

前提：Supertag 已经按 README 的安装步骤装好（包和依赖先在 load-path 里）。

## 最小的初始配置

两行就够了：设置同步目录，然后加载。`supertag-sync-directories` **必须在 `(require 'supertag)` 之前**设置。

```emacs-lisp
;; init.el
(setq supertag-sync-directories '("~/Documents/notes/"))   ; 放 Org 文件的目录，可以有多个
(require 'supertag)
```

同步目录需要在加载前设置；之后要换库或改目录，用 `M-x supertag-vault-activate`（多库）或改 init 后重启。

然后跑一次首次扫描：

```
M-x supertag-sync-full-rescan
```

## 可选：文件级节点的身份

`supertag-file-id-source` 只决定**文件节点**的身份，与标题节点的 ID 无关，也不受 config guard 保护——想改就直接 `setq`：

- `org-roam`（默认）：识别文件顶端 `:PROPERTIES:` drawer 里的 `:ID:`。用这个默认值**不需要**安装 org-roam。
- `denote`：识别文件里的 `#+IDENTIFIER:`。
- `auto`：两种格式都认；`disabled`：不创建文件级节点。

标题节点一律用标题自己的 Org ID（`M-x org-id-get-create` 之类），与上面这项无关。

```emacs-lisp
(setq supertag-file-id-source 'auto)
```

## 可选：org-capture 集成

记录仍然用 Org 自己的 `org-capture`；默认 Supertag 不介入 capture。想让 capture 收尾时给新标题补上 `:ID:` 并同步进数据库，做两步。

一、开启集成。在 init 里于 `(require 'supertag)` 之前写：

```emacs-lisp
(setq supertag-org-capture-auto-enable t)
```

已经加载了也可以求值 Lisp 开启：`(supertag-enable-org-capture-integration)`；关闭是 `(supertag-disable-org-capture-integration)`。这两个不是 M-x 命令。

二、在 `org-capture-templates` 里追加一个带 `:supertag t` 的模板（目标文件要自己先建好），不要覆盖你已有的模板：

```emacs-lisp
(require 'org-capture)
(add-to-list 'org-capture-templates
             '("n" "笔记" entry
               (file+headline "~/Documents/notes/inbox.org" "Inbox")
               "* %?\n"
               :supertag t)
             t)
```

收尾时 Supertag 给新标题补 ID 并同步为节点。写入落在目标文件的缓冲区，随后按 Emacs 的常规保存流程落盘。没有 `:supertag t` 的模板不受影响。

## 其他

- 数据目录默认在 `~/.emacs.d/supertag/`；要改的话，在 init 里于 `require` 之前设置 `supertag-data-directory`。
- 全部选项与默认值见 [customization_cn.md](customization_cn.md)。
