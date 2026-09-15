# Task brief: Node View, terminal editorial pass

Read `design.md` at the repository root first. It is the single source of
truth for how every Supertag view looks. Your job is to bring Node View
(`supertag-view-node.el`) in line with it, and to adjust the shared
helpers and faces in `supertag-view-framework.el` that Node View renders
through. Another agent is concurrently working on
`supertag-view-tag-cards.el` and must not be affected: you may change
`supertag-view-framework.el` helpers and face defaults, but keep every
existing helper's signature and every face name, and keep the four
palettes' role structure. Do NOT touch `supertag-view-tag-cards.el`,
`test/tag-cards-test.el` or `scripts/tag-cards-render.el`. No commits.

## Current state

Node View is a read-only side pane (`supertag-view-node--display-buffer`,
usually 60 to 90 columns wide) rendered by
`supertag-view-node--render-from-state`: masthead (tag chips, file,
date), a title panel, an action row (`[OPEN] [STREAM] [TAG MANAGER]`),
then sections inserted by other modules through the shared helper
`supertag-view-helper-insert-section-chip` and
`supertag-view-helper-insert-excerpt` (references and backlinks from
`supertag-link`, AI from `supertag-ai`, mentions from `supertag-mention`,
similar notes from `supertag-semantic`, named relations), and a footer.
Faces: `supertag-view-title` currently uses `:height 1.4`,
`supertag-view-chip1/2/3`, `supertag-view-accent`, `supertag-view-mute`,
`supertag-view-panel`, `supertag-view-rule`, `supertag-view-entry`,
`supertag-view-excerpt`. Default palette is `paper`.

## Changes

1. **One size.** Remove `:height` from `supertag-view-title` and from any
   other view face. The title becomes an UPPERCASE statement on the
   `supertag-view-panel` surface (design.md §1, §5.2), wrapped to the pane
   width, at most three lines, with `…` if longer.
2. **Default palette `neon`.** Change the `supertag-view-palette` default
   and confirm all four palettes still apply. Colored foreground text is
   removed: `supertag-view-accent` and `supertag-view-score` become
   foreground-neutral (inherit the default foreground, weight bold where
   needed); accent color appears only as fills.
3. **Masthead (design.md §5.1).** One line: `SUPERTAG / NODE` as a chip1
   fill on the left, the node's tags as `TAG / CHILD` fills next to it
   (rotate chip2/chip3 per tag), the date right-aligned in mute via
   `:align-to`. File name moves to the colophon.
4. **Actions.** Keep the traditional `[OPEN] [STREAM] [TAG MANAGER]`
   buttons; render them in the `widget-button` face on one line directly
   under the title panel, then one blank line.
5. **Section chips.** `supertag-view-helper-insert-section-chip` renders
   ` REFERENCES / 03 ` as a fill padded to the pane width (label left,
   count right), one blank line above each section, none below the chip.
   Section color: references chip1, backlinks chip2, similar chip3,
   mentions chip2, AI chip3, relations chip2. Keep the
   `supertag-view-section` text property so TAB folding still works.
6. **Entries and excerpts.** Entry lines keep the `→ title` form in
   `supertag-view-entry` (no colored foreground; bold is fine). Excerpts
   stay muted, indented six spaces, one per entry, at most two lines.
   Empty sections are omitted, never rendered as a chip with `/ 00`.
7. **Colophon.** `+ . + . + .` rule, then one mute line
   `01 / NODE  file-name.org  ·  ID-PREFIX`, then `SUPERTAG / NODE` in mute.
8. **Ornament.** No box-drawing characters anywhere in Node View.

## Verification

- Add `scripts/node-view-render.el`: loads the live database read-only
  (copy the loader recipe from `scripts/tag-cards-render.el`: tmp
  `supertag-data-directory`, `supertag-presence-enable` nil, explicit
  `supertag-load-store` of
  `/Users/chenyibin/Documents/notes/.supertag/supertag-db.el`), picks the
  node with the most references plus one node with tags and a TODO
  keyword, renders Node View for each into a temp buffer at
  `window-width` 72 (bind or set `fill-column` and any width the renderer
  consults), writes the text to `/private/tmp/supertag-node-view-*.txt`,
  and prints the max line length. Never write to the live database.
- Byte-compile `supertag-view-node.el` and `supertag-view-framework.el`
  with no new warnings; run the existing test suite entry for views
  (`bash test/run-tests.sh` with the suite that covers node view or the
  framework; see `test/renovation-suites.el`) and paste results.
