# Brief: subprocess tests break when the repo lives under `$HOME`

## The defect

Every subprocess test helper isolates the child by repointing `HOME` at a
temp directory:

```elisp
(setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
```

(`test/promote-workflow-test.el:1037` and the equivalent line in each of the
other helpers.)

But when the checkout sits under the real `$HOME`, Emacs reports
`default-directory` in tilde form:

```
$ cd ~/Documents/emacs/package/supertag
$ emacs -Q --batch --eval '(princ default-directory)'
~/Documents/emacs/package/supertag/
```

`call-process` inherits that `default-directory`. By the time it runs, `~` no
longer means the real home — it means `tmp` — so the child cannot chdir and the
test dies before it starts:

```
(file-missing "Setting current directory" "No such file or directory"
              "~/Documents/emacs/package/supertag/")
```

This is why the bug stayed invisible: it depends entirely on **where the
checkout lives**, not on the code under test.

| checkout location | promote suite |
|---|---|
| `~/Documents/emacs/package/supertag` (the normal case) | 10 unexpected |
| `/tmp/...` worktree | 0 unexpected |

Both measured at `8fff198` with `SUPERTAG_DEPS_LOADPATH` correctly derived, so
this is a separate defect from the one that commit fixed. Agents verifying in
`/tmp` worktrees see green while the maintainer, whose checkout is under
`$HOME`, sees ten phantom failures.

## The fix

Before `HOME` is changed, pin `default-directory` to a real absolute path, so
the child's working directory cannot depend on what `~` currently means.
Expanding it once inside the helper's `let*` — while the original `HOME` is
still in effect — is enough; binding it around the `call-process` is fine too.
Pick one shape and apply it consistently.

There are **56 subprocess call sites across 18 test files** (find them with
`grep -rl SUPERTAG_DEPS_LOADPATH test`). Several files carry the same helper
shape more than once — `tag-path-hierarchy-test.el` has 13,
`add-link-workflow-test.el` 7, `storage-save-boundary-test.el` and
`node-feature-test.el` 6 each. Fix all of them, not just promote's.

If the helper body is genuinely identical across files, prefer extracting one
shared helper over 56 copies of the same edit; if the shapes differ enough that
extraction would change behaviour, do the mechanical fix and say so.

While you are there, check whether `root` (derived from `symbol-file`) and the
other paths handed to the child have the same tilde exposure, and expand those
too if so.

## Verification

Run **from the checkout under `$HOME`** — that is the case that reproduces:

```sh
cd ~/Documents/emacs/package/supertag
bash test/run-tests.sh promote contract
```

Expect promote 49/49 with 0 unexpected, and contract down to its single real
failure, `supertag-node-feature-compat-create-real-positions-draft-hooks`,
which is out of scope and must still be failing when you are done.

Then confirm the suites still pass from a checkout **outside** `$HOME`, so the
fix is not a swap of one location dependency for another.

Do not verify only in a `/tmp` worktree. That is precisely the blind spot that
let this bug survive.

## Note on this machine

`-Q --batch` here aborts on any `fset` onto a subr because libgccjit cannot
link (`ld: library 'emutls_w' not found`), adding dozens of unrelated phantom
failures. Work around it with an `EMACS_BIN` wrapper:

```sh
exec emacs --eval '(setq native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil)' "$@"
```

That is a local toolchain fault, not a repo defect, and not part of this task.

## Scope

Test files only. Do not touch any `supertag-*.el`. Do not drive the user's
running Emacs; batch verification only. Branch is now `supertagV2` — commit
there.
