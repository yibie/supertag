# Brief: rename/merge has the same blind spot delete just lost

## The problem

`supertag-delete-tag-everywhere` was fixed in `293e562` to enumerate tag
occurrences from **Org text**. `supertag-tag-rename` (and the merge path) was
left as it was: it collects through `supertag-tag-change--collect` ->
`supertag-find-nodes-by-tag` and edits per node, so it only reaches text the
**database** has projected onto a node.

This was measured on a fixture during that work: renaming `old` to `new` left

- `* No ID #old` (heading without `:ID:`) — untouched,
- `Prose #old` in that heading's body — untouched,
- the `#old` in a duplicate-`:ID:` copy file — untouched,

while `* Hashed #new` and `#+FILETAGS: :new:` were correct. Once the `old`
entity is gone, every one of those leftovers becomes an orphan — exactly the
mess the user has been cleaning up.

So rename currently *manufactures* the orphans that delete just learned to
find.

## What to do

Put rename/merge on the **same text enumerator** that `293e562` built. Do not
write a parallel scanner.

- Reuse `supertag-tag--text-scan-buffer` / the shared enumerator, the
  `(BEGIN END NAME)` range records, the preview, the per-file rescan guard and
  the range-write path. The set of occurrences rename rewrites must equal the
  set delete would remove, which in turn equals the set the product highlights.
- **Preview before writing**, file → line, with the same context labels
  (`heading without :ID:`, `duplicate :ID:`, `FILETAGS`, …) and the same
  `NOT CHANGED` section for shapes that only look like tags (link descriptions,
  src blocks, property drawers, commented headings). Renaming rewrites the
  user's Org text, so the non-invasive rule applies with full force: no write
  without the exact lines shown and confirmed.
- **Merge** (renaming onto an existing tag name) goes through the same path.
  Be explicit in your report about what merge does to membership when both tags
  are on one node — it must not produce a duplicate tag on that node.
- Keep the existing retry/recovery contract intact. `tag-change` has tests such
  as `...-retry-after-save-failure` for rename; they must still pass unchanged.
  If one genuinely has to change, itemise it and say why.
- Whatever the entity-side gate is for rename, make it consistent with the one
  delete now uses: do not delete or retire the old entity while text still
  carries the old name; report what remains instead.

## Watch for

- Rename writes rather than deletes, so the byte length changes. The
  back-to-front per-file write order that `293e562` relies on matters even more
  here — confirm it, and add a test with several occurrences in one file where a
  naive forward pass would corrupt later positions.
- `#+FILETAGS:` must be renamed through the existing writer
  (`supertag-service-org--set-filetags`), not by raw text substitution.
- The tokenizer changed in `81b8b95` (trailing ASCII punctuation is stripped).
  `#old,` at the end of a sentence is now the token `old` and **must** be
  renamed. Add a test for that; it is the interaction between the last two
  changes and nobody has covered it.

## Tests

On temp fixtures (roots via `(file-truename (make-temp-file …))`), at minimum:

- rename reaches a heading **without** `:ID:`, its body prose, and a
  duplicate-`:ID:` copy in another file;
- `#old,` (trailing punctuation) is renamed;
- several occurrences in one file are all rewritten correctly;
- `NOT CHANGED` shapes stay byte-identical;
- preview is shown and a decline writes nothing;
- rescan guard aborts only the file that changed;
- merge onto an existing tag leaves no duplicate membership;
- the old entity is not retired while text still carries the old name.

Each new test must fail on the current code — show that.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
bash test/run-tests.sh          # 35 suites / 1212 tests, currently 0 unexpected, exit 0
bash test/static-gates.sh       # exit 0
```

Nothing may regress. If the local libgccjit trampoline problem appears, use an
`EMACS_BIN` wrapper setting
`native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil`.

## Scope

`supertag-tag.el` and tests; `supertag-view-tags.el` only if the Tag Manager's
rename entry needs the preview wired through (likely — check it, the bulk
delete path had exactly this problem). Never run anything against
`/Users/chenyibin/Documents/notes`. Branch `supertagV2`.

Do not touch the orphan report UI — turning it into a proper `supertag-view-*`
page is the next queued task and will conflict.

## Reporting

Write `doc/report-rename-merge-text.md` — what changed, commit hash,
verification with raw output, every existing test you modified and why, and
what merge does to membership — then end with
`DONE: doc/report-rename-merge-text.md`. Stop with `BLOCKED: <reason>` if a
ruling is needed.
