# Supertag: Write notes in Emacs and Org, organize them later

> 中文: [README_CN.md](README_CN.md)

## Where V2 came from

I use Emacs and Org. In V1 I kept adding features to Supertag, and each one added a layer of
paperwork to writing: first decide where the note belongs, then its title, its tags, whether
to create a node now. As the features grew, one day I noticed I was spending far more time
developing the system than writing notes — the opposite of the original intent.

So V2 exists for one goal: make recording notes enjoyable, as if you had pressed do-not-disturb.

Concretely, V2 removes fields and the dedicated supertag-capture. Fields go because of the
cost of defining, configuring and maintaining them; structured notes themselves are fine.
The dedicated capture made recording carry too much filling-in.

`supertag-view-table` goes as well. It did two jobs: browsing nodes under a tag, and handling
fields values. Browsing was taken over by `supertag-view-stream`; the fields-value half
retired together with fields.

What remains is the database part: search, link discovery and views read from it instead of
rescanning every file. Org properties are not removed — they are still ordinary text in your
source files, and existing properties and historical data are not deleted because of this.

## Writing flows

Recording now uses Org's own `M-x org-capture`. The templates are still yours: write it down
first, and decide file, title and category later; Supertag adds the ID and tags only when you
need them.

The difference for me: I used to think about which file a note goes into, what type it is,
and whether to create a node right now. Now I drop it first and decide while organizing. Both
ways work; they differ only in when the decision happens — classify first or write first. The
latter suits me better.

**Completion.** Type `#` in an Org note to complete an existing tag; keep typing a new name
and select `[New]` to create it in place. Type `[[` to complete an existing note title or
create a new note from the same list. What remains in the file is still an ordinary `#tag`
or Org ID link.

**Nested tags.** Type a path such as `#emacs/package/elpa`, and completion builds the
`emacs › package › elpa` hierarchy. The source receives the leaf tag `#elpa`, while
Supertag records the parent relationships. A Stream or descendant query for `emacs` can then
include notes under `package` and `elpa` as well.

One thing to be clear about: this is not zero initial configuration. Your `org-capture`
template still has to name a target file; you also set the sync directory in init before
`(require 'supertag)` and run the first scan once. That is done once, and the template is in
[doc/setup.md](doc/setup.md).

On what counts as a note: plain text can be written directly, and the scan will not create an
ID for a heading that has none; only headings carrying an Org ID (an `:ID:` property) enter
the nodes. When a heading should become a node, add the ID by hand with
`M-x org-id-get-create`, or let org-capture add it on finalize (the optional integration;
[doc/setup.md](doc/setup.md) again).

## Organizing, made easy

Organizing happens after recording, and you can stop at any point.

**Tag after the fact.** `M-x supertag-add-tag` adds a `#tag` to a heading; tags are ordinary text.

**Turn a keyword into a note.** Select text, or put point on a heading, and run
`M-x supertag-promote`; pick a template keyword, and it creates a new node or reuses an
existing note per that template, replacing the selection with an ordinary Org link.

Customizing promote is a core idea, and the configuration has two layers: template data, and
wrapping a template into a command.

```emacs-lisp
(setq supertag-creation-templates
      '((:key "concept" :name "Concept"
         :target-file "~/Documents/notes/concepts.org"
         :tags ("concept"))))
;; supertag-define-promote-command is a macro; place it after (require 'supertag) so it expands.
(supertag-define-promote-command my/supertag-promote-concept "concept")
;; From then on M-x my/supertag-promote-concept turns the selection into a concept node
```

**Make connections.** Open Node View (`M-x supertag-view-node`); it has an unlinked-mentions
section listing literal candidates: other notes' bodies mention the current node's title or
aliases but have not written a link yet. Each source offers three actions: Link replaces that
single occurrence, Link all replaces every occurrence in that source, and Ignore in node stops
showing it. This section appears only for concept nodes — headings that live in your templates'
target files and carry a persistent ID; ordinary note nodes do not show it.

If you like, you can also start typing `[[` to complete a note title and add a connection
directly.

**Discover related notes along the way.** With local Ollama or a compatible embedding service
installed (optional), Node View lists semantically similar notes; installation and privacy
notes are in "Optional: Similar notes" below. `M-x supertag-mention-mode` marks known concept
titles and aliases in the body, as hints only, writing no links. When you really want to move a
note, use `M-x supertag-move-node`.

## Reviewing, at the right moment

`M-x supertag-view-stream` lays out nodes by tag (including sub-tags), good for rereading along
one theme.

