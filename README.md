# Supertag – Structured knowledge, inside Emacs, on your own files

[中文](./README_CN.md) | [English](./README.md)

Supertag turns your plain Org headings into a **structured, queryable knowledge base**.
No external services. No Python. No lock-in. Your `.org` files stay yours — we just make them smarter.

> **Upgrading from Org-Supertag?** Version 6.0 is a breaking rename with no
> compatibility aliases or automatic data move. Follow
> **[Migrating to Supertag](doc/MIGRATING-TO-SUPERTAG.md)** before starting it.

> **⚠️ Upgrading a database that still uses nested Tag fields?**
> Complete the **global field migration** before editing fields with this version. The global field model is now mandatory; `supertag-use-global-fields` is obsolete and ignored.
> See [`doc/GLOBAL-FIELD-MIGRATION-GUIDE.md`](doc/GLOBAL-FIELD-MIGRATION-GUIDE.md) for step-by-step instructions.

> **Why this matters**: Ever tried to find "all papers I haven't read yet" across your notes? Or "all tasks due this week assigned to @alice"? Plain Org-mode can't do this without painful manual tagging and grep. Supertag makes it as easy as clicking a column header.

> **📖 Ready to dive in?** Start with **[A Day with Supertag](doc/A-DAY-WITH-SUPERTAG.org)** — a complete walkthrough of one person's daily workflow, with copy-paste Elisp you can tangle into your config. (中文版：[Supertag 的一天](doc/A-DAY-WITH-SUPERTAG_CN.org))

---

## What you get (and why it's easier)

| Without Supertag | With Supertag |
|---|---|
| Manually typing `:PROPERTIES:` drawers for every field | Type `#tag` once, define fields once, fill values in a Table View |
| `grep` + regex to find "high priority tasks this week" | `M-x supertag-search` — structured query, instant results |
| Copy-pasting between notes to link related items | Type `[[` and complete — one forward Org link, contextual backlinks |
| Every new project means rebuilding your tracking system from scratch | Define a `#project` tag schema once, reuse forever |
| "Where did I write that meeting note?" | Query `#meeting` by date, participant, or decision |

**The core idea**: You keep writing Org files normally. Supertag reads them, builds a structured index, and gives you database-like views *on top of* your plain text.

---

## Installation and first run

```emacs-lisp
;; With straight.el
(straight-use-package '(supertag :host github :repo "yibie/supertag"))
(require 'supertag)
```

Then, in Emacs:

1. **`M-x supertag-setup`** — the guided setup wizard. It reports your current status, lets you pick which directories to sync, choose a file-ID source (Org-roam, Denote, or both), set persistence options, and optionally run the first scan.
2. **`M-x supertag-menu`** — the task menu for Capture & Write, Organize, Find & View, and Maintain. Use it to discover commands instead of memorizing them.
3. **`M-x supertag-doctor`** — run this any time something looks off. It's a full health check with guided repairs.

That's it. No API keys, no database server to run. Your existing Org files are already compatible.

---

## The one command to remember

**`M-x supertag-menu`** is organized around four jobs: **Capture & Write**, **Organize**, **Find & View**, and **Maintain**. Daily commands stay on the first screen; specialized automation, migration, query, and display commands live in the matching `More...` submenu. If you remember nothing else from this README, remember this one.

The easiest way to get keybindings is the built-in global minor mode:

```emacs-lisp
(supertag-act-mode 1)  ; C-c s → default action, C-c S → context action menu
```

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

After changing the setting, run `M-x supertag-reindex-org`.

---

## The three things you need to know

Supertag is built on three simple ideas:

### 1. `#tag` turns a heading into a record

```org
* Attention Is All You Need #paper
```

The `#paper` tag means "this heading belongs to the 'paper' collection." Like tagging in any system — but with superpowers.

### 2. Tags have fields (like database columns)

Once you've tagged something as `#paper`, you define what information you want to track:

```
authors  →  text
year     →  number
venue    →  text
status   →  select (unread / reading / done)
rating   →  number (1–5)
```

You define these **once per tag** (in the Schema View, `M-x supertag-view-schema`). Every `#paper` node automatically gets these fields.

### 3. Views let you browse, fill, and query your data

