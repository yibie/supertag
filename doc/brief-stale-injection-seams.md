# Brief: test injection seams left stale by two performance refactors

5 failing tests across two files. Both groups have the same shape: a test
stubs a function to inject a failure or count calls, a performance refactor
moved the production path off that function, and the stub now never fires. The
product behaviour is intact in both cases — only the observation point is
stale.

This is the third instance of this class in this repo, so treat the pattern as
known: `54d350f` and `6aad163` both fixed it by re-pointing the injection at
the real shared seam, and that is the precedent to follow.

---

## Group 1 — `test/automation-tag-action-test.el` (3 tests)

```
supertag-automation-add-projection-failure-is-retryable
supertag-automation-add-draft-repair-projection-failure-is-retryable
supertag-automation-tag-actions-repeat-through-service-noop
```

Symptoms: the first two get `caught` = nil where they expect
`supertag-projection-error` — no error raised at all. The third expects
`'(save project save project)` and gets `'(save save)` — the `project` calls
never happen.

Cause: all three `cl-letf` a stub onto `supertag-service-org--project-current-node`
(around lines 176, 209, 281). Commit `8b020d3` (2026-09-12, *"perf(tag): record
boundary tags node-locally instead of re-projecting the whole file"*) added a
`tags-only-p` branch to `supertag-service-org--update-buffer-and-resync`
(`supertag-service-org.el:975-1002`):

```elisp
(funcall (if tags-only-p
             #'supertag-service-org-save-and-record-tags-at-point
           #'supertag-service-org-save-and-project-current-node)
         node-id)
```

add-tag / remove-tag take the `tags-only-p` branch, and
`supertag-service-org-save-and-record-tags-at-point`
(`supertag-service-org.el:1392-1447`) never calls `--project-current-node`; it
refreshes membership inline via `supertag-sync--resolve-node-tag-occurrences`
+ `supertag-node-update`, wrapped in `condition-case` →
`--signal-projection-error`. The draft-repair test takes the repair branch at
`:984-:988`, routed the same way for the same reason.

`8b020d3` updated six test files but missed this one (its last touch was
`0997073`, 2026-09-10). That is the moment of divergence.

Membership projection still happens — `supertag-automation-tag-real-trigger-writes-org`
and `supertag-automation-add-tag-obeys-live-org-when-db-says-present` pass and
assert the DB `:tags` really change. The retry contract is intact too.

Fix (~10 lines, tests only):

1. `add-projection-failure-is-retryable` — move the stub from
   `--project-current-node` to `supertag-sync--resolve-node-tag-occurrences`.
   Every other assertion stays byte-for-byte.
2. `add-draft-repair-projection-failure-is-retryable` — same substitution;
   `(should (= 1 saves))` still holds.
3. `tag-actions-repeat-through-service-noop` — count
   `supertag-service-org-save-and-record-tags-at-point` instead, and expect
   `'(record save record save)`. The order inverts because the save happens
   *inside* the recorder; that is not a bug, and a one-line comment saying so
   will save the next reader.

A prior investigation verified this shape works before you start: injecting at
the new seam reproduces `supertag-projection-error` with `:retry` /
`:retry-args` intact, durable disk text, and membership restored after
`apply`ing the retry.

Do not add a new indirection to the product just to give tests a stable hook.
`save-and-record-tags-at-point` is a good enough seam.

---

## Group 2 — `test/move-node-ui-test.el` (4 tests, two causes)

```
move-node-ui-capture-cold-reachability
move-node-ui-capture-commands-preloaded-reachability
move-node-ui-node-first-call-real-write
move-node-ui-node-first-call-real-write-and-link
```

All four share the helper `move-node-ui-test--node-d-cold` (line 480), whose
child exits on the first failed `should`, so one cause hides the other.

**Cause A — affects all 4.** Line 481 builds the fixture root from a raw
`make-temp-file`; on macOS that is `/var/folders/…` while the implementation
deliberately stores the truenamed `/private/var/…` (`supertag-service-org.el:567`,
`supertag-services-sync.el:2500-2503`). Line 621's
`(should (equal destination (plist-get (supertag-node-get id) :file)))` fails on
the prefix alone — the move itself succeeds (`1 node(s) successfully moved to
target.org.` appears in the same output).

Fix: `(tmp (file-truename (make-temp-file "supertag-node-d-" t)))`, matching
`test/move-nodes-position-test.el:61` and the other fixtures in this repo.

**Cause B — affects the 2 `node-first-call-real-write*` tests, and it is ours.**
They advise `supertag-service-org-retry-node-projection` to count projections
(lines 560, 565, 599). Commit `54d350f` moved the move path onto
`supertag--project-nodes-from-org-text` + `supertag-sync--reconcile-node`, so
the advised function is no longer called and the count is 0 — line 638's
`(should (= (if (eq nd-spec 'link) 2 1) (length projects)))` fails.

`54d350f` updated `move-node-safety-test.el` and `promote-workflow-test.el` but
missed this file, and Cause A kept the regression invisible.

Fix: move the observation point to `supertag-sync--reconcile-node`
(signature `(props &optional counters)`, count `(plist-get props :id)`),
exactly as `54d350f` did for `move-node-safety-test.el`. A prior check confirms
the counts remain 1 and 2, so line 638's expected values need no change. The
semantics shift slightly — you are now counting reconciled headings rather than
provider invocations — so note that in a comment.

Say in the commit message that this is a follow-up to `54d350f`, not a
behaviour fix.

---

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
EMACS_BIN=<wrapper> bash test/run-tests.sh automation-actions move
```

Expect automation-actions 3→0 unexpected and move 4→0.

The wrapper is required on this machine — plain `emacs -Q --batch` aborts on
any `fset` onto a subr because libgccjit cannot link
(`ld: library 'emutls_w' not found`):

```sh
exec emacs --eval '(setq native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil)' "$@"
```

Because Cause A is a macOS-symlink artifact, also confirm the suites pass with
`TMPDIR` pointed at a non-symlinked directory, so the fix is genuine rather
than environment-lucky. Do **not** canonicalise `TMPDIR` in the harness — a
separate agent is fixing a real product defect that such a change would mask.

## Scope

Only `test/automation-tag-action-test.el` and `test/move-node-ui-test.el`. Do
not touch any `supertag-*.el`, nor `test/vault-test.el`,
`test/add-link-workflow-test.el`, `test/sync-worker-regression-test.el` or
`test/node-feature-test.el` — other agents hold those in parallel. Branch is
`supertagV2`. Batch verification only; never drive the user's running Emacs.
