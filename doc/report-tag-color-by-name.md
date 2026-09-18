# Report: each inline tag gets its own colour

Commit: `fad0ec9 feat(tag): colour each inline tag from its canonical name`.
Brief: `doc/brief-tag-color-by-name.md`.  Branch `supertagV2`.  Nothing was run
against `/Users/chenyibin/Documents/notes`; every measurement is a temp-directory
fixture whose root is `(file-truename (make-temp-file ...))` or a batch Emacs.

## How the colour is derived

1. **Canonical identity.** The matcher resolves the token with
   `supertag-tag-resolve-occurrence` and hands the resulting **Tag id** to
   `supertag-view-style--tag-face`.  The colour itself is hashed from
   `supertag-tag--name`, i.e. the entity's `:name` (falling back to the id), so
   two aliases of one Tag hash the same bytes and the raw token is never what
   gets hashed.
2. **Hue from a stable hash.** `supertag-view-style--name-hue` is 32-bit FNV-1a
   over the name's characters, modulo 360.  Deliberately not `sxhash`: the value
   must survive sessions, Emacs versions and machines, and must not depend on
   the store's hash-table order or on how many Tags exist.
3. **Bands pinned per background mode.** `supertag-view-style--color-bands`
   holds `(MODE SAT LIGHT)`:

   | mode | saturation | lightness |
   |------|-----------|-----------|
   | `dark` | 0.55 | 0.76 |
   | `light` | 0.55 | 0.32 |

   `(frame-parameter nil 'background-mode)` selects the band.  Only the hue
   varies per Tag, so no Tag can come out near-black on a dark background or
   near-white on a light one.
4. **HSL -> hex** with `color-hsl-to-rgb` then
   `(color-rgb-to-hex r g b 2)`.  The rounding argument matters: without it the
   result is not a valid short hex (`"#199933334ccc"`).

Measured contrast over **all 360 hues** (not just the sample below), against
`#1e1e1e` for dark and `#ffffff` for light:

| band | min contrast | max contrast | distinct colours |
|------|--------------|--------------|------------------|
| `dark` (S 0.55, L 0.76) | 6.85:1 | 12.43:1 | 254 / 360 |
| `light` (S 0.55, L 0.32) | 4.37:1 | 12.89:1 | 254 / 360 |

The light band clears 4.37:1 at its worst hue, i.e. even body-text contrast on
white; 8-bit rounding merges 106 of the 360 hue steps, which is why 254
distinct colours remain.

## The palette, as text

Ten real-ish names, hue and the exact hex each gets (this is the raw output of
`supertag-view-style--color-for-name`, with the contrast ratios computed from
those hex values):

| tag | hue | dark background | contrast | light background | contrast |
|-----|-----|-----------------|----------|------------------|----------|
| `emacs` | 56 | `#e3dea0` | 12.08:1 | `#7e7824` | 4.57:1 |
| `rust` | 287 | `#d4a0e3` | 7.89:1 | `#6b247e` | 9.64:1 |
| `zettel` | 49 | `#e3d7a0` | 11.51:1 | `#7e6e24` | 5.07:1 |
| `reading` | 251 | `#aca0e3` | 7.06:1 | `#35247e` | 12.32:1 |
| `meeting` | 346 | `#e3a0af` | 7.87:1 | `#7e2439` | 9.55:1 |
| `project` | 198 | `#a0cfe3` | 9.95:1 | `#24637e` | 6.64:1 |
| `writing` | 39 | `#e3cba0` | 10.57:1 | `#7e5f24` | 5.92:1 |
| `python` | 207 | `#a0c5e3` | 9.20:1 | `#24567e` | 7.76:1 |
| `package` | 243 | `#a3a0e3` | 6.90:1 | `#29247e` | 12.74:1 |
| `idea` | 146 | `#a0e3bd` | 11.29:1 | `#247e4b` | 5.05:1 |

## Cache design

