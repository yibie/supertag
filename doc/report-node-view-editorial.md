# Node View editorial pass

## Scope and result

Changed only `supertag-view-node.el`, `supertag-view-framework.el`,
`scripts/node-view-render.el`, and this report. No commits. The concurrent
Tag Cards implementation and its tests/render script were not edited.

Node View now has a branded masthead, uppercase bounded title panel,
traditional action row, full-width section fills, arrow entries, and a
three-line colophon. Existing helper signatures and face names remain intact.
TAB folds on a section chip and otherwise advances among buttons; S-TAB
moves backward. Fold overlays stop before the colophon. Meow and Evil are
disabled locally in Node View.

## Faces and shared drawing

- Removed title scaling; neither scoped view file contains `:height`.
- `neon` is the default. All four palettes retain their role structure and
  light/dark variants. Palette switching was exercised successfully.
- `supertag-view-accent` and `supertag-view-score` inherit neutral default
  foreground with bold emphasis in every palette.
- `supertag-view-entry` inherits `widget-button`, with bold emphasis and no
  explicit colored foreground. Action buttons remain `widget-button`.
- Titles use `supertag-view-title` on `supertag-view-panel`, uppercased,
  wrapped to at most three lines. Long titles end in an ellipsis.
- References use chip1; backlinks, mentions and relations chip2; similar
  notes and AI candidates chip3. Counts are right aligned and zero-count
  chips are not emitted. The section text property remains on the band.
- Excerpts retain their muted face, six-space indent and a two-line cap.
  Complete Org links are displayed as descriptions before wrapping;
  already clipped source snippets can still contain partial link syntax.
- The Node adapter adds arrow markers and truncates feature-owned entry
  rows while preserving button actions and context properties.

## Read-only live-data renders

Run the command documented at the top of `scripts/node-view-render.el`.
It creates a fresh temporary data directory, disables presence, explicitly
loads the requested live Store, disables background semantic computation
for these deterministic samples, and never calls save. SHA256 before and
after matched:

`848e7e37cc1c32936169b52c5c8d7f88b3cef7d79de8f9788fc84c90e0feec0d`

Selection:

- Most ordinary incoming + outgoing references: `E7F070EF-D0CB-41D2-97C5-9EDFCB04409A`
  (`org-supertag`), 43 stored reference relations. The context services
  aggregate those into 11 outgoing and 11 backlink entry cards.
- Tagged TODO-keyword node: `04066A76-D2AF-4822-9F90-419B6B271024`,
  `【箱单发票】漏掉集装箱，原产地编号填写位置`. TODO stripping remains enabled.

| Sample | Width 72 maximum | Width 80 maximum | Width 120 maximum |
|---|---:|---:|---:|
| References | 72 | 80 | 120 |
| Tagged TODO | 72 | 80 | 120 |

Widths are Emacs `string-width` display columns, not character counts;
CJK characters count as two columns. All six outputs are under
`/private/tmp/supertag-node-view-{references,todo}-{72,80,120}.txt`.
The script also checks title/excerpt limits, empty chips, preserved button
identity, footer visibility after folding, absence of box drawing,
unspecified title height, and neutral palette emphasis. All passed.

### Reference sample — first 60 lines at width 72

```text
 SUPERTAG / NODE   TAG / PRJ                                  2026-07-05

 ORG-SUPERTAG
[OPEN]  [STREAM]  [TAG MANAGER]

 REFERENCES /                                                        11
→ 2025-03-05 Wed
      …query 语法的工具 org-roam-ql 通过结合 Denote， org-supertag
      的用法其实和 LogSeq 已经一模一样了 2025-03-05 Wed [2025-07-28 Mon…
→ [2025-07-28 Mon 09:40] 测试 org-sueprtag-query-insert
      …ogSeq 已经一模一样了 2025-03-05 Wed [2025-07-28 Mon 09:40] 测试
      org-sueprtag-query-insert [[id:95EB206B-1D12-48B1-8983-01683B720F…
→ [2025-09-09 Tue 17:17] Zettelkasten 不应该结构化，应该主题化
      [2025-09-09 Tue 22:24] 解决 org-supertag 数据库初始化的问题
      [2025-10-07 Tue 01:36] 看来要尽快实现 HAIP Prompt 规范 [[id:19BC1…
→ [2025-10-07 Tue 01:36] 看来要尽快实现 HAIP Prompt 规范
      …解决 org-supertag 数据库初始化的问题]] [2025-10-07 Tue 01:36]
      看来要尽快实现 HAIP Prompt 规范 [[id:19BC17F2-02A1-480C-94A2-8E5A…
→ [2025-11-11 Tue 00:11] 我解决了 org-sueprtag 数据库文件总是被意外清零…
      …36] 看来要尽快实现 HAIP Prompt 规范]] [2025-11-11 Tue 00:11]
      我解决了 org-sueprtag 数据库文件总是被意外清零的问题 org-supertag…
→ [2025-11-11 Tue 16:26] 结合自然对话和 AGENTS.md 实现 Spec-kit 的效果
      …org-sueprtag-query-insert]] [2025-11-11 Tue 16:26]
      结合自然对话和 AGENTS.md 实现 Spec-kit 的效果 让窗口可以临时 Zoom…
→ org-id-find 无法找到 file-node
      …Tue 16:26] 结合自然对话和 AGENTS.md 实现 Spec-kit 的效果]]
      让窗口可以临时 Zoom in/Zoom out org-id-find 无法找到 file-node su…
→ org-supertag 的标签支持嵌套标签
      …E5AE5800A97][[2025-11-11 Tue 00:11] 我解决了 org-sueprtag
      数据库文件总是被意外清零的问题]] org-supertag 的标签支持嵌套标签 …
→ supertag-schema 新增：合并 tag
      …d 实现 Spec-kit 的效果]] 让窗口可以临时 Zoom in/Zoom out
      org-id-find 无法找到 file-node supertag-schema 新增：合并 tag
→ 为 org-roam 提供 query 语法的工具 org-roam-ql
      …1 Tue 00:11] 我解决了 org-sueprtag
      数据库文件总是被意外清零的问题]] org-supertag 的标签支持嵌套标签 …
→ 让窗口可以临时 Zoom in/Zoom out
      …1683B720F72][[2025-11-11 Tue 16:26] 结合自然对话和 AGENTS.md
      实现 Spec-kit 的效果]] 让窗口可以临时 Zoom in/Zoom out org-id-fin…

 BACKLINKS /                                                         11
→ org-supertag 的标签支持嵌套标签
      …的写法，如果要从数据库映射到前端显示，这条路径不知道要耗时多久，
      而 Emacs 典型是单线程设计，如果绘图方面消耗资源太多，就容易堵塞主…
→ 为 org-roam 提供 query 语法的工具 org-roam-ql
      …m-ql 视频上看，可以直接检索 backlink-to 某个 node，比较有趣。
      可以看出，org-roam-ql 的 query 语法比 org-supertag 要全面。 参考…
→ 让窗口可以临时 Zoom in/Zoom out
      https://x.com/mitchellh/status/2071688415524049208 org-supertag
→ org-id-find 无法找到 file-node
      org-supertag
→ supertag-schema 新增：合并 tag
      …的 tag - 合并时用户可选择保留哪些 field - 对应 node 的 tag
      要修改成合并后的 tag - 不仅数据层面，包括文件层面 org-supertag
→ 2025-03-05 Wed
      今天终于更新了 org-zettel-ref-mode
      的过滤、排序、还有高亮笔记的样式了。顺道还更新了 org-supertag 的…
→ [2025-07-28 Mon 09:40] 测试 org-sueprtag-query-insert
      #+BEGIN_SRC org-supertag-query :results raw (and (tag "project")
      (field "Status" "On-going")) #+END_SRC #+RESULTS: | Node | Tags |…
```

