# Report: the orphan report is a view page

Commit: `4b9b632 refactor(view): orphan report becomes a standalone view
page` (files: `supertag-view-orphan-tags.el` new, `supertag-tag.el`,
`test/orphan-view-page-test.el` new, `test/orphan-bulk-cleanup-test.el`,
`test/delete-everywhere-text-test.el`, `test/renovation-suites.el`).
Brief: `doc/brief-orphan-view-page.md`.  Branch `supertagV2`.  Nothing was run
against `/Users/chenyibin/Documents/notes`; every measurement below is a
temp-directory fixture whose root is `(file-truename (make-temp-file ...))`.

## What moved

The whole page left `supertag-tag.el` (the 13,257-character
`supertag-report-orphan-tag-occurrences` block, its keymap and its major mode
are gone from that file) and now lives in `supertag-view-orphan-tags.el`,
registered with the view framework:

```elisp
(supertag-view-register
 :id 'orphan-tags :name "Orphan Tags" :selectable nil
 :buffer-name supertag-view-orphan-tags--buffer-name
 :mode-fn #'supertag-view-orphan-tags-mode
 :state-fn #'supertag-view-orphan-tags--build-state
 :render-fn #'supertag-view-orphan-tags--renderer
 :display-action '(display-buffer-same-window))
```

`:selectable nil` is deliberate: the relocation must not add a new entry
point, so the page opens from its own command and not from a view switcher.
Both command spellings survive with autoloads in `supertag-tag.el`, so every
existing caller keeps working:

- `supertag-view-orphan-tags` -- the page, the Tag Manager's spelling.
- `supertag-report-orphan-tag-occurrences` -- kept as the Tag spelling.

The selection rule that the page and the non-interactive cleanup must agree on
became one shared function, `supertag-tag--orphan-select-records`, still in
`supertag-tag.el`; the page's `D` and `supertag-cleanup-orphan-tag-occurrences`
both call it.  The removal path itself is untouched: the page's `D` calls
`supertag-view-orphan-tags-remove`, which calls the same
`supertag-tag--orphan-remove` (records + near + rescan guard) as `f46307a` and
`293e562`, and passes the same records.  There is no second write path.

## What did not change

- Every token starts marked when the page opens; reopening resets that
  default.  `g` re-reads the scope, prunes vanished occurrences, and never
  re-marks a token the user unmarked on purpose.
- One preview, one `yes-or-no-p`, per-file rescan abort, range writes: all of
  it is still the `f46307a` path, verified by `orphan-bulk-cleanup-test.el`
  (7 tests, renamed only) which calls the page's own keys.
- `supertag-cleanup-orphan-tag-occurrences` still takes a token, a list, or
  nil, and needs no minibuffer.
- Ambiguous tokens are still listed separately and refused; a token whose
  resolution signals is never an orphan and can never be removed.
- No new capability: the page cannot register, rename or adopt a token.  The
  only actions are REMOVE (the existing path), MARK ALL, UNMARK ALL, REFRESH,
  and visiting an occurrence's file and line.

## The two preferences

**Modal editing is disabled locally, not switched to a state.**  The mode body
is copied from the Tag Manager: after `special-mode`, the page sets
`buffer-read-only`, `truncate-lines`, applies the palette locally, and calls
`(meow-mode -1)` and `(evil-local-mode -1)` -- the two minor modes are turned
off in the buffer rather than left in motion or emacs state.  The framework's
`supertag-view-register-modal-state` call is kept as well (as on the Tag
Manager), so a buffer that enables evil later still starts in emacs state
rather than a motion state.

**Actions are traditional text buttons.**  `[ REMOVE ]`, `[ MARK ALL ]`,
`[ UNMARK ALL ]` and `[ REFRESH ]` are inserted with the framework's
`supertag-view-helper-insert-action-button`, i.e. `insert-text-button` with
`face widget-button`, `follow-link t`, `RET`/`mouse-2` activation.  No chip
face is used for an action; chip faces only fill labels and titles.

## design.md checks