- **Table View** (`M-x supertag-view-table`): Like a spreadsheet for your tagged nodes. Sort by any column, filter, bulk edit.
- **Node View** (`M-x supertag-view-node`): Edit a single node's fields with auto-completion.
- **Kanban** (`M-x supertag-view-kanban`): Board-style view for workflow tags (`#task`, `#project`).
- **Stream View** (`M-x supertag-view-stream`): Browse a chronological, single-column list grouped by creation day, with `title  #tags` rows for a tag and all transitive `:extends` descendants. Use `n`/`p` to move naturally, `e` to edit the expanded source node (`C-c C-c` confirms, `C-c C-k` aborts), or `v` for fields in Node View.

---

## Step-by-step: your first 5 minutes

Let's say you're a researcher. You have papers scattered across your notes.

### Step 1: Tag a paper

Go to any Org heading and run `M-x supertag-add-tag`, type `paper`:

```org
* Attention Is All You Need #paper
```

### Step 2: Define what a "paper" tracks

`M-x supertag-view-schema` → find `paper` → add fields:

| Field | Type |
|-------|------|
| `authors` | text |
| `year` | number |
| `status` | select: unread, reading, done |
| `rating` | number 1–5 |

### Step 3: Fill in data

`M-x supertag-view-table` → choose tag `paper`. You'll see a table with all `#paper` nodes. Click any cell to edit. Sort by year to find recent papers. Filter by `status = unread` to see your reading queue.

### Step 4: Tag more papers

Go to other paper headings, add `#paper`. They appear in the table automatically.

**That's it. You now have a queryable research library.** No copy-paste, no PROPERTIES drawers, no manual organization.

---

## Real workflows (with commands you can copy)

### 📚 Academic reading queue

```org
* Diffusion Models Survey #paper
* ViT Explained #paper
* CLIP Paper #paper
```

Define fields on `#paper`: `authors`, `year`, `status` (unread/reading/done), `rating`.

**Daily workflow**:
1. `M-x supertag-view-table` → tag `paper` → sort by `status`
2. Filter to `unread` → pick one → `o` to jump to the heading
3. After reading: click `status` cell → select `done` → rate it

**Why it's convenient**: You find papers by status and rating, not by scrolling through 50 headings and reading each title.

### 📋 Project task tracking

```org
* Rewrite sync layer #task #project
* Fix auth bug #task
* Deploy v2.1 #task
```

Define fields on `#task`: `status`, `priority`, `due`, `assignee`.

**Daily workflow**:
1. `M-x supertag-view-kanban` → tag `task` → columns by `status`
2. Drag tasks between columns as they progress
3. `M-x supertag-search` → `(and (tag "task") (field "priority" "high"))` for urgent items

**Why it's convenient**: Your tasks live in their natural Org files (meeting notes, project files), but you see them all in one board.

### 📝 Meeting notes with decisions

```org
* Sprint Planning 2024-11-15 #meeting
```

Define fields on `#meeting`: `date`, `participants`, `decisions`, `action-items`.

**Workflow**:
1. `M-x supertag-capture` → choose `meeting` template → fill fields
2. Later: `M-x supertag-search` → `(tag "meeting")` → filter by date range
3. Find "all decisions from Q4" in seconds

**Why it's convenient**: Meeting notes live where they belong (project files), but you query across all of them at once.

---

## Commands you'll use every day

