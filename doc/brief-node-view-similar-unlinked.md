# Task brief: Node View — Similar notes vanish; Unlinked Mentions repeat

Branch `supertag-refactor`. Batch verification only. Do NOT drive the
user's running Emacs, and NEVER load or save the user's real store
(`~/Documents/notes/.supertag/`): a previous agent's "read-only" check ran
`supertag-load-store` on that file and its auto-migration wrote it back.
Use isolated temp data directories only. Commit only your own files.

## 1. Similar section disappears after restarting Emacs

`supertag-semantic-enabled` defaults to nil and `supertag-semantic-rebuild`
asks "Enable for this session and index the vault?" then only `setq`s it.
After a restart the Node View `Similar` section silently disappears even
though the side-car index `supertag-semantic.el` is still on disk.

Fix: when the user accepts the prompt, persist the choice with
`customize-save-variable` (reword the prompt so it no longer says "for this
session"; keep the endpoint probe before persisting, so a failing endpoint
does not save t). Update the README / README_CN sentence that describes
enabling Similar notes if it says session-only. Test with a temp
`custom-file` that accepting writes the variable and declining does not.

## 2. Unlinked Mentions lists the same source many times

`supertag-mention-service--find-uncached` (supertag-mention.el) returns one
candidate per occurrence, and `supertag-view-mention-insert-section` renders
one card per candidate. Live example: target "Pi" shows 7 cards from only
3 source notes; "了解 Pi 的 control.ts" appears 4 times.

Fix in the view layer, keeping the service's per-occurrence records (the
[Link] command needs exact occurrences):

- Group candidates by `:source-id`, preserving first-appearance order.
  Render one card per source: the source title button, the excerpt of the
  first occurrence, and when there are more occurrences a muted
  `+N more` note (design.md grammar, `supertag-view-mute`). The section
  chip count is the number of sources, not occurrences.
- `[Link]` links the first occurrence (one link per source is enough to
  connect the notes); `[Ignore in node]` is per source already.
- `supertag-mention-max-results` currently caps occurrences, which can hide
  later sources behind one noisy source. Make the cap count distinct
  sources instead (collect all occurrences of a source once it is admitted).

Also exclude sources that already reference the target through an Org link
anywhere in the node, including its heading (live example: a note titled
`为什么 X 上发 [[id:…][Pi]] 的内容…` is listed as an unlinked mention of Pi).
Use the existing relation/reference query (e.g. the ordinary references
from the source, or `supertag-relation-find-between`) rather than
re-parsing text; check heading/title links are projected as references and,
if not, match the `[[id:TARGET]` form in the stored title as a fallback.

Update the result cache key/logic if the cap semantics change.

## Tests

ERT in the mention test file(s) (find them under test/): grouping renders
one card per source with `+N more`, chip count = sources, [Link] on a
grouped card links only the first occurrence, cap counts sources, an
already-linked source (heading link and body link) is excluded. Run the
mention and node-view suites before/after (`test/run-tests.sh <suite>`, see
test/renovation-suites.el) and compare failure names; byte-compile changed
files without new warnings.

## Report

`doc/report-node-view-similar-unlinked.md`, then commit.
