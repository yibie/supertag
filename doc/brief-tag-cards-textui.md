# Task brief: Tag Cards prototype (Tag Manager magazine page on TextUI)

Status: experiment. Throwaway-grade code is acceptable, but it must load
cleanly, byte-compile without warnings, and run against the user's live
supertag store. Do NOT touch `supertag-view-tags.el` or any other existing
file except `supertag.el` if a `require` is unavoidable (prefer not).

## Goal

A single new file `supertag-view-tag-cards.el` that renders every Semantic
Tag as a card on a responsive grid, in the spirit of Alexander Obenauer's
"Tag Navigator" (https://alexanderobenauer.com/labnotes/exp001/): each card
shows the tag, how many nodes carry it, which OTHER facets co-occur with it
(with counts), and a few recent nodes. Clicking a co-occurring facet narrows
the whole page to the intersection.

The frontend framework is TextUI (the user's own package). Load it from
`/Users/chenyibin/Documents/emacs/package/textui` (`textui.el`,
`textui-widgets.el`). Read its `README.md` first, especially the Grid and
Flex sections and the "A first interface" example, and skim
`examples/textui-grid-gallery.el`. Version is 0.8.0.

Visual language follows Node View (`supertag-view-node.el`, functions
`supertag-view-node--insert-masthead`, `--insert-actions`, `--insert-footer`)
and reuses the shared palette role faces from `supertag-view-framework.el`:
`supertag-view-chip1/2/3`, `supertag-view-accent`, `supertag-view-mute`,
`supertag-view-panel`, `supertag-view-rule`, `supertag-view-title`.
Buttons are traditional Emacs text buttons in the `widget-button` face
(`[OPEN]` style), never colored chips. Do not invent new colors.

## Data (read-only, computed on demand, nothing persisted)

- Tags: `(supertag-store-get-collection :tags)`; each is a plist with
  `:name`, `:extends` (parent tag id or nil), `:aliases`. Helpers:
  `supertag-tag-get`, `supertag-tag-ancestors`, `supertag-tag-descendants`,
  `supertag-tag-display-name` (ancestor chain joined with ` › `).
- Nodes carrying a tag: `supertag-index-find-node-ids-by-tags` (list of
  tag ids, returns node ids), or `supertag-find-nodes-by-tag TAG t` to
  include `:extends` descendants. Node plists come from
  `(supertag-store-get-collection :nodes)` / `supertag-view-api-get-entity`.
  Relevant node keys: `:title` `:raw-value` `:tags` (list of tag id
  strings) `:todo` (TODO keyword string or nil) `:file` `:created-at`
  `:modified-at`.
- Links: `supertag-query-ordinary-references-from NODE-ID` returns relation
  plists with `:to`.

### Facets

A "facet" is (KIND . VALUE) with a display label. For the node set S of a
card compute counts over S for:

1. `tag`: other tag ids present in nodes' `:tags` (exclude the card's own
   tag and its ancestors). Label = `supertag-tag-display-name`.
2. `todo`: the `:todo` keyword. Label = the keyword. This is the free
   equivalent of Obenauer's `status/` group; it matters because the user
   tags sparsely, so tag-only co-occurrence is thin.
3. `link`: target node ids referenced from nodes in S. Label = target
   title. Skip targets referenced by only one node.

Show the top 6 facets across all kinds, sorted by count desc, then label.
Rows read `+ LABEL  N` like the screenshot. Mention facets (supertag-concept
/ supertag-mention) are OUT of scope for this round.

### Groups and favorites

A "group" is any tag that has children in the `:extends` tree. Cards show
the parent chain in `supertag-view-mute` above the tag name. The page
header lists groups as buttons ("Favorite groups"); clicking one restricts
the grid to that group's descendants. `defcustom
supertag-view-tag-cards-favorite-groups` (list of tag ids, default nil =
all groups) controls which groups appear.

## State and interaction

State is one plist held by TextUI (`textui-open` third argument,
`textui-set-state` to mutate):

- `:filter` list of facets currently intersected (empty = All Tags).
- `:group` tag id or nil.
- `:limit-nodes` integer, default 5.

Page layout:

1. Header line: `All Tags   N notes` (or the active filter chain rendered as
   `reading ∩ DONE   9 notes` with a `[×]` button per facet and a `[RESET]`
   button). Face `supertag-view-title` for the first word.
2. Favorite groups row: `Favorite groups:` + one `widget-button` per group.
3. `:grid :columns 3 :min-column-width 34 :gap 2`. One child per card.
   Each card is `:flex :direction :column :gap 0`, containing:
   - parent chain (mute) or blank line to keep alignment,
   - `TAGNAME` in `supertag-view-chip1` with the count right-aligned in
     `supertag-view-accent` (a single `:text` line is fine),
   - up to 6 facet rows as push-buttons whose action adds that facet to
     `:filter` (a `tag` facet on a card = intersect card tag AND facet),
   - a blank line, then up to `:limit-nodes` node rows `→ title` as
     push-buttons calling `supertag-goto-node`, newest `:created-at` first.
4. Footer as in Node View: dotted rule + `SUPERTAG / TAGS`.

When `:filter` is non-empty the grid shows one card per facet that still
co-occurs within the intersection (so the page becomes the drill-down of
the screenshot). Keep it simple: recompute everything from the store on
every render; do not cache across renders. Performance target: full render
of the user's vault under 200 ms; measure with `benchmark-run` and report
the number.

Refresh: subscribe via
`(supertag-view-api-subscribe :store-changed (lambda (path _old _new) ...))`
when `(memq (car path) '(:tags :nodes))`, calling `textui-request-refresh`
(or `textui-update` with identity). Register the unsubscribe function with
`textui-register-cleanup`. Copy the pattern in
`supertag-view-tags--subscribe`.

Mode: derive from `special-mode`, call
`(supertag-view-register-modal-state 'supertag-view-tag-cards-mode)` so meow
and evil are disabled locally like the other views. Keys: `g` refresh, `q`
quit-window, `TAB`/`S-TAB` widget-forward/backward, `r` reset filter.
Entry command: `M-x supertag-view-tag-cards`.

## Deliverables

1. `supertag-view-tag-cards.el` (lexical-binding, Commentary header in the
   same style as the other view files, `Commands:` and `Dependencies:`
   lines included).
2. `test/tag-cards-test.el` with ERT tests for the pure data layer only
   (facet counting on a small in-memory store fixture; intersection
   narrowing). Do not test rendering.
3. Run `emacs -Q --batch -L . -L /Users/chenyibin/Documents/emacs/package/textui -l supertag-view-tag-cards.el` plus the byte-compiler and the tests, and paste the outputs.
4. A short Markdown report at `doc/report-tag-cards-textui.md` covering: the
   render benchmark, any TextUI limitation or bug you hit (be specific,
   with the element plist that failed), and anything in the brief that was
   ambiguous and how you resolved it.

Do not commit. Leave the working tree for review.

## Round 2: review findings to fix

Rendered against the live vault (`/Users/chenyibin/Documents/notes/.supertag/supertag-db.el`,
45 tags, 1806 nodes, 673 tagged) at width 120. Reuse the loader recipe in
`/Users/chenyibin/.claude/jobs/ab0ed400/tmp/cards-probe.el` (tmp
`supertag-data-directory`, `supertag-presence-enable` nil, explicit
`supertag-load-store FILE`) and keep a repeatable text-render script under
`scripts/tag-cards-render.el` that writes the all-tags page and one
drill-down page to text files and prints the max line length. Never write
to the live database.

1. **Header and Favorite groups render vertically.** Every `×`, `RESET` and
   group button lands on its own line with a blank line between, because
   they are direct children of the column flex. Wrap them in
   `(:type :flex :direction :row :gap 2 ...)` rows so they read
   `Favorite groups:  [ contact ]  [ diary ]  [ media ] ...`. Confirm rows
   wrap when there are more buttons than fit.
2. **Cards overflow their grid track.** Max rendered line length was 811
   columns at a 120-column frame. Long node titles inside native buttons
   are atomic, so the grid widens the track to fit them. Truncate every
   facet and node label with `truncate-string-to-width` and an `…`
   ellipsis to the card's content budget (track width minus padding,
   border and button chrome) before building the button. After the fix the
   text render at width 120 must have no line longer than 120, and at width
   80 it must fall back to fewer columns with no overflow.
3. **Bracketed buttons are too noisy for rows.** `[ + contact › friend  19 ]`
   and `[ → title ]` on every line fight the magazine layout. Facet rows and
   node rows must render as bracket-free link-style buttons (still the
   `widget-button` face, still TAB-navigable, still mouse/RET actionable).
   Keep brackets only for `×`, `RESET`, `ALL TAGS` and group buttons.
   Implement a widget derived from widget.el `link` with a
   `:textui-measure` that returns exactly the label and a matching
   `:textui-attach`; if TextUI cannot support that, say precisely why in the
   report with the failing element.
4. **No way back from a group.** `RESET` and `r` must clear `:group` as well
   as `:filter`, and the Favorite groups row starts with an `[ ALL TAGS ]`
   button that clears the group.
5. **Drill-down noise.** In filtered mode omit facet cards whose count is 1,
   unless that would leave the grid empty.
6. **Report additions.** Record the tags-per-node histogram you measure
   (mine: 0 tags 1133, 1 tag 659, 2 tags 14), frame-construction time and
   full `textui-refresh` time for both the all-tags page and the
   `(tag . "diary") (tag . "idea")` drill-down, on the live database.

Same rules as before: no commits, do not touch other supertag files, rerun
load, byte-compile and ERT and paste the outputs.

7. **Drop the boxes.** Remove `:border t` and the `:padding 1` from cards.
   Separate cards by whitespace only (grid `:gap 3`, one blank line between
   card rows), like Node View and the reference screenshot. Set
   `truncate-lines` to t in the mode so any residual overflow never wraps
   into the next card. The user saw the round-1 page in GUI Emacs and the
   boxes made every misalignment glaring.

## Round 3: bring Tag Cards in line with design.md

Read `design.md` at the repository root first; it is now the authority on
how every view looks and overrides the visual notes earlier in this brief
where they differ. Scope stays `supertag-view-tag-cards.el`,
`test/tag-cards-test.el`, `scripts/tag-cards-render.el`. Do NOT edit
`supertag-view-framework.el` (another agent owns it this round; use its
faces as they are). No commits.

1. **Masthead** (design.md §5.1): one row, three cells. Left: `SUPERTAG / TAGS`
   as a chip1 fill. Middle: `VOL. 45 / 673 NOTES` (tag count, tagged-node
   count) in mute. Right: the live status `COMPOSITION / LIVE` as a chip3
   fill, or the active filter chain `DIARY / IDEA ∩ DONE` when narrowing.
2. **Manifesto**: two uppercase lines plus one sentence-case line, on a
   `supertag-view-panel` surface spanning the frame width. Default copy:
   `MAKE ROOM` / `FOR THE UNEXPECTED.` and `Tags are fuel. The connections
   are computed for you: click any + row to narrow.` Provide a defcustom
   for the copy.
3. **Action row**: `[ ALL TAGS ]` `[ RESET ]` then the group buttons, as
   now, one flex row.
4. **Card title as fill** (design.md §6): the title line becomes
   ` DIARY / IDEA ` on a chip fill padded to the card content width, with
   the count right-aligned inside the fill. Rotate chip1/chip2/chip3 by
   top-level group so siblings share a color and neighbouring groups
   differ; ungrouped tags use chip2. Use the `NOUN / NOUN` grammar inside
   fills; keep ` › ` only in the muted parent line.
5. **Facet rows vs entry rows**: facet rows keep `+ label  N` with the
   count right-aligned in the card; entry rows keep `→ title`. Link facets
   get a `↗` marker instead of `+` so the three facet kinds read apart
   (`+` tag, `◆` todo, `↗` link). All still bracket-free link buttons.
6. **Zero cards**: omit cards with count 0 from the grid and list their
   names on one muted line under the grid: `EMPTY / 02  diary › lesson,
   diary › log`.
7. **Colophon**: rule `+ . + . + .`, then `01 / TAG FIELD   live store,
   recomputed on every refresh` in mute, then `SUPERTAG / TAGS` in mute.
8. **Fills on TextUI**: a fill is a string padded to the target width with
   the face applied to the whole padded string. Verify in the text render
   that padded fills are exactly the track width, and note in the report
   whether TextUI needed anything special (an `item` vs `:text` leaf, face
   survival through layout). If CJK titles inside a fill cannot be padded
   reliably by columns, say so precisely.
9. Rerun `scripts/tag-cards-render.el` at widths 120 and 80, byte-compile,
   ERT, and append a "Round 3" section to `doc/report-tag-cards-textui.md`
   with the renders' first 40 lines and the refresh timings.

## Round 4: GUI findings

The user opened the Round 3 page in GUI Emacs (light theme, window about
130 columns). Two defects:

1. **No fills are visible in the GUI buffer.** Card titles render as plain
   text; only the text render preserved faces. Verify face survival in the
   MATERIALIZED buffer, not in `textui--render-frame` output: after
   `textui-open` in a batch temp buffer, `get-text-property` on the card
   title line must return the chip face, and the masthead brand cell must
   carry `supertag-view-chip1`. If TextUI's widget materialization or your
   static item strips or overrides faces, fix it on the Tag Cards side
   (for example by attaching the face in `:textui-attach` after the widget
   is created) and record precisely what TextUI did in the report. Add an
   ERT test for this.
2. **Rows wrap in the GUI.** Lines containing CJK titles overflow their
   track and wrap onto the next visual line (`→ 姑` / `姑`), so the whole
   grid collapses. Two causes to handle:
   - The mode must guarantee no visual wrapping: `truncate-lines` t,
     `word-wrap` nil, `visual-line-mode` off, and re-assert these after
     `textui-open` (TextUI or a global minor mode may reset them).
   - CJK glyphs in the user's font are wider than two ASCII cells, so a
     column-correct row is pixel-wide. Make label budgets pixel-aware
     when a window is available: truncate a label until
     `(string-pixel-width label)` is at most the track's pixel width
     (`(* track-columns (frame-char-width))`) minus the marker and count,
     falling back to `string-width` in batch. Pad by columns afterwards
     as now; a CJK row may end a little short of the track edge, which is
     acceptable. Do the same for fills (title, masthead), padding them by
     columns but never letting their pixel width exceed the track.
3. Report the exact numbers you assumed and add a note to the report
   listing what TextUI would need in order to lay out by pixels instead
   of columns (this feeds a TextUI issue the user will file).

Rerun the render script, tests, byte-compile. No commits.

## Round 5: pixel-aligned cards composed locally (no TextUI changes)

Decision from the user: do NOT modify TextUI. Bring the alignment fix into
`supertag-view-tag-cards.el` itself, using only TextUI's public interface.

Reference: `/Users/chenyibin/Documents/emacs/package/textui/examples/textui-card-alignment-probe.el`
and its report `/Users/chenyibin/Documents/emacs/package/textui/docs/report-card-alignment-probe.md`.
Variant **C** (relative pixel padding: whole spaces plus one
`(space :width (N))` residual spacer at every block and gap boundary,
measured with `string-pixel-width` against `(* cells (frame-char-width))`)
removed all glyph-induced drift in a GUI. Variant B (align-to) also worked
but is not the choice here.

1. **Compose each card row yourself.** Replace the TextUI `:grid` of
   card elements with one attached block per row of cards (the
   `:textui-layout` / `:textui-attach` attached-block interface the probe
   uses). Inside it, compose the N cards of that row line by line with
   variant C padding so every card's left edge, right edge and count
   column sit on the same pixel for every line. Keep the responsive
   column count (3 / 2 / 1 from the width TextUI passes to the frame
   function) and the existing card content, order and faces. In batch or
   a terminal frame fall back to column padding.
2. **Overflow policy.** Truncate every label to its pixel budget with `…`
   before padding (you already have the pixel truncation helpers); a card
   never widens its track. Fills (title line) pad to the exact track pixel
   width so the background spans the whole card width on every card.
3. **Buttons inside the composed block.** Facet rows and node rows stay
   clickable and TAB-navigable: use text buttons (`make-text-button` on
   the composed strings with the same actions) since widget.el controls
   cannot be embedded in a precomposed attached block. `TAB`/`S-TAB` map
   to `forward-button`/`backward-button` in the mode; RET and mouse-1
   activate. Masthead, manifesto and the action row can stay as they are.
4. **Measurement command.** Add `supertag-view-tag-cards-measure` that,
   in the live buffer, prints for each card row the right-edge x of every
   card on every line via `window-text-pixel-size`, and `PASS` when all
   edges of a card agree within 1px, exactly like the probe. The user
   will run this in their GUI and paste the output.
5. Update `scripts/tag-cards-render.el` and the ERT tests; batch renders
   at 120 and 80 must still have no line over the width and column-exact
   tracks. Byte-compile clean. Append a Round 5 section to the report
   describing what of TextUI's public interface you relied on and what
   you had to give up (for example, TextUI focus restoration on those
   rows). No commits; do not edit any TextUI file.

## Round 6: one-cell overshoot on truncated labels in card 1

The user ran `supertag-view-tag-cards-measure` in their GUI
(`frame-char-width=7`). Result: every card 2 and card 3 edge is exact
(756px / 1141px on all 190 lines), card 1 is exact (371px) on all lines
except eight, where it measures 378px, i.e. exactly one cell too far. All
eight lines are card-1 rows whose label was truncated with `…`:

```
 29| ↗ [2025-11-05 Wed 22:35] 昨天下午和… 2
 70| → [2025-11-20 Thu 20:12] 在手机上实现…
 72| → [2026-01-16 Fri 08:40] 在邻居旁边创…
 96| ↗ [2025-08-26 Tue 23:09] 我今天开始… 2
140| → 一门语言的表面语法来自哪里？它的数…
147| → Oibeater：突然觉得有了 AI 后程序猿…
149| → 我对自己的要求很低：我活在世上，无…
174| ↗ [2025-11-03 Mon 02:22] 看到 Sky 交…4      <- count glued to the label
```

Non-truncated CJK rows on the same cards pass (lines 28, 30, 71, 95). So
the pixel truncation leaves a truncated label one cell wider than its
budget in the first card only, and line 174 shows the count column being
pushed as a consequence.

Fix:

1. Make the truncation loop re-measure the candidate WITH the ellipsis
   appended and with the marker and count reserve, and accept only when
   `(string-pixel-width candidate) <= budget` strictly; never rely on a
   column estimate for the ellipsis. Check why card 1 differs from cards
   2 and 3 (first-card path measuring the label in isolation instead of
   the full line prefix, or the gap before card 2 absorbing card 1's
   overshoot) and make all cards use the same measured-prefix method.
2. The count column must be positioned from the measured prefix too, so a
   label can never touch it; if the label plus one space plus the count
   does not fit, truncate the label further.
3. Add a batch-safe regression test with a fake pixel measurer (bind or
   advise the width function to return, for example, 9px for `…` and
   17px per CJK char with a 7px cell) that reproduces the overshoot on
   these strings and proves the new loop keeps every row within budget.
4. Rerun render script, byte-compile, ERT; append Round 6 to the report.
   No commits; no TextUI file changes.

## Round 7: Round 6 changed nothing in the GUI; diagnose measurement vs rendering

The user re-ran `supertag-view-tag-cards-measure` after Round 6. The
PASS/FAIL summary is byte-identical to Round 5: card 1 FAIL 7px on rows 2,
5, 7, 10, 11, 13; every card 2 and 3 PASS. Either the Round 6 code path is
not what renders card 1's truncated rows, or the measurement of card 1 is
wrong on `…` rows while rendering is fine.

1. **Prove which.** Extend `supertag-view-tag-cards-measure` so that for
   every FAIL line it also prints: the card segment's raw text, the
   `string-pixel-width` of that segment, the `window-text-pixel-size`
   right edge, the char code and rendering font family (`font-at`) of
   the `…` glyph, and the pixel width of the residual `(space :width)`
   spacer it emitted. Also print, once, `(string-pixel-width "…")` and
   `(string-pixel-width " ")`.
2. **Check the card-1 path explicitly.** Read the code path that composes
   the first card of a row versus later cards; if the first card's label
   budget or its right-edge padding is computed from anything other than
   the measured full line prefix, unify it. Write down in the report the
   exact function and line where card 1 diverges, or state that there is
   no divergence.
3. **Reproduce in batch with the fake font.** Bind the pixel measurer so
   that `…` is 9px, CJK 17px, ASCII 7px and space 7px, compose row 2 of
   the live vault (or a fixture with the eight failing strings) and assert
   card 1's right edge equals cards 2 and 3's spacing. If this passes in
   batch but fails in the GUI, the suspect is `string-pixel-width` versus
   actual display for the `…` glyph (a fallback font whose advance is not
   what `string-pixel-width` reports in a temp buffer without the
   buffer's face remaps) and the fix is to measure in the live buffer
   (`window-text-pixel-size` on the composed line) instead of in a
   temp buffer.
4. ERT green, render script unchanged in width, report appended. No
   commits, no TextUI or framework edits.

## Round 8: per-view palette

The framework now has `supertag-view-apply-palette-locally NAME`
(`supertag-view-framework.el`), which remaps the role faces in the current
buffer with `face-remap-add-relative`, and the global default
`supertag-view-palette` is back to `paper`. Node View uses `paper`; Tag
Cards keeps `neon` (see design.md §2).

1. Add `defcustom supertag-view-tag-cards-palette` (default `neon`, same
   choice type as `supertag-view-palette`) and call
   `supertag-view-apply-palette-locally` with it in
   `supertag-view-tag-cards-mode` and again after `textui-open` if the
   mode is re-entered. Do not change the global palette.
2. Confirm the local remap survives TextUI materialization and the
   attached-block composer: extend the existing materialized-fills ERT to
   assert that, in a Tag Cards buffer, the chip1 background equals the
   neon light/dark value while a plain buffer with the global palette
   shows paper's.
3. Rerun render script, byte-compile, ERT; append Round 8 to the report.
   No commits; no TextUI or framework edits.

## Round 9: back to TextUI `:grid` now that the core composes by pixels

TextUI `e71d9bf` ("compose rows and boxes by pixels on graphical frames")
is committed and verified in the user's GUI: stock composition keeps every
right edge on the same pixel. The local card-row composer from Rounds 5 to
7 is now redundant. Read
`/Users/chenyibin/Documents/emacs/package/textui/docs/report-pixel-composition.md`
("what Tag Cards can delete") and ADR 0039 first.

Key facts about the new core:
- On graphical frames, row blocks and gaps are padded from the cumulative
  line prefix with a residual `(space :width (N))`; terminal and batch
  output are unchanged (column based).
- Overflow is not clipped: a block wider than its allocation still grows
  its track, now measured in pixels. So labels must still be truncated to
  the track's pixel budget before they reach TextUI, or tracks become
  unequal.

1. **Restore the field as a TextUI `:grid`.** Replace the attached
   card-row blocks with one `:grid` whose children are the cards (as in
   Round 4: each card a `:flex :direction :column :gap 0`). Facet rows and
   node rows go back to the bracket-free link widgets
   (`supertag-view-tag-cards-link`) and TAB/S-TAB go back to
   `widget-forward`/`widget-backward`; the title fill stays the static item
   with `:textui-attach` that preserves faces.
2. **Keep pixel truncation, drop pixel padding.** Keep
   `--fit-label-to-target` (or its equivalent) so every label, facet count
   reservation and title fill fits the track's pixel budget
   (`track-columns * frame-char-width`, measured with the target window's
   fonts; column fallback in batch). Delete what the core now does:
   `--compose-card-row-line`, `--compose-card-row`, `--card-row-block*`,
   `--append-to-cell`, `--append-to-width`, `--spacer-to-width`, the
   layout half of `--pad-right`/`--pad-between`, and any attached-block
   widget type that only existed for the composer. Fills pad to the track
   by columns and let the core finish the pixel edge.
3. **Keep `supertag-view-tag-cards-measure` working.** It currently finds
   cards through the `supertag-view-tag-cards--card` text property set by
   the composer. Put that property (row index, card index) on each card's
   rendered text through the card element instead, so the command still
   measures every card edge in the live buffer and prints PASS/FAIL. Keep
   the diagnostic fields.
4. **Tests.** Remove tests that only exercised the deleted composer.
   Keep and adapt: facet counting, narrowing, label budgets, fill faces
   after materialization, per-view palette, and the eight-failing-strings
   regression, now asserted through `textui--render-frame` with
   `textui--pixel-metrics-override` bound to the fake font
   (`(MEASURE . 7)` with CJK 14px, arrows and `…` 14px, space 7px, which is
   the user's real Iosevka geometry) so every card's right edge is equal on
   every line.
5. Load path: TextUI is at
   `/Users/chenyibin/Documents/emacs/package/textui` at commit `e71d9bf` or
   later. Rerun `scripts/tag-cards-render.el` (widths 120 and 80, no line
   over width), byte-compile clean, ERT green, append Round 9 to the report
   with the line count of `supertag-view-tag-cards.el` before and after. No
   commits; do not edit TextUI or `supertag-view-framework.el`.

## Round 10: one grid for the whole field

TextUI `dfb5e72` adds `:column-gap` and `:row-gap` to `:grid` (`:gap` stays
the shorthand; axis-specific properties override it). The per-row grids
from Round 9 existed only because one `:gap` controlled both axes.

1. Render the card field as a single `:grid` with `:column-gap 3` and
   `:row-gap 1` (keep the current `:columns` and `:min-column-width`).
   Delete the code that splits cards into visual rows and builds one grid
   per row, including any duplicated responsive column calculation.
2. The measure command needs a (row . card) identity per card. Derive the
   row index from the card's position and the grid's responsive column
   count at render width, or have the measure command group cards by the
   line where their title starts; pick whichever needs less code, and keep
   the report output format unchanged.
3. Tests: the render at widths 120 and 80 must stay line-for-line
   identical to the Round 9 render (compare against the text files the
   render script writes before your change), and the Iosevka-geometry
   regression must still show equal card edges on every line.
4. Byte-compile clean, ERT green, append Round 10 to the report with the
   line count before and after. No commits; no TextUI or framework edits.
