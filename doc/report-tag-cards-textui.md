# Tag Cards TextUI prototype report

## Delivered

- `supertag-view-tag-cards.el` adds a read-only `M-x supertag-view-tag-cards`
  TextUI page.  It holds `:filter`, `:group`, and `:limit-nodes` in
  `textui-state`; calculates tag/TODO/link facets directly from the Store;
  renders the required responsive three-column card grid; and subscribes to
  tag/node Store changes with a registered cleanup.
- `test/tag-cards-test.el` covers pure facet counts (including repeated
  relation records from one source) and inherited-tag intersection narrowing.
- No existing Supertag source files were changed and no commit was made.

## Round 1 benchmark baseline (superseded by Round 2 timings below)

This read the current vault database **without claiming presence or writing to
it**, seeded a 120-column TextUI buffer, and used `benchmark-run` for five
complete calls to `supertag-view-tag-cards--frame`.  Each call recomputes all
card sets and element plists; there is no cross-render cache.

```text
tag-cards cards=45
tag-cards frame construction: 73.728 ms/render (5 runs)
tag-cards full TextUI refresh: 250.527 ms/render (5 runs); tags=45 nodes=1806
```

**Round 1 baseline: 73.728 ms/render** for the complete page render function
on 45 tags and 1,806 nodes.  The Round 2 numbers below supersede this sample:
they use the revised unboxed grid and also report full refresh timing.

## TextUI finding

TextUI requires `:layout :focus-id` values to be unique across the entire
frame, not merely within a card.  During the live-vault render, a node that
appeared on multiple cards made this element shape fail:

```elisp
(:type supertag-view-tag-cards-button
 :value "→ …"
 :layout (:focus-id (node "NODE-ID")))
```

with `Duplicate focus ID: (node "NODE-ID")`.  The prototype now scopes node
anchors by their card facet, e.g. `(:focus-id (node (tag . "TAG-ID")
"NODE-ID"))`, so point restoration and TAB navigation remain available.  No
remaining TextUI element plist fails to render.  Batch buffers also have no
window width by default, so the benchmark explicitly seeds
`textui--last-width` to 120; normal `textui-open` obtains this from its display
window.

## Resolved ambiguities

- A selected favorite group displays its **strict descendants**; its root tag
  stays available in the all-tags grid.  This follows “restricts the grid to
  that group's descendants”.
- A tag filter matches nodes carrying that tag or any descendant tag, matching
  the project convention used by `supertag-find-nodes-by-tag TAG t`.
- A link facet count means distinct source nodes.  Multiple equivalent relation
  records from one node count once, which gives “referenced by only one node”
  its literal meaning.

## Verification output

### Load

```sh
emacs -Q --batch -L . -L /Users/chenyibin/Documents/emacs/package/textui \
  -l supertag-view-tag-cards.el
```

```text
(exit 0; no output)
```

### Byte compiler

```sh
emacs -Q --batch -L . -L /Users/chenyibin/Documents/emacs/package/textui \
  --eval '(byte-compile-file "supertag-view-tag-cards.el")'
```

```text
(exit 0; no warnings)
```

### ERT

```sh
emacs -Q --batch -L . -L test \
  -L /Users/chenyibin/Documents/emacs/package/textui \
  -L "$HOME/.emacs.d/elpa/ht-20230703.558" \
  -L "$HOME/.emacs.d/elpa/dash-20260221.1346" \
  -l test/tag-cards-test.el -f ert-run-tests-batch-and-exit
```

```text
[supertag] org-id-find integration enabled
supertag-node.el: Warning: ‘when-let’ is an obsolete macro (as of 31.1); use ‘when-let*’ or ‘and-let*’ instead. (6 existing warnings)
supertag-tag.el: Warning: ‘when-let’ is an obsolete macro (as of 31.1); use ‘when-let*’ or ‘and-let*’ instead. (3 existing warnings)
Running 2 tests (2026-09-12 09:20:19-0700, selector ‘t’)
   passed  1/2  supertag-tag-cards-counts-tag-todo-and-repeated-link-facets (0.001504 sec)
   passed  2/2  supertag-tag-cards-narrows-filters-by-intersection (0.000210 sec)

Ran 2 tests, 2 results as expected, 0 unexpected (2026-09-12 09:20:19-0700, 0.001858 sec)
```

