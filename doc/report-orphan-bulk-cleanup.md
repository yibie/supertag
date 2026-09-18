# Report: bulk orphan cleanup (marks, one preview, one confirmation)

Commit: `f46307a feat(tag): bulk orphan cleanup with marks and one
confirmation` (files: `supertag-tag.el`, `test/orphan-bulk-cleanup-test.el`
new, `test/delete-everywhere-text-test.el`, `test/renovation-suites.el`).
Rework of `293e562` per `doc/brief-orphan-bulk-cleanup.md`.  Branch
`supertagV2`.  Nothing was run against `/Users/chenyibin/Documents/notes`;
every measurement is a temp-directory fixture whose root is
`(file-truename (make-temp-file ...))`.

## What changed

**The orphan report is actionable** (`supertag-report-orphan-tag-occurrences`
-> `*Supertag Orphan Tags*`, major mode `supertag-orphan-tags-mode`, derived
from `special-mode`).  It keeps the old read-only content -- token rows with
file / line / line text / context per occurrence, plus a separate
`Not orphans (ambiguous tokens)` list -- and adds marks:

| key | action |
|-----|--------|
| `m` | toggle the mark on the token or occurrence at point, move down |
| `u` | unmark the token or occurrence at point |
| `M` | mark every token |
| `U` | unmark everything |
| `D` | remove the marked occurrences (one preview, one confirmation) |
| `RET` | visit the occurrence's file and line |
| `g` | rescan the scope, keep the marks |
| `n` / `p` | next / previous row |
| `q` | `special-mode` quit |

Marks follow the Tag Manager exactly: a two-character `"* "` prefix in
`supertag-view-accent`, `m` toggle / `u` unmark / `U` unmark-all keys, and a
header line (` Orphan Tags   3 token(s) / 6 occurrence(s)   3 token(s) marked,
6 occurrence(s) selected `) mirroring "… N marked".  `M` is new only because
the Tag Manager has no mark-all; it follows the same lowercase-per-row,
uppercase-global convention.

**Every token starts marked.**  "Review, then confirm" is therefore the
default: open the report, unmark the few tokens to keep, press `D`, confirm
once.  Occurrence rows are markable too, so one occurrence can be excluded
while its token stays marked; unmarking a token visibly unmarks its
occurrence rows (a test asserts the `"  #word"` / `"      N  …"` prefixes).

**One bulk command.**  `D` (and the non-interactive entry) reuses the
`293e562` write path unchanged: `supertag-tag--text-preview` (one listing of
every file and line across all marked tokens, plus the NOT CHANGED section),
one `yes-or-no-p`, then `supertag-tag--text-write` with its per-file rescan
guard.  The shared step is now `supertag-tag--orphan-remove`; no second
removal path exists.  A failed or aborted file keeps its text and re-renders
a `NOT REMOVED` preview.

**Non-interactive entry.**  `supertag-cleanup-orphan-tag-occurrences` accepts
a token name, a list of names, or nil for every orphan token; it never opens a
minibuffer.  Explicit names that resolve to a Tag entity (or ambiguously) are
still refused with `user-error`, so the command can only delete text no entity
claims.  The old single-token interactive behaviour is therefore a subset of
the new signature, not a separate code path.

**Stem handling (the punctuation wrinkle).**  One markable row per token, but
rows are sorted by stem so variants are adjacent, and a variant is labelled:

```
* #seo   3 occurrence(s)
    * 5  /…/node.org   [heading :ID: hashed]   * Hashed #seo
    …
* #seo,   1 occurrence(s)   [stem #seo]
    * 9  /…/node.org   [heading :ID: hashed]   Body #seo and #seo, and #old
```

That is the brief's "at minimum display them adjacently" option, plus the
`[stem #seo]` label and a note line in the report explaining that ASCII
punctuation belongs to the token.  I did **not** make a stem mark cover all
its variants: with everything marked by default, and top-down navigation, the
only practical flow is unmarking keepers, where adjacency plus the label makes
the leftover variant obvious.  The tokenizer is untouched, as scoped.

