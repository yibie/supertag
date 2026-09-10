The legacy schema/table/kanban/search/capture entry points described here are archived; see README for the current workflow.

# SUPERTAG-PLUGIN-GUIDE: Full Plugin Developer Guide

This is the canonical developer guide for building supertag plugins.

Core principles:

- Org owns Document Facts; the database owns Semantic Facts and physically contains rebuildable Projections.
- Plugins primarily extend *views* (any UI), not schemas.
- Plugins MUST read data through the **UI-agnostic View Data API** (`supertag-view-api.el`).
- Writes go through **ops** APIs and (usually) `supertag-with-transaction`.

Built-in DSL example:

- `M-x supertag-view-dsl-example`

Chinese version:

- `doc/SUPERTAG-PLUGIN-GUIDE_cn.md`

## 0) Data model & conventions

### Entities and storage

supertag currently stores Semantic Facts, Document Projections, and derived
state in one central hash-table Store. The Store is a physical container, not
the owner of every fact in it. See `doc/OWNERSHIP-CONSTITUTION_cn.md`.

Common collections and their types:

- `:nodes` — node entities (plist)
- `:tags` — tag entities (plist)
- `:relations` — relation entities (plist)
- `:field-definitions`, `:tag-field-associations`, `:field-values` — global field model

### Entity representation

- Entities are **plists** (property lists), usually containing `:id` plus other keys.
- Entity IDs are strings.
- Keys are keywords (e.g. `:title`, `:file`, `:tags`).

### Read vs write contract

- Read APIs return plists and MUST be treated as immutable snapshots by plugin code.
- Document Fact writes go through document commands; Semantic Fact writes go
  through the matching ops function. Both emit the events needed by views.

## 1) Read APIs (View Data API)

The View Data API is **internal public** and UI-agnostic. Use it for *all* data reads
in plugins (even if you do not use table UI).

File:

- `supertag-view-api.el`

### Query spec

Many read APIs take a `QUERY-SPEC` plist, e.g.:

- `(:type :tag :value "foo")` → nodes that have tag "foo"
- `(:type :nodes)` → all node IDs
- `(:type :tags)` → all tag IDs

### API list (read-only)

**Dataset**

- `(supertag-view-api-list-tags) -> (list string)`  
  All tag names (sorted).

- `(supertag-view-api-tag-id TAG-NAME) -> string-or-nil`  
  Tag name → tag id.

- `(supertag-view-api-list-entity-ids QUERY-SPEC) -> (list string)`  
  Entry point to get IDs for a dataset.

**Entity fetch**

- `(supertag-view-api-get-entity TYPE ID) -> plist-or-nil`  
  Fetch one entity. `TYPE` supports aliases like `:node/:nodes`, `:tag/:tags`, etc.

- `(supertag-view-api-get-entities TYPE IDS) -> (list plist)`  
  Batch fetch (recommended for performance).

**Raw collections (legacy compatibility)**

- `(supertag-view-api-get-collection COLLECTION) -> hash-table`  
  Transitional legacy Interface that returns an underlying Store collection.
  Do not use it in new plugins. Use a specific query helper; if none exists,
  add the smallest domain query to the existing query Module. Removal is tracked
  by ownership-separation `task026`.

**Field access**

- `(supertag-view-api-node-field-in-tag NODE-ID TAG-ID FIELD-NAME) -> value`  
  Read a node field value within a tag context (field values).

**Subscription**

- `(supertag-view-api-subscribe EVENT FN) -> unsubscribe-fn`  
  Subscribe to changes. `EVENT` is a keyword like `:node-updated` / `:store-changed`
  or a store path list. Returns an `unsubscribe-fn` you should call on cleanup.

## 2) Write APIs (Ops layer)

Plugins MUST NOT mutate the raw Store. Use document commands for Document Facts
and ops functions for Semantic Facts.

### Transactions (recommended)

Most write flows should be wrapped in:

```elisp
(supertag-with-transaction
  ;; multiple ops here
  ...)
```

This batches notifications and makes the UI react once per logical change.

### API list (common writes)

**Nodes**

- `(supertag-node-create PROPS) -> node-plist`  
- `(supertag-node-update NODE-ID UPDATER) -> node-plist-or-nil`  
- `(supertag-node-delete NODE-ID) -> deleted-node-or-nil`

**Tags**

- `(supertag-tag-create PROPS) -> tag-plist`  
- `(supertag-tag-update TAG-ID UPDATER) -> tag-plist-or-nil`  
- `(supertag-tag-delete TAG-ID) -> deleted-tag-or-nil`  
- `(supertag-tag-add-field TAG-ID FIELD-DEF) -> tag-plist`  
- `(supertag-tag-remove-field TAG-ID FIELD-NAME) -> tag-plist`

**Fields**

- `(supertag-field-set NODE-ID TAG-ID FIELD-NAME VALUE) -> VALUE`  
- `(supertag-field-set-many NODE-ID SPECS) -> plist`  
  `SPECS` is a list of `(:tag-id TAG-ID :field FIELD-NAME :value VALUE)` items.

**Relations**

- `(supertag-relation-add-reference FROM-ID TO-ID) -> t-or-nil` (Store-only; never writes Org)
- `(supertag-relation-delete RELATION-ID) -> deleted-relation-or-nil`

Data conventions for writes:

- IDs are strings.
- UPDATER functions receive the current plist and return the updated plist (or nil to abort).
- Prefer calling ops functions inside a transaction when you do multiple writes.

## 2.5) Schema Registration (Advanced)

supertag allows users to register/override schemas at init time.
This is intended for advanced setups (custom entities or extended validation),
and does not provide automatic migrations.

Recommended configuration pattern:

```elisp
(setq supertag-schema-registration-functions
      (list
       (lambda ()
         ;; Override/extend an existing schema (merge by default).
         (supertag-schema-register :node '(:my-field (:type :string :default "")))

         ;; Or register a brand new entity type + schema.
         (supertag-register-entity-type
          :my-entity
          '(:id (:type :string :required t)
            :name (:type :string :default "")))))))
```

## 3) Transaction system (what it actually means)

File:

- `supertag-core-transform.el`

API:

- `(supertag-with-transaction ...)`

Semantics:

- It **suppresses notifications** during the body and emits a **batch** of changes
  after the body finishes.
- It provides `supertag--transaction-active` and collects a transaction log.
- It currently focuses on notification batching; do not assume full rollback
  semantics unless explicitly implemented in code.

## 4) Built-in DSL example

File:

- `supertag-view-framework.el`

It demonstrates:

- defining a View from declarative Widget configuration
- nested Widgets and function-valued bindings
- registering the View through the public View Framework

## 5) Validation checklist (manual)

1. Run `M-x supertag-view-dsl-example`.
2. Run `M-x supertag-view-select-and-render`, enter the `demo` tag, and select
   `DSL Example`.

3. Verify:

- the Overview section renders
- the stats row reflects the supplied View context
- the progress bar and list render through the normal Runtime path