### Tagged TODO sample — first 60 lines at width 72 (entire page)

```text
 SUPERTAG / NODE   PRJ / TASK                                 2026-07-15

 【箱单发票】漏掉集装箱，原产地编号填写位置
[OPEN]  [STREAM]  [TAG MANAGER]


+ . + . + .
01 / NODE  20260622T082132--hangji__project.org  ·  04066A76
SUPERTAG / NODE
```

## Verification results

Both scoped implementation files byte-compiled, with outputs redirected to
`/private/tmp` rather than the repository. Compared warning messages and
counts with the same command against `git show HEAD:<file>` copies:
**zero new warnings**. Existing warnings concern `when-let`, two existing
customization docstrings and the forward palette variable assignment.
Logs: `/private/tmp/node-editorial-compile{,-baseline}.log`.

The repository test entrypoint was run, without changing any tests:

```sh
bash test/run-tests.sh view-framework
bash test/run-tests.sh node-view-extra
```

The initial run encountered local Emacs 32 native trampoline linking
(`emutls_w`), abbreviated child-process working directories, and missing
`ht` in cold child processes. Repeated using `EMACS_BIN` pointing to a
temporary wrapper that expands `default-directory`, disables native
subroutine trampolines, and adds the installed `ht`/`dash` load paths.
This changes no test assertions or repository files.

Final selected-suite output:

```text
Ran 47 tests, 44 results as expected, 3 unexpected (2026-09-12 20:53:53-0700, 15.322422 sec)
Ran 22 tests, 21 results as expected, 1 unexpected (2026-09-12 20:53:54-0700, 0.870926 sec)
```

Remaining framework failures are assertions for the old default `paper`,
the old unpadded section-chip/excerpt string, and a zero-count `SIMILAR`
status chip. The node-view-extra failure expects a relation entry to start
with two spaces rather than `→ `. These assertions conflict with the brief;
the test files are outside the authorized scope and were left untouched.

The Node View subset of `test/node-view-test.el` was also run directly
with the same environment wrapper:

```text
Ran 8 tests, 5 results as expected, 3 unexpected (2026-09-12 20:53:13-0700, 3.506856 sec)
```

Its three remaining assertions expect the old colophon string, an
unpadded section chip, and tag context at `point-min` (now the brand, not
the first tag). The framework live-subscription/selection-preservation
check passes, as does the script's current-layout folding check.

An earlier broader `contract` run reported 108/153 passing, 45 unexpected;
it included unrelated cold-process environment and existing feature-test
failures as well as the old Node View layout assertions. That diagnostic
run is not presented as a green suite. Full logs remain at
`/private/tmp/node-editorial-{framework-final,extra,node-final,contract}.log`.
`git diff --check` passed.

## GUI check and design qualifications

Opened the property-bearing 72-column CJK reference render in a temporary
GUI Emacs QA frame and inspected the screenshot. CJK entries and six-space
excerpt indents align; the date and counts align with the rendered field
edge. GUI title height is unspecified (not a scaling override).
Screenshot:
`/var/folders/ns/sfzfbcd16d19rky4mtm4gpbm0000gq/T/codex-shot-2026-09-12_20-49-15.png`.

- A separate manifesto is deliberately omitted, as permitted for Node View
  side panes. The node title serves as the uppercase statement.
- The requested date replaces the generic live-status fill. The source
  filename appears only in the colophon.
- Tag chips are truncated or dropped when horizontal room runs out.
  Below 40 columns the date is omitted to retain brand and tag context;
  the required 72/80/120 samples all retain it. Node View is a single column,
  not a grid, so no grid tracks need dropping.
- The existing user's light Emacs theme was respected during GUI checking;
  the neon light variant was shown instead of forcibly recoloring the
  user's global editor background. Dark palette variants remain supported.
- Meaningful in-flight/error status text and its action buttons remain
  available without a misleading zero-count filled heading. Empty result
  chips themselves are omitted.
- The three-part *tag card* template is not imposed on contextual reference
  entries: those have no parent/facet data. Their section fill, arrow entry,
  and muted excerpt use the Node-specific layout in the brief.


## Round 2 — review fixes and final verification

This section supersedes Round 1's right-aligned section counts, footer
spacing, test failures, and GUI procedure. Round 2 used **batch Emacs
only**: no `emacsclient`, no frames or buffers in the user's running Emacs,
and no GUI checks. GUI inspection is left to the user. No commits.

### All five review items