Two defects found while testing this and fixed in the same commit:
1. the row lookup's backward-character fallback let a token row inherit the
   occurrence row ending on the line above, so `u` on `#word` unmarked its
   neighbour instead (now the fallback is consulted only on a row's newline);
2. `D` ran its refresh in the preview buffer, because the preview pops to it
   (now it refreshes the report buffer explicitly).

## Verification

```sh
EMACS_BIN=<wrapper> bash test/run-tests.sh      # exit 0
$ python3 -c "...summarise 'Ran N tests' lines..."
suites=35 tests=1206 skipped=5 unexpected=0

bash test/static-gates.sh                        # exit 0
Static O gates: PASS
```

(`static-gates` first failed on the new lazy view-framework require; it now
carries a one-line `;; lazy-require: …` marker as that gate requires.)

`tag-change` suite with the rework:

```
Suite: tag-change
Ran 32 tests, 32 results as expected, 0 unexpected
   passed  25/32  supertag-delete-everywhere-text-orphan-report-and-cleanup
   passed  26/32  supertag-orphan-tags-bulk-remove-all-in-one-confirmation
   passed  27/32  supertag-orphan-tags-cleanup-list-needs-no-minibuffer
   passed  28/32  supertag-orphan-tags-mark-all-and-unmark-all
   passed  29/32  supertag-orphan-tags-refresh-keeps-deliberate-unmarks
   passed  30/32  supertag-orphan-tags-rescan-aborts-only-the-changed-file
   passed  31/32  supertag-orphan-tags-unmarked-token-survives
   passed  32/32  supertag-orphan-tags-visit-opens-the-occurrence-line
```

**Pre-fix evidence** (`git stash push -- supertag-tag.el`, then the suite):

```
Ran 32 tests, 24 results as expected, 8 unexpected
   FAILED  supertag-delete-everywhere-text-orphan-report-and-cleanup
   FAILED  supertag-orphan-tags-bulk-remove-all-in-one-confirmation
   FAILED  supertag-orphan-tags-cleanup-list-needs-no-minibuffer
   FAILED  supertag-orphan-tags-mark-all-and-unmark-all
   FAILED  supertag-orphan-tags-refresh-keeps-deliberate-unmarks
   FAILED  supertag-orphan-tags-rescan-aborts-only-the-changed-file
   FAILED  supertag-orphan-tags-unmarked-token-survives
   FAILED  supertag-orphan-tags-visit-opens-the-occurrence-line
```

The eight are the seven new tests plus the updated report assertion in
`delete-everywhere-text-test.el` (the old report has no marks and no
`All tokens start marked` line).

Test-by-test coverage of the brief's list:
- **Marking all + one bulk command** -- `…bulk-remove-all-in-one-confirmation`
  captures the prompt and the preview *at prompt time*: exactly one
  confirmation, `WILL CHANGE: 6` listing all four changed lines and all four
  rejected shapes, then every orphan gone, `#old` (a registered Tag) intact,
  the report refreshed to nothing.
- **Unmarking one token** -- `…unmarked-token-survives`: `#word` text stays in
  both files, `#seo`/`#seo,` text goes, and the refreshed report holds exactly
  `("word")`.
- **Non-interactive entry** -- `…cleanup-list-needs-no-minibuffer` stubs
  `completing-read` to fail the test if called, clears one token from a list,
  refuses `"old"` (registered) with `user-error`, and clears everything with
  no argument.
- **Rescan guard** -- `…rescan-aborts-only-the-changed-file`: the edited file
  keeps its text and the user's unsaved edit; the other file is cleaned; the
  preview showed all six lines.
- **NOT CHANGED shapes** -- asserted byte-identical in both the bulk and the
  non-interactive tests (src block, link description, `#+CAPTION:` line,
  `COMMENT` heading).

## Out-of-scope observations

1. **ASCII punctuation stays inside tokens** (`#seo,` is the token `seo,`) per
   the brief.  The report mitigates display only; a user still unmarking by
   hand must read the `[stem …]` labels.  A real fix would live in the
   occurrence model.
2. **Tag Manager has no mark-all.**  I added `M` to the orphan report; the Tag
   Manager still only offers `U`.  Unifying that is a separate change.
3. **The report is not a View Runtime page.**  The brief allowed "a view file
   if the actionable buffer belongs there"; I kept it in `supertag-tag.el`
   next to the other Tag surface (`*Supertag Tag Change*`), because it is a
   report-and-act buffer over text, not a rendered page, and because
   registering a new View Runtime view would have required touching view
   wiring outside the listed scope.  Marks, keys and header line follow the
   Tag Manager regardless.  If the coordinator wants it as a real
   `supertag-view-*` page (design.md skeleton, width renders), that is a
   follow-up decision, not a correction of this one.
4. **FILETAGS orphans work too** (verified in a scratch fixture, not a
   permanent test): an unregistered `#+FILETAGS: :never:` token is reported
   with context/kind `:filetags` and its cleanup removes the line through
   `supertag-service-org--set-filetags`, so the whole-file deletion path can
   reach token text the user never wrote inline.
5. **No entity work**: the orphan commands still only remove text.  They never
   create, rename or delete Tag entities, so a token that should have been
   registered must be registered by the user afterwards.
6. **`g` keeps deliberate unmarks and does not auto-mark newly appeared
   tokens** (documented in the command's docstring): a token the user
   unmarked must not come back marked on a refresh.