## Round 2 review fixes

The repeatable live-vault renderer is `scripts/tag-cards-render.el`.  It sets
`supertag-data-directory` to `/private/tmp/supertag-tag-cards-render-data/`,
sets `supertag-presence-enable` to nil, and calls
`(supertag-load-store "/Users/chenyibin/Documents/notes/.supertag/supertag-db.el")`
explicitly.  It never invokes a save command.  It writes these checked text
renders:

- `/private/tmp/supertag-tag-cards-all.txt`
- `/private/tmp/supertag-tag-cards-diary-idea.txt`

The rendered 1,806-node vault has this tags-per-node histogram:

```text
0 tags: 1133 nodes
1 tag:   659 nodes
2 tags:   14 nodes
```

### Review changes

1. Header controls and Favorite groups are each a `:flex` row with `:gap 2`,
   so `[×]`, `[RESET]`, `[ ALL TAGS ]`, and favorite-group controls stay
   horizontal until the available width requires them to wrap.
2. All facet, title, parent-chain, and node labels are whitespace-normalized
   and limited to their responsive card track budget with `…`.  The budget is
   recomputed from the current width and column count before native widgets
   are built.
3. Facet and node rows use `supertag-view-tag-cards-link`, a widget.el `link`
   derivative.  Its `:textui-measure`, creation, and attach functions all use
   exactly the unbracketed label.  Thus those rows remain `widget-button`
   faced, TAB/RET/mouse actionable TextUI controls without `[ … ]`; brackets
   remain on only the page controls and group controls.
4. Both `r`/`RESET` and `[ ALL TAGS ]` clear `:filter` and `:group`.
5. The data-only `supertag-view-tag-cards--filtered-card-records` removes
   count-one drill-down cards whenever any repeated continuation exists; it
   retains the singleton set if dropping it would make the grid empty.  ERT
   exercises both cases.
6. Cards now use no `:border` or `:padding`.  Responsive one-row grids have
   `:gap 3` for whitespace between tracks and are stacked with one blank line
   between card rows.  `truncate-lines` is buffer-local and true in the mode.

The custom link widget worked with TextUI; no new framework limitation or
failing element plist was encountered.  The Round 1 focus-ID requirement
remains applicable: node focus IDs are scoped by their containing card so a
node shown on multiple cards does not duplicate a frame-wide focus ID.

### Live-vault timing and width checks

Timing uses three post-warm-up `benchmark-run` iterations at 120 columns.
Frame construction recomputes the Store-derived page; refresh additionally
materializes and commits the TextUI widget buffer.

```text
TAG-CARDS histogram=((0 . 1133) (1 . 659) (2 . 14))
TAG-CARDS all width=120 max-line=120 frame=83.419ms refresh=138.300ms file=/private/tmp/supertag-tag-cards-all.txt
TAG-CARDS drill width=120 max-line=120 frame=47.388ms refresh=45.078ms file=/private/tmp/supertag-tag-cards-diary-idea.txt
TAG-CARDS width=80 max-line=80
```

Therefore the **maximum rendered display-line length at width 120 is exactly
120 columns** (for both pages); at width 80 it is exactly 80 columns and the
grid drops to two columns.  Full refresh timing is **138.300 ms/render** for
All Tags and **45.078 ms/render** for the `(tag . "diary")` + `(tag . "idea")`
drill-down.

### Round 2 verification output

#### Load and byte compiler

```sh
emacs -Q --batch -L . -L /Users/chenyibin/Documents/emacs/package/textui \
  -l supertag-view-tag-cards.el
emacs -Q --batch -L . -L /Users/chenyibin/Documents/emacs/package/textui \
  --eval '(byte-compile-file "supertag-view-tag-cards.el")'
```

```text
Both commands exited 0 with no output or compiler warnings.
```

#### ERT

```sh
emacs -Q --batch -L . -L test \
  -L /Users/chenyibin/Documents/emacs/package/textui \
  -L "$HOME/.emacs.d/elpa/ht-20230703.558" \
  -L "$HOME/.emacs.d/elpa/dash-20260221.1346" \
  -l test/tag-cards-test.el -f ert-run-tests-batch-and-exit
```