1. Updated only the assertions that encode the superseded design in
   `test/view-palette-test.el`, `test/view-framework-test.el`,
   `test/node-view-test.el`, and `test/text-link-node-view-test.el`.
   The new expectations check `neon`, the exact padded section band,
   two physically wrapped excerpt lines with six-space indents, the new
   colophon, tag selection on the tag chip rather than the brand at
   `point-min`, arrow-prefixed incoming/outgoing relation entries, and
   meaningful semantic error status without a zero-count chip. Existing
   action, subscription, source/store isolation, and navigation checks
   remain intact. The suite manifest needed no changes.
2. Section label and count now stay together on the left:
   ` REFERENCES / 11 ` followed by padding through the pane width.
   The complete band retains its face and folding property.
3. Fixed the producing service in `supertag-link.el`, not a post-render
   cleanup. The path is `supertag-view-reference-insert-sections` →
   incoming/outgoing context services →
   `supertag-reference-service--aggregate` →
   `supertag-reference-service-context-snippet`.
   The snippet service locates the actual physical ID/Denote link first,
   selects its source line, then calls the existing cleaner with Org's
   bracket-link regexp. Described ID and URL links become descriptions,
   bare ID links disappear, and remaining malformed double-bracket
   delimiters are removed. Only then is the cleaned line length capped.
   A reference without a physical link falls back to a matching target
   term's line, or the first nonblank source line when no term is found.
   The two edited service functions keep their existing signatures.
   The former cross-line character window is no longer used.
4. The footer normalizes preceding newlines to **exactly one blank line**
   before `+ . + . + .`, with or without any reference sections.
5. The running Emacs session was not accessed in this round. The render
   script uses temporary buffers inside its isolated batch process only.

Added five Node View regression tests covering cleanup before clipping
(including very long URL paths and bracketed timestamp descriptions),
physical-link priority over an earlier title mention, bare-ID removal,
semantic line selection, long-line clipping, unchanged source data, and
footer spacing. The render script now additionally rejects double-bracket
syntax in every excerpt and validates one blank line before the colophon.

### `org-supertag` before / after (72 columns)

The same stored node was used in both rounds. Below is the beginning of
its old reference section, captured before editing the producer:

```text
 REFERENCES /                                                        11
→ 2025-03-05 Wed
      …query 语法的工具 org-roam-ql 通过结合 Denote， org-supertag
      的用法其实和 LogSeq 已经一模一样了 2025-03-05 Wed [2025-07-28 Mon…
→ [2025-07-28 Mon 09:40] 测试 org-sueprtag-query-insert
      …ogSeq 已经一模一样了 2025-03-05 Wed [2025-07-28 Mon 09:40] 测试
      org-sueprtag-query-insert [[id:95EB206B-1D12-48B1-8983-01683B720F…
→ [2025-09-09 Tue 17:17] Zettelkasten 不应该结构化，应该主题化
      [2025-09-09 Tue 22:24] 解决 org-supertag 数据库初始化的问题
      [2025-10-07 Tue 01:36] 看来要尽快实现 HAIP Prompt 规范 [[id:19BC1…
→ [2025-10-07 Tue 01:36] 看来要尽快实现 HAIP Prompt 规范
      …解决 org-supertag 数据库初始化的问题]] [2025-10-07 Tue 01:36]
      看来要尽快实现 HAIP Prompt 规范 [[id:19BC17F2-02A1-480C-94A2-8E5A…
```

After, the same entries contain only their source link line. Several source
lines consist solely of a link, so their cleaned excerpts are simply the
link description; no surrounding prose is invented. Full first 60 lines:

```text
 SUPERTAG / NODE   TAG / PRJ                                  2026-07-05

 ORG-SUPERTAG
[OPEN]  [STREAM]  [TAG MANAGER]

 REFERENCES / 11
→ 2025-03-05 Wed
      2025-03-05 Wed
→ [2025-07-28 Mon 09:40] 测试 org-sueprtag-query-insert
      [2025-07-28 Mon 09:40] 测试 org-sueprtag-query-insert
→ [2025-09-09 Tue 17:17] Zettelkasten 不应该结构化，应该主题化
      [2025-09-09 Tue 22:24] 解决 org-supertag 数据库初始化的问题
→ [2025-10-07 Tue 01:36] 看来要尽快实现 HAIP Prompt 规范
      [2025-10-07 Tue 01:36] 看来要尽快实现 HAIP Prompt 规范
→ [2025-11-11 Tue 00:11] 我解决了 org-sueprtag 数据库文件总是被意外清零…
      [2025-11-11 Tue 00:11] 我解决了 org-sueprtag
      数据库文件总是被意外清零的问题
→ [2025-11-11 Tue 16:26] 结合自然对话和 AGENTS.md 实现 Spec-kit 的效果
      [2025-11-11 Tue 16:26] 结合自然对话和 AGENTS.md 实现 Spec-kit
      的效果
→ org-id-find 无法找到 file-node
      org-id-find 无法找到 file-node
→ org-supertag 的标签支持嵌套标签
      org-supertag 的标签支持嵌套标签
→ supertag-schema 新增：合并 tag
      supertag-schema 新增：合并 tag
→ 为 org-roam 提供 query 语法的工具 org-roam-ql
      为 org-roam 提供 query 语法的工具 org-roam-ql
→ 让窗口可以临时 Zoom in/Zoom out
      让窗口可以临时 Zoom in/Zoom out

 BACKLINKS / 11
→ org-supertag 的标签支持嵌套标签
      org-supertag
→ 为 org-roam 提供 query 语法的工具 org-roam-ql
      可以看出，org-roam-ql 的 query 语法比 org-supertag 要全面。
→ 让窗口可以临时 Zoom in/Zoom out
      org-supertag
→ org-id-find 无法找到 file-node
      org-supertag
→ supertag-schema 新增：合并 tag
      org-supertag
→ 2025-03-05 Wed
      今天终于更新了 org-zettel-ref-mode
      的过滤、排序、还有高亮笔记的样式了。顺道还更新了 org-supertag 的…
→ [2025-07-28 Mon 09:40] 测试 org-sueprtag-query-insert
      | #project | project, org_supertag | On-going |
→ [2025-09-09 Tue 17:17] Zettelkasten 不应该结构化，应该主题化
      E7F070EF-D0CB-41D2-97C5-9EDFCB04409A
→ [2025-10-07 Tue 01:36] 看来要尽快实现 HAIP Prompt 规范
      org-supertag
→ [2025-11-11 Tue 00:11] 我解决了 org-sueprtag 数据库文件总是被意外清零…
      org-supertag
→ [2025-11-11 Tue 16:26] 结合自然对话和 AGENTS.md 实现 Spec-kit 的效果
      org-supertag

+ . + . + .
01 / NODE  20260620T131132--org-supertag__emacs_project.org  ·  E7F070EF
SUPERTAG / NODE
```

