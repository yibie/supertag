# Brief: concept refresh and font-lock cost (fixes B and C)

Two independent performance defects in `supertag-concept.el`. Both are yours;
please land them as **two separate commits**, B first.

Everything here stays inside `supertag-concept.el`. Another agent is editing
`supertag-service-org.el` and `supertag-services-sync.el` in parallel — do not
touch those, and do not change `supertag-mention.el`.

---

## Fix B — `supertag-concept--refresh-all-buffers` recomputes the same thing N times

`supertag-promote` ends by calling `supertag-concept--refresh-all-buffers`
(`supertag-concept.el:269`). For **every** buffer with `supertag-concept-link-mode`
on, it calls `supertag-concept-refresh` →
`supertag-concept--refresh-font-lock-keywords` → `supertag-concept-entries`,
which scans the whole node store.

Measured on the real vault (1822 nodes): **0.13s per buffer**. Five Org buffers
open means 0.65s of the user-visible stutter. The entries list is identical for
every buffer, so it is computed N times for one result.

Inside that scan, `supertag-concept-node-p` (`supertag-concept.el:122`) calls
`(supertag-template-target-files)` once **per node**, and that function
recomputes `file-truename` for each configured template target every time.

Do:

1. Compute the entries **once** in `supertag-concept--refresh-all-buffers` and
   pass them down. Give `supertag-concept-refresh` and
   `supertag-concept--refresh-font-lock-keywords` an optional ENTRIES argument;
   when it is absent they behave exactly as today, so every existing caller
   (including `supertag-concept-link-mode` itself) keeps working.
2. Hoist the target-file list out of the per-node predicate. Give
   `supertag-concept-node-p` an optional second argument carrying an
   already-computed target list, and have `supertag-concept--term-index`
   compute it once before the scan. `supertag-concept-node-p` is called with
   one argument from `supertag-view-node.el:736` and from several tests, so the
   one-argument call must keep working unchanged. **Do not** edit
   `supertag-template-target-files` itself; it lives in another agent's file.

---

## Fix C — every font-lock match re-hashes the entire buffer

`supertag-concept--ignored-org-context-p` (`supertag-concept.el:194`) runs for
**each** candidate match and, on each one, does:

```elisp
(supertag-mention-service--protected-ranges
 (buffer-substring-no-properties (point-min) (point-max)))
```

That copies the whole buffer into a fresh string and takes a SHA-256 of it —
per match. `supertag-mention-service--protected-ranges` does cache, but keyed
on the content hash, so the copy and the hash are paid every single time; only
the range computation is saved.

This is currently dormant because the user's `concepts.org` is empty, so the
entries list is empty and no keywords are installed. The moment they start
using concepts it becomes a continuous typing stutter, not just a Promote one.

Do: memoize the protected ranges per buffer inside `supertag-concept.el`, keyed
on `(buffer-chars-modified-tick)`, so one fontification pass computes them at
most once and an unmodified buffer reuses them. Keep calling
`supertag-mention-service--protected-ranges` for the actual computation — it
stays the owner of that logic; you are only avoiding the repeated whole-buffer
copy and hash.

Correctness to preserve:
- The existing `(save-restriction (widen) ...)` is essential — font-lock can
  narrow to a single line and hide an enclosing Embed. The memo must be built
  from the widened buffer, and the `start`/`end` offsets passed to
  `supertag-mention-service--inside-range-p` must stay relative to the same
  origin they use today (`(- pos (point-min))` under that widening).
- Invalidate on any buffer modification. A stale range set would mis-highlight
  text inside a src block or drawer.
- Make the memo buffer-local, and make sure it cannot leak between buffers.

---

## Verification (run all of it, paste the output)

```sh
bash test/run-tests.sh mention-extra promote contract
```

Byte-compile clean (no new warnings), then delete the `.elc` you produce:

```sh
emacs -Q --batch -L . -f batch-byte-compile supertag-concept.el
```

Add regression tests:
- For B: assert the store scan happens **once** for N enabled buffers — e.g.
  `cl-letf` a counter onto the entry-computing function, enable the mode in
  three temp buffers, call `supertag-concept--refresh-all-buffers`, assert the
  count is 1 and that all three buffers ended up with the same keywords.
- For C: assert that fontifying a buffer with many matches computes the
  protected ranges at most once per modification tick, and that editing the
  buffer invalidates the memo. Also keep a correctness case: a concept term
  inside a src block or property drawer must still **not** be highlighted.

Report the before/after timing you measure for B on a vault-sized store.

Do not drive the user's running Emacs (no emacsclient, no frames); batch
verification only.