The face is chosen per match during fontification, so the expensive path must
stay off it:

- `supertag-view-style--tag-face` looks the id up in
  `supertag-view-style--face-cache`, a hash table keyed by
  `(TAG-ID . BACKGROUND-MODE)`.  A hit costs one hash lookup; a miss runs the
  hash + HSL + hex once and stores the result.
- Keying on the background mode makes the cache self-correcting if the mode
  changes, and `enable-theme-functions` is additionally hooked to
  `supertag-view-style--clear-face-cache` (`clrhash`), the one hook worth
  keeping from the deleted SVG code.  The hook is installed under
  `(when (boundp 'enable-theme-functions) ...)`, matching the file's Hooks note.
- The face is an anonymous plist, `(:foreground "#…" :underline t)`; there is no
  `defface` per Tag.  The generated `:foreground` leads the plist so it wins if
  a user also set `:foreground`, and every other attribute from
  `supertag-view-style-tag-face-properties` (the underline, a `:weight`
  someone adds) still applies.
- `test-view-style-face-is-computed-once-per-tag` counts calls: three
  occurrences of one Tag in one buffer fontify to identical faces with exactly
  **one** call to `supertag-view-style--compute-tag-face` (counted with
  `cl-letf`, no wall-clock).

## Nested tags, measured

