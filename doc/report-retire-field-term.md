# Report: retiring the term "field" from Query and Automation

Brief: `doc/brief-retire-field-term.md`. Branch `supertagV2`. **Not
committed** — the changes sit in the working tree. Batch only, no emacsclient,
and nothing was run against `/Users/chenyibin/Documents/notes`.

## Two agents worked this brief in the same tree

The working tree already contained (and kept gaining) a *parallel*
implementation of this same brief while I worked: the doc edits
(`doc/QUERY.md`, `doc/ABOUT-QUERY-BLOCK*.md`, `doc/AUTOMATION-SYSTEM-GUIDE*.md`,
`README*.md`, the `CHANGELOG.org` `[Unreleased]` entry), the creation-time
trigger/action validation the brief marked optional, a converted
`test/automation-create-node-test.el`, and two extra tests appended to the new
template test file. I have left all of that in place and not fought it for
lines. What follows separates **my** changes from what was already or also
done, because the combined diff is not one agent's work. The full-suite run
below (exit 0) covers the combined state of that moment.

Unrelated to this brief, another agent is also mid-edit on
`supertag-view-framework.el` modal-state registration: at the time of writing,
`tag-change` and `tag-manager` each fail one test for it
(`supertag-orphan-page-mode-registers-with-evil-as-emacs`,
`supertag-view-register-modal-state-is-idempotent-for-evil` — both expect four
registrations where the code performs two). I did not touch either; they are
outside this brief's scope.

## Renamed, repointed, or deleted (my edits)

| old | new | notes |
|-----|-----|-------|
| `supertag-query-resolved-fields` | *deleted* | byte-identical duplicate of `supertag-query-node-properties`; callers repointed (the brief asked to check exactly this, and to delete rather than rename) |
| `supertag-query-field-value` | *deleted* | "legacy compatibility" wrapper with two ignored arguments; callers now call `supertag-query-property-value` (which also drops the meaningless TAG-ID argument) |
| `supertag-query--find-nodes-by-field-indexed` | *deleted* | no callers anywhere; the name was doubly wrong (no index, no field) |
| `supertag-query-fields` | `supertag-query-properties` | callers: the babel table renderer and the result buffer |
| `supertag-query--get-fields-from-ast` | `supertag-query--get-properties-from-ast` | internal `fields` list renamed too |
| `supertag-query-block--live-field-names` | `supertag-query-block--live-property-names` | |
| `supertag-query-block--read-field-name` | `supertag-query-block--read-property-name` | prompt is now "Property: ", not "Field: " |
| `supertag-view-api-node-field-in-tag` | `supertag-view-api-node-property` | see the decision below |
| formula `field-getter` argument | `property-getter` | argument name and docstring only; positional callers unaffected |
| formula tokenizer `field-name` | `property-name` | same |

No `defalias` and no `define-obsolete-function-alias` was added, per the brief.

**`supertag-view-api-node-field-in-tag` decision: renamed, not deleted.** It is
not just an alias of `supertag-query-property-value`: it validates that the
name is a non-empty string (the contract test asserts that error) and it is
part of the view-API surface listed in the plugin guide and in the contract
test's `qe-forms`. Deleting it would have dropped that validation and the
documented entry point, so it keeps its own name, now spelled
`supertag-view-api-node-property` with `PROPERTY-NAME` in the docstring and the
error message.

## Query text, prompts and examples (my edits)

- The parser's alias comment no longer says "until phase 4": it now says
  `field` is a **permanent input alias** for `property`, kept so existing query
  blocks keep working, and that it is not offered in the UI, docs or prompts.
- Error messages: "expects a property key" for `sort-by`, the aggregate
  operators and `group-by`.
- Guided builder: the operator list offers `property`
  (`(property KEY VALUE) -- nodes whose property KEY equals VALUE`) and the
  built condition is generated as `(property ...)`. Its value prompt reads
  "Value for property `KEY': ".
- Syntax reference (`supertag-query-block--syntax-reference-text`): the leaf
  condition line documents `(property KEY VALUE)`, and every example uses
  `property`; one added paragraph says `field` is accepted as an older
  spelling and `property` is the spelling to write.
