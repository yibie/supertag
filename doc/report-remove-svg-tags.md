# Report: SVG tag rendering is deleted; inline tags are underlined

Commit: `e422b83 feat(tag): inline tags are underlined text, not SVG badges`.
Brief: `doc/brief-remove-svg-tags.md`.  Branch `supertagV2`.  Nothing was run
against `/Users/chenyibin/Documents/notes`; every measurement is a
temp-directory fixture whose root is `(file-truename (make-temp-file ...))`.

## Deleted

`supertag-tag.el`: **+19 / -343** (`git diff --cached --numstat`), 4639 -> 4315
lines, net -324.  Removed forms, counted from the diff:

| what | count |
|------|-------|
| `defgroup` (`supertag-view-svg-tag`) | 1 |
| `defcustom` | 11 |
| `defun` | 22 |
| `defvar` (svg keyword list, image cache) | 2 |
| startup lines (`enable-theme-functions` hook, refresh call) | 2 |
| the `;; Customization` block as one unit | 309 lines |

The 309-line block runs from `;;; Customization` through
`supertag-svg-tag--refresh-all-buffers`: the group and its defcustoms
(`supertag-svg-tag-enable`, `-style`, `-padding-x`, `-radius`,
`-stroke-width`, `-font-scale`, `-font-family`, `-min-column-em`,
`-show-hash`, `-font-weight`, `-color-alpha`), colour generation
(`--is-light-theme-p`, `--hash-to-index`, `--hsl-color`, `--hsl-rgba`,
`--neutral-colors`, `--colored-colors`, `--get-colors`), the builder and cache
(`--char-width`, `--char-height`, `--font-size-px`, `--base-font-px`,
`--text-pixel-width`, `--default-font-family`, `--make-svg`, `--get-cached`,
`--clear-cache`, `--match-handler`), the theme hook (`--on-theme-change`),
`--enable`, `--disable`, the toggle command `supertag-toggle-tag-style`, and
`--refresh-all-buffers`.

Also removed from that file, all of it verified by reading the resulting file:

- `(require 'svg)`, `(require 'color)`, the `svg` and `color` names in
  `;; Dependencies:`, and `supertag-toggle-tag-style` from `;; Commands:`.
  `color-*` was used only by the deleted HSL helpers; a repo-wide search for
  `color-hsl`, `color-rgb`, `color-name-to-rgb` and `(require 'color)` outside
  `archive/` matches nothing else, so the require was dead once the block went.
- the commentary line "Ordinary face styling and SVG rendering share this
  feature and parser" and the `;;; Tag display: plain faces and SVG` header.
- `font-lock-extra-managed-props`: the mode pushed `display` onto it only so
  font-lock could clear the image property.  Nothing else needs it, so the
  mode no longer touches that variable (measured: `display-in-extra-managed`
  is nil after enabling the mode).
- `supertag-toggle-tag-style` is gone outright: `fboundp` is nil, and no
  `defalias`/`define-obsolete-function-alias` was added.

`supertag-menu.el`: **+0 / -5**.  The `supertag-menu--toggle-svg-tags`
wrapper, its `declare-function supertag-toggle-tag-style`, and the
`("t" "Toggle SVG tags" ...)` row are removed.  The `["Display" ...]` group
keeps `("c" "Toggle concept links" ...)`, so it is neither empty nor holding a
stale `t` key.

`test/svg-tag-test.el`: **-345 lines** (the whole file) plus the `svg-tag`
suite removed from both places in `test/renovation-suites.el` (the default
suite list, and the `("svg-tag" ("test/svg-tag-test.el" . t))` definition).

## The two faces as they now read

```elisp
(defcustom supertag-view-style-tag-face-properties
  '(:underline t)
  "Face properties for inline supertags.
Default properties of `supertag-inline-face': a tag the system knows is
underlined and inherits its colour from the active theme.  Set `:foreground'
or `:inherit' here to pin a colour instead."
  :type '(plist :key-type symbol :value-type sexp)
  :group 'supertag-view-style)

