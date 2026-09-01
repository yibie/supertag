# Evidence

## E-20260825-001 — Legacy v2 cutover decisions confirmed

### Observation

The repository contains 196 tracked files under the root `.phrase/` v2 tree,
has no v3 decision/current/evidence markers, and uses Git without `.jj/`. The
user reviewed the upgrade report and explicitly accepted all recommended
decisions on 2026-08-25.

### Interpretation

The root legacy tree may be archived without importing its completed phase
tasks into modern active state. The project-specific development rules must be
preserved before root `AGENTS.md` becomes installed doctrine. The Operational
Fact proposal is confirmed for planning but still requires implementation
evidence before promotion from K1.

### Recommended next action

Perform the approved recoverable cutover, verify file counts and doctrine
identity, then capture and arrange the C1–C5 architecture enforcement SPEC.

### Verification

- `.scratch/upgrade-review/REPORT.md` records source classification, conflicts, disposition, and user decision.
- `git ls-files .phrase | wc -l` returned 196 before cutover.
- `test -d .jj` was false; Git history was inspected through `git log`.
- pre-cutover `CONTEXT.md` SHA-256: `ee5b903c1abaad6723e53c660cf2b17903f324b3ce1c014c227cc3c39e99e5c6`.

### References

- `.scratch/upgrade-review/REPORT.md`
- `UPGRADE.md`
- `CONTEXT.md`
- `doc/OWNERSHIP-CONSTITUTION_cn.md`

## E-20260825-002 — Legacy v2 cutover verified

### Observation

The root `.phrase/` tree was moved with Git history to
`archive/legacy-v2/2026-08-25-phrase/`. Project development rules were
preserved as a Protocol, upstream root doctrine was installed byte-identically,
and project vocabulary remained unchanged.

### Interpretation

The repository now has one modern workflow entry and a recoverable legacy
history. Completed legacy tasks are no longer in the default authority path.

### Recommended next action

Capture and arrange the confirmed C1–C5 architecture enforcement work.

### Verification

- `git ls-files .phrase | wc -l` → `0`.
- `git ls-files archive/legacy-v2/2026-08-25-phrase | wc -l` → `196`.
- root `AGENTS.md` is byte-identical to upstream doctrine.
- `CONTEXT.md` SHA-256 remained `ee5b903c1abaad6723e53c660cf2b17903f324b3ce1c014c227cc3c39e99e5c6`.
- `.gitignore` exposes root doctrine, `docs/spec-agents/`, and `docs/protocols/`, while ignoring `.scratch/`.
- no application source, tests, dependencies, or durable data were changed by cutover.

### References

- `MIGRATION.md`
- `docs/protocols/supertag-development.md`
- `archive/legacy-v2/2026-08-25-phrase/`

## E-20260825-003 — Document command ownership violations reproduced

### Observation

Seven new public-command contract tests fail against the current implementation
for four precise reasons: create does not save before projection, delete removes
Projection before save, demote never saves, and projection failure is a generic
pre-save error with no retry data. The pre-change relevant baseline passed
53/53 tests.

### Interpretation

The ownership problem is observable behavior rather than a naming or layering
preference. The existing `supertag-service-org.el` save/project seam is the
correct authority to extend; the UI should remain a thin adapter.

### Recommended next action

Add the static boundary guard, then implement create and delete/demote against
these tests without changing persistence, Store shape, or unrelated UI hunks.

### Verification

- focused ERT: 7 tests loaded, 7 expected contract failures, each message matched the planned violation.
- relevant baseline: 53/53 passed before adding the red tests.
- `check-parens` passed for `test/document-command-ownership-test.el`.
- `git diff --check` passed.

### References

- `.specs/ownership-safe-mutations/issues/01-document-failure-contracts.md`
- `test/document-command-ownership-test.el`
- `supertag-ui-commands.el:198`
- `supertag-ui-commands.el:245`
- `supertag-ui-commands.el:281`

## E-20260825-004 — Architecture boundary guard enacted

### Observation

A source-level ERT guard now scans production UI, View, Automation, Ops, and
Query call sites for three forbidden dependency shapes. Current legacy
exceptions are exact path/call/count entries; a removed exception forces the
allowlist to shrink, and a new violation fails the test.

### Interpretation

The current architecture debt is now bounded rather than silently expandable.
This is enforcement of the existing Kernel/SPEC ownership boundaries, not a
new business authority or a production dependency.

### Recommended next action

Route node creation through the existing Org service seam, making the Document
save durable before any node Projection mutation.

