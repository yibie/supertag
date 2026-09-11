# Supertag – Structured knowledge, inside Emacs, on your own files

<!-- P1 development -->
## Development verification

The first replacement read path is `supertag-note-query-read-node`: an isolated
node/Org-property projection consumed directly by the existing Node View builder.
It does not certify disk/live equality. The public load chain still has legacy
tag, relation and business dependencies; writer and queue behavior is unchanged.

Run `bash test/run-tests.sh` for contract, compatibility and named transition
checks, or `bash test/run-tests.sh --guidance` for lightweight guidance checks.
Historical field/Board assertions use explicit `bash test/run-tests.sh archive`;
the Board and Graph web frontends are archived under `archive/ext/`, and the
manual Board npm/build CI job is retired with them. No dependency installation is
performed by the local runner. See the [test guide](test/README.md) for scope and logs.
This slice does not claim complete package isolation, fresh-package installation,
Embark integration or acceptance of the remaining renovation packages.
<!-- /P1 development -->

[中文](./README_CN.md) | [English](./README.md)

Supertag helps you **write notes, connect ideas, and find them again** in Org. Write headings and prose, organize with tags, and connect notes with links. No field definitions or table design required; your `.org` files remain plain text.

> **Upgrading from Org-Supertag?** Version 6.0 is a breaking rename with no
> compatibility aliases or automatic data move. Follow
> **[Migrating to Supertag](doc/MIGRATING-TO-SUPERTAG.md)** before starting it.

> **Start with writing**: Record an idea, add a tag when useful, and link related notes. Read them together in Stream or search the whole collection with Discovery.

> **Getting started?** Follow “Installation and first run” and “Real workflows” below. The historical [A Day with Supertag](doc/A-DAY-WITH-SUPERTAG.org) guide still includes archived views and field workflows; do not copy it wholesale as current configuration.

---

## What you get (and why it's easier)

| Without Supertag | With Supertag |
|---|---|
| Notes on one topic are scattered across files | Add `#tag` to headings and read them together in Stream |
| You cannot remember a note's title or location | Open Discovery for random reading; press `s` to search all notes |
| You want to connect related ideas | Complete after `[[` to insert an ordinary Org link and inspect backlinks |
| You want to add a thought while reading | Press `e` in Stream to edit the source note, or return to the original |

**The core idea**: Write first, organize when useful. Supertag adds tag browsing, links, and search to plain text; a field system is no longer a product goal. Native Org properties remain optional, and existing properties and historical data are not deleted by this change in direction.

---

## Installation and first run

**Optional dependency: Embark (recommended).** It enables the contextual actions described below; SuperTag itself does not require Embark.

**Optional dependency: superchat.** Load and configure superchat yourself before using `supertag-ai-extract-properties` (Embark node key `x`, or menu `e`). The model configured in superchat proposes properties for review in Node View’s **Property candidates** section. Accept writes a property to the Org PROPERTIES drawer; Skip discards it without writing. Supertag has no LLM client of its own, and its other features work without superchat. Customize prompt templates with `supertag-ai-prompts`.

Batch and cancel: `supertag-ai-extract-tag-properties` (menu `w` → `E`) picks a tag and extracts its nodes one at a time, one request owned by this batch at a time (independent pending requests may coexist and are skipped); when the batch finishes, `*Supertag AI Plan*` lists every candidate grouped by file (`k` skips a line, `a` applies, `q` quits). Applying writes exactly the plan you saw: a candidate that changed meanwhile, or a node whose file has unsaved edits, is left unwritten and counted in the summary. `supertag-ai-cancel-extraction` (menu `w` → `C`) and the section’s [Cancel] button stop one node; `supertag-ai-cancel-batch` (menu `w` → `B`) stops the batch. A response that could not be parsed keeps a [Show raw] button so you can tune your model’s JSON output in superchat.


**Optional capability: similar notes.** Install and start Ollama (or an Ollama-compatible `/api/embed` service), then make the model available with `ollama pull bge-m3`. Enable `supertag-semantic-enabled` to show **Similar notes (candidates)** automatically in Node View, after unlinked mentions. It sends projected titles, outline paths and up to 1,500 own-body characters per node to `supertag-semantic-endpoint` (default `http://localhost:11434`) asynchronously through `curl`. It never writes Org or creates links. Cards show node-level similarity and original-body previews, not exact passage matches or claims of concept identity.

The default model is `bge-m3`. In the synthetic Chinese rewrite/cross-language probe, `dengcao/Qwen3-Embedding-0.6B:Q8_0` performed better; for a primarily Chinese vault, pull that model and set `supertag-semantic-model` accordingly. This is synthetic evidence, not a quality guarantee for your notes. Model changes rebuild the disposable int8 side-car `supertag-semantic.el` in Supertag’s data directory. Tune `supertag-semantic-min-similarity` (default 0.4) and `supertag-semantic-max-results` (default 5) for your notes. Use `supertag-semantic-rebuild`, `supertag-semantic-status`, or `supertag-semantic-stop` from **Maintain → More maintenance → Data & setup**. An endpoint failure pauses the round; use [Retry] in the section or rebuild to try again. The feature is off by default and adds no package dependency.

```emacs-lisp
;; With straight.el
(straight-use-package '(supertag :host github :repo "yibie/supertag"))
(require 'supertag)
```

Then, in Emacs:

1. **`M-x supertag-setup`** — the guided setup wizard. It reports your current status, lets you pick which directories to sync, choose a file-ID source (Org-roam, Denote, or both), set persistence options, and optionally run the first scan.
2. **`M-x supertag-menu`** — the task menu for Capture & Write, Organize, Find & View, and Maintain. Use it to discover commands instead of memorizing them.

That's it. No API keys, no database server to run. Your existing Org files are already compatible.

---

## The one command to remember

**`M-x supertag-menu`** is organized around four jobs: **Capture & Write**, **Organize**, **Find & View**, and **Maintain**. Daily commands stay on the first screen; specialized automation, migration, query, and display commands live in the matching `More...` submenu. If you remember nothing else from this README, remember this one.

