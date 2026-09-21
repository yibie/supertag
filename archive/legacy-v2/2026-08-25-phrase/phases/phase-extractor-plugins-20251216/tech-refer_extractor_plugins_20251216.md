#+TITLE: Extractor Plugin System Tech Refer (Org-supertag)
#+AUTHOR: Internal
#+DATE: 2025-12-16

* Purpose

This document focuses on building an extractor plugin system for
Org-supertag, using the existing \"read-many, write-once\" baseline as
foundation. It extracts and refines the relevant parts from the sync
phase tech refer and prepares design options for this new phase.

* Baseline: Read-Many, Write-Once in Org-supertag

** Single-file level

- =supertag--parse-org-nodes=:
  - Calls =org-element-parse-buffer= once per file;  
  - Uses =supertag--map-headlines= to turn all headlines into node
    plists;  
  - Ignores embed blocks and keeps parsing side-effect free.
- =supertag-sync-import-file=:
  - For a given file, calls =supertag--parse-org-nodes= once;  
  - Iterates returned node plists and calls =supertag-node-create=
    for each;  
  - These writes are typically wrapped in a higher-level transaction
    (full rescan / auto-sync).

** Batch / transaction level

- Full rescan (=supertag-sync-full-rescan=):
  - Groups work for many files inside a =supertag-with-transaction=
    (or per-queue batch), ensuring a single commit boundary for a set
    of node operations.
- Auto-sync (=supertag-sync--check-and-sync=):
  - Runs the core work of each tick in a single
    =supertag-with-transaction=, regardless of whether queue-based
    processing is enabled.

In other words, the system already approximates \"parse once per file,
many node updates, commit in transactions\".

* Already Achieved \"Read-many, Write-once\"

- Parse cost is paid once per file per operation (per sync/import),
  not once per extractor or per consumer.  
- Node and relation updates are funneled through ops and committed in
  transactions at batch/tick level.

This is a strong base for an extractor plugin architecture: we do not
need to re-invent parsing or transaction handling, only to introduce a
clean extension point on top of them.

* Future Improvements (Extractor-focused)

These are the improvements this phase will focus on (compared to the
sync phase, which only noted them as future work):

- **Extractor plugin API**
  - Define a registry for extractors (e.g. =supertag-extractor-register=
    with name/priority/signature);  
  - Each extractor receives a well-defined context (file path, AST,
    headline element, current node data, etc.) and returns data in a
    structured form.

- **Extractor pipeline over existing parse**
  - Instead of hard-coding all per-headline logic into
    =supertag--convert-element-to-node-plist=, factor it into a set of
    extractors that run over the same parse result;  
  - Ensure we still only parse once per file and reuse the same AST /
    context across all extractors.

- **Store/ops integration**
  - Make extractors responsible only for \"what to extract\", not
    \"how to write\";  
  - Keep writes centralized in ops/commit pipelines wrapped in
    =supertag-with-transaction=, preserving existing transactional
    guarantees.

Other ideas mentioned in the sync phase (transaction tuning for huge
repos, AST caching across subsystems) remain out of scope for this
phase, but the extractor design should avoid making them harder later.

* Current Per-headline Extraction Responsibilities

To design a plugin-friendly extractor API, we first need to understand
what the existing per-headline logic does today and where the natural
boundaries lie.

** Where per-headline extraction lives today

The core per-headline parsing happens in
`supertag--convert-element-to-node-plist` in
`supertag-services-sync.el`. Its responsibilities include:

- ID handling
  - Reads `:ID` from the headline element;  
  - In normal mode, optionally generates a new ID via `org-id-new`
    when `supertag-sync-auto-create-node` is non-nil;  
  - In migration mode, only accepts existing IDs.

- Title normalization
  - Reads `:raw-value` and `:todo-keyword` from the headline;  
  - Removes TODO keywords from the display title;  
  - Strips native Org `:tags:` suffix on the headline line;  
  - Strips inline `#tags` from the title using `supertag--strip-inline-tags`;  
  - Produces:
    - `:title` (cleaned, user-visible title);
    - `:raw-value` (used for hashing).

- Outline path (`:olp`)
  - Uses `supertag--extract-outline-path` to walk ancestor headlines;  
  - Cleans titles similarly to the current headline (remove TODO /
    native tags / inline tags);  
  - Produces an `:olp` list like `(\"Top\" \"Project\" \"Task\")`.

- Tags (`:tags`)
  - Extracts inline tags from the title (`headline-tags`) via
    `supertag--extract-inline-tags` on the raw title;  
  - Extracts inline tags from the contents (`content-tags`) via the
    same helper over `org-element-contents`;  
  - Optionally reads native Org `:tags:` via
    `supertag--extract-org-headline-tags` when
    `supertag-sync--is-full-rescan-p` is true;  
  - Merges and sanitizes tags using
    `supertag--merge-and-sanitize-tags`, producing a clean tag list.