`#emacs/package` is coloured by its **leaf**.  One measurement decides what that
means here: a Tag *name* may not contain a separator
(`supertag-tag-create` signals "contains a path separator; creates a nested
tag"), and `supertag-tag-resolve-occurrence "emacs/package"` returns **nil**
unless some Tag claims that exact token (`supertag-tag--matching-ids` is a pure
token-index lookup).  So:

- when a leaf claims the path token (an alias, as the test does), resolution
  returns the leaf's id and the colour is the leaf's canonical name -- the test
  asserts `#emacs/package` and `#package` are the *same* face and that this
  differs from `(--color-for-name "emacs/package")`, i.e. the raw token is not
  hashed;
- when nothing claims it, the token is simply dimmed, like any other token the
  system does not know.

No parent-hue inheritance is built (a child does not derive from its parent's
colour).  If a family look is ever wanted, the place to do it is
`supertag-view-style--compute-tag-face`, e.g. by mixing in an ancestor's hue;
this report records it as a refinement, not a plan.

## What is drawn

| token | face | result |
|-------|------|--------|
| resolves to one registered Tag | anonymous plist `(:foreground "#…" :underline t)` | coloured **and** underlined |
| resolves to nothing (or to several Tags) | `supertag-unresolved-tag-face` = `(:inherit shadow)` | dimmed, no colour, no underline |
| `supertag-view-style-color-by-name` nil | `supertag-inline-face` = `supertag-view-style-tag-face-properties` | underline only, theme colour |

`supertag-view-style-color-by-name` (default `t`) is the single switch; both
face property `defcustom`s stay, so the underline or a pinned colour can still
be re-styled without editing code.

`design.md` section 2 ("Colored foreground text is not part of this system")
governs the buffers Supertag itself draws.  That is recorded as a comment right
above the colour machinery in `supertag-tag.el`, and no view page's palette was
touched: the diff is `supertag-tag.el` plus two test files, nothing under
`supertag-view-*.el`.

## Matching is untouched

`git diff -- supertag-tag.el | grep -c "font-lock-matcher\|inline-tag-range-at\|keyword-line\|terminator"`
prints **0**: the matcher, the range reader, the keyword-line rule and the
punctuation tokenisation from the two previous tasks are byte-identical.  Only
`supertag-view-helper--matched-tag-face` (which face to *draw*) and the new
colour code changed: +106 / -11 lines in `supertag-tag.el`.

## Tests

Added to `test/view-framework-test.el` (9 tests, +175 / -3):

1. `test-view-style-colour-is-stable-and-store-independent` -- repeated calls,
   a cleared cache and a `supertag-load-store` reload all give the same colour.
2. `test-view-style-colour-differs-per-tag` -- five names, five colours.
3. `test-view-style-alias-and-name-share-one-colour` -- `#emacs` and `#editor`
   fontify to the same face.
4. `test-view-style-nested-tag-is-coloured-by-its-leaf` -- see above.
5. `test-view-style-unresolved-token-keeps-shadow-without-colour` -- the symbol
   face, no `:foreground`, underline and foreground `unspecified`.
6. `test-view-style-colour-follows-the-background-band` -- saturation and
   lightness inside the pinned band for both modes, 0.2 < L < 0.9.
7. `test-view-style-face-is-computed-once-per-tag` -- the call count.
8. `test-view-style-face-cache-is-dropped-on-theme-change` -- the hook is
   registered and the cache empties.
9. `test-view-style-colour-can-be-switched-off` -- with the defcustom nil, the
   known tag gets `supertag-inline-face` and an unknown token still gets
   `supertag-unresolved-tag-face`.

Updated, with reasons:

- `test-view-style-face-stops-before-adjacent-org-link`: binds
  `supertag-view-style-color-by-name` nil.  Its contract is where styling stops,
  not its colour, so the `memq` on the two face symbols stays exact.
- `test-view-style-underlines-known-tags-and-dims-unknown-ones`: the known tag
  now carries a plist, so it asserts `:underline t` plus a `#rrggbb`
  `:foreground` instead of the face symbol (the unresolved half is unchanged).
- `test/tag-path-hierarchy-test.el` (+1 / -1): the embedded child program
  asserted `(eq 'supertag-inline-face ...)` for a registered tag; it now accepts
  either the plain face or a colour plist, and the negative case is strict for
  both.  That child's point is the Transform/display load split, not the face
  shape.

No test was deleted or weakened.

## Verification (raw)

`EMACS_BIN=/tmp/st-bin/emacs bash test/run-tests.sh` -> exit 0, no `FAILED`
line anywhere:

```
Suite: contract -> Ran 166 tests, 166 results as expected, 0 unexpected
Suite: view-framework -> Ran 59 tests, 59 results as expected, 0 unexpected
Suite: tag-change -> Ran 60 tests, 60 results as expected, 0 unexpected
Suite: tag-path -> Ran 101 tests, 101 results as expected, 0 unexpected
```

Totals: **34 suites, 1231 tests, 1226 results as expected, 5 skipped, 0
unexpected** -- the previous run's 1222 plus the 9 new colour tests.

`bash test/static-gates.sh` -> `Static O gates: PASS` (exit 0).

Post-commit introspection, raw:

```
LOADED tag+menu
tag-face-props=(:underline t)
unresolved-props=(:inherit shadow)
inline-face-underline=t
unresolved-face-underline=unspecified
keywords=((supertag-view-helper--font-lock-matcher (0 (supertag-view-helper--matched-tag-face) t)))
toggle-bound=nil
face-props-defcustom-bound=nil
```

and for the colour path:

```
color-by-name=t
emacs        hue= 56 dark=#e3dea0 light=#7e7824
rust         hue=287 dark=#d4a0e3 light=#6b247e
zettel       hue= 49 dark=#e3d7a0 light=#7e6e24
tag-face=(:foreground "#e3dea0" :underline t)
cache=1 hook=(supertag-view-style--clear-face-cache)
```

## Known ceilings

- Hue-only variation means two names can land a few degrees apart and look
  related (`emacs` 56 deg vs `zettel` 49 deg in the sample).  Inherent to a
  360-hue hash; a future refinement could jitter saturation as well.
- `color-values`/`color-name-to-rgb` are frame-dependent in batch and quantise
  badly there; the derivation itself is a pure function and the report's numbers
  come from the product code, not from those helpers.
- `background-mode` is read from the selected frame, like the existing view
  palette code does; per-frame colours are not implemented.

DONE: doc/report-tag-color-by-name.md
