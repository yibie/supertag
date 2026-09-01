# Project Kernel

status: enacted
version: K3
scope: Supertag Emacs package
source: K1 admission set plus E-20260825-005 through E-20260825-007 and E-20260825-009
verified_at: 2026-08-25
confidence: confirmed-only

## Concepts

### Document Fact

since: K1
source: `CONTEXT.md:7`; `doc/OWNERSHIP-CONSTITUTION_cn.md:32`

A fact encoded by Org text or document topology, including node identity,
heading content, Tag Occurrences, and physical Org links.

### Semantic Fact

since: K1
source: `CONTEXT.md:11`; `doc/OWNERSHIP-CONSTITUTION_cn.md:38`

A typed fact not encoded by Org text, including stable Semantic Tags, schemas,
field values, and Semantic Edges.

### Operational Fact

since: K2
source: `CONTEXT.md`; `doc/OWNERSHIP-CONSTITUTION_cn.md:44`; `supertag-core-persistence.el:1194`; `supertag-conflicts.el:431`
status: enacted
scope: authoritative conflict/recovery facts
applies_when: state cannot be rebuilt from Document or Semantic Facts and must survive until explicit resolution
source_evidence: E-20260825-007
verification: conflict merge/persistence/resolution tests in the full ERT suite

Non-rebuildable conflict or recovery state that must remain durable until it
is explicitly resolved. The enacted instance is an unresolved sync conflict;
ordinary runtime state, caches, and Projections do not qualify.

### Projection

since: K1
source: `CONTEXT.md:15`; `doc/OWNERSHIP-CONSTITUTION_cn.md:18`

A disposable representation derived from Document Facts, Semantic Facts, or
both. It has no independent ownership and must be rebuildable.

### Tag Occurrence and Semantic Tag

since: K1
source: `CONTEXT.md:19`; `CONTEXT.md:23`

A Tag Occurrence is a token physically present in an Org document. A Semantic
Tag is a stable semantic identity that may own a canonical name, aliases,
inheritance, and schema.

### Document Link, Semantic Edge, and Backlink

since: K1
source: `CONTEXT.md:27`; `CONTEXT.md:31`; `CONTEXT.md:35`

A Document Link is physical Org text. A Semantic Edge is Store-owned typed
semantics. A Backlink is a derived query answer over those two relation kinds,
not a reciprocal physical link.
Physical Org links inside machine-generated views, including dynamic blocks and
other generated regions, are not Document Link assertions and synchronization
does not extract them.

### Link Definition and Link Instance

since: Ontology Links v3
source: `supertag-ops-link-definition.el`; `supertag-ops-relation.el`

A Link Definition is schema owned by the semantic Store. It identifies the
allowed source type, target type, endpoint cardinalities, and optional inverse.
A Link Instance is a Semantic Edge in `:relations` that cites exactly one Link
Definition. Definitions MUST NOT be stored as relation instances, and instances
MUST NOT duplicate their definition as an independent schema fact.

## Identities

### Node identity

since: K1
source: `supertag-service-node-identity.el:29`; `supertag-service-node-identity.el:36`

The authoritative node key is the Org heading's persisted ID. Store location
is a Projection and `org-id-locations` is not authoritative.

### Semantic Tag identity

since: K1
source: `CONTEXT.md:23`; `doc/OWNERSHIP-CONSTITUTION_cn.md:38`

A Semantic Tag's stable ID identifies it. Display names, canonical names,
aliases, paths, and Tag Occurrence text are not identity.

### Relation identity

since: K1
source: `supertag-ops-relation.el:208`

Relation identity is deterministic for its owned fact identity so repeated
reconciliation does not create duplicates. For ontology Link instances, the
Link Definition ID is part of identity; two different Link Definitions may
connect the same endpoint pair without collapsing into one relation.

## Relations

### Projection derivation

since: K1
source: `doc/OWNERSHIP-CONSTITUTION_cn.md:18`; `supertag-services-sync.el:2141`

