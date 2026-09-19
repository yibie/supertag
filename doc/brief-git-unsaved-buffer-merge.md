# Brief: a merge must not set up an unsaved buffer to clobber remote edits

Bounded bug fix in `supertag-git.el`. No redesign of the transport.

## The bug

After a successful merge, `supertag-git--project-files` reverts each changed
file's buffer only `(unless (buffer-modified-p) ...)`. A buffer with unsaved
edits is left alone — correct, we must not throw the user's typing away — but
the file underneath it has now been replaced by the merged version. From there
the only protection is Emacs's stock "file changed on disk; save anyway?"
prompt. If the user answers yes, the buffer's stale text overwrites the merged
file, the next auto-commit records that, and **the other machine's edits are
silently reverted** (recoverable only from git history). Supertag's own sync
caused this and says nothing.

The same hole exists at both merge call sites: the periodic one in
`supertag-git-sync--pull` and the rejected-push retry in
`supertag-git-sync--push`.

## Contract after the fix

Recommended shape (argue in the report if you find a better one, but keep it
this small):

1. **Do not merge underneath an unsaved buffer.** After a successful fetch and
   before running `merge`, compute the Org paths the merge would touch
   (`git diff --name-only -z HEAD...@{upstream} -- '*.org'` or equivalent) and
   check whether any of them has a live buffer with `buffer-modified-p`. If so,
   **postpone the merge for this cycle**: skip it, clear `--in-flight`, leave
   timers running, and tell the user once per episode which files are holding
   the sync and that saving them lets it continue. Follow the existing
   one-message-per-state pattern (`--offline-warned`,
   `--conflict-commit-warned`), and clear the flag when the condition ends.
2. Once the user saves, the normal path takes over: after-save → debounce
   commit → push rejected → fetch + merge, which is now a real three-way merge
   ending either clean or in the existing conflict-pause / smerge path. The
   point of this fix is to funnel the dangerous case into that already-safe
   path, not to build a new resolution UI.
3. Put the check in **one helper used by both merge call sites**, so `--pull`
   and `--push` cannot drift apart.
4. When a merge is postponed in the `--push` retry path, the pending push stays
   pending (the lighter's `↑N` remains truthful) and is retried on a later
   cycle — do not report it as an offline failure.
5. Never revert, kill, or save the user's buffer on their behalf. Never stash
   or reset. Local text stays sovereign.
6. `supertag-git--project-files` keeps its `(unless (buffer-modified-p))`
   guard as a second line of defence (a buffer can become modified while the
   async merge runs). In that residual case emit a message naming the buffer
   instead of staying silent.

## Tests

Add to `test/git-test.el`, **directly after
`supertag-git-pull-projects-exact-delta-and-orphans-deletion`**, names prefixed
`supertag-git-unsaved-buffer-`. Use `supertag-git-test-with-vault` (it gives
`root`, `bare`, `peer`). At minimum:

- peer pushes an edit to `note.org`; locally `note.org` is visited and the
  buffer modified but unsaved; `supertag-git-sync--pull` → HEAD unchanged (no
  merge), file on disk unchanged, buffer text intact and still modified, a
  message emitted once across two ticks, `--in-flight` nil, nothing paused.
- then save the buffer and run the commit path → merge happens (clean or
  paused, depending on your fixture) and the postponed flag is cleared.
- an unsaved buffer on a file the merge does **not** touch does not postpone
  anything.
- the rejected-push retry path honours the same guard.

Kill any buffers you create in tests.

## Coordination — another worker is in this file right now

A second worker is fixing a different bug in parallel (brief:
`doc/brief-git-dirty-tree-merge.md`). It owns: the entry of
`supertag-git-sync--pull` (committing saved local edits before the merge
decision), the failure branch of `supertag-git-sync--after-merge` (reporting a
refused merge), and tests placed after
`supertag-git-retained-diverged-pull-cycle`.

You own: the new pre-merge helper, the two `merge --no-edit @{upstream}` call
lines that it replaces, `supertag-git--project-files`, any new warned-once
variable, and your tests. Re-read the file before each edit since it changes
under you. If a test failure is clearly inside the other worker's functions or
tests, note it in your report and do not fix it.

**Do not commit.** Leave your changes in the working tree; the coordinator
splits and commits both fixes after review.

## Verification

- `bash test/run-tests.sh git` while iterating; full `bash test/run-tests.sh`
  and `bash test/static-gates.sh` at the end.
- Byte-compile `supertag-git.el` clean; delete your `.elc` afterwards.
- Batch only. Never drive the user's running Emacs (no emacsclient).
- Branch is `supertagV2`.

## Report

Write `doc/report-git-unsaved-buffer-merge.md`: what changed, which functions,
test names, verification output counts, anything you chose not to do. Last
line `DONE:` plus one sentence, or `BLOCKED: <reason>` if you need a ruling —
then end your turn. The coordinator is watching your state and reads the
report; do not relay through other workers.
