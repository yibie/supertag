# Ontology Foundation: actual status in the Links v3 branch

This file records the implementation that is actually present in this branch.
It replaces the earlier aspirational Foundation v2 note, which described several
boundaries that the code had not yet implemented.

## Present foundation

Ontology source is an upstream declaration layer over the existing Supertag
Schema and Store:

```text
Ontology source
    -> normalize
    -> validate
    -> diff against last deployed specification
    -> explicit apply
    -> existing Tag / Field / Link Definition operations
    -> existing Store transaction
```

Implemented now:

- pure declaration registration: loading a source file does not write the Store;
- deterministic runtime IDs, separated from mutable labels;
- explicit `:runtime-id` for adopting an existing entity;
- validation and safe/destructive change classification;
- atomic Store mutation through `supertag-with-transaction`;
- code-managed provenance for fields, types, and Link Definitions;
- typed Link Definitions as a separate schema collection;
- concrete Link instances as Semantic Edges in `:relations`.

## Current limitations

The broader Foundation v2 design is not fully implemented in this branch:

- diff currently compares with the last deployed normalized specification, not
  a reconstructed live-Store model;
- deployment provenance is persisted in `supertag-ontology-state-file`, outside
  the main Store lifecycle;
- field/type write protection still uses conservative operation guards rather
  than a first-class authority interface at every schema mutation boundary;
- logical-to-runtime binding is represented by normalized specification IDs,
  not a dedicated binding entity;
- removal, endpoint changes, cardinality changes, and runtime rebinding require
  a future Migration DSL.

These limitations are intentionally stated here so Link v3 is not mistaken for
completion of the entire planned ontology control plane.

## Schema and Ontology

- Tag Schema is the runtime structure currently used by Supertag.
- Ontology source declares the structure that should be deployed.
- Link Definition is schema.
- Link Instance is a semantic fact.
- Org remains the owner of document text and physical links.

## Product workflow

```text
free capture
    -> discover a repeated pattern
    -> shape it with Schema View
    -> stabilize it
    -> adopt it into Ontology
    -> add typed links
    -> later add functions and actions
```

The intended product principle remains:

> Write like Roam; consolidate like Palantir.