```text
[supertag] org-id-find integration enabled
supertag-node.el: Warning: ‘when-let’ is an obsolete macro (six existing warnings)
supertag-tag.el: Warning: ‘when-let’ is an obsolete macro (three existing warnings)
Running 5 tests (2026-09-12 09:32:48-0700, selector ‘t’)
   passed  1/5  supertag-tag-cards-counts-tag-todo-and-repeated-link-facets
   passed  2/5  supertag-tag-cards-drill-down-hides-singleton-continuations
   passed  3/5  supertag-tag-cards-drill-down-keeps-singletons-as-empty-grid-fallback
   passed  4/5  supertag-tag-cards-label-budgets-follow-responsive-tracks
   passed  5/5  supertag-tag-cards-narrows-filters-by-intersection

Ran 5 tests, 5 results as expected, 0 unexpected (0.002111 sec)
```

## Round 3: terminal editorial alignment

`design.md` is now the visual source of truth for this view.  Tag Cards has
all five page bands: a three-cell masthead, full-width panel manifesto,
traditional action row, card field, and editorial colophon.  The masthead
keeps the whole-Store volume stable while the right chip reports the active
filter chain.  The action row is `[ ALL TAGS ]`, `[ RESET ]`, then the group
buttons.

Cards use a padded whole-track title fill with the count right-aligned inside
it.  Chip faces rotate by root tag group (siblings share a face; ungrouped
tags use chip2).  Bare tag identities receive the `TAG / NAME` form, while
hierarchies receive `PARENT / CHILD`; this keeps every fill in the editorial
noun/slash/noun grammar.  Tag facets use the same uppercase slash grammar,
while `›` is confined to muted parent metadata and the muted `EMPTY / NN`
line.  Tag, TODO, and link facets have `+`, `◆`, and `↗` respectively, with
counts aligned at the right edge of the same bracket-free link widget.
Zero-count tag families are omitted from the grid and listed below it.

The render script now checks face-bearing fills directly.  A stock TextUI
`item` drops text properties while measuring, so Tag Cards uses a tiny derived
static item with `:textui-measure` returning the attributed value.  That keeps
face properties in both `textui--render-frame` output and materialized view
buffers.  All fill helpers first use `truncate-string-to-width` and
`string-width`; the pure ERT case includes a CJK title and confirms the exact
column width.  No special `:text` leaf is needed.  At 120 columns all card
tracks are 38; at 80 TextUI's equal-share remainder yields 39 and 38, and the
cards receive the corresponding exact width before their fills are built.

### Round 3 live render and timing

The current live vault changed during the task: it rendered as 45 tags, 674
tagged nodes, and a tags-per-node histogram of 1133/659/15 for 0/1/2 tags.
The repeatable private-directory loader wrote no live Store data.

```text
TAG-CARDS fills width=120 card-tracks=(38 38 38) masthead=(39 38) faces=preserved
TAG-CARDS fills width=80 card-tracks=(39 38) masthead=(26 25) faces=preserved
TAG-CARDS histogram=((0 . 1133) (1 . 659) (2 . 15))
TAG-CARDS all width=120 max-line=120 frame=102.735ms refresh=171.643ms file=/private/tmp/supertag-tag-cards-all.txt
TAG-CARDS drill width=120 max-line=120 frame=55.881ms refresh=53.701ms file=/private/tmp/supertag-tag-cards-diary-idea.txt
TAG-CARDS width=80 max-line=80
```

Thus the maximum display-line width is **120 columns at width 120**, and 80
columns at width 80.  Refresh timing (three post-warm-up runs) is 171.643 ms
for All Tags and 53.701 ms for the diary/idea drill-down.

### All Tags text render: first 40 lines at width 120