Updated tagged TODO sample (whole page, fewer than 60 lines):

```text
 SUPERTAG / NODE   PRJ / TASK                                 2026-07-15

 【箱单发票】漏掉集装箱，原产地编号填写位置
[OPEN]  [STREAM]  [TAG MANAGER]

+ . + . + .
01 / NODE  20260622T082132--hangji__project.org  ·  04066A76
SUPERTAG / NODE
```

### Final tests and compilation

Reused the isolated `EMACS_BIN=/private/tmp/node-editorial-emacs` wrapper
from Round 1. Its complete contents, for reproduction:

```sh
#!/bin/sh
if [ "$1" = -Q ]; then shift; fi
exec /opt/homebrew/bin/emacs -Q --eval '(setq native-comp-enable-subr-trampolines nil default-directory (expand-file-name default-directory))' -L /Users/chenyibin/.emacs.d/elpa/ht-20230703.558 -L /Users/chenyibin/.emacs.d/elpa/dash-20260221.1346 "$@"
```

Suite command:

```sh
EMACS_BIN=/private/tmp/node-editorial-emacs \
  bash test/run-tests.sh view-framework node-view-extra
```

The Node View subset was run in a separate batch process with `-L . -L test`,
package initialization, a fresh temporary `user-emacs-directory` and
`supertag-data-directory`, then:

```elisp
(require 'ert)
(load "test/node-view-test.el")
(ert-run-tests-batch-and-exit "^supertag-node-view-")
```

Final output (framework, node-view-extra, Node View subset respectively):

```text
Ran 47 tests, 47 results as expected, 0 unexpected (2026-09-12 21:02:58-0700, 15.124747 sec)
Ran 22 tests, 22 results as expected, 0 unexpected (2026-09-12 21:03:00-0700, 0.729567 sec)
Ran 13 tests, 13 results as expected, 0 unexpected (2026-09-12 21:03:04-0700, 3.574489 sec)

```

Byte-compiled `supertag-view-framework.el`, `supertag-view-node.el` and
`supertag-link.el` into `/private/tmp`. Comparing warning messages and
counts against isolated HEAD copies of the same files found **zero new
warnings**. `git diff --check` passed.

### Final render checks

| Sample | Pane width | Maximum display line length |
|---|---:|---:|
| References | 72 | 72 |
| Tagged TODO | 72 | 72 |
| References | 80 | 80 |
| Tagged TODO | 80 | 80 |
| References | 120 | 120 |
| Tagged TODO | 120 | 120 |

All six renders passed the bounds, excerpt-syntax and footer-spacing
checks. All four palettes passed neutral-emphasis checks. The live Store
SHA256 was unchanged:

`848e7e37cc1c32936169b52c5c8d7f88b3cef7d79de8f9788fc84c90e0feec0d`

Artifacts: `/private/tmp/supertag-node-view-{references,todo}-{72,80,120}.txt`.
Logs: `/private/tmp/node-round2-final-suites.log`,
`/private/tmp/node-round2-node.log`, `/private/tmp/node-round2-render.log`,
and `/private/tmp/node-round2-compile{,-baseline}.log`.

No per-entry multicolor backgrounds were added: that was discussed as a
possible follow-up, not made part of this five-item correction pass.
Tag Cards files were not edited.

## Round 3 — three-part entry cards, cap, and pane-aware width

This round fixes the user's readability complaint with structure, not
color: no per-entry fills were added. Round 3 used **batch Emacs only**
(no `emacsclient`, no frames, no buffers in the running Emacs), touched no
Tag Cards file and nothing under the external `textui` package, and made
no commits.

### Excerpts that add information (producer)

`supertag-reference-service-context-snippet` still selects the source
line of the physical link, then removes the matched link itself before
cleaning. `supertag-reference-service--snippet-adds-information-p` drops
the excerpt when what remains is blank, is contained in either endpoint's
title, or is only the link description. The two functions keep their
signatures; the cleaning and clipping order from Round 2 is unchanged.

`supertag-reference-service--aggregate` now also records the endpoint's
`:date` (`YYYY-MM-DD` from `:created-at`, else `:modified-at`).

### Three-part card and section cap

`supertag-view-reference--insert-card` now emits
`→ title`, one muted excerpt line (only when the service kept one, clipped
to a single line), and one muted metadata line
`<file> · <YYYY-MM-DD>`; entries are separated by one blank line. The
Node View side adds a generic pass that puts one blank line between a
section band and its first entry (`supertag-view-node--space-sections`).

Each section is capped at 8 entries. Past that, a muted `+ N more` text
button is inserted at the cap point and an invisible overlay hides the
remaining entries; RET deletes the overlay and the button line in place.
The cap is generic (`supertag-view-node--cap-sections`), so AI,
mentions, similar notes and relations sections obey it too.

### Pane-aware width, no full-width padding, no wrap

- `supertag-view-helper-width` uses the live window when one shows the
  buffer, then the Node View render width, then `fill-column`.
  `supertag-view-node--render-view` sets the render width from the window
  or, before the side window exists, from the configured side size
  (`supertag-view-node--estimated-width`), so the first render already
  matches the pane that is about to open.
- New shared helpers `supertag-view-helper-window`,
  `supertag-view-helper-display-capacity`, `-display-cost` and `-clip`
  measure in pixels against `window-body-width ... t` and
  `string-pixel-width` in a graphical window, and in display columns in
  batch. Fills, the title panel, entry lines, excerpts and the colophon
  are clipped with `supertag-view-helper-clip`; CJK glyphs wider than two
  ASCII cells clip instead of wrapping.
