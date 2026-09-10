# Current P1 entry and historical refactor evidence

<!-- P1 development -->
`bash test/run-tests.sh` now executes the [static P1 manifest](renovation-suites.el).
The old script delegates to that executor. The suite names/counts below describe
historical runs, not a second executable default list or a current green claim.

| Replaced assertion | Current protection | Retained scope |
| --- | --- | --- |
| query-model node reads/detail shape | document-query-contract + public node-view-properties | tag/completion P3, links P4, old DSL G2 remain named transitions |
| NodeView injected state/private field layout | actual public window header/metadata/mode-line, wrong-Q counterexamples | public aggregate loading remains transitional |
| NodeView save/update/delete private render calls | native save hook → real file queue → subscribed view refresh and selection fallback | existing S15 writer/queue unchanged |
| old fields as property defaults | document-query-compat conflict/collection preservation | field/Board query tests remain explicit archive |

See the [test guide](README.md). No legacy-all run is
required to validate this cutover; historical results remain evidence only for
their original scope. Fresh-package/Embark installation is not covered here.
<!-- /P1 development -->

## Historical batch 1 record (commands below describe the old executor)

# Text-first refactor: batch 1 checks and loading inventory

Run `bash test/run-refactor-batch1.sh SUITE`. Each run uses a fresh temporary data directory, does not load user init, and retains its log there. Installed package dependencies are initialized. This is test isolation, not a security sandbox; tests themselves must use synthetic fixtures.

| Suite | Purpose |
| --- | --- |
| baseline | Inherited Org-first tag membership, tag paths, query model and node identity (85 tests at capture) |
| foundation | New shared move-service failure safety and read-only migration preflight |
| regression | Baseline + foundation + ownership, architecture, document commands, concept, reference, query and Node View seams |
| legacy-all | Exact default file list read from `test/run-tests.sh`; retains old-model tests as regression evidence |
| contextual | Separate `tests/` ontology/link/reference suites plus unlinked mentions |
| moves | Batch 2 positional/batch service, public Move UI, singular safety, physical-link/backlink and shared capture-selector checks |
| move-legacy | Existing physical-link writer and write-efficiency tests; baseline before batch 2: 15/17, with two service leave-link failures described below |
| archived-view-entrypoints | Fresh-process default load/init exclusion, menu/act retirement, and separate explicit archive-load smoke |
| legacy-entry-retirement | Fresh-process standalone Capture/field command retirement, retained Org Capture finalization and field backend/Table provenance, Embed lifecycle isolation, virtual-menu exit, and explicit archive compatibility |
| add-link | Unified ordinary/named Add Link, complete template-created targets, exact projection identity, cancellation/failure boundaries and configured restart compatibility |
| find-node | Unified current/other-window Find, read-only preview restoration, explicit complete-template creation, and retained writer retry boundaries |
| discovery | Immediate random full-body reading, complete keyword search, live-origin navigation/selection and sequential ordinary-reference insertion/recovery |
| stream | Complete cross-file collection, real Org whole-file save/projection and failure retry, latest-successful-save cancellation, source context/hook cleanup, Node View and native related-note return |
| promote | Template-key Promote, actual same-name preview/reuse/new, retained subtree relocation and plain old-site links, staged multi-file retry, persisted-ID position monitoring and explicit mention materialization; includes retained concept/unlinked-mention suites |

These groups are not a claim that the new text-first model is implemented. Old schema/field/ontology tests still characterize the inherited runtime. The Discovery gate includes the matcher parity/performance file that remains outside the old default runner. `tests/` has a separate contextual runner and is not covered by the old default suite.

The default package no longer loads or advertises Table, Schema View, Kanban,
Board UI, Graph UI, the ontology umbrella, or standalone ontology migration/tool
UIs.  Their source remains available for explicit archive loading.  Retained
Node View no longer loads or renders ontology Function/Action/Policy or UI
Action capabilities.  Its old typed-Link and schema-derived relation displays
are replaced by configured, saved Org named links; query paths still load board
ops, and core schema remains in Store/Automation paths.  Old
standalone Capture/field commands, Embed initialization/default entry points and
virtual-column menu entries have also exited.  Org Capture integration and the
internal finalizer remain, while Embed and virtual columns remain explicitly
loadable archives.  This is not complete ontology, field, relation, or phase
retirement.

## Contract classification for subsequent slices

