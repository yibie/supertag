# Contextual Reference Workflow v6

## Purpose

This stage completes the low-friction reference loop without adding another
index or another fact owner:

```text
write [[...
  -> choose an existing node or explicitly create a concept
  -> persist one physical Org link in the source
  -> run the existing document projector
  -> derive outgoing references and incoming backlinks
  -> show both with source context in Node View
```

## Ownership boundary

- The source Org document owns a physical reference.
- `:reference` relations are projections or semantic facts according to their
  existing `:kind` and `:origin` contract.
- A Backlink is a query result over incoming relations. No reciprocal Org text
  is written to the target.
- Context cards are disposable UI projections over node `:content`, `:olp`,
  `:file`, `:position`, and reference relations already present in the Store.
- This stage adds no durable collection and no reference cache.

## Create-or-link

In an Org node, type:

```org
[[Ont
```

Completion offers titles and aliases of existing nodes. If no exact term
exists, it also offers an explicit `[Create new concept]` row. Selecting a row
rewrites the shorthand to the canonical physical link:

```org
[[id:TARGET-ID][Ontology]]
```

The fallback command is:

```text
M-x supertag-reference-insert
```

With a region, the selected text becomes the initial title and is replaced by
the link. With a prefix argument, a newly created concept's destination can be
chosen interactively.

## Concept creation policy

Normal create-or-link does not ask for a file or insertion position. New
concepts are appended as top-level headings to `concepts.org` under:

1. the active Supertag vault;
2. the sync root containing the current file;
3. the first configured sync root;
4. `org-directory`;
5. the current file's directory.

The policy can be changed through:

```elisp
(setq supertag-concept-default-file "/path/to/concepts.org")

(setq supertag-concept-create-target-function
      #'my-supertag-concept-target)
```

A target function receives the title and returns:

```elisp
(:file "/path/to/notes.org" :position nil :level 1)
```

This is the adapter boundary for Org-roam, Denote, or another capture system.

## Contextual Node View

Node View now renders two separate projections:

```text
References
  nodes referenced by the current node

Backlinks
  nodes that reference the current node
```

Each card includes:

- a clickable node title;
- file and outline path;
- relation ownership/kind summary;
- an excerpt centered on the target title or alias when possible.

Multiple relation kinds between the same source and target are aggregated into
one card instead of duplicating the same context.

## Modules

```text
supertag-services-reference.el
  read-only candidates, context excerpts, outgoing/incoming projections

supertag-ui-reference.el
  CAPF, prompts, concept creation choice, physical Org edits

supertag-view-reference.el
  disposable Node View rendering
```

Existing modules retain their responsibilities:

```text
supertag-concept.el
  concept identity, aliases, default creation policy

supertag-ui-commands.el
  source-owned Org link replacement and document reprojection

supertag-ops-relation.el
  relation ownership, identity, validation, and indexes
```

## Deliberate exclusions

This stage does not implement:

- automatic unlinked-mention conversion;
- reciprocal physical links;
- a second backlink database;
- bidirectional transclusion;
- Function, Action, Policy, or LLM tool generation.