| check | how this page meets it | evidence |
|-------|------------------------|----------|
| five-band skeleton | masthead, manifesto, action row, field, colophon | `supertag-orphan-page-shows-all-five-bands` |
| one font size | no view face carries `:height`; emphasis is fill, case, whitespace | `supertag-orphan-page-uses-the-paper-palette-at-one-size` |
| colour as filled area | brand/title fills (`chip1`/`chip2`/`chip3`), manifesto panel, rules | `supertag-orphan-page-buttons-and-fills-carry-no-ink-colour` |
| `NOUN / NOUN` labels | `SUPERTAG / ORPHANS`, `VOL. 3 / 5 OCCURRENCES`, `MARKED / 3 TOKENS`, `FILES / 1`, `AMBIGUOUS / 1 TOKENS, NOT ORPHANS` | renders below |
| character-built ornament | `+ . + . + .` rule, `→` entries, `* ` marks, `…` clipping | renders below |
| three-part card | overline (`FILES / N`), title fill with the count in chip3, blank line, entry rows | renders below |
| text buttons, not chips | `widget-button` face, `RET`/`mouse-2`, `follow-link` | `supertag-orphan-page-actions-are-plain-text-buttons` |
| 120 / 80 render, nothing overflows | every line <= width, narrow drops the manifesto sentence | `supertag-orphan-page-renders-at-120-and-80-columns` |
| GUI CJK alignment | **not verified** -- batch only; the render below does include a CJK line and stays inside the width | see ceilings |

## Render at width 120

```
 SUPERTAG / ORPHANS                       VOL. 3 / 5 OCCURRENCES                   MARKED / 3 TOKENS                    

 METADATA / NOT GARBAGE.                                                                                                
 TOKENS / NO TAG OWNS.                                                                                                  
 Orphan tokens are text no Tag entity owns.  Every token starts marked; unmark what to keep, then REMOVE.               

[ REMOVE ]  [ MARK ALL ]  [ UNMARK ALL ]  [ REFRESH ]

 FILES / 1                                                                                                              
 * #old                                                                                                               1 
 * → 5  node.org  [FILETAGS]  #+FILETAGS: :old:                                                                         

 FILES / 1                                                                                                              
 * #seo                                                                                                               3 
 * → 6  node.org  [heading :ID: hashed]  * 域名比价 | hosting notes #seo                                                
 * → 10  node.org  [heading :ID: hashed]  Body prose with #seo, at the end of a sentence.                               
 * → 15  node.org  [heading without :ID:]  More prose with #seo and a long trailing line that goes on and on to test cl…

 FILES / 1                                                                                                              
 * #word                                                                                                              1 
 * → 11  node.org  [heading without :ID:]  * No ID heading #word                                                        

 AMBIGUOUS / 1 TOKENS, NOT ORPHANS                                                                                      
 #dup                                                                                                                   
+ . + . + .
 01 / ORPHAN FIELD  3 TOKEN(S)  5 OCCURRENCE(S)  LIVE TEXT SCAN                                                         
SUPERTAG / ORPHANS
```

## Render at width 80

```
 SUPERTAG / ORPHANS          VOL. 3 / 5 OCCURRENCES     MARKED / 3 TOKENS       

 METADATA / NOT GARBAGE.                                                        
 TOKENS / NO TAG OWNS.                                                          
 Orphan tokens are text no Tag entity owns.  Every token starts marked; unmark …

[ REMOVE ]  [ MARK ALL ]  [ UNMARK ALL ]  [ REFRESH ]

 FILES / 1                                                                      
 * #old                                                                       1 
 * → 5  node.org  [FILETAGS]  #+FILETAGS: :old:                                 

 FILES / 1                                                                      
 * #seo                                                                       3 
 * → 6  node.org  [heading :ID: hashed]  * 域名比价 | hosting notes #seo        
 * → 10  node.org  [heading :ID: hashed]  Body prose with #seo, at the end of a…
 * → 15  node.org  [heading without :ID:]  More prose with #seo and a long trai…

 FILES / 1                                                                      
 * #word                                                                      1 
 * → 11  node.org  [heading without :ID:]  * No ID heading #word                

 AMBIGUOUS / 1 TOKENS, NOT ORPHANS                                              
 #dup                                                                           
+ . + . + .
 01 / ORPHAN FIELD  3 TOKEN(S)  5 OCCURRENCE(S)  LIVE TEXT SCAN                 
SUPERTAG / ORPHANS
```

