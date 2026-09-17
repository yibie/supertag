# Brief: `delete-tag-everywhere` must find tags in the text, not only in the node model

## Scope — two bounded things, nothing more

1. `supertag-delete-tag-everywhere` enumerates occurrences from **file text**
   instead of trusting the database's node projection.
2. A way to clean up **orphan occurrences** — `#token` text whose tag entity
   no longer exists — which today no command can reach.

Explicitly **out of scope** (report findings, do not change): rename/merge,
the tag occurrence model or list-item granularity, native `:#x:` headline tag
import, tag-name case sensitivity, and the duplicate-ID file described below.

## What is wrong today

`supertag-delete-tag-everywhere` (`supertag-tag.el:3656`) builds its targets
from `supertag-tag-change-preview` (`:3457`), which walks nodes the **database**
has projected. It removes the tag from those, then deletes the entity once
`(supertag-find-nodes-by-tag id)` is empty (`:3676`). Both the enumeration and
the gate trust the DB. A diagnosis over the user's real vault found three ways
text escapes that:

- **Headings without `:ID:`.** Not projected, so never visited. Example:
  `#seo` on its own line under `* 域名比价 | …` in `resource__list.org:59`.
- **Duplicate-ID copies.** A heading whose `:ID:` also exists in another file.
  The DB node points at one file; the preview locates by node `:file`, so the
  other copy is unreachable. In the user's vault `2026.org` is a stale
  duplicate of the diary: all 434 of its IDs exist elsewhere, no DB node points
  at it, mtime frozen at 2026-08-28. It holds 16 residual occurrences.
- **The entity gate is DB-only**, so the entity is deleted while text remains,
  turning every leftover into an unresolved orphan.

The "preview" is also thin: it is a single `yes-or-no-p` with a node/file
count, not a listing of what will change. And the Tag Manager bulk path
(`supertag-view-tags.el:257-260`) asks one `"Delete N tags … everywhere?"` and
then calls `(supertag-delete-tag-everywhere id t)` with `skip-confirm` — the
user never sees what text is about to be rewritten.

## The fix

### 1. One text-based occurrence enumerator

Given a tag name (and its aliases/ID), return every occurrence across the sync
scope as concrete `(file BEGIN END line-text context)` records.

- Scan every Org file in scope. For a file with a live buffer, read the buffer
  (it may hold unsaved text); otherwise read the file.
- **The set it returns must equal exactly what the product itself treats as a
  tag occurrence.** Reuse `supertag-inline-tag-regexp`,
  `supertag-view-helper--inline-tag-range-at` and
  `supertag-transform-inline-tag-matches-in-region` (`supertag-tag.el:243`)
  rather than a fresh regexp. What gets deleted must be what the user sees
  highlighted — never a CSS colour, a link description, a src/example block, a
  property drawer.
- Resolve tokens through `supertag-tag-resolve-occurrence` where an entity
  exists; for orphans (part 3) match by token name.
- `#+FILETAGS:` — include it **only if** the product currently projects
  FILETAGS entries as supertag tag occurrences. Verify, do not assume; say which
  way it went and why.
- Context per record: whether the enclosing heading has an `:ID:`, is at file
  top, or has an `:ID:` that the DB assigns to a different file (duplicate).
- A cheap plain-string prefilter for `#name` before the Org-aware pass is fine;
  a full-vault scan took about 1 second in the diagnosis.

### 2. `supertag-delete-tag-everywhere` on top of it

- **Preview lists file → line**, with each record's context label. Things that
  look like the tag but will **not** be touched (native `:#x:`, link
  descriptions, src blocks) go in a separate "not changed" section, so the user
  is not surprised later.
- **Write by the recorded ranges.** Within a file, delete back to front. Just
  before writing, rescan; if the occurrences differ from what was previewed,
  abort that file and ask the user to preview again. Then save and reproject
  what changed.
- **Gate entity deletion on the files.** After writing, rescan the whole scope.
  Delete the entity only if there are zero text occurrences **and** no DB owner.
  If anything remains, keep the entity and report exactly where.
- **The Tag Manager bulk path must show the text preview.** One combined
  preview for all marked tags is fine; a bare "Delete N tags?" is not. The
  `skip-confirm` argument must never mean "rewrite Org text without having
  shown what changes".

### 3. Orphan occurrence cleanup

Orphan text has no entity, so `delete-tag-everywhere` refuses it with
`Unknown Tag`. Provide:

- a **read-only report** of orphan occurrences grouped by token, with
  file/line/context, and
- a **cleanup by token name** that shows the same file → line preview and
  rewrites only after confirmation, built on the same enumerator and write
  path.

It must not assume every orphan is garbage. Most orphans in the user's vault
were never deleted tags at all — they are tokens the user wrote that were
simply never registered (147 of them; e.g. `#seo`, while `SEO` existed with
different case). The user picks which tokens to clean; nothing is cleaned by
default.

## Hard rules

- **Non-invasive.** No Org text is rewritten without a preview of the exact
  lines and an explicit confirmation. This is the product's core promise.
- **Never touch the user's real vault.** Do not run any of this against
  `/Users/chenyibin/Documents/notes`, not even to "try it". All development and
  testing happens on fixtures in temp directories. The user's actual cleanup
  will be done by the user, interactively, after review.
- Use `(file-truename (make-temp-file …))` for fixture roots — this repo's
  suites broke on macOS for exactly that reason until recently.

## Tests to add

On temp-directory fixtures, at minimum:

- tag under a heading **without** `:ID:` is found, previewed and removed;
- tag in a **duplicate-ID** copy in a second file is found and labelled;
- occurrences inside a link description, src block, property drawer and a CSS
  hex colour are **not** touched and appear under "not changed";
- entity is **kept** when text remains after the write, and deleted when none
  does;
- rescan-abort: text changed between preview and write aborts that file;
- Tag Manager bulk delete shows the text preview before writing;
- orphan cleanup by token name removes only the chosen token, after preview.

For each test that encodes a bug, confirm it **fails on the current code**
before your fix.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
bash test/run-tests.sh            # full manifest: must stay exit 0, 0 unexpected
bash test/static-gates.sh         # must stay exit 0
```

The full manifest is 35 suites / 1193 tests and was green before you start;
nothing may regress. If the local libgccjit trampoline problem appears, use an
`EMACS_BIN` wrapper setting
`native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil`.

## Files

`supertag-tag.el`, `supertag-view-tags.el`, and new/changed test files. If you
find you need another product file, stop and report `BLOCKED` rather than
widening scope. Branch `supertagV2`. Batch verification only; never drive the
user's running Emacs.

## Reporting

When done, write `doc/report-delete-everywhere-text.md` — what changed, commit
hash(es), verification commands with raw results, and every out-of-scope finding
— then end your turn with `DONE: doc/report-delete-everywhere-text.md`. If you
hit a decision that needs a ruling, stop with `BLOCKED: <reason>`.
