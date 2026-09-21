# Brief: retire the term "field" from Query and Automation

The field mechanism (tag-defined fields, `:fields` / `:field-values`, global
fields) was retired in `d75283c`. Query and Automation now read and write
**Org properties** projected into the Store (`(plist-get node :properties)`).
The word "field" survives in names, prompts, docstrings, templates and docs,
and it misleads: it suggests a mechanism that no longer exists.

Rename it to "property" wherever it means "an Org property of a node".
This is a terminology cleanup plus one repair (two dead templates). It must
not change what any working query or rule does.

## User decisions (already made — do not reopen)

1. **`(field KEY VALUE)` stays accepted by the query parser** as an alias of
   `(property KEY VALUE)`. Existing query blocks in users' Org files keep
   working. `supertag-query.el:519-528` is the alias; keep the behaviour,
   update the comment (it says "until phase 4", which is no longer the plan:
   say it is a permanent input alias for existing blocks).
2. By the same reasoning, the capture spec key `:field` stays accepted as an
   alias of `:property` (`supertag-node.el:841-853`, `:891`). Leave it.
3. No `defalias` / `define-obsolete-function-alias` for renamed Lisp symbols.
   Rename, update every caller and test, done.

So "field" remains legal **input** in exactly those two places, and nowhere
else is it presented to the user: every prompt, help text, template, error
message, doc and example says "property".

## In scope

### `supertag-query.el`

- Rename the symbols below and update all callers (grep the whole repo,
  including `test/`, `supertag-view-*.el`, `supertag-api.el`,
  `supertag-automation.el`):
  - `supertag-query-resolved-fields` → `supertag-query-resolved-properties`
    — but first check whether `supertag-query-node-properties` (`:328`)
    already does the same job; if so delete the duplicate instead of renaming.
  - `supertag-query-field-value` (`:265`) — a "legacy compatibility" wrapper
    around `supertag-query-property-value` with two ignored arguments. Delete
    it; point callers at `supertag-query-property-value`.
  - `supertag-view-api-node-field-in-tag` (`:1961`) — same: a wrapper that
    ignores TAG-ID. Delete it and move callers to
    `supertag-query-property-value`, or rename to
    `supertag-view-api-node-property` if the view-API layer needs its own
    entry point. Your call; say which and why in the report.
  - `supertag-query-fields` → `supertag-query-properties`
  - `supertag-query--get-fields-from-ast` → `…--get-properties-from-ast`
  - `supertag-query--find-nodes-by-field-indexed` → `…-by-property` (it is not
    indexed; drop the false "indexed" too, or delete if it has no callers)
  - `supertag-query-block--live-field-names` → `…--live-property-names`
  - `supertag-query-block--read-field-name` → `…--read-property-name`
- `supertag-query-block--syntax-reference-text`: document `(property KEY
  VALUE)`; all examples use `property`. Add one line noting `field` is
  accepted as an older spelling.
- The guided builder (`supertag-query-build`): offer `property`, not `field`,
  and generate `(property …)`.
- Docstrings, comments, header-arg docs ("a field name" → "a property name"),
  table headers, error messages.

### `supertag-automation.el`

- Docstrings/comments/log messages: "field" → "property" where it means an
  Org property.
- **Two dead templates** in `supertag-automation-templates`:
  - #5 `:field-change-update-field` and #6 `:field-equals-move-node` use
    trigger `:on-field-change`, conditions `field-changed` / `field-equals`
    and (#5) action `:update-field`. None of these exist in the engine any
    more: unknown triggers fail closed (`:135-160`), the condition evaluator
    has only `property-equals` / `property-changed` / `property-test`
    (`:960-975`), and `:update-field` hits "Unknown action type" (`:538`).
    Rules built from them are created without error and never run.
  - Rewrite both on the live vocabulary:
    - #5 → "Property change -> set another property":
      `:trigger :on-property-change`, condition
      `(and (tag SCOPE) (property-changed KEY))` in whatever form the current
      evaluator accepts for tag scoping (check how the other templates and
      `supertag-automation--condition-to-query` express "has tag"), action
      `:update-property`. Drop the `target-tag` parameter — it has no meaning
      without tag-defined fields.
    - #6 → "Property equals value -> move node to file":
      `:on-property-change`, `property-equals`, action `:move-node`.
  - Give them new `:id`s that say `property`.
  - Add an ERT test that instantiates **every** template with sample params,
    creates the rule, fires the matching event against a fixture vault, and
    asserts the action's effect. The point is that a template which builds a
    rule the engine cannot run must fail the suite. Put it in the
    `automation-actions` suite (`test/renovation-suites.el`).
- If `supertag-automation-create` can cheaply reject an unknown trigger
  keyword or unknown action type at creation time, do that too (a rule that
  can never fire should not be creatable silently). If it is not cheap, say so
  in the report and leave it.

### `supertag-api.el`

- `:136` and `:212`: examples say `(field "Status" "active")` → `property`.

### Docs

- `doc/QUERY.md`, `doc/ABOUT-QUERY-BLOCK.md`, `doc/ABOUT-QUERY-BLOCK_cn.md`,
  `doc/AUTOMATION-SYSTEM-GUIDE.md`, `doc/AUTOMATION-SYSTEM-GUIDE_cn.md`:
  bring the query/automation vocabulary in line with the code (property
  operator, property triggers/conditions/actions, the nine templates as they
  now are). Remove passages that describe tag-defined fields, global fields,
  `:on-field-change`, `:update-field`. Do not invent features; describe only
  what the code does.
- `README.md` / `README_CN.md`: only the query and automation passages.
- `CHANGELOG.org` `[Unreleased]`: add an entry for this change (renamed
  public functions, the two repaired templates, `field` kept as input alias).

## Out of scope — do not touch

- `supertag-migrate.el`, the legacy readers in `supertag-core-persistence.el`
  / `supertag-core-store.el` / `supertag-tag.el` (`:legacy-fields`, `:fields`
  rejection, `field-id` in relation identity). They read **other users'
  stored data**; "field" there names the old data correctly.
- `supertag-view-framework.el` "editable field" / `widget-field-*`: that is
  the Emacs widget term. `supertag-view-tag-cards.el` / orphan view "field":
  that is the page-layout grid. Unrelated.
- Generic English ("missing required :id field", git status `fields`).
- `archive/`. Non-default tests that are already stale and load missing
  modules (`test/query-block-test.el`, `test/query-library-test.el`,
  `test/automation-condition-test.el`): list them in the report, do not fix.
- Any change to what `(property …)` matches, to sync, or to how properties
  are projected.

## Verification

Run from the repo root; all must pass:

```sh
bash test/run-tests.sh            # default suites
bash test/static-gates.sh
```

(`test/deps-loadpath.sh` now exports `LIBRARY_PATH` for native-comp in `-Q`
children — that uncommitted change is mine, leave it in place.)

Also:

- byte-compile `supertag-query.el`, `supertag-automation.el`,
  `supertag-api.el` with no new warnings; delete the `.elc` afterwards.
- `grep -n -i field supertag-query.el supertag-automation.el supertag-api.el`
  — every remaining hit must be one of: the parser alias, the capture alias
  note, or generic English. List the survivors in the report with a one-word
  reason each.
- Do not drive the user's running Emacs (no emacsclient). Batch only.

## Report

Write `doc/report-retire-field-term.md`: what was renamed (old → new), what
was deleted and why, the template rewrite, test results (exact counts), the
surviving-`field` list, anything you chose not to do. Do not commit. End your
turn when the report is written.