- Nothing pads to the full width anymore: fills and the title panel pad
  to `width - 1`, the title wraps at `width - 3`, entry lines and the
  colophon stay inside `width - 1`, and the excerpt indent budget is
  `width - 7`.
- `supertag-view-node-mode` sets `truncate-lines` t and `word-wrap` nil.
- `window-size-change-functions` and `window-configuration-change-hook`
  schedule a debounced (0.1 s) refresh of the Node View buffer whenever
  the pane width differs from the width the text was laid out for, so a
  resized pane re-flows.

### `org-supertag` sample: excerpts before / after

Round 2 rendered the References entries with an excerpt that was the link
description on its own line (for example `→ 2025-03-05 Wed` over
`2025-03-05 Wed`), and most Backlinks entries showed `org-supertag`, the
current node's own title. After Round 3 all 11 References excerpts are
dropped (they only repeated the link text), 4 of the 11 Backlinks
excerpts are dropped as the current node's title, and the two genuinely
informative backlink lines survive. Every entry now carries its own
file/date line:

```text
 REFERENCES / 11

→ 2025-03-05 Wed
      20260629T105208--diary-2025__diary.org · 2026-06-28

→ [2025-07-28 Mon 09:40] 测试 org-sueprtag-query-insert
      20260629T105208--diary-2025__diary.org · 2026-06-28

…

→ org-supertag 的标签支持嵌套标签
      20260617T063222--diary__diary.org · 2026-06-21

+ 3 more

 BACKLINKS / 11

→ org-supertag 的标签支持嵌套标签
      20260617T063222--diary__diary.org · 2026-06-21

→ 为 org-roam 提供 query 语法的工具 org-roam-ql
      可以看出，org-roam-ql 的 query 语法比 要全面。
      20260617T063222--diary__diary.org · 2026-06-21
```

### Width 62 render (the failing GUI pane) and bounds

The full 62-column page is
`/private/tmp/supertag-node-view-references-62.txt`; the head of it:

```text
 SUPERTAG / NODE   TAG / PRJ                       2026-07-05

 ORG-SUPERTAG
[OPEN]  [STREAM]  [TAG MANAGER]

 REFERENCES / 11

→ 2025-03-05 Wed
      20260629T105208--diary-2025__diary.org · 2026-06-28

→ [2025-07-28 Mon 09:40] 测试 org-sueprtag-query-insert
      20260629T105208--diary-2025__diary.org · 2026-06-28

→ [2025-09-09 Tue 17:17] Zettelkasten 不应该结构化，应该主题…
      20260629T105208--diary-2025__diary.org · 2026-06-28

→ [2025-10-07 Tue 01:36] 看来要尽快实现 HAIP Prompt 规范
      20260629T105208--diary-2025__diary.org · 2026-06-28

→ [2025-11-11 Tue 00:11] 我解决了 org-sueprtag 数据库文件总…
      20260629T105208--diary-2025__diary.org · 2026-06-28

→ [2025-11-11 Tue 16:26] 结合自然对话和 AGENTS.md 实现 Spec-…
      20260629T105208--diary-2025__diary.org · 2026-06-28

→ org-id-find 无法找到 file-node
      20260617T063222--diary__diary.org · 2026-07-05

→ org-supertag 的标签支持嵌套标签
      20260617T063222--diary__diary.org · 2026-06-21

+ 3 more
 BACKLINKS / 11

→ org-supertag 的标签支持嵌套标签
      20260617T063222--diary__diary.org · 2026-06-21

→ 为 org-roam 提供 query 语法的工具 org-roam-ql
      可以看出，org-roam-ql 的 query 语法比 要全面。
      20260617T063222--diary__diary.org · 2026-06-21

→ 让窗口可以临时 Zoom in/Zoom out
      20260617T063222--diary__diary.org · 2026-06-29
```

Maximum display line length per render; every value is one column inside
the pane, so no line wraps or overflows:

| Sample | 62 | 72 | 80 | 120 |
|---|---:|---:|---:|---:|
| References | 61 | 71 | 79 | 119 |
| Tagged TODO | 61 | 71 | 79 | 119 |

The tagged TODO page is unchanged apart from the bounds (8 lines):

```text
 SUPERTAG / NODE   PRJ / TASK                       2026-07-15

 【箱单发票】漏掉集装箱，原产地编号填写位置
[OPEN]  [STREAM]  [TAG MANAGER]

+ . + . + .
01 / NODE  20260622T082132--hangji__project.org  ·  04066A76
SUPERTAG / NODE
```

The live Store digest differs between runs because the user's own Emacs
keeps syncing their notes; the script verifies the digest before and after
each run to prove Node View never writes. The final run matched:

`75bdde033913d33a01b9576f61b8f29dfc3c44c3872a9750d7ebdf7df52dadc2`

### The 62-column batch test

`supertag-node-view-62-column-pane-flows-without-padding` renders into a
buffer shown in a real 62-column window (`split-window` + `set-window-buffer`
+ `with-selected-window`) and asserts no line exceeds 61 display columns,
the section band is padded to 61, the metadata line is present, entries
past 8 are hidden behind `+ 3 more`, and activating the button removes the
overlay, the button line and reveals all 11 entries. It is part of the
Node View subset below.

### Final tests and compilation

The same isolated `EMACS_BIN=/private/tmp/node-editorial-emacs` wrapper
and `SUPERTAG_DEPS_LOADPATH` as Round 2 (so VWA/cold child processes find
`ht` and `dash`) were used throughout.

