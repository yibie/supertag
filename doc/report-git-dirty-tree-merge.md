# Report: a pull no longer silently fails on saved-but-uncommitted Org edits

Brief: `doc/brief-git-dirty-tree-merge.md`. Branch `supertagV2`. **Not
committed**: the changes sit in the working tree next to the other worker's, as
the brief instructs. Batch only, no emacsclient; nothing was ever run against
`/Users/chenyibin/Documents/notes`.

`test/git-test.el` in the working tree also carries the other worker's five
`supertag-git-unsaved-buffer-*` tests and their guard; the git suite is green
with both fixes in place (see Verification). Their transient failures I
measured mid-flight, and their causes, are in "Coordination" below.

## What changed

My additions are 61 lines in 5 hunks of `supertag-git.el`:

1. **`supertag-git-sync--pull` (entry only)** -- before the fetch chain, a new
   guarded step:

   ```elisp
   (when (and supertag-git-sync--vault-root (not supertag-git--conflicted-files)
              (not supertag-git-sync--in-flight)
              (supertag-git-sync--owned-changes-p supertag-git-sync--vault-root))
     (supertag-git-sync--fire-commit))
   ```

   That is the same route `supertag-git-sync-now` already takes
   (`owned-changes-p` -> `--fire-commit`), so there is no second commit path:
   `--fire-commit` keeps every guard it has (index scope via
   `supertag-git--assert-index-scope`, staged conflict markers, unmerged paths,
   `supertag-git-sync--in-flight` serialization) and its own push falls back to
   fetch + merge + retry when the remote moved on. The pre-existing fetch /
   merge / push block below is byte-identical, including the
   `merge --no-edit @{upstream}` line (the other worker owns those call sites).
   The `--pull` docstring gains a paragraph explaining this step.
2. **`supertag-git--editor-ephemera-path-p` (new) + `supertag-git-sync--auto-commit-path-p`**
   -- Emacs lock files (`.#note.org`), auto-save files (`#note.org#`) and
   backup files (`note.org~`) are no longer treated as owned Org text. This is
   not optional for the step above: see "Why the lock-file guard is part of
   this fix".
3. **`supertag-git-sync--merge-refused-warned` (new) plus
   `supertag-git-sync--note-merge-refused` and
   `supertag-git-sync--clear-merge-refused-warning`** -- the warned-once state,
   modelled directly on `--offline-warned` / `--conflict-commit-warned`.
4. **`supertag-git-sync--after-merge`** -- a third `cond` branch. When the
   merge neither paused on a live Org conflict nor succeeded, it now reports
   through the existing `supertag-git-sync--report-failure` (git's own text,
   local-safety summary, "No local data was discarded", how to retry), once per
   episode. The two existing branches clear the warning, so the next episode
   speaks again.

Also 111 lines in `test/git-test.el`: three tests and one base helper, placed
directly after `supertag-git-retained-diverged-pull-cycle`:

- `supertag-git-dirty-merge-commits-saved-edits-before-merging`
- `supertag-git-dirty-merge-pauses-on-an-overlapping-edit`
- `supertag-git-dirty-merge-reports-a-refused-merge-once`

## Contract check

| requirement | how it is met |
|---|---|
| saved Org edits are committed before a merge is attempted | pull entry routes to `--fire-commit` first; its rejected push is the `--pull`/`--push` merge site, now fed by a real three-way merge |
| a merge with no unmerged paths is never silent | `--after-merge`'s new branch reports via `--report-failure`, once per episode |
| `--in-flight` cleared exactly once per branch | unchanged: the routing hands off to `--fire-commit`, which clears it on every branch it owns; the `--pull` block keeps its own clears; all three new tests assert it ends nil |
| nothing stashed, reset or checked out | no stash/reset/checkout anywhere; local text untouched |

## Tests, and their pre-fix failure

All three fail on pristine `HEAD` and pass with the fix. Measured by exporting
`HEAD` into a throwaway directory (`git archive HEAD | tar -x -C /tmp/...`,
plus my `test/git-test.el`), so the shared working tree -- and the other
worker's edits in it -- were never touched:

```
   FAILED   4/38  supertag-git-dirty-merge-commits-saved-edits-before-merging
   FAILED   5/38  supertag-git-dirty-merge-pauses-on-an-overlapping-edit
   FAILED   6/38  supertag-git-dirty-merge-reports-a-refused-merge-once
Ran 38 tests, 32 results as expected, 6 unexpected
```