`M-x supertag-discovery` flips out a batch of notes with their full bodies instead; press `s`
to search the whole vault, and a quote you pick can be inserted back into the note you started
from.

When to review is up to you; Supertag does not schedule revision.

## Getting started

```emacs-lisp
;; Install with straight.el (this assumes you already use straight)
(straight-use-package '(supertag :host github :repo "yibie/supertag"))
;; Set before require: Supertag installs its config guard when it loads.
(setq supertag-sync-directories '("~/Documents/notes/"))   ; where your Org files live
(require 'supertag)
```

Requires Emacs 29.1 and Org 9.6 or newer (the floor in the package metadata).

1. Set the sync directory in init (before `(require 'supertag)`; the file-level ID source is
   optional and can change any time), then run `M-x supertag-sync-full-rescan` once; template in
   [doc/setup.md](doc/setup.md).
2. `M-x supertag-menu`: a menu grouped into write, organize, find and maintain; look here when
   you cannot recall a command name.

No API key, no database server to run; your existing Org files work as they are.

## Advanced features


### Optional: Git backup and sync

Git can auto-commit and push the Org text under your sync directory, and other machines pull
and rebuild their own notes; a local commit is a version record, not a remote backup.

The database, and the rules and configuration that live in it, do not travel with Git — keep a
separate backup for them. On the first machine, `M-x supertag-git-setup` creates the repository;
on the second, `M-x supertag-git-clone` clones and rebuilds; after that,
`M-x supertag-git-sync-mode` turns on automatic sync (it is not persistent — enable it again
after a restart, or put it in init). Manual sync is `M-x supertag-git-sync-now`. The full
mechanics and configuration are in [doc/sync.md](doc/sync.md).

### Similar notes

An optional feature, off by default. It needs `curl` on the machine, a local Ollama or a
compatible embedding service, and an embedding model ready on that service (`bge-m3` by
default).

```emacs-lisp
(setq supertag-semantic-endpoint "http://localhost:11434")
(setq supertag-semantic-model "bge-m3")
```

The service must be `/api/embed` compatible; `supertag-semantic-endpoint` takes the root
address without `/api/embed` appended.

Then `M-x supertag-semantic-rebuild`. It first asks whether to enable similar notes for future
sessions; after you agree it probes the service and model, and only a successful probe writes
that choice into your configuration — an unreachable service leaves nothing "enabled". It then
indexes nodes in the background, and Node View shows a "Similar" candidate section.
`M-x supertag-semantic-status` shows progress, `M-x supertag-semantic-stop` pauses,
`M-x supertag-semantic-resume` continues; changing the model requires rebuilding the index.

Two things to keep in mind. On what is sent: each request to the service carries the title, the
outline path and the beginning of the body (1500 characters by default); requests go to your
local machine by default, and pointing the address at a remote service means sending that text
to that machine — think twice before using a public or third-party service. On bounds: similar
candidates are hints only; they never create links automatically and never rewrite your Org
files.

### Query

A query is an S-expression; it can live in an Org Babel block or a dynamic block, or run from
the query entry in `M-x supertag-menu`. Day to day, the most common filter is by tag and TODO
state:

```org
#+BEGIN_SRC supertag-query-block :results raw
(and (tag "task") (todo "TODO"))
#+END_SRC
```

Combine conditions with `and`, `or`, `not`, and use `(property "KEY" "value")` for Org
properties. The fuller operator set and composition rules are in [doc/query.md](doc/query.md).

### Automation

Automation is rule-driven; the easiest way to make a rule is from a ready-made template:

1. `M-x supertag-automation-insert-template`, then pick a template;
2. fill in the parameters it asks for (e.g. which tag, which value to set);
3. look at the preview, confirm, and it is created.

To see which templates exist first, use `M-x supertag-automation-list-templates`.

The engine runs by default, but it modifies no file without rules; when a rule runs, it writes
back to the source Org file. The current triggers, conditions, actions and templates are in
[doc/automation.md](doc/automation.md).

## Command list