Embark is optional and recommended. Install it from GNU ELPA with `M-x package-install RET embark`; `embark-act` then offers Supertag actions on headings, #tags, id links, concept mentions, and regions. On headings, `x` extracts property candidates through optional superchat. All commands remain available through `supertag-menu` and M-x without Embark. Set `supertag-embark-integration` to nil before loading Supertag (or restart Emacs). An already registered integration stays active for the current session. In an Org body, the containing node is the object; before the first heading, native Embark objects apply. A writable selection offers RET/`l` to add a link, `t` to tag all nodes in the selection, and `p` to Promote the selected text (existing boundary checks apply). On Stream, Discovery and Node View node cards, RET visits the original note and `v` opens Node View. Node View tag rows support RET/`r`/`c`/`R`/`D` as tag actions.

Or bind the menu directly to any key you like with `global-set-key`.

---

## File nodes: Org-roam, Denote, or both

This setting only affects file-level nodes. Heading nodes continue to use Org IDs normally.

```emacs-lisp
;; Default: files with a top-level :ID: (Org-roam style)
(setq supertag-file-id-source 'org-roam)

;; Files with #+IDENTIFIER: (Denote style)
(setq supertag-file-id-source 'denote)

;; Mixed directory: recognize either format per file
(setq supertag-file-id-source 'auto)

;; Do not create file-level nodes
(setq supertag-file-id-source 'disabled)
```

Use `auto` when Org-roam and Denote files share a sync directory. Links are generated from each node's own identity: Org-ID nodes use `id:`, while Denote file nodes use `denote:`. A file without the selected persistent identity remains an ordinary Org file; SuperTag does not invent a temporary ID for it.

After changing the setting, run `M-x supertag-sync-full-rescan`.

---

## The three things you need to know

Supertag is built on three simple ideas:

### 1. Use `#tag` to bring related notes together

```org
* Attention Is All You Need #paper
```

Add `#paper` to paper notes to read them in one Stream without moving them into one file.

### 2. Write prose and connect it with links

Write summaries, questions, and conclusions beneath the heading. There is no set of properties to fill in first. Use `supertag-add-link` to connect existing notes and Node View to inspect references and mentions.

Org properties are optional. They live in Org files and enter the database as rebuildable projections after synchronization. You do not need them to write, tag, or search notes. The old field UI is archived; defining schemas and filling fields are not prerequisites for the current workflow.

### 3. Read, search, and keep writing in views

- **Node View** (`M-x supertag-view-node`): Inspect a node's saved Org properties, tags, references, and mentions in a read-only detail view.
- **Stream View** (`M-x supertag-view-stream`): Browse the complete chronological, single-column list grouped by creation day, with `title  #tags` rows for a tag and all tags below it in the slash path (`#media` includes `#media/book`). Use `n`/`p` to move, `e` to edit the source heading and its own body (file-level nodes expose the whole file), or `v` for the read-only Node View. `C-c C-c` saves the **whole source file, including other existing drafts**, then projects the node and returns to Stream. `C-c C-k` cancels only pending session edits: a successful native `C-x C-s` becomes the new cancellation baseline, and outside edits are preserved. Save failure leaves the edit open; post-save projection failure keeps the saved text and exposes the existing retry.

Legacy Table, Schema, Kanban, Board, and Graph tool UIs are
archived and are not loaded or advertised by the default package. Their source
can still be loaded explicitly for compatibility work.

---

## Step-by-step: your first 5 minutes

1. Open or create an Org file and add tags with `supertag-add-tag`; Stream and Discovery follow the source text.
2. Press `g` in Stream or `g` in Node View to refresh; press `v` on a node card to open Node View.
3. Use `supertag-discovery` to search notes, and use Embark on headings, tags, links, or selections for contextual add-link, tag, and Promote actions.
4. Use an Org capture template for new notes. For a versioned data migration, preview and apply with `supertag-migrate-preview` and `supertag-migrate-apply`.

Table, Schema, Kanban, Board, and Graph entry points are archived and are not part of the current workflow.

---

## Real workflows (with commands you can copy)

### 📚 Academic reading queue

```org
* Diffusion Models Survey #paper
* ViT Explained #paper
* CLIP Paper #paper
```

Write reading summaries, open questions, and comments directly below each heading.

**Daily workflow**:
1. `M-x supertag-view-stream` → tag `paper`; move with `n`/`p`, `g` refreshes
2. On an entry press `e` to add reading notes; `C-c C-c` saves the whole source file, including other existing drafts
3. Press `v` to open Node View: properties, references, mentions and semantic candidates in one place

**Why it's convenient**: Read related notes together and find their contents by keyword without first recording ratings or reading status.

### 📋 Project task tracking

```org
* Rewrite sync layer #task #project
* Fix auth bug #task
* Deploy v2.1 #task
```

Write the next step in the body. Use native Org TODO states and timestamps when you need task status or scheduling.

**Daily workflow**:
1. `M-x supertag-view-stream` → tag `task` to read task notes together
2. Use Stream `e` to edit the source and `g` to refresh
3. `M-x supertag-discovery`, press `s`, then enter space-separated keywords to review every matching note

**Why it's convenient**: Your tasks live in their natural Org files (meeting notes, project files), but you see them all in one Stream.

### 📝 Meeting notes with decisions

```org
* Sprint Planning 2024-11-15 #meeting
```

Write participants, discussion, and decisions in the body; use ordinary lists for action items.

**Workflow**:
1. Write an Org heading directly, or use your existing `org-capture` configuration
2. Later: `M-x supertag-discovery`, then press `s` to search titles, tags, bodies, and Org property values
3. Enter words present in the notes, such as `meeting release`; all keywords must match

**Why it's convenient**: Meeting notes live where they belong (project files), but you query across all of them at once.

---

## Commands you'll use every day