```text
 SUPERTAG / TAGS                         VOL. 45 / 674 NOTES                       COMPOSITION / LIVE                   
                                                                                                                        
MAKE ROOM                                                                                                               
FOR THE UNEXPECTED.                                                                                                     
Tags are fuel. The connections are computed for you: click any + row to narrow.                                         
                                                                                                                        
[ ALL TAGS ]  [ RESET ]  [ CONTACT ]  [ DIARY ]  [ MEDIA ]  [ NOTE ]  [ NOTE / REF ]  [ PRJ ]  [ PRJ / TASK ]           
                                                                                                                        
                                                                                  contact                               
 TAG / COMPANY                      7     TAG / CONTACT                     26     CONTACT / FAMILY                   3 
                                                                                                                        
→ ANYCOLOR / COVER                       + CONTACT / FRIEND                  19   ↗ 什么是 LSP 协议？                  2
→ Facebook                               ↗ 签字汪炜提供的合同解除书           4                                         
→ Andreessen Horowitz（a16z）            + CONTACT / FAMILY                   3   → 姑姑                                
→ [2025-03-21 Fri 21:30]创始人宣布成…    ↗ 那些与亲朋好友一起做的事           3   → 老妈                                
→ Vercel                                 ↗ [2025-09-08 Mon 16:19] 很郁闷，其… 2   → 老爸                                
                                         ↗ [2025-10-28 Tue 08:30] 要去镇上的… 2                                         
                                                                                                                        
                                         → iSouthRain                                                                   
                                         → OwenYang                                                                     
                                         → #contact                                                                     
                                         → MJ                                                                           
                                         → 施宏斌                                                                       
                                                                                                                        
contact                                  contact                                                                        
 CONTACT / FRIEND                  19     CONTACT / PARTNER                  2     TAG / DIARY                      240 
                                                                                                                        
↗ 签字汪炜提供的合同解除书           3   → 阿聪                                   + DIARY / IDEA                     104
↗ [2025-11-05 Wed 22:35] 昨天下午和… 2   → 陈建聪                                 + DIARY / HAPPY                     39
↗ 那些与亲朋好友一起做的事           2                                            + DIARY / THINK                     36
                                                                                  + DIARY / NEW                       17
→ iSouthRain                                                                      + DIARY / RECORD                    15
→ OwenYang                                                                        + DIARY / EXP                       14
→ MJ                                                                                                                    
→ 施宏斌                                                                          → Emacs 配置：一键切换字体            
→ 黄杰敏                                                                          → 将网页高亮注释，转换成剪报          
                                                                                  → 将 SPEC-AGENTS 项目归档了           
                                                                                  → 可以让 Zed 的 zeta2 模型，用在本地… 
                                                                                  → 安伯尼可这类游戏机可以作为桌面 AI … 
                                                                                                                        
```

### Diary / idea drill-down text render: first 40 lines at width 120

```text
 SUPERTAG / TAGS                         VOL. 45 / 674 NOTES                       DIARY / IDEA                         
                                                                                                                        
MAKE ROOM                                                                                                               
FOR THE UNEXPECTED.                                                                                                     
Tags are fuel. The connections are computed for you: click any + row to narrow.                                         
                                                                                                                        
[ ALL TAGS ]  [ RESET ]  [ CONTACT ]  [ DIARY ]  [ MEDIA ]  [ NOTE ]  [ NOTE / REF ]  [ PRJ ]  [ PRJ / TASK ]           
                                                                                                                        
                                                                                                                        
 TODO / DONE                        4     TAG / EMACS                        2     LINK / ORG-SUPERTAG                2 
                                                                                                                        
→ 文件级别 tag                           → Emacs 配置：一键切换字体               → 让窗口可以临时 Zoom in/Zoom out     
→ 升级 org-zettel-ref-mode 的格式转换…   → AI 管家                                → org-supertag 的标签支持嵌套标签     
→ 将 pdf-craft 集成到 convert-to-org.…                                                                                  
→ 将书信体作为博客输出主要体裁                                                                                          
                                                                                                                        
                                                                                                                        
+ . + . + .                                                                                                             
01 / TAG FIELD   live store, recomputed on every refresh                                                                
SUPERTAG / TAGS                                                                                                         
```

### Round 3 verification output

```text
Load:        exit 0, no output
Byte compile: supertag-view-tag-cards.el and scripts/tag-cards-render.el exit 0,
              no warnings
ERT:         8 tests, 8 expected, 0 unexpected
```

