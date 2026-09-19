# Brief: a pull must not silently fail on saved-but-uncommitted Org edits

Bounded bug fix in `supertag-git.el`. No redesign of the transport.

## The bug

`supertag-git-sync--pull` runs `fetch`, then `merge --no-edit @{upstream}` when
behind. It never looks at the working tree first. Auto-commit is debounced
(`supertag-git-sync-commit-debounce`, 30 s), so there is a routine window where
an Org file is saved but not yet committed. If a pull tick (timer or focus)
lands in that window and upstream changed the same file, git refuses:

```
error: Your local changes to the following files would be overwritten by merge
```

That is neither a conflict nor a success, so `supertag-git-sync--after-merge`
does nothing: no unmerged paths, result not ok, **no message at all**. The cycle
then falls through to `supertag-git-sync--maybe-push-after-cycle`. The user sees
nothing; the merge just did not happen. It only self-heals later, when the
debounce commit fires and its push is rejected.

## Contract after the fix

1. **Saved local Org edits are committed before a merge is attempted**, so the
   merge is a real three-way merge: it either merges cleanly or lands in the
   existing conflict-pause path (`supertag-git--pause` → smerge →
   `supertag-git-sync-now`). `supertag-git-sync-now` already routes this way
   (`owned-changes-p` → `supertag-git-sync--fire-commit`, whose rejected push
   does fetch + merge + retry). Reuse that path from the pull cycle rather than
   inventing a second one. Keep every existing guard `--fire-commit` has
   (index scope, staged markers, unmerged paths, `--in-flight` serialization).
2. **A merge that fails without producing unmerged paths is never silent.**
   This can still happen (e.g. a tracked non-Org file is dirty locally and
   changed upstream — we do not own it and must not commit it). Report it
   through the existing failure reporting (`supertag-git-sync--report-failure`
   style: git's own text, "no local data was discarded", how to retry), once
   per episode rather than once per tick — follow the
   `--offline-warned` / `--conflict-commit-warned` one-message-per-state pattern.
3. `--in-flight` is still cleared exactly once on every branch.
4. Nothing is ever stashed, reset, or checked out. Local text stays sovereign.

## Tests

Add to `test/git-test.el`, **directly after
`supertag-git-retained-diverged-pull-cycle`**, names prefixed
`supertag-git-dirty-merge-`. Use `supertag-git-test-with-vault` (it gives
`root`, `bare`, `peer`). At minimum:

- peer pushes an edit to `note.org`; local has a saved, uncommitted, *non-
  overlapping* edit to `note.org`; one `supertag-git-sync--pull` → both edits
  end up in HEAD, working tree clean, nothing paused.
- same but *overlapping* edits → the vault is paused with `note.org` in
  `supertag-git--conflicted-files` (the normal conflict path), not a silent
  no-op.
- a merge refused because of a dirty tracked non-Org file → a message is
  emitted (capture `message`), emitted once across two pull ticks, and
  `supertag-git-sync--in-flight` ends nil.

## Coordination — another worker is in this file right now

A second worker is fixing a different bug in parallel (brief:
`doc/brief-git-unsaved-buffer-merge.md`). It owns: a new pre-merge guard helper
that wraps the two `merge --no-edit @{upstream}` call sites (in `--pull` and in
`--push`), `supertag-git--project-files`, and tests placed after
`supertag-git-pull-projects-exact-delta-and-orphans-deletion`.

You own: the entry of `supertag-git-sync--pull` (before the fetch / before the
merge decision), the failure branch of `supertag-git-sync--after-merge`, any
new warned-once variable, and your tests. Do not rewrite the merge call lines
themselves, and re-read the file before each edit since it changes under you.
If a test failure is clearly inside the other worker's functions or tests,
note it in your report and do not fix it.

**Do not commit.** Leave your changes in the working tree; the coordinator
splits and commits both fixes after review.

## Verification

- `bash test/run-tests.sh git` while iterating; full `bash test/run-tests.sh`
  and `bash test/static-gates.sh` at the end.
- Byte-compile `supertag-git.el` clean; delete your `.elc` afterwards.
- Batch only. Never drive the user's running Emacs (no emacsclient).
- Branch is `supertagV2`.

## Report

Write `doc/report-git-dirty-tree-merge.md`: what changed, which functions, test
names, verification output counts, anything you chose not to do. Last line
`DONE:` plus one sentence, or `BLOCKED: <reason>` if you need a ruling — then
end your turn. The coordinator is watching your state and reads the report;
do not relay through other workers.