- Properties (`:properties`)
  - Uses `supertag--parse-properties` to collect user-defined
    properties from the headline element;  
  - Excludes standard/internals (IDs, category, etc.);  
  - Returns a plist mapping property keywords to values.

- References (`:ref-to`)
  - Uses `supertag--extract-refs` over the direct contents of the
    headline (excluding child headlines) to find `id:` links;  
  - Produces a list of node IDs referenced by the current node.

- Content (`:content`)
  - Uses `supertag--extract-node-own-content` to get only the
    content belonging to the current headline, excluding its children;  
  - Aggressively strips `:PROPERTIES:` drawers that ended up in the
    content region (due to org-element treating them as paragraphs in
    some cases).

- Structural metadata
  - Reads `:level`, `:todo-keyword`, `:priority`, `:scheduled`,
    `:deadline`, `:begin` (position) from the headline using
    `org-element-property`;  
  - Normalizes `:priority` to a `\"#X\"` string when present;  
  - Stores positional info twice (`:position` and `:pos`) for
    backward-compat/history reasons.

The output is a single node plist with keys:

- `:id`, `:title`, `:raw-value`, `:tags`, `:properties`, `:ref-to`,
  `:file`, `:olp`, `:content`, `:level`, `:todo`, `:priority`,
  `:scheduled`, `:deadline`, `:position`, `:pos`.

** Where \"write\" responsibilities start

The per-headline extractor itself does *not* write to the store. Store
and relation writes happen later, mainly in
`supertag-sync--process-single-file` and helpers:

- For each file:
  - `supertag--parse-org-nodes` returns a list of node plists
    (created via `supertag--convert-element-to-node-plist`);  
  - Compare with existing nodes (via `supertag-find-nodes-by-file`);  
  - Per node:
    - `supertag-node-mark-deleted-from-file` marks deletions;  
    - `supertag-db-add-with-hash` handles create/update:
      - Adds `:id`, `:type`, `:hash`;  
      - Calls `supertag--process-node-tags` to create tag entities and
        node-tag relations;  
      - Calls `supertag--cleanup-orphaned-references` and
        `supertag--process-node-references` to manage references;  
      - Clears `:orphaned-at` when node is tied to a file.

This separation (parse/derive vs. write/commit) is what the plugin
system should preserve and make more explicit.

* Candidate Extractor Types for First Pilot

Based on current responsibilities, good candidates for the first
extractor plugins are:

- **Tag extractor**
  - Inputs: headline element, file, maybe full AST context;  
  - Outputs: consolidated tag list and/or tag-related metadata
    (`:tags`), leaving entity creation/relations to ops;  
  - Today: implemented via
    `supertag--extract-inline-tags`,
    `supertag--extract-org-headline-tags`,
    `supertag--merge-and-sanitize-tags`.

- **Properties extractor**
  - Inputs: headline element;  
  - Outputs: user properties plist (`:properties`), possibly with
    normalization or type hints;  
  - Today: implemented via `supertag--parse-properties`.

- **Reference extractor**
  - Inputs: headline element and contents;  
  - Outputs: `:ref-to` list;  
  - Today: implemented via `supertag--extract-refs` on filtered
    content elements.

- **Outline / title extractor**
  - Inputs: headline element and its ancestry;  
  - Outputs: cleaned `:title`, `:raw-value`, `:olp`;  
  - Today: handled inside `supertag--convert-element-to-node-plist`
    and `supertag--extract-outline-path`.

Starting with tags and properties as initial extractors is likely the
lowest-risk path: they are conceptually self-contained, heavily used
for queries/views, and relatively easy to test in isolation.

* Extractor API Design (Task003)

This section describes the minimal extractor API and registry for the
first iteration of the plugin system. The goal is to be simple enough
to migrate existing logic (tags/properties) while being explicit about
what is allowed (pure extraction) and what is not (writes / side
effects).

** Per-headline extractor function

- Shape:
  - In Emacs Lisp terms, an extractor is a function with the signature:
    - =FUN ELEMENT FILE CTX -> PLIST-PATCH=
- Inputs:
  - =ELEMENT= :: org-element headline node for current outline entry;
  - =FILE= :: absolute file name for the current buffer;
  - =CTX= :: read-only context struct or plist, containing:
    - the full AST for the file (for advanced extractors);
    - ancestor/parent info if needed;
    - parse mode flags (full rescan vs incremental, migration mode
      etc.).
