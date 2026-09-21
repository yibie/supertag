# Getting Started (initial configuration template)

> 中文: [setup_cn.md](setup_cn.md)

Prerequisite: Supertag is installed as described in the README (package and dependencies already on `load-path`).

## Minimal initial configuration

Two lines are enough: set the sync directory, then load. `supertag-sync-directories` **must be set before `(require 'supertag)`**.

```emacs-lisp
;; init.el
(setq supertag-sync-directories '("~/Documents/notes/"))   ; where your Org files live; several directories allowed
(require 'supertag)
```

The sync directories must be set before loading; to switch vaults or change directories later, use `M-x supertag-vault-activate` (multi-vault) or edit init and restart.

Then run the first scan once:

```
M-x supertag-sync-full-rescan
```

## Optional: file-node identity

`supertag-file-id-source` only decides the identity of **file nodes**. It is independent of heading-node IDs and is not covered by the config guard — just `setq` it:

- `org-roam` (default): reads the `:ID:` in the `:PROPERTIES:` drawer at the top of the file. The default does **not** require org-roam.
- `denote`: reads `#+IDENTIFIER:` in the file.
- `auto`: accepts both; `disabled`: no file-level nodes.

Heading nodes always use the heading's own Org ID (`M-x org-id-get-create`, etc.), independent of this option.

```emacs-lisp
(setq supertag-file-id-source 'auto)
```

## Optional: org-capture integration

Recording still uses Org's own `org-capture`; Supertag stays out of capture by default. To have capture finalize add an `:ID:` to the new heading and sync it into the database, do two things.

1. Enable the integration. In init, before `(require 'supertag)`:

```emacs-lisp
(setq supertag-org-capture-auto-enable t)
```

If Supertag is already loaded, evaluate Lisp instead: `(supertag-enable-org-capture-integration)`; disable with `(supertag-disable-org-capture-integration)`. These two are not M-x commands.

2. Append a template carrying `:supertag t` to `org-capture-templates` (create the target file yourself first), instead of overwriting your existing templates:

```emacs-lisp
(require 'org-capture)
(add-to-list 'org-capture-templates
             '("n" "Note" entry
               (file+headline "~/Documents/notes/inbox.org" "Inbox")
               "* %?\n"
               :supertag t)
             t)
```

On finalize Supertag adds the ID and syncs the node. The write lands in the target file's buffer and reaches disk through Emacs's normal save flow. Templates without `:supertag t` are unaffected.

## Other

- The data directory defaults to `~/.emacs.d/supertag/`; to change it, set `supertag-data-directory` in init before `require`.
- All options and defaults: [customization.md](customization.md).
