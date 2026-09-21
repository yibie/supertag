#+TITLE: Sync Architecture Tech Refer (Org-supertag)
#+AUTHOR: Internal
#+DATE: 2025-12-16

* Purpose

This document captures the technical exploration for improving the
Org-supertag sync subsystem. It focuses on:

- Clarifying the current architecture (data store, notifications, sync pipeline)
- Comparing with Vulpea-style async architectures
- Deciding how to evolve org-supertag's sync without over-complicating

It should be read before updating =plan_sync_improve_20251216= and
before doing any major refactor.

* Current Architecture (Relevant Parts)

** Store & Notifications

- =supertag-core-store.el=
  - =supertag--store=: central hash-table store.
  - =supertag-store-put-entity= / =supertag-update= / =supertag-delete=:
    the main write paths into the store.
  - Every write emits:
    - low-level change via =supertag--notify-change path old new=
    - high-level event via =supertag-emit-event :store-changed path old new=

- =supertag-core-notify.el=
  - =supertag-subscribe=: subscribe to keyword or path events.
  - =supertag-emit-event=: generic event bus.
  - =supertag-core-notify-handle-change=: bridge from store changes to
    path-specific callbacks.
  - Batch notifications:
    - =supertag--suppress-notifications= / =supertag--pending-changes=
      live in =supertag-core-state.el=.
    - =supertag--notify-batch-changes= flushes pending changes in order.

- =supertag-core-state.el=
  - =supertag-core-state-with-suppressed-notifications= macro used to
    run a block where notifications are suppressed and then flushed at
    the end (batch).

- =supertag-core-transform.el=
  - Historically introduced =supertag-transform= and
    =supertag-batch-transform= as a functional gate for state updates.
  - In current code, real-world usage is:
    - =supertag-with-transaction= macro (widely used)
    - =supertag-transform-extract-inline-tags= helper for tag parsing
  - The =supertag-transform= function itself is essentially unused by
    higher-level modules.

** Transactions & Batch Ops

- =supertag-with-transaction= (in =supertag-core-transform.el=):
  - Wraps BODY with:
    - transaction flags (=supertag--transaction-active=,
      =supertag--transaction-log=).
    - =supertag-core-state-with-suppressed-notifications=:
      notifications are collected, then flushed via
      =supertag--notify-batch-changes= on success.
  - Used in many places:
    - =supertag-services-sync.el=
    - =supertag-ops-batch.el=
    - =supertag-ops-relation.el=
    - Various UI commands and automation.

- =supertag-ops-batch.el=
  - Provides batch create/update/delete helpers which wrap
    multiple =supertag-node-*=/=supertag-tag-*=/=supertag-relation-*=
    calls inside a single =supertag-with-transaction=.

** Sync Pipeline

- =supertag-services-sync.el= (current commit 77ca208…)
  - Maintains a sync state table (=supertag-sync--state=) with last
    sync times per file.
  - =supertag-scan-sync-directories= scans configured sync directories
    for files, filtered by =supertag-sync--in-sync-scope-p=.
  - =supertag-sync-import-file= parses a single file (via
    =supertag--parse-org-nodes=) and calls =supertag-node-create= for
    each node. These operations can be wrapped in
    =supertag-with-transaction= in higher-level calls.
  - Auto-sync:
    - timers + =supertag-sync--auto-start-tick= schedule
      =supertag-sync-start-auto-sync= which sets up a repeating
      timer to run =supertag-sync--check-and-sync=.
  - There is no explicit "file work queue" structure yet; instead,
    scanning + per-file processing is done synchronously when the
    timer fires.

* Current Usage of =supertag-transform=

- Code search shows:
  - Defined in =supertag-core-transform.el=
  - Used only by =supertag-batch-transform= and
    =supertag-transform-pattern= (both internal helpers).
  - No external module calls =supertag-transform= directly.
- Documentation still describes it as the "single gateway" for state
  changes (see =doc/COMPARE-NEW-OLD-ARCHITECTURE*.md=), which no
  longer matches reality:
  - Real-world writes go through:
    - =supertag-store-put-entity=
    - =supertag-update=
    - =supertag-node-create= / =supertag-node-update= / etc.
  - Coordination and atomicity are handled by:
    - =supertag-with-transaction=
    - =supertag-core-state-with-suppressed-notifications=
    - =supertag--notify-batch-changes=

Conclusion: =supertag-transform= is a legacy abstraction that can be
removed to simplify the mental model, while keeping transactions and
batch notifications.

