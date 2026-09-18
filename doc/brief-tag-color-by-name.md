# Brief: give each inline tag its own colour

The user wants what the SVG badges gave them — a different colour per tag —
now that tags render as underlined text. Decision taken: **the tag text itself
is coloured**, and it keeps the underline.

```
今天试了 #emacs 和 #rust 两个工具
         ▔▔▔▔▔▔    ▔▔▔▔▔
         blue      orange       ← both the glyphs and the underline
```

## On design.md

`design.md` §2 says "Colored foreground text is not part of this system". That
rule governs **view buffers** (Node View, Tag Cards, Stream, Tag Manager, the
new Orphan Tags page) — buffers Supertag draws. An inline tag sits in the
user's own Org file, which Supertag styles but does not own, so it is outside
that system. Say this in a comment next to the face code, so the next reader
does not think the rule was overlooked. Do not change any view page's colours.

## Where the colour comes from

There is **no colour field on Tag entities** — the old SVG code derived colour
by hashing, and that is what to do again (the relevant helpers,
`supertag-svg-tag--hash-to-index`, `--hsl-color`, `--is-light-theme-p`, were
deleted in `e422b83`; re-introduce only what this needs, named for text, not
SVG).

Requirements:

- **Hash the resolved Tag's canonical identity, not the raw token.** Two
  aliases of one Tag must get the same colour; `#emacs` written two ways must
  not look like two tags. Resolve through `supertag-tag-resolve-occurrence`,
  which the matcher already does to pick the face.
- **Stable forever.** The same Tag must get the same colour across sessions,
  machines and store reloads. A pure function of the canonical name — no
  randomness, no dependence on hash-table order or on how many tags exist.
- **Readable on both themes.** Pick the hue from the hash but pin saturation
  and lightness per `(frame-parameter nil 'background-mode)`, so no tag ever
  comes out near-black on a dark background or near-white on a light one. Say
  in your report which bands you chose.
- **Nested tags**: `#emacs/package` resolves to the leaf Tag; colour it by that
  leaf. Do not try to make children inherit a parent's hue — mention it as a
  possible refinement, do not build it.

## Unresolved tokens stay grey

`supertag-unresolved-tag-face` keeps `:inherit shadow`, with no colour and no
underline. The whole point of the scheme is that decoration means "the system
knows this tag": colour + underline = known, dim = unknown. Do not colour a
token the system cannot resolve.

## Performance — read this before writing the matcher

The face is chosen per match, during fontification, for every tag in the
buffer. Computing a hash and an HSL conversion per match, per redisplay, is
exactly the class of bug that cost this project a visible freeze earlier
(`supertag-concept--ignored-org-context-p` re-hashed the whole buffer per
match).

- Cache the computed face per Tag id, in a hash table.
- Invalidate the cache when the theme changes (`enable-theme-functions`), since
  the lightness band depends on `background-mode`. That is the one hook the
  deleted SVG code had that is worth keeping; re-add just it.
- The face may be an anonymous plist (`(:foreground "#…" :underline t)`);
  there is no need for a `defface` per tag.
- Add a test that asserts the colour for one tag is computed once across many
  matches (count calls, not wall-clock).

## Customization

- One `defcustom` to turn per-tag colour off, falling back to the current
  single `supertag-inline-face`. Default on.
- `supertag-view-style-tag-face-properties` stays and still supplies the
  non-colour attributes (the underline). The generated colour is merged over
  it, so a user who sets `:weight bold` there keeps it.

## Do not touch

Matching rules. This brief changes only how a match is drawn. The keyword-line
rule and the punctuation tokenisation from this week stay exactly as they are.
View pages and their palettes are unrelated.

## Tests

- Same Tag → same colour on repeated calls and after a store reload;
- two different Tags → different colours (assert on a handful of names, not a
  universal guarantee);
- an alias and the canonical name of one Tag → the same colour;
- unresolved token → `shadow`, no colour, no underline;
- the colour respects the light/dark band (assert the computed lightness falls
  in the expected range for each `background-mode`);
- the per-tag face is computed once for many matches;
- with the `defcustom` off, every tag gets the plain face.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
bash test/run-tests.sh          # 34 suites / 1222 tests, currently 0 unexpected, exit 0
bash test/static-gates.sh       # exit 0
```

Nothing may regress. If the local libgccjit trampoline problem appears, use an
`EMACS_BIN` wrapper setting
`native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil`.

In your report, include a small table of ten real-ish tag names with the hex
colour each gets under a dark and a light background, so the palette can be
eyeballed as text.

## Scope

`supertag-tag.el` and tests. Never run anything against
`/Users/chenyibin/Documents/notes`. Branch `supertagV2`.

## Reporting

Write `doc/report-tag-color-by-name.md` — the derivation, the chosen bands, the
colour table, the cache design, commit hash and verification with raw output —
then end with `DONE: doc/report-tag-color-by-name.md`.