The ERT additions cover slash-label/marker grammar, redundant ancestor-filter
presentation, exact CJK fill width and face coverage, exact 120/80 track
allocation, and root-group chip-face sharing.

## Round 4: GUI fills and CJK-safe tracks

### Materialized fills

The Round 3 custom static item only changed TextUI measurement.  That made the
attributed value survive `textui--render-frame`, but it did **not** make the
widget a TextUI-attached widget.  During buffer materialization,
`textui--materialize-placeholders` therefore followed its ordinary no-attach
branch: it deleted the face-bearing placeholder and invoked `item`'s normal
creator.  The replacement was the source of the missing GUI fills.

`supertag-view-tag-cards-item` now has `:textui-attach`
(`supertag-view-tag-cards--item-attach`).  It leaves the measured text in
place, installs the required widget markers and delete function, and copies
face runs from `:value` defensively after attachment.  Thus the rendered
placeholder and the materialized buffer use the same full-width chip/panel
faces.  The ERT test opens the real Tag Cards buffer with `textui-open`, then
checks `get-text-property` on both the masthead `SUPERTAG / TAGS` cell
(`supertag-view-chip1`) and the `TAG / PROJECT` card fill
(`supertag-view-chip2`); it also starts with visual-line enabled and verifies
the post-open no-wrap state.

### GUI wrapping guard and pixel budget

The derived mode and the entry command now enforce, including immediately
after `textui-open`, all of:

```elisp
truncate-lines t
word-wrap nil
(visual-line-mode -1)
```

Label fitting remains deterministic in a batch/text render (`string-width`),
but a visible graphical Tag Cards buffer performs a second pass with
`string-pixel-width`.  It shortens a label with `…` until the measured pixels
fit its column-derived track after subtracting the actual marker and count:
`+ ` / `◆ ` / `↗ ` plus a facet count, or `→ ` for a node title.  Masthead and
card fills apply the same limit after reserving their leading/trailing spaces
and, for card titles, the count.  Padding is still added in character cells,
but stops before a further space would exceed the pixel track; a wide-CJK row
can consequently finish slightly short instead of wrapping.

The exact layout constants used are a 3-cell grid gap, 34-cell minimum card
width, and two 2-cell masthead gaps.  At the renderer's 120 columns this
means three 38-column card tracks and masthead cells `(39 39 38)`; at 80 it
means card tracks `(39 38)` and masthead cells `(26 25 25)`.  For the reported
approximately 130-column GUI window, the same calculation is 124 usable grid
columns, hence card tracks `(42 41 41)`, and 126 usable masthead columns,
hence `(42 42 42)`.  There is intentionally **no assumed fixed pixel
number**: a track cap is exactly `track-columns * (frame-char-width)` for the
actual displayed frame.  Marker, count, title, and padding reservations are
measured with that same frame's `string-pixel-width`, so the font's real CJK
advance rather than an assumed “two cells” decides the final truncation.

For TextUI to lay out this itself rather than letting this view guard labels,
it would need to supply the target window/frame and its font metrics during
measurement, accept intrinsic/preferred pixel widths for native widgets, and
perform flex/grid track allocation and wrapping against pixel widths.  Its
current public layout contract supplies only column widths, so a column-exact
CJK string can still be pixel-too-wide in a particular GUI font.

### Round 4 verification

The repeatable renderer still uses the private data directory and only reads
the live vault.  Its batch fallback retains exact column fills and no line
exceeds the requested width:

```text
TAG-CARDS fills width=120 card-tracks=(38 38 38) masthead=(39 38) faces=preserved
TAG-CARDS fills width=80 card-tracks=(39 38) masthead=(26 25) faces=preserved
TAG-CARDS histogram=((0 . 1133) (1 . 659) (2 . 15))
TAG-CARDS all width=120 max-line=120 frame=101.614ms refresh=173.466ms file=/private/tmp/supertag-tag-cards-all.txt
TAG-CARDS drill width=120 max-line=120 frame=56.275ms refresh=54.207ms file=/private/tmp/supertag-tag-cards-diary-idea.txt
TAG-CARDS width=80 max-line=80
```