* Vulpea-inspired Concepts (What We Can Borrow)

From the Vulpea =architecture.org= and =sync-architecture.org=
documents, the most relevant ideas are:

- Clear separation between:
  - Data store + notification (already present in org-supertag)
  - File-level sync queue (to be designed / improved)
- Async-first file processing:
  - File changes are enqueued and processed in batches.
  - UI never blocks on DB updates.
- Smart batching and debouncing:
  - Use a queue with delay (debounce) and a max batch size per run.
  - Each batch executes in a single transaction.
- Explicit sync modes:
  - Manual sync, autosync, force/rehash modes with a decision table.

Org-supertag already has:

- Transactions and batch notifications for store-level changes.
- A sync loop that can wrap per-file import in =supertag-with-transaction=.

Missing pieces for a "Vulpea-style" experience:

- A dedicated file-level work queue + debounced processing.
- Stronger separation between:
  - "What files need to be processed" (queue),
  - "How each file is processed" (parse + extractor + ops),
  - "When/if we run autosync" (mode / user control).

* Options for Evolving Transform & Sync

** Option A: Remove =supertag-transform=, keep transactions

- Remove:
  - =supertag-transform=
  - =supertag-batch-transform=
  - =supertag-transform-pattern= and matching helpers
  - Update docs to no longer present =supertag-transform= as the sole
    gateway.
- Keep and emphasize:
  - =supertag-with-transaction= as the main high-level API for
    atomic operations.
  - Explicit ops APIs (node/tag/relation/field ops) as the "only"
    way to mutate state from outside core.
- Impact:
  - Simplifies the conceptual model.
  - No functional change for sync or UI, since they already rely on
    =supertag-with-transaction= and ops functions.

** Option B: Reintroduce a thin "transform" layer via ops (later)

- If we still want a "single gateway" narrative, we can define it as:
  - "All state changes go through =supertag-ops-commit= / ops
    functions inside =supertag-with-transaction=."
- This would align documentation with reality without forcing all
  call sites to use a single function like =supertag-transform=.

** Option C: File-level Queue for Sync (future work)

- Introduce a small file queue abstraction in =supertag-services-sync.el=:
  - API ideas:
    - =supertag-sync-enqueue-file=
    - =supertag-sync-process-queue=
  - Backed by a simple list or hash-table of pending files.
- Use =supertag-with-transaction= per batch:
  - For each batch of files:
    - Start transaction.
    - For each file in the batch: parse + extractor + ops.
    - Commit → triggers batch notifications + persistence.

This aligns with the current core architecture and reuses existing
batch notification logic.

* Decision for This Phase

For the current "sync improvement" phase, we adopt:

- Remove the legacy =supertag-transform= and related helpers that are
  unused by other modules.
- Keep =supertag-with-transaction= as the official transaction API.
- Treat ops functions (e.g. =supertag-node-create=, batch ops) as the
  canonical way to mutate state.
- Introduce a *documented* design for a dedicated file-level queue in
  =supertag-services-sync.el=, inspired by Vulpea's async queue
  design. Actual implementation will be planned and executed in
  follow-up tasks.

These decisions should be reflected in:

- Updated docs (COMPARE-NEW-OLD-ARCHITECTURE*)
- The sync-improvement plan and subsequent tasks.

* File-Level Queue & Batch Processing Design (Draft)

This section sketches how a file-level queue could work in
Org-supertag, building on top of the existing store/transaction and
notification system.

** Goals

- Avoid blocking Emacs UI when syncing large sets of files.
- Make "what is being synced" and "how much is processed at once"
  explicit and configurable.
- Reuse `supertag-with-transaction` to keep per-batch updates atomic
  and compatible with existing notifications and persistence.

** Core Ideas

- Introduce a *file-level work queue* in =supertag-services-sync.el=
  that manages pending files to be processed.
- Separate three responsibilities:
  - *Discovery*: finding which files need sync (directory scan,
    modified files, user commands).
  - *Queuing*: adding files to a queue with deduplication.
  - *Processing*: taking small batches from the queue and importing
    them inside `supertag-with-transaction`.

** Proposed Internal API (Conceptual)

These function names are illustrative; final naming can be adjusted
when implementing.

- Queue state:
  - =supertag-sync--queue=: a hash-table or list tracking pending
    file paths (absolute).
  - =supertag-sync-max-batch-size=: defcustom for max files per
    batch (e.g. 20–100), tuned for responsiveness.

