# Task brief: `[[` reference completion must always commit a link

Status: bug fix on branch `supertag-refactor`. Another agent is concurrently
editing supertag-tag.el / supertag-view-tags.el / supertag-migrate.el for a
different task: touch only `supertag-link.el` and a test file (new or
`test/add-link-workflow-test.el`). Commit only your own files. Do not drive
the user's running Emacs; batch only.

## Symptom (user report)

Typing `[[` + title, then choosing a node in the popup, leaves the raw
candidate text in the buffer (e.g. `[[Emacs Tips  (t.org | Emacs Tips)`)
instead of rewriting it to `[[id:ID][Title]]`.

User setup: corfu (`corfu-auto t`, `corfu-preselect 'prompt`, TAB bound to
`corfu-complete`, `corfu-popupinfo-mode`), orderless
(`orderless-flex`, `orderless-affix-dispatch`), cape-dabbrev/file/keyword
in global capfs, Chinese IME (full-width `【【` opener exists already).

## Confirmed failure paths (reproduced in batch with real corfu+orderless)

Reproduction script pattern: load corfu/orderless from
`~/.config/nova-emacs/elpaca/builds/*/` (set EMACSLOADPATH to the repo plus
those dirs), use `supertag-add-link-test--isolated` and
`supertag-add-link-test--write-node` from test/add-link-workflow-test.el,
override `corfu--popup-support-p` to t and `corfu--popup-show/hide` to nil,
enable `supertag-ui-completion-mode` + `corfu-mode`, set
`completion-in-region-function` to `corfu--in-region`, call
`completion-at-point`, set `corfu--index`, then call `corfu-insert`,
`corfu-complete` or `corfu-expand`. Run with `</dev/null` (template prompts
read stdin).

1. `corfu-complete` (TAB) on the `X  [Create new node]` row: corfu inserts
   the row text, then only calls the exit function if
   `(test-completion newstr table)` is true. The table's `lambda` action
   deliberately tests only existing rows, so the exit function is never
   called and the raw text stays. Fix: an exact match of the full create
   row string must test true (typed prefixes never equal the row string, so
   the "never auto-commit a prefix" intent is kept). Check the `nil`
   (try-completion) action too so corfu finishes rather than looping.
2. Closer already present after point (`[[emac|]]`, from an auto-pairing
   input method or retyping inside brackets): `org-element-context` reports
   a `link`, `supertag-reference--completion-context-p` rejects it and our
   CAPF returns nil, so other capfs (ispell/dabbrev) take over. Fix: allow
   the case where point is inside a bracket link whose path is not a
   known-scheme link (`id:`, `denote:`, `file:`, http(s), ftp, mailto — keep
   the existing regexp as the source of truth) and has no description
   part; bounds end at point, and `supertag-reference--post-completion`
   already consumes the closer. Same for `【【…】】`.

## Defensive fix

3. `supertag-reference--post-completion`: if SELECTED arrives without the
   `supertag-reference-*` text properties (some UI paths pass the plain
   inserted string, e.g. `corfu--exit-function` falls back to STR when it is
   not `member` of its candidate list, or `corfu--done` is called with
   CANDS nil), recover the candidate by matching the plain string against
   the table's current candidates (existing and create row) before giving
   up. Only an explicit completion status (`finished`/`exact`/`sole`) may
   commit, as today.

Also look for any other corfu path (`corfu-expand` with a unique match,
`corfu--in-region-1` total=1 / `t` branches) where the exit function
receives a propertyless string, and make sure fix 3 covers it.

## Tests

ERT tests driving real corfu in batch are welcome if they can be made
reliable without the user's config; otherwise test the table actions
(`test-completion` on the create row, `try-completion`) and the
post-completion recovery directly, plus bounds inside `[[emac]]` and
`【【emac】】`, and that `[[id:x]]`, `[[https://…]]`, `[[x][desc]]` still
return no bounds. Run the whole test/add-link-workflow-test.el and
byte-compile supertag-link.el without new warnings.

## Report

Write `doc/report-reference-capf-commit.md`: root causes, changes, commands
run and results. Commit.
