# Report: ASCII punctuation in inline tag names

Commit: `81b8b95 fix(tag): ASCII punctuation no longer joins an inline tag name`
(files: `supertag-tag.el`, `test/inline-tag-punctuation-test.el` new,
`test/orphan-bulk-cleanup-test.el`, `test/tag-path-hierarchy-test.el`,
`test/renovation-suites.el`).  Branch `supertagV2`.  Nothing was run against
`/Users/chenyibin/Documents/notes`.

## Decision: strip trailing ASCII punctuation, keep inner punctuation

Two shapes were possible; I chose the second:

1. terminate on ASCII punctuation like the CJK list does (`#foo.bar` -> `foo`);
2. **strip trailing ASCII punctuation only** (`#foo.`/`#seo,`/`#old]]` -> `foo`/
   `seo`/`old`, while `#v1.2`, `#c++`, `#a.b,c` stay whole).

Why option 2: option 1 silently *truncates* identifiers, and a truncated token
can turn out to be a *different registered* tag - `#v1.2` would become `v1`
and attach to the user's `v1` with no signal.  That is the one failure this
product cannot show the user; option 2 leaves such text as its own (visible)
token or orphan.  It also matches the complaint exactly: the bug is
sentence-final punctuation, not inner punctuation.

The two halves still share one rule, stated in one sentence in the docstring
of `supertag-inline-tag-regexp`:

> A name runs until whitespace, `#`, `＃`, a full-width punctuation character
> or an ASCII delimiter, and drops any trailing ASCII sentence punctuation, so
> `#seo,` yields `seo` while `#v1.2`, `#c++` and `#emacs/package` stay whole.

The CJK side is unchanged (`full-width punctuation always terminates`, because
CJK prose has no spaces); the ASCII side drops only what trails it, because
ASCII prose separates words with whitespace.

## What changed (`supertag-tag.el` only; no extractor change needed)

- New fragments, all explicit ASCII sets (no `[:punct:]`, no allowlist, so CJK
  and emoji are untouched):
  - `supertag-inline-tag-ascii-delimiter-regexp` = `]([){}<>"` - brackets and
    quotes are Org structure, so a name ends at one wherever it appears.  The
    leading `]` is load-bearing: Emacs ends a character class at an unescaped
    `]`, so it must be the class's first member.
  - `supertag-inline-tag-ascii-trailing-regexp` = `,.;:!?'\`` - allowed inside
    a name, never at its end.
  - `supertag-inline-tag-name-inner-regexp` (quantified `*`) and
    `supertag-inline-tag-name-last-regexp` (exactly one character).
- `supertag-inline-tag-regexp` now builds its name from those two classes, so
  **every** consumer of the shared regexp picks up the new name at once:
  extraction (`supertag--extract-inline-tags`), the range engine
  (`supertag-transform-inline-tag-matches-in-region`), highlighting
  (`supertag-view-helper--font-lock-matcher`), removal/rename
  (`supertag-view-helper-remove-tag-text`,
  `supertag-view-helper-rename-tag-text-in-node`) and the delete/orphan paths.
  `supertag-services-sync.el` needed no change; its extractor already goes
  through the range engine.
- `supertag-completion--valid-tag-char-p` now mirrors the inner class (the
  second place that encoded the character rule, at `supertag-tag.el:2980`), so
  typing and tokenising agree; the completion prefix stops at `)`/`]`/`"`.
- The loose candidate regexp used by the delete/orphan scan
  (`supertag-tag--text-candidate-regexp`) is deliberately left looser than the
  tokenizer: it still *finds* `#seo,`/`#old]]` and lets
  `supertag-view-helper--inline-tag-range-at` decide, which keeps the deleted
  set exactly the highlighted set.
- Three sentences that described the old model were corrected (no behaviour
  change, and no orphan-UI change beyond wording): the orphan report's note
  line, `supertag-orphan-tags--stem`'s docstring, and
  `supertag-tag--text-look-alike-p`'s docstring (that helper is now only
  relevant for *rejected* candidates, whose raw text the loose scan still
  carries punctuation for).

## Re-verification of the registered tags (read-only, outside the vault)

The default data directory has no store (`~/.emacs.d/supertag/` holds only an
empty `backups/` and `sync-state.el`); the store readable outside the vault is
`~/.emacs.d/org-supertag/supertag-db.el` (mtime 2026-07-15, header form plus
2337 `(:collection ...)` records).  Read with plain `read`, no Org parsing, no
writes:

```
TAGS=105 NODES=891
TAG-NAMES-WITH-PUNCTUATION=nil
STALE-OCCURRENCES=0 UNIQUE=0
```

So **no registered tag name or alias contains ASCII punctuation**, and no
stored `:tag-occurrences` entry does either - the tightening invalidates no
existing tag there (the coordinator's count of 48 is lower than the 105 in this
store, but both agree that the set is empty).  To re-check a *live* store the
user can evaluate this read-only snippet in their own Emacs:

```elisp
(seq-filter
 (lambda (id)
   (let ((tag (supertag-tag-get id)))
     (or (string-match-p "[][(){}\"<>,.;:!?'`]" (or (plist-get tag :name) ""))
         (seq-some (lambda (alias)
                     (string-match-p "[][(){}\"<>,.;:!?'`]" (or alias "")))
                   (plist-get tag :aliases)))))
 (supertag-view-api-list-tag-ids))