```text
Byte compile: supertag-view-tag-cards.el and scripts/tag-cards-render.el: exit 0, no local warnings
ERT:          9 tests, 9 expected, 0 unexpected
```

## Round 5: locally composed pixel-aligned card rows

No TextUI source was changed.  The card field no longer uses a nested TextUI
`:grid`: each responsive visual row (three cards at 120 columns, two at 80,
or one when necessary) is one **top-level attached block** of the package's
own `supertag-view-tag-cards-card-row-block` type.  This uses only TextUI's
public block-widget protocol: `:textui-layout` returns the precomposed
multiline string and `:textui-attach` installs marker bounds and its delete
function without changing the plain text.

The block builds every card line locally.  It starts every card and gap from
the measured complete prefix, pads to the exact column-derived pixel target
with Variant C (whole normal spaces plus one residual
`(space :width (N))` display spacer), and repeats that at the title/count
boundary and the card's right edge.  Batch and terminal buffers use ordinary
column spaces.  Labels are truncated before padding with the existing pixel
budget helpers; title-fill residual spacers receive the chip face, so the
background reaches the local card edge instead of stopping at the last glyph.
Each row is made equal height with locally generated blank card lines.

Facet and node rows are now `make-text-button` ranges created in the block's
attachment callback.  The precomposed string transports a private action text
property because TextUI converts a fresh widget for materialization and hence
does not retain layout-time widget-local span data.  These buttons remain
mouse/RET actionable; `TAB` and `S-TAB` now call `forward-button` and
`backward-button`, respectively.  The trade-off is that these embedded text
buttons do not participate in TextUI's widget `:focus-id` reconciliation;
TextUI still performs the full redraw on resize, but focus restoration for
those rows falls back to ordinary buffer position rather than a row-button
identity.

`M-x supertag-view-tag-cards-measure` writes
`*Supertag Tag Cards Measurement*`.  In a GUI it lists every card's right-edge
x for every logical line using `window-text-pixel-size`, then emits one
`PASS` per card only when the maximum line-to-line edge spread is at most 1px.
Its terminal result is explicitly marked `COLUMN-ONLY`; the GUI user can run
the command after choosing their final font/window and paste its report.

The render script now scans the package-owned card-span property as well as
fills.  In batch it verified 513 local card spans at 120 and 478 at 80; every
span occupied its exact responsive column track and no line exceeded the
requested width.

```text
TAG-CARDS fills width=120 card-tracks=(38 38 38) masthead=(39 38) faces=preserved
TAG-CARDS fills width=80 card-tracks=(39 38) masthead=(26 25) faces=preserved
TAG-CARDS local-tracks width=120 spans=513; width=80 spans=478
TAG-CARDS histogram=((0 . 1133) (1 . 659) (2 . 15))
TAG-CARDS all width=120 max-line=120 frame=106.151ms refresh=132.298ms file=/private/tmp/supertag-tag-cards-all.txt
TAG-CARDS drill width=120 max-line=120 frame=88.306ms refresh=90.349ms file=/private/tmp/supertag-tag-cards-diary-idea.txt
TAG-CARDS width=80 max-line=80
```

ERT now includes batch column-track coverage, materialized `make-text-button`
coverage, and the `COLUMN-ONLY` measurement command.  The suite completed
**11 expected, 0 unexpected**.  Byte-compiling Tag Cards and its renderer
completed with no task-local warnings (the test load still reports the
pre-existing `when-let` deprecation warnings from core files).

## Round 6: full-prefix pixel fitting for truncated card rows

The isolated-label pixel pass was the remaining first-card-only path.  It
could accept a label after measuring just that label, even though the actual
card line also contained the marker, the previously composed line prefix, and
for facets the count column.  The inter-card gap then made cards two and three
look correct while card one extended by a cell.

`supertag-view-tag-cards--fit-label-to-target` now takes the full prefix, a
required suffix, and an absolute card edge.  In a GUI it first measures the
complete untruncated line; when it must shorten a label, every candidate is
constructed as `PREFIX + candidate + … + SUFFIX` and is accepted only when
its measured width is at most the edge.  It never starts from a
column-truncated ellipsis estimate.  Card titles, facet rows, node rows, and
muted parent lines all use this same full-prefix fitter.

