## Supertag – Global Field Database Migration

This guide describes how to upgrade an existing Supertag database to the new global field model introduced in 5.2.0, where fields are first-class entities and no longer nested under individual tags.

> **Important:** Before running any migration, make a fresh backup of your Supertag data directory.

The global field model is now the only production read/write path. The obsolete
`supertag-use-global-fields` option is ignored; it cannot reopen legacy storage.

### 1. Audit Before Migrating

Run the dedicated read-only audit first:

```elisp
(require 'supertag)
(require 'supertag-migration)
(supertag-migration-audit-global-fields)
```

The command returns a deterministic report and opens `*supertag-migration*` when
called interactively. It compares:

- every legacy Tag field definition with its global field ID and definition;
- ordered Tag/field associations;
- every legacy node/field value with its global value, including inherited fields;
- global-only values that will be preserved;
- orphan values/associations and the full-database backup preflight.

Only `:safe-to-apply t` is a clean result. Different or malformed definitions,
ambiguous display names, different values, multiple legacy values for one
node/field, malformed associations, Tags absent from their Nodes, and orphan
owners all fail closed. The report never changes the Store or database file.

### 2. Run the Migration in Dry-Run Mode

The migration command delegates its dry-run to the same audit:

```elisp
;; Ensure dry-run is enabled (default is t)
(setq supertag-migration-dry-run t)

;; Dry-run: scan and log, but do not write
(supertag-migration-run-global-fields)
```

Check the report's definition/association mappings, per-node/per-field parity,
coverage policy, conflicts, orphans, and backup SHA-256 values. Re-running it on
unchanged data produces the same report regardless of hash-table insertion
order.

### 3. Execute the Real Migration (Writes Enabled)

Once the report has `:safe-to-apply t`, save your work and apply the migration:

```elisp
(require 'supertag-migration)

;; Turn off dry-run, or pass a prefix arg / FORCE-WRITE
(setq supertag-migration-dry-run nil)

;; Perform the actual migration (writes to the store)
(supertag-migration-run-global-fields t)
```

This will:
- Deduplicate tag-scoped field definitions into global field definitions in `:field-definitions`.
- Create ordered tag↔field associations in `:tag-field-associations`.
- Rewrite node-level values from nested `:fields` into flat `:field-values` (node-id → field-id → value).
- Log a summary and any conflicts to `*supertag-migration*`.

The write entry point reruns the audit immediately before changing data and
raises an error if any conflict or orphan exists. It never chooses an overwrite
winner. Before the first write, it also serializes the live Store to
`backups/supertag-db-preglobal-fields-*.el`; this protects unsaved in-memory
state rather than copying a possibly stale database file.

### 4. Verify and Continue Using Global Fields

After the migration:

- Remove `supertag-use-global-fields` from your config; it is obsolete.
- Open key views to verify data:
  - Table / Node / Kanban views show fields once per node (shared fields dedupe correctly).
  - Editing a field value triggers your existing automation rules (e.g., rules written with `field-equals` / `field-changed`).
  - Queries and capture flows see the expected field values.

If you see issues, consult:
- `doc/global-field-migration-rfc.md` – design decisions and conflict policy.
- `doc/global-field-migration-plan.md` / `doc/global-field-migration-tasks.md` – phased rollout plan and checklist.

The global field collections are authoritative immediately after cutover.
Legacy `:fields` is read only by migration/compatibility infrastructure; normal
field, schema, view, query, capture, and automation operations neither read nor
grow it.
