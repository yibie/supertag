# Brief: orphan cleanup needs a direct bulk action, not per-token picking

## What is wrong

`supertag-cleanup-orphan-tag-occurrences` (added in `293e562`) takes one token
name through `completing-read` with no default. To clear a vault with ~180
orphan occurrences across dozens of distinct tokens, the user has to invoke the
command once per token and answer a minibuffer prompt each time.

The user's verdict: *"就不能直接移除吗？我还选啥？不应该打开 mini-buffer 让我一个个挑"*.

That design was a mistake. The caution it was trying to express — not every
orphan is garbage — belongs in a preview the user reviews, not in forcing
repetitive selection. Per-item picking makes the user feed the system; this
product is supposed to work the other way round.

## What to build

Make the orphan report **actionable**, following the Tag Manager pattern
already in this repo (`supertag-view-tags.el`: marked rows, one bulk command,
one confirmation).

1. **`supertag-report-orphan-tag-occurrences` becomes an actionable buffer**,
   not a read-only dump. Group by token, showing file / line / line text /
   context for each occurrence, as it does now.

2. **Marks.** Mark and unmark a token (and ideally an individual occurrence),
   mark all, unmark all. Use this repo's existing view conventions for the
   keys and for how marks are displayed; do not invent a new idiom. Check
   `supertag-view-tags.el` and follow it.

3. **One bulk command removes everything marked**: a single preview listing
   every line that will change across all marked tokens, a single
   confirmation, then the whole job in one pass. Reuse the range-write path and
   the rescan guard from `293e562` — do not write a second removal path.

4. **Everything starts marked**, so "review, then confirm" is the default flow
   and clearing the whole vault is one keystroke plus one confirmation. The
   user unmarks the few they want to keep.

5. **Keep a non-interactive entry point** that takes the token list as an
   argument, so the whole set can be cleared without any minibuffer at all.
   The existing single-token command may stay as a thin wrapper over it, but it
   must no longer be the only way in.

The `NOT CHANGED` section (link descriptions, src blocks, property drawers,
commented headings) stays as it is — those are never candidates.

## Keep these properties

- **Non-invasive still holds**: no Org text is rewritten without the user
  seeing the exact lines and confirming. Bulk means one preview for everything,
  not no preview.
- The deleted set stays exactly what the product highlights as a tag
  occurrence. Do not widen the matcher to sweep up more.
- Never run anything against `/Users/chenyibin/Documents/notes`. Fixtures in
  temp directories only, with roots built as
  `(file-truename (make-temp-file …))`.

## A real wrinkle to handle

ASCII punctuation is currently part of a token, so `#seo,` is the token `seo,`
and appears separately from `#seo`. If the user marks `seo` they will silently
miss `seo,`. Do not fix the tokenizer (out of scope, it is the occurrence
model). Instead make the report **group punctuation variants of the same stem
together** so marking the stem covers them, or at minimum display them
adjacently so the omission is obvious. Say which you did.

## Tests

On temp fixtures: marking all and running the bulk command clears every
orphan occurrence in one preview + one confirmation; unmarking one token leaves
exactly that token's text untouched; the non-interactive entry point clears a
given token list with no minibuffer; the rescan guard still aborts only the
file that changed; `NOT CHANGED` shapes stay byte-identical. Each new test must
fail on the current code — show that.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
bash test/run-tests.sh          # 35 suites / 1199 tests, currently 0 unexpected, exit 0
bash test/static-gates.sh       # exit 0
```

Nothing may regress. If the local libgccjit trampoline problem appears, use an
`EMACS_BIN` wrapper setting
`native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil`.

## Scope

`supertag-tag.el`, plus a view file if the actionable buffer belongs there, and
tests. Branch `supertagV2`. Batch verification only; never drive the user's
running Emacs.

## Reporting

Write `doc/report-orphan-bulk-cleanup.md` — what changed, commit hash,
verification commands with raw output, and anything out of scope you noticed —
then end your turn with `DONE: doc/report-orphan-bulk-cleanup.md`. If something
needs a ruling, stop with `BLOCKED: <reason>`.
