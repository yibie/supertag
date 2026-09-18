# Brief: make the orphan report a real Supertag view page

## What exists

`supertag-report-orphan-tag-occurrences` currently opens `*Supertag Orphan
Tags*`, a `special-mode` buffer defined inside `supertag-tag.el`. It works —
marks, bulk removal, one preview, one confirmation — but it is not a Supertag
view: it does not go through the View Runtime and it does not follow the design
system.

## What to build

Move it to its own `supertag-view-*.el` file and make it a proper view page.

**Read `design.md` first.** `AGENTS.md` names it as the single source of truth
for how a view looks, and it is binding here: one font size with hierarchy by
contrast, colour as filled area rather than ink, `NOUN / NOUN` label grammar,
ornament built from the character set, the five-band page skeleton, the
three-part card template, and the checks in its last section — including a text
render at widths 120 and 80.

Follow the existing pages for structure and idiom rather than inventing one;
`supertag-view-tags.el` (Tag Manager) is the closest relative, since this page
is also a markable list that acts on what is marked.

## Behaviour that must carry over unchanged

- **Every token starts marked.** The user confirmed this default explicitly:
  open the page, unmark what to keep, remove the rest in one confirmation.
- The bulk removal path stays exactly the one built in `f46307a`/`293e562`:
  one preview listing every file and line, the `NOT CHANGED` section, one
  `yes-or-no-p`, the per-file rescan guard, the range writes. Do not write a
  second removal path, and do not change what counts as an occurrence.
- The non-interactive entry (`supertag-cleanup-orphan-tag-occurrences` taking a
  token, a list, or nil for everything) keeps working with no minibuffer.
- Marks, keys and the header line keep following the Tag Manager's conventions.
  `g` still rescans without re-marking tokens the user deliberately unmarked.
- Ambiguous tokens stay listed separately and are still refused by cleanup.

## Interaction

Keep the keys the page already has (`m`/`u`/`M`/`U`/`D`/`RET`/`g`/`n`/`p`/`q`).
`RET` visiting the occurrence's file and line matters — it is how the user
judges whether a token is worth keeping.

Two standing user preferences apply:

- **Modal editing must be fully disabled locally** in this buffer — meow and
  evil both, disabled outright, not merely switched to motion or emacs state.
  The Tag Manager already does this; copy that treatment.
- **Action buttons look like traditional Emacs text buttons** (`[REMOVE]` in
  the `button` face), not coloured chips, on the warm `paper` palette.

## Scope discipline

This is a presentation and placement change. Do not add new capabilities —
in particular do not add an "adopt/register this token as a tag" action, even
though it is an obvious next step; that is a separate decision the user has not
taken yet.

## Tests

The existing orphan tests must keep passing, adjusted only where the buffer's
name or rendering changed — itemise any such change with its reason. Add the
view-level checks the design system requires, following what
`test/view-framework-test.el` and the other view suites already do: a text
render at widths 120 and 80, and the page skeleton.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
bash test/run-tests.sh          # 35 suites / 1227 tests, currently 0 unexpected, exit 0
bash test/static-gates.sh       # exit 0
```

Nothing may regress. Paste the width-120 and width-80 renders into your report
so the design can be reviewed as text.

If the local libgccjit trampoline problem appears, use an `EMACS_BIN` wrapper
setting `native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil`.

## Scope

A new `supertag-view-*.el`, `supertag-tag.el` (removing what moves out),
`test/renovation-suites.el` and tests. Never run anything against
`/Users/chenyibin/Documents/notes`. Branch `supertagV2`.

If moving the buffer out of `supertag-tag.el` would drag in view wiring that
reaches beyond these files, stop and report `BLOCKED` with what it would touch,
rather than widening on your own.

## Reporting

Write `doc/report-orphan-view-page.md` — what moved, the design decisions and
which `design.md` rule each follows, commit hash, the two text renders,
verification with raw output, and any test you changed with the reason — then
end with `DONE: doc/report-orphan-view-page.md`.
