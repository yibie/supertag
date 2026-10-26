# Supertag view design: terminal editorial

Every Supertag view buffer (Node View, Stream, Summary, Tag Manager, and
any future view) is a page of the same dark terminal magazine. The
reference is a "ORBIT / CREATIVE OS" style UI: near-black ground, three
accent colors used as filled blocks, one monospace size, uppercase
slash-separated labels, ornament built from characters. This file is the
single source of truth for how a view looks. Data rules for views
(read-only, org-native, system proposes) live elsewhere; this file is only
about form. Summary panels, whose layout a model writes and which can act
on entries, follow this file for form and `summary.md` for everything else.

## 1. One size, hierarchy by contrast

All text is one font size, with one user-chosen exception: the Node View
title keeps its larger `supertag-view-title` face (`:height 1.4`) on the
panel, showing the full title as written. Everywhere else, never use
`:height` in a view face. Rank information with these four levers, in this
order of strength:

1. **Fill**: text on an accent background. Reserved for identity and
   titles (a card's tag, a section label, the masthead brand).
2. **Case**: labels and titles are UPPERCASE; body and entries are
   sentence case.
3. **Whitespace**: one blank line between a card's three parts, three
   blank lines between rows of cards, two before the footer. The gap
   between objects is always wider than any gap inside one. Padding inside
   a fill is one space on each side.
4. **Position**: identity top-left, live status top-right, colophon at the
   bottom. Position carries meaning; keep it constant across views.

These levers rank. They do not tell one kind of object from another. A
self-contained object sits on its own surface: the `surface` background
under every line it occupies. A surface is a background, never a line drawn
around the object. Its color is not chosen by a palette: it is the theme's
background with its lightness moved by `supertag-view-surface-offset`
(5 percent), lighter on a dark theme and darker on a light one, so it suits
whatever theme is loaded. What counts as one object:

- Tag Cards (local and unreleased): a card.
- Stream: a group, from its label to its last line. The label keeps its
  fill; the selected note's background ranks above the surface.
- Summary: whatever the model draws as one card or group. The prompt asks
  the model to put each in a `:flex` with `:surface t :padding 1`; Supertag
  turns `:surface t` into TextUI's `:face supertag-view-surface`.

## 2. Color is area, not ink

The ground is neutral and dark; accents are surfaces. Foreground text is
either the ground's light text color or dark text on a fill. Colored
foreground text is not part of this system.

| Role | Face | Meaning | Typical use |
|---|---|---|---|
| chip1 (lime) | `supertag-view-chip1` | live, current, primary | card title, masthead brand, the active group |
| chip2 (lavender) | `supertag-view-chip2` | structure, container | section labels, second group family |
| chip3 (pale cyan) | `supertag-view-chip3` | information, tertiary | counts, third group family, status |
| panel | `supertag-view-panel` | quiet surface | masthead block, manifesto block |
| surface | `supertag-view-surface` | one object | card, Stream group (computed, section 1) |
| mute | `supertag-view-mute` | metadata | parent chain, dates, colophon |
| rule | `supertag-view-rule` | ornament | `+ . + .` rules |

Palettes are chosen per view. Node View uses `paper` (the warm palette);
Tag Cards (local and unreleased) uses `neon` (lime, lavender, pale cyan). All palettes live in
`supertag-view-framework.el`, keep the same role structure, and are applied
per buffer, so two views can show different palettes at the same time. Rotate chip1/chip2/chip3 across groups so
siblings share a color and neighbors differ.

## 3. Label grammar

Every label is `NOUN / NOUN` or `NOUN / 007`. The slash, with one space on
each side, is the only separator. Numbers are editorial (VOL., EDITION,
FIELD, 01) and pad to a fixed width when they sit in a series. Examples:

```
SUPERTAG / TAGS        VOL. 45 / 673 NOTES        COMPOSITION / LIVE
DIARY / IDEA           FIELD / 104                OBJECT 01 / EDITION 007
```

Tag hierarchy renders through this grammar: `DIARY / IDEA`, never
`diary › idea` inside a fill. The ` › ` chain is allowed only in muted
metadata lines.

## 4. Ornament from the character set

All decoration is text so it survives any monospace terminal:

- Section and footer rule: `+ . + . + . + . + . + .`
- Ruler for a field: `00 04 08 12 16 20` down the left margin when the
  field has vertical extent worth measuring.
- Bars and ratios: `03:42 ====---- 05:18`.
- Markers: `+` before a co-occurring facet, `→` before a note entry.

Box-drawing borders around cards are not used by default. Each card sits on
its surface, and rows of cards are separated by whitespace.

**Discovery exception (user preference):** retain its bordered reading cards,
with title, file/tags and complete body in distinct sections. Preserve title
case and use `[ ]` / `[X]` for marks; a selected-card background is allowed.
TextUI is the layout backend, not a reason to replace this reading interface.
Discovery uses a compact title, result/mark counts and actions instead of the
magazine manifesto and decorative colophon. The shared one-size, responsive
width and native-button requirements still apply.

## 5. Page skeleton

Every view renders these five bands in this order. A band with nothing to
say is omitted, never left as an empty gap.

1. **Masthead**: brand fill on the left (`SUPERTAG / NODE`), volume or
   count in the middle (`VOL. 45 / 673 NOTES`), live status fill on the
   right (`COMPOSITION / LIVE`, `PALETTE / NEON`). Node View keeps its
   earlier masthead: tag chips, then file name and date, above the large
   title panel; the user prefers that presentation of the node itself.
2. **Manifesto**: two short uppercase lines that state what this page is
   for, then one or two sentence-case lines of explanation. Declarative,
   short, no key help. Example: `MAKE ROOM / FOR THE UNEXPECTED.` over
   `A desk of intersecting ideas. Pull it apart. Shift the focus.`
3. **Action row**: traditional widget buttons side by side, `[ RESET ]`
   `[ ALL TAGS ]`. Actions are never fills; fills are never actions.
4. **Field**: the body. Cards, entries, sections.
5. **Colophon**: rule, then one muted line `01 / TAG FIELD  absolute
   counts + live store`, then the brand line.

### Width follows the window

A view lays out to the width of the window that shows it, and lays out
again when that width changes. Cards and groups sit side by side only in
a grid whose column count drops as the window narrows, down to one
column; a fixed horizontal row of cards or groups is not used, because it
runs past the right edge of a narrow window. Every width inside the
field, of a column or of a single-line element, is computed from the
window width, never written as a constant. When the window is narrower
than one column's minimum, objects stack vertically instead of
overflowing.

## 6. Card template

Every card is a self-contained small page with three parts separated by
one blank line. The whole card is one surface, including those
blank lines and one blank line at its bottom. Cards in the same grid row
are the same height, so their surfaces end on the same line:

```
diary                                  ← muted parent chain, or blank line
DIARY / IDEA                     104   ← fill on the title; count in chip3
+ DONE  4                              ← facets, `+` marker
+ emacs  2

→ Emacs 配置：一键切换字体              ← entries, `→` marker
→ 将网页高亮注释，转换成剪报
```

Labels are truncated with `…` to the card's content width; a card never
widens its grid track. Empty cards (count 0) are omitted from the field
and, if worth showing, listed on one muted line.

## 7. Buttons and interaction

Clickable actions look like classic Emacs text buttons in the
`widget-button` face, `[ OPEN ]` style. Entry rows (`→ title`) and facet
rows (`+ label  N`) are bracket-free link buttons in the same face. TAB
and S-TAB move among buttons; RET and mouse-1 activate. Modal editing
(meow, evil) is disabled locally in every view.

## 8. Checks before shipping a view

- Render the page to text at width 120 and width 80, and once at a
  half-screen width such as 60; no line exceeds the width and narrow
  widths drop columns instead of overflowing.
- In a GUI frame at both widths, every surface has a straight right edge,
  including rows with CJK text, and cards in one row end on the same line.
- One font size; every emphasis is a fill, case, or whitespace.
- Every fill is a label or title; every action is a `[ ]` button.
- Masthead and colophon present; manifesto present or deliberately
  omitted for panes that are too small (the Node View side pane may skip
  the manifesto).
- Open the page in GUI Emacs with CJK content and confirm column
  alignment, which batch rendering cannot verify.