```text
Ran 47 tests, 47 results as expected, 0 unexpected (2026-09-13 01:20:13-0700, 13.990083 sec)
Ran 22 tests, 22 results as expected, 0 unexpected (2026-09-13 01:20:14-0700, 0.544545 sec)
Ran 16 tests, 16 results as expected, 0 unexpected (2026-09-13 01:24:50-0700, 2.988709 sec)
Ran 50 tests, 49 results as expected, 0 unexpected, 1 skipped (2026-09-13 01:20:16-0700, 1.083440 sec)
Ran 36 tests, 36 results as expected, 0 unexpected (2026-09-13 01:20:18-0700, 0.847740 sec)
Ran 16 tests, 16 results as expected, 0 unexpected (2026-09-13 01:20:19-0700, 0.504750 sec)
Ran 25 tests, 25 results as expected, 0 unexpected (2026-09-13 01:20:20-0700, 0.717765 sec)
Ran 97 tests, 97 results as expected, 0 unexpected (2026-09-13 01:22:02-0700, 75.557592 sec)
```

The lines are `view-framework`, `node-view-extra`, the Node View subset
(`^supertag-node-view-`, now 16 tests, including the 62-column pane test
and a width/clip helper test), `ai` (1 pre-existing skip), `semantic`,
`mention-extra`, `stream`, and `tag-path`. The `contract` suite is 160/161; its
single failure,
`supertag-node-feature-compat-create-real-positions-draft-hooks`, fails
identically on a pristine `git archive HEAD` checkout in this environment
(`Ran 153 tests, 152 results as expected, 1 unexpected`) and is unrelated
to Node View. The `add-link` suite likewise has the same 11 child-process
failures (path-prefix `/var` vs `/private/var`) on the pristine checkout.

Byte-compiling `supertag-view-framework.el`, `supertag-view-node.el` and
`supertag-link.el` into `/private/tmp` produced the same 16 warnings as
compiling the pristine HEAD copies: **zero new warnings**.

### Assertions updated for the Round 3 design

- `test/node-view-test.el`: the three snippet tests now expect the link
text removed (for example `This cites .`, `Read manual with and .`), a new
test covers title-only/link-only dropping, the 62-column test was added,
and the two side-window tests pin `supertag-view-node-side-size` to 0.8 so
the batch frame's 26-column default side pane does not truncate the tag
name before the assertion reads it.
- `test/view-framework-test.el`: the padded section band expectation moved
from 72 to 71 columns.
- `test/ai-test.el` / `test/semantic-test.el`: their fixtures pin the
Node View side size to 0.8 (the assertions read full sentences and passage
previews, which genuinely cannot fit in 26 columns), the no-blank-excerpt
regexp is anchored to the line start so the padded band no longer matches
it, the semantic status band is asserted through its live status line
(zero-count bands are omitted by the Round 1 decision), and the wrapped
passage preview accepts whitespace at the wrap point.

### Qualifications

- The masthead brand is 17 columns; below roughly 30 columns the tag chip
  can only show a clipped label. That is a consequence of never exceeding
  the pane width; no rule in design.md drops the brand, so it was kept and
  the tests were given a realistic pane.
- Zero-count status sections (AI `Extracting…`, semantic `Computing…`,
  errors) keep their message and buttons but no filled heading, per the
  Round 1 review decision; design.md does not require a fill for status.
- The pixel path is only exercised in a graphical window
  (`string-pixel-width` vs `window-body-width` pixels); batch renders and
  the 62-column test use display columns. Pixel measurement in a real GUI
  remains part of the user's own GUI check.
- Tag Cards files (`supertag-view-tag-cards.el`, `test/tag-cards-test.el`,
  `scripts/tag-cards-render.el`) and the external `textui` package were
  not edited; no commits were made.

## Round 4 — display names, sentence-preserving excerpts, section gaps

Round 4 fixes the three review findings on the Round 3 renders. Batch
Emacs only (no `emacsclient`, no frames, no buffers in the running
Emacs); no commits, no TextUI edits, no Tag Cards edits.

### 1. File display names

New framework helper `supertag-view-helper-file-display-name`: Denote
names lose their `YYYYMMDDTHHMMSS--` prefix, their `__tags` suffix and
the extension; other files keep the base name without extension. The
reference card metadata line uses it instead of
`file-name-nondirectory`. The colophon still shows the raw file name.

```text
/notes/20260629T105208--diary-2025__diary.org        → diary-2025
20260620T131132--org-supertag__emacs_project.org    → org-supertag
20260622T082132--hangji__project.org                → hangji
/notes/hangji__project.org                          → hangji__project
plain.org                                           → plain
nil / ""                                             → nil
```

### 2. Excerpts keep the link description in place

`supertag-reference-service-context-snippet` no longer cuts the matched
link out of the source line; after linking it still cleans physical link
syntax into descriptions, then drops the whole excerpt only when the
result is blank, equals either endpoint's title, or is nothing but the
matched link's own description. The backlink sentence is readable again:

```text
before (Round 3)   可以看出，org-roam-ql 的 query 语法比 要全面。
after  (Round 4)   可以看出，org-roam-ql 的 query 语法比 org-supertag 要全面。
```

### 3. One blank line after a more-line

The cap overlay now ends before the blank line in front of the next
section band instead of swallowing it, so every band is preceded by one
empty line, including after `+ 3 more`. `scripts/node-view-render.el`
now asserts that gap on every band of every visible render.

```text
→ org-supertag 的标签支持嵌套标签
      diary · 2026-06-21

+ 3 more

 BACKLINKS / 11

→ 为 org-roam 提供 query 语法的工具 org-roam-ql
      可以看出，org-roam-ql 的 query 语法比 org-supertag 要全面。
      diary · 2026-06-21
```

### Renders and bounds

Maximum display line length; still one column inside each pane:

| Sample | 62 | 72 | 80 | 120 |
|---|---:|---:|---:|---:|
| References | 61 | 71 | 79 | 119 |
| Tagged TODO | 61 | 71 | 79 | 119 |

Artifacts: `/private/tmp/supertag-node-view-{references,todo}-{62,72,80,120}.txt`.
The live Store digest was unchanged before/after the final run:
`75bdde033913d33a01b9576f61b8f29dfc3c44c3872a9750d7ebdf7df52dadc2`.

### Final tests and compilation

The same isolated wrapper and `SUPERTAG_DEPS_LOADPATH` as Round 3 were
used.

