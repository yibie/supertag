# Brief: remove the quadratic reprojection in Promote (fix A)

## Problem, measured

`supertag-promote` freezes Emacs after the confirmation prompt. The freeze is
in `supertag-service-org--retry-move-projection` (`supertag-service-org.el:540`).

It walks every ID-bearing heading of the source and target files and calls
`supertag-service-org-retry-node-projection` once per heading. That leads to
`supertag--parse-node-at-point` (`supertag-services-sync.el:2468`), which — as
its own docstring admits — copies the **whole file** into a temp buffer, runs
`org-mode`, parses **every** node, and then returns just the one requested.

So one Promote costs `headings x whole-file-parse`. Measured on the real vault
(1822 nodes):

| file | size | ID headings | one parse | whole-file reprojection |
|---|---|---|---|---|
| source.org | 39KB | 3 | 0.019s | 0.1s |
| hangji__project.org | 55KB | 25 | 0.046s | 1.2s |
| 2026.org | 120KB | 431 | 0.273s | ~117s |
| diary.org | 231KB | 471 | 0.31s | ~145s |

Ordinary saves do not suffer this: `supertag-sync--run-on-save` enqueues async
work. `supertag-service-org--move-save` deliberately removes that hook and the
Promote path pays the cost synchronously on the main thread instead.

## The fix

Parse each file **once**, then reconcile all of its nodes. The efficient shape
already exists in `supertag-sync--process-single-file`
(`supertag-services-sync.el:1218`): parse once with
`supertag--parse-org-nodes-from-current-buffer`, then
`supertag-sync--reconcile-node` per node.

Suggested shape, but you own the details:

1. In `supertag-services-sync.el`, factor the whole-file projection out of
   `supertag--project-node-from-org-text` into a sibling that returns **all**
   parsed nodes for the given source text (same scratch-buffer isolation, same
   carried-over `org-todo-keywords-1` / `org-todo-regexp` /
   `org-not-done-regexp` / `org-complex-heading-regexp` /
   `org-todo-line-regexp` / `tab-width` locals). Re-express
   `supertag--project-node-from-org-text` as that call plus the existing
   `cl-find`, so single-node behaviour is provably unchanged.
2. In `supertag-service-org.el`, rewrite `supertag-service-org--retry-move-projection`
   to reproject each file with one parse and reconcile each node, all still
   inside the single `supertag-with-transaction` that covers every file.

## Invariants you must not break

- **One transaction** still covers all files, as the current docstring promises.
- **The scratch-buffer isolation stays.** The parser strips embed blocks
  destructively; that must never reach the user's live buffer. Keep parsing a
  copy of the text, never the visited buffer itself.
- **Only heading nodes are reprojected.** Today `org-map-entries` never visits
  the level-0 file node, so the file node is not reprojected here. Preserve
  that: do not start upserting file nodes in this path.
- **No deletions.** Unlike `supertag-sync--process-single-file`, this path must
  not mark nodes deleted, not even ones now absent from the file. It only
  reprojects what is present.
- **`supertag-service-org-retry-node-projection` keeps its signature and
  behaviour.** It is the per-node retry entry point named in error payloads
  (`:retry` / `:retry-args`) by the Promote and Move recovery contract. Leave it
  alone; a single-node retry may stay whole-file-parse-expensive.
- Error signalling from this path keeps its current shape, so
  `supertag-service-org--signal-projection-error` callers and the
  `supertag-projection-error` recovery flow still work.

## Verification (all of it, and paste the output)

```sh
bash test/run-tests.sh promote move saved-projection contract
```

Byte-compile clean (no new warnings):

```sh
emacs -Q --batch -L . -f batch-byte-compile supertag-service-org.el supertag-services-sync.el
```

Then delete the `.elc` files you produced.

Add a **performance regression test** that would have caught this: build a
temp Org file with, say, 60 ID-bearing headings, call
`supertag-service-org--retry-move-projection` on it, and assert the number of
whole-file parses is proportional to files, not to headings — e.g. count calls
by advising/`cl-letf`-ing the parse entry point and asserting it runs once per
file. Do not assert wall-clock seconds; count parses. Put it wherever the
promote or saved-projection suite will pick it up.

Also report the before/after timing you measure yourself on a generated
60-heading file.

## Scope

Touch only `supertag-service-org.el` and `supertag-services-sync.el`, plus the
test file. Another agent is editing `supertag-concept.el` in parallel — do not
touch that file. Do not modify anything outside this repository. Do not drive
the user's running Emacs (no emacsclient); batch verification only.
