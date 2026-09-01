# Ontology Link Workflow v5

## Purpose

This release turns the typed-Link kernel into a usable Supertag workflow without
introducing a second graph database or a new editor model.

The model remains deliberately small:

```text
Link Definition
  describes one allowed relation between two semantic Types

Link Instance
  records one concrete relation between two Nodes

Link Query
  selects Nodes by traversing those typed relations
```

Example:

```text
Definition
  Project --tasks--> Task

Instances
  StackWM --tasks--> Fix region migration
  StackWM --tasks--> Add Link query
```

The definition belongs to the Schema/Ontology control plane. The instances
belong to the semantic relation Store. Org files remain the source of document
content and are not rewritten to create reciprocal physical links.

## What v5 adds

### 1. Link Definition management in Schema View

Open:

```text
M-x supertag-view-schema
```

Commands:

```text
a l   create an interactive Link Definition
e l   edit the Link Definition at point
d d   delete the Link Definition at point
```

Each definition shows:

```text
name
source Type
source cardinality
target cardinality
target Type
authority: interactive or ontology module/key
```

Ontology-managed definitions are read-only in Schema View. `e l` jumps to the
source declaration instead of creating a competing UI definition.

### 2. Link Instance workflow in Org and Node View

At an Org heading or in Node View:

```text
l a   add a typed Link
l d   remove a typed Link
l l   open the Link action menu
```

The same commands are available through `M-x supertag-menu` under “Typed
Links”.

When adding a Link, Supertag:

1. reads the current Node's Types;
2. offers only Link Definitions applicable to those Types;
3. determines forward or inverse direction;
4. offers only Nodes satisfying the opposite endpoint Type;
5. excludes an already-linked endpoint;
6. validates both endpoint Types and cardinalities before mutation;
7. asks explicitly before replacing a conflicting one-to-one Link;
8. performs conflict replacement and creation in one Store transaction.

The Node View renders a “Typed Links” section grouped by relation and
direction. Every target/source is clickable.

### 3. Composable Link query operators

Forward traversal filters source Nodes by a nested target query:

```elisp
(link work/tasks
      (field "status" "blocked"))
```

The expression means:

```text
return source Nodes that have work/tasks Links
to targets whose status is blocked
```

Reverse traversal filters target Nodes by a nested source query:

```elisp
(reverse-link work/tasks
              (tag "project"))
```

Existence checks:

```elisp
(has-link work/tasks)
(has-reverse-link work/tasks)
```

`exists-link` is an alias for `link`:

```elisp
(exists-link work/tasks
             (tag "task"))
```

Link operators compose with the existing language:

```elisp
(and
  (tag "project")
  (link work/tasks
        (and
          (tag "task")
          (field "status" "blocked"))))
```

Traversal can be nested:

```elisp
(link work/projects
      (link work/tasks
            (field "status" "blocked")))
```

A Link reference may be:

```text
runtime Link Definition ID
unique display name
unique ontology key
module/key
```

Use `module/key` in saved queries. It is stable, readable, and unambiguous.

The guided query builder and `M-x supertag-query-describe-syntax` now expose
these operators.

## Query extension boundary

v5 does not hard-code graph traversal throughout the query engine. It adds one
small extension registry:

```text
supertag-query-operator.el
```

A query extension registers:

```text
surface operator -> AST parser
AST type         -> executor
```

Typed-Link traversal lives in:

```text
supertag-query-link.el
```

The existing `and`, `or`, `not`, field extraction, sorting, aggregation and
query entry points remain unchanged. This boundary can later support other
well-defined semantic operators without turning the core parser into a large
conditional.

## Read/write module boundaries

```text
supertag-ops-link-definition.el
  Link Definition invariants, identity and reference resolution

supertag-ops-relation.el
  typed Link instance mutation, validation and indexed lookup

supertag-services-link.el
  read-only UI model: directions, instances and legal candidates

supertag-ui-link.el
  interactive instance commands

supertag-ui-link-definition.el
  interactive definition commands

supertag-view-link.el
  Node View projection

supertag-view-link-definition.el
  Schema View projection

supertag-query-operator.el
  generic query extension seam

supertag-query-link.el
  typed-Link query grammar and execution
```

Views do not mutate the Store. Services do not render buffers. Ops own domain
invariants and writes.

## Control-plane corrections included in v5

The downloadable v4 artifact was used as the actual baseline. Before adding
Link UX, v5 corrects several control-plane seams:

- runtime diff reads real `:tag-field-associations`;
- Field/Type/Link deployment maps directly to current Ops APIs;
- Ontology Bindings and module provenance are canonical Store collections;
- planning compares the supplied live snapshot only;
- explicit adoption produces a Binding operation even when structure matches;
- implicit same-name adoption and runtime rebinding are rejected;
- deployment rejects stale plans;
- an empty plan does not enter a write transaction;
- Field/Type/Link operations, Binding writes and provenance writes share one
  transaction;
- old v4 `:ontology-control-plane` metadata remains readable; the next
  non-empty deployment writes authoritative canonical Binding/module records.

These changes do not create another Schema Store. Runtime Schema remains in the
existing Tag, Field association and Link Definition collections.

## Storage ownership

```text
Org
  document text, headings and physical links

Supertag Store
  Nodes, Types, Fields, typed Link instances, runtime Bindings and provenance

Ontology source
  desired managed Type/Field/Link structure

Views
  projections only
```

A typed Link is one semantic fact. `inverse-name` changes how the same fact is
shown from the target side; it does not create a second relation.

## Compatibility

The existing typed-Link API remains available:

```elisp
(supertag-link-create definition-id from-id to-id)
(supertag-link-targets definition-id from-id)
(supertag-link-sources definition-id to-id)
(supertag-link-delete definition-id from-id to-id)
```

v5 adds:

```elisp
(supertag-link-conflicts definition-id from-id to-id)
(supertag-link-create-replacing-conflicts definition-id from-id to-id)
(supertag-link-instances-for-node node-id)
(supertag-link-definition-resolve reference)
```

No existing untyped relation is automatically converted. A future explicit
migration must classify and validate legacy relations before conversion.

## Deliberate limits

This release does not implement:

```text
legacy Relation -> typed Link migration
Link endpoint/cardinality migration DSL
Function
Action
Policy
LLM tool generation
unlinked mentions
full Roam-style contextual backlinks
```

The next clean architectural step is contextual Link/backlink projection and
create-or-link completion, not Function/Action yet.

## Verification boundary

The repository includes focused ERT tests and a batch runner:

```bash
EMACS="/Applications/Emacs.app/Contents/MacOS/Emacs" \
  ./tests/run-link-workflow-tests.sh
```

The build environment used for this release has no Emacs executable. The ERT
tests are therefore written but were not executed there. Static Elisp
structure, shell syntax, patch application, archive integrity and source-tree
reproduction are verified separately in the release validation report.