- Output:
  - =PLIST-PATCH= :: a plist with only the keys this extractor owns.
    Examples:
    - Tag extractor: =(:tags (\"tag1\" \"tag2\"))=
    - Properties extractor: =(:properties (\"FOO\" \"bar\" \"BAZ\" \"qux\"))=
- Constraints:
  - Extractors are *pure*:
    - No DB or store writes;
    - No modification of buffers;
    - No logging except optional debug logs under a dedicated flag;
    - No modification of =CTX= or =ELEMENT=.
  - For a given =ELEMENT/FILE/CTX= tuple, result should be stable
    (deterministic), to ease testing and future caching.

** Registry: registration and ordering

To keep core parsing code agnostic of concrete extractors, we use a
small registry.

- Internal representation:
  - A list (or vector) of entries, each entry being a plist:
    - =:name= :: symbolic name, e.g. =tags=, =properties=;
    - =:priority= :: integer used for sorting (lower runs first);
    - =:fn= :: function object satisfying the extractor signature;
    - optionally future fields like =:enabled-p=, =:phase= etc.
- Core API (proposed):
  - =(supertag-extractor-register &key name priority fn)=
    - Adds or replaces an entry with the given =name=;
    - Maintains the registry sorted by =priority=.
  - =(supertag-extractor-unregister name)=
    - Removes the entry with the given =name= if present.
  - =(supertag-extractor-list)=
    - Returns a copy of the current registry contents (for debugging /
      tests).
- Merge behavior:
  - When multiple extractors emit the same key, later extractors
    (higher =priority= or later in order) win for that key;
  - This allows override patterns (e.g. user extractor replacing core
    tag behavior) while keeping semantics predictable.

** Where the pipeline runs in the parse flow

Given the current structure around =supertag--parse-org-nodes= and
=supertag--convert-element-to-node-plist=, the extractor pipeline can
be wired in as follows:

- =supertag--parse-org-nodes=
  - Parses buffer once and obtains the AST;
  - Iterates all headline elements.
- For each headline:
  - Build a base node plist with structural fields that are unlikely
    to be pluggable (=:file=, =:position=, =:level=, =:todo=, etc.);
  - Construct a =CTX= object containing:
    - the full AST;
    - the current file path;
    - sync mode hints (full rescan vs auto-sync);
    - migration flags if needed.
  - Call the extractor pipeline:
    1. Ask the registry for the current ordered extractor list;
    2. For each entry:
       - Call its function with =(ELEMENT FILE CTX)=;
       - Merge the returned =PLIST-PATCH= into the node plist using a
         deterministic merge rule.
- Finally, return the full list of enriched node plists to the
  sync/ops layer.

This keeps the existing \"parse once per file\" behavior intact, while
making per-headline enrichment extensible.

** Merge semantics and ownership of keys

To avoid subtle conflicts when introducing new extractors:

- Each core extractor is responsible for a small, well-defined set of
  keys:
  - Tag extractor: =:tags=;
  - Properties extractor: =:properties=;
  - Reference extractor: =:ref-to=;
  - Outline/title extractor: =:title=, =:raw-value=, =:olp=.
- When merging:
  - For scalar or list fields, later extractors override earlier ones;
  - Extractors that want to *augment* an existing list (e.g. add tags)
    should explicitly read the current value from the node and append /
    merge as needed.
- For third-party extractors:
  - Recommended to use new keys (e.g. =:my-plugin/foo=) to avoid
    unexpected clashes;
  - If overriding a core key is desired, the extractor should be
    registered with a higher =priority= and this behavior should be
    clearly documented.

** User and developer facing surfaces

As a direct consequence of the API design:

- Users:
  - Can enable/disable specific extractors via defcustom options that
    control which built-in extractors are registered;
  - Can install extra packages that call =supertag-extractor-register=
    to add new behavior without touching core sync code.
- Developers:
  - Can implement a new extractor by providing a single pure function
    and calling the register API;
  - Can write focused unit tests for each extractor by constructing
    synthetic =ELEMENT/CTX= and checking the resulting =PLIST-PATCH=,
    without needing to drive the full sync pipeline.

* Task005: Towards full per-headline pluginization

While tasks 001–004 focused on the registry and a couple of pilot
extractors, task005 aims to gradually move *all* per-headline parsing
responsibilities behind the extractor interface, while keeping a small
non-pluggable core (mainly ID generation and minimal bookkeeping).

** Scope and priority

Short-term priorities for extractor migration:

- References (=ref-to=)
  - Today: computed inside =supertag--convert-element-to-node-plist=
    via =supertag--extract-refs= on filtered contents;
  - Next: move this logic into a dedicated =refs= extractor that
    returns =(:ref-to LIST)=.
- Content and outline path (=content= + =olp=)
  - Today: content is extracted via
    =supertag--extract-node-own-content=, then PROPERTIES drawers are
    stripped with a regexp; OLP is computed via
    =supertag--extract-outline-path=;
  - Next: introduce a =content+olp= extractor that owns these two
    fields, allowing future variations (e.g. alternative content
    slicing strategies) to be plugged in.
- Structural fields (title/level/scheduling)
  - Today: =:title=, =:raw-value=, =:level=, =:todo=, =:priority=,
    =:scheduled=, =:deadline= etc. are all set directly in
    =supertag--convert-element-to-node-plist=;
  - Next: evaluate whether they should be grouped into a
    \"core-metadata\" extractor or kept as non-pluggable base fields.

As a first concrete step for task005, this repo migrates the
reference field into a dedicated extractor, leaving the other fields
as future work.