- Basic operations:
  - =(supertag-sync-enqueue-file FILE)=
    - Normalize =FILE= to an absolute path.
    - Check `supertag-sync--in-sync-scope-p`.
    - Add to =supertag-sync--queue= if not already present.
  - =(supertag-sync-enqueue-files FILES)=
    - Convenience helper to batch-enqueue a list of files.
  - =(supertag-sync--dequeue-batch)=
    - Take up to =supertag-sync-max-batch-size= files from the queue.
    - Return the list and remove them from the internal queue.
  - =(supertag-sync-queue-empty-p)=
    - Predicate to check whether the queue is empty.

- Processing:
  - =(supertag-sync-process-queue)=
    - If the queue is empty, return immediately.
    - Otherwise:
      - Dequeue a batch of files.
      - Wrap processing in `supertag-with-transaction`:

#+begin_src elisp
  (defun supertag-sync-process-queue ()
    "Process up to `supertag-sync-max-batch-size` files from the sync queue."
    (interactive)
    (let ((batch (supertag-sync--dequeue-batch)))
      (when batch
        (supertag-with-transaction
          (dolist (file batch)
            (condition-case err
                (progn
                  (supertag-sync-import-file file)
                  (supertag-sync-update-state file))
              (error
               ;; TODO: record error for diagnostics / retry
               (message \"Supertag sync error for %s: %s\" file err))))))))
#+end_src

    - Note: this is a *conceptual* snippet; error handling, logging,
      and retry policy would be refined during implementation.

** Integration with Existing Flow

- *Manual sync commands*:
  - Functions like =supertag-sync-full-rescan= would:
    - Discover relevant files (via =supertag-scan-sync-directories= or
      a more targeted scan).
    - Enqueue them with =supertag-sync-enqueue-files=.
    - Call =supertag-sync-process-queue= (possibly in a loop or via
      a timer to avoid long single runs).

- *Auto-sync timer*:
  - The timer callback (currently =supertag-sync--check-and-sync=)
    would be adjusted to:
    - Discover modified files and enqueue them.
    - Call =supertag-sync-process-queue= once per timer tick, letting
      subsequent ticks handle remaining work.
  - This avoids long synchronous loops in a single timer invocation.

- *State & observability*:
  - Provide helper commands to inspect queue size:
    - e.g. =supertag-sync-queue-length=, or a debug command that
      prints pending files.
  - Optionally, add basic logging whenever a batch is processed:
    - number of files, total queue length, time spent.

** Safety & Defaults

- The queue mechanism itself does not force auto-sync to be enabled;
  it only defines *how* work is processed when requested.
- Safer defaults planned in this phase (as per spec/plan):
  - Make auto-start of sync opt-in or clearly documented as such.
  - Provide a “manual-only sync” mode where users explicitly trigger
    full rescan or directory sync, which internally uses the queue.
- The combination of:
  - file-level queue
  - limited batch size
  - and `supertag-with-transaction`
  should reduce the risk of Emacs appearing “frozen” during large
  sync operations.

* Analysis: `supertag-sync--check-and-sync` Structure & Refactor Space

This section breaks down the current auto-sync worker
`supertag-sync--check-and-sync` to understand where the file-level
queue can be introduced safely.

** Current Responsibilities (Step-by-step)

From `supertag-services-sync.el`, the function performs:

1. **Pre-checks**
   - If `org-supertag-sync-directories` is nil:
     - Log a warning and `cl-return-from supertag-sync--check-and-sync`.
   - Check for “empty DB but non-empty sync-state”:
     - If `:nodes` collection is empty but `supertag-sync--state` has
       tracked files, log warnings and suggest
       `supertag-sync-full-rescan`.

2. **Transactional body (`supertag-with-transaction`)**
   - Local bindings:
     - `files-to-remove`: files to untrack from sync-state.
     - `state-changed`: whether sync-state was modified.
     - `modified-files`: from `supertag-get-modified-files` (based on
       last-sync timestamps).
     - `counters`: plist for node/ref change statistics.
     - `processed-files`: hash-table of files processed in this run.

   - **Step 1: Sync-state cleanup**
     - Iterate over entries in `supertag-sync--state`:
       - If file no longer exists, or is no longer in sync scope
         (`supertag-sync--in-sync-scope-p`), push into
         `files-to-remove`.
     - For each file in `files-to-remove`:
       - Remove from state table;
       - If file truly does not exist, call
         `supertag-sync--verify-file-nodes` to mark orphaned nodes and
         increment `:nodes-deleted`.

   - **Step 2: Discover new files**
     - Call `supertag-scan-sync-directories` (non-ALL mode) to get
       files under sync directories that are not yet in state;  
     - Merge `new-files` into `modified-files` using `cl-union`.

   - **Step 3: Process modified files**
     - Sort `modified-files` by file mtime ascending;  
     - For each file in `sorted-files`:
       - Call `supertag-sync--process-single-file file counters`;
       - Mark `state-changed` t;
       - Record file into `processed-files` hash-table.

   - **Step 4: Orphan detection for unmodified files**
     - Compute `all-files-in-scope` via `supertag-scan-sync-directories t`;  
     - For each file in `all-files-in-scope` not in `processed-files`:
       - Call `supertag-sync--verify-file-nodes` to mark orphaned
         nodes / ensure nodes match disk;  
       - Ensure file is present in state table (via
         `supertag-sync-update-state`).

   - **Step 5: Persist sync-state & deep validation**
     - If `state-changed`, call `supertag-sync-save-state`;  
     - Call `supertag-sync-validate-nodes` for a full pass over nodes
       to detect zombies and inconsistencies.

   - **Step 6: Reporting**
     - Compute `refs-created` / `refs-deleted` / `total-changes` /
       `idle-run` (no changes and no refs);  
     - Unless `idle-run` and `supertag-sync-quiet-when-idle`, print
       summary message;  
     - For `idle-run`, call `supertag--diagnose-empty-sync` to give
       hints why no changes were detected.

3. **Outside transaction**
   - Call `supertag-sync-garbage-collect-orphaned-nodes` to physically
     delete orphaned nodes.

** What Can Be Queue-ified vs. What Should Stay Synchronous

- **Should remain synchronous in `supertag-sync--check-and-sync`**
  - Pre-checks:
    - Validating configuration (`org-supertag-sync-directories`), DB
      vs sync-state consistency.  
    - These are quick checks and safety rails, independent of file
      count.
  - State cleanup (Step 1):
    - Removing out-of-scope or non-existent files from sync-state;  
    - Prevents stale entries from lingering；  
    - Typically bounded by the size of tracked files, but still cheap
      compared to parsing org files.
  - Deep validation (Step 5) & GC after transaction:
    - For correctness, these need a “global view”；  
    - They might be candidates for further optimization (e.g. less
      frequent runs), but this should be a separate, carefully scoped
      phase.

- **适合通过队列 + 批处理处理的部分**
  - Step 2 + Step 3：处理 `modified-files` 和新发现的 files：
    - 解析 org 文件 + 调用 extractor + ops → CPU/IO 重型操作；  
    - 适合放入队列，由 `supertag-sync-process-queue` 一批一批处理；  
    - `processed-files` 逻辑可以输入到队列消费结果中（例如：由
      queue consumer 负责更新 `processed-files` 或状态表）。
  - Step 4：对未修改文件做 orphan 检查：
    - 在大仓库中非常昂贵（需要跑完整轮 `supertag-sync--verify-file-nodes`）；  
    - 可以拆成：
      - “定期/手动触发的全库健康检查”（例如命令或低频 timer）；  
      - 或“每次只对一小批未检查文件做 orphan 检查”，依然利用队列或类似机制。

** 可能的重构方案（简略对比）

- 方案 A：仅将 modified/new files 的处理迁移到队列
  - 保留 Step 4 的全范围 orphan 检查和 Step 5 的 validate；  
  - 在 `supertag-sync--check-and-sync` 中：
    - 发现 modified/new files → `supertag-sync-enqueue-files`；  
    - 调用一次 `supertag-sync-process-queue` 处理一批；  
    - 使用队列中剩余工作量作为后续 tick 的 backlog。  
  - 优点：
    - 改动相对集中，主要作用于 Step 3；  
    - 行为更容易与当前版本对比验证。  
  - 风险：
    - Step 4 & Step 5 的成本仍可能较高，尤其在大仓库中。

- 方案 B：同时将 orphan 检查部分拆分为“低频/分批”任务
  - 将 Step 4 的逻辑部分迁出主 loop：  
    - 例如只在某些条件下（如 interval 的倍数、用户手动触发）跑全量 orphan 检查；  
    - 或给 orphan 检查单独的队列/命令。  
  - 优点：
    - 在大仓库中能显著降低普通 auto-sync tick 的工作量；  
  - 风险：
    - 更容易引入逻辑“时序滞后”（orphan 不会在第一次 tick 就全部被发现），需要在文档中解释预期行为。

- 方案 C：保留现有 `supertag-sync--check-and-sync` 作为“兼容模式”
  - 引入 `supertag-sync-auto-use-queue` 等开关；  
  - 当开关关闭时，继续执行现有的同步逻辑；  
  - 当开关开启时，按方案 A/B 运行队列版本。  
  - 优点：
    - 易于回退和 A/B 比较；  
  - 风险：
    - 需要维护两套逻辑路径，测试与维护成本更高。

本阶段的结论（用于后续 task011/task012）：

- 短期内建议采用“方案 A + 兼容开关”的方式：
  - 优先把 modified/new files 的处理迁移到队列，借此验证在真实仓库中的收益；  
  - 保留当前 orphan/validate 的处理方式，作为下一阶段优化对象；  
  - 通过配置开关允许用户在遇到问题时暂时回退到旧行为。

* Orphan / Validate Strategy: Toward Deferred Maintenance

This section explores how to make orphan detection and deep validation
less intrusive for day-to-day auto-sync, by treating them as
low-frequency maintenance tasks instead of work that runs on every
tick.

** Current Behavior (Summary)

- In `supertag-sync--check-and-sync` (inside the transaction):
  - Step 4: For *all* in-scope files:
    - For unprocessed files, run `supertag-sync--verify-file-nodes`
      to detect orphaned nodes and ensure DB matches disk;  
    - Ensure every in-scope file has an entry in sync-state.
  - Step 5: Run `supertag-sync-validate-nodes` as a full pass to catch
    remaining zombie nodes / inconsistencies.
- Outside the transaction:
  - `supertag-sync-garbage-collect-orphaned-nodes` deletes orphaned
    nodes.

On large repos, Step 4 + Step 5 can become very expensive if executed
on every auto-sync tick.

** Option 1: Dedicated Low-Frequency Maintenance Timer

- Introduce a separate timer (e.g., once per day / once per N hours)
  whose sole job is to:
  - Run `supertag-sync-validate-nodes` and
    `supertag-sync-garbage-collect-orphaned-nodes` over the whole DB;  
  - Optionally also invoke `supertag-sync--verify-file-nodes` for all
    tracked files (or a subset).
- Auto-sync tick (`supertag-sync--check-and-sync`) then focuses on:
  - State cleanup for obviously out-of-scope files;  
  - Processing modified/new files via the queue;  
  - Light-weight consistency checks.
- Pros:
  - Clear separation between “incremental sync” and “full health
    check”；  
  - Easy to document and reason about (“run this maintenance job once
    a day or week”).
- Cons:
  - Orphan/zombie nodes may persist longer between maintenance runs.

** Option 2: N-th Tick Maintenance

- Maintain a counter for auto-sync ticks:
  - e.g., `supertag-sync--maintenance-counter`;  
  - Increment on each successful tick.
- Only when `(= 0 (mod counter N))`:
  - Run the heavy parts: full `supertag-sync-validate-nodes` and/or
    full-scope `supertag-sync--verify-file-nodes`;  
  - Reset or continue counting.
- Pros:
  - Does not require a separate timer;  
  - Keeps maintenance tied to actual sync activity.
- Cons:
  - Behavior less obvious to users (“why does every 10th sync take
    longer?”) unless clearly documented.

** Option 3: Threshold-Based Maintenance

- Trigger maintenance when the amount of change in a tick exceeds a
  threshold:
  - e.g., if `:nodes-created + :nodes-deleted` in `counters` exceeds a
    certain number, or queue length crosses a threshold;  
  - This indicates “a lot has changed”, making a deeper check
    worthwhile.
- Pros:
  - Adaptive: heavy maintenance runs only when there is significant
    churn.  
  - Good for users with sporadic but large edits/migrations.
- Cons:
  - More complex to reason about and test;  
  - Still needs a cap to avoid repeated heavy maintenance on every
    large tick.

** Option 4: Manual-Only Deep Maintenance (Status-Quo + Docs)

- Keep `supertag-sync-cleanup-database` (and/or a new
  `supertag-sync-maintenance-now` command) as the *primary* way to run
  deep orphan/validate passes;  
- Auto-sync tick:
  - Does minimal orphan verification (only for clearly invalid or
    out-of-scope files);  
  - Does *not* run full `supertag-sync-validate-nodes` on every tick.
- Pros:
  - Simplest implementation;  
  - Puts control fully in the user’s hands.
- Cons:
  - Requires discipline / good documentation to ensure users actually
    run maintenance when needed.

** Preferred Direction for This Phase

Given the current phase scope (sync safety & responsiveness), a
reasonable direction is:

- Short term:
  - Keep full `supertag-sync-validate-nodes` in `supertag-sync--check-and-sync` for compatibility;  
  - Document `supertag-sync-cleanup-database` as the recommended
    manual maintenance command.
- Next phase candidate:
  - Introduce *either* a dedicated low-frequency maintenance timer
    (Option 1) *or* an N-th-tick strategy (Option 2), gated by a
    defcustom (e.g., `supertag-sync-maintenance-mode`);  
  - Allow advanced users to opt into deferred maintenance while
    keeping current behavior as a “strict” mode.

This analysis is meant to prepare for a future phase focused on
maintenance strategy; the current phase will not change orphan /
validate semantics beyond what is needed for queue-based sync.

* Read-Many, Write-Once Pattern in Org-supertag

This section relates the “parse once, extract many, commit in a
transaction” idea from Vulpea to the current org-supertag design and
highlights where we already follow it and where we can tighten it.

** Current Status

- Per-file parsing
  - `supertag--parse-org-nodes`:
    - Uses `org-element-parse-buffer` once per file;  
    - Maps headlines via `supertag--map-headlines` into a list of node
      plists;  
    - Ignores embed blocks and minimizes side effects in the temp
      buffer.
  - Extractor-style behavior is currently embedded in the conversion
    logic (`supertag--convert-element-to-node-plist`) rather than a
    pluggable extractor registry, but the “parse once → produce all
    node plists for this file” principle is already respected.

- Per-node / per-file writes
  - `supertag-sync-import-file`:
    - For a given file, calls `supertag--parse-org-nodes` once;  
    - Iterates nodes and calls `supertag-node-create` for each. These
      writes are typically executed inside a higher-level transaction
      (`supertag-with-transaction`).

- Per-batch transactional writes
  - Full rescan (`supertag-sync-full-rescan`):
    - Before introducing the queue: one `supertag-with-transaction`
      wrapped around all files.  
    - Now: each batch processed by `supertag-sync-process-queue` is
      wrapped in a single `supertag-with-transaction`, giving “multi
      file / multi node → one transaction per batch”.
  - Auto-sync (`supertag-sync--check-and-sync`):
    - The whole tick still runs inside a single
      `supertag-with-transaction`, regardless of whether queue-based
      processing is enabled;  
    - File-level work is limited by
      `supertag-sync-max-batch-size` when queue mode is on.

** Where We Already Match “Read-many, Write-once”**

- Single file:
  - Parse once (`supertag--parse-org-nodes`), then multiple nodes /
    ops against that parse result.  
  - Store writes are staged via ops and committed within a
    transaction at the caller level (sync / migration / commands).

- Batch / tick:
  - Full rescan and auto-sync both use `supertag-with-transaction` to
    group a set of per-file/per-node changes into one commit boundary.

** Potential Improvements (Future Work)**

These ideas stay aligned with “read-many, write-once” but are out of
scope for this phase:

- Extractor as first-class plugin system  
  Move more of the per-headline extraction logic out of
  `supertag--convert-element-to-node-plist` into a registry-driven
  extractor system (similar to Vulpea’s
  `vulpea-db-register-extractor`). Parsing cost stays “once per file”,
  but different concerns (tags, properties, links, custom schemas)
  can evolve independently.

- Coarser-grained transaction tuning for very large repos  
  For extremely large note sets, it might be useful to:
  - Keep one transaction per auto-sync tick, but make batch size /
    tick frequency more tunable;  
  - Consider introducing “macro batches” for long-running operations
    (full rescan of tens of thousands of files) with explicit
    checkpoints, rather than a single massive transaction.

- AST reuse across subsystems  
  Today `supertag--parse-org-nodes` is invoked per sync operation that
  needs file content. Future phases could explore caching parse
  results per mtime/hash so that sync, views, and analysis can share
  ASTs where appropriate, while respecting Emacs memory/GC limits.

These improvements are *not* part of the current sync-improvement
phase, but they frame how org-supertag can continue to evolve toward
an efficient “parse-once, extract-many, commit-in-transactions” model
without destabilizing the current architecture.
