# Supertag agent notes

Before you write or change any view buffer (Node View, Tag Cards, Stream,
Tag Manager, or a new `supertag-view-*.el`), read `design.md`. It is the
single source of truth for how a view looks: one font size, accent colors
as filled blocks only, `NOUN / NOUN` label grammar, character-built
ornament, the five-band page skeleton and the three-part card template.
Node View is not exempt; it is the first page to bring in line with it.
Finish view work with the checks in its last section, including a text
render at widths 120 and 80.

Before you work on summary panels (a tag's information panel whose layout a
model writes from the user's sentence), read `summary.md`. It is the
contract `supertag-summary.el` implements: who decides what, the two data
layers, which form rules are enforced by code and which are only prompted,
actions, and the safety boundary. A rule it marks Enforced or Accepted has
a test in `test/summary-test.el`; keep it that way.

Before you work on Stream agents (a tag's Stream grouped, annotated and
given keys by an agent a model writes from the user's sentence), read
`stream-agent.md`. It is the contract `supertag-stream-agent.el`
implements; a rule it marks Enforced has a test in
`test/stream-agent-test.el`.

## `doc/` is for user documentation only

`doc/` holds the documents a Supertag user reads: setup, query, sync,
automation, properties and the like, each with its `_cn` translation. It is
not a place for documents produced while developing: task briefs, work
reports, investigation notes, benchmarks, plans (`brief-*.md`,
`report-*.md`, and anything of that kind).

Write such a file under `.scratch/` instead, never in `doc/`. `.scratch/` is
ignored by git, so nothing there is committed; the briefs and reports that
were once in `doc/` by mistake are now in `.scratch/briefs/`.

## Tests: a child Emacs that cannot find TextUI

On this machine TextUI is the sibling checkout `../textui`, not an installed
package. `test/deps-loadpath.sh` finds it and exports every dependency
directory as `SUPERTAG_DEPS_LOADPATH`. A test that spawns `emacs -Q --batch`
gets dependencies from that variable only: `(package-initialize)` in the
child finds `ht` and `dash` in `~/.emacs.d/elpa` and no `textui`, so
`(require 'supertag)` dies in `supertag-discovery.el` with

    Cannot open load file ... "textui"

When a test fails with that message (or the same for `ht` or `dash`), the
child's load path is the bug, whatever you changed. Fix the test:

    (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "")
                        path-separator t))
    ;; in the child, before it loads Supertag code
    (dolist (dir ',deps) (add-to-list 'load-path dir))

Write every new child-process test this way from the start.

Two things that go with it:

- `test/run-tests.sh` stops at the first failing suite. After a failure,
  the later suites have not run; run each by name (`bash test/run-tests.sh
  git`) before reporting a result for the whole set.
- Source `test/deps-loadpath.sh` from `bash`. In `zsh` its unmatched glob
  for `textui-*` aborts the script.
