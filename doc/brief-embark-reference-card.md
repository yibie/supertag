# Brief: `:origin` is `:node-link` where a reference card is expected

One failing test, pre-existing and unclaimed. It is red at `888c36b` and at
every commit since, so nothing in the recent performance/test work caused it.

```
supertag-embark-node-view-reference-card-remove-tag-writes-remotely
test/embark-test.el:454
```

## The failure

```elisp
(supertag-embark-test--goto-property 'supertag-reference-node-id "other")
(should (eq :reference-card (plist-get (supertag-embark--target-at-point) :origin)))
;; actual :origin is :node-link
```

The test opens Node View on a node, moves point to a position carrying the
`supertag-reference-node-id` text property — i.e. onto a reference card — and
expects `supertag-embark--target-at-point` to report that the target came from
a reference card. It reports `:node-link` instead.

The sibling test immediately above it
(`...reference-add-tag-writes-remotely`, same file) passes, so the surrounding
fixture and the remote-write machinery are sound. The divergence is specifically
in how the target's origin is classified at that point.

## What I need decided first

**Which side is wrong?** Do not assume the test is stale and edit it to expect
`:node-link`; do not assume the product is wrong and force `:reference-card`.
Establish it, then fix that side.

Useful questions:

- What does `:origin` mean to the callers that consume it? Find every reader of
  `:origin` and see which ones behave differently for `:reference-card` versus
  `:node-link`. If a real action dispatches on it, a misclassification is a
  live bug, not a cosmetic one.
- In `supertag-embark--target-at-point`, what is the order of the checks? A
  reference card inside Node View may well carry *both* an id link and the
  `supertag-reference-node-id` property, in which case an earlier `:node-link`
  branch would shadow the `:reference-card` branch. If so, the ordering is the
  defect.
- Does the remove-tag path actually still write remotely and correctly? The
  test's later assertions never run because it dies at line 454 — so we do not
  currently know whether the rest of that test would pass. Find out; there may
  be a second defect hiding behind the first, which has happened repeatedly in
  this repo's recent history.
- Use git history (`git log -S':reference-card'`, `git log -S'supertag-reference-node-id'`,
  and the history of `supertag-embark.el` and `test/embark-test.el`) to find
  whether the product or the expectation moved, and when.

## Then fix it

Once you know which side is wrong, fix that side and nothing else. If the
product is wrong, the test should need no change at all. If the test is stale,
say precisely which commit made it so, and keep every other assertion in it
intact.

If you find the remove-tag behaviour itself is broken once the test gets past
line 454, treat that as the more important finding and report it clearly.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
EMACS_BIN=<wrapper> bash test/run-tests.sh embark
```

Expect 35 tests, 0 unexpected (currently 1 unexpected, 1 skipped). Then confirm
you have not disturbed the neighbours:

```sh
EMACS_BIN=<wrapper> bash test/run-tests.sh contract promote
```

Both must stay at 0 unexpected.

The wrapper is required on this machine — plain `emacs -Q --batch` aborts on
any `fset` onto a subr because libgccjit cannot link
(`ld: library 'emutls_w' not found`):

```sh
exec emacs --eval '(setq native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil)' "$@"
```

## Scope

`supertag-embark.el` and/or `test/embark-test.el`, whichever the diagnosis
points at. Another agent is working on `supertag-view-framework.el`,
`supertag-tag.el`, `supertag-link.el`, `supertag-view-tag-cards.el` and
`test/static-gates.sh` in parallel — leave those alone; if your fix genuinely
needs one of them, stop and report instead. Branch is `supertagV2`. Batch
verification only; never drive the user's running Emacs.
