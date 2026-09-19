# Report: a merge must not set up an unsaved buffer to clobber remote edits

Branch `supertagV2`, **not committed** (working tree), as the brief requires.
Only `supertag-git.el` and `test/git-test.el` were touched; the parallel
worker's functions (`supertag-git-sync--pull`'s entry,
`supertag-git-sync--after-merge`'s failure branch, their tests and their new
`--merge-refused-warned` helpers) were left alone, and their in-flight work was
re-read before every edit.

## What changed (`supertag-git.el`)

1. `supertag-git-sync--unsaved-merge-files` (new) — the Org files a merge of
   `@{upstream}` would replace that are currently visited by a modified
   buffer: `git diff --name-only -z HEAD...@{upstream} -- '*.org'` (the upstream
   side since the merge base, which is exactly what a merge writes), expanded
   against the truenamed root so the paths match `supertag-git--project-files`.
2. `supertag-git-sync--unsaved-merge-warned` (new, warned-once flag) and
   `supertag-git-sync--merge-blocked-by-unsaved-p` (new helper) — one seam used
   by *both* merge call sites. It postpones the merge, reports once per episode
   which buffers hold the sync and that saving them lets it continue, and clears
   the flag as soon as none remains. It only reads `buffer-modified-p`; no
   buffer is reverted, saved, or killed, and nothing is stashed or reset.
3. `supertag-git-sync--push` — the rejected-push retry now runs the helper after
   its fetch and before its `merge --no-edit @{upstream}`: on a hold it clears
   `--in-flight` and returns, so the pending push stays pending (the lighter's
   `↑N` stays truthful) and nothing is reported as an offline failure.
4. `supertag-git-sync--pull` — same helper after the successful fetch and
   behind-check. On a hold it clears `--in-flight` and returns without merging
   *and without pushing* (a push while behind would only be rejected again);
   timers are untouched, so the next tick retries.
5. `supertag-git--project-files` — keeps its `(unless (buffer-modified-p))`
   guard as the second line of defence, and in that residual case (a buffer that
   became modified while the async merge ran) now emits
   `supertag-git-sync: <file> changed on disk while its buffer had unsaved edits;
   save it to reconcile` instead of staying silent. The buffer is still left
   alone.

Both merge call sites are the only two `merge --no-edit @{upstream}` forms in
the file, so `--pull` and `--push` cannot drift apart.

## Tests (`test/git-test.el`, directly after `supertag-git-pull-projects-exact-delta-and-orphans-deletion`)

Helpers: `supertag-git-test--messages` (capture), `supertag-git-test--peer-note`
(peer pushes `note.org`), `supertag-git-test--commit-owned` (commit whatever the
fixture/mode enable left, so these tests measure the unsaved-buffer decision
alone), `supertag-git-test--disk`, `supertag-git-test--postponed-messages`.

- `supertag-git-unsaved-buffer-postpones-merge` — unsaved `note.org`, peer
  pushed; two `--pull` ticks: HEAD unchanged, disk unchanged, buffer text
  intact and still modified, exactly one postponed message naming `note.org`,
  `--in-flight` nil, `--offline-warned` nil, no conflicts, no unmerged paths,
  pull timer still live.
- `supertag-git-unsaved-buffer-save-then-merge-continues` — after `save-buffer`
  + the commit path the flag is cleared, nothing is postponed, and the merge
  either landed clean (upstream..HEAD 0, both texts present) or paused on a real
  conflict with smerge-mode on.
- `supertag-git-unsaved-buffer-unrelated-file-does-not-postpone` — unsaved
  `unchanged.org` (not in the merge set): no hold, merge lands, buffer intact.
- `supertag-git-unsaved-buffer-postpones-rejected-push-retry` — owned local edit
  + unsaved `note.org`: commit → push rejected → fetch → hold. One postponed
  message, not offline, `--in-flight` nil, `--pending-push-count` > 0, ahead > 0,
  upstream has the peer's text, local file does not.
- `supertag-git-unsaved-buffer-residual-case-names-the-buffer` — direct
  `supertag-git--project-files` call with a modified buffer: the buffer is kept,
  its text intact, and the message names it.

All created buffers are killed (modified flags cleared first).

## Verification (native-comp-off `EMACS_BIN` wrapper, deps derived, batch only)

- `bash test/run-tests.sh git` → `Ran 39 tests, 39 results as expected, 0
  unexpected` (my five plus the parallel worker's tests and the pre-existing
  ones).
- Full `bash test/run-tests.sh` → **exit 0**: 34 suites, 1239 tests, 5 skipped,
  0 unexpected. This ran with the parallel worker's in-flight changes present;
  nothing failed in their functions or tests either.
- `bash test/static-gates.sh` → `Static O gates: PASS`, exit 0.
- Byte-compile of `supertag-git.el`: HEAD baseline 9 warnings, current 9
  warnings, **warning-set diff empty**, none mentioning the new functions. I
  compiled in scratch copies so no `.elc` was ever created in the repo (the
  parallel worker's runs must not pick up a newer `.elc`); the scratch `.elc`
  was deleted, and the repo has none.
- Negative control (scratch copy with the hold helper neutralised to always
  return nil): 3 of the 5 tests fail
  (`…-postpones-merge`, `…-postpones-rejected-push-retry`,
  `…-save-then-merge-continues`) and the 2 that must not depend on the hold
  still pass — so the tests pin the pre-merge guard, not just the end state.
- Before the fix the same tests fail the same way (the guard is what makes them
  pass), and the guarded paths are exactly the two `git merge` invocations.

## Chosen not to do

- No new resolution UI and no change to the conflict/`smerge` path: the fix
  funnels the dangerous case into the existing commit → push → fetch → merge
  route, as the brief asked.
- `supertag-git--pause` (not mine, and not broken) still calls `find-file` on
  the conflicted file, which can raise Emacs's stock "File … changed on disk.
  Reread from disk?" prompt when that buffer is modified. That is pre-existing
  stock protection, not part of this bug; the test answers that prompt the way
  an interactive user would (reread), and the local text is already committed by
  then. Reported here instead of changed, since the brief scoped me to the two
  merge call sites, the pre-merge helper, `--project-files`, and the new flag.
- Nothing was committed, and no `.elc` or scratch file was left in the repo.

DONE: doc/report-git-unsaved-buffer-merge.md — a merge now waits while a file it would replace has unsaved edits, reporting once which buffers hold it, instead of leaving a later save free to revert the other machine's work.