Document and Semantic Facts derive Projections. Reindex may replace
Document-owned Projections but does not transfer ownership of source facts.

### Occurrence resolution

since: K1
source: `CONTEXT.md:23`; `supertag-services-sync.el:842`

A Tag Occurrence may resolve to one Semantic Tag. The token does not own or
become the Semantic Tag.

### Backlink derivation

since: K1
source: `CONTEXT.md:35`; `doc/OWNERSHIP-CONSTITUTION_cn.md:52`

A Backlink is derived from incoming Document Links and Semantic Edges. It does
not require inserting a second link in the target document.

## Lifecycles

### Document Projection lifecycle

since: K1
source: `supertag-services-sync.el:2141`; `doc/OWNERSHIP-CONSTITUTION_cn.md:55`

The lifecycle is extract a complete snapshot, resolve semantic identities,
reconcile Document Projections in a Store transaction, and rebuild derived
indexes. An incomplete snapshot aborts before destructive reconciliation.

### Operational conflict lifecycle

since: K2
source: `supertag-merge.el:433`; `supertag-conflicts.el:431`; `supertag-core-persistence.el:1194`
status: enacted
scope: durable unresolved sync conflicts
applies_when: a semantic merge cannot choose one lossless winner
source_evidence: E-20260825-007
verification: `test/merge-test.el`; `test/conflicts-test.el`; persistence full-suite coverage

A deterministic merge conflict becomes a durable `:sync-conflicts` fact,
survives Store save/load, and is removed atomically only when explicitly
resolved or dropped. It is not rebuildable from the merged winner alone.

### Derived index lifecycle

since: K1
source: `doc/OWNERSHIP-CONSTITUTION_cn.md:66`; `supertag-core-index.el:187`

Store-derived indexes are cleared and rebuilt as one generation after load,
reindex, or rollback. A failed rebuild leaves the generation empty rather than
partially readable.

### Durable Store save lifecycle

since: K1
source: `supertag-core-persistence.el:1429`

The Store is written to a same-directory temporary file, optionally read back
and verified over every durable collection, then atomically renamed. Failure
leaves the previous file untouched.

## Action Contracts

### Ensure node identity at point

since: K1
source: `supertag-service-node-identity.el:36`

- precondition: point is inside an Org heading.
- input: optional explicit ID.
- permitted effect: create the heading's ID property when absent.
- invariant: no global Org ID-location entry is created; caller owns save and projection.
- verification: return the existing or newly persisted ID; reject a conflicting explicit ID.

### Locate a node

since: K1
source: `supertag-service-node-identity.el:160`

- precondition: caller has a node ID.
- input: node ID.
- permitted effect: open the projected file and return a marker; no fact mutation.
- invariant: an existing but broken Store Projection fails closed.
- verification: `org-id-find` is used only when the node is absent from Store and compatibility fallback is enabled.

### Mutate a document Tag Occurrence

since: K1
source: `supertag-service-org.el:320`; `supertag-service-org.el:381`

- precondition: the node resolves to a file-backed Org buffer and the Semantic Tag resolves.
- input: node identity and add/remove/replace intent.
- permitted effect: edit the Tag Occurrence, save Org, then reproject the affected node.
- invariant: no Projection update occurs before a successful save.
- verification: the save-and-project helper performs one node projection and reconciles field lifecycle.

### Create, delete, or demote a document node

since: K2
source: `supertag-service-org.el:335`; `supertag-service-org.el:416`; `test/document-command-ownership-test.el`
status: enacted
scope: file-backed Org node create/delete/demote
applies_when: an interactive command changes a node's Document Fact
source_evidence: E-20260825-005; E-20260825-006
verification: `test/document-command-ownership-test.el`; ownership/identity/transaction regressions