| What you want to do | Command | What happens |
|---|---|---|
| Tag something | `M-x supertag-add-tag` | Adds `#tag` inline, node appears in that tag's table |
| See all nodes of a tag | `M-x supertag-view-stream` | Browse source-backed nodes chronologically |
| Browse a tag chronologically | `M-x supertag-view-stream` | Complete tag/descendant title collection; `e` edits source, `C-c C-c` saves the whole file then projects, `C-c C-k` cancels unsaved session edits while retaining successful native saves |
| Inspect a node's Org properties | `M-x supertag-view-node` | Read-only detail view of saved projected properties, tags, references, and mentions |
| Follow named links | `M-x supertag-view-node` | Inspect relations on a node |
| Add or view relationships | `M-x supertag-add-link` (prefix argument for a relation name), then open Node View | Ordinary links keep `id`/`denote`; a named link such as `[[supports:NODE-ID]]` is saved text and can use a configured or newly entered session name |
| Find or explicitly create a node | `M-x supertag-find-node`; use `C-u M-x supertag-find-node` for another window | Existing nodes open without writes. If nothing matches, choose the explicit Create action and a complete creation template; Find never inserts a source link or performs Promote monitoring |
| Merge duplicate tags | Preview and merge tags from the current tag workflow; Schema View is archived | Preview and merge into a new/existing tag; Schema renames are previewed, then written file by file through the Org writer |
| Capture new node | `M-x org-capture` | Uses normal Org Capture; Supertag templates can retain their internal finalization |
| Rediscover notes | `M-x supertag-discovery` | Opens 10 random full-body notes by default; `s` searches all nodes for every keyword, `g` refreshes, and marked references can be inserted at the starting note |
| Link related nodes | Type `[[` and complete, or `M-x supertag-add-link` | Links an existing node or explicitly creates a fresh template-based target, writes one forward Org link, and derives the target Backlink |
| Review unlinked mentions | Open Node View and use **Unlinked Mentions** | Finds plain-text title/alias mentions as disposable candidates; link one, link all in the source node, or ignore that target in the source |
| Promote text or a heading with a template | `M-x supertag-promote` | Explicit reuse/new with content preview; selected text becomes an ordinary Org link |
| Highlight concept mentions | `M-x supertag-concept-link-mode` | Shows concept title/alias mentions as amber semantic highlights, not stored links |
| Context actions at point | `embark-act` (Embark, optional) | Object-specific actions; RET runs the default |
| Reindex Org documents | `M-x supertag-sync-full-rescan` | Rebuilds Document Projections from one complete snapshot; never restores Semantic Facts |

Discovery's initial sample is an unranked, without-replacement reading sample.
Set `supertag-discovery-initial-sample-size` to change its default size of 10;
keyword search always shows the complete matching set and is not capped by
that setting.

To keep results inside a note, use a `supertag-query-block` code block, for example `(tag "paper")`. Insert one with `M-x supertag-add-query-block` or build a query with `M-x supertag-query-build`. See `doc/QUERY.md` for advanced syntax; everyday search does not require learning a query language.

Optional keybindings:

```emacs-lisp
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c n l") #'supertag-add-link)
  (define-key org-mode-map (kbd "C-c n p") #'supertag-promote)
  (define-key org-mode-map (kbd "C-c n o") #'supertag-concept-open-at-point))
```

### Create-or-link and contextual backlinks

Type `[[` in ordinary Org prose to complete an existing node title or alias.
Completion includes an explicit `[Create new node]` row for the entered title,
including when an existing node has that same title. Selecting that row creates
a fresh ID; unmatched typed text receives a separate explicit Create choice, so
typing alone never creates data. The shorthand is
replaced with the canonical physical Org link, and the existing document
projector derives the Backlink. No reciprocal link is written to the target.

Chinese and other full-width input methods can type `【【` instead of `[[`:
both openers trigger the same completion, and an auto-paired `】】` after
point is consumed when the link is written. The recognised pairs live in
`supertag-reference-shorthand-openers`, so other bracket pairs can be added.

`M-x supertag-add-link` provides the same workflow without relying on a popup.
With an active region it preserves the selected words as the link description;
without one it uses the target title.  A prefix argument prompts for an exact
relation name.  Names entered there are registered for this Emacs session but
are not written to user configuration.  Configured names remain readable after
restart and reindex; automatic cold-start discovery of unconfigured names is a
later milestone.

Fresh targets use `supertag-creation-templates`.  Each data-only plist supplies
`:key`, `:name`, absolute `:target-file`, and optional `:tags`, `:properties`,
and `:body`; for example:

```emacs-lisp
(setq supertag-creation-templates
      '((:key "c" :name "Concept"
         :target-file "/path/to/vault/concepts.org"
         :tags ("concept")
         :properties (("STAGE" . "seed"))
         :body "Initial prose.\n\n** Sources\n")))
```

The default preset targets `concepts.org` in the effective vault.  Creation is
always fresh even when a title matches an existing node; choosing an existing
target never applies a template or changes that target.

Node View now shows both outgoing **References** and incoming **Backlinks** as
context cards: clickable source/target title, file and outline path, relation
kind, and an excerpt centered on the referenced title or alias. These cards are
disposable projections over the existing Store; they are not a second index.

### Unlinked mentions

Node View also discovers plain-text occurrences of the current node's title and
aliases in other source nodes. An unlinked mention is only a candidate: it is
not persisted and does not become a Backlink until you choose **Link** or
**Link all in node**. Existing Org links and literal/code regions are excluded;
Chinese text is matched without imposing incorrect ASCII word boundaries.

**Ignore in node** writes `SUPERTAG_IGNORE_MENTIONS` on the source heading, so
the decision remains inspectable, syncable Org data rather than a hidden cache.
Mention discovery itself uses only a small disposable parse cache. See
`UNLINKED-MENTIONS.md` for the exact boundaries.

## Why this doesn't add friction

The most common fear about "structured tools" is: *"Will I spend more time organizing than actually working?"*

Supertag avoids this in three ways:

### 1. Your files are still plain Org

You never *have* to use the SuperTag views. Write Org normally. The `#tag` markers are just text. If you stop using SuperTag tomorrow, your files are 100% readable Org-mode — you just have some extra `#tag` annotations that don't hurt anything.

### 2. No structure to design first

A heading and some prose are enough. Add tags or links later. You do not need to define fields for each kind of note, maintain required values, or make every note follow the same format.

### 3. Sync is automatic and safe

