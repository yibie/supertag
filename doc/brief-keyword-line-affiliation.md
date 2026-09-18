# Brief: a keyword line is metadata whether or not a paragraph follows it

## The defect

`supertag-view-helper--inline-tag-range-at` accepts an occurrence when
`org-element-context` reports `headline` or `paragraph`. That makes the same
line of text mean two different things depending on what comes *after* it:

```
* H
prose
#+CAPTION: META #foo          <- last line of the section
```
→ `org-element-context` reports `keyword`, occurrence **rejected**.

```
* H
prose
#+CAPTION: META #foo          <- followed by a paragraph
PROSE here
```
→ `#+CAPTION:` is now that paragraph's *affiliated keyword*, so
`org-element-context` reports `paragraph`, and the occurrence is **accepted**.

Both measured; the preceding element (src block, property drawer, prose) makes
no difference — affiliation is what decides.

Because highlighting, `delete-tag-everywhere`, the orphan cleanup and
rename/merge all share this one acceptance function, the consequence is that
a tag written in a `#+CAPTION:` (or any affiliated keyword line) is highlighted
and **rewritten** when a paragraph happens to follow it, and left alone when it
does not. The user cannot predict which, and a rename can silently edit Org
metadata.

## What to fix

A keyword line is metadata. Its text is not prose, and an occurrence on it
must never be treated as a tag occurrence — regardless of whether Org attaches
it to a following element as an affiliated keyword.

Decide the position's own line, not just what `org-element-context` reports for
the element containing it. The check must be robust for every affiliated
keyword, not special-cased to `#+CAPTION:` — `#+NAME:`, `#+ATTR_*:`,
`#+RESULTS:` and the rest behave identically.

Be careful not to over-reach:

- A **headline** occurrence must still be accepted.
- Ordinary **paragraph** prose must still be accepted, including a paragraph
  that happens to sit directly under an affiliated keyword line (the paragraph's
  own text is prose; only the keyword line is not).
- `#+FILETAGS:` must keep working as it does today. It is handled by its own
  writer (`supertag-service-org--set-filetags`) and is deliberately *not* an
  inline occurrence; do not change that behaviour in either direction.
- CJK, emoji and full-width `＃` behaviour is unchanged.

## Why it matters that one function decides

Highlighting and rewriting share this function on purpose: what the user sees
highlighted is exactly what a delete or rename will touch. Keep that property.
After the fix, a tag on a keyword line must be **neither highlighted nor
rewritten**, consistently.

Note this changes highlighting for such lines. That is intended — today they
are highlighted only in the affiliated case, which is itself the inconsistency.

## Tests

- `#+CAPTION: META #foo` as the last line of a section: rejected (pins today's
  behaviour, must not regress);
- the same line **followed by a paragraph**: now also rejected — this is the
  fix, and it must fail on current code;
- the following paragraph's own `#foo` is still accepted;
- `#+NAME:` and one `#+ATTR_*:` line behave the same as `#+CAPTION:`;
- a headline tag and a plain prose tag are still accepted;
- `#+FILETAGS:` handling is unchanged (assert whatever it does today still
  holds);
- rename and delete leave a keyword-line occurrence byte-identical and list it
  under `NOT CHANGED`.

Show the failing-before / passing-after evidence for the new case.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
bash test/run-tests.sh          # 35 suites / 1219 tests, currently 0 unexpected, exit 0
bash test/static-gates.sh       # exit 0
```

Nothing may regress. Expect the existing CAPTION test
(`supertag-tag-change-preview-keeps-not-changed-shapes`, restored in `62afb01`)
to become stronger rather than change meaning. If any other existing test
encodes the affiliated-accept behaviour, itemise it with the reason.

If the local libgccjit trampoline problem appears, use an `EMACS_BIN` wrapper
setting `native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil`.

## Method

Measure, do not reason statically. Both the coordinator and the previous agent
reached wrong conclusions about this exact code by reading it: the coordinator's
probes were all of the standalone shape, and an earlier probe took the position
of the token's last character instead of the `#`. Probe with a real Org buffer,
at the `#` marker, and print the element type alongside the accept/reject
result.

## Scope

`supertag-tag.el` and tests. Never run anything against
`/Users/chenyibin/Documents/notes`. Branch `supertagV2`. Do not touch the orphan
report UI — that is the next queued task.

## Reporting

Write `doc/report-keyword-line-affiliation.md` — the rule you implemented, the
measured before/after table, commit hash, verification with raw output, and any
existing test you changed with the reason — then end with
`DONE: doc/report-keyword-line-affiliation.md`. Stop with `BLOCKED: <reason>`
if a ruling is needed.