### Verification

- `./test/run-tests.sh architecture` passed 3/3.
- A synthetic `supertag-store-put-entity` call in UI scope is rejected.
- Store reads and concrete Query Model calls are accepted.
- Full Elisp comparator names such as `supertag-query--value<` are captured.
- Same-context check: scope and authority match Slice 02; `check-parens`,
  `bash -n test/run-tests.sh`, and `git diff --check` passed.

### References

- `.specs/ownership-safe-mutations/issues/02-architecture-boundary-guard.md`
- `test/architecture-boundary-test.el`
- `test/run-tests.sh`

## E-20260825-005 — Node creation is Document-first

### Observation

Both public create branches now delegate identity persistence and Projection
reconciliation to one Org service command.  The service ensures the heading ID,
saves the file, then invokes the existing current-buffer Projector exactly once.

### Interpretation

Creation order is no longer a UI convention.  It is an enforceable Document
Command invariant owned by `supertag-service-org.el`, while node parsing and
Projection logic remain in their existing modules.

### Recommended next action

Apply the same service-owned ordering to delete and demote, including a
structured post-save projection failure.

### Verification

- Focused create ERT passed 3/3: existing heading, new heading, and save failure.
- Ownership/identity/sync-worker/architecture regressions passed 59/59.
- Temporary-copy byte compilation succeeded for both changed production files;
  output contains only pre-existing Emacs 31/docstring warnings.
- Same-context check confirmed scope, service authority, return value, prompts,
  and unrelated UI path-normalization hunks are preserved.
- `check-parens` and `git diff --check` passed.

### References

- `.specs/ownership-safe-mutations/issues/03-create-save-before-project.md`
- `supertag-service-org.el`
- `supertag-ui-commands.el`
- `test/document-command-ownership-test.el`

## E-20260825-006 — Delete and demote are Document-first and retryable

### Observation

Public delete and demote commands now delegate to Org service commands that
validate identity, apply a recoverable buffer edit, save the Org file, and only
then remove the node Projection.  Save failure rolls back the in-memory edit.
Post-save Projector failure signals `supertag-projection-error` with executable
service-level retry data.  Rebuild plus tag-field lifecycle runs in one Store
transaction.

### Interpretation

The old split-brain window caused by Store-first deletion is closed.  Document
durability and Projection atomicity are separate, explicit boundaries: Org is
never rolled back after a successful save, while a failed Store reconciliation
retains its prior Projection and can be retried idempotently.

### Recommended next action

Implement the isolated Canonical Change/CommitRecord/FIFO skeleton, without
migrating any production writer or subscriber.

### Verification

- Focused Document Command ERT passed 10/10.
- Focused Document Command + transaction ERT passed 30/30, including a late
  Projector failure after an actual Store write and full rollback.
- Ownership/identity/transaction/smart-key/architecture/command regressions
  passed 86/86 before the final late-failure strengthening.
- Both create and delete recovery functions were executed successfully by
  applying `:retry` to `:retry-args` from the structured error.
- Temporary-copy byte compilation succeeded; only pre-existing warnings remain.
- Same-context authority/scope review, `check-parens`, `bash -n`, and
  `git diff --check` passed; unrelated user UI hunks remain unchanged.

### References

- `.specs/ownership-safe-mutations/issues/04-delete-demote-save-before-project.md`
- `supertag-service-org.el`
- `supertag-ui-commands.el`
- `test/document-command-ownership-test.el`
- `test/test-smart-key.el`

## E-20260825-007 — Canonical Change skeleton verified

### Observation

`supertag-core-change.el` now provides one isolated, outer-transaction-owned
commit seam. It validates an authority/scope envelope, derives a private
first-touch CommitRecord, suppresses equal-write no-ops, and publishes a
bounded Canonical Change only after transaction state is cleared. A synchronous
FIFO prevents subscriber-derived commits from reentering current delivery;
subscriber errors are captured and reported independently.

The previously reported K1 map gap is real: this is a new authority module.
Repository search found no production load point, writer, or subscriber. The
existing `:sync-conflicts` collection independently verifies the narrow
Operational Fact lifecycle: merge creates deterministic unresolved records,
persistence preserves them, and explicit conflict resolution removes them.

### Interpretation

The event contract is executable without changing current production behavior.
Fact authority and mutation scope are now proven orthogonal, including the
narrow `:operational` authority. The skeleton deliberately rejects entry from
an ambient Store transaction because this slice adds no general after-commit
hook; accepting that case would publish before the real outer commit.

