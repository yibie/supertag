# Brief: make `test/static-gates.sh` pass honestly

`bash test/static-gates.sh` exits 1. It is pre-existing — red at `888c36b` and
at every commit since — and it has two separate causes. One is trivial. The
other is a real circular dependency, and I do **not** want it papered over.

## Cause 1 — a missing header (trivial)

The gate requires every root `.el` to carry both `;; Commands:` and
`;; Dependencies:` lines (`test/static-gates.sh:9-12`).
`supertag-view-framework.el` has `;; Commands:` but no `;; Dependencies:`.

Add it, matching the convention the other files use, and listing what the file
actually requires. Do not add a placeholder — the line should be true.

That alone moves the gate to its next failure, which is Cause 2.

## Cause 2 — three indented `(require)` forms guarding a real cycle

`test/static-gates.sh:13` forbids indented requires outright:

```sh
if grep -nE '^\s+\(require ' ./*.el ...; then ... exit 1
```

Three files violate it, all requiring the same module from inside a function:

- `supertag-link.el:1882`
- `supertag-tag.el:3892`
- `supertag-view-tag-cards.el:1430`  (carries a comment explaining itself:
  *"Keep the file independently loadable alongside TextUI, while making the
  command robust when it is invoked outside the normal `supertag' loader."*)

These are **not** sloppiness. `supertag-view-framework.el:16` requires
`supertag-tag` at top level, so a top-level `(require 'supertag-view-framework)`
in `supertag-tag.el` would close a cycle. The lazy require is load-bearing.

So the gate as written forbids a pattern the architecture currently needs. That
is the actual problem to solve, and there are two honest routes:

### Route A (preferred) — break the cycle

Find what `supertag-view-framework` actually needs from `supertag-tag`, and
what the three callers actually need from `supertag-view-framework`. From a
quick look the callers want the shared role faces
(e.g. `supertag-view-mute`), which is a leaf concern. If the shared faces (and
whatever else is genuinely leaf-level) move into a small module that both sides
can require at top level, the cycle dissolves and all three requires can rise
to the top of their files.

Check first whether `supertag-view-framework`'s dependency on `supertag-tag` is
itself narrow enough to invert instead. Pick whichever direction produces the
smaller, more honest module boundary, and say why you chose it.

### Route B (fallback) — relax the gate, deliberately and narrowly

If Route A turns out to require a disproportionate refactor, then the gate's
blanket rule is simply wrong and should be narrowed — for example, permitting
an indented require that carries an explicit marker comment stating the cycle
it avoids, and requiring that marker so the exemption cannot spread silently.

If you take Route B, the three call sites must each get that justification
comment, and the gate must still reject an unmarked indented require. A gate
that no longer catches anything is worse than no gate.

## What I do not want

Do not delete the gate, do not weaken it to a warning, and do not simply
`grep -v` the three offending files out of it. If the rule is wrong, narrow it
on stated principle; if the code is wrong, fix the code. Either way the
end state must be a gate that would still fail on a genuinely careless
indented require.

Say plainly in your report which route you took and why, and what the gate
still protects afterwards.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
bash test/static-gates.sh          # must exit 0
```

Then confirm you have not broken loading or the suites:

```sh
EMACS_BIN=<wrapper> bash test/run-tests.sh contract vault view-framework tag-manager promote
```

All must stay at 0 unexpected. If you took Route A, also confirm each of the
three files still loads standalone in a fresh `-Q --batch` (that independent
loadability is exactly what the tag-cards comment was protecting):

```sh
emacs -Q --batch -L . -L <deps> --eval "(require 'supertag-view-tag-cards)"
```

and likewise for `supertag-tag` and `supertag-link`.

The wrapper is required on this machine — plain `emacs -Q --batch` aborts on
any `fset` onto a subr because libgccjit cannot link
(`ld: library 'emutls_w' not found`):

```sh
exec emacs --eval '(setq native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil)' "$@"
```

## Scope

`supertag-view-framework.el`, and whichever of `supertag-tag.el`,
`supertag-link.el`, `supertag-view-tag-cards.el` your route touches, plus
`test/static-gates.sh` only if you take Route B. Another agent is working on
`test/embark-test.el` and `supertag-embark.el` in parallel — leave those alone.
Branch is `supertagV2`. Batch verification only; never drive the user's running
Emacs.

If Route A looks like it would sprawl beyond a contained change, stop and
report rather than pushing through — I would rather decide than have it forced.