Common commands grouped by purpose. Every row is a command you can invoke with `M-x`
(`org-capture` is Org's own).

| Group | Command | Effect |
|---|---|---|
| Capture & organize | `org-capture` | Org's own command; record from a template, and with `:supertag t` finalize can add the ID ([doc/setup.md](doc/setup.md)) |
| Capture & organize | `supertag-menu` | task-grouped command menu; look here when you cannot recall a name |
| Capture & organize | `supertag-add-tag`, `supertag-remove-tag-from-node` | add a tag to a heading, remove one |
| Capture & organize | `supertag-promote` | turn the selection or the heading at point into a node via a creation template |
| Capture & organize | `supertag-move-node`, `supertag-move-node-and-link` | move a node to another file; the `-and-link` variant leaves a link behind |
| Capture & organize | `supertag-add-link`, `supertag-find-node` | insert a node link; find and jump to a node by title |
| Capture & organize | `supertag-tag-rename`, `supertag-delete-tag-everywhere` | rename a tag; delete a tag across the vault |
| Find & review | `supertag-view-node` | the node page: unlinked mentions, similar notes, and more |
| Find & review | `supertag-view-stream` | lay nodes out by tag (including sub-tags) |
| Find & review | `supertag-discovery` | flip out random notes; `s` searches the whole vault, and a picked quote can be inserted back |
| Find & review | `supertag-mention-mode` | mark known concept titles and aliases in the body as hints only |
| Query & automation | `supertag-add-query-block`, `supertag-query-build`, `supertag-query-describe-syntax` | insert a query block; assemble a query interactively; show the syntax reference |
| Query & automation | `supertag-automation-insert-template`, `supertag-automation-list-templates` | create a rule from a template; browse templates ([doc/automation.md](doc/automation.md)) |
| Maintain | `supertag-sync-full-rescan` | full rescan; run once after initial setup |
| Maintain | `supertag-semantic-rebuild`, `supertag-semantic-status`, `supertag-semantic-stop`, `supertag-semantic-resume` | similar notes (optional, off by default): rebuild the index, check status, pause, continue |
| Maintain | `supertag-migrate-status`, `supertag-migrate-preview` | migration status report; preview before retired fields are written back to Org ([doc/migration.md](doc/migration.md)) |
| Maintain | `supertag-git-setup`, `supertag-git-clone`, `supertag-git-sync-mode`, `supertag-git-sync-now` | Git backup and sync: create the repository / clone and rebuild / toggle auto-sync / sync now ([doc/sync.md](doc/sync.md)) |

## Customization list

The most-changed options, with defaults taken from the source; the full list by feature group
is in [doc/customization.md](doc/customization.md).

| Option | Default | Effect |
|---|---|---|
| `supertag-sync-directories` | `nil` | directories to sync; nil means not configured yet — set before `(require 'supertag)` in init (the wizard is retired) |
| `supertag-file-id-source` | `'org-roam` | file-level ID source: `org-roam`, `denote`, `auto`, `disabled` |
| `supertag-sync-auto-interval` | `900` | auto-sync interval (seconds) |
| `supertag-sync-idle-delay` | `1.0` | idle seconds before sync runs |
| `supertag-db-backup-interval` | `86400` | daily database backup interval (seconds); retention in `supertag-db-backup-keep-days` |
| `supertag-git-sync-commit-debounce` | `30` | Git auto-sync: quiet seconds before committing; pull interval in `supertag-git-sync-pull-interval` |
| `supertag-org-capture-auto-enable` | `nil` | org-capture integration; off by default, enable when needed |
| `supertag-creation-templates` | `nil` | creation presets shared by Add Link, Find Node and Promote; nil uses the built-in Concept preset |
| `supertag-view-style-color-by-name` | `t` | colour inline tags by name |
| `supertag-view-node-side` | `'right` | which side the Node View side window takes |
| `supertag-view-node-side-size` | `0.33` | Node View side-window width ratio |
| `supertag-discovery-initial-sample-size` | `10` | random notes shown by Discovery |
| `supertag-mention-max-results` | `300` | maximum sources listed for unlinked mentions |
| `supertag-semantic-enabled` | `nil` | similar-notes switch; off by default, needs a working embedding service |


## Documentation

- Initial setup: [doc/setup.md](doc/setup.md)
- Automation rules: [doc/automation.md](doc/automation.md)
- Query syntax: [doc/query.md](doc/query.md)
- Sync and multiple machines: [doc/sync.md](doc/sync.md)
- Migration (package rename and V1→V2 upgrade): [doc/migration.md](doc/migration.md)
- Unlinked mentions, behaviour bounds: [doc/mentions.md](doc/mentions.md)
- Customization (full list): [doc/customization.md](doc/customization.md)
- Development and tests: [test/README.md](test/README.md)
- Change history: [CHANGELOG.org](CHANGELOG.org)
- Historical guides and design records: [archive/docs/README.md](archive/docs/README.md)