### Recommended next action

Run the full suite, update the final architecture document to match enacted K2,
and perform three fresh architecture review rounds before declaring the batch
ready for follow-on production migration work.

### Verification

- `./test/run-tests.sh change` passed 7/7.
- Change/transaction/ownership/architecture regressions passed 56/56.
- A delivery subscriber observed `supertag--transaction-active` as nil.
- Nested subscriber commit order and causation were asserted without reentry.
- No-op, late body error, and rollback emitted zero and restored Store state.
- Batch public data contains bounded collection counts and no path/old/new or
  private CommitRecord.
- `rg` found only definitions in `supertag-core-change.el`, no production
  require or call.
- Temporary-copy byte compilation, `check-parens`, `bash -n`, and
  `git diff --check` passed.

### References

- `.specs/ownership-safe-mutations/issues/05-canonical-change-skeleton.md`
- `supertag-core-change.el`
- `test/canonical-change-test.el`
- `supertag-merge.el:433`
- `supertag-conflicts.el:431`
- `supertag-core-persistence.el:1194`

## E-20260825-008 — C1–C5 full gate and six-round architecture review passed

### Observation

The complete repository test runner loaded 40 test files and ran 569 tests:
567 produced expected passing results, zero were unexpected, and two
interactive dashboard tests were skipped by their declared environment guard.
The four architecture documents now distinguish historical audit findings from
the enacted K2 state. Three implementation-time Linus reviews corrected the
Operational Fact model, made the outer-transaction precondition explicit, and
verified compatibility/no-production-adoption.

### Interpretation

The ownership-safe-mutations SPEC is complete. C1–C5 are independently tested,
the combined repository remains green, and no hidden bridge or production
consumer is required for current behavior. The next migration batch must start
with a new confirmed SPEC; M2b is not implicitly authorized by this completion.

### Recommended next action

Capture a separate M2b SPEC for CommitRecord-to-legacy bridge parity before
migrating any production writer or consumer.

### Verification

- `./test/run-tests.sh` → 569 total, 567 expected pass, 0 unexpected, 2 skipped.
- `test/test-results.txt` records the same final summary.
- Markdown relative-link validation found no missing target.
- Every architecture document has balanced fenced code blocks.
- Contradiction scan found no remaining current claim that authority is limited
  to Document/Semantic or that C1 is the next implementation step.
- `git diff --check` passed.
- K2 promotions include status, scope, applies-when, source Evidence, and
  verification metadata.

### References

- `doc/architecture/01-system-evolution.md`
- `doc/architecture/02-architecture-problems.md`
- `doc/architecture/03-refactoring-plan.md`
- `doc/architecture/04-final-architecture.md`
- `KERNEL.md`
- `.specs/ownership-safe-mutations/`

## E-20260825-009 — Canonical Change legacy bridge and first production writer verified

### Observation

`supertag-core-change.el` now suppresses immediate legacy
`:store-changed` delivery only inside a Kernel-managed outer transaction,
captures changed first-touch entries in its private CommitRecord, and enqueues
one complete delivery batch. The batch delivers one bounded Canonical Change
before its ordered legacy `(path old new)` events. Canonical- or
legacy-subscriber commits append complete later batches and do not interleave
with the current batch.

The same callback cannot subscribe to both Canonical Change and legacy
`:store-changed`; `supertag-core-notify.el` delegates that decision to the
Canonical Change authority. Bounded diagnostics expose subscriber, commit, and
path counts without retaining or publishing a CommitRecord.

`supertag-board-create` is the only production writer migrated to the seam.
Its board shape, return value, Store path, single write, and legacy event remain
compatible; it additionally emits `:board-created` as a
`:semantic/:fact/:single` Canonical Change. No production consumer migrated.

### Interpretation

The K2 non-production skeleton has become a production commit seam for one
tracer writer without widening the durable model or exposing Store paths to new
consumers. The temporary one-way bridge is a verified compatibility adapter,
not a second event authority: commit ordering, topic exclusivity, private
CommitRecord use, diagnostics, and FIFO delivery remain owned by
`supertag-core-change.el`.

This evidence supports K3. It does not support ambient-transaction entry,
`supertag-field-set` migration, consumer migration, persistent event replay,
or deletion of `:store-changed`.

### Recommended next action

Start any additional writer or consumer migration through a new `plan`.
Do not migrate a writer that can run inside an ambient Store transaction until
a separately confirmed and verified after-commit design exists.

### Verification

