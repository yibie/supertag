# Brief: `run-tests.sh` silently fails every subprocess test

## The defect

`test/run-tests.sh` never sets or exports `SUPERTAG_DEPS_LOADPATH`. Any test
that spawns a child Emacs reads its dependency load path from that variable
only:

```elisp
(deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
```

With the variable unset, `deps` is nil, the child runs with no package
directories, and it dies on `(require 'ht)`:

```
CA-ERROR (file-missing "Cannot open load file" "No such file or directory" "ht")
```

The **parent** process never notices the problem, because `run-tests.sh` gives
itself dependencies a different way — `(require 'package)` + `(package-initialize)`
at line 36. So the harness works for in-process tests and silently fails for
every out-of-process one. That asymmetry is the whole bug.

There are **56 such subprocess call sites across 18 test files**: migrate,
add-link, document-query-contract, tag-path-hierarchy, multi-instance,
view-framework, node-identity, svg-tag, storage-save-boundary, vault, git,
promote, node-view, property-consumers, sync-worker-regression, node-feature,
move-node-ui, automation-create-node.

Measured at `888c36b` on this machine:

| suite | `SUPERTAG_DEPS_LOADPATH` unset | set to the elpa dirs |
|---|---|---|
| promote | 48 tests, **10 unexpected** | 48 tests, **0 unexpected** |
| contract | 162 tests, **25 unexpected** | 162 tests, **1 unexpected** |

Every one of those disappearing failures was a false alarm.

This is not hypothetical damage. An agent working on this repo yesterday
accepted a 31-failure promote baseline as "pre-existing", and that noise
concealed a genuine regression its own change had introduced. A failing
baseline that everyone learns to ignore is worse than a red build.

## The fix

`test/static-gates.sh` (lines 18–28) already solves exactly this, correctly.
Reuse its logic in `run-tests.sh`:

1. If `SUPERTAG_DEPS_LOADPATH` is already set, honour it untouched.
2. Otherwise derive it: for each of `ht` and `dash`, take the
   highest-versioned `"$HOME"/.emacs.d/elpa/<name>-*` directory (`sort -V | tail -1`).
3. If nothing is found, **fail loudly** with the same message shape
   static-gates.sh uses — `No ht/dash dependency directories found; set SUPERTAG_DEPS_LOADPATH`
   — rather than running a suite that is guaranteed to report false failures.
4. Validate that each directory exists, then `export SUPERTAG_DEPS_LOADPATH`
   so every child process in every suite inherits it.

Prefer factoring the derivation into one shared snippet sourced by both
scripts over copying the block, if that can be done without disturbing
`static-gates.sh`'s current behaviour. If sharing turns out to be awkward,
duplicating it is acceptable — say which you chose and why.

Keep `set -euo pipefail` semantics intact, and keep honouring `EMACS_BIN`.

## Verification

Show the before/after for both suites, on a clean checkout:

```sh
bash test/run-tests.sh promote      # expect 48/48, 0 unexpected
bash test/run-tests.sh contract     # expect 162, 1 unexpected
```

with the variable **unset in your shell** — that is the point of the fix, the
harness should now derive it by itself. Then confirm that explicitly exporting
a custom `SUPERTAG_DEPS_LOADPATH` still overrides the derivation, and that
unsetting it on a machine with no `ht`/`dash` in `~/.emacs.d/elpa` fails with
the clear message instead of running.

The one genuinely failing contract test,
`supertag-node-feature-compat-create-real-positions-draft-hooks`, is a real
pre-existing failure and is **out of scope** here. Do not fix it, do not hide
it — it should still be failing when you are done.

## Note on native compilation

Separately, on this machine every `cl-letf`/`fset` onto a subr aborts under
`-Q --batch` because libgccjit cannot link (`ld: library 'emutls_w' not found`),
producing dozens more phantom failures. That is a local toolchain fault, not a
repo defect, and it is **not** part of this task. Mention it in your report if
you hit it; a wrapper setting
`native-comp-enable-subr-trampolines nil` works around it.

## Scope

`test/run-tests.sh`, and `test/static-gates.sh` only if you factor out the
shared snippet. Do not touch any `.el` file. Do not drive the user's running
Emacs; batch verification only.