Facet and title composition now reserves and inserts an explicit literal
space before the right-aligned count.  The fitter includes that space and the
count in its candidate suffix, so a title or facet is shortened further rather
than allowing `…4` or equivalent glued output.

The new batch-safe ERT regression uses a fake font with 7px ASCII cells, 17px
CJK glyphs, and a 9px ellipsis.  It models the reported first-card contextual
advance and reproduces a 7px overshoot for the supplied `↗ [2025-11-05 ...]`
facet and `→ [2025-11-20 ...]` node examples when their labels are measured
in isolation.  It verifies the measured-prefix candidate, including the
mandatory facet count gap, stays within budget for those rows and an all-CJK
node title.

### Round 6 verification

```text
TAG-CARDS fills width=120 card-tracks=(38 38 38) masthead=(39 38) faces=preserved
TAG-CARDS fills width=80 card-tracks=(39 38) masthead=(26 25) faces=preserved
TAG-CARDS local-tracks width=120 spans=513; width=80 spans=478
TAG-CARDS histogram=((0 . 1133) (1 . 659) (2 . 15))
TAG-CARDS all width=120 max-line=120 frame=109.888ms refresh=126.824ms file=/private/tmp/supertag-tag-cards-all.txt
TAG-CARDS drill width=120 max-line=120 frame=58.954ms refresh=60.438ms file=/private/tmp/supertag-tag-cards-diary-idea.txt
TAG-CARDS width=80 max-line=80
```

```text
Byte compile: supertag-view-tag-cards.el, scripts/tag-cards-render.el, and
              test/tag-cards-test.el completed with no task-local warnings.
ERT:          12 tests, 12 expected, 0 unexpected.
```

## Round 7: diagnosis of the card-1-only overshoot

### Is the first card measured or padded differently?

