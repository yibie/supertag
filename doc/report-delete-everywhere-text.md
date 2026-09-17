# Report: `delete-tag-everywhere` from Org text, plus orphan cleanup

Commit: `293e562 feat(tag): enumerate and delete Tag occurrences from Org text`
(files: `supertag-tag.el`, `supertag-view-tags.el`,
`test/delete-everywhere-text-test.el` new, `test/renovation-suites.el`).
Branch `supertagV2`. Nothing was run against `/Users/chenyibin/Documents/notes`;
every measurement below is a temp-directory fixture.

## What changed

**One text enumerator decides occurrences.** `supertag-tag--text-scan-buffer`
walks a buffer with a loose `#name` candidate regexp
(`supertag-tag--text-candidate-regexp`) and lets the view layer answer:
`supertag-view-helper--inline-tag-range-at` (which calls
`supertag-transform-inline-tag-matches-in-region`, `supertag-inline-tag-regexp`
and the object-range machinery) decides whether a candidate is a Tag
occurrence, and its `(BEGIN END NAME)` range is what gets deleted.  The
deleted set is therefore the highlighted set: measured on a fixture, a
`#old;` inside a src block, `#old]]` inside a link description, `:NOTE: #old`
in a property drawer, `#+CAPTION: META #old` and `* COMMENT hidden #old` are
all rejected and left byte-identical, while the heading/prose occurrences and
the FILETAGS entry are removed.

Per file the scan records `:file :begin :end :token :line :line-text :kind
:context :node-id :resolution`, with the context the brief asked for:
`file top`, `FILETAGS`, `heading :ID: <id>`, `heading without :ID:`,
`heading :ID: not projected`, `duplicate :ID: (Store points at another file)`.
Rejected candidates keep a `:reason` (`src or example block`, `link path or
description`, `property drawer`, `keyword line`, `commented heading`, or the
element type) and are rendered in a NOT CHANGED section.

**Files scanned** are the sync scope (via
`supertag-sync--effective-directories` when Sync is loaded, else the bound
`supertag-sync-directories`, with the exclude directories honoured) **plus
every file the Store projects the tag on**.  The Store's files are a
deliberate superset beyond "every Org file in scope": a tag whose text sits
in a file the scope no longer covers must still be reachable, and it keeps
the zero-scope cold-load path (`supertag-sync-directories nil`) working as
before.  Live buffers are read as-is so unsaved text is seen.

