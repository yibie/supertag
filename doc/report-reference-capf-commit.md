# Report: `[[` reference completion always commits a link

Branch: `supertag-refactor`. Scope: `supertag-link.el` plus tests. The
concurrent multi-parent-tag task owns `supertag-tag.el`,
`supertag-migrate.el` and the tag suites; nothing of it was touched or
committed here.

## Symptom

Typing `[[` + title and picking a row in the popup (Corfu, orderless)
left the raw candidate text in the buffer instead of rewriting the
shorthand to `[[id:ID][Title]]`. Same report for a closer that an
auto-pairing input method already inserted (`[[Emac|]]`).

## Root causes

1. **The explicit create row was not a completion.** The table's `lambda`
   action tested only *existing* rows, so `test-completion` of the full
   create row was nil. Corfu's `corfu-complete` inserts the row and only
   calls the exit function when `(test-completion newstr table expr)` is
   true; with no exit call the inserted row text stayed and no link was
   written. Two further details made this unfixable by that check alone:
   the row string is rebuilt per call from the *live buffer prefix*, and
   the completion machinery calls the table back *after* it inserted the
   row (buffer text is then the row itself), so the recomputed row string
   no longer matched the inserted one, and a doubled
   `... [Create new node]  [Create new node]` row could be selected.
2. **A typed closer rejected the shorthand.** `[[Title]]` is parsed by
   `org-element` as a `link` from the first bracket, so
   `supertag-reference--completion-context-p` returned nil for
   `[[Emac|]]`, the CAPF returned no bounds, and other capfs
   (ispell/dabbrev/cape) took over. `【【Emac】】` already worked because
   `org-element` sees a plain paragraph there.