```text
Ran 48 tests, 48 results as expected, 0 unexpected (2026-09-13 01:34:38-0700, 13.822766 sec)
Ran 22 tests, 22 results as expected, 0 unexpected (2026-09-13 01:34:39-0700, 0.534798 sec)
Ran 16 tests, 16 results as expected, 0 unexpected (2026-09-13 01:34:50-0700, 2.965626 sec)
Ran 50 tests, 49 results as expected, 0 unexpected, 1 skipped (2026-09-13 01:34:41-0700, 1.083770 sec)
Ran 36 tests, 36 results as expected, 0 unexpected (2026-09-13 01:34:44-0700, 1.617059 sec)
Ran 16 tests, 16 results as expected, 0 unexpected (2026-09-13 01:34:45-0700, 0.508292 sec)
Ran 25 tests, 25 results as expected, 0 unexpected (2026-09-13 01:34:47-0700, 0.707307 sec)
Ran 97 tests, 97 results as expected, 0 unexpected (2026-09-13 01:36:16-0700, 77.227166 sec)
```

The lines are `view-framework` (48, including the new display-name test),
`node-view-extra`, the Node View subset (16), `ai` (1 pre-existing skip),
`semantic`, `mention-extra`, `stream`, and `tag-path`. `contract` is
160/161 with the same pre-existing, baseline-identical
`supertag-node-feature-compat-create-real-positions-draft-hooks` failure.
Byte-compiling the three view files produced the same 16 warnings as the
pristine HEAD copies: zero new warnings.

### Assertions updated for Round 4

- `test/node-view-test.el`: the snippet tests expect the link description
  in place again (`This cites The actual note.`,
  `Read manual with [2026-01-01] Target and .`);
  `supertag-node-view-reference-snippet-drops-uninformative-prose` now
  covers equality with either title and with the matched link's own
  description; the 62-column test renders a second section and asserts
  display-name metadata (`hangji__project-0`, `incoming`), the visible
  blank line after `+ 3 more`, 9 visible entries before and 12 after
  expanding, using the new `supertag-node-view-test--visible-text`
  helper.
- `test/view-framework-test.el`: new
  `supertag-view-framework-file-display-name` test covers Denote prefix,
  `__tags` suffix, plain files and nil.
- `scripts/node-view-render.el`: visible renders must contain two
  newlines before every section band.

## Round 5 — per-view palettes, classic node presentation, title fix

Round 5 answers the user's GUI feedback: Node View shows the warm `paper`
palette and the pre-editorial presentation of the node itself, and the
truncated-title bug is gone.  Batch Emacs only (no `emacsclient`, no
frames, no buffers in the running Emacs); no commits, no TextUI edits,
`supertag-view-tag-cards.el` untouched.

### 1. Palette per view, Node View = paper

- The global default `supertag-view-palette` is `paper` again.
- New `supertag-view-apply-palette-locally` remaps the seven role faces
  (`panel`, `chip1/2/3`, `accent`, `score`, `rule`) in the current buffer
  via `face-remapping-alist` and `face-remap-add-relative`, choosing the
  light or dark variant for the frame's background mode and replacing
  only this buffer's previous role remaps.  A companion
  `supertag-view--local-palette` records what was applied.
- New `defcustom supertag-view-node-palette` (default `paper`) is applied
  by `supertag-view-node-mode`; the mode line reports it.  Another view can
  apply `neon` at the same time (Tag Cards wires its own defcustom later).

Two buffers with different palettes report different chip1 backgrounds
(`supertag-view-palette-applies-locally-per-buffer`).

### 2. Classic masthead and large title panel

- `supertag-view-title` has its `:height 1.4` back, and
  `supertag-view-node--insert-panel` is the pre-Round-1 panel again:
  blank line, two spaces, the title in sentence case on the
  `supertag-view-panel` surface, blank line.  There is no uppercase, no
  three-line cap and no ellipsis.  A title wider than the pane is split
  by *display units* (`supertag-view-node--wrap-title`) so the GUI font
  cannot clip it either.
- `supertag-view-node--insert-masthead` is the pre-Round-1 masthead:
  one blank line, the tag chips in uppercase on `supertag-view-chip1`,
  then the file name in `supertag-view-accent`, then `  /  date` in mute.
  It stays inside the pane by clipping the file name before the date, so
  the date survives at 62 columns.  Hierarchy tags use `PRJ / TASK`
  rather than the old `PRJ › TASK`, per the amended design.md label
  grammar.
- The action row, filled section bands, `→` three-part entries, `+ N more`
  lines and colophon from Rounds 2–4 are unchanged, and the Round 3 width
  computation, caps and resize re-render stay.

### 3. Title truncation bug

Root cause: Round 1–4's panel passed a **column** budget
(`(1- width)`, 61 at a 62-column pane) to
`supertag-view-helper-clip`, whose limit is in **display units** — pixels
when a graphical window shows the buffer.  A CJK title at `:height 1.4`
measures well over 61 pixels, so the clip cut it down to `机动战士…` in the
GUI while batch renders (columns for both) looked fine.  The full-text
panel removes that path.

`supertag-node-view-title-is-never-truncated` renders the 12-character
CJK title `机动战士高达水星的魔女` into a real 62-column window while the
display helpers report pixel-like units (10 per column, reproducing the
GUI glyph width); it asserts the full title is present and that no `…` or
ASCII `...` appears.  The render script's contract now asserts the panel
keeps all 300 `界` of its fixture title with no ellipsis.

### Renders and bounds

| Sample | 62 | 72 | 80 | 120 |
|---|---:|---:|---:|---:|
| References | 61 | 71 | 79 | 119 |
| Tagged TODO | 61 | 65 | 65 | 65 |

```text

 PRJ   20260620T131132--org-supertag__emacs_p…  /  2026-07-05


  org-supertag

[OPEN]  [STREAM]  [TAG MANAGER]

 REFERENCES / 11
```

```text

 PRJ / TASK   20260622T082132--hangji__projec…  /  2026-07-15


  【箱单发票】漏掉集装箱，原产地编号填写位置

[OPEN]  [STREAM]  [TAG MANAGER]

+ . + . + .
01 / NODE  20260622T082132--hangji__project.org  ·  04066A76
SUPERTAG / NODE
```

