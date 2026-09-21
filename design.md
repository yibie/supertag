# Supertag view design: terminal editorial

Every Supertag view buffer (Node View, Tag Cards, Stream, Tag Manager, and
any future view) is a page of the same dark terminal magazine. The
reference is a "ORBIT / CREATIVE OS" style UI: near-black ground, three
accent colors used as filled blocks, one monospace size, uppercase
slash-separated labels, ornament built from characters. This file is the
single source of truth for how a view looks. Data rules for views
(read-only, org-native, system proposes) live elsewhere; this file is only
about form.

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
3. **Whitespace**: one blank line between a card's three parts, one blank
   line between cards, two before the footer. Padding inside a fill is one
   space on each side.
4. **Position**: identity top-left, live status top-right, colophon at the
   bottom. Position carries meaning; keep it constant across views.

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
| mute | `supertag-view-mute` | metadata | parent chain, dates, colophon |
| rule | `supertag-view-rule` | ornament | `+ . + .` rules |

Palettes are chosen per view. Node View uses `paper` (the warm palette);
Tag Cards uses `neon` (lime, lavender, pale cyan). All palettes live in
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

Box-drawing borders around cards are not used. Cards are separated by
whitespace and by their filled title.

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

## 6. Card template

Every card is a self-contained small page with three parts separated by
one blank line:

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

- Render the page to text at width 120 and width 80; no line exceeds the
  width and narrow widths drop columns instead of overflowing.
- One font size; every emphasis is a fill, case, or whitespace.
- Every fill is a label or title; every action is a `[ ]` button.
- Masthead and colophon present; manifesto present or deliberately
  omitted for panes that are too small (the Node View side pane may skip
  the manifesto).
- Open the page in GUI Emacs with CJK content and confirm column
  alignment, which batch rendering cannot verify.