Classification applies to assertions, not permission to delete a whole mixed test file. Until its owning cutover slice lands, an existing test failure remains a regression to investigate. Archived coverage is excluded from the future default release gate only when its consumers are disconnected; keep an explicit archive gate while code remains.

| Class | Principal test families | What subsequent work must preserve/change |
| --- | --- | --- |
| Retained | `node-identity`, `document-command-ownership`, `architecture-boundary`, new `move-node-safety`; view framework/runtime/refresh | Stable Org ID, authoritative document writer, save/projection failure safety and view lifecycle. Adapt only assertions demonstrably tied to retired dependencies. |
| Revised contract | `tag-membership-org-first`, `tag-path`, `tag-merge`, `query-model`, `query-block`, `query-library`, `ownership-separation`, extractor/reference/concept tests | Replace stable tag-ID/schema/field authority assertions with text names/paths, Org properties and text-derived links. Preserve literal text, backlinks, native capture and generated-output exclusion. |
| Revised contract | Persistence/restore/canonical serialization, merge/conflicts/Git sync, automation/transaction/canonical-change | Test rebuildable cache, durable user rules and vault-scoped Git text conflicts. Old DB merge/conflict semantics are not the future acceptance contract. |
| Revised contract | `test-ui-act`, `test-add-reference`, `test-back-to-heading`, `test-concept-mention`, Node View/Stream tests; search performance file outside old default suite | Test final command surface and approved UX. Retire demotion-command assertions, route link insertion through final add-link, Promote templates, and later scenario-approved Embark actions. Do not infer menu design from old act tests. |
| Archive | Table/kanban/schema-view, formula/aggregate/virtual-column/embed, schema/field-node-reference, reciprocal field migration, ontology suites under `tests/` | Preserve as archive compatibility evidence while consumers exist; remove from future default loading and release gate with the relevant cutover, not by silently weakening old tests now. |
| Missing new coverage | Migration apply/rollback; rebuild from Org alone; durable Automation configuration | Batch 2 adds public positional/multi-node Move gates; migration remains read-only inventory. Add the remaining gates before authority cutover or real migration. |
| Retained workflow coverage | Promote template keys/collision previews; Node View related notes/native return | Promote has temporary-file save/projection/retry and persisted-ID position-monitoring ERT. Stream covers real Node View/native return; manual Emacs acceptance and large-vault performance remain separate. Find and Discovery retain their dedicated workflow gates. |
| Missing new coverage | Chinese semantic relevance/provider privacy; Embark WHERE/WHAT/ACTION scenarios; multi-vault asynchronous isolation; Git conflict pause/resume; full-width tag labels | Provider/scenario decisions precede implementation. Need explicit fixtures and manual checks; current all-green old suites do not cover these goals. |

## Verification boundary

Batch 1 checks ordinary recoverable save failures, not power-loss atomicity. Save hooks that rewrite buffer text are rejected during the shared move; recovery snapshots are in-process, not a durable recovery journal. Preflight is heading-only, inventories explicit Store nodes, reports default `ST_` legacy properties as unsupported, and currently reparses a file for each node. It is not a complete migration plan or a large-vault performance claim.

Successful shared moves save both entire live buffers, including pre-existing drafts; restored modified flags do not keep drafts memory-only. Failure compensation restores the original disk/draft split. Moving the sole heading may leave an empty source file (not delete it). Recovery can reset unrelated markers/window positions despite restoring current point and narrowing. Reprojection currently visits all identified headings in both files and may repeat scans; large-diary performance is unmeasured. Supertag save side effects must wait for durable documents; unrelated third-party hook effects cannot be rolled back by this service.

## Current startup dependencies to unwind in later slices

| Existing seam | Current consumers / constraint |
| --- | --- |
| `supertag.el` default require block | Table, Kanban, Schema View, Board UI, Graph UI, the ontology umbrella, Embed and virtual columns no longer load from the default root or appear in its menus/actions. Their source remains explicitly loadable. Core schema and retained ontology/query consumers remain for later cuts. |
| `supertag-init` | Store load, schema registrations, backups, scheduler and completion still operate on retained or old-model paths; Embed initialization has exited. Do not discard the cache before durable automation/semantic data is inventoried. |
| `supertag-service-org.el` | Shared document operations still require legacy services. Batch 2 routes public positional/multi-node Move through the common writer; this does not retire other legacy dependencies. |
| `supertag-migration-preflight.el` | New internal read-only explicit-Store report. Must not join default startup or implicitly load/migrate user data. |
| Persistence 6.1 work in inherited tree | Removes duplicate node-tag projections; still uses stable tag IDs. This is not the planned name/path tag cutover. |