3. **A UI may hand back a propertyless string.** Corfu's
   `corfu--exit-function` falls back to the plain string when it is not
   `member` of its candidate list, and `corfu--done` is called with
   CANDS nil from several paths (`corfu--in-region-1` `total = 0`,
   `corfu-expand`'s `t` branch, `corfu-insert`). Without the
   `supertag-reference-*` properties `supertag-reference--post-completion`
   silently did nothing, leaving the raw text.

## Changes (`supertag-link.el`)

- `supertag-reference--link-scheme-regexp`: the known-scheme regexp is now
  a constant shared by the bounds test and the new link check (single
  source of truth for `id:`, `denote:`, `file:`, `http(s)`, `ftp:`,
  `mailto:`).
- `supertag-reference--shorthand-link-p`: a `link` element counts as a
  shorthand only when it has no description part and no known scheme;
  `supertag-reference--completion-context-p` allows exactly that case and
  still rejects real links, `[[x][desc]]`, code/verbatim/tables/…
- `supertag-reference--create-suffix`, `--create-row-p`,
  `--completion-candidates`: one place builds the candidate list
  (existing rows + optional create row). The create row is suppressed
  when the title already is a create row (repeated calls after insertion)
  or when the source node already owns the term.
- `supertag-reference--completion-title`: the create title is taken from
  the string being completed when that string is a create row, otherwise
  from the live prefix. This keeps the row string stable across the
  completion session, which is what makes the post-insertion
  `test-completion` check — and therefore the commit — succeed.
- `supertag-reference--completion-table`:
  - `lambda` (test-completion) accepts an exact match against existing
    rows **or** the full create row. A typed prefix never equals the row
    string, so typing is still not authorization to create.
  - `nil` (try-completion) still shapes the common prefix from existing
    rows only (so a unique existing target keeps expanding), and answers
    `t` for an exact full row so Corfu finishes instead of re-entering
    completion on its own inserted text.
- `supertag-reference--recover-selection` +
  `supertag-reference--post-completion` (now takes optional PREFIX and
  EXCLUDE-ID): when SELECTED arrives without reference text properties,
  it is matched against the table's candidates by plain text (full row),
  then by create title (bare typed title), before giving up. The commit
  is still gated on status `finished`/`exact`/`sole`.
- `supertag-reference-completion-at-point` passes PREFIX and SOURCE-ID to
  the exit function.

## Tests (`test/reference-capf-commit-test.el`, new)

Registered in `test/renovation-suites.el` under the existing `add-link`
suite (selector `t`, no new suite name).

- `…-exact-create-row-completes`: create row tests true, typed prefix and
  bare title do not, unique existing target still expands.
- `…-bounds-accept-a-typed-closer`: `[[Emac|]]` and `【【Emac|】】` return
  bounds ending at point; `[[Emac][desc]]`, `[[id:emac]]`,
  `[[https://emac]]` and a link with trailing text return none.
- `…-recovers-a-propertyless-existing-selection` /
  `…-recovers-a-propertyless-create-title`: the real CAPF exit function
  commits when called with the plain string.
- Real Corfu + orderless in batch (`corfu-mode`, stubbed popup, no user
  config): `corfu-complete` on the create row, `corfu-complete` on a
  multi-word existing row, `corfu-expand` on a unique target. These skip
  (`ert-skip`) when Corfu is not on the load path, e.g. in CI.

## Commands run and results

Reproduction (before the fix), Corfu/orderless from
`~/.config/nova-emacs/elpaca/builds/*/`, real `supertag-add-link-test`
fixtures:

```sh
EMACSLOADPATH="$DEPS" emacs -Q --batch -L . -L test -l /tmp/repro-capf.el </dev/null
```

`corfu-complete` on the create row left `[[Emacs Ti  [Create new node]`
(exit function never called), `[[Emac|]]` returned nil bounds. After the
fix every scenario reaches the create/commit path and `[[Emac|]]` returns
bounds `(48 . 52)`.

New tests, dependencies on the load path (7/7 pass):

```sh
EMACSLOADPATH="$DEPS" emacs -Q --batch -L . -L test \
  -l test/reference-capf-commit-test.el -f ert-run-tests-batch-and-exit
# Ran 7 tests, 7 results as expected, 0 unexpected
```

Same file against the pre-fix `supertag-link.el` (HEAD): 5 of 7 fail —
the create-row completion, the typed-closer bounds, both propertyless
recoveries and the real-Corfu create path — so the tests pin the bugs.
The two existing-row Corfu tests and the description/scheme bounds cases
pass on HEAD as well (they are regression guards).

Official runner, whole Add Link suite (99 tests: 92 existing + 7 new, 3
skipped because Corfu is not on the runner load path):

```sh
EMACS_BIN=emacs SUPERTAG_DEPS_LOADPATH="$DEPS" bash test/run-tests.sh add-link
# Ran 99 tests, 77 results as expected, 19 unexpected, 3 skipped
```

The 17 Add Link failures are pre-existing in this environment: a pristine
`git archive HEAD` copy run with the same command gives exactly the same
17 (`file-missing "Setting current directory"` in the child-process
LA/LB/LC/LD/VA/VB tests). A copy of the current working tree also carried
two failures from the concurrent tag/migrate edits
(`supertag-add-link-lc-main`,
`supertag-add-link-template-rejects-stale-active-vault`); a tree with HEAD
plus only the changes in this report reproduces the baseline failure list
exactly (`diff` of the FAILED lists is empty).

Other suites, HEAD vs. HEAD + this change, identical result lines:
`find-node` (29 tests, 12 unexpected both), `discovery` (24/2),
`mention-extra` (16/2), `extractor` (29/0), `promote` (48/31).

Byte compilation:

```sh
emacs -Q --batch -L . -L test -L <deps> \
  --eval '(byte-compile-file "supertag-link.el")'
```

Warning set identical to HEAD and to the pristine copy: the five
unknown `supertag-view-helper-*` functions, one over-long docstring
(line 414, pre-existing) and one unused lexical argument
(`supertag-reference--resolve-or-create`, pre-existing). No new warnings.
`bash test/static-gates.sh` passes.

## Judgment calls

- The create row's title is taken from the completion string when that
  string already is a create row, otherwise from the live buffer prefix.
  The alternative — always using the captured prefix — would freeze the
  row while a user types with `corfu-auto` off; always using the live
  prefix is what let the row text drift after Corfu inserted it. The
  chosen split keeps both behaviors correct.
- A create title that itself ends in `[Create new node]` is refused
  (whitespace-tolerant match), which is what stops the doubled row from
  ever being committed.
- Recovery matches existing candidates by their *display* string. Two
  nodes with an identical display string are indistinguishable to a UI
  that lost the properties; the first match wins. Properties, when
  present, are always authoritative and no lookup happens.
- The three Corfu tests need Corfu's own `corfu--capf-wrapper` (installed
  by `corfu-mode`) because that is what computes the candidate state the
  popup commands act on; they enable `corfu-mode` in the test buffer and
  stub `corfu--popup-show`/`hide`/`support-p` only.
- No Emacs process of the user was driven; everything ran in batch
  (`</dev/null`, `-Q`).
