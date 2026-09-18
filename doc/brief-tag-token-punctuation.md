# Brief: ASCII punctuation should not be part of an inline tag name

## The problem

`supertag-inline-tag-terminator-chars` (`supertag-tag.el:168`) lists only
full-width CJK punctuation:

```elisp
"＃　，。；：！？、（）【】《》“”‘’"
```

The inline tag regexp (`:190`) therefore ends a tag name only at whitespace,
`#`, `＃` or one of those CJK characters. In English prose that means the
trailing punctuation joins the name:

- `#seo,` is the token `seo,`
- `#old;` is `old;`
- `#old]]` is `old]]`

Consequences the user has already hit: the orphan report lists `#seo` and
`#seo,` as two unrelated tokens, so cleaning one silently leaves the other; and
a tag written at the end of a sentence never resolves to the tag the user meant.

The CJK half is correct and was added deliberately — this is the ASCII half of
the same idea, which was never done.

## Risk check already done

In the user's real vault, **0 of 48 registered tags contain ASCII punctuation
in their name**. So tightening the tokenizer invalidates no existing registered
tag. Re-verify this yourself before relying on it.

## Constraints that must hold

These are load-bearing and are documented in the repo's own history:

- **`/` is the nested-tag path separator and must stay a name character.**
  `#emacs/package` is one token. See the repo's completion docs (`b7f4197`).
- **`_` and `-` are ordinary name characters.** `#c_maker`, `#tag-name` must
  keep working.
- Full-width punctuation must keep terminating names exactly as today, and the
  full-width `＃` must keep working as a marker (the user types with a Chinese
  IME).
- Unicode and emoji names must keep working — the current class is a negated
  set for exactly that reason; do not switch to an allowlist that breaks CJK
  tag names.

## Design decision you must make and justify

Two shapes are possible:

1. **Terminate** on ASCII punctuation, like the CJK list does — `#foo.bar`
   becomes the token `foo`.
2. **Strip trailing** punctuation only — `#foo.bar` stays `foo.bar`, while
   `#foo.` / `#seo,` / `#old]]` yield `foo` / `seo` / `old`.

Option 2 is gentler and probably closer to intent (a tag ending a sentence),
but it is a different rule from the CJK one, which would make the two halves
inconsistent. Pick one, say why, and make sure the CJK and ASCII behaviour are
explainable in one sentence in the docstring.

Whichever you choose, `]` and `)` must not survive in a token, since
`[[id:x][#foo]]` currently yields `foo]]`.

## Reprojection / stored data

Nodes may carry stored occurrences such as `seo,` in their projected
`:tag-occurrences` / unresolved tags. After the change these become stale.

Say clearly in your report whether a re-sync is required for the user's vault
to pick up the new tokenisation, and if so the exact command they should run.
Do not run anything against `/Users/chenyibin/Documents/notes`.

If any registered tag entity *does* turn out to have punctuation in its name
(re-verify), stop and report `BLOCKED` rather than silently renaming user data.

## Tests

- `#seo,` `#seo.` `#seo;` `#seo!` `#seo?` `#seo)` `#seo]` and `[[id:x][#seo]]`
  all yield the token `seo`;
- `#emacs/package` stays one token; `#c_maker` and `#tag-name` unchanged;
- CJK: `#标签，后面` still yields `标签`; full-width `＃标签` still matched;
- an emoji / CJK-only tag name still matched;
- highlighting and extraction agree — a token that highlights is the token that
  gets extracted (this equality is what the orphan/delete work relies on).

Each new test must fail on the current code; show that.

## Verification

```sh
cd /Users/chenyibin/Documents/emacs/package/supertag
bash test/run-tests.sh          # 35 suites / 1206 tests, currently 0 unexpected, exit 0
bash test/static-gates.sh       # exit 0
```

Nothing may regress. Expect fallout in suites that assert tag text: extractor,
tag-path, tag-change, mention-extra, promote. Where an existing test encodes
the *old* tokenisation, changing it is legitimate — but call out every such
test in your report with the reason, so the coordinator can check none of them
was masking a real behaviour.

If the local libgccjit trampoline problem appears, use an `EMACS_BIN` wrapper
setting `native-comp-enable-subr-trampolines nil native-comp-jit-compilation nil`.

## Scope

`supertag-tag.el` and tests; `supertag-services-sync.el` only if the extractor
genuinely needs it (say so). Do not touch the orphan report UI or
rename/merge — those are separate follow-ups already queued. Branch
`supertagV2`.

## Reporting

Write `doc/report-tag-token-punctuation.md` — decision taken and why, what
changed, commit hash, verification with raw output, every existing test you
had to modify and why, and whether the user must re-sync — then end with
`DONE: doc/report-tag-token-punctuation.md`. Stop with `BLOCKED: <reason>` if a
ruling is needed.