- Write `doc/report-node-view-editorial.md`: the two renders (first 60
  lines each), the face changes, and any place where design.md could not
  be followed and why.

## Round 2: review findings to fix

1. **Tests.** You may now edit `test/node-view-test.el`,
   `test/view-framework-test.el` (or whichever files hold the failing
   assertions) and `test/renovation-suites.el` if needed. Update the
   assertions that encode the old design (default `paper` palette,
   unpadded section chip text, old colophon string, tag context at
   `point-min`, relation entries starting with two spaces) to the new
   design. Do not weaken unrelated assertions. Rerun `view-framework`,
   `node-view-extra` and the Node View subset until they are green with
   your `EMACS_BIN` wrapper, and paste the final `Ran N tests` lines.
2. **Section fill grammar.** Render the band as ` REFERENCES / 11 ` padded
   to the pane width, label and count together on the left, no dangling
   slash and no right-aligned count. Same for every section.
3. **Excerpts at the source.** Find where reference and backlink excerpts
   are produced (the context services in `supertag-link.el` or
   `supertag-services-*.el`; follow `supertag-view-reference-insert-sections`).
   Convert `[[id:…][desc]]` and `[[url][desc]]` to their descriptions and
   drop bare `[[id:…]]` BEFORE the snippet is clipped, and clip the snippet
   to the sentence or line that contains the link rather than a fixed
   character window that spans neighbouring headlines. The excerpt shown
   under an entry must never contain `[[` or `]]`. Edit the producing
   function in place; keep its signature. Show before/after for the
   `org-supertag` sample in the report.
4. **Spacing.** The TODO sample has two blank lines between the action row
   and the colophon rule; make it exactly one blank line before the rule
   in every case.
5. **Never drive the user's running Emacs.** Do not use `emacsclient`,
   create frames, or open buffers in the user's live session. GUI checks
   are the user's job; batch text renders are yours.

Rerun `scripts/node-view-render.el` at 72/80/120 and append a Round 2
section to `doc/report-node-view-editorial.md`. No commits.

## Round 3: entries as three-part mini cards

The user finds the References and Backlinks sections hard to read. Fix it
with structure, not color: no per-entry fills (design.md keeps fills for
labels and titles).

1. **Excerpt must add information.** After cleanup, drop the excerpt when
   it equals or is contained in the entry title, or equals the current
   node's title, or is only the link description itself. Prefer the source
   line with the link text removed; if what remains is blank, omit the
   excerpt. In the `org-supertag` sample most References excerpts
   currently repeat the title and most Backlinks excerpts are just
   `org-supertag`; both must disappear.
