# Supertag Customization Reference

> 中文: [customization_cn.md](customization_cn.md)

Every defcustom in the active `supertag*.el` files (excluding `archive/`, `test/`,
`scripts/` and retired modules), with defaults taken straight from the source. Dynamic
defaults are explained under "Where the defaults come from" below. Each section lists its
source files; where a long default is elided, the source is authoritative.

## Contents

- [Sync and vaults](#sync-and-vaults)
- [Database and backups](#database-and-backups)
- [Views and palettes](#views-and-palettes)
- [Tag display and completion](#tag-display-and-completion)
- [Links and context backlinks](#links-and-context-backlinks)
- [Concepts and unlinked mentions](#concepts-and-unlinked-mentions)
- [Creation templates and capture](#creation-templates-and-capture)
- [Semantic similar notes](#semantic-similar-notes)
- [AI property extraction](#ai-property-extraction)
- [Automation and scheduling](#automation-and-scheduling)
- [Git text sync](#git-text-sync)
- [Discovery](#discovery)
- [Embark integration](#embark-integration)

## Where the defaults come from

- `supertag-data-directory` defaults to `~/.emacs.d/supertag/`; `supertag-db-file`,
  `supertag-db-backup-directory` and `supertag-sync-state-file` are computed from it, so
  their real paths follow the data directory.
- `supertag-project-root` is derived from the source file's location; no need to write it by
  hand.
- Path defaults are computed once at load (or when a vault is activated) from the
  `user-emacs-directory` and vault root in effect then; changing `supertag-data-directory`
  later does not rewrite the already-computed `supertag-db-file`,
  `supertag-db-backup-directory` or `supertag-sync-state-file` — reset those variables or
  restart.
- `supertag-view-node-palette` and `supertag-view-tag-cards-palette` are buffer-local and do
  not override the global `supertag-view-palette`.
- Read `nil` per option: for `supertag-sync-directories` it means "not configured yet", for
  `supertag-creation-templates` "use the built-in preset", for
  `supertag-discovery-history-file` "do not persist", and for
  `supertag-text-link-relation-types` "no preset types" (types explicitly accepted in the
  session still apply).

## When to enable, and caveats

- `supertag-org-capture-auto-enable` is off by default; turn it on when you want the
  org-capture integration.
- `supertag-semantic-enabled` is off by default: start a local embedding service first
  (default `http://localhost:11434`, model `bge-m3`), then run
  `M-x supertag-semantic-rebuild` once. Requests go to the endpoint you configure.
- `supertag-presence-enable` writes a cross-machine heads-up file; the database itself is a
  single file, and relaying it through a cloud drive is "whole file, last writer wins".
- After changing `supertag-text-link-relation-types`, run `supertag-text-link-refresh` and
  rebuild the index.
- `supertag-creation-templates` holds data only (files, tags, properties, body) — no
  functions.
- `supertag-sync-auto-create-node` and `supertag-reference-backlink-include-timestamp` are
  retained compatibility options; they do not affect current behaviour.
- Automation writes back to source Org files only after you create rules; the engine runs by
  default, but with no rules there are no actions.

## Sync and vaults

| Option | Default | Effect |
|---|---|---|
| `supertag-async-batch-size` | `1` | how many files one idle cycle processes |
| `supertag-async-idle-delay` | `0.5` | idle seconds before the next queued job |
| `supertag-sync-auto-create-node` | `nil` | deprecated, kept for compatibility: sync never invents node IDs, and nil is current behaviour |
| `supertag-sync-auto-interval` | `900` | auto-sync interval in seconds |
| `supertag-sync-auto-start-initial-delay` | `3` | seconds after startup before the first auto-start attempt |
| `supertag-sync-auto-start-max-retries` | `24` | maximum auto-start retries |
| `supertag-sync-auto-start-retry-interval` | `5` | retry interval after a failed auto-start |
| `supertag-sync-auto-start` | `t` | start syncing automatically after Emacs startup |
| `supertag-sync-directories-mode` | `'unified` | how `supertag-sync-directories` is interpreted: `unified` shares one vault, `vaults` gives each directory its own |
| `supertag-sync-directories` | `nil` | root directories to sync; nil means not configured yet. Set before `(require 'supertag)` per [setup.md](setup.md) (the wizard is retired) |
| `supertag-sync-exclude-directories` | `nil` | directories excluded from sync; nil excludes nothing |
| `supertag-sync-file-pattern` | `".org$"` | filename regexp for files taking part in sync (default: ends in `.org`) |
| `supertag-sync-hash-props` | `'(:raw-value :olp :tags :todo :priority :content :properties :parent-id)` | extra Org attributes in the node hash; append only, never remove required entries |
| `supertag-sync-idle-delay` | `1.0` | idle seconds before auto-sync runs |
| `supertag-sync-import-org-tags` | `nil` | whether native Org `:tag:`s are imported as tags; the import is read-only |
| `supertag-sync-max-delete-count` | `1000` | maximum nodes a single GC pass may delete; beyond it the pass aborts |
| `supertag-sync-max-delete-ratio` | `0.5` | maximum delete ratio for a single GC pass; beyond it the pass aborts |
| `supertag-sync-node-creation-level` | `1` | legacy: defined but never read in the repo; sync never invents an ID for an ID-less heading |
| `supertag-sync-orphan-grace-seconds` | `3600` | grace seconds before an orphaned node may be deleted (it must stay fileless throughout) |
| `supertag-sync-quiet-when-idle` | `t` | print no routine sync message when nothing changed |
| `supertag-sync-smart-detection-enabled` | `nil` | skip unchanged files using their hash |
| `supertag-sync-smart-detection-verbose` | `nil` | print decisions such as "skipping unchanged file" |
| `supertag-sync-snapshot-guard` | `t` | protect destructive operations with snapshot state |
| `supertag-sync-state-file` | `(expand-file-name "sync-state.el" supertag-data-directory)` | sync state file (default `sync-state.el` under the data directory) |
| `supertag-active-sync-directory` | `nil` | root of the active vault in `vaults` mode |
| `supertag-data-directory` | `(expand-file-name "supertag" user-emacs-directory)` | data directory (default `~/.emacs.d/supertag/`) |
| `supertag-vault-auto-switch` | `nil` | switch to the matching vault by file path (loads that vault's database and state) |
| `supertag-vault-modeline-indicator` | `t` | show the current vault name in the mode line |
| `supertag-file-id-source` | `'org-roam` | file-level ID source: `org-roam`, `denote`, `auto` or `disabled` |
| `supertag-project-root` | `(file-name-directory (file-name-directory (or load-file-name buffer-file-name)))` | project root, derived from the source file's location |

Source: [`../supertag-services-sync.el`](../supertag-services-sync.el),
[`../supertag-vault.el`](../supertag-vault.el), [`../supertag.el`](../supertag.el)

## Database and backups

| Option | Default | Effect |
|---|---|---|
| `supertag-db-auto-migrate` | `t` | migrate automatically when an older database is loaded |
| `supertag-db-auto-save-interval` | `300` | database auto-save interval in seconds |
| `supertag-db-backup-directory` | `(supertag-data-file "backups")` | backup directory (default `backups/` under the data directory) |
| `supertag-db-backup-interval` | `86400` | daily backup interval in seconds (24 hours by default) |
| `supertag-db-backup-keep-days` | `3` | days to keep daily backups |
| `supertag-db-file` | `(supertag-data-file "supertag-db.el")` | database file (default `supertag-db.el` under the data directory) |
| `supertag-db-follow-interval` | `30` | idle check for newer revisions written by other Emacsen; nil disables following |
| `supertag-db-verify-after-save` | `t` | verify the database file after saving |
| `supertag-presence-enable` | `t` | write a cross-machine heads-up file for multi-machine awareness |
| `supertag-presence-stale-seconds` | `300` | age beyond which another machine's heads-up is treated as stale |
| `supertag-change-bridge-debug` | `nil` | print delivery diagnostics for the legacy change bridge |

Source: [`../supertag-core-persistence.el`](../supertag-core-persistence.el),
[`../supertag-core-store.el`](../supertag-core-store.el)

## Views and palettes

| Option | Default | Effect |
|---|---|---|
| `supertag-view-palette` | `'paper` | default view palette (`paper`) |
| `supertag-view-node-auto-show` | `nil` | show the Node View side window automatically and follow context |
| `supertag-view-node-follow-idle-delay` | `0.08` | idle seconds before following to another node |
| `supertag-view-node-palette` | `'paper` | buffer-local palette for Node View |
| `supertag-view-node-side-size` | `0.33` | Node View side-window width ratio |
| `supertag-view-node-side` | `'right` | which side the Node View side window takes |
| `supertag-view-node-strip-todo-keywords` | `t` | strip TODO keywords from view titles |
| `supertag-view-node-todo-keywords` | `'("TODO" "DONE" "NEXT" ...)` (illustrative; long value elided — see the source) | the TODO keyword list to strip |
| `supertag-view-tag-cards-favorite-groups` | `nil` | tag IDs shown as favourite groups in Tag Cards |
| `supertag-view-tag-cards-manifesto` | `'("MAKE ROOM" "FOR THE UNEXPECTED." "Tags are fuel. The connections are computed for you: click any + row to narrow.")` | the three lines under the Tag Cards masthead |
| `supertag-view-tag-cards-palette` | `'neon` | buffer-local palette for Tag Cards |

Source: [`../supertag-view-framework.el`](../supertag-view-framework.el),
[`../supertag-view-node.el`](../supertag-view-node.el),
[`../supertag-view-tag-cards.el`](../supertag-view-tag-cards.el)

## Tag display and completion

| Option | Default | Effect |
|---|---|---|
| `supertag-batch-tag-insert-position` | `'end` | batch tagging inserts tags at the start or end |
| `supertag-capture-tag-position` | `'end` | capture-generated headings insert tags at the start or end |
| `supertag-completion-auto-enable` | `t` | enable tag completion automatically in Org buffers |
| `supertag-view-style-auto-enable` | `t` | enable inline tag styling when an Org buffer opens |
| `supertag-view-style-color-by-name` | `t` | colour inline tags by tag name |
| `supertag-view-style-tag-face-properties` | `'(:underline t)` | face properties for registered inline tags (underline by default) |
| `supertag-view-style-unresolved-tag-face-properties` | `'(:inherit shadow)` | face properties for unregistered tokens (inherit shadow by default) |

Source: [`../supertag-tag.el`](../supertag-tag.el)

## Links and context backlinks

| Option | Default | Effect |
|---|---|---|
| `supertag-reference-backlink-include-timestamp` | `nil` | retained for compatibility; currently no behavioural effect |
| `supertag-reference-context-before` | `72` | characters shown before the matched term |
| `supertag-reference-context-length` | `220` | maximum characters in a context backlink excerpt |
| `supertag-reference-shorthand-openers` | `'(("[[" . "]]") ("【【" . "】】"))` | opener/closer pairs for create-or-link shorthand (default `[[` and `【【`) |
| `supertag-text-link-relation-types` | `nil` | no preset relation types; types explicitly accepted in the current session still apply (`supertag-link.el:80` appends session types to the result) |

Source: [`../supertag-link.el`](../supertag-link.el)

## Concepts and unlinked mentions

| Option | Default | Effect |
|---|---|---|
| `supertag-concept-alias-separator-regexp` | `"[,，;；]"` | separator regexp for aliases in `SUPERTAG_ALIASES` |
| `supertag-concept-default-file` | `nil` | default file for new concept nodes; when nil it is derived from the sync directory, `org-directory`, then the current file's directory |
| `supertag-concept-min-term-length` | `2` | minimum title or alias length for a concept mention |
| `supertag-mention-context-after` | `120` | characters shown after a mention |
| `supertag-mention-context-before` | `64` | characters shown before a mention |
| `supertag-mention-max-results` | `300` | maximum source nodes listed for unlinked mentions |
| `supertag-mention-min-term-length` | `2` | minimum title or alias length for an unlinked mention |
| `supertag-mention-protected-range-cache-size` | `128` | entry cap for the mention scan's temporary Org parse cache |
| `supertag-mention-result-cache-size` | `64` | how many target queries the mention result cache keeps |

Source: [`../supertag-concept.el`](../supertag-concept.el),
[`../supertag-mention.el`](../supertag-mention.el)

## Creation templates and capture

| Option | Default | Effect |
|---|---|---|
| `supertag-org-capture-auto-enable` | `nil` | whether the org-capture integration is enabled (off by default) |
| `supertag-creation-templates` | `nil` | creation presets shared by Add Link, Find Node and Promote; nil uses the built-in Concept preset |
| `supertag-node-location-org-id-fallback` | `t` | locate nodes absent from the Store with `org-id-find` |
| `supertag-org-id-find-auto-enable` | `t` | let `org-id-find` resolve IDs through the Supertag Store first |

Source: [`../supertag-service-org.el`](../supertag-service-org.el),
[`../supertag-node.el`](../supertag-node.el)

## Semantic similar notes

| Option | Default | Effect |
|---|---|---|
| `supertag-semantic-curl-program` | `"curl"` | external program used for embedding requests |
| `supertag-semantic-enabled` | `nil` | master switch for similar notes; off by default, needs a working embedding service |
| `supertag-semantic-endpoint` | `"http://localhost:11434"` | embedding service address (local Ollama by default) |
| `supertag-semantic-max-chars` | `1500` | maximum body characters sent for embedding |
| `supertag-semantic-max-results` | `5` | maximum similar candidates shown |
| `supertag-semantic-min-similarity` | `0.4` | similarity floor; so far calibrated only on synthetic notes |
| `supertag-semantic-model` | `"bge-m3"` | embedding model name (`bge-m3` by default; changing it rebuilds the index) |
| `supertag-semantic-preview-lines` | `3` | preview lines of a candidate's body |
| `supertag-semantic-request-chars` | `6000` | approximate character budget per request; a long node may exceed it |
| `supertag-semantic-request-timeout` | `30` | timeout in seconds for one embedding request |
| `supertag-semantic-save-interval` | `30` | minimum seconds between partial side-car saves |

Source: [`../supertag-semantic.el`](../supertag-semantic.el)

## AI property extraction

| Option | Default | Effect |
|---|---|---|
| `supertag-ai-max-body-chars` | `8000` | maximum body characters sent for property extraction |
| `supertag-ai-prompts` | (built-in extract-properties prompt; full default in the code block below and in the source) | extraction prompts; templates may use the `%t`, `%p`, `%b` placeholders |
| `supertag-ai-timeout` | `60` | timeout in seconds for a property-extraction request |

Source: [`../supertag-ai.el`](../supertag-ai.el)
Full default (copied from `supertag-ai.el`; the newlines in `:user` are `\n` in the source):

```emacs-lisp
(defcustom supertag-ai-prompts
  '((extract-properties
     :system "Extract only facts explicitly stated in the body. Do not invent facts or repeat existing properties with equal values. Return at most 12 entries as one JSON object with uppercase property names and values shaped as {\"value\": \"text\", \"source\": \"verbatim body quote\"}. Use null for source if absent from the body. Output only JSON, with no surrounding prose."
     :user "Title: %t\nExisting properties:\n%p\nBody:\n%b"))
  "Named extraction prompts.  User templates expand %t, %p and %b."
  :type '(alist :key-type symbol :value-type plist) :group 'supertag-ai)
```


## Automation and scheduling

| Option | Default | Effect |
|---|---|---|
| `supertag-automation-verbose` | `nil` | print detailed automation diagnostics |
| `supertag-scheduler-check-interval` | `300` | seconds between scheduler checks for pending tasks |

Source: [`../supertag-automation.el`](../supertag-automation.el)

## Git text sync

| Option | Default | Effect |
|---|---|---|
| `supertag-git-sync-commit-debounce` | `30` | quiet seconds after the last change before auto-commit |
| `supertag-git-sync-focus-pull-min-interval` | `60` | minimum seconds between two focus-triggered pulls |
| `supertag-git-sync-pull-interval` | `300` | background fetch (plus merge when needed) interval in seconds |

Source: [`../supertag-git.el`](../supertag-git.el)

## Discovery

| Option | Default | Effect |
|---|---|---|
| `supertag-discovery-history-file` | `nil` | file for search history; nil means do not persist |
| `supertag-discovery-history-max-items` | `100` | how many search-history entries to keep |
| `supertag-discovery-initial-sample-size` | `10` | random notes shown when Discovery opens or refreshes |

Source: [`../supertag-discovery.el`](../supertag-discovery.el)

## Embark integration

| Option | Default | Effect |
|---|---|---|
| `supertag-embark-integration` | `t` | register Supertag's context actions when Embark loads |

Source: [`../supertag-embark.el`](../supertag-embark.el)
