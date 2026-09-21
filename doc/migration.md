# Migration and Upgrade

> 中文: [migration_cn.md](migration_cn.md)

This document covers two kinds of migration; read the part that matches your setup:

- **Data upgrade (V1 → V2)**: old database formats and retired fields data. The current data
  format is **7.2.0** (the source's `supertag-data-version`).
- **Package rename (conditional section)**: only old installs still using the `org-supertag`
  package name need it.

If you are still on the old `org-supertag` package name, handle the package name, config and
old data directory in the conditional section at the end first, and only then load the new
package.

Both share the same floor: nothing is silently moved or merged; back up first; anything that
writes back to Org asks you to confirm.

## Back up first

1. **Org files**. Part of the migration writes retired fields back to Org properties, so keep
   a copy first (Git, sync-service history, backups — whatever you normally use).
2. **The database**. It lives in the data directory (`supertag-data-directory`, default
   `~/.emacs.d/supertag/`; the file is `supertag-db-file`). Quit every Emacs that might write
   it, then copy.
3. Note the current data version: after loading the database, `M-x supertag-migrate-status`
   reports it.

## Old configuration: delete or replace

- **The initial-configuration wizard is retired**. `supertag-setup` no longer exists;
  configure in init following [setup.md](setup.md).
- **`supertag-view-table` is gone**. Browse nodes under a tag with
  `M-x supertag-view-stream`; its former fields-value handling retired with fields.
- **The dedicated capture is retired**. Recording uses standard `org-capture`; to have
  capture finalize add the ID, add the optional integration, see [setup.md](setup.md).
- **fields values have no editing entry point any more**. Old values are either written back
  to Org properties by `supertag-migrate-apply`, or stay in preview's raw records.
- **fields-related configuration is retired** (for example the global field switch
  `supertag-use-global-fields`; the old modules live under `archive/`). Leaving such `setq`s
  in your config does not error, but has no effect.
- Everything else: [customization.md](customization.md).

## Loading migrates automatically (snapshot first)

`supertag-db-auto-migrate` defaults to `t`. When loading finds a version below the current one
inside the migratable range (next section), Supertag migrates automatically:

1. it first copies the current database **byte for byte** into the backup directory
   (`supertag-db-backup-directory`) and verifies the bytes match;
2. it runs the version chain's database steps in memory (including extracting old fields
   sources into pending `:legacy-fields`; these touch the database only, never Org);
3. it saves the new database stamped with the current version. On error it restores the
   snapshot just made and records the error in `M-x supertag-migrate-status`'s report.

To stop it from running automatically, set `(setq supertag-db-auto-migrate nil)` before
`(require 'supertag)` and migrate by hand with `M-x supertag-migrate-run`.

A database already at 7.2.0 is not migrated and gets no extra snapshot; refused versions
(no version stamp, 4.x, newer than current) are left untouched as well.

## What can migrate directly

| Your data version | Result |
|---|---|
| 5.0.0 to 7.2.0 (current) | migrates to 7.2.0 |
| 4.x and older | cannot migrate directly; the message tells you to upgrade with supertag 6.x first, then to the current version |
| no `:version` stamp | refused; the database is untouched — establish which release wrote it, then handle it manually |
| newer than 7.2.0 | refused; the database is newer than the program, so upgrade Supertag instead of migrating the data |

"Can migrate" means the version chain accepts that data; it does not promise lossless
handling of every version and every edge case: values it cannot explain are kept (preview's
raw records), and conflicts are left for you to decide.

## Retired fields data: four commands

- `M-x supertag-migrate-status` — read-only report: data version, pending fields, unresolved
  sub-tag relations, duplicate/invalid nodes, the last migration error and snapshot path. It
  deletes nothing.
- `M-x supertag-migrate-preview` — in the `*Supertag Field Migration*` buffer it shows, node
  by node, what is about to be written, what is still pending, what conflicts with existing
  Org properties, and what was skipped for empty names/reserved keys/unlocatable headings;
  the raw source records are listed below. It modifies neither files nor the database.
- `M-x supertag-migrate-apply` — the one that writes Org. It first resolves still-unresolved
  sub-tag relations in the database (that part does not touch Org), then asks
  "write N keys, pending M; save and re-project?"; **only after you confirm** does it write the
  properties into the source files and re-project, leaving conflicts for the next round and
  retiring the records that succeeded.
- `M-x supertag-migrate-run` — runs the database version chain only (the automatic-migration
  step), writing no Org properties.

The fields path is just those two steps: preview to see clearly, apply to write back to Org;
the database snapshots and your Org backup are the plain-text fallback.

## Conditional section: still on `org-supertag`

> Skip this section if the package name is already `supertag`.

**Package and loading**. The rename is breaking: there is no old-library alias and no
automatic data-directory move. Change two places:

```emacs-lisp
;; before
(straight-use-package '(org-supertag :host github :repo "yibie/org-supertag"))
(require 'org-supertag)

;; after (sync directories must precede require; full template in setup.md)
(straight-use-package '(supertag :host github :repo "yibie/supertag"))
(setq supertag-sync-directories '("~/Documents/notes/"))
(require 'supertag)
```

**Old data directory**. The old default was `~/.emacs.d/org-supertag/`; it is now
`~/.emacs.d/supertag/`. Supertag does not move or merge the two directories silently: quit
every Emacs, back up first, then choose explicitly. The current build provides
`(supertag-resolve-data-directories)` (a Lisp function, not an `M-x` command): it shows a
comparison of the old and new default directories, lets you choose which one to keep, and
requires confirmation of the exact rename operations. The root not selected is renamed to a
dated `-retired-` archive (a numeric suffix on collisions); no data is deleted. You can also
rename the directory by hand as before — again, back up and quit Emacs first.

**Config rename**. Search your configuration for `org-supertag` and replace per this table. Old
names are no longer read: keeping a `setq` with an old name usually does not error, but it has
no effect.

| Old name | New name |
|---|---|
| `org-supertag-data-directory` | `supertag-data-directory` |
| `org-supertag-sync-directories` | `supertag-sync-directories` |
| `org-supertag-sync-directories-mode` | `supertag-sync-directories-mode` |
| `org-supertag-active-sync-directory` | `supertag-active-sync-directory` |
| `org-supertag-vault-auto-switch` | `supertag-vault-auto-switch` |
| `org-supertag-vault-modeline-indicator` | `supertag-vault-modeline-indicator` |
| `org-supertag-file-id-source` | `supertag-file-id-source` |

**Babel language**. Replace the old `org-supertag-query-block` / `org-supertag-query` with
`supertag-query-block`; existing dynamic blocks remain refreshable.

## Post-upgrade checks

1. Reload the database and confirm with `M-x supertag-migrate-status` that the version is
   7.2.0 and no error is reported;
2. if it still reports pending fields, list them with `M-x supertag-migrate-preview` and then
   decide whether to run `M-x supertag-migrate-apply`;
3. open one or two old notes and confirm titles, tags and properties; run a query or view you
   use often;
4. if you renamed the package or the directory, confirm the data directory points at the right
   place (`M-: (supertag-doctor)` shows the current state);
5. afterwards the snapshots stay in the backup directory — keep them as long as you like.