No, not in the composition path. `supertag-view-tag-cards--compose-card-row-line`
(`supertag-view-tag-cards.el:1142`) runs one `cl-mapc` over the row's `(spec
card)` pairs with a single `pcase` on the spec kind.  `card-index` is used only
to brand the `supertag-view-tag-cards--card` text property (line 1186); it
never selects a measurement or padding method.  Every card:

- fits its label through `supertag-view-tag-cards--fit-label-to-target` with
  `text`, the complete composed line prefix so far, and pads it with
  `supertag-view-tag-cards--append-to-width` to the absolute
  `edge = origin + (plist-get card :budget)`;
- receives its left origin from the same helper, `(--append-to-cell text
  origin)`, with `origin` = previous card's edge plus `--grid-gap`.

The only asymmetry is structural: on the first iteration `text` is empty and
`origin` is 0, so the leading `(--append-to-cell text origin)` at line 1158 is
a no-op, while on later cards that same call emits the inter-card gap.  No
card-1 line is measured in isolation; the eight failing rows reach their edge
through the same pad-to-absolute-edge call as cards 2 and 3.

A card-1-only 7px excess is therefore impossible while the measurer agrees
with the renderer.  Cards 2 and 3 stay exact in the GUI because their leading
pad targets an absolute origin: when card 1's display is 7px wider than
`string-pixel-width` reported, that pad adds 7px fewer spaces, so the excess
stays inside the gap and never reaches card 2's measured edge.  The remaining
suspect is the live measurement/renderer pair, not the first-card path:
`--string-pixel-width` (`string-pixel-width`, line 228) versus the displayed
`…` advance.  The Round 7 measurement command now prints exactly that
comparison: for every FAIL line the card segment's raw text,
`string-pixel-width`, `window-text-pixel-size` right edge, the `…` char code
and `font-at` family, and the residual `(space :width)` live pixels beside its
declared width, plus once the widths of `…` and a space.

### Batch reproduction with the fake font

The new ERT test
`supertag-tag-cards-round-seven-eight-failing-rows-keep-card-one-edge` composes
one three-card block whose first card carries all eight Round 6 failing
strings (three `↗` facet rows with counts 2, 2, 4 and five `→` node rows)
through the production `supertag-view-tag-cards--compose-card-row`.  The fake
font is the specified one: 7px cells, 17px CJK, 9px ellipsis, 7px space, with
`space :width` residual spacers measured as the pixels they declare.  The card
budgets are the reported GUI geometry `(53 52 52)` with the 3-column grid gap,
so the expected card edges are exactly the GUI's own PASS values:

```text
every composed line: card edges (371 756 1141) px
card 1 right edge = 53 * 7 = 371
card 1 -> card 2 = card 2 -> card 3 = (52 + 3) * 7 = 385
eight card-1 lines end in `…`
```

All twelve lines of the block pass, so the batch composition of the eight
failing rows is edge-exact.  The GUI FAIL does not reproduce from the
composer and points at the live measurer/renderer pair above.

### Round 7 verification

```text
TAG-CARDS fills width=120 card-tracks=(38 38 38) masthead=(39 38) faces=preserved
TAG-CARDS fills width=80 card-tracks=(39 38) masthead=(26 25) faces=preserved
TAG-CARDS local-tracks width=120 spans=513; width=80 spans=478
TAG-CARDS histogram=((0 . 1133) (1 . 659) (2 . 15))
TAG-CARDS all width=120 max-line=120 frame=106.217ms refresh=134.721ms file=/private/tmp/supertag-tag-cards-all.txt
TAG-CARDS drill width=120 max-line=120 frame=88.108ms refresh=90.732ms file=/private/tmp/supertag-tag-cards-diary-idea.txt
TAG-CARDS width=80 max-line=80
```

```text
Byte compile: test/tag-cards-test.el clean; no task-local warnings
ERT:          14 tests, 14 expected, 0 unexpected
```

No TextUI file and no `supertag-view-framework.el` was touched.

## Round 8: per-view palette (Tag Cards keeps neon)

Tag Cards now owns `supertag-view-tag-cards-palette` (`defcustom`, default
`neon`, the same `(choice (const paper) (const neon) (const ink) (const
ocean))` type as the global).  `supertag-view-tag-cards--apply-palette` wraps
`supertag-view-apply-palette-locally` and is a no-op when the file is loaded
standalone without `supertag-view-framework`; it is called from the
`supertag-view-tag-cards-mode` body, so a re-entered mode reapplies it, and
again in `supertag-view-tag-cards` after `textui-open` next to the existing
`--enforce-no-wrap` reassertion.  TextUI copies `face-remapping-alist` into
its layout context and may re-enter or materialize the buffer after the mode
body, so the post-open call guarantees the neon remap is the one in effect.
The global `supertag-view-palette` is untouched and stays `paper`; Node View
continues to apply `paper` locally through the same framework helper.

The materialized-fills ERT now also asserts the buffer-local remap: in the
Tag Cards buffer `supertag-view--local-palette` is `neon`, the chip1 remap
background equals the neon light/dark value from `supertag-view-palettes` and
differs from paper's, while a plain temp buffer still resolves chip1 through
the global paper spec.

### Round 8 verification

```text
TAG-CARDS fills width=120 card-tracks=(38 38 38) masthead=(39 38) faces=preserved
TAG-CARDS fills width=80 card-tracks=(39 38) masthead=(26 25) faces=preserved
TAG-CARDS local-tracks width=120 spans=539; width=80 spans=494
TAG-CARDS histogram=((0 . 1131) (1 . 662) (2 . 15))
TAG-CARDS all width=120 max-line=120 frame=104.028ms refresh=132.287ms file=/private/tmp/supertag-tag-cards-all.txt
TAG-CARDS drill width=120 max-line=120 frame=85.365ms refresh=87.652ms file=/private/tmp/supertag-tag-cards-diary-idea.txt
TAG-CARDS width=80 max-line=80
```

The span and histogram counts differ from Round 7 only because the live vault
was rewritten between the runs (mtime 03:34); the renderer's checks, tracks,
and widths are unchanged.

```text
Byte compile: supertag-view-tag-cards.el, scripts/tag-cards-render.el, and
              test/tag-cards-test.el completed with no task-local warnings
ERT:          14 tests, 14 expected, 0 unexpected
```