- Commentary, `:sort`/`:columns` header-arg docs, table renderer docstrings and
  the `--live-property-names` body all say property.
- `supertag-api.el`: both examples now read `(property "Status" "active")`.

## The two dead templates (my rewrite)

Both were creatable and unrunnable: `:on-field-change` is not a known trigger
(unknown triggers fail closed and only log), `field-changed` / `field-equals`
are not in the condition evaluator, and `:update-field` reaches "Unknown action
type". They now use the live vocabulary:

| | trigger | condition | action |
|---|---|---|---|
| **#5** `:field-change-update-field` -> `:property-change-update-property` | `:on-field-change` -> `:on-property-change` | `(and (has-tag SCOPE) (field-changed KEY))` -> `(and (has-tag SCOPE) (property-changed :KEY))` | `:update-field` (TAG/:field) -> `:update-property` (`:property`) |
| **#6** `:field-equals-move-node` -> `:property-equals-move-node` | `:on-field-change` -> `:on-property-change` | `(and (has-tag SCOPE) (field-equals KEY V))` -> `(and (has-tag SCOPE) (property-equals :KEY V))` | `:move-node` (unchanged) |

`target-tag` is gone from #5 (it only made sense with tag-defined fields; the
action writes the node's own property). Parameter names and types follow the
live `property` type, which prompts for a property name and keywordizes it the
same way templates 2 and 7 already did. The one other in-scope comment
("update a property/field on every node") now says property.

**Not done, as instructed to report:** I did not add creation-time vocabulary
validation myself — it is not cheap *drift-free* (the known trigger shapes live
in a `pcase` in `supertag-automation--trigger-match-p` and the action list in
the dispatch `pcase`, so a validator duplicates both lists and a future trigger
added to the matcher but not to the validator would refuse valid rules). The
parallel worker added such a validator anyway (`--validate-actions` plus an
inline trigger `pcase` in `--validate-automation-data`); the `automation-actions`
suite and the new template tests are the guard against that drift, and I left
their implementation untouched.

## Tests

**Added by me**: `test/automation-templates-test.el`, registered in
`test/renovation-suites.el` under the `automation-actions` suite with the
selector `^supertag-automation-template-`. It instantiates every one of the
nine templates with sample params, creates the rule, fires the event its
trigger names against a fixture vault, and asserts the action's effect — so a
template the engine cannot run fails the suite instead of being created
silently (which is exactly what the two field templates did). The nine effect
tests are one per template: NODE-1 TODO state, NODE-2 property write, NODE-3
implied tag, NODE-4 derived tag removal, NODE-5 scoped property change sets the
target property, NODE-6 property value moves the node's Org text, NODE-7
property value adds a tag, NODE-8 scheduled tick writes the property on tagged
nodes (driven through `supertag-scheduler--check-tasks`, the same route the
existing writer test uses), NODE-9 follow-up node creation. The fixture
isolates the rule index, the scheduler table and the automation flags, because
those are global state a template test must not leak into the next one.

The parallel worker appended two more tests to the same file (a catalog
completeness check that every `:id` has a matching effect test, and an
unknown-vocabulary rejection test); both are kept.

**Updated**: `test/document-query-contract-test.el` (the `qa-symbols`,
`qd-functions` and `qe-forms` inventories, plus the five call sites of the
renamed view-API function), `test/query-model-test.el` (bodies repointed to
`supertag-query-node-properties` / `supertag-query-property-value` /
`supertag-view-api-node-property`; the archive-only test name and its `archive`
suite selector were renamed to `...-resolves-properties-and-values` by the
parallel worker, consistently on both sides),
`test/automation-create-node-test.el` (the field-compatibility test asserted
the *broken* vocabulary — unknown trigger, "Unknown action type: :update-field"
— and is now a property-template persistence test), `test/renovation-suites.el`
(the new suite entry, plus the archive selector rename).

## Verification

`bash test/run-tests.sh` (full default suite) with the field-retire changes in
the tree: **exit 0, 34 suites, 1250 tests, 1245 as expected, 5 skipped, 0
unexpected**. Raw per-suite lines for the suites this brief touches:

