# Supertag

Supertag gives Org documents typed semantics without transferring ownership of the documents themselves to the database.

## Language

**Document Fact**:
A fact encoded by the user's Org text or document topology, such as a title, body, heading relation, Tag Occurrence, or Document Link.
_Avoid_: Node data, file-backed semantic data

**Semantic Fact**:
A typed fact that Org text does not encode, such as a Tag schema, field value, or Semantic Edge.
_Avoid_: Metadata, database copy

**Operational Fact**:
Non-rebuildable conflict or recovery state that must remain durable until it is explicitly resolved. It is neither ordinary runtime state nor a general-purpose third fact category.
_Avoid_: Runtime state, cache, projection

**Projection**:
A disposable representation derived from Document Facts, Semantic Facts, or both. It has no independent ownership and can be rebuilt.
_Avoid_: Cache when referring to authoritative data, source of truth

**Tag Occurrence**:
A tag token that physically appears in an Org document.
_Avoid_: Tag entity, Tag definition

**Semantic Tag**:
A stable semantic identity that can own a schema, inheritance, a canonical name, and aliases. A Tag Occurrence may resolve to it without owning it.
_Avoid_: Tag token, tag string

**Document Link**:
A physical Org link owned by the document in which it appears. Links inside
machine-generated views, such as dynamic blocks and other generated regions,
are presentation only and do not assert Document Links.
_Avoid_: Semantic relation, backlink

**Semantic Edge**:
A typed relation owned by the semantic store and not represented by inserting reciprocal text into Org documents.
_Avoid_: Org link, reference cache

**Backlink**:
A derived answer to “which Document Links or Semantic Edges point here?” It is not a second physical link.
_Avoid_: Reciprocal link

**Reindex**:
Rebuild Document Projections and derived indexes from their authoritative facts without changing Semantic Facts.
_Avoid_: Full database rebuild, semantic restore

**Semantic Restore**:
Restore non-rebuildable Semantic Facts from a backup or synchronized copy.
_Avoid_: Reindex, rescan

**Canonical Change**:
A bounded domain description of one committed mutation, stating fact authority and change scope separately without exposing a raw Store diff.
_Avoid_: Store event, path diff, notification payload

**Ontology Function**:
A deployed, typed, read-only domain computation over a semantic subject. Its result is a transient Projection, not a stored fact.
_Avoid_: Formula string, arbitrary callback, cached field

**Ontology Action**:
A deployed, named semantic state transition with typed parameters, Function preconditions, declarative effects, one outer Canonical Change, and a successful-run audit record.
_Avoid_: Emacs command, automation rule, arbitrary callback

**Ontology Policy**:
A deployed, fail-closed authorization contract that decides whether one explicit actor may execute, must confirm, may only propose, or is denied for an Action. It does not replace Action preconditions.
_Avoid_: Business precondition, UI prompt, role cache

## Runtime boundary

`supertag-service-node-identity.el` owns runtime node identity creation and
location lookup. It persists heading IDs as Document Facts, resolves locations
from the Store plus an in-file ID search, and confines the legacy
`org-id-locations` fallback to unprojected compatibility cases. Runtime feature
modules must not call Org's global ID-location APIs directly.
