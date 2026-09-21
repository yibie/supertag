# Development test entry

<!-- P1 development -->
Run from the repository root with installed Emacs/package dependencies:

```sh
bash test/run-tests.sh                 # contract + compat + named transitions
bash test/run-tests.sh contract compat
bash test/run-tests.sh transition      # retained public safeguards
bash test/run-tests.sh promote         # one named transition
bash test/run-tests.sh archive         # historical field/Board assertions
bash test/run-tests.sh --guidance       # lightweight links/entrypoints
```

[Static manifest](renovation-suites.el) owns file/ERT selections. The old
`bash test/run-refactor-batch1.sh` pathname delegates to the same executor;
old broad names such as `legacy-all` and `regression` are not default aliases.
Other historical tests remain in place and can be loaded explicitly in an
isolated Emacs process; this manifest does not claim all old contracts migrated.

Contract covers independent Q source loading, real document projections,
public NodeView header/metadata/mode-line and native save/queue refresh, plus
real runner failures in disposable copies. Compat preserves conflicting old
field values and historical collections without using them as property defaults.
Named transitions retain identity, saved projection, property Automation,
Move/Promote/Stream/Find/Add Link/Discovery; query-links await P4, tag completion
P3, and legacy query DSL remains subject to G2. Full public loading still uses
old aggregates; independent Q loading is a separate, narrower claim.

Every run prints its unique `supertag-tests.*` directory. Data and per-suite logs
stay there, including successful suites before a failure. Missing files, empty
sets/selectors, unmatched selectors and zero ERT fail. `tee` preserves the Emacs
failure status. Counterexample copies and their
exit-code logs remain in the printed `supertag-entrypoints.*` directory.
The runner uses `-Q`, initializes installed dependencies, source-loads Query and
Node, then requires Tag/Sync and prepares the Node cache listener. It never
installs packages or runs npm builds (the Board/Graph frontends are archived
under `archive/ext/`).
Independent byte compilation must use a temporary source copy and fresh process;
source results do not establish fresh-package or Embark installation coverage.

Historical results and assertion replacement are in the
[refactor manifest](refactor-batch1-manifest.md).
<!-- /P1 development -->

## Historical virtual-column guide (explicit archive use only)

The following earlier guide is retained as historical material. It is not the
default test entry or current product authority.

# Virtual Column Test Guide

## Quick Start

### Step 1: Load the module (fresh Emacs session)
```elisp
(add-to-list 'load-path "/Users/chenyibin/Documents/emacs/package/supertag")
(load-file "/Users/chenyibin/Documents/emacs/package/supertag/supertag-virtual-column.el")
```

### Step 2: Run quick test
```elisp
(load-file "/Users/chenyibin/Documents/emacs/package/supertag/test/quick-test.el")
```

Expected output:
```
=== Virtual Column Quick Test ===
Test 1: Creating virtual column...
✓ Create: PASS
Test 2: Getting definition...
✓ Get: PASS
Test 3: Cache operations...
✓ Cache: PASS
Test 4: List columns...
✓ List: PASS (1 column)
Test 5: Delete column...
✓ Delete: PASS
=== Quick Test Complete ===
```

### Step 3: Run interactive demo
```elisp
(load-file "/Users/chenyibin/Documents/emacs/package/supertag/test/demo-virtual-column.el")
M-x supertag-demo-virtual-column
```

### Step 4: Run full ERT tests
```elisp
(load-file "/Users/chenyibin/Documents/emacs/package/supertag/test/virtual-column-test.el")
M-x ert-run-tests-interactively
```

## Troubleshooting

### Error: `(void-variable total-effort)`
**Cause**: Old version of module with quoted plist in docstring  
**Fix**: Re-load the updated `supertag-virtual-column.el` file

### Error: `Module not loaded`
**Cause**: `load-path` not set correctly  
**Fix**: Ensure path includes the supertag directory

### Error: `Feature not found`
**Cause**: Module failed to load due to dependencies  
**Fix**: Load dependencies first:
```elisp
(require 'supertag-core-store)
(require 'supertag-core-schema)
(require 'supertag-virtual-column)
```