**`supertag-delete-tag-everywhere`** now previews file -> line with each
record's context label and a NOT CHANGED section, then writes the recorded
ranges file by file, back to front.  Back-to-front holds across the whole
file, not only within a node: owner groups are ordered by descending
position, so deleting one cannot shift the next.  Occurrences a node owns are
deleted inside `supertag-service-org--update-buffer-and-resync` (the
product's own save/projection thunk, `repair-projection' nil), so membership
and projection are refreshed by the existing machinery; occurrences no node
owns (no-`:ID:' heading, duplicate-ID copy, unprojected `:ID:`, FILETAGS
without a file node) are deleted by range and saved directly, because there
is no node to reproject.  `#+FILETAGS:` is written through
`supertag-service-org--set-filetags`, the existing writer.

**Rescan guard.** Immediately before a file is written it is rescanned and
compared (signature = begin/end/token set) with the previewed records.  A
mismatch leaves that file untouched, is reported as `N file(s) changed since
the preview; preview again`, and keeps the entity; other files still proceed.

**Entity gate.** After the write, nodes whose text no longer carries the tag
but whose projection still does are refreshed with a no-op thunk plus
`repair-projection' t -- never by re-running the regexp remover, which would
delete text the preview rejected.  The entity is deleted only when the
rescan finds no occurrence and no owner remains; otherwise the preview is
re-rendered with a NOT REMOVED section and a message names the counts.

**Orphans.** `supertag-report-orphan-tag-occurrences` renders a read-only
report grouped by token (file/line/context), and lists ambiguous tokens
separately under `Ambiguous tokens (not orphans)`.  `supertag-cleanup-orphan-
tag-occurrences` takes an explicit token name (`completing-read`, no
default), previews the same file -> line list, and rewrites only that token's
unresolved occurrences on the same range-write path; a token that resolves to
an entity (or resolves ambiguously) is refused with `user-error`.  Nothing is
cleaned without the user picking a token.

**Tag Manager bulk path** (`supertag-view-tags-delete`) now builds one
combined preview for all marked tags, shows it, and its single confirmation
carries the counts (`Delete N tags (a, b) everywhere? X occurrence(s) in Y
file(s) will be rewritten.` -- the old prefix is preserved for the existing
test).  The per-tag delete re-enumerates instead of reusing the combined
scan, because deleting one tag shifts the next tag's positions (found while
testing: the first version aborted the second tag as "text changed").

## Verification

Wrapper used everywhere (libgccjit cannot link `emutls_w` locally):

```sh
exec emacs --eval '(setq native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil)' "$@"
```

```
$ EMACS_BIN=<wrapper> bash test/run-tests.sh
manifest exit=0
35 suites: contract 166/166, compat 1, identity 34, vault 60, view-framework 49,
node-view-extra 22, automation-actions 52, extractor 29, persistence-restore 16,
multi-instance 1, mention-extra 24, saved-projection 31, property-automation 5,
move 62, promote 49, stream 25, find-node 29, add-link 96/99 + 3 skipped,
discovery 24, query-links 1, query-tag-completion 2, legacy-query-compat 1,
migrate 19, storage-format 51, property-consumers 21, tag-change 25,
named-link-query 6, svg-tag 13, tag-path 101, tag-merge-plan 7, tag-manager 20,
embark 34/35 + 1 skipped, ai 49/50 + 1 skipped, semantic 38, git 31
-- 1199 tests, 5 skipped, 0 unexpected, exit 0.

$ bash test/static-gates.sh
static-gates exit=0
Static O gates: PASS
```

**Every new test fails on the unpatched product** (`git stash push --
supertag-tag.el supertag-view-tags.el`, then the suite):

```
$ EMACS_BIN=<wrapper> bash test/run-tests.sh tag-change
FAILED 20/25 supertag-delete-everywhere-text-aborts-only-the-changed-file
FAILED 21/25 supertag-delete-everywhere-text-bulk-tag-manager-shows-preview
FAILED 22/25 supertag-delete-everywhere-text-covers-no-id-headings-and-filetags
FAILED 23/25 supertag-delete-everywhere-text-keeps-the-entity-when-text-remains
FAILED 24/25 supertag-delete-everywhere-text-labels-a-duplicate-id-copy
FAILED 25/25 supertag-delete-everywhere-text-orphan-report-and-cleanup
Ran 25 tests, 19 results as expected, 6 unexpected
```

Patched: `Ran 25 tests, 25 results as expected, 0 unexpected`.  The 19
pre-existing `tag-change` tests (including `...-retry-after-save-failure` for
rename and delete, `...-cancel-is-zero-write`, `...-unrelated-draft-does-not-
request-repair`, `...-delete-confirmed` with its FILETAGS assertion) and the
`tag-path` cold ownership test pass unchanged.

New tests (all temp-directory fixtures via `supertag-document-test-with-vault`,
whose root is `(file-truename (make-temp-file ...))`): no-`:ID:` heading plus
FILETAGS found/previewed/removed; duplicate-ID copy labelled and cleaned;
rejected shapes untouched and listed; entity kept when text remains after the
write; rescan abort for the changed file only; orphan report is zero-write and
cleanup removes only the chosen token; Tag Manager bulk preview before writing.

A real bug was caught during this work by the existing tests:
`supertag-tag--text-tokens-for-tag` originally used `delete-dups` on the
entity's own `:aliases` list and mutated the Store
(`("alias" "emacs/package" "old")` -> `("alias" "emacs/package")`); it now uses
`cl-remove-duplicates`.  `supertag-tag-change-cancel-is-zero-write` failed
until that was fixed.

## Out-of-scope findings (reported, not changed)

1. **Rename/merge still cannot see text-only occurrences.** `supertag-tag-
   rename` collects through `supertag-tag-change--collect` ->
   `supertag-find-nodes-by-tag` and edits per node.  Measured on a fixture
   with a no-`:ID:` heading and a duplicate-ID copy: after renaming `old` to
   `new`, `* Hashed #new` and `#+FILETAGS: :new:` were correct but
   `* No ID #old` / `Prose #old` and the copy file still read `#old`, i.e. a
   rename leaves exactly the occurrences this task taught delete to find
   (they become orphans once the old entity is gone).  The brief put rename
   out of scope, so nothing was changed.
2. **The occurrence model treats ASCII punctuation as part of a token.**
   `supertag-inline-tag-terminator-chars` is CJK punctuation only, so `#seo,`
   is the token `seo,`, `#old;` is `old;` and `#old]]` is `old]]`.  The
   near-miss matcher ignores a punctuation tail for reporting, but the tokens
   themselves stay distinct: a user's orphan list can therefore contain
   `#seo,`-style entries beside `#seo`.  Not changed (model out of scope).
3. **Ambiguity is surfaced, not resolved.** A token that resolves to several
   entities (`supertag-tag-resolve-occurrence` signals) is recorded as
   `:ambiguous`, listed in the orphan report under a separate heading, and
   refused by cleanup.  Case sensitivity is unchanged and unreviewed.
4. **Duplicate-ID files are flagged but not re-projected.** The preview labels
   them, the tag text is removed, and the Store keeps pointing the shared
   `:ID:` at the other file; no ID re-projection or conflict handling was
   added.
5. **`supertag-cleanup-orphaned-tags`** (the entity-side cleanup) is
   untouched; the new orphan commands deal with text, not entities, and the
   two are deliberately separate.
6. **Entity-gate behaviour change.** An entity that keeps an owner or any
   remaining text is now kept and reported where the old code could delete it
   after clearing projected nodes.  That is the brief's requirement, but it
   means a stale membership now keeps the entity until the file text is
   actually clean.

## Notes

- The project instruction to consult the code graph first could not be
  followed: the `code-review-graph` MCP server is disconnected and the
  `gitnexus` CLI is missing (`spawn gitnexus ENOENT`), so this work used
  grep/read, which the instruction allows as a fallback.
- The graph plan would also have flagged `supertag-node-tag-occurrences-at-point`
  and `supertag-service-org--update-buffer-and-resync` as the seams; both are
  outside the two files this brief allowed, and both are called (`declare-
  function`/autoload) rather than modified.