- precondition: point identifies a heading in a file-backed Org buffer; destructive commands are confirmed by the caller.
- input: create, delete-subtree, or remove-identity intent and the affected node ID.
- permitted effect: make a recoverable Org edit, save it, then reconcile the affected node Projection.
- invariant: save failure writes no Projection and restores destructive in-memory edits; post-save Projector failure preserves durable Org and rolls Store changes back.
- verification: return the node ID on success or signal `supertag-projection-error` with executable service-level retry data.

### Commit a Canonical Change

since: K3
source: `supertag-core-change.el:142`; `supertag-core-change.el:230`; `supertag-core-change.el:269`; `supertag-board-ops.el:33`; `test/canonical-change-test.el`
status: enacted
scope: production Store commit seam enacted for board creation
applies_when: the seam owns the outer transaction and receives a validated bounded envelope
source_evidence: E-20260825-009
verification: 11 focused Canonical/legacy tests; 92-test related gate; 573-test full suite

- precondition: a validated authority/scope envelope enters the seam outside an ambient Store transaction.
- input: authority, scope, operation, subject, cardinality, bounded affected counts, metadata, and a mutation body.
- permitted effect: commit one real Store mutation transaction, then enqueue one delivery batch containing one in-process Canonical Change followed by ordered temporary legacy path events derived from the private CommitRecord.
- invariant: managed immediate legacy delivery is suppressed; raw first-touch paths remain private; no-op/error/rollback publish zero; complete batches dispatch FIFO without reentry or interleaving; one callback cannot subscribe to both Canonical and legacy change topics; Canonical subscriber failure cannot roll back committed Store.
- verification: focused tests cover all authorities/scopes, post-commit delivery, exact legacy path parity, topic exclusivity, nested causation, bounded diagnostics, batch summaries, and subscriber isolation.

### Create a board

since: K3
source: `supertag-board-ops.el:21`; `test/canonical-change-test.el:330`
status: enacted
scope: creation of one persisted board Semantic Fact
applies_when: `supertag-board-create` is called outside an ambient Store transaction
source_evidence: E-20260825-009
verification: `supertag-board-create-is-the-canonical-tracer-writer`; full ERT suite

- precondition: caller supplies a title and board creation can own the outer Store transaction.
- input: title plus generated board ID and timestamps.
- permitted effect: write one board with the existing shape, return it, publish one `:board-created` Canonical Change, then one compatible legacy Store event.
- invariant: board shape, Store path, return value, and one-write behavior remain stable; board update/delete and every other writer remain unmigrated.
- verification: fixed ID/time ERT compares returned and stored values, write count, classification, event payload, delivery order, and rollback.

### Reindex Org

since: K1
source: `supertag-services-sync.el:2141`

- precondition: configured source discovery can produce a complete snapshot.
- input: current configured Org source set.
- permitted effect: replace Document Projections and derived indexes.
- invariant: Org files and Semantic Facts are not modified.
- verification: return `complete`, `aborted`, or `failed`; incomplete input aborts and transaction failure rolls Store changes back.

### Save the durable Store

since: K1
source: `supertag-core-persistence.el:1429`; `supertag-core-persistence.el:1495`

- precondition: persistence guards permit saving and the in-memory Store is dirty.
- input: optional database path.
- permitted effect: atomically replace the durable Store snapshot after verification.
- invariant: a failed write or verification does not replace the previous file.
- verification: durable collections round-trip canonically before rename.

## Invariants

### Facts and Projections remain distinct

since: K1
source: `doc/OWNERSHIP-CONSTITUTION_cn.md:14`; `CONTEXT.md:15`

Physical co-location in Store does not make a Projection authoritative. A
Projection cannot silently become a second owner of a Document or Semantic
Fact.

### Fact authority and change scope are orthogonal

since: K2
source: `.specs/ownership-safe-mutations/SPEC.md`; `supertag-core-change.el:15`; `supertag-core-change.el:19`; `test/canonical-change-test.el`
status: enacted
scope: Canonical Change v1 classification
applies_when: describing any committed Document, Semantic, or Operational mutation
source_evidence: E-20260825-007
verification: `supertag-change-validates-v1-envelope`