(defcustom supertag-view-style-unresolved-tag-face-properties
  '(:inherit shadow)
  "Face properties for inline tag tokens with no registered tag.
Default properties of `supertag-unresolved-tag-face': a token the system does
not know is dimmed, not underlined.  The underline marks a tag that resolves
to a registered Semantic Tag."
  :type '(plist :key-type symbol :value-type sexp)
  :group 'supertag-view-style)
```

Both are still `defcustom`s, so the look can be changed without editing code.
Measured in a fresh batch Emacs after loading `supertag-tag` and
`supertag-menu` (raw output):

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

`supertag-view-style-mode` now documents exactly this split, and
`supertag-view-helper--get-font-lock-keywords` returns the face keywords with
no branch left.

## Matching was not touched

`git show e422b83 -- supertag-tag.el | grep '^-'   | grep -c "defun supertag-view-helper--font-lock-matcher \
     |defun supertag-view-helper--inline-tag-range-at \
     |defun supertag-view-helper--matched-tag-face \
     |defun supertag-view-helper--refresh-fontification \
     |defun supertag-view-helper--auto-enable \
     |defun supertag-view-helper--enable-existing-org-buffers"`

prints `0`: none of the matcher, the range-aware token reader, the face
chooser, the refresh helper, the auto-enable hook or the existing-buffer pass
lost a single line.  `git diff e422b83~1 e422b83 -- supertag-tag.el | grep -c
"keyword-line\|terminator"` prints `0` as well, so the keyword-line rule and
the punctuation/tokenizer rules from the two previous tasks are untouched.
The mode, its auto-enable and the Org-buffer enabling path all still work.

## Tests removed and changed

1. `test/svg-tag-test.el` deleted with the feature (13 tests, the whole
   `svg-tag` suite); both manifest entries removed.
2. `test/view-framework-test.el` (+45 / -33):
   - `test-view-style-svg-stops-before-adjacent-org-link` deleted: it asserted
     the `display` image property, which no longer exists.
   - `test-view-style-enables-existing-org-buffers` keeps its contract (a late
     load enables already open Org buffers, never a non-Org buffer); the tail
     that enabled styling, stubbed the image cache and asserted `display` is
     gone.
   - `test-view-style-face-stops-before-adjacent-org-link` keeps its
     assertions; the now-meaningless `(supertag-svg-tag-enable nil)` binding
     is dropped.
   - added `test-view-style-underlines-known-tags-and-dims-unknown-ones`: a
     registered tag is fontified with `supertag-inline-face` (and that face
     carries `:underline t`), an unregistered token with
     `supertag-unresolved-tag-face` (underline `unspecified`), and neither
     carries a `display` property.
   - added `test-view-style-mode-leaves-no-keywords-behind`: the mode installs
     exactly its own keyword element, fontifies a token, and after
     `(supertag-view-style-mode -1)` the keyword element is gone from
     `font-lock-keywords` and the token is no longer styled.
   Nothing was weakened: the suite went 49 -> 50 tests and every removed
   assertion belonged to the deleted image rendering.
3. `test/menu-lazy-test.el` (+1 / -1): the wrapper-count contract
   `(should (= 38 (length wrappers)))` becomes `37` because exactly one
   wrapper was deleted with its command.  The loop that checks every wrapper
   is lazy is unchanged, so the contract still covers all of them.
4. `test/tag-path-hierarchy-test.el` (+3 / -3): four
   `supertag-svg-tag-enable nil` bindings and one
   `(should-not supertag-svg-tag-enable)` inside the embedded child programs
   are removed.  These would have become `void-variable` errors now that the
   option is gone; the neighbouring `supertag-view-style-auto-enable nil`
   bindings stay.
5. `test/migrate-test.el` (+1 / -1): the same inert binding in its child
   program.
6. `test/test-inline-tag-filter.el` (-7): the standalone self-check's block
   that called `supertag-svg-tag--make-svg` and asserted the 14px font is
   removed; the file is not part of the manifest.

## Verification (raw output)

`EMACS_BIN=/tmp/st-bin/emacs bash test/run-tests.sh` -> exit 0, no `FAILED`
line anywhere.  Per-suite raw lines for the suites this task touched:

```
Suite: contract -> Ran 166 tests, 166 results as expected, 0 unexpected
Suite: view-framework -> Ran 50 tests, 50 results as expected, 0 unexpected
Suite: tag-change -> Ran 60 tests, 60 results as expected, 0 unexpected
Suite: tag-path -> Ran 101 tests, 101 results as expected, 0 unexpected
Suite: migrate -> Ran 19 tests, 19 results as expected, 0 unexpected
```

Totals across the run: **34 suites, 1222 tests, 1217 results as expected, 5
skipped, 0 unexpected**.  The manifest shrank by the `svg-tag` suite as the
brief predicted, and the arithmetic is exactly: 1234 tests before - 13
(`svg-tag`) + 1 (`view-framework` 49 -> 50) = 1222.

`bash test/static-gates.sh` -> `Static O gates: PASS` (exit 0); the edited
`;; Dependencies:` header is the one the gate looks for.

## SVG references that remain, and why

`grep -rniI svg --include="*.el" .` outside `archive/` and `doc/` now prints
nothing.  What is left is documentation, all outside the brief's scope, listed
rather than edited:

- `README.md:775-789` and `README_CN.md:706-720` -- a generated options table
  headed `**supertag-view-svg-tag.el**` listing the 11 deleted `defcustom`s.
  That table was already stale before this change: it names a file that does
  not exist, and the options it documents were living in `supertag-tag.el`.
- `MODEL_CN.md:263` -- a dated decision-log entry that recorded keeping SVG tag
  display.  Historical record, not a live reference.
- `COMMANDS-TRIAGE_cn.md:327-330,367-368,470`, `plan_cn_v2.md:271`,
  `PLAN_CN.md` -- planning and command-triage records.
- `doc/report-*.md` (two historical reports) and
  `doc/brief-remove-svg-tags.md` (this brief).
- `archive/**` untouched.

If the coordinator wants the README option tables regenerated, that is a
separate, mechanical follow-up; nothing in the code base refers to the
deleted feature any more.

DONE: doc/report-remove-svg-tags.md