(The other three failures in that run are the other worker's tests failing
against unfixed `HEAD`, which is expected.)

Test 1 needed one correction during development: my first version changed two
*adjacent* lines, which git merges as a single hunk and therefore conflicts.
The base fixture now separates the two edit sites by four unchanged lines, so
"non-overlapping" really is non-overlapping.

## Why the lock-file guard is part of this fix

Measured with a probe (`--owned-changes-p` and `git status` at each step):

```
PROBE with-dirty-buffer: modified=t owned=t
PROBE pathspecs=(":(literal).#note.org" ":(literal)delete.org" ":(literal)note.org" ...)
PROBE status="?? .#note.org"
PROBE head-before=9f0378e...  PROBE head-after=b4049db...
PROBE log=b4049db supertag-sync: <host> 2026-09-18T23:17:54-0700
```

Any Org buffer open in the vault has an Emacs lock symlink `.#note.org` next to
it, and `.#note.org` ends in `.org`, so `--auto-commit-path-p` called it owned
text. That is pre-existing, but the new pull-entry step turns it from a rare
debounce race into "every pull tick while the user is editing commits a lock
file": HEAD moves, history gains a symlink, and (as the probe shows) the
workflow cannot settle. The guard is three name patterns and applies to the
debounce path too, so `--fire-commit` can no longer commit editor ephemera.
Real Org backups the tests care about (`*backup*.org`, deleted files,
`.gitignore`) are unaffected -- the whole `git` suite plus the `repair-*`
contracts are green.

## Coordination

The other worker's tests are not mine to touch, and they now pass. Two of them
failed for a while mid-flight; attribution, measured with probes rather than
assumed:

- `supertag-git-unsaved-buffer-postpones-rejected-push-retry` reached its
  postponed-retry assertion (their message count 1) *only* because
  `.#note.org` was being staged and committed: with my ephemera guard active
  the same scenario yields `postponed=0`; with the guard disabled at runtime
  (`cl-letf` on `supertag-git--editor-ephemera-path-p`) it yields `postponed=1`
  and a `supertag-sync:` commit in the log. Their test now writes a genuinely
  saved owned edit (`supertag-git-test--commit-owned` + `local.org`), which is
  the correct setup, and passes.
- `supertag-git-unsaved-buffer-save-then-merge-continues` never involved my
  routing: in its unsaved-buffer state `owned-changes-p` is nil, my pull step
  does not fire, HEAD does not move, their postpone flag is set and nothing is
  conflicted (`PROBE B head-moved-by-pull=nil`). Its failure lived entirely in
  their own path and they resolved it.

## Verification

```
Suite: git -> Ran 39 tests, 39 results as expected, 0 unexpected
```

`bash test/run-tests.sh` (full): **34 suites, 1239 tests, 1234 as expected,
5 skipped, 0 unexpected, exit 0**. `bash test/static-gates.sh`: `Static O
gates: PASS`, exit 0. `byte-compile-file` on `supertag-git.el`: no warning or
error for that file, and the `.elc` was deleted afterwards (no root `.elc`
left; the gate that forbids them passed).

## Chosen not to do

- No second commit path, no new resolution UI, no stash/reset/checkout.
- Did not touch the two `merge --no-edit @{upstream}` call sites, the
  pre-merge guard helper, `supertag-git--project-files`, or the other worker's
  tests.
- Did not restructure `--pull` into a single `if`/`cond`: that would have
  re-indented the shared merge call and invited a conflict with the other
  worker's edit there. Consequence, measured: with
  `supertag-git-sync--synchronous` bound (batch tests), `--fire-commit` runs to
  completion before the fetch chain's own `--in-flight` check, so a test can
  see one extra no-op cycle; production runs asynchronously and the flag
  suppresses it. Documented here rather than papered over.
- Did not cache the owned-changes check: it costs one `git ls-files` plus one
  `git status` per pull tick when idle. That is the price of looking before
  merging; the timer interval makes it negligible, but it is new traffic.

DONE: fixed the silent dirty-tree merge refusal by committing owned Org edits through the existing `--fire-commit` path at the pull entry, reporting refused merges once per episode from `--after-merge`, and keeping Emacs lock/auto-save/backup files out of auto-commit.
