# Ontology Migration DSL v1

Supertag's ontology control plane can detect a destructive Schema change.  The
Migration DSL supplies the missing part: an explicit, reviewable description of
how existing semantic data must be made valid before that Schema change commits.

The migration layer does not create a second Schema store.  It combines:

```text
registered migration declaration
        +
live Ontology diff
        +
live field values / Link instances
        |
        v
read-only migration plan
        |
        v
one existing Supertag Store transaction
        |
        +-- data actions
        +-- destructive Schema deployment
        +-- derived relation reconciliation
        +-- applied-migration ledger
```

## Supported steps

Migration DSL v1 deliberately supports only three operations.

### `transform-field`

Use this when a Field type changes or allowed options are removed.

```emacs-lisp
(defun my-status-v2 (value context)
  (ignore context)
  (pcase value
    ((or "doing" "in progress") "active")
    ((or "finished" "done") "done")
    (_ "idea")))

(supertag-defmigration status-v2
  :module personal-work
  :from 1
  :to 2

  (transform-field status
    :using my-status-v2
    :on-error :abort))
```

The transformer receives `(VALUE CONTEXT)`.  `CONTEXT` includes the migration,
module, logical Field key, runtime Field ID, node ID, and desired Field model.
The returned value is normalized and validated against the target Field before
it enters the plan.

Transformers and Link resolvers are planning callbacks and must be deterministic
and side-effect free.  Supertag runs them inside a read-only transaction check:
any write performed through the canonical Store mutation seams is rolled back
and reported as an impure callback.  The runtime cannot undo arbitrary external
I/O, so migration callbacks must not edit files, buffers, processes, or network
services.

Return `supertag-ontology-migration-drop` to remove one value explicitly.
`:on-error :drop` is also available, but it must be chosen in the declaration;
conversion errors never delete data silently.

### `detach-field`

Use this when a Type no longer owns a Field association.

```emacs-lisp
(detach-field project legacy-status)
```

This removes only the Type–Field association.  It does **not** silently delete
existing Field values.  Global Field deletion and value cleanup require a
future, separately modeled migration step.

### `tighten-link`

Use this when Link cardinality changes from `many` to `one`.

```emacs-lisp
(defun my-keep-primary-project (relations context)
  (ignore context)
  ;; RELATIONS are sorted by stable relation ID before this function runs.
  (car relations))

(tighten-link tasks
  :target-resolver my-keep-primary-project)
```

A resolver receives `(RELATIONS CONTEXT)` for one conflicting endpoint and must
return either the relation plist or its relation ID.  The chosen relation is
kept; every other deletion is shown in the preview and executed in the same
transaction as the cardinality change.

Use `:source-resolver` when source cardinality becomes `one`, and
`:target-resolver` when target cardinality becomes `one`.  A resolver is not
required when live data has no conflict.

## Exact coverage

A migration is accepted only when every destructive operation in the current
live diff has exact coverage, and every declared step covers a current
operation.  This prevents broad declarations from accidentally authorizing an
unrelated change.

Migration DSL v1 continues to reject:

- tightening a Field from optional to required (a future `fill-missing` step
  must explicitly define values for nodes that currently have none);
- Type deletion;
- global Field deletion;
- Type parent changes;
- Link endpoint changes;
- logical/runtime rebinding;
- arbitrary callback steps;
- force flags that bypass validation.

Those operations need dedicated migration models rather than a universal escape
hatch.

## Commands

```text
M-x supertag-ontology-migration-validate
M-x supertag-ontology-migration-preview
M-x supertag-ontology-migration-apply
M-x supertag-ontology-migration-status
M-x supertag-ontology-migration-goto-definition
```

Set declaration files alongside ontology files:

```emacs-lisp
(setq supertag-ontology-files
      '("~/notes/ontology/personal-work.el"))

(setq supertag-ontology-migration-files
      '("~/notes/ontology/personal-work-migrations.el"))
```

Loading either file is registration-only.  It never mutates the Store.

## Apply-time guarantees

A plan is rejected before mutation when:

- the module version changed;
- the registered migration declaration changed;
- the registered desired Ontology model changed;
- the live runtime Schema changed;
- relevant Field values or Link instances changed;
- a source node or relation disappeared;
- a planned node-reference value no longer points to a live node;
- the migration was already applied;
- any destructive operation lacks exact coverage.

Data actions, Schema deployment, derived Field Reference reconciliation, module
provenance, and the applied ledger commit through one existing
`supertag-with-transaction` boundary.  A failure restores the previous Store
state.

Ordinary Automation is dynamically disabled inside that transaction.  It must
not react to temporary states between data cleanup and Schema commit.  Code
that needs to react after a successful upgrade should attach to
`supertag-ontology-migrated-hook` instead.

Applied records live in the canonical `:ontology-migrations` collection, so
they follow the existing persistence, backup, restore, and sync lifecycle.
They are audit metadata, not another ontology definition.

## Relation to `supertag-embed`

This release does not build another Transclusion system.  Supertag already owns
that capability through `supertag-ops-embed.el`, `supertag-services-embed.el`,
and `supertag-ui-embed.el`; those modules remain the single embed boundary.