| What you want to do | Command | What happens |
|---|---|---|
| Tag something | `M-x supertag-add-tag` | Adds `#tag` inline, node appears in that tag's table |
| See all nodes of a tag | `M-x supertag-view-table` | Spreadsheet view. Sort, filter, edit cells |
| Browse a tag chronologically | `M-x supertag-view-stream` | Single-column creation-day groups with `title  #tags` rows, including transitive `:extends` descendants; `e` opens an expanded source edit, `C-c C-c` confirms and `C-c C-k` aborts |
| Edit a node's fields | `M-x supertag-view-node` | Form view with completion, pickers, and validation |
| Fill a node's fields in one pass | `M-x supertag-edit-fields` | Prompts for every field of one tag, then commits the changed values together |
| Board view | `M-x supertag-view-kanban` | Drag-and-drop between columns |
| Define tag fields | `M-x supertag-view-schema` | Add/remove fields, set types, configure inheritance |
| Define typed relations | Schema View: `a l` | Declare a source Type, target Type, direction labels, and cardinalities |
| Link typed nodes | `M-x supertag-link-menu` | Add/remove only relations valid for the current node's Type |
| Declare Types, Fields, and Links in code | `supertag-defontology` in an Elisp file, then `M-x supertag-ontology-preview` / `M-x supertag-ontology-apply` | Loading only registers the declaration; preview classifies every change as SAFE, BEHAVIORAL, or DESTRUCTIVE; apply deploys it in one transaction |
| Run an Action on a node | `M-x supertag-action-run` (or `A` in Node View) | Shows the planned effect (`set-field status = "active" -> "done"`) and executes it under the Action's Policy |
| Merge duplicate tags | Schema View: mark tags with `m m`, then press `m M` | Preview and merge into a new/existing tag; updates fields, nodes, references, and Org files atomically |
| Capture new node | `M-x supertag-capture` | Quick entry with template, adds to your Org file |
| Search | `M-x supertag-search` | Structured query. Save results to file |
| Link related nodes | Type `[[` and complete, or `M-x supertag-reference-insert` | Reuses a node or explicitly creates a concept, writes one forward Org link, and derives the target Backlink |
| Review unlinked mentions | Open Node View and use **Unlinked Mentions** | Finds plain-text title/alias mentions as disposable candidates; link one, link all in the source node, or ignore that target in the source |
| Preview an ontology migration | `M-x supertag-ontology-migration-preview` | Compares a declared migration with the live destructive Schema diff and shows every data action before mutation |
| Apply an ontology migration | `M-x supertag-ontology-migration-apply` | Converts data, deploys the destructive Schema change, reconciles derived relations, and records one applied ledger entry atomically |
| Promote selected text to a concept | `M-x supertag-promote-concept` | Creates/reuses a concept node, references it from the current node, and keeps the text plain |
| Confirm an agent-written field value | `c` in Node View | The value stays; its provenance becomes human and the ⟨AI⟩ badge goes away |
| Highlight concept mentions | `M-x supertag-concept-link-mode` | Shows concept title/alias mentions as amber semantic highlights, not stored links |
| Act on the object at point | `M-x supertag-act` | Lists the actions that apply to the current tag, node, field, mention, region, link, button, or table cell, default first |
| Run the default action immediately | `M-x supertag-act-dwim` | Executes the default action for the object at point without a menu |
| Reindex Org documents | `M-x supertag-reindex-org` | Rebuilds Document Projections from one complete snapshot; never restores Semantic Facts |

Beyond single-command lookups, Supertag has a small S-expression query
language for combining tags, fields, dates, full-text search, and typed-Link
traversal, e.g. `(and (tag "task") (not (field "status" "done")))` or
`(link work/tasks (field "status" "blocked"))`. Write one in a
`supertag-query-block` babel block, save it with `M-x supertag-query-save`
for reuse, or build one interactively with `M-x supertag-query-build`. See
`doc/QUERY.md` for the full grammar.

Optional keybindings:

```emacs-lisp
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c n l") #'supertag-reference-insert)
  (define-key org-mode-map (kbd "C-c n p") #'supertag-promote-concept)
  (define-key org-mode-map (kbd "C-c n o") #'supertag-concept-open-at-point))
```

### Create-or-link and contextual backlinks

Type `[[` in ordinary Org prose to complete an existing node title or alias.
When there is no exact term, completion includes an explicit
`[Create new concept]` row; typing alone never creates data. The shorthand is
replaced with the canonical physical Org link, and the existing document
projector derives the Backlink. No reciprocal link is written to the target.

Chinese and other full-width input methods can type `【【` instead of `[[`:
both openers trigger the same completion, and an auto-paired `】】` after
point is consumed when the link is written. The recognised pairs live in
`supertag-reference-shorthand-openers`, so other bracket pairs can be added.

`M-x supertag-reference-insert` provides the same workflow without relying on
a popup. With an active region it uses the selected text as the initial title.
New concepts normally append to `concepts.org` in the active vault or matching
sync root without another location prompt; use a prefix argument to choose the
destination, or customize `supertag-concept-create-target-function`.

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

### Ontology as code

Once a tag/field pattern stabilises, declare it in Elisp instead of maintaining
it by hand in Schema View:

```emacs-lisp
(supertag-defontology work
  :version 1
  (field status :label "Status" :type options :options (idea active blocked done))
  (type project :label "Project" :fields (status))
  (type task    :label "Task"    :fields (status))
  (link tasks :label "Tasks" :inverse-label "Project"
        :from project :to task :from-cardinality many :to-cardinality one))
```