```
Suite: contract          -> Ran 166 tests, 166 results as expected, 0 unexpected
Suite: automation-actions-> Ran  63 tests,  63 results as expected, 0 unexpected
Suite: property-automation-> Ran   5 tests,   5 results as expected, 0 unexpected
Suite: property-consumers-> Ran  21 tests,  21 results as expected, 0 unexpected
Suite: migrate           -> Ran  19 tests,  19 results as expected, 0 unexpected
```

`bash test/static-gates.sh` -> `Static O gates: PASS` (exit 0).

Byte-compiling `supertag-query.el`, `supertag-automation.el` and
`supertag-api.el` with `byte-compile-file`: **no new warnings** (30 warnings in
the new tree versus 32 at `HEAD`; the two that disappeared are the unused
`tag-id` in the deleted wrapper and an unused `field-name` in the rewritten
automation code). The `.elc` files were deleted afterwards; no root `.elc`
remains.

Re-running the suite after the other agent's view-framework edit landed gives
the two modal-state failures named at the top (in `tag-change` and
`tag-manager`), which abort the runner before the last suites; running those
remaining suites explicitly (`named-link-query`, `tag-path`, `tag-merge-plan`,
`tag-manager`*, `embark`, `ai`, `semantic`, `git`) shows everything else green
(embark 35/34 expected +1 skipped, ai 50/49 +1 skipped, semantic 38/38, git
39/39) and only `tag-manager` failing on the same unrelated modal-state test.
`tag-path`, `tag-merge-plan` and `named-link-query` pass.

## Surviving `field` hits, with a one-word reason each

`grep -n -i field supertag-query.el supertag-automation.el supertag-api.el`:

| hit | reason |
|-----|--------|
| `supertag-query.el:511,514` — comment + `((memq op '(property field))` | **alias** (user decision 1: permanent query input alias) |
| `supertag-query.el:1837` — the note in the syntax reference | **alias** (documents that alias) |
| `supertag-query.el:1195-1204` — `date-field` / `field` in `supertag-index-get-nodes-by-date-range` | **timestamp** (a node plist key `:created-at`/`:modified-at`, not an Org property) |
| `supertag-automation.el:277,279,281` — "missing required :name field" | **generic** (plain English, out of scope per the brief) |
| `supertag-api.el` | **none** (both examples now say property) |

## Chosen not to do (left, with reasons)

- `date-field` in `supertag-index-get-nodes-by-date-range` (node timestamp
  key, above) and the formula helper's `entity-data` keys.
- The capture spec `:field` alias in `supertag-node.el` — user decision 2, left
  untouched (verified still present at lines 841/852-853/891).
- Legacy readers: `supertag-migrate.el`'s `:on-field-change` / `field-equals` /
  `:update-field` forms, `:legacy-fields`, and the migrate tests that exercise
  them — the brief's out-of-scope list; "field" there names other users' stored
  data correctly.
- Docs not listed in the brief but still showing retired vocabulary, so the
  coordinator can decide: `doc/QUERY-SYNTAX-PROPOSAL.md`,
  `doc/architecture/02-architecture-problems.md`,
  `doc/architecture/03-refactoring-plan.md`,
  `doc/architecture/04-final-architecture.md` (also names the deleted
  `supertag-query-field-value`), `doc/A-DAY-WITH-SUPERTAG.org` /
  `_CN.org` (`:on-field-changed` examples),
  `doc/SUPERTAG-PLUGIN-GUIDE*.md` (a `:field-definitions` line; I did update
  the two lines per guide that name the renamed view-API function), and
  `plan_cn_v2.md`.
- The stale non-default test files the brief lists
  (`test/query-block-test.el`, `test/query-library-test.el`,
  `test/automation-condition-test.el`) plus one more I found:
  `test/test-view-node-runtime.el` stubs the now-deleted
  `supertag-query-resolved-fields` and is loaded by no suite.

DONE: renamed the retired "field" vocabulary to "property" across Query and Automation, repaired both dead templates onto the live trigger/condition/action vocabulary (guarded by a new every-template effect test), and left `field` as input-only syntax in exactly the two documented alias places.