2. **Three-part entry.** `→ title` in `supertag-view-entry`; one muted
   excerpt line (only when it adds information); one muted metadata line
   with the source file's display name and the date (`hangji__project.org
   · 2026-07-15`). One blank line between entries. Section band, then one
   blank line, then the first entry.
3. **Cap per section.** Show at most 8 entries per section, then one muted
   line `+ 3 more` that expands the section in place on RET.
4. Rerun `scripts/node-view-render.el`, keep tests green, append a Round 3
   section to the report. Batch only; never touch the running Emacs.

5. **Width and wrapping (from the user's GUI screenshot).** In a 62-column
   side pane the title panel wrapped after 17 CJK characters, the
   `REFERENCES /` band spilled its count onto the next line, and the
   masthead date dropped to a second line. Causes and fixes:
   - Node View is rendered before its buffer is shown, so
     `supertag-view-helper-width` falls back to `fill-column`. Render with
     the width of the window that will show it: compute width from the
     live window when present, otherwise from the side-window width Node
     View is configured to use; and re-render on
     `window-size-change-functions` / `window-configuration-change-hook`
     for the Node View buffer, debounced, so a resized pane re-flows.
   - Never pad a line to the full width. Fills and the title panel pad to
     `width - 1` at most, and the title wrap budget is `width - 3`.
   - CJK glyphs in the user's font are wider than two ASCII cells, so a
     column-correct padded line is pixel-wide and wraps. When a window is
     available, cap fills, the title lines and entry lines by pixel width
     (`string-pixel-width` against `(window-body-width nil t)`), falling
     back to `string-width` in batch. Set `truncate-lines` t and
     `word-wrap` nil in the mode so residual overflow is clipped, never
     wrapped.
   - Add a batch test that renders into a buffer shown in a 62-column
     window (`with-selected-window` on a split, or `set-window-buffer`
     after `split-window`) and asserts no line exceeds 61 display
     columns.

## Round 4: review of Round 3 renders

1. **Metadata line shows raw Denote file names.** Entries read
   `20260629T105208--diary-2025__diary.org · 2026-06-28`. Show a display
   name instead: strip the Denote identifier prefix (`YYYYMMDDTHHMMSS--`)
   and the `__tags` suffix and the extension, giving `diary-2025 · 2026-06-28`;
   for non-Denote files use the base name without extension. Add a
   helper in the framework (`supertag-view-helper-file-display-name`)
   and a test.
2. **Removing the link text breaks the sentence.** The backlink excerpt
   became `可以看出，org-roam-ql 的 query 语法比 要全面。` because the link
   description (`org-supertag`) was cut out. Keep the link description in
   place inside the sentence; only drop the whole excerpt when, after
   cleanup, it equals the entry title, equals the current node's title,
   or consists of nothing but the link description. Update the Round 3
   tests accordingly.
3. **Spacing after `+ N more`.** There is no blank line between `+ 3 more`
   and the next section band. One blank line before every section band,
   always, including after a more-line.
4. Rerun the render script at 62/72/80/120, keep every suite green, append
   Round 4 to the report. No commits, no TextUI edits, never touch the
   running Emacs.

## Round 5: user feedback from the GUI (design.md amended accordingly)

The user looked at Node View in their GUI and said two things:
"node-view 里，palette 应该是 paper" and "显示 node 的部分，我觉得还是以前
的方式好". `design.md` §1, §2 and §5 have been amended; read them again.

1. **Palette per view, Node View = paper.** Restore the global default
   `supertag-view-palette` to `paper`. Add per-buffer palette application
   in the framework: `supertag-view-apply-palette-locally NAME` remaps the
   role faces (`chip1/2/3`, `panel`, `accent`, `score`, `rule`, `mute` as
   applicable) in the current buffer with `face-remap-add-relative`, so
   one view can be paper while another is neon. Add
   `defcustom supertag-view-node-palette` (default `paper`) and call the
   local apply in `supertag-view-node-mode`. Do not touch
   `supertag-view-tag-cards.el`; another agent will wire its own
   `supertag-view-tag-cards-palette` (default `neon`) to the same helper.
   Test: two buffers, one per palette, report different chip1 backgrounds.
2. **Restore the earlier presentation of the node itself.** Bring back
   the pre-editorial masthead and title panel exactly as they were before
   Round 1 (see `git show HEAD:supertag-view-node.el`,
   `supertag-view-node--insert-masthead` and `--insert-panel`): tag chips
   in uppercase on chip faces, then file name in accent and date in mute
   on the masthead line; the title on the `supertag-view-panel` surface
   in `supertag-view-title` with its original `:height 1.4`, full text,
   sentence case, wrapped naturally (no uppercase, no line cap, no
   ellipsis). Keep the action row, the filled section bands, the `→`
   three-part entries, the `+ N more` lines and the colophon from
   Rounds 2 to 4. The width-aware rendering and re-render on resize from
   Round 3 stay, but the title must never be truncated.
3. **Title truncation bug.** The screenshot shows the title rendered as
   `机动战士...` (three characters plus ASCII dots) for a node whose title
   is a full anime name. Find the truncation path that produced this
   (an ASCII `...` ellipsis, so probably not the `…` helpers: check
   `supertag-view-node--strip-todo-keyword`, any `truncate-string-to-width`
   with a small width, and the width value used when the buffer is not yet
   displayed) and remove it; add a regression test with a 12-character
   CJK title rendered in a 62-column window that asserts the full title
   is present.
4. Rerun the render script at 62/72/80/120, keep every suite green, append
   Round 5 to the report. No commits; no TextUI edits; never touch the
   running Emacs.

## Round 6: masthead file name

Round 5 restored the masthead correctly, but it prints the raw Denote
file name (`20260620T131132--org-supertag__emacs_project.org`, truncated
to `hangji__projec…` at 62 columns). Use the existing
`supertag-view-helper-file-display-name` there so it reads
`PRJ   org-supertag  /  2026-07-05`; keep the accent face for the name and
the muted date. Update the affected assertions, rerun renders at
62/72/80/120, keep suites green, append Round 6 to the report. No
commits.