Artifacts: `/private/tmp/supertag-node-view-{references,todo}-{62,72,80,120}.txt`.
The live Store digest was unchanged before/after the final run:
`9705fd594d042631e404bea51d193d46922649b42a47ba3e60ce5a0fafe78f68`.

### Final tests and compilation

```text
Ran 49 tests, 49 results as expected, 0 unexpected (2026-09-13 03:51:03-0700, 13.684441 sec)
Ran 22 tests, 22 results as expected, 0 unexpected (2026-09-13 03:51:04-0700, 0.532842 sec)
Ran 17 tests, 17 results as expected, 0 unexpected (2026-09-13 03:51:15-0700, 2.951622 sec)
Ran 50 tests, 49 results as expected, 0 unexpected, 1 skipped (2026-09-13 03:51:06-0700, 1.074568 sec)
Ran 36 tests, 36 results as expected, 0 unexpected (2026-09-13 03:51:09-0700, 1.651085 sec)
Ran 16 tests, 16 results as expected, 0 unexpected (2026-09-13 03:51:10-0700, 0.511215 sec)
Ran 25 tests, 25 results as expected, 0 unexpected (2026-09-13 03:51:12-0700, 0.706102 sec)
Ran 97 tests, 97 results as expected, 0 unexpected (2026-09-13 03:52:46-0700, 75.150167 sec)
Ran 162 tests, 161 results as expected, 1 unexpected (2026-09-13 03:54:02-0700, 75.956518 sec)
```

The lines are `view-framework` (49, including the per-buffer palette test),
`node-view-extra`, the Node View subset (17, including the title
regression test), `ai` (1 pre-existing skip), `semantic`, `mention-extra`,
`stream`, `tag-path`, and `contract`.  `contract` has the same single
pre-existing, baseline-identical
`supertag-node-feature-compat-create-real-positions-draft-hooks` failure;
`add-link` keeps its 11 pre-existing `/var` vs `/private/var` child-process
failures.  Byte-compiling the three view files produced the same 16
warnings as the pristine HEAD copies: zero new warnings.

### Assertions updated for Round 5

- `test/view-palette-test.el`: the default is `paper`; new
  `supertag-view-palette-applies-locally-per-buffer` compares the locally
  remapped chip1 background of a paper buffer with a neon buffer and
  rejects an unknown palette name.
- `test/node-view-test.el`: new
  `supertag-node-view-title-is-never-truncated` (62-column CJK title with
  GUI-like display units).
- `scripts/node-view-render.el`: the global palette assertion is `paper`,
  the title height is `1.4`, and the panel contract counts all 300 `界`
  with no ellipsis.

## Round 6 — masthead file name

Small follow-up to Round 5: the classic masthead now prints
`supertag-view-helper-file-display-name` instead of the raw Denote file
name, so a Denote node reads
` PRJ   org-supertag  /  2026-07-05` (accent face on the name, muted
date).  The file-name clip from Round 5 stays as a safety net for long
non-Denote names, and the raw file name is still available in the
colophon.  Batch Emacs only; no commits, no TextUI or Tag Cards edits.

```text

 PRJ   org-supertag  /  2026-07-05


  org-supertag

[OPEN]  [STREAM]  [TAG MANAGER]

 REFERENCES / 11
```

```text

 PRJ / TASK   hangji  /  2026-07-15


  【箱单发票】漏掉集装箱，原产地编号填写位置

[OPEN]  [STREAM]  [TAG MANAGER]

+ . + . + .
01 / NODE  20260622T082132--hangji__project.org  ·  04066A76
SUPERTAG / NODE
```

| Sample | 62 | 72 | 80 | 120 |
|---|---:|---:|---:|---:|
| References | 61 | 71 | 79 | 119 |
| Tagged TODO | 60 | 60 | 60 | 60 |

Artifacts: `/private/tmp/supertag-node-view-{references,todo}-{62,72,80,120}.txt`.
The live Store digest was unchanged before/after the run:
`9705fd594d042631e404bea51b193d46922649b42a47ba3e60ce5a0fafe78f68`.

### Final tests and compilation

```text
Ran 49 tests, 49 results as expected, 0 unexpected (2026-09-13 03:59:27-0700, 13.807271 sec)
Ran 22 tests, 22 results as expected, 0 unexpected (2026-09-13 03:59:28-0700, 0.530398 sec)
Ran 17 tests, 17 results as expected, 0 unexpected (2026-09-13 03:59:39-0700, 2.973295 sec)
Ran 50 tests, 49 results as expected, 0 unexpected, 1 skipped (2026-09-13 03:59:30-0700, 1.089312 sec)
Ran 36 tests, 36 results as expected, 0 unexpected (2026-09-13 03:59:32-0700, 1.629400 sec)
Ran 16 tests, 16 results as expected, 0 unexpected (2026-09-13 03:59:34-0700, 0.516708 sec)
Ran 25 tests, 25 results as expected, 0 unexpected (2026-09-13 03:59:35-0700, 0.699262 sec)
Ran 97 tests, 97 results as expected, 0 unexpected (2026-09-13 04:01:03-0700, 75.706368 sec)
Ran 162 tests, 161 results as expected, 1 unexpected (2026-09-13 04:02:20-0700, 76.250841 sec)
```

`view-framework`, `node-view-extra`, the Node View subset, `ai` (1
pre-existing skip), `semantic`, `mention-extra`, `stream`, `tag-path`,
and `contract`.  `contract` keeps the same pre-existing, baseline-identical
`supertag-node-feature-compat-create-real-positions-draft-hooks` failure.
Byte-compiling the three view files produced the same 16 warnings as the
pristine HEAD copies: zero new warnings.

### Assertions updated for Round 6

- `test/node-view-test.el`: the 62-column test asserts the masthead shows
  `heading  /  2026-07-15` and never `heading.org  /`; its `:created-at`
  fixture now uses `(encode-time '(0 0 0 15 7 2026))`, since a bare
  6-element list is read as a 3-element time value (1969-12-31).
- `scripts/node-view-render.el`: a new contract fixture renders a Denote
  masthead at 62 columns and asserts `org-supertag  /  2026-07-05` with
  no `20260620T` or `__emacs_project` in the buffer.




