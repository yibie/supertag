# Report: Node View — Similar notes persist, Unlinked Mentions group per source

Branch `supertag-refactor`. Batch only: no `emacsclient`, no user Emacs driven.
Every command below ran with a temp data directory
(`supertag-data-directory` / `supertag-db-file` under `mktemp -d`); the real
store `~/Documents/notes/.supertag/` was never loaded, migrated or saved.

## 1. Similar notes disappeared after a restart

**Root cause.** `supertag-semantic-rebuild` asked "Enable for this session…"
and only `setq` the variable, so the next Emacs started with
`supertag-semantic-enabled` nil and `supertag-semantic-insert-section`
returned nothing, although the side-car index was still on disk.

**Change** (`supertag-semantic.el`, `supertag-semantic-rebuild`):

- the prompt is now "Similar notes are off. Enable them for future sessions
  and index the vault? ";
- the endpoint probe runs *before* anything is stored;
- on acceptance the choice is written with
  `customize-save-variable 'supertag-semantic-enabled t` (after the probe, so
  a failing endpoint saves nothing);
- on a probe failure the session stays disabled too — previously the variable
  was already `t` for the session even though the probe failed.

The default stays nil, so the feature is still opt-in. `customize-save-variable`
writes to the user's `custom-file` (or init file) through standard Custom
behaviour; under `emacs -q` Custom refuses to save and only the session value
applies, as usual.

Docs: README.md / README_CN.md no longer say "for this session" / "仅为本次
Emacs 会话".

## 2. Unlinked Mentions listed one card per occurrence

**Root causes** (reproduced in an isolated temp vault):

- `supertag-mention-service--find-uncached` returns one candidate per
  occurrence and the view rendered one card per candidate: target "Pi" with
  one source holding 3 occurrences produced 3 identical cards.
- `supertag-mention-max-results` capped *occurrences*, so the first source's
  repetitions could fill the whole budget. Measured on the repro fixture with
  the cap set to 1: baseline returned a single record (`("head-src")`) and
  silently dropped every other source.
- a source that already links the target stayed listed. Body links are
  projected (`:ref-to` = `("pi")` and a `:document-link` relation), but a link
  written in the *heading* is not: for
  `* 为什么 X 上发 [[id:pi][Pi]] 的内容是错的` the projection shows
  `:ref-to nil` and `supertag-relation-find-between` returns nil, because
  `supertag-extractor--refs` only walks the headline's contents, not its
  title. That is why the live example was listed as an unlinked mention.

**Changes** (`supertag-mention.el`):

- `supertag-mention-service--links-target-p` excludes a source when it
  already points at the target through `:ref-to`, through a `:document-link`
  relation (`supertag-relation-find-between … :reference :document-link`,
  which also covers named Org links), or — the fallback for heading links —
  when its stored `:raw-value`/`:title` contains `[[id:TARGET]`.
- `supertag-mention-service--find-uncached` admits whole sources: a source is
  counted once and all of its occurrences are returned, and the cap
  (`supertag-mention-max-results`, docstring updated) now counts distinct
  sources. The result-cache token now covers `:nodes` *and* `:relations`,
  because the exclusion reads both.
- `supertag-view-mention--source-groups` groups the candidates by
  `:source-id` in first-appearance order; `supertag-view-mention-insert-section`
  renders one card per group and the section chip counts sources.
- `supertag-view-mention--insert-card` takes the occurrence count and adds one
  muted line `+N more` (face `supertag-view-mute`) after the excerpt when the
  source mentions the target again. The card's `[Link]` still receives the
  first occurrence, so it links exactly one occurrence; `[Ignore in node]` is
  per source as before.

Docs: README.md / README_CN.md "Unlinked mentions" and the
`supertag-mention-max-results` table row, plus UNLINKED-MENTIONS.md.

## Files

- `supertag-semantic.el` — persistent enable.
- `supertag-mention.el` — exclusion, source cap, grouping, `+N more`.
- `README.md`, `README_CN.md`, `UNLINKED-MENTIONS.md` — wording.
- `test/semantic-test.el`, `test/test-concept-mention.el` — tests.

## Commands and results

Reproduction and before/after probes (isolated temp vaults; script in
`/tmp/probe-mention.el`, `/tmp/probe-render.el`, `/tmp/probe-cap.el`, run
against a pristine `git archive HEAD` copy in `/tmp/st-base` and against the
final tree in `/tmp/st-mine2`):