Loading the file only registers the declaration. `M-x supertag-ontology-preview`
shows the deployment plan against the live Store, with every operation classed
as **SAFE** (new fields, types, links, label changes), **BEHAVIORAL** (Functions,
Actions, Policies — apply asks for explicit approval), or **DESTRUCTIVE** (field
type changes, removed options, tightened cardinality — apply refuses until a
matching migration exists). `M-x supertag-ontology-apply` deploys the plan in
one transaction; redeploying an unchanged declaration is a no-op.

A deployed Type answers to its declaration key as well as its label: with the
module above, `#project` and `#Project` both bind to the Project type, and
`:aliases (proj 项目)` on a `type` form adds more spellings. Aliases you add by
hand in Schema View are kept.

Typed links then enforce endpoint types and cardinality (`Link Tasks permits
only one source for target node …`), and queries can traverse them:
`(and (tag "Project") (link work/tasks (field "status" "blocked")))`. Node View
lists each node's typed links and — once you add `function`, `action`, and
`policy` forms — its computed Functions and runnable Actions. Start from
`examples/personal-work-ontology.el`; see `ONTOLOGY-LINK-WORKFLOW-V5.md` and
`ONTOLOGY-FUNCTION-ACTION-V10.md` for the full forms.

### Ontology migrations

Ordinary ontology deployment accepts safe additions and compatible updates. A
destructive change—such as converting a Field type, removing a Type/Field
association, or tightening Link cardinality—must be paired with an explicit
`supertag-defmigration` declaration. Loading migration files only registers
pure declarations; preview is read-only, and apply commits data actions, the
Schema deployment, derived-relation reconciliation, and the Store-owned applied
ledger through one transaction.

Preview also flags transforms that would silently clear data: when a
`transform-field` callback maps an existing value to `nil`, the plan shows a
`WARNING :transform-clears-value` issue and a `cleared=N` count. Return
`supertag-ontology-migration-drop` to remove a value on purpose.

Migration DSL v1 deliberately supports only `transform-field`, `detach-field`,
and `tighten-link`. Every destructive operation must have exact coverage; Type
or global Field deletion, parent/endpoint changes, and rebinding remain blocked
instead of being hidden behind a force flag. See `ONTOLOGY-MIGRATION-V8.md` and
`examples/ontology-migration-v8-example.el`.

Supertag does not add another Transclusion implementation here. Existing embed
behavior remains owned by `supertag-ops-embed.el`,
`supertag-services-embed.el`, and `supertag-ui-embed.el`.

### Agent-written values and the plain-data API

Designing fields pays off when something else fills them. When an agent (for
example superchat through its Supertag bridge) writes a field, the value is
stored like any other, and a **provenance** record is kept beside it: who
asserted it (`:agent` or `:human`), when, with which model, and the node's text
`:hash` at that moment. Node View shows such values with an **⟨AI⟩** badge, or
**⟨AI · outdated⟩** once the node's text changed after the extraction; Table
View marks the cell ⟨AI⟩ / ⟨AI?⟩. Press `c` on the field in Node View to
confirm it: the value stays, its provenance becomes `:human`, and the badge
disappears. Values you edit in Node View, Table View, or Kanban are recorded as
human-written; values written by sync, automation, or older code carry no
record and count as plain facts.

The agent side talks to Supertag through six plain-data functions in
`supertag-api.el`: `supertag-api-query`, `supertag-api-node`,
`supertag-api-schema` read; `supertag-api-set-field`, `supertag-api-link`,
`supertag-api-add-field` write. Arguments and results are plain Elisp data
(strings, numbers, keywords, plists), `supertag-api-json` renders a result as
JSON, and `supertag-api-catalog` declares each function's effect (`:read` /
`:write`) and parameters so a host can register them as LLM tools under its own
authority model. Writes use the same validation and transactions as the UI;
`set-field` binds the agent value to the node's current hash, and `link` only
creates typed Links (document references stay owned by the Org text).

```emacs-lisp
(supertag-api-set-field "node-id" "Status" "active" :model "claude-sonnet-5")
;; => (:node "node-id" :tag "project" :field "status" :name "Status"
;;     :value "active" :previous nil :changed t
;;     :provenance (:origin :agent :at "…" :model "claude-sonnet-5" :source-hash "…"))
```

### How concept mentions behave

- Promotion accepts non-empty text inside an Org node. It reuses a unique heading node or creates one, adds one explicit reference, and leaves the selected text unchanged. A same-title file node is not silently converted into a concept.
- Mentions are display-only. Org links, code/verbatim, comments and `COMMENT` subtrees, keywords/drawers, source blocks, and tables are not highlighted.
- A title or alias shared by multiple concepts is ambiguous. SuperTag does not choose a target from hash-table order; the mention stays plain and promotion reports the conflict.

