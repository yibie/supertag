# Supertag Sync Mechanics

> 中文: [sync_cn.md](sync_cn.md)

This document describes how Supertag's synchronization works, keeping three things apart:
incremental Org-text-to-database sync, local database saving and backup, and moving Org text
with Git.

## Three layers, not one

| Layer | Moves | Owner | On failure |
|---|---|---|---|
| Org → database | your Org text into the local database projection | Supertag auto-sync | skip this round, keep the state, never delete source text |
| Local database save/backup | `supertag-db.el` and daily snapshots | Supertag persistence | refuse to overwrite, keep the old file and snapshots |
| Git text sync | Org text only | `supertag-git.el` | pause and wait, or report; never silently drop text |

The Git layer is **not** database sync: it commits Org text only, and each machine rescans
that text and rebuilds its projection locally. Things that live only in the database
(automation rules, some settings, local tag-projection state) do not travel with Git; the
database itself is protected by its own backup mechanism instead.

## Org → database (incremental sync)

It starts once the directories are ready: `supertag-sync-auto-start` (on by default) waits
after startup for the directories to become available, then starts the periodic scan; if they
never appear it gives up after its retries and says so.

- **Saved changes**: saving an Org file puts it into the sync queue; the periodic scan
  (`supertag-sync-auto-interval`, 900 seconds by default) adds files changed since the last
  sync, and the async queue then processes them one by one once Emacs is idle.
- **Incremental detection**: each file's last-synced state is kept in a state file in the
  data directory, so the scan only processes new or changed files.
- **ID prerequisite**: only headings carrying an Org ID (an `:ID:` property) become nodes; a
  read-only scan never invents an ID for an ID-less heading, and never rewrites your Org
  files. Writing plain text first is fine — add the ID when the heading should become a node
  (the capture integration or `M-x org-id-get-create`).
- **When to full-rescan**: after changing sync directories, moving machines, or suspecting a
  stale state file, use `M-x supertag-sync-full-rescan` to rebuild projections from one
  complete snapshot.

## Enabling it (first machine)

Prerequisites: `git` is installed, and your commit identity (`user.name`/`user.email`) and
remote authentication (SSH key or credential helper) are configured;
`supertag-sync-directories` names exactly one directory, and that directory must be the Git
worktree toplevel itself — not a subdirectory inside some repository.

```emacs-lisp
;; init.el, must precede (require 'supertag)
(setq supertag-sync-directories '("~/Documents/notes/"))
(require 'supertag)
```

Then `M-x supertag-git-setup`: it checks that the directory is in a Git repository (running
`git init` if not), writes the ignore rules, commits the current Org text, and offers an
optional remote URL (leave it empty for a local-only repository). If old local data (database,
backups, ...) is already tracked by Git, it first asks whether to stop tracking those paths;
the files stay on disk and are not deleted. A successful remote answer pushes once; a failed
push is reported only, and retries are left to auto-sync.

Turn on automatic sync with `M-x supertag-git-sync-mode`. The mode is **not persistent**: it
applies to this session only, and must be turned on again after an Emacs restart. To enable it
at startup, call `(supertag-git-sync-mode 1)` in init after `(require 'supertag)`. Manual sync
is `M-x supertag-git-sync-now`.

## Second machine

`M-x supertag-git-clone`: clones into an empty directory, sets it as the sync directory **for
the current session only**, rebuilds the local projection and saves the local database. If the
next startup should use the same directory, put `supertag-sync-directories` into init (before
`(require 'supertag)`). Then turn on `M-x supertag-git-sync-mode` as before. Each machine keeps
its own database file; only Org text passes through Git.

## What Git actually syncs

The auto-commit scope is narrow:

- **Committed**: `*.org` recursively under the sync directory, plus the repository root's
  `.gitignore`.
- **Not committed**: the data directory, `supertag-db.el`, the backup directory, the sync
  state file, the presence file, `.gitattributes`; Emacs lock/auto-save/backup files
  (`.#note.org`, `#note.org#`, `note.org~`); ordinary attachments are outside the auto-commit
  scope too.

Those two bullets describe **auto-commit**, not the entire repository: attachments or other
files you track by hand still move with `git fetch`/merges — Supertag just does not commit
them for you.

The index scope is checked before and after staging: an out-of-scope path already in the index
makes the commit refuse, and staged conflict markers are refused as well, so local data or
half-finished text does not get into history.

## Timing, offline, conflicts

- **Auto-commit**: saving Org starts a timer; the commit happens after
  `supertag-git-sync-commit-debounce` (30 seconds by default) of quiet, and further edits keep
  postponing it.
- **Auto-pull**: a `git fetch` every `supertag-git-sync-pull-interval` (300 seconds by
  default); merge if behind, push if local commits are ahead. Regaining focus also triggers
  one, at most once per `supertag-git-sync-focus-pull-min-interval` (60 seconds).
- **Offline/failure**: a failed fetch or push is reported once (not once per retry) and local
  commits stay; the next cycle after connectivity returns pushes the backlog.
- **Unsaved buffers**: if a merge would overwrite files with unsaved edits, the merge is
  postponed and the blocking files are named; Supertag never saves, reverts or kills your
  buffers. The next cycle continues after you save. Saved-but-uncommitted Org edits are
  committed first, then the pull proceeds.
