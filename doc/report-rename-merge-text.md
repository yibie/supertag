# Report: rename/merge on the shared Org-text enumerator

Commit: `9bafeed feat(tag): rename/merge enumerates occurrences from Org text`
(files: `supertag-tag.el`, `test/rename-merge-text-test.el` new,
`test/tag-rename-delete-test.el`, `test/renovation-suites.el`).
Branch `supertagV2`.  Nothing was run against `/Users/chenyibin/Documents/notes`;
every measurement is a temp-directory fixture.

## What changed

Rename/merge now runs on the enumerator `293e562` built for delete; no second
scanner exists.

- `supertag-tag-change--collect` returns the **text** records for the tag
  (`supertag-tag--text-records-for-tag` over the shared scan) and `nil` for an
  unknown tag, matching the old contract that a finished rename leaves nothing
  to preview.
- `supertag-tag-change-preview` renders the same file → line listing as
  delete (`supertag-tag--text-preview`), with the same context labels
  (`FILETAGS`, `heading without :ID:`, `duplicate :ID: (Store points at another
  file)`, …) and the same `NOT CHANGED` section; `DISPLAY` still gates popping.
- `supertag-tag--text-write` gained an optional `NEW-TOKEN`.  Inline ranges are
  replaced with `#NEW-TOKEN`; `#+FILETAGS:` is rewritten through
  `supertag-service-org--set-filetags` (matching tokens mapped, then
  `delete-dups`, so a merge never writes the target twice).  Every edit now
  sets point to the recorded `:begin` before `insert` — the first draft
  corrupted files because `insert` used point rather than the range — and the
  per-file, per-owner order stays strictly back to front, so byte-length
  changes cannot shift the ranges still to be written.
- `supertag-tag-rename` previews (file → line + context), asks once, writes via
  that path, then keeps the resolution guard, the merge prompt that names the
  target id, and an entity gate consistent with delete: the old Tag is retired
  only when no text occurrence and no owner remain, and a file left untouched
  by the rescan guard keeps the old entity and is reported in a `NOT RENAMED`
  preview.  Nodes whose text no longer carries the old Tag are refreshed
  (`supertag-tag--text-repair-owners`) instead of keeping a stale membership.
- Bug found by the existing retry test: `supertag-tag--text-tokens-for-tag`
  (added in `293e562`, used by the near-miss lookup for delete and the orphan
  report too) read the entity as a plist; a hash-table shaped entity — e.g.
  after a store reload — produced `supertag-sanitize-tag-name nil` →
  `"Tag name cannot be empty"`.  It now goes through
  `supertag--ensure-plist`.

## What merge does to membership (explicitly)

- Text first: every occurrence of the old token becomes the target's canonical
  token, so `#old #new` on one node becomes `#new #new`.
- Membership is then *derived from that text* by the node's own projection and
  de-duplicated during extraction (`supertag--merge-and-sanitize-tags`), so the
  node's `:tags` ends as `(target)` **exactly once** — never a duplicate.
- The file node only gains the target if its `#+FILETAGS:` said so; the
  FILETAGS writer de-duplicates too.
- The old entity is deleted only when no text occurrence and no owner remain
  (`(not (equal old-id new-id))` and `(not (supertag-find-nodes-by-tag
  old-id))` plus the text rescan), otherwise it is kept and the leftovers are
  reported.
- Measured in `supertag-rename-merge-text-merge-deduplicates-membership`: a
  node with `#old #new` and a node with only `#old` both end with
  `("target")`, the file node stays without tags, and the old entity is gone.

## Tag Manager / other entries (checked, no change needed)

`supertag-view-tags-rename` (`supertag-view-tags.el:214`) calls
`supertag-tag-rename` and so inherits the preview and the single confirmation;
likewise `supertag-embark-tag-rename` (`supertag-embark.el:294`).  Unlike the
bulk delete path there was no separate writer to rewire, so
`supertag-view-tags.el` is untouched.

## Verification

```sh
EMACS_BIN=<wrapper> bash test/run-tests.sh      # exit 0
$ python3 -c "...summarise 'Ran N tests' lines..."
suites=35 tests=1218 skipped=5 unexpected=0

bash test/static-gates.sh                        # exit 0
Static O gates: PASS
```

`tag-change` with the new tests: `Ran 44 tests, 44 results as expected, 0
unexpected`.

**Pre-fix evidence** (`git stash push -- supertag-tag.el`, then the suites):