After changing concept titles or aliases outside SuperTag, run `M-x supertag-concept-refresh` in enabled buffers.

### Context actions at point

Run `M-x supertag-act` on an inline tag, node, field, concept mention,
selected region, Org link, Emacs button, or table cell to choose from the
actions that apply to that object; the default action is listed first.
`M-x supertag-act-dwim` runs the default action immediately. The complete
`supertag-menu` remains available from the action list and opens directly
when point has no semantic target. With Embark installed, the same objects
are also exposed as `embark-act` targets, with the originally detected object
preserved for the selected action. Neither command has a default keybinding
unless you enable `supertag-act-mode`; then `C-c s` runs the default action
and `C-c S` opens the context action menu. Open the full command catalog with
`M-x supertag-menu`.

---

## Why this doesn't add friction

The most common fear about "structured tools" is: *"Will I spend more time organizing than actually working?"*

Supertag avoids this in three ways:

### 1. Your files are still plain Org

You never *have* to use the SuperTag views. Write Org normally. The `#tag` markers are just text. If you stop using SuperTag tomorrow, your files are 100% readable Org-mode — you just have some extra `#tag` annotations that don't hurt anything.

### 2. Fields are defined once, used everywhere

You define `status`, `priority`, `due` for `#task` **one time**. Every `#task` node you create from then on gets those fields automatically. The upfront cost is 30 seconds; the payoff is permanent.

### 3. Sync is automatic and safe

Supertag reads your files on a timer (configurable via `doc/SYNC-CONFIGURATION.md`). User edits reach Org only through explicit commands and views; sync and reindex never modify Org files. `M-x supertag-reindex-org` rebuilds Org-derived Document Projections in the existing Store. Restore non-rebuildable Semantic Facts from a database backup or synced copy instead.

### Compare the effort

**Without SuperTag** — tracking papers:
- Manually write `:PROPERTIES:` drawer with `:authors:`, `:year:`, `:status:`
- `grep` for `status.*unread` across files
- No sorting, no filtering, no table view

**With SuperTag** — tracking papers:
- Add `#paper` to headings (2 seconds each)
- Define fields once in Schema View (30 seconds)
- Table View for sorting, filtering, editing (instant)

**The win**: For 10 papers, you save ~5 minutes of PROPERTIES typing and get a live-updating table view for free. For 100 papers, the difference is hours.

---

## When to go deeper

Supertag grows with you. Start simple, add power when you need it:

| After you're comfortable with... | Try this |
|---|---|
| Tags and Table View | **Automation** — rules that auto-fill fields based on conditions (`doc/AUTOMATION-SYSTEM-GUIDE.md`) |
| Manual capture | **Capture Templates** — predefined forms for common entries (`doc/CAPTURE-GUIDE.md`) |
| Basic queries | **Query Blocks** — embed live query results inside Org files (`doc/ABOUT-QUERY-BLOCK.md`) |
| A tag/field pattern you keep recreating | **Ontology as code** — declare Types, Fields, and typed Links once, preview, and deploy (`examples/personal-work-ontology.el`, `ONTOLOGY-LINK-WORKFLOW-V5.md`) |
| A stable Ontology module | **Ontology Migration DSL** — preview and safely apply destructive model upgrades (`ONTOLOGY-MIGRATION-V8.md`) |
| Default views | **Custom Views** — build declarative dashboards with native buttons and editable fields (`doc/VIEW_FRAMEWORK_DEV_GUIDE.md`) |
| Single vault | **Multi-Vault** — separate databases for work/personal (`doc/SYNC-CONFIGURATION.md`) |
| Writing plugins | **Plugin Guide** — extend with your own extractors and services (`doc/SUPERTAG-PLUGIN-GUIDE.md`) |

---

## Data storage (where things live)

| What | Where | Format |
|---|---|---|
| Your Org files | Whatever directories you configure | Plain `.org` text |
| Structured field values | `~/.emacs.d/supertag/supertag-db.el` | Emacs Lisp data |
| Sync state | `~/.emacs.d/supertag/sync-state.el` | File mtimes and hashes |
| Daily backups | `~/.emacs.d/supertag/backups/` | Timestamped DB snapshots |

