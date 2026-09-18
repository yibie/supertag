# Report: a keyword line is metadata, affiliated or not

Commit: `dcad317 fix(tag): a keyword line is metadata, affiliated or not`
(files: `supertag-tag.el`, `test/keyword-line-affiliation-test.el` new,
`test/tag-rename-delete-test.el`, `test/renovation-suites.el`).
Branch `supertagV2`.  Nothing was run against `/Users/chenyibin/Documents/notes`.

## The rule implemented

An occurrence whose own line is an Org keyword line is never a Tag occurrence.
A line whose first non-blank characters are `#+` is such a line - `#+CAPTION:`,
`#+NAME:`, `#+ATTR_*:`, `#+RESULTS:`, `#+FILETAGS:` and the block delimiters -
whether or not Org affiliates it to the element that follows.  The decision is
made at the marker (`supertag-transform--inline-tag-keyword-line-p`), not from
the element type `org-element-context` reports.

Applied in:

- `supertag-transform-inline-tag-matches-in-region`: every match whose `#`
  sits on such a line is dropped.  This is the one place extraction
  (`supertag--extract-inline-tags` -> `:tag-occurrences`), highlighting
  (`supertag-view-helper--font-lock-matcher`) and the view gate
  (`supertag-view-helper--inline-tag-range-at`) all pass through, so the
  "highlighted = rewritten" property holds without further changes.
- `supertag-view-helper-remove-tag-text`: the raw-regexp writer behind
  `supertag-service-org-remove-tag` (Embark's remove-tag actions, automation,
  `supertag-remove-tag-from-node`) now skips the same lines, as its rename
  sibling `supertag-view-helper-rename-tag-text-in-node` already did.
- `supertag-tag--text-reject-reason`: such candidates are labelled
  `not a Tag: keyword line` in the preview's NOT CHANGED section.

Deliberately not changed: headline occurrences, ordinary paragraph prose
(including a paragraph sitting directly under a keyword line, whose own text is
prose), CJK/emoji/full-width behaviour, and `#+FILETAGS:`, whose occurrences
come from their own scanner and are written by
`supertag-service-org--set-filetags` in both directions.

## Measured before/after

Probe: a real Org file per fixture (`(file-truename (make-temp-file ...))`,
written with `with-temp-file`, then `find-file-noselect`), and at each `#tg`
marker (`match-beginning 0` after `re-search-forward "#tg"`):

```elisp
(org-element-type (org-element-context))            ; type at the marker
(supertag-view-helper--inline-tag-range-at pos)     ; the shared acceptance
```

| fixture (line at the marker) | type at marker | before | after |
|---|---|---|---|
| `#+CAPTION: META #tg`, last line of the section | `keyword` | REJECT | REJECT |
| `#+CAPTION: META #tg` + following paragraph | `paragraph` | **ACCEPT** | **REJECT** |
| `#+NAME: tbl #tg` + paragraph | `paragraph` | **ACCEPT** | **REJECT** |
| `#+ATTR_HTML: :class #tg` + paragraph | `paragraph` | **ACCEPT** | **REJECT** |
| `#+RESULTS: #tg` + paragraph | `paragraph` | **ACCEPT** | **REJECT** |
| `  #+CAPTION: META #tg` (indented) + paragraph | `paragraph` | **ACCEPT** | **REJECT** |
| `#+caption: META #tg` (lowercase) + paragraph | `paragraph` | **ACCEPT** | **REJECT** |
| `#+FOO: META #tg` (non-affiliated) + paragraph | `keyword` | REJECT | REJECT |
| the following paragraph's own `#tg` | `paragraph` | ACCEPT | ACCEPT |
| headline title `* H #tg` | `headline` | ACCEPT | ACCEPT |
| plain prose `prose #tg` | `paragraph` | ACCEPT | ACCEPT |
| `x #tg` inside a src block | `src-block` | REJECT | REJECT |
| `#+FILETAGS: :tg:` | - | no inline candidate | unchanged |