```
fixture: target "Pi"; sources = 3 occurrences, 1 occurrence, a body link plus
         1 plain mention, a heading link plus 1 plain mention, 2 occurrences
baseline: 8 candidates in total (both linked sources listed);
          cap=1 -> ("head-src")           ; one occurrence hid four sources
final:    6 candidates (both linked sources excluded);
          cap=1 -> ("long-src" "long-src") ; every occurrence of one source
```

Render check from design.md §8 (batch text render, `org-link-display-format`
applied as the helper does):

```
width 120 -> UNLINKED MENTIONS / 03 (chip counts sources), one card each:
             excerpt of the first occurrence, "+1 more" / "+2 more" on a
             muted line, then [Link]  [Ignore in node]; max line width 119
width 80  -> same cards; a long CJK excerpt wraps to two lines and is clipped
             with "…"; max line width 79
```

Suites, run with `bash test/run-tests.sh <suite>` in temp copies of the tree
(child-process tests behave differently when the suite is run from a
non-temporary path, so both sides were run the same way); failure names
compared, baseline = pristine `git archive HEAD`:

```
suite           tests base->mine   unexpected base->mine   new failures
semantic         36 -> 38           5 -> 4                  none (one fixed)
mention-extra    16 -> 20           2 -> 2                  none
view-framework   49 -> 49           3 -> 3                  none
promote          48 -> 48          30 -> 30                 none
node-view-extra  22 -> 22           0 -> 0                  none
contract        162 -> 162         25 -> 25                 none
```

The remaining unexpected results are pre-existing in this environment (mainly
native-compiled subr stubs: `ld: library 'emutls_w' not found`, and one
long-standing storage/vault group in `contract`).

New/updated tests:

- `test/test-concept-mention.el` (mention-extra): one card per source with
  `+2 more` and chip count 2; `[Link]` on the grouped card rewrites only the
  first occurrence and leaves the other two as plain text; cap 1 keeps all
  occurrences of one source and cap 2 admits the second source; body-link and
  heading-link sources are excluded while a plain source stays listed.
- `test/semantic-test.el` (semantic): accepting writes
  `'(supertag-semantic-enabled t)` to a temp `custom-file` (and declines
  writes nothing); a probe failure after accepting saves nothing and enables
  nothing; an already-enabled session that fails the probe keeps its index and
  saves nothing; a *fresh* process that loads the saved `custom-file`, as an
  init file does, ends with `supertag-semantic-enabled` t
  (`FRESH=t`, child `emacs -Q --batch`). The old
  `…-rebuild-offers-session-enable` was replaced by these.

Byte compilation (temp copies, `byte-compile-file`, no `.elc` left behind):
`supertag-mention.el` and `supertag-semantic.el` produce the same 11 warnings
as HEAD (unknown optional providers, long docstrings) — no new warnings.
`bash test/static-gates.sh` passes.

## Judgment calls

- **Probe failure no longer enables the session.** The brief only requires not
  *persisting* on failure; keeping the flag also unset makes the retry prompt
  again instead of leaving a half-enabled feature after an error.
- **Heading-link fallback is a text match on the stored title**, not a new
  projection: heading links are deliberately not reference facts today, and
  changing the projection (and every consumer of `:ref-to`) would be a much
  larger change. The relation/`ref-to` query is the primary check; the title
  match only covers what the projection omits.
- **A source that links the target anywhere is hidden entirely**, even when it
  still has plain-text occurrences; "Unlinked Mentions" is about notes that
  are not connected yet.
- **`+N more` sits on its own muted line** after the excerpt: appending it to a
  clipped excerpt or to the action row could push a line past the pane width,
  which design.md §8 forbids.
- **Cap of 0** now admits one source (as before it returned one occurrence);
  no caller sets it, and the docstring says the cap counts sources.
- The three semantic tests that stub `yes-or-no-p` bind
  `native-comp-enable-subr-trampolines` to nil locally: this machine's native
  compiler cannot build subr trampolines, and without the binding the stub
  triggers a failing compile. The pre-existing semantic failures of the same
  kind (other subr stubs in that file) were left untouched.
- GUI CJK column alignment (design.md §8, last bullet) cannot be checked in
  batch; the batch render at 120/80 with CJK content is recorded above.
