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

1. **Metadata-line classification depends on Org's parse of the line's
   neighbours, and the guarantee is therefore not absolute.**  Measured (see
   the addendum at the end of this report): a standalone `#+CAPTION:` line is a
   `keyword` element and its `#tag` is not an occurrence, while the same line
   directly followed by a paragraph is that paragraph's *affiliated keyword*,
   so `org-element-context` reports a paragraph and the occurrence **is**
   accepted - rename and delete would rewrite it.  Rename, delete and
   highlighting all agree with each other (they share one acceptance
   function), so the brief's consistency requirement holds; what is not
   guaranteed is "metadata lines are never rewritten".  Fixing that belongs to
   whoever owns `supertag-view-helper--inline-tag-range-at` /
   `supertag-transform-inline-tag-matches-in-region`.
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

## Addendum (review of `9bafeed`): CAPTION classification, measured

The review rejected the reason given for dropping the `(should-not
(string-match-p "CAPTION" ...))` assertion: three probes (`#+CAPTION: META
#foo` after a src block, after a property drawer, after ordinary prose) all
*rejected* it.  Reproduced: the conclusion was right in substance but **wrong
in cause**, and the test assertion had to come back in a stronger form.  This
section is the evidence.

### The call used

A real org file per fixture (`(file-truename (make-temp-file ...))`, written
with `with-temp-file`, then `find-file-noselect`), and at the marker of
the tag inside the CAPTION line:

```elisp
(goto-char (point-min))
(search-forward "#+CAPTION: META #")      ; point is just after the `#'
(let ((pos (1- (point))))                  ; the marker itself
  (org-element-type (org-element-context))
  (supertag-view-helper--inline-tag-range-at pos))
```

### Raw result (probe output, unabridged)

```
--- E1 standalone CAPTION after src block (coordinator case 1)
* H|#+BEGIN_SRC text|x|#+END_SRC|#+CAPTION: META #alias|
[type=keyword range=nil accepted=nil]
--- E2 CAPTION after src block, followed by prose
* H|#+BEGIN_SRC text|x|#+END_SRC|#+CAPTION: META #alias|PROSE #alias|
[type=paragraph range=(50 56 "alias") accepted=t]
--- E3 standalone CAPTION after property drawer (coordinator case 2)
* H|:PROPERTIES:|:ID: h|:END:|#+CAPTION: META #alias|
[type=keyword range=nil accepted=nil]
--- E4 CAPTION after property drawer, followed by prose (failing-test shape)
* H #alias|:PROPERTIES:|:ID: alias-node|:END:|#+CAPTION: META #alias|PROSE #alias|
[type=paragraph range=(63 69 "alias") accepted=t]
--- E5 CAPTION after ordinary prose, followed by more prose (case 3 plus text)
* H|Prose line|#+CAPTION: META #alias|More prose #alias|
[type=paragraph range=(32 38 "alias") accepted=t]
--- E6 standalone CAPTION after ordinary prose (coordinator case 3)
* H|Prose line|#+CAPTION: META #alias|
[type=keyword range=nil accepted=nil]
```

### Cause: affiliation, not the drawer

A `#+CAPTION:` line that has a following line of element text is Org's
*affiliated keyword* of that element, so `org-element-context` at the marker
reports that **paragraph** (`type=paragraph`) and the acceptance gate
(`memq type '(headline paragraph)`) passes - `range=(BEGIN END "alias")`.
When the same line is the last line of its section it is a plain **`keyword`**
element and the occurrence is rejected.  The preceding line (src block,
drawer, or prose) makes no difference: E1/E3/E6 reject and E2/E4/E5 accept.
So the coordinator's three probes were all of the *standalone* shape, which is
exactly the rejected case; the failing test's fixture had
`#+CAPTION: META #alias` immediately followed by `PROSE #alias`, which is the
accepted shape, and that is why its preview listed the line under
`WILL CHANGE`.

### What my earlier probe got wrong

My first probe passed `(1- (point))` after `(re-search-forward "#alias")`,
i.e. the position of the final `s`, not of the `#`.  Every position then
looked rejected - including a *headline title* tag that the product obviously
accepts - and the invalid result is what produced the "after a property
drawer" story.  The table above uses the marker position and is reproducible
with `bash -c` free of any product state.

### Test changes in this addendum (tests only)

1. `supertag-tag-change-preview-keeps-not-changed-shapes`: the CAPTION
guarantee is restored, and now stronger - the fixture appends

```
#+BEGIN_SRC text
META #alias
#+END_SRC
PROSE #alias
#+CAPTION: META #alias
```

so the `#+CAPTION:` line is a plain keyword, and the test asserts the CAPTION
text appears **only after** the `NOT CHANGED:` header and never in the changed
section, alongside the src-block assertion (both present, as requested).

2. New `supertag-tag-change-caption-affiliation-decides-acceptance` pins the
measured rule both ways: a standalone CAPTION (followed by nothing) is not an
occurrence, the same line followed by a paragraph is.  Its docstring names
this as the open question and states that a rule fix must update the test, so
the fix cannot land silently.

### Corrected claim

"Metadata lines are never rewritten" does **not** hold today: a `#+tag` on an
affiliated `#+CAPTION:` line is a real occurrence, and rename/delete rewrite
it.  Rename, delete and highlighting still agree with each other, so the
consistency requirement of this brief holds, but making metadata lines immune
is a change to the acceptance rule itself (out of this task's scope, which is
`supertag-tag.el` plus tests).

### Verification after the addendum

```
$ EMACS_BIN=<wrapper> bash test/run-tests.sh
manifest exit=0   suites=35 tests=1219 skipped=5 unexpected=0
$ bash test/static-gates.sh
static-gates exit=0   Static O gates: PASS
$ EMACS_BIN=<wrapper> bash test/run-tests.sh tag-change
Ran 45 tests, 45 results as expected, 0 unexpected
```