The same probe compared the shipped line test against Org's own classification
for twelve line shapes (`#+CAPTION: x`, `#+caption: x`, indented, `#+CAPTION:x`,
`#+FOO:x`, `#+FOO-BAR: x`, `#+FOO_BAR: x`, and the negative shapes
`#+CAPTION : x`, `#+ FOO: x`, `#+: x`, a full-width `＃+CAPTION:` line).
It agrees on every shape.  It is deliberately *broader* for block delimiters
(`#+BEGIN_SRC x`, which Org reports as a paragraph): a block-delimiter line is
not prose either, so it is metadata under the same rule, and positions inside
such blocks were already rejected by the element-type check.

A method note: the first version of the const used a `\`` anchor, which never
matched because callers use `looking-at-p` at the line beginning and `\`` only
matches `point-min`.  The probe showed the fix had no effect (`keyword-line-p`
returned nil on the very line it should match); the anchor was removed and the
table above is the re-measurement.

## Tests

New `test/keyword-line-affiliation-test.el` (registered in the `tag-change`
suite, selector `^supertag-keyword-line-`):

- `...-standalone-caption-is-not-an-occurrence` - pins today's rejection;
- `...-affiliated-caption-is-not-an-occurrence` - **the fix**; also asserts the
  element at the marker is still a `paragraph` (so the test shows the
  affiliation is real and no longer decides) and that the paragraph's own
  occurrence is the only record;
- `...-name-and-attr-keywords-are-metadata` - `#+NAME:` and `#+ATTR_HTML:`;
- `...-headline-and-prose-still-accept` - headline, prose, and the paragraph
  under a keyword line;
- `...-highlighting-paints-the-same-set` - the font-lock matcher paints exactly
  the accepted set (`#old` from the paragraph only);
- `...-rename-leaves-the-line-byte-identical` - preview lists the keyword line
  under NOT CHANGED with `not a Tag: keyword line`, the line is byte-identical
  on disk, only the prose occurrence is renamed;
- `...-delete-leaves-the-line-byte-identical` - same for delete, and the
  entity is still deleted (the metadata text is not an occurrence and does not
  keep it alive);
- `...-filetags-keeps-its-own-behaviour` - `#+FILETAGS: :old:` becomes
  `:new:` through its writer while the prose occurrence renames normally.

Failing-before / passing-after: pre-fix, seven tag-change tests fail (six of the
new ones plus the tripwire below), post-fix `tag-change` is 53/53.

### Existing test changed

`supertag-tag-change-caption-affiliation-decides-acceptance` (added in
`62afb01` as an explicit tripwire) -> renamed to
`supertag-tag-change-caption-affiliation-does-not-decide` and now asserts that
*both* the standalone and the affiliated shape are rejected, with the
affiliated case still yielding exactly the paragraph's occurrence.  Reason: the
test was written to pin the old rule and to fail when the rule was fixed; the
rule was fixed here, so its expectation flips, exactly as its docstring said it
would.  No other existing test encoded the affiliated-accept behaviour - the
`extractor`, `contract`, `saved-projection`, `mention-extra`, `promote`,
`semantic` and `ai` suites passed unchanged.

## Verification

```sh
$ EMACS_BIN=<wrapper> bash test/run-tests.sh
manifest exit=0   suites=35 tests=1227 skipped=5 unexpected=0
$ bash test/static-gates.sh
static-gates exit=0   Static O gates: PASS
$ EMACS_BIN=<wrapper> bash test/run-tests.sh tag-change
Ran 53 tests, 53 results as expected, 0 unexpected
```

## Notes

- Highlighting for affiliated keyword lines changes from painted to not painted;
  that is the intended consequence, and it is what makes the visible set equal
  to the rewritable set again.
- The orphan report is untouched (next queued task).  Because keyword lines are
  no longer occurrences, a stale `#tag` left on one is also not orphan
  material, which is consistent with "the tool never rewrites metadata".
- `supertag-service-org-remove-tag` / the merge-plan writers still exist for
  node-level operations; the raw remover now skips keyword lines, and the raw
  renamer already did, so those paths cannot edit metadata either.