(The render comes from `/tmp/st-bin/orphan-render.el`: a document-fixture
vault with `#old`, `#seo` (3 occurrences, one of them a long line that is
clipped), `#word`, and one token whose resolution is made to signal, so the
ambiguous section is real.  Widths are pinned with
`supertag-view-helper-width-override` and the buffer is never displayed, so
`window-body-width` cannot change them.)

## Test changes, itemized

New:

1. `test/orphan-view-page-test.el` (11 tests) plus the manifest entry
   `("test/orphan-view-page-test.el" . "^supertag-orphan-page-")`: page
   registration, five bands, text-button faces and mouse keys, paper palette
   with no `:height`, marks default and `g` semantics on a card-title fill,
   the ambiguous section and its refusal, meow/evil local disable, evil
   initial state, quit, and the 120/80 width invariants.

Renamed (no assertion changed by the rename):

2. `test/orphan-bulk-cleanup-test.el`: 7 test names
   `supertag-orphan-tags-*` -> `supertag-view-orphan-tags-*`, and the manifest
   selector for that file updated to `^supertag-view-orphan-tags-` so the
   suite keeps selecting exactly those 7 tests.

Updated assertions (each with its reason; none weakened):

3. `"^\\* #seo   4 occurrence(s)"` -> `"\\* #seo"` plus the occurrence-row
   text.  Reason: the token row is now a fill whose trailing cell holds the
   count, so "4 occurrence(s)" is no longer written in that row.  The count is
   still asserted, twice and behaviourally: `(= 6 (length
   supertag-view-orphan-tags--records))` and the preview's `WILL CHANGE: 6`.
4. `"^  #word"` / `"^      [0-9]+  .*Prose #word"` -> `"\\* #word"` must be
   absent and `"→ [0-9]+  node\\.org  \\[heading without :ID:\\]  Prose #word"`
   must be present.  Reason: same fill change; the assertion now combines the
   mark prefix (behaviour) with the exact file/line/context/text of the row.
5. The fixture pointer `(re-search-forward "^  #seo " nil t)` ->
   `(re-search-forward "#seo" nil t)`.  Reason: the row is padded now.  This is
   a pointer into the page in a test helper, not a product assertion; the test
   then presses `m` and still asserts the resulting mark set.
6. `test/delete-everywhere-text-test.el`: `"\\* #never   2 occurrence(s)"` ->
   `"\\* #never"`, and `"All tokens start marked"` ->
   `"METADATA / NOT GARBAGE."`.  Reason: the note line became the manifesto.  "Every token
   starts marked" is now asserted directly on the mark set in
   `supertag-orphan-page-mark-keys-work-on-a-card-title`.

No test was deleted, no retry/recovery contract was touched, and the deletion
suite (`tag-rename-delete`) is untouched.

## Measurements

- `EMACS_BIN=/tmp/st-bin/emacs bash test/run-tests.sh`: 35 suites, 1234 tests,
  1229 results as expected, 5 skipped, 0 unexpected, exit 0.
- `tag-change` suite (the suite that holds every test above): 60 tests, 60
  results as expected, 0 unexpected -- 49 before this task, +11 from the new
  page file.
- `bash test/static-gates.sh`: `Static O gates: PASS`.
- Renders: `orphan-render.el` at 120 and 80 columns, `max line` 120 and 80
  respectively (byte-exact output is pasted above).

## Ceilings (measured, not silently dropped)

- **TAB / S-TAB do not move between buttons on this page.**  Measured on this
  page and on the Tag Manager page in the same process: `TAB` =
  `indent-for-tab-command`, `S-TAB` = nil on both.  That is a pre-existing
  framework gap, unchanged by this relocation; `RET` and `mouse-2` (plus
  `follow-link` for mouse-1) do activate.
- **GUI CJK alignment is not verified.**  `design.md` asks for a GUI check
  with CJK content; this task verified batch renders only, with one CJK line
  inside the width.
- The card overline reads `FILES / N` rather than a parent chain; the design
  allows the overline to be blank and the count lives in chip3 as specified.

DONE: doc/report-orphan-view-page.md