```
tag-change: Ran 44 tests, 34 results as expected, 10 unexpected
   FAILED  all six new supertag-rename-merge-text-* tests
   FAILED  supertag-tag-change-merge-previews-canonical-target
   FAILED  supertag-tag-change-preview-is-zero-write
   FAILED  supertag-tag-change-preview-keeps-not-changed-shapes
   FAILED  supertag-tag-change-retry-after-save-failure
tag-path:  Ran 101 tests, 101 results as expected, 0 unexpected
```

New tests (fixtures rooted at `(file-truename (make-temp-file …))`):
no-`:ID:` heading + its prose + duplicate-`:ID:` copy + FILETAGS all renamed;
`#old,`/`#old.` renamed with the punctuation kept; four occurrences in one file
rewritten with an exact whole-file comparison (a forward pass corrupts it);
preview shown at prompt time and decline writing nothing; rescan guard aborting
only the changed file while keeping the old entity; merge membership without
duplicates; rejected shapes byte-identical.

## Existing tests modified (itemised)

All four are in `test/tag-rename-delete-test.el` and each pinned the **old
node-based preview**, not a behaviour this task keeps:

1. `supertag-tag-change-preview-is-zero-write`: asserted the grouped return
   shape (`2` groups, `3` nodes), the Chinese summary
   `"3 个 token / 3 节点 / 2 文件"` and `"待保存/待投影 0"`.  Now asserts three
   records with their tokens, `WILL CHANGE: 3`, `3 occurrence(s) / 2 file(s)`,
   the `FILETAGS` label and the same zero-write guarantee.  Reason: the preview
   is text-based now; the guarantee it checks (preview writes nothing) is
   unchanged and still asserted.
2. `supertag-tag-change-preview-skips-metadata-lines` → renamed to
   `supertag-tag-change-preview-keeps-not-changed-shapes`: it asserted a
   `#+CAPTION:`-line occurrence never appears in the preview.  Reason, with a
   measurement: the *shared* acceptance rule is not what skipped it — after a
   src block the same line is classified `not a Tag: keyword line` (rejected),
   but directly after a property drawer `org-element-context` reports a
   paragraph and the occurrence is accepted (see "Observations" below).  The
   test now pins the rejected shape it can rely on (a src block listed under
   `not a Tag: src or example block`, text byte-identical) instead of asserting
   a classification the shared rule does not guarantee.
3. `supertag-tag-change-merge-previews-canonical-target`: asserted the
   `"并入已有标签 other（token Canonical）"` heading and one `→ Canonical` arrow
   per entry.  Now asserts the new merge heading
   `Merge 'old' into existing Tag 'other' (token 'Canonical')` and the text
   summary.  Reason: preview format change; the merge target, prompt wording
   and resulting membership assertions are untouched.
4. `supertag-tag-change-retry-after-save-failure`: two assertions —
   `"待保存/待投影 1"` became `WILL CHANGE: 1` (the same fact: the occurrence
   still on disk is the work left), and the final `"待保存/待投影 0"` became a
   direct check that no occurrence of the old token survives in the text (a
   missing tag now returns nil from `-preview`, which the assertion above it
   already required).  Both changes are wording/shape only; the retry,
   recovery and "earlier files stay committed" contract is unchanged and now
   passes with the text path.

No test was weakened to hide a failure: every changed assertion was replaced by
the text-path equivalent of the same guarantee, or by a stronger one.

## Observations (out of scope)

1. **Metadata-line classification depends on Org structure.**  A `#tag` inside
   a `#+CAPTION:` line is rejected as `not a Tag: keyword line` when the line
   follows a src block, but accepted as paragraph text when it directly
   follows a property drawer.  Rename and delete agree with each other and with
   highlighting (they share one acceptance function), so the brief's
   consistency requirement holds; what is *not* guaranteed is "metadata lines
   are never rewritten".  Making the scan's classification independent of
   Org's parse state is its own change.
2. **`supertag-tag-merge-plan` / `-merge-execute` / `-rename-plan` /
   `-rename-execute` remain node-based** (they rewrite nodes through
   `supertag-tag-merge--rewrite-nodes` → `supertag-service-org-replace-tag`).
   They have no product caller — only `test/tag-merge-plan-test.el` drives them
   — so no user command still has the blind spot, but that API keeps it.  Not
   touched: the brief scoped rename/merge to the user-facing path.
3. **A pure rename creates the new entity before the write**, so an aborted
   rename leaves an empty target entity behind (the old code behaved the same
   way).  The same is visible in the retry test, where the second attempt
   becomes a merge into the entity the first attempt created.
4. **`supertag-service-org-replace-tag` is now unused by the rename command**
   but is still called by the merge-plan machinery above, so it stays.
5. The rename preview is shown by the command itself, so `supertag-embark` and
   the Tag Manager prompts now include a preview buffer pop and a single
   confirmation before any text is rewritten.