**Org files own document facts; the database owns semantic facts.** Titles, body text, document topology, Org properties, tag occurrences, and physical Org links belong to the documents. Stable tag identities, schemas, field values, semantic relations, boards, automations, and persisted query/view definitions belong to the database. The current database also contains rebuildable projections of Org content; those copies are not independent owners.

`M-x supertag-reindex-org` rebuilds Org-derived nodes, Tag Occurrences, Document Links, and their derived indexes from one complete Org snapshot. It aborts without changing the Store when that snapshot is incomplete. It is not a whole-database reset or Semantic Restore and cannot recover non-rebuildable Semantic Facts. Losing `supertag-db.el` without a backup or synced copy therefore loses non-rebuildable data. See the [data ownership constitution](doc/OWNERSHIP-CONSTITUTION_cn.md) for the authoritative ownership and migration rules.

**6.0 changed the on-disk format of `supertag-db.el` — this is a one-way upgrade.** Since 6.0, the database is written in a deterministic, one-entity-per-line format (what makes git-native sync's field-level merging possible). Older builds (5.9.x and earlier) cannot read entities out of this format — a 5.9.x Emacs pointed at a 6.0+ database will look like it loaded successfully but show an empty store, because the old code only reads the file's first line. Upgrading is safe and automatic (opening an old database with 6.0+ migrates and re-saves it), but **going back to 5.9.x afterward is not** unless you restore a pre-upgrade copy. Two safety nets exist for that: an automatic `backups/supertag-db-premigrate-<old-version>-<timestamp>.el` snapshot the moment an out-of-date database is first loaded, and a `backups/supertag-db-preformat6-<timestamp>.el` snapshot the moment a database still in the old file format is first re-saved (covering the case where the stored version already looked current but the file itself had not been re-saved yet). Neither is ever deleted by the daily-backup cleanup. To downgrade: run `M-x supertag-restore`, pick the pre-upgrade snapshot from the list, preview it, and confirm — then quit Emacs immediately and reopen with the older build. The command keeps the selected file in the old format, refuses to replace a database locked by another Emacs, and first saves the current state (including unsaved changes) as a unique `backups/supertag-db-prerestore-*` recovery point. `M-x supertag-doctor` reports both the current on-disk format and how many of each migration snapshot type exist.

---

## Syncing across machines

Two ways to keep `supertag-db.el` consistent across machines: **git-native sync** (recommended — it actually understands merges), or pointing a sync-folder service at the data directory (simpler to set up, but "last writer wins").

### Git-native sync (recommended)

**Machine 1** (first time setting this up):

```
M-x supertag-git-setup
```

This puts your vault under git: it initializes a repository if there isn't one already, migrates the database into `<repo-root>/.supertag/supertag-db.el` if it wasn't already tracked inside the repo, and configures a semantic merge driver for `supertag-db.el` so concurrent edits from different machines merge field-by-field instead of clobbering each other. It then prompts for a remote URL — give it one (any empty git remote: GitHub, a self-hosted server, a NAS) and it creates the first commit and pushes; leave the prompt empty to stay local-only for now (a fully valid, supported state — re-run the command later once you have a remote).

**Machine 2** (and every machine after that):

```
M-x supertag-git-clone
```

Give it the same remote URL and a local directory. It clones, configures the merge driver for *this* machine, and loads the database. If the database is missing or unreadable, it can only reindex Document Projections from the cloned Org files; restore Semantic Facts from a database backup or synced copy.

**Every clone must run its own setup.** `merge.supertag-db.driver` lives in `.git/config`, which git never syncs between clones — so `supertag-git-clone` configuring the driver on machine 2 isn't optional busywork, it's what makes *that* machine's merges semantic instead of falling back to git's default line-based text merge (see "Conflicts" below for what that fallback looks like).

**Optional automation:** `M-x supertag-git-sync-mode` runs a background loop that debounce-commits your changes, fetches/merges on a timer and on focus, and pushes — including catching up any commits that piled up while you were offline, without waiting for a new edit to trigger it. Without this mode, `git pull`/`git push` (or `magit-pull`/`magit-push`) by hand works identically; the mode is a convenience layer, not where correctness lives.

Use `M-x supertag-git-sync-now` to skip the debounce and synchronize immediately. While the mode is enabled, a normal `C-x C-c` checks for an unsaved Store, managed working-tree changes, a running Git operation, and local commits ahead of the last-fetched upstream. With no local work it exits without syncing, even when the remote is ahead. If local work remains, choose sync and Emacs exits automatically after success; a failed sync or a new edit keeps Emacs open. You can instead explicitly keep the recoverable working tree/local commits and exit. The low-level `kill-emacs` primitive deliberately bypasses this normal exit query.

**Conflicts.** The database's own edits merge automatically in the common case — different nodes or fields touched on each side. When the *same* field is edited differently on both sides, or plain `.org` prose is edited on the same line by both sides, git leaves that file with a real, unresolved conflict: for `supertag-db.el` itself, it refuses to load until resolved (the error names the file and points here); for `.org` files, the sync scanner skips importing anything still conflict-marked rather than ingesting garbage. Either way, `M-x supertag-doctor` (section "8. Git Sync") lists exactly what's unresolved — resolve it by hand or with `magit`/`git checkout --merge`, same as any other git conflict.

**Upgrade all synced machines together.** The 6.0 database format (see "Data storage" above) is readable only by 6.0+. A 5.9.x machine that pulls a database saved by a 6.0 machine will *appear* to load it successfully but show an empty store — old code reads only the file's first line and never errors. Its save guards prevent actual data loss (an empty in-memory store refuses to overwrite a non-trivial file), but everything will look gone until you upgrade that machine. So: upgrade supertag on **every** machine that shares the vault before any of them saves under 6.0.

### Sync-folder services (Dropbox/iCloud/Syncthing)

If you'd rather not use git, you can keep `~/.emacs.d/supertag/` (or wherever `supertag-db-file` lives) inside a Dropbox/iCloud/Syncthing-style folder so it follows you between machines — know the tradeoffs before you rely on it:

**Safest mode: one writer at a time.** `supertag-db.el` is a single serialized file. The sync service's job is "replicate the whole file, last writer wins" — it has no idea two Emacs sessions edited different parts of it, so it cannot merge them. If both machines save, one save clobbers the other, silently. The reliable workflow is: **fully quit Emacs on machine A (`C-x C-c`, not just closing the frame) before you start editing on machine B.**

This matters even if you think you're "just reading" on machine A: the auto-save timer (`supertag-db-auto-save-interval`, default 300 seconds) writes the database in the background whenever anything in the session marked it dirty, so an Emacs process left open is a background writer whether you're actively typing or not.

**The 5.9.0 database lock does not cover this.** Since 5.9.0, Supertag takes an advisory lock (`supertag-db-lock`) on the database file to stop two Emacs instances *on the same machine* from stepping on each other. The current version keeps that host-local lock under `temporary-file-directory/supertag-locks/` instead of writing new locks into a network/sync folder; it still only protects against a same-machine double-open and has no meaning across machines. After upgrading, if an old `.#supertag-db.el` remains next to the database, confirm that no older Emacs is using the vault before deleting that stale artifact.

**The presence warning.** To give sync-folder users at least a heads-up (not a lock — a sync service's multi-minute propagation delay means it can't physically be one), Supertag writes a small `supertag-presence.json` file next to the database recording which host last touched it and when. When you load the database and another host's presence looks like it was active in roughly the last 5 minutes (`supertag-presence-stale-seconds`), you'll see a loud warning naming that host and the risk. **What to do when you see it:** if you're sure the other machine is done (Emacs quit there), it's safe to proceed — the warning is one-shot and won't repeat until the other host claims presence again. If you're not sure, go quit Emacs on that other machine first. Run `M-x supertag-doctor` any time to see the current presence file's host, age, and verdict (own / foreign-active / foreign-stale). Set `supertag-presence-enable` to `nil` to turn this off entirely.

**Do not sync `sync-state.el` or `backups/`.** Both live in the same data directory as the database but are local, per-machine bookkeeping (`sync-state.el` tracks file mtimes/hashes for *this machine's* filesystem; `backups/` is disk space you don't need to duplicate across machines). If your sync tool syncs the whole data directory, exclude those two paths where the tool allows it; at worst, having them get overwritten just costs an extra Org reindex, it doesn't lose data.

This is a stopgap, not a solution — real multi-machine sync needs something that understands merges, which is exactly what the git-native sync described above does. If concurrent editing across machines is what you're after, use that instead; a sync-folder service only ever gives you the single-writer discipline above.

---

## Migration from older versions

> **⚠️ 5.9.x → 6.0.0**: The database file format changed (see "Data storage" above) — upgrading is automatic, but downgrading afterward needs a restored backup. Use `M-x supertag-restore` to pick and restore the pre-upgrade snapshot, then quit Emacs immediately and reopen with the older build.

> **⚠️ Legacy nested fields → current**: Complete the [global field migration](doc/GLOBAL-FIELD-MIGRATION-GUIDE.md) before editing fields. Current releases always use the global field model.

### From SuperTag 4.x

```emacs-lisp
;; 1. Back up your data directory (~/.emacs.d/supertag/)
;; 2. Load and run migration
M-x load-file RET supertag-migration.el RET
M-x supertag-migrate-database-to-new-arch RET
```

### From plain Org files

No migration needed. Add `#tag` to headings, define fields, and start using views. Your existing files work as-is.

### Old reciprocal reference links

Older Supertag versions could insert the same reference in both source and
target files. Those generated links are indistinguishable from links you wrote
yourself, so Supertag never deletes them automatically. Run
`M-x supertag-migration-preview-reciprocal-links` for a read-only list of exact
mutual link occurrences. If you decide some are obsolete, run
`M-x supertag-migrate-reciprocal-links`, select the individual occurrences, and
confirm once more. Nothing is selected by default; aborting writes nothing.
Each changed file receives an adjacent `.<filename>.supertag-migration-*.bak` snapshot,
and every file is restored if reprojection fails.

---

## Troubleshooting quick reference

| Problem | Fix |
|---|---|
| Not sure where to start | `M-x supertag-doctor` — an 8-section health check with guided repairs |
| Org-derived nodes or links look stale | `M-x supertag-reindex-org` |
| Auto-sync not starting | Check `supertag-sync-directories` is set correctly |
| Specific file not syncing | `M-x supertag-sync-analyze-file` |
| Field values are missing | Reindex cannot restore Semantic Facts; restore the database from a backup or synced copy |
| Sync freezes Emacs | See `doc/SYNC-CONFIGURATION.md` for performance tuning |

---

## Comparison with other tools

| Tool | Supertag's difference |
|---|---|
| **Org-roam** | Org-roam is a graph of linked notes. SuperTag is structured tables on top of Org. They can coexist. |
| **Notion** | Notion locks your data in a proprietary cloud. SuperTag works offline on your own files. |
| **Obsidian** | Obsidian is a different editor. SuperTag is native Emacs — no context switching. |
| **org-ql** | org-ql queries Org properties inline. SuperTag stores field data separately, enabling views, automation, and a query DSL that doesn't litter your Org files. |

---

## Ontology Policy

Each deployed Action is governed by one fail-closed Policy covering
`interactive-user`, `automation`, `llm`, and `external`. Decisions are
`allow`, `deny`, `confirm`, or `propose-only`. Use `M-x supertag-action-run`
from an Org heading or Node View; LLM-facing code should call
`supertag-ontology-action-propose` when its Policy grants proposal only. See
[`ONTOLOGY-POLICY-V11.md`](ONTOLOGY-POLICY-V11.md).

## Ontology LLM Tools

A deployed Function or Action is exposed to an LLM only when its Ontology
source declares `:llm-tool t`. Function tools remain read-only. Action tools
are filtered through the `llm` Policy rule: `allow` executes, `confirm` needs an
out-of-band one-use capability, `propose-only` returns a transient proposal,
and `deny` is omitted. Inspect the current provider-neutral catalog with
`M-x supertag-ui-tool-list` or copy its JSON with
`M-x supertag-ui-tool-copy-catalog-json`. See
[`ONTOLOGY-LLM-TOOL-V12.md`](ONTOLOGY-LLM-TOOL-V12.md).

---

## Further reading

- **Sync configuration**: `doc/SYNC-CONFIGURATION.md`
- **📖 A Day with Supertag**: `doc/A-DAY-WITH-SUPERTAG.org` — complete workflow tutorial with tangleable Elisp
- **Automation rules**: `doc/AUTOMATION-SYSTEM-GUIDE.md`
- **Capture system**: `doc/CAPTURE-GUIDE.md`
- **Virtual columns**: `doc/VIRTUAL_COLUMNS.md`
- **Plugin development**: `doc/SUPERTAG-PLUGIN-GUIDE.md`
- **Architecture deep-dive**: `doc/ONTOLOGY-ARCHITECTURE_cn.md`
- **View framework**: `doc/VIEW_FRAMEWORK_DEV_GUIDE.md`
- **vs old architecture**: `doc/COMPARE-NEW-OLD-ARCHITECTURE.md`

---

Supertag is developed as free software under the GPLv3. Contributions, bug reports, and feature requests are welcome on GitHub.