Every Canonical Change identifies one fact authority (`:document`,
`:semantic`, or narrowly `:operational`) independently from whether the
mutation touches `:fact`, `:projection`, or `:fact+projection`. Projection is
never promoted to an authority.

### Reindex is not Semantic Restore

since: K1
source: `CONTEXT.md:39`; `CONTEXT.md:43`; `doc/OWNERSHIP-CONSTITUTION_cn.md:55`

Reindex rebuilds Document Projections and indexes. Non-rebuildable Semantic
Facts require backup or synchronized restore.

### Runtime identity is Store-first and fail-closed

since: K1
source: `CONTEXT.md:47`; `supertag-service-node-identity.el:160`

Runtime features use the node-identity boundary. A broken projected location
must not be hidden by a stale global Org ID cache.

### Current package name is Supertag

since: K1
source: `AGENTS.md:20`; `supertag.el:1`

New runtime symbols, entry points, and data paths use `supertag`. The previous
name appears only in migration, historical, and compatibility contexts.

## Architecture boundaries

### Runtime node identity

since: K1
source: `CONTEXT.md:47`; `supertag-service-node-identity.el:1`

- authority: `supertag-service-node-identity.el`
- second site: none for runtime lookup; compatibility fallback is confined inside this module.

### Org Tag Occurrence mutation

since: K1
source: `supertag-service-org.el:320`; `supertag-service-org.el:381`

- authority: `supertag-service-org.el`
- second site: external user edits are accepted source changes and are reconciled by Projector tests.

### Org-backed Document Commands

since: K2
source: `supertag-service-org.el:335`; `supertag-service-org.el:416`
status: enacted
scope: Document Command ordering
applies_when: create/delete/demote or Org-backed tag mutation crosses save/project boundaries
source_evidence: E-20260825-005; E-20260825-006
verification: `test/document-command-ownership-test.el`; `test/architecture-boundary-test.el`

- authority: `supertag-service-org.el`
- second site: `supertag-ui-commands.el` owns prompts and messages only; it does not order Document and Projection writes.

### Complete Document reindex

since: K1
source: `supertag-services-sync.el:2141`

- authority: `supertag-services-sync.el`
- second site: point projection exists for saved-node updates; parity is enforced by ownership/sync tests.

### View lifecycle

since: K1
source: `supertag-view-framework.el:32`; `supertag-view-framework.el:137`

- authority: `supertag-view-framework.el`
- second site: renderers implement adapters but do not own open/refresh/cleanup lifecycle.

### Durable Store persistence

since: K1
source: `supertag-core-persistence.el:1429`

- authority: `supertag-core-persistence.el`
- second site: none for canonical atomic Store replacement.

### Canonical committed change

since: K3
source: `supertag-core-change.el:186`; `supertag-core-change.el:230`; `supertag-core-change.el:269`; `supertag-core-notify.el:24`; `supertag-board-ops.el:33`; `test/canonical-change-test.el`
status: enacted
scope: Canonical Change commit and delivery
applies_when: board creation or a future separately approved writer enters the outer-transaction-owned change seam
source_evidence: E-20260825-009
verification: `test/canonical-change-test.el`; exact-one-production-caller scan; full ERT suite

- authority: `supertag-core-change.el`
- second site: `supertag-core-notify.el` is the temporary legacy adapter for immediate-event suppression and subscription entry; it delegates topic exclusivity to the authority and has parity tests in `test/canonical-change-test.el`.

### Board creation

since: K3
source: `supertag-board-ops.el:21`; `test/canonical-change-test.el:330`
status: enacted
scope: board shape and creation command
applies_when: creating a new persisted board
source_evidence: E-20260825-009
verification: `supertag-board-create-is-the-canonical-tracer-writer`

- authority: `supertag-board-ops.el`
- second site: `supertag-core-change.el` owns transaction/event delivery only and does not define board shape; the focused board tracer test separates both rules.

### Operational sync-conflict facts

