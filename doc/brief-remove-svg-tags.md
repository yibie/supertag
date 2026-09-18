# Brief: delete SVG tag rendering; inline tags are underlined text

The user's decision: remove the SVG pill-badge rendering entirely and show an
inline tag as underlined text. Delete the code outright — no compatibility
shim, no obsolete alias, no `defvar` kept "just in case". That is this repo's
standing preference for superseded code.

## What to delete

`supertag-tag.el` carries ~121 lines mentioning `svg`. All of it goes:

- `(require 'svg)` (`:64`) and the `svg` entry in the file's
  `;; Dependencies:` header — the static gate checks that header, so update it.
- `supertag-view-svg-tag--font-lock-keywords` (`:1715`).
- The whole `supertag-view-svg-tag` customization group (`:1873`) and its
  ~15 `defcustom`s: `supertag-svg-tag-enable`, `-style`, `-padding-x`,
  `-radius`, `-stroke-width`, `-font-scale`, `-font-family`,
  `-min-column-em`, `-color-alpha` and the rest of that block.
- Colour generation (`--is-light-theme-p`, `--hash-to-index`, `--hsl-color`,
  `--hsl-rgba`, `--neutral-colors`, `--colored-colors`, `--get-colors`).
- The SVG builder and cache (`--char-width`, `--char-height`, `--font-size-px`,
  `--base-font-px`, `--text-pixel-width`, `--default-font-family`,
  `--make-svg`, `--get-cached`, `--clear-cache`, `--match-handler`).
- Theme hooks (`--on-theme-change`, its `enable-theme-functions` hook) and
  `supertag-svg-tag--refresh-all-buffers`, `--enable`, `--disable`, and the
  toggle command `supertag-toggle-tag-style` (`:2235`).
- The file's trailing startup block that calls
  `supertag-svg-tag--refresh-all-buffers`.

`supertag-view-helper--get-font-lock-keywords` (`:1805`) loses its SVG branch
and simply returns the face keywords. Its docstring and
`supertag-view-style-mode`'s (which currently explains the SVG/face choice)
must be rewritten to describe what remains. `supertag-view-style-mode` also
pushes `display` onto `font-lock-extra-managed-props` only for SVG — drop that
if nothing else needs it (check).

Elsewhere:

- `supertag-menu.el:247` `supertag-menu--toggle-svg-tags` wrapper and
  `:298` the `("t" "Toggle SVG tags" …)` menu entry — both go. Check the
  surrounding menu for a now-empty group or a stale key.
- `test/svg-tag-test.el` (345 lines) is deleted, and the `svg-tag` suite is
  removed from both places in `test/renovation-suites.el` (`:7` default list,
  `:25` suite definition).
- `grep -rn svg` across the repo afterwards must come back empty apart from
  unrelated matches; say what is left, if anything.

## The appearance

Registered inline tags get an **underline**.
`supertag-view-style-tag-face-properties` (`:1740`) is currently
`'(:foreground "snow3")` — a hardcoded colour that only suits a dark theme.
Replace it so the face underlines and inherits its colour from the theme rather
than pinning one.

**Unresolved tokens** (`supertag-view-style-unresolved-tag-face-properties`,
`:1842`) are currently `'(:inherit shadow :underline t)`. Drop the underline,
keep `shadow`: underline then means "this is a Tag the system knows", and a
token it does not know is merely dimmed. That keeps the two visually distinct —
which is the whole point of the unresolved face — while reserving the new
decoration for real tags.

Both remain `defcustom`s, so the user can re-style without editing code.

## Keep working

- `supertag-view-style-mode`, its auto-enable, and the existing Org buffer
  enabling path.
- The font-lock matcher and everything that decides what a tag occurrence is —
  this brief changes only how a match is *drawn*, never what matches. The
  recent keyword-line and punctuation rules must be untouched.
- The tag-cards / view pages that use their own faces are unrelated; do not
  touch them.

## Tests

- A registered inline tag is fontified with `supertag-inline-face`, and that
  face carries an underline attribute.
- An unresolved token gets `supertag-unresolved-tag-face` and it is **not**
  underlined.
- Nothing sets a `display` property on a tag any more (the SVG image is gone).
- `supertag-view-style-mode` still toggles cleanly on and off, leaving no
  keywords behind.

Any existing test that asserted SVG behaviour is deleted with the feature; list
what you removed.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
bash test/run-tests.sh          # 35 suites minus svg-tag; currently 1234 tests, 0 unexpected, exit 0
bash test/static-gates.sh       # exit 0 (it checks the ;; Dependencies: header you are editing)
```

The manifest will shrink by the `svg-tag` suite — expected; state the new
totals. Nothing else may regress.

If the local libgccjit trampoline problem appears, use an `EMACS_BIN` wrapper
setting `native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil`.

## Scope

`supertag-tag.el`, `supertag-menu.el`, `test/renovation-suites.el`, deleting
`test/svg-tag-test.el`, plus tests. Never run anything against
`/Users/chenyibin/Documents/notes`. Branch `supertagV2`.

## Reporting

Write `doc/report-remove-svg-tags.md` — what was deleted (with line counts),
the two face definitions as they now read, commit hash, verification with raw
output, and anything you found that referenced SVG indirectly — then end with
`DONE: doc/report-remove-svg-tags.md`.