### Consumer-first dependency cuts

| Retained consumer → existing dependency | Replacement order |
| --- | --- |
| `supertag-view-node.el` relation display | Node View renders configured, saved Org relation links through the shared named-link query. Ordinary references, tags, properties, and mentions remain; archived typed-Link and schema-derived relation UI are not fallback sources. |
| `supertag-view-stream.el` → view-node, view-api and service-org | Complete-set browsing retains the shared query/runtime. Stream edit finish delegates whole-file save and node projection to service-org; transient session state tracks native-save cancellation and source context. Remaining indirect legacy read dependencies still need separate retirement. |
| `supertag-services-reference.el` → services-query → board-ops/link-definition/ops-field/services-formula | Keep text-link/backlink reads and retained queries, remove archived query branches and dependencies next. An indirect board dependency does not mean the board UI is opened by default. |
| `supertag-ui-reference.el` → shared template/service-org creation; template → shared vault selection | Add Link/Find/Promote use complete data-only presets. Promote reuses explicit heading locations and service-org relocation, retaining durable targets on later source failures. Monitoring reads persisted-ID nodes in current template files; it does not scan ID-less headings or create identities. Root and standalone templates share the effective-vault selector. |
| `supertag-ui-embark.el` → ui-act retained target dispatch | Default field/table/tag DWIM entry points and archived lazy loads are retired; tag Rename/Delete/Remove remain explicit menu choices and `All Supertag commands...` is the safe fallback. Native WHERE/WHAT/ACTION redesign and removal of the remaining wrapper wiring are still separate work. |
| Capture/Embed/virtual default entry points → archive components | Standalone Capture commands and old field editors are retired in favor of Org Capture and source-Org property editing. Embed hooks and commands plus virtual-column menus are absent from ordinary init; explicit archive loading retains their implementations and generated Embed text remains excluded from extraction. |

The `text-link-node-view` suite covers configured protocol ownership, real Org
save/projection/query/render, same-endpoint identity isolation, cleanup, edit,
deletion, and pure reindex behavior.

These are key blocking edges, not an exhaustive dependency graph. Removing only the root `require` block would leave indirect loading intact.

## Baseline preservation

Batch 2 acceptance (2026-09-05): main-tree moves 71/71,
regression 202/202, legacy-all 641/641 and contextual 93/93 pass. Review verified
rollback source context/caller-marker retry and legal delimiter-end targets
while rejecting drawer/block interiors. Recovery of arbitrary unrelated markers
and crash atomicity remain outside the verified boundary. Tests are synthetic,
not manual acceptance in a real note vault.

Batch 2 tracked baseline: `b999c45667a0655ad587ab32242481ba5b7857a0`, pinned at
`refs/supertag/batch2-baseline-20260905`. Required untracked batch 1 test/module
files were explicitly copied into isolated worker trees, not taken from backups.
The expanded `move-legacy` baseline exposed two omitted tests: an obsolete
requirement to call the nested saving materializer, and a real loss of stub
identity/backlink Projection. Batch 2 changes the former boundary assertion and
repairs the latter behavior; semantic backlink assertions must remain intact.

Batch 2 service coverage must include pre-edit target anchors, both same-file
directions (including native capture use), multiple normalized roots, folded
and ID-less selection, Under/After nesting, all affected saves/compensation,
independent stub IDs, and public cancellation/source context. The UI is not a
second writer and must call the service only once per accepted operation.

Source: `/Users/chenyibin/Documents/emacs/package/supertag`, branch `supertag-refactor`.
Inherited HEAD: `56dc6867ba0bfaa8cad1a89e30ae7196a3886c1f`.
Non-mutating tracked snapshot: `17356fe6ed1ae494dcdb493f015a4835b0c2d98d`, retained at `refs/supertag/batch1-baseline-20260905`.
Inherited tracked patch SHA256: `d63e977def8dc292fb7e4f8f5290cb6989d17b8771be7393e5712ddd78baa4b4`.
The snapshot does not include pre-existing untracked design documents or `sueprtag-backup/`; these remain untouched in the main worktree.