since: K2
source: `supertag-merge.el:433`; `supertag-conflicts.el:431`; `supertag-core-persistence.el:1194`
status: enacted
scope: creation, durability, and termination of sync-conflict facts
applies_when: merge produces or a user resolves an unresolved sync conflict
source_evidence: E-20260825-007
verification: `test/merge-test.el`; `test/conflicts-test.el`; full ERT suite

- authority: merge conflict creation belongs to `supertag-merge.el`; explicit resolution/removal belongs to `supertag-conflicts.el`.
- second site: persistence stores the collection but does not own conflict creation or resolution semantics.

## Source evidence

### K1 admission set

since: K1
source: `CONTEXT.md`; `doc/OWNERSHIP-CONSTITUTION_cn.md`; `test/ownership-separation-test.el`; `test/node-identity-test.el`; `test/supertag-persistence-test.el`

K1 contains only terminology, identities, action contracts, and boundaries
directly supported by the cited accepted document, runtime code, and stable
tests. Conflicting or proposed architecture remains outside enacted K1 until a
confirmed Plan resolves it.

### K2 admission set

since: K2
source: `EVIDENCE.md#e-20260825-005`; `EVIDENCE.md#e-20260825-006`; `EVIDENCE.md#e-20260825-007`; `test/document-command-ownership-test.el`; `test/canonical-change-test.el`
status: enacted
scope: K1 to K2 model delta
applies_when: governing Document Commands, Canonical Change, or Operational Facts
source_evidence: E-20260825-005; E-20260825-006; E-20260825-007
verification: focused gates plus 569-test full-suite run

K2 enacts Document-first node commands, structured Projector recovery,
orthogonal change authority/scope, the isolated Canonical Change FIFO, and the
narrow Operational Fact already embodied by durable unresolved sync conflicts.
It does not claim a production Canonical Change migration, a new Operational
writer, or a new durable collection.

### K3 admission set

since: K3
source: `EVIDENCE.md#e-20260825-009`; `.specs/canonical-change-legacy-bridge/SPEC.md`; `test/canonical-change-test.el`
status: enacted
scope: K2 to K3 Canonical Change production delta
applies_when: governing migrated Canonical writers and temporary legacy compatibility delivery
source_evidence: E-20260825-009
verification: 11 focused tests; 92-test related gate; 573-test full-suite run

K3 enacts the private CommitRecord-to-legacy adapter, complete FIFO delivery
batches, topic exclusivity, bounded bridge diagnostics, and
`supertag-board-create` as the sole production Canonical writer. It does not
enact ambient transaction support, another writer or consumer migration, a
durable event log, or deletion of legacy `:store-changed`.


## Ontology Declaration Authority

Ontology-as-Code is a control-plane declaration, not a second semantic store.

- Loading an ontology source file MUST NOT mutate canonical or semantic state.
- A normalized ontology specification MUST be validated and diffed before apply.
- A code-managed schema entity has exactly one authority: its ontology module.
- Interactive editors MUST NOT silently overwrite a code-managed entity.
- Stable ontology IDs are independent from mutable display labels.
- A deployment is one atomic store transaction followed by one notification.
- Destructive changes require an explicit migration; force-apply is not a migration.
- UI projections, previews, and generated lenses are never fact owners.

The deployment boundary covers Field Definitions, semantic Types, Type
inheritance, Type/Field associations, typed Link Definitions, Function
Definitions, Action Definitions, and Policy Definitions. Concrete Link
instances remain Semantic Facts in `:relations`; ontology deployment creates
Link schema, while Action execution may create or remove instances only through
the canonical typed-Link Ops boundary.

## Ontology Function, Action, and Policy

