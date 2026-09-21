# Goal: File-Level Tag Support (File Nodes in DB)

## Objective

Add file-level tag support to org-supertag by making org files themselves into database nodes ("file nodes") that exist alongside heading nodes, linked by parent-child relationships via `:parent-id`. File nodes carry file-level tags sourced from `#+FILETAGS:` and are compatible with both org-roam (`:PROPERTIES:` `:ID:`) and denote (`#+IDENTIFIER:`) ID sources.

**Desired end state**: 
- Every org file in `org-supertag-sync-directories` has a corresponding file node (level=0) in the database
- Each heading node has a `:parent-id` pointing to its file node
- File node tags are read from `#+FILETAGS:` on sync and auto-create tag entities
- File nodes participate in orphan detection (file deleted → file node + children orphaned)
- 4 new query APIs exist: `supertag-find-nodes-by-parent`, `supertag-find-file-node`, `supertag-get-file-node-for-node`, `supertag-find-all-file-nodes`
- Existing heading node sync continues to work unchanged
- No UI changes in this phase

**Verified by**: 
- `supertag-sync-force-rescan` completes without errors
- Query APIs return correct results for test org files with `#+FILETAGS:` and `#+TITLE:`
- Orphan detection: delete a test file → its file node and children marked orphaned
- Existing heading nodes retain all existing properties and tags
- Denote mode: `#+IDENTIFIER:` becomes file node ID
- org-roam mode: `:PROPERTIES:` `:ID:` becomes file node ID

## Constraints

- Do NOT break existing heading node sync, tag processing, or relation creation
- Do NOT change heading node `:file` field behavior (keep as file path string)
- Do NOT change heading node `:type` (stays `:node`)
- Do NOT implement tag inheritance to children (out of scope)
- Do NOT write back to `#+FILETAGS:` (unidirectional import only)
- Do NOT add any UI components (graph, table, sidebar, node view)
- Do NOT import denote front matter beyond `#+IDENTIFIER:`, `#+TITLE:`, `#+FILETAGS:`
- Do NOT auto-generate denote-format IDs (if missing in denote mode, fallback to `org-id-new` + warn)
- Do NOT add a schema version number (migration triggered by user running `supertag-sync-force-rescan`)

## Boundaries

**Allowed scope**:
- `supertag-services-sync.el` — main changes: file node upsert in `process-single-file`, file header parsing, `:parent-id` assignment, orphan detection extension
- `supertag-services-query.el` — add 4 new query functions
- `org-supertag.el` — add `defcustom org-supertag-file-id-source`
- Any other `.el` files that need minor compatibility adjustments for `:parent-id`

**Forbidden scope**:
- All UI files (`supertag-ui-*.el`, `supertag-view-*.el`, `supertag-graph-ui.el`, `supertag-board-ui.el`)
- `ext/` directory (React frontends)
- `doc/` directory
- `test/` or test infrastructure (tests are a separate task)

## Decisions (from grilling session)

| # | Decision |
|---|----------|
| 1 | File becomes a DB node (not just tag inheritance) |
| 2 | Parent-child relationship (file node → heading nodes) |
| 3 | File node ID: user chooses org-roam (`:ID:`) or denote (`#+IDENTIFIER:`) via defcustom |
| 4 | `:level 0` for file nodes (compatible with org-roam) |
| 5 | File node creation in `process-single-file`, before heading processing |
| 6 | `:parent-id` dual field (keep `:file` unchanged) |
| 7 | `#+FILETAGS:` auto-creates tag entities (both modes) |
| 8 | Orphan detection: file deleted → file node + children orphaned |
| 9 | `:type` stays `:node`, distinguished by `:level 0` |
| 10 | `#+FILETAGS:` is read-only (user edits the file directly) |
| 11 | `:title` = `#+TITLE:` only, no fallback |
| 12 | No tag inheritance from file to children |
| 13 | UI deferred to later phase (storage layer only) |
| 14 | No file-level exclude mechanism (sync directories = scope) |
| 15 | Migration via `supertag-sync-force-rescan` (no schema version) |
| 16 | `#+IDENTIFIER:` discarded after used as ID (no separate field) |
| 17 | File header parsing: direct regex, NOT extractor pipeline |
| 18 | Change detection: hash-based (same as heading nodes) |
| 19 | 4 new query functions |
| 20 | Sync order: file node first, then children |
| 21 | No schema version; user runs force-rescan |
| 22 | `defcustom org-supertag-file-id-source` (org-roam or denote, no auto) |
| 23 | `#+FILETAGS:` read in both modes |
| 24 | Missing denote ID → `org-id-new` + warn (don't generate denote format) |
| 25 | No other denote front matter imported |
| 26 | Orphan logic extended for file nodes, structure unchanged |
| 27 | File node changes use existing event types |
| 28 | No separate migration version file |

## Implementation Plan

### Step 1: Add `defcustom` and file header parser
- Add `org-supertag-file-id-source` to `org-supertag.el`
- Write `supertag-sync--parse-file-header` to extract `#+TITLE:`, `#+FILETAGS:`, and ID (from `:ID:` or `#+IDENTIFIER:`)
- Return a plist with `:id`, `:title`, `:file-tags`

### Step 2: File node upsert in `process-single-file`
- Before heading processing, call file header parser
- Upsert file node (create or update) with level=0, type=:node
- Hash-based change detection (same as heading nodes)
- Process `#+FILETAGS:` → auto-create tag entities → create tag relations

### Step 3: Add `:parent-id` to heading nodes
- After file node upsert, pass `file-node-id` to heading node creation
- Set `:parent-id` on each heading node plist before upsert
- Keep `:file` field unchanged

### Step 4: New query functions
- `supertag-find-nodes-by-parent` (parent-id → child nodes)
- `supertag-find-file-node` (file-path → file-node-id)
- `supertag-get-file-node-for-node` (node-id → file-node)
- `supertag-find-all-file-nodes` (→ all level-0 nodes)

### Step 5: Orphan detection extension
- Extend `supertag-sync--verify-file-nodes` to also check/clean file nodes
- When file is missing from disk: orphan file node + all children

### Step 6: Manual verification
- Create test org files with various `#+FILETAGS:` / `#+TITLE:` / ID configurations
- Run `supertag-sync-force-rescan`
- Verify via query functions and `supertag-debug-dump-node`
- Test both org-roam and denote modes
- Test orphan detection

## Iteration Policy

After each step:
1. Run all existing tests (`make test` or equivalent)
2. If tests fail, fix before proceeding
3. After steps 1-4 complete, do a full rescan and verify with query functions
4. After step 5, test orphan detection manually

## Stop Condition

If blocked by:
- Unclear how existing code handles a decision we made → re-read relevant sources, trace the logic
- Test failure with unclear root cause → minimize reproduction, diagnose
- File header parsing fails on edge cases → document the edge case, implement workaround

Stop with: what was attempted, what blocks progress, what input is needed to unblock.