Supertag reads your files on a timer (configurable via `doc/SYNC-CONFIGURATION.md`). User edits reach Org only through explicit commands and views; sync and reindex never modify Org files. `M-x supertag-sync-full-rescan` rebuilds Org-derived Document Projections in the existing Store. Restore non-rebuildable Semantic Facts from a database backup or synced copy instead.

### Start with one reading note

1. Write a heading and add `#paper`.
2. Record your thoughts in the body and link related notes.
3. Read the collection in Stream and press `e` to keep writing; use Discovery `s` to search all notes.

None of these steps requires field definitions or a property drawer.

---

## When to go deeper

Supertag grows with you. Start simple, add power when you need it:

| After you're comfortable with... | Try this |
|---|---|
| Manual capture | **Capture Templates** — reusable body outlines for common notes (`doc/CAPTURE-GUIDE.md`) |
| Basic queries | **Query Blocks** — embed live query results inside Org files (`doc/ABOUT-QUERY-BLOCK.md`) |
| Default views | **Node View and Discovery** — open a node to see references, mentions and semantic candidates; Discovery multi-selects notes and inserts them back (`doc/VIEW_FRAMEWORK_DEV_GUIDE.md`) |
| Single vault | **Multi-Vault** — separate databases for work/personal (`doc/SYNC-CONFIGURATION.md`) |
| Writing plugins | **Plugin Guide** — extend with your own extractors and services (`doc/SUPERTAG-PLUGIN-GUIDE.md`) |

---

## Data storage (where things live)

| What | Where | Format |
|---|---|---|
| Your Org files | Whatever directories you configure | Plain `.org` text |
| Document projections, tag identities, and historical semantic data | `~/.emacs.d/supertag/supertag-db.el` | Emacs Lisp data |
| Sync state | `~/.emacs.d/supertag/sync-state.el` | File mtimes and hashes |
| Daily backups | `~/.emacs.d/supertag/backups/` | Timestamped DB snapshots |

**Org files own document facts; the database owns semantic facts.** Titles, body text, document topology, Org properties, tag occurrences, and physical Org links belong to the documents. Configured link types such as `supports:` project exact, rebuildable named relations and appear in both endpoint Node Views; property keys do not create relations. Stable tag identities, schemas, legacy semantic relations, boards, automations, and persisted query/view definitions belong to the database. The current database also contains rebuildable projections of Org content; those copies are not independent owners.

`M-x supertag-sync-full-rescan` rebuilds Org-derived nodes, Tag Occurrences, Document Links, and their derived indexes from one complete Org snapshot. It aborts without changing the Store when that snapshot is incomplete. It is not a whole-database reset or Semantic Restore and cannot recover non-rebuildable Semantic Facts. Losing `supertag-db.el` without a backup or synced copy therefore loses non-rebuildable data. See the [data ownership constitution](doc/OWNERSHIP-CONSTITUTION_cn.md) for the authoritative ownership and migration rules.

