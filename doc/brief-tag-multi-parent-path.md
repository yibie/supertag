# Task brief: multi-parent tags, `/` path creation, Tag Manager "new tag"

Status: production change on branch `supertag-refactor`. Commit when done
(one or more focused commits). Do not drive the user's running Emacs
(no emacsclient); verify with batch ERT and byte-compile only.

## Why

The user wants to create nested tags without leaving the buffer: typing
`#topics/emacs` and choosing `[New]` must create `topics` (if missing) and
`emacs` (if missing), and make `emacs` a child of `topics`. The user also
decided that a tag may have **several parents**: if `emacs` already extends
`tools`, then `#topics/emacs` adds `topics` as a second parent (it does not
reparent, does not error). Inline text stays the short leaf token `#emacs`;
one token still maps to exactly one Tag (the token-uniqueness invariant in
`supertag-tag--assert-tokens-unique` stays).

## 1. Data model: `:extends` becomes a list

- A Tag's `:extends` is a list of parent Tag IDs (nil = root). Writes always
  store a list. Update `supertag--validate-tag-data` (supertag-tag.el ~306)
  to require a list of strings or nil.
- Ship a forward DB migration: bump `supertag-data-version` (see
  supertag-core-persistence.el ~35, currently 7.1.0) and add a DB-only,
  idempotent step in `supertag-migrate--db-steps` that rewrites a string
  `:extends` into a one-element list. Other users' stores contain string
  values, so this step is mandatory; after it, no code path should need to
  accept a string (no read-time compat shim; the user prefers deleting
  superseded code over shims).
- `supertag-migrate--apply-legacy-extends`: a child that already has other
  parents is no longer a conflict; add the parent to the list (still skip
  cycles and missing tags). Update `supertag-migrate--legacy-extends-cycle-p`
  and the path walk at supertag-migrate.el ~140 for lists (the path string
  there can follow the first parent).
- `supertag-tag-rename--rewrite-tags` (~1496): map every parent in the list.

## 2. Hierarchy API (supertag-tag.el)

- Replace `supertag-tag-parent` with `supertag-tag-parents` (list). Delete
  the old function and update every caller (grep the repo, including
  views, embark, query, tests).
- `supertag-tag-ancestors`: transitive union over all parents, nearest
  first (BFS), deduplicated, cycle-safe.
- `supertag-tag-display-name`: one parent chain -> unchanged
  (`note › ref › paper`). Several direct parents -> join the parents'
  names with ` · ` then ` › leaf`, e.g. `tools · topics › emacs` (do not
  expand deeper chains in that case).
- Descendant index in `supertag-tag-index-rebuild`: build children from
  every parent in the list.
- `supertag-tag--validate-extends`: validate each parent exists, no self,
  and no cycle through any path (DFS over parent lists).
- `supertag-tag-create`: `:extends` accepts a list (or nil).
- `supertag-tag-set-parent`: becomes "set parents": interactive read with
  `completing-read-multiple` prefilled with current parents (empty input
  clears). Keep a programmatic signature taking a list. Add a small
  `supertag-tag-add-parent (tag-id parent-id)` helper used by path creation.
- `supertag-embark-tag-set-parent` follows the rename.

## 3. Path creation

Add `supertag-tag-ensure-path (path)` in supertag-tag.el:

- Separator is `/`; also accept full-width `／` (the user types with a
  Chinese IME). Split, trim, sanitize each segment; empty segments are a
  `user-error`. A path with one segment is just normal creation.
- For each segment left to right: resolve an existing Tag by occurrence
  token (`supertag-tag-resolve-occurrence`), else create it. For every
  segment after the first, ensure the previous segment's ID is in its
  `:extends` (add, never replace). A would-be cycle is a `user-error` and
  nothing is written (do the whole thing in one `supertag-with-transaction`
  so a failure leaves the store untouched).
- Return the leaf Tag ID.
- `/` and `／` are no longer allowed inside a single tag name: make
  `supertag-sanitize-tag-name` (or creation) reject them, and update the
  docstrings that say "A slash path is the complete tag name" /
  "Slashes are ordinary tag-name characters". The user's store has no tag
  names containing `/`.

Wire it into every creation entry point:

- Inline CAPF `[New]` (`supertag-completion--get-completion-table`,
  `supertag-completion--post-completion-action`, ~2930-3030): for a prefix
  containing a separator, `[New]` must be offered when the path would
  create a tag OR add a missing parent edge (e.g. `topics/emacs` where both
  exist but unrelated). Completion display (affixation) should show the
  resulting hierarchy, e.g. `topics › emacs  [New]`. On commit, call
  `supertag-tag-ensure-path`, then replace the typed `#topics/emacs` with
  `#emacs` (the leaf's sanitized name), and record membership as today.
  Boundary auto-record (`supertag-completion--auto-record-on-boundary`)
  still never creates anything.
- `supertag-add-tag` (~3575) minibuffer input: a path creates/links the
  same way and inserts the leaf token.
- Tag Manager (supertag-view-tags.el): add a root-level "new tag" command
  (`supertag-view-tags-create`, key `+`, also add to the mode docstring /
  describe-mode), reading a name or path. `c` (create child of row) also
  accepts a path, created under the row's tag.

## 4. Tag Manager tree with multiple parents

`supertag-view-tags--build-rows`: a tag with several parents appears under
each existing parent (DAG expanded into the tree), roots are tags whose
parent list is empty or whose parents are all missing (`:orphan` when any
listed parent is missing and none exist). Guard against cycles in stored
data. Point-based commands must still resolve the row's tag ID; marks are
by ID, so a tag shown twice is marked in both places — acceptable.

Tag Cards (`supertag-view-tag-cards.el`) uses ancestors/descendants; check
it still loads and its tests pass; adjust only what the API rename forces.

## 5. Tests and verification

- Update existing tests that assert string `:extends`
  (test/tag-path-hierarchy-test.el, tag-path-test.el, tag-manager-test.el,
  migrate-test.el, tag-merge*, test-view-stream.el, tag-cards-test.el, ...).
- New ERT: migration string->list idempotent; multi-parent ancestors,
  descendants, display name, cycle rejection across two parents;
  `supertag-tag-ensure-path` (all new, partial existing, add second
  parent, cycle rolls back, full-width `／`); CAPF commit of
  `#topics/emacs` writes `#emacs` and creates the edge; Tag Manager rows
  show a two-parent tag under both parents; `+` creates a root/path.
- Run the full ERT suite touched by these files in batch and byte-compile
  the changed files with no new warnings. Look at how existing tests are
  run (test/ directory, `emacs -Q --batch -L . -L test ...`); dependencies
  such as `ht` live under `~/.config/nova-emacs/elpaca/builds/*/`.

## Report

Write `doc/report-tag-multi-parent-path.md`: what changed, files, commands
run with results, anything left undone or judgment calls made.