- Independent check context: implementation was executed by delegated agent
  Halley; the parent context reviewed the resulting code and reran every gate.
- Focused
  `emacs -Q --batch -L . -L test --eval '(package-initialize)' -l test/canonical-change-test.el -f ert-run-tests-batch-and-exit`
  passed 11/11 with zero unexpected results.
- `./test/run-tests.sh change tx automation-condition view-kanban view-runtime ownership architecture`
  ran 92 tests: 90 expected passes, zero unexpected, and two existing
  interactive dashboard skips.
- Full `./test/run-tests.sh` ran 573 tests: 571 expected passes, zero
  unexpected, and the same two declared skips.
- Temporary-copy byte compilation passed for
  `supertag-core-notify.el`, `supertag-core-change.el`, and
  `supertag-board-ops.el`; only the pre-existing wide-docstring warning
  remained.
- `check-parens`, `bash -n test/run-tests.sh`, and
  `git diff --check` passed.
- Production scans found exactly one `supertag-change-commit` caller and one
  `supertag-core-change` require, both in `supertag-board-ops.el`; production
  Canonical subscribers remain zero.

### References

- `.specs/canonical-change-legacy-bridge/SPEC.md`
- `.specs/canonical-change-legacy-bridge/issues/01-bridge-parity-board-create.md`
- `supertag-core-change.el`
- `supertag-core-notify.el`
- `supertag-board-ops.el`
- `test/canonical-change-test.el`

## E-20260828-011 — Ontology Policy v11 implemented and statically verified

### Observation

The user-uploaded `supertag-ontology-action-v10(1).zip` was used as the exact
baseline. Policy v11 adds a fail-closed, Store-owned authorization contract for
every deployed Action and corrects the Action boundaries required for Policy to
be meaningful.

The closed actor classes are `:interactive-user`, `:automation`, `:llm`, and
`:external`; decisions are `:allow`, `:deny`, `:confirm`, and
`:propose-only`. Action execution now requires an explicit actor, re-resolves
Policy and all business facts inside one Action-owned Canonical Change, and
defers Ops post-events until commit. Confirmation is an in-memory one-use
capability bound to the exact Action/Policy contracts and transition plan.

### Verification

- Elisp structure scanner: 120 files, zero structural errors.
- Local `require` / `provide` audit: 120 unique providers, 601 local
  dependency edges, zero missing providers, and no Policy-module cycle.
- Shell syntax: all 7 test runners passed `bash -n`; `git diff --check` passed.
- Focused ERT source: `tests/supertag-ontology-action-test.el` and
  `tests/supertag-ontology-policy-test.el`.
- Runtime ERT: not executed in the build environment because no Emacs binary is
  available; this limitation must remain visible in release artifacts.
- Patch and ZIP tree reproduction are recorded in the release artifacts, not
  asserted by this source-tree evidence entry.

### Boundary

Policy v11 does not enact roles, groups, actor-ID-specific rules, contextual
Policy callbacks, durable proposal queues, or LLM Tool generation. Function or
Action business preconditions remain separate from actor authorization.

## E-20260828-012 — Ontology LLM Tool Generation v12 implemented and statically verified

### Observation

The user-uploaded Ontology Policy v11 ZIP was used as the exact baseline. v12
adds explicit Function/Action exposure metadata and a transient,
provider-neutral catalog with versioned names, JSON Schema, typed JSON
invocation, Policy-filtered Action modes, and an out-of-band confirmation
boundary. The implementation scans no arbitrary `defun`, persists no tool
registry or proposal queue, and opens no provider connection.

### Interpretation

The stable Ontology Function, Action, and Policy contracts can now be projected
into LLM-callable capabilities without creating another execution authority.
Tool discovery is opt-in; denied Actions are absent; proposal-only tools cannot
execute; confirmation and execution use identical typed arguments; stale
Function, Action, or Policy catalogs fail closed. Provider adapters remain a
separate translation layer.

### Verification

- Focused ERT source: `tests/supertag-ontology-tool-test.el`.
- Runner: `tests/run-ontology-tool-tests.sh`.
- Structural and local require/provide scans report zero errors.
- All shell runners pass `bash -n`; `git diff --check` passes.
- Patch and ZIP tree reproduction are recorded in the v12 release artifacts.
- Runtime ERT execution remains unverified when the build environment has no
  Emacs executable; release artifacts must state that boundary.

### Boundary

v12 does not implement a provider SDK, HTTP service, MCP server, gptel adapter,
durable proposal queue, arbitrary Elisp discovery, or Policy roles/ABAC.