**6.0 changed the on-disk format of `supertag-db.el` — this is a one-way upgrade.** Since 6.0, the database is written in a deterministic, one-entity-per-line format (what makes git-native sync's field-level merging possible). Older builds (5.9.x and earlier) cannot read entities out of this format — a 5.9.x Emacs pointed at a 6.0+ database will look like it loaded successfully but show an empty store, because the old code only reads the file's first line. Upgrading is safe and automatic (opening an old database with 6.0+ migrates and re-saves it), but **going back to 5.9.x afterward is not** unless you restore a pre-upgrade copy. Two safety nets exist for that: an automatic `backups/supertag-db-premigrate-<old-version>-<timestamp>.el` snapshot the moment an out-of-date database is first loaded, and a `backups/supertag-db-preformat6-<timestamp>.el` snapshot the moment a database still in the old file format is first re-saved (covering the case where the stored version already looked current but the file itself had not been re-saved yet). Neither is ever deleted by the daily-backup cleanup. To downgrade: with Emacs closed, copy the pre-upgrade snapshot over `supertag-db.el`, then reopen with the older build (or evaluate `(supertag-restore)` inside Emacs, which previews, confirms, keeps the old format, refuses a locked database, and first saves a `backups/supertag-db-prerestore-*` recovery point; quit Emacs immediately afterward and reopen with the older build). `M-: (supertag-doctor)` reports both the current on-disk format and how many of each migration snapshot type exist.

---

## Syncing across machines

Git synchronization transports Org text; each machine rebuilds its local Org-derived database cache. Git does not synchronize the database, backups, locks or presence files.

### Multiple vaults

Supertag vaults are isolated. Auto-switch runs only when opening an Org file
through the Org mode hook and is disabled by default. Activate another vault only after the current
vault has been saved; a failed save or an enabled Git sync mode refuses the
switch. Switching clears transient candidates, queued automation, deferred
sync work, scheduler tasks, AI candidates, and migration diagnostics. Scheduler
and discovery history files are derived from the active vault's data directory.
Already-open Org buffers are not reloaded by auto-switch. A Node View whose ID
belongs to another vault renders an empty state until a node from the active
vault is selected.

### Git Org text sync

Configure exactly one `supertag-sync-directories` root, then run `M-x supertag-git-setup`. Setup initializes that root if needed, writes its `.gitignore`, commits only `*.org` (including subdirectories) and the root `.gitignore`, and optionally configures and pushes to an origin URL. Leave the URL empty for a local-only repository. Your database remains at `supertag-data-directory`; setup does not move it or install a merge driver.

For an older repository that tracks a database or `.gitattributes`, setup asks once before removing those paths from Git's index. Files remain on disk and history is retained. `supertag-git-sync-now` only warns about such paths; it does not silently untrack them. Existing unrelated staged files block automatic commits and are left untouched.

On another machine, run `M-x supertag-git-clone` with the remote URL and an empty local directory. It sets the Org sync root and rebuilds from the cloned Org text, then saves the local projection. It never loads the repository's database. Non-document data is not transported by this feature.

Enable `M-x supertag-git-sync-mode` for debounced commits after Org saves, periodic/focus-triggered fetch and merge, and push. Offline commits remain local and are retried after connectivity returns; a rejected push fetches, merges and retries once. `M-x supertag-git-sync-now` skips the debounce. Successful pulls enqueue only added/modified Org files; deleted files use the existing orphan lifecycle (`:file=nil`, with a grace period before garbage collection). The normal periodic scanner remains a fallback.

**Org conflicts:** the mode stays enabled, its lighter gains `!`, and pull/debounce timers pause. The first conflicted file opens with Emacs' built-in `smerge-mode`. Resolve the text, save the files, then run `supertag-git-sync-now` to stage the resolved files, finish the merge, refresh local projections, restore timers and push. Remaining conflict markers or unsaved conflict buffers keep the pause in place. No side is chosen automatically. A repository already conflicted when the mode starts enters the same pause. `M-: (supertag-doctor)` lists the root, tracked caches and conflicts.

Normal Emacs exit can synchronize pending Org work before exiting or explicitly keep it local. Database persistence remains independent of Git transport.

### Sync-folder services (Dropbox/iCloud/Syncthing)

If you'd rather not use git, you can keep `~/.emacs.d/supertag/` (or wherever `supertag-db-file` lives) inside a Dropbox/iCloud/Syncthing-style folder so it follows you between machines — know the tradeoffs before you rely on it:

**Safest mode: one writer at a time.** `supertag-db.el` is a single serialized file. The sync service's job is "replicate the whole file, last writer wins" — it has no idea two Emacs sessions edited different parts of it, so it cannot merge them. If both machines save, one save clobbers the other, silently. The reliable workflow is: **fully quit Emacs on machine A (`C-x C-c`, not just closing the frame) before you start editing on machine B.**

This matters even if you think you're "just reading" on machine A: the auto-save timer (`supertag-db-auto-save-interval`, default 300 seconds) writes the database in the background whenever anything in the session marked it dirty, so an Emacs process left open is a background writer whether you're actively typing or not.

**The 5.9.0 database lock does not cover this.** Since 5.9.0, Supertag takes an advisory lock (`supertag-db-lock`) on the database file to stop two Emacs instances *on the same machine* from stepping on each other. The current version keeps that host-local lock under `temporary-file-directory/supertag-locks/` instead of writing new locks into a network/sync folder; it still only protects against a same-machine double-open and has no meaning across machines. After upgrading, if an old `.#supertag-db.el` remains next to the database, confirm that no older Emacs is using the vault before deleting that stale artifact.

**The presence warning.** To give sync-folder users at least a heads-up (not a lock — a sync service's multi-minute propagation delay means it can't physically be one), Supertag writes a small `supertag-presence.json` file next to the database recording which host last touched it and when. When you load the database and another host's presence looks like it was active in roughly the last 5 minutes (`supertag-presence-stale-seconds`), you'll see a loud warning naming that host and the risk. **What to do when you see it:** if you're sure the other machine is done (Emacs quit there), it's safe to proceed — the warning is one-shot and won't repeat until the other host claims presence again. If you're not sure, go quit Emacs on that other machine first. Run `M-: (supertag-doctor)` any time to see the current presence file's host, age, and verdict (own / foreign-active / foreign-stale). Set `supertag-presence-enable` to `nil` to turn this off entirely.

**Do not sync `sync-state.el` or `backups/`.** Both live in the same data directory as the database but are local, per-machine bookkeeping (`sync-state.el` tracks file mtimes/hashes for *this machine's* filesystem; `backups/` is disk space you don't need to duplicate across machines). If your sync tool syncs the whole data directory, exclude those two paths where the tool allows it; at worst, having them get overwritten just costs an extra Org reindex, it doesn't lose data.

This is a stopgap, not a solution — real multi-machine sync needs something that understands merges, which is exactly what the git-native sync described above does. If concurrent editing across machines is what you're after, use that instead; a sync-folder service only ever gives you the single-writer discipline above.

---

## Migration from older versions

Loading a supported 5.x/6.x database automatically upgrades its data version to
7.1.0. Before any migration changes, SuperTag copies the database into
`backups/supertag-db-premigrate-<old-version>-*.el` and verifies the snapshot
byte for byte. Database-only conversion preserves old fields as pending
records; it does not edit Org files. For versions before 5.0, use
SuperTag 6.x to upgrade first.

Legacy tag inheritance (old `:extends` records) is resolved automatically and
directly into the `:extends` field on the matching Tag entity — no rename, no
confirmation step; whatever cannot be resolved (a missing parent, a cycle, or
a tag that already extends something else) stays visible in
`M-x supertag-migrate-status` under `:unresolved-extends`, each with a reason.

1. Run `M-x supertag-migrate-preview` to review old fields, live Org conflicts,
   and any parent/child `:extends` records that are still unresolved.
2. Run `M-x supertag-migrate-apply` and confirm the changes. It saves through the
   existing Org writers; live drafts in the affected buffers are saved too.
   Conflicts and unexportable records remain available in
   `M-x supertag-migrate-status`. Complete this step before orphan tag cleanup.

A pending-export message appears only when the version migration completes.
If automatic migration is disabled, `M-x supertag-migrate-run` runs the same
verified database migration explicitly.

---

## Troubleshooting quick reference

| Problem | Fix |
|---|---|
| Org-derived nodes or links look stale | `M-x supertag-sync-full-rescan` |
| Auto-sync not starting | Check `supertag-sync-directories` is set correctly |
| Specific file not syncing | `M-x supertag-sync-status`（按需检查文件） |
| Legacy database field values are missing | Reindex cannot restore these historical Semantic Facts; restore from a database backup or synced copy. Org properties instead belong to their source files |
| Sync freezes Emacs | See `doc/SYNC-CONFIGURATION.md` for performance tuning |

---

## Comparison with other tools

| Tool | Supertag's difference |
|---|---|
| **Org-roam** | Org-roam is a graph of linked notes. SuperTag is structured tables on top of Org. They can coexist. |
| **Notion** | Notion locks your data in a proprietary cloud. SuperTag works offline on your own files. |
| **Obsidian** | Obsidian is a different editor. SuperTag is native Emacs — no context switching. |
| **org-ql** | org-ql provides Org queries. Supertag focuses on tag-based reading, note links, Node View, and Discovery search; Org properties remain in source files. |

---

### Optional agent integration and the plain-data API

Agent integration is not required for writing. Historical field provenance remains alongside `:legacy-fields` and is not deleted by this change in direction; its preservation does not imply a field system in the current default workflow.

The agent side talks to Supertag through five plain-data functions in
`supertag-api.el`: `supertag-api-query`, `supertag-api-node`,
`supertag-api-schema`, `supertag-api-catalog`, and `supertag-api-json`.
Arguments and results are plain Elisp data (strings, numbers, keywords,
plists); `supertag-api-json` renders a result as JSON, and
`supertag-api-catalog` describes each function's effect and parameters so a
host can register them as LLM tools under its own authority model. Writes go
through Node View and the Org writer; there are no API write functions.

### How concept mentions behave

- `supertag-promote` selects a key from the shared `supertag-creation-templates`. With an active region, only the selected text becomes an ordinary Org link; its containing heading stays in place. Without a region, Promote operates on the current heading. Same-name candidates show their actual contents and require explicit reuse or new creation, never automatic merging.
- Fresh creation applies the complete template (file, tags, properties and initial body). Reuse preserves the ID, subtree, existing properties and body, adding tags and filling only absent properties. An outside heading moves to the template file and leaves a plain link at its old location, not an identified Move stub. Initial body is never inserted into a reused node.
- Monitoring includes only headings with persisted Org IDs in current template target files, regardless of whether they were created manually, by Find, Add Link or Promote. ID-less headings are not monitored. Explicit identity-requiring operations may assign an ID through the document writer; reading, preview and cancellation do not. Retargeting/removing the last template reference removes only monitoring membership: files, old marker properties and links are untouched.
- Mentions are display-only. Org links, code/verbatim, comments and `COMMENT` subtrees, keywords/drawers, source blocks, and tables are not highlighted.
- A title or alias shared by multiple monitored nodes stays plain. Generated Embed contents are excluded too. Only explicit link actions write links.

For everyday use, assemble purpose-specific commands instead of selecting a template each time. These are user-defined commands, not built-ins; once defined, invoke them through `M-x` or key bindings:

```emacs-lisp
;; Run after your normal Supertag configuration. Adjust these destinations.
(require 'supertag-concept)
(setq supertag-creation-templates
      (list
       (list :key "concept" :name "Concept"
             :target-file (expand-file-name "concepts.org" org-directory)
             :tags '("concept"))
       (list :key "person" :name "Person"
             :target-file (expand-file-name "people.org" org-directory)
             :tags '("person"))
       (list :key "quote" :name "Quote"
             :target-file (expand-file-name "quotes.org" org-directory)
             :tags '("quote"))))

(supertag-define-promote-command supertag-promote-concept "concept")
(supertag-define-promote-command supertag-promote-person "person")
(supertag-define-promote-command supertag-promote-quote "quote")

(define-key org-mode-map (kbd "C-c n c") #'supertag-promote-concept)
(define-key org-mode-map (kbd "C-c n P") #'supertag-promote-person)
(define-key org-mode-map (kbd "C-c n q") #'supertag-promote-quote)
```

These commands skip template selection, but retain reuse/new choices and save confirmation. Keep `supertag-promote` for occasional selection of another template. Templates only configure destinations, tags, properties and initial body; all commands share the same Promote implementation. The example `setq` replaces the shared template list (also used by Add Link and Find Node); merge entries into existing configurations rather than overwriting them, and adjust destinations and bindings. Keys are resolved at invocation time, so later configuration changes do not require redefining commands.

The default template still targets `concepts.org`. Confirmation saves whole affected files, including existing drafts. Cancellation before confirmation is zero-write. Cross-file Promote is not atomic: a target already saved is retained if saving the old-location link or current selection later fails. Structured errors carry the failed stage, identities and callable `:retry`/`:retry-args`; retry that operation instead of invoking Promote again. Save failures retain drafts, and projection failures retain durable text. Recovery is in-process, not a crash journal.

On projection cards, `t`/`r` add or remove tags remotely; Stream title-line `#tag` supports RET/r/c/R/D, and remote writes refuse unsaved edits in the target file.

### Context actions at point

With optional Embark installed, run `embark-act` on an object. RET selects its default action; `embark-dwim` runs the default directly.

| Object | RET default | Other keys |
|---|---|---|
| Org heading or body | Toggle Node View (`v` also works; no ID is created for an unidentified heading) | `t` add tag, `r` remove tag, `l` add link, `d` select and delete link, `m` move, `M` move and leave link, `p` Promote, `x` extract properties (optional superchat) |
| #tag | Open its Stream | `r` remove from this node, `c` change this node's tag, `R` rename everywhere, `D` delete everywhere; global changes preview and confirm |
| id link | Open link | `d` delete this complete link, including its description, save, and refresh its projection |
| Concept mention | Open concept node | `l` turn this occurrence into a physical link |
| Node reference | Visit referenced node | `v` open Node View |
| Writable Org region | Add link | `l` add link, `t` tag nodes in the region, `p` Promote selected text |

Discovery never creates IDs. A #tag on a heading takes priority over the heading; other Org links are handled by Embark's Org integration. Use `embark-cycle` to switch to native Org objects. This prototype covers these locations; the full command catalog remains available through `supertag-menu` and M-x.

---



## Further reading

- **Sync configuration**: `doc/SYNC-CONFIGURATION.md`
- **📖 A Day with Supertag**: `doc/A-DAY-WITH-SUPERTAG.org` — complete workflow tutorial with tangleable Elisp
- **Automation rules**: `doc/AUTOMATION-SYSTEM-GUIDE.md`
- **Capture system**: `doc/CAPTURE-GUIDE.md`
- **Virtual columns**: `doc/VIRTUAL_COLUMNS.md`
- **Plugin development**: `doc/SUPERTAG-PLUGIN-GUIDE.md`
- **View framework**: `doc/VIEW_FRAMEWORK_DEV_GUIDE.md`
- **vs old architecture**: `doc/COMPARE-NEW-OLD-ARCHITECTURE.md`

---

Supertag is developed as free software under the GPLv3. Contributions, bug reports, and feature requests are welcome on GitHub.

## Configuration variables

The following table is generated from the loaded source; purposes use each docstring’s first sentence.

;; 108 defcustoms

**supertag-ai.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-ai-max-body-chars` | `8000` | Maximum number of own-body characters sent for extraction. |
| `supertag-ai-prompts` | `list of 1 entries, see docstring` | Named extraction prompts. |
| `supertag-ai-timeout` | `60` | Runtime request timeout in seconds. |

**supertag-automation.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-automation-verbose` | `nil` | When non-nil, log verbose automation diagnostics. |

**supertag-concept.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-concept-alias-separator-regexp` | `"[,，;；]"` | Regexp used to split concept aliases stored in SUPERTAG_ALIASES. |
| `supertag-concept-default-file` | `nil` | Default Org file used for newly created concept nodes. |
| `supertag-concept-min-term-length` | `2` | Minimum character length for a concept title or alias mention. |

**supertag-core-async.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-async-batch-size` | `1` | Number of files to process in a single idle cycle. |
| `supertag-async-idle-delay` | `0.5` | Seconds of idle time to wait before processing the next job in the queue. |

**supertag-core-change.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-change-bridge-debug` | `nil` | When non-nil, log bounded legacy bridge delivery diagnostics. |

**supertag-core-persistence.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-db-auto-migrate` | `t` | When non-nil, automatically migrate an out-of-date database after load. |
| `supertag-db-auto-save-interval` | `300` | Auto-save interval in seconds. |
| `supertag-db-backup-directory` | `"<data-directory>/backups"` | Directory for database backups. |
| `supertag-db-backup-interval` | `86400` | Daily backup interval in seconds (default: 24 hours). |
| `supertag-db-backup-keep-days` | `3` | Number of days to keep daily backups. |
| `supertag-db-file` | `"<data-directory>/supertag-db.el"` | Database file path. |
| `supertag-db-lock` | `t` | When non-nil, protect the database from concurrent multi-instance access. |
| `supertag-db-lock-directory` | `string of 64 chars, see docstring` | Directory for local database advisory lock files. |
| `supertag-db-verify-after-save` | `t` | When non-nil, verify the database file after saving. |
| `supertag-presence-enable` | `t` | When non-nil, write and check an advisory presence file for cross-machine awareness. |
| `supertag-presence-stale-seconds` | `300` | Age in seconds beyond which a foreign presence record is ignored. |

**supertag-discovery.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-discovery-history-file` | `nil` | File to store Discovery history. |
| `supertag-discovery-history-max-items` | `100` | Maximum number of keywords to keep in history. |
| `supertag-discovery-initial-sample-size` | `10` | Number of notes shown when Discovery opens or refreshes its sample. |

**supertag-embark.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-embark-integration` | `t` | Register Supertag contextual actions when optional Embark is loaded. |

**supertag-git.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-git-sync-commit-debounce` | `30` | Seconds of quiet after the LAST detected change before `supertag-git-sync-mode' auto-commits. |
| `supertag-git-sync-focus-pull-min-interval` | `60` | Minimum seconds between two focus-triggered pulls (rate limit). |
| `supertag-git-sync-pull-interval` | `300` | Seconds between automatic background `git fetch' (+ merge if behind) attempts while `supertag-git-sync-mode' is enabled. |

**supertag-link.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-reference-context-before` | `72` | Preferred number of characters shown before the matched reference term. |
| `supertag-reference-context-length` | `220` | Maximum number of characters in one contextual backlink excerpt. |
| `supertag-reference-shorthand-openers` | `(("[[" . "]]") ("【【" . "】】"))` | Opener/closer pairs that start a create-or-link shorthand. |

**supertag-mention.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-mention-context-after` | `120` | Maximum source characters shown after an unlinked mention. |
| `supertag-mention-context-before` | `64` | Maximum source characters shown before an unlinked mention. |
| `supertag-mention-max-results` | `300` | Maximum unlinked mention candidates returned for one target node. |
| `supertag-mention-min-term-length` | `2` | Minimum title or alias length considered for unlinked mentions. |
| `supertag-mention-protected-range-cache-size` | `128` | Maximum ephemeral Org parse results retained by the mention scanner. |
| `supertag-mention-result-cache-size` | `64` | Maximum target queries retained by the disposable mention result cache. |

**supertag-ops-relation.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-reference-backlink-include-timestamp` | `nil` | Legacy option retained for compatibility. |

**supertag-semantic.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-semantic-curl-program` | `"curl"` | Program used for asynchronous embedding HTTP requests. |
| `supertag-semantic-enabled` | `nil` | Whether to show and compute semantic candidates. |
| `supertag-semantic-endpoint` | `"http://localhost:11434"` | Base URL of an Ollama-compatible /api/embed endpoint. |
| `supertag-semantic-max-chars` | `1500` | Maximum own-body characters embedded after the title and outline path. |
| `supertag-semantic-max-results` | `5` | Maximum similar-note candidates shown. |
| `supertag-semantic-min-similarity` | `0.4` | Minimum similarity, calibrated only on synthetic notes so far. |
| `supertag-semantic-model` | `"bge-m3"` | Embedding model available at the endpoint. |
| `supertag-semantic-preview-lines` | `3` | Maximum lines of a candidate's own-body preview. |
| `supertag-semantic-request-chars` | `6000` | Approximate text-character budget per request; one longer node may exceed it. |
| `supertag-semantic-save-interval` | `30` | Minimum seconds between partial side-car saves; a drained queue saves immediately. |

**supertag-service-node-identity.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-node-location-org-id-fallback` | `t` | When non-nil, use `org-id-find' for nodes absent from the Store. |

**supertag-service-org.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-org-id-open-link-auto-enable` | `t` | When non-nil, let `org-id-open-link` resolve IDs via Supertag first. |

**supertag-services-capture.el**

The standalone Supertag Capture engine is retired. Use standard `org-capture`;
the opt-in Supertag integration remains available and is disabled by default.

| Variable | Default | Purpose |
|---|---|---|
| `supertag-org-capture-auto-enable` | `nil` | When non-nil, enable Supertag integration with `org-capture'. |

**supertag-services-scheduler.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-scheduler-check-interval` | `300` | Interval in seconds for master timer to check for pending tasks. |

**supertag-services-sync.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-sync-auto-create-node` | `nil` | Deprecated compatibility option; sync never invents heading IDs. |
| `supertag-sync-auto-interval` | `900` | Interval in seconds for automatic synchronization. |
| `supertag-sync-auto-start` | `t` | Automatically start Supertag auto-sync after Emacs startup. |
| `supertag-sync-auto-start-initial-delay` | `3` | Seconds to wait after startup before the first auto-start attempt. |
| `supertag-sync-auto-start-max-retries` | `24` | Maximum number of auto-start retries before giving up. |
| `supertag-sync-auto-start-retry-interval` | `5` | Seconds between auto-start retry attempts when directories are not yet available. |
| `supertag-sync-directories` | `nil` | List of directories to monitor for automatic synchronization. |
| `supertag-sync-directories-mode` | `unified` | How to interpret `supertag-sync-directories`. |
| `supertag-sync-exclude-directories` | `nil` | List of directories to exclude from synchronization. |
| `supertag-sync-file-pattern` | `".org$"` | Regular expression for matching files to synchronize. |
| `supertag-sync-hash-props` | `list of 8 entries, see docstring` | Additional properties to include when calculating node hashes. |
| `supertag-sync-idle-delay` | `1.0` | Seconds of idle time required before automatic sync runs. |
| `supertag-sync-import-org-tags` | `nil` | When non-nil, import Org native `:tag:` syntax as tag occurrences. |
| `supertag-sync-max-delete-count` | `1000` | Maximum number of nodes allowed to be deleted in a single GC pass. |
| `supertag-sync-max-delete-ratio` | `0.5` | Maximum allowed ratio of nodes to delete in a single GC pass. |
| `supertag-sync-node-creation-level` | `1` | Minimum heading level for automatic node creation. |
| `supertag-sync-orphan-grace-seconds` | `3600` | Grace period in seconds before deleting orphaned nodes. |
| `supertag-sync-quiet-when-idle` | `t` | If non-nil, suppress routine sync summary/diagnostic messages when no changes were detected. |
| `supertag-sync-smart-detection-enabled` | `nil` | If non-nil, enable smart detection to skip unchanged files during sync. |
| `supertag-sync-smart-detection-verbose` | `nil` | If non-nil, show messages about smart detection decisions during sync. |
| `supertag-sync-snapshot-guard` | `t` | When non-nil, sync uses snapshot state to guard destructive operations. |
| `supertag-sync-state-file` | `"<data-directory>/sync-state.el"` | File to store sync state data. |
| `supertag-tag-style` | `inline` | Style to write tags when generating or inserting Org headlines. |
| `supertag-text-link-relation-types` | `nil` | Exact non-empty Org link types that project as named relations. |

**supertag-services-template.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-creation-templates` | `nil` | Creation presets shared by Add Link, Find Node and Promote. |

**supertag-ui-commands.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-batch-tag-insert-position` | `end` | Where to insert tags when adding tags in batch mode. |
| `supertag-capture-tag-position` | `end` | Where to place tags when creating a headline via capture. |

**supertag-ui-completion.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-completion-auto-enable` | `t` | Whether to automatically enable tag completion in org-mode buffers. |

**supertag-view-helper.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-view-style-auto-enable` | `t` | Whether to automatically enable supertag-view-style-mode in org buffers. |
| `supertag-view-style-tag-face-properties` | `(:foreground "snow3")` | Face properties for inline supertags. |
| `supertag-view-style-unresolved-tag-face-properties` | `(:inherit shadow :underline t)` | Face properties for inline tag tokens with no registered tag. |

**supertag-view-node.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-view-node-auto-show` | `nil` | Whether to automatically show the Node View side window and follow context. |
| `supertag-view-node-side` | `right` | Side where the Node View side window appears. |
| `supertag-view-node-side-size` | `0.33` | Default size of the Node View side window. |
| `supertag-view-node-strip-todo-keywords` | `t` | Whether to strip TODO keywords from node titles in view buffers. |
| `supertag-view-node-todo-keywords` | `list of 11 entries, see docstring` | List of TODO keywords to strip from node titles. |

**supertag-view-svg-tag.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-svg-tag-color-alpha` | `1.0` | Opacity of the colored style background (0 = invisible, 1 = opaque). |
| `supertag-svg-tag-enable` | `t` | When non-nil, render #tags as SVG pill badges. |
| `supertag-svg-tag-font-family` | `nil` | Explicit SVG font family, or nil to use the default face family. |
| `supertag-svg-tag-font-scale` | `0.68` | Font size scale factor relative to the frame character height. |
| `supertag-svg-tag-font-weight` | `"500"` | Font weight used inside SVG tags (e.g. "normal", "500", "bold"). |
| `supertag-svg-tag-min-column-em` | `0.6` | Minimum width per display column, in units of the SVG font size. |
| `supertag-svg-tag-padding-x` | `8` | Horizontal padding (px) inside the SVG tag. |
| `supertag-svg-tag-radius` | `100` | Corner radius (px) of SVG tag badges. |
| `supertag-svg-tag-show-hash` | `nil` | When non-nil, include the leading '#' in the SVG badge. |
| `supertag-svg-tag-stroke-width` | `0` | Stroke width for SVG tag borders. |
| `supertag-svg-tag-style` | `colored` | Visual style of SVG tags. |

**supertag.el**

| Variable | Default | Purpose |
|---|---|---|
| `supertag-active-sync-directory` | `nil` | Active vault root directory when `supertag-sync-directories` lists multiple roots. |
| `supertag-data-directory` | `"<user-emacs-directory>/supertag"` | Directory for storing Supertag data. |
| `supertag-file-id-source` | `org-roam` | Policy for recognizing stable file node IDs. |
| `supertag-project-root` | `directory of supertag.el at load time` | The root directory of the supertag project. |
| `supertag-vault-auto-switch` | `nil` | When non-nil, automatically switch the active vault for Org buffers. |
| `supertag-vault-modeline-indicator` | `t` | When non-nil, show the matched vault name in the mode line for Org buffers. |
