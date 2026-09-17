# Brief: test fixtures compare raw temp paths against canonicalised ones

24 of the repo's 28 currently-failing tests come from this one omission.

## The defect

Product code deliberately canonicalises paths with `file-truename`:

- `supertag-vault.el:71` — `supertag-vault-selection-normalize-path`
- `supertag-vault.el:155` — `supertag-vault--find-by-file`
- `supertag-service-org.el:116, 567, 889`
- `supertag-git.el:898-908` — `supertag-git--project-files`

This is intentional and documented. `supertag-git.el:49` says so outright:
*"Using `file-truename' (not just `expand-file-name') matters on macOS."*

Several test fixtures build their root from a raw `make-temp-file`, which on
macOS returns `/var/folders/…` — and `/var` is a symlink to `/private/var`.
They then embed that raw string as the **expected** value. The product returns
`/private/var/…`, `equal` fails, and the test dies on a path mismatch before
ever reaching the contract it was written to check.

Every failure reduces to the same shape:

```
:form (equal ("/var/folders/.../b/")
             ("/private/var/folders/.../b/"))
:explanation (arrays-of-different-length 70 78 ... first-mismatch-at 1)
```

This has nothing to do with any refactor. The `file-truename` calls predate the
tests, and **the repo already has the correct idiom in six other places** —
`test/promote-workflow-test.el:12`, `test/stream-workflow-test.el:14`,
`test/document-fixture.el:15`, `test/node-view-test.el:11`,
`test/text-link-node-view-test.el:24,289` all write
`(file-truename (make-temp-file …))`. These fixtures simply never adopted it.

CI has never caught it: `.github/workflows/test.yml:75` pins `TMPDIR: /tmp` on
`ubuntu-latest`, which has no such symlink. These suites have most likely never
been green on macOS since the day they were added.

## Your scope: three files, 24 tests

### 1. `test/vault-test.el` — 8 tests (`supertag-vault-vd-*`)

All 8 fail on one shared assertion in the vd child script's common prologue,
before each test's own contract is reached:

```elisp
(should (equal (list b) (supertag-sync--effective-directories)))
```

Fix at **line 654**:

```elisp
(tmp (make-temp-file "supertag-vd-" t))
;; ->
(tmp (directory-file-name (file-truename (make-temp-file "supertag-vd-" t))))
```

Everything (`tree`, `a`, `b`, `base`, `VD_TMP`) derives from `tmp`, so one edit
aligns all of it. Line 697's `(setq default-directory (file-truename default-directory))`
becomes redundant; removing it is optional, but say what you did.

### 2. `test/add-link-workflow-test.el` — 11 tests (`la-`/`va-`/`vb-`)

Three separate child harnesses, same omission. Wrap each fixture root:

- **line 23** — `supertag-add-link-test--isolated` (`"supertag-add-link-test-"`)
- **line 2355** — `supertag-add-link-test--va-child` (`"supertag-va-"`)
- **line 2608** — `supertag-add-link-test--vb-child` (`"supertag-vb-"`)

For `va-`/`vb-`, the parent-level failure you see is only the child's exit code
(`(should (equal 0 status))`); the real assertion is in the child's
`VA-ERROR`/`VB-ERROR` line on stdout.

The same file has further `make-temp-file` sites at lines 315, 420, 453, 1501,
1887, 2124. They pass today only because they never compare against a
truenamed path — latent instances of the same trap. Fix them too for
consistency, and say so.

### 3. `test/sync-worker-regression-test.el` — 1 test (`supertag-sync-syb-git`)

The visible failure is the wrapper `(should (equal 0 status))` → `0` vs `255`
at line 599; the real assertion is inside the child program
(`supertag-sync-worker-test--syb-program`, the `defconst` from ~line 467):

```elisp
(should (equal (list file) supertag-async--queue))
```

`supertag-git--project-files` truenames before enqueuing (correct); the
expected value derives from the raw `SYB_TMP`. Canonicalise the temp root once
in the child, after reading the env and before `root`/`file`/`data`/`state-file`
are derived — that also protects the later `state-file` and
`supertag-find-nodes-by-file` assertions in the same case. Only the `git` case
truenames, which is why its siblings pass.

## What this is NOT

Do not change product code. Do not change any assertion's meaning. Do not
canonicalise `TMPDIR` in the harness to sidestep this — a separate agent is
fixing a **real** product defect that such a change would mask.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
EMACS_BIN=<wrapper> bash test/run-tests.sh vault add-link saved-projection
```

Expect vault 8→0 unexpected and add-link 11→0. For `saved-projection`, only
`supertag-sync-syb-git` is yours; the suite may still show other failures from
work in flight elsewhere.

Sanity-check your fix is real and not an environment accident: the suites must
also pass with `TMPDIR` pointed at a non-symlinked directory. Both conditions
green means the fixture is canonical, not merely lucky.

The wrapper is required on this machine — plain `emacs -Q --batch` aborts on
any `fset` onto a subr because libgccjit cannot link
(`ld: library 'emutls_w' not found`):

```sh
exec emacs --eval '(setq native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil)' "$@"
```

## Scope

Only the three test files named above. Do not touch
`supertag-services-sync.el`, `test/node-feature-test.el`,
`test/move-node-ui-test.el` or `test/automation-tag-action-test.el` — other
agents hold those. Branch is `supertagV2`. Batch verification only; never drive
the user's running Emacs.