since: K4 candidate
source: `.specs/ontology-policy-v11/SPEC.md`; `ONTOLOGY-POLICY-V11.md`;
`supertag-ontology-function.el`; `supertag-ontology-action.el`;
`supertag-ontology-policy.el`; `tests/supertag-ontology-action-test.el`;
`tests/supertag-ontology-policy-test.el`
status: implemented; runtime ERT verification pending
scope: executable ontology behavior and authorization
applies_when: deploying or invoking Function, Action, or Policy contracts
verification: focused ERT source, static structure/dependency checks, exact
patch reproduction, and ZIP reproduction; real Emacs execution remains pending

- A Function is a typed, read-only computation. It may read the Store through
  trusted code, but official Store mutations are rejected and rolled back. Its
  result is a transient Projection and is not persisted by the Function layer.
- Function, Action, and Policy create/update plans are `:behavioral`. Safe
  auto-apply never deploys executable contract changes; explicit behavioral
  approval is required. Destructive removal or structural rebinding remains a
  Migration concern.
- An Action is a Semantic Fact writer. It owns one outer Canonical Change with
  `:authority :semantic` and `:scope :fact`; it re-resolves its deployed
  contract, actor Policy, parameters, Function preconditions, Field facts, Link
  facts, and cardinality inside that transaction before applying effects.
- Action v1 effects are declarative Field and typed-Link operations. The Action
  subject occupies one Link endpoint; `node-reference` Field mutation is not a
  second relationship writer.
- Ops post-events produced inside an Action are deferred until the outer Action
  commits and are discarded on rollback. Failed Action attempts are not durable
  success facts. Post-commit hook failures are isolated from the committed
  Action result.
- A Policy is data, not a callback. Every deployed Action has exactly one Policy
  covering exactly the closed actor classes `:interactive-user`, `:automation`,
  `:llm`, and `:external`. The closed decisions are `:allow`, `:deny`,
  `:confirm`, and `:propose-only`. Missing, duplicate, ambiguous, or malformed
  policy data denies by default.
- Action callers state an actor explicitly. `:confirm` uses a memory-only,
  expiring, one-use capability bound to Action and Policy contract hashes,
  subject, actor, normalized arguments, and exact planned effects.
  `:propose-only` can inspect a transient proposal but cannot be elevated into
  execution by confirmation.
- Policy authorizes an actor; Function preconditions validate the current world.
  Neither layer substitutes for the other. Actor-ID-specific rules, roles,
  attribute conditions, and durable proposal queues remain outside K4.

## Ontology LLM Tool Projection

since: K5 candidate
source: `.specs/ontology-llm-tool-v12/SPEC.md`;
`ONTOLOGY-LLM-TOOL-V12.md`; `supertag-ontology-tool.el`;
`tests/supertag-ontology-tool-test.el`
status: implemented; runtime ERT verification pending
scope: transient provider-neutral capability projection
applies_when: discovering or invoking explicitly exposed Ontology capabilities
verification: focused ERT source, static structure/dependency checks, exact
patch reproduction, and ZIP reproduction; real Emacs execution remains pending

- Tool generation scans no arbitrary Emacs Lisp symbols. Only deployed Function
  or Action contracts with explicit `:llm-tool t` may become descriptors.
- The generated catalog, tool descriptors, proposals, and confirmation tokens
  are transient Projections. They are not durable fact collections or a second
  execution registry.
- Function tools are read-only. Action tools are filtered by the closed `:llm`
  Policy decision: `allow` maps to execution, `confirm` requires an out-of-band
  one-use capability, `propose-only` maps to proposal-only, and `deny` is not
  exposed.
- Generated names include current executable and authorization fingerprints.
  A Function, Action, or Policy contract change invalidates older names; stale
  calls fail closed instead of being redirected to newer behavior.
- JSON `false`, JSON `null`, omission, and empty arrays preserve distinct typed
  meanings. Confirmation and execution use the same typed argument conversion
  before Policy fingerprints are calculated.
- Provider transport is outside K5. OpenAI, Anthropic, gptel, MCP, HTTP, or
  other adapters may translate the provider-neutral catalog, but may not bypass
  the catalog resolver, Policy decision, Action transaction, or confirmation
  boundary.