```

(Exercised on a fixture: it returns the punctuation-named tag and nothing
else.)

## Does the user need to re-sync?

**Only if their Org text contains punctuation-tailed tags, and then one
command.**

- Projections are *derived* state: `:tag-occurrences`, node membership and the
  unresolved/failed token lists were computed with the old tokenizer.  The
  incremental sync compares mtime/size/content hash, so a file that has not
  changed since the update is never re-parsed and keeps its old-shape tokens
  (`seo,` instead of `seo`) until something re-reads it.
- The exact command: `M-x supertag-sync-full-rescan` (interactive; "Rebuild
  Document Projections from one complete Org snapshot"; never restores
  Semantic Facts and never modifies Org files).  Run it once after updating.
- Not needed for the orphan report or `delete-tag-everywhere`: those enumerate
  occurrences from live Org text, so they already see the new tokens.

## Verification

```sh
EMACS_BIN=<wrapper> bash test/run-tests.sh      # exit 0
$ python3 -c "...summarise the 'Ran N tests' lines..."
suites=35 tests=1212 skipped=5 unexpected=0

bash test/static-gates.sh                        # exit 0
Static O gates: PASS
```

`tag-change` with the new tests: `Ran 38 tests, 38 results as expected, 0
unexpected`.

**Pre-fix evidence** (`git stash push -- supertag-tag.el`, then the suites):

```
tag-change: Ran 38 tests, 29 results as expected, 9 unexpected
   FAILED 4 of the 6 new tests
     supertag-inline-tag-punctuation-trailing-forms
     supertag-inline-tag-punctuation-name-characters
     supertag-inline-tag-punctuation-resolves-the-intended-tag
     supertag-inline-tag-punctuation-completion-mirrors-the-rule
   FAILED the 5 updated orphan tests (they assert the new tokenisation)
tag-path:  Ran 101 tests, 100 results as expected, 1 unexpected
   FAILED supertag-path-tp-lexical   (asserted the regexp's old construction)
```

The two new tests that pass on both sides are deliberate non-regression pins,
not bug encodings: `...-cjk-and-emoji` (full-width/CJK/emoji behaviour must not
change) and `...-highlighting-matches-extraction` (highlighting and extraction
agree under *either* tokenizer; the bug was never an agreement failure).

## Existing tests modified (itemised, with reasons)

1. `test/tag-path-hierarchy-test.el` - `supertag-path-tp-lexical`, one
   assertion inside the `tp-program` string:
   `(should (equal (concat supertag-inline-tag-boundary-regexp "[#＃]\\([^…"]+
   \\)") supertag-inline-tag-regexp))` -> the same assertion built from the two
   new class fragments.  Reason: it pinned the *construction* of the regexp,
   which this task changes by design; the test's intent (the regexp is
   assembled from the shared fragments) is preserved.  Its lexical and object
   expectations (`#x^2` staying `x^2`, `#'quoted` rejected,
   `word#embedded`/URL fragments unmatched, `[[id:target][#link]]` yielding no
   token) all still hold unchanged - no expectation was weakened.
2. `test/orphan-bulk-cleanup-test.el` - five tests, because each asserted
   `seo,` as a token of its own, which is the behaviour this task fixes:
   - `supertag-orphan-tags-bulk-remove-all-in-one-confirmation`: the report now
     shows one `#seo` row with 4 occurrences instead of `#seo` + `#seo,` rows,
     so the stem/adjacency assertions were replaced by "one row, 4
     occurrences, no `#seo,` row" and the marked-token count 3 -> 2.
   - `supertag-orphan-tags-unmarked-token-survives`: marks `("seo")`, not
     `("seo" "seo,")`; the kept/removed text assertions are unchanged.
   - `supertag-orphan-tags-mark-all-and-unmark-all`: 2 tokens, not 3.
   - `supertag-orphan-tags-cleanup-list-needs-no-minibuffer`: cleans `"seo"`
     (which now also owns `#seo,`) and asserts both spellings go.
   - `supertag-orphan-tags-refresh-keeps-deliberate-unmarks`: marks `"seo"`
     (4 records), not `"seo,"`.
   No assertion was dropped to make a failure disappear; each either changed a
   count or was replaced by the new (stronger) expectation.
3. `test/renovation-suites.el`: registers the new test file in `tag-change`.

## Out-of-scope observations

1. **The brief's `[[id:x][#seo]]` example is not a tag occurrence - before or
   after this change.**  The character before `#` is `[`, which the boundary
   rule (`supertag-inline-tag-boundary-char-regexp`: start, whitespace or CJK)
   has never accepted; the repo's own `tp-objects` test pins that
   `[[id:target][#link]]` yields nothing.  The `]`-in-token problem this brief
   describes appears with a space-preceded or free-standing tag (`see #seo]]`
   or `#seo]]`), which now yields `seo`, and `)`/`]` can no longer survive a
   token.  Making a `#` directly after `[` a boundary would be a *boundary*
   change (URL fragments, `word#part`) and is not included.
2. **Inner punctuation is still allowed** (`#a.b,c` is one token).  If the
   coordinator wants option 1 after all, it is a one-line change: move
   `supertag-inline-tag-ascii-trailing-regexp` into the delimiter fragment so
   it terminates instead of trailing.
3. **`supertag-completion--valid-tag-char-p` duplicates the character rule**
   (now mirroring the inner class).  A future change to the name characters
   must touch both places; a shared class constant would remove the
   duplication.
4. **Stem grouping in the orphan report is now inert** for the case it was
   written for (`#seo`/`#seo,`); it still labels tokens whose name legitimately
   ends in a name character that reads as punctuation (`tag-`).  The orphan UI
   proper is a queued follow-up and was not touched beyond the stale note text.
5. **The store I could audit is not necessarily the live one** (mtime
   2026-07-15, 105 tags).  The check above is offered to the user so they can
   audit their own store without anyone touching the vault.