- **Conflicts**: an unresolved Org conflict pauses auto-sync, opening the first conflicted
  file in `smerge-mode` (conflicted files are not imported into the database). Resolve, save,
  then run `M-x supertag-git-sync-now` to continue.
- **Bounds**: there is no promise of lossless arbitrary concurrency. Two machines editing the
  same text hand it to Git; if Git cannot merge, the sync stops and waits for you. If you would
  rather not handle conflicts, stagger your edits and sync often.

## The database layer

- The database lives under `~/.emacs.d/supertag/` by default (`supertag-data-directory`).
  Unsaved changes are written every `supertag-db-auto-save-interval` (300 seconds by default);
  after writing, `supertag-db-verify-after-save` (on by default) re-reads and compares, and a
  bad write aborts, leaving the old file untouched.
- Every `supertag-db-backup-interval` (86400 seconds by default) a snapshot is written, kept
  for `supertag-db-backup-keep-days` (3 days by default) under `backups/`. The snapshot restore
  entry point is the Lisp function `(supertag-restore)` (not an `M-x` command): it lists the
  daily, pre-migration and other snapshots, and after confirmation creates a recovery point
  before replacing the database.
- Loading and saving prefer the newer on-disk revision: when the disk is newer and this session
  has unsaved changes, Supertag refuses to overwrite and says so; a clean session checks every
  `supertag-db-follow-interval` (30 seconds by default) and switches to the newer revision
  automatically. `M-: (supertag-doctor)` shows database, guard and conflict state.
- Two Emacsen writing the same database file at the same time are not protected: the presence
  file is only a heads-up (on by default, `supertag-presence-enable`), not a lock. Relaying the
  database through a sync service (Dropbox/iCloud) is still "whole file, last writer wins" —
  do not edit on two machines at once.

## Key configuration

Defaults come from the source; the full list is in [customization.md](customization.md).
Directory-related variables must be set before `(require 'supertag)`; for timing parameters,
set them before startup or before enabling the relevant mode — an already running timer does
not recompute on a value change, and only a restart of the mode or Emacs picks up the new
value.

| Variable | Default | Effect |
|---|---|---|
| `supertag-sync-directories` | `nil` | Org root(s) to sync; Git requires exactly one |
| `supertag-sync-auto-start` | `t` | start the periodic sync once directories are ready |
| `supertag-sync-auto-interval` | `900` | periodic scan interval (seconds) |
| `supertag-sync-idle-delay` | `1.0` | how long Emacs must be idle before the periodic sync runs |
| `supertag-sync-exclude-directories` | `nil` | excluded directories, taking precedence over sync directories |
| `supertag-sync-file-pattern` | `"\\.org$"` | which files are recognized |
| `supertag-sync-snapshot-guard` | `t` | guard destructive operations with a snapshot; skip when directories are unavailable |
| `supertag-db-auto-save-interval` | `300` | database auto-save interval (seconds) |
| `supertag-db-backup-interval` | `86400` | daily backup interval (seconds) |
| `supertag-db-backup-keep-days` | `3` | days to keep daily backups |
| `supertag-db-verify-after-save` | `t` | re-read after writing and compare; abort on mismatch |
| `supertag-db-follow-interval` | `30` | follow newer revisions written by other Emacsen |
| `supertag-git-sync-commit-debounce` | `30` | quiet seconds before Git auto-commit |
| `supertag-git-sync-pull-interval` | `300` | auto-fetch interval (seconds) |
| `supertag-git-sync-focus-pull-min-interval` | `60` | minimum seconds between focus-triggered pulls |
| `supertag-presence-enable` | `t` | write the multi-machine presence heads-up file |

## Common commands

| Command | Effect |
|---|---|
| `M-x supertag-git-setup` | set up the current Org root as a Git repository (init, ignore rules, first commit, optional remote) |
| `M-x supertag-git-clone` | clone on another machine and rebuild the projection |
| `M-x supertag-git-sync-mode` | toggle this session's auto-commit and pull (not persistent) |
| `M-x supertag-git-sync-now` | commit/pull now, or commit a resolved conflict |
| `M-x supertag-sync-full-rescan` | full rescan rebuilding projections from one complete snapshot (does not modify Org) |
| `M-x supertag-sync-status` | show sync status and current configuration |
| `M-x supertag-sync-cleanup-database` | validate nodes and garbage-collect orphans (destructive maintenance; confirm directories first) |
| `M-x supertag-save-store` | save the database now |
| `M-x supertag-vault-activate` | switch vaults in multi-vault mode (refused while Git sync is on) |

## Quick troubleshooting

- **Auto-sync does nothing**: first check that `supertag-sync-directories` is set and the
  directory exists, and confirm with `M-x supertag-sync-status`.
- **Git stuck on a conflict**: resolve, save, `M-x supertag-git-sync-now`; `supertag-doctor`'s
  report also lists unresolved files.
- **A large number of nodes looks about to disappear**: the snapshot guard's deletion ratio
  and count limits block wholesale deletion; first check that the sync directory has not moved
  or become unavailable.
