# Brief: realtime sync silently dies when a sync directory is behind a symlink

This is the only genuine product defect found in the current test triage. The
other open failures are test-side; this one affects real users.

## The defect

`supertag-sync--run-on-save` (`supertag-services-sync.el:2410-2430`) canonicalises
the saved file before testing scope:

```elisp
(file-norm (and file (file-truename (expand-file-name file))))
(when (and file-norm (supertag-sync--in-sync-scope-p file-norm)) ...)
```

But `supertag-sync--in-scope-path-p` (`supertag-services-sync.el:473-494`), which
does the actual matching, canonicalises neither side with `file-truename` — it
uses `expand-file-name` on the file **and** on each configured directory:

```elisp
(cl-some (lambda (dir) (string-prefix-p (expand-file-name dir) file-dir)) sync-dirs)
```

So a truenamed path is prefix-matched against a non-truenamed configured
directory. When they differ, the match fails and the save is dropped in
silence: no enqueue, no state update, no message.

Observed directly by instrumenting the on-save hook:

```
PROBE on-save file="/private/var/.../target.org" org=org-mode scope=nil internal=nil
                dirs=("/var/folders/.../supertag-node-feature-YaNMzY/")
```

## Why it matters to users

Any `supertag-sync-directories` entry that passes through a symlink — the
common `~/org -> /mnt/data/org`, or an iCloud/Dropbox-style indirection, or
macOS's own `/var -> /private/var` — silently disables realtime after-save sync
while periodic scanning keeps working. That half-working state is much harder
to diagnose than an outright failure.

The codebase is already internally inconsistent about this:
`supertag-git--ancestor-p` (`supertag-git.el:55-59`) truenames both sides and
gets it right, and the comment above it at `supertag-git.el:49` states outright
that *"Using `file-truename' (not just `expand-file-name') matters on macOS."*

History: the `file-truename` on the caller side came in with `a5f7917`
(2025-12-18); the scope predicate reached its current form in `c90e2d4`
(2025-12-29). The two were never reconciled.

## The fix

Make `supertag-sync--in-scope-path-p` symmetric, mirroring
`supertag-git--ancestor-p`: canonicalise the file path and every entry of
`supertag-sync-directories` and `supertag-sync-exclude-directories` through
`file-truename` before the `string-prefix-p` comparison.

Two constraints to respect:

1. **The predicate is documented as not requiring the file to exist.**
   `file-truename` on a non-existent path still resolves its existing
   ancestors, so the contract survives — but add a test that pins it, so the
   guarantee is not silently lost later.
2. **This predicate runs per file during full scans.** Do not call
   `file-truename` on each configured directory once per file. Hoist or cache
   the canonicalised directory list so the cost stays proportional to the
   number of files, not files x directories. Say in the commit message which
   approach you chose.

## Verification

The regression test already exists and currently fails:

```
supertag-node-feature-compat-create-real-positions-draft-hooks   (test/node-feature-test.el)
```

Its inner assertion (visible only when `ert-batch-print-level` is raised — the
outer `condition-case` swallows it) is:

```elisp
(when (eq mode 'hook) (should (member (file-truename file) supertag-async--queue)))
```

Run:

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
EMACS_BIN=<wrapper> bash test/run-tests.sh contract saved-projection
```

Expect `contract` to go from 1 unexpected to 0. **Do not** touch
`test/node-feature-test.el` to make it pass — the test is correct and the
product is wrong. If you find yourself editing that test, stop and re-read.

Add a test for the symlink case directly: a sync directory reached through a
symlink must enqueue on save. That is the behaviour users are losing, and
nothing currently covers it.

Note `saved-projection`'s `supertag-sync-syb-git` failure is test-side and
belongs to another agent — it should still be failing when you are done, unless
your product fix happens to resolve it, in which case say so explicitly.

## Environment

`emacs -Q --batch` on this machine aborts on any `fset` onto a subr because
libgccjit cannot link (`ld: library 'emutls_w' not found`), producing dozens of
phantom failures. Use an `EMACS_BIN` wrapper:

```sh
exec emacs --eval '(setq native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil)' "$@"
```

Do **not** "fix" this by canonicalising `TMPDIR` in the test harness. That
would mask this very defect. It is only acceptable as an extra guard after the
product fix lands.

## Scope

`supertag-services-sync.el`, plus new tests. Do not touch
`test/vault-test.el`, `test/add-link-workflow-test.el`,
`test/sync-worker-regression-test.el`, `test/move-node-ui-test.el` or
`test/automation-tag-action-test.el` — two other agents are editing those in
parallel. Branch is `supertagV2`. Batch verification only; never drive the
user's running Emacs.
