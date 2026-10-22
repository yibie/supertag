# Property Hints and Completion

> 中文: [properties_cn.md](properties_cn.md)

A property is plain text in an Org drawer. Nothing in the drawer says whether a key takes
one of a few values or anything at all, or which values those are. Supertag answers both
where you type, in the drawer itself.

## Closed keys and open keys

A **closed key** has its allowed values declared the Org way: a `KEY_ALL` property without
`:ETC`. Org reads the declaration from three places, and the nearer one wins:

```org
:PROPERTIES:
:STATUS_ALL: todo doing done
:END:
```

```org
#+PROPERTY: STATUS_ALL todo doing done
```

```elisp
(setq org-global-properties '(("STATUS_ALL" . "todo doing done")))
```

Every other key is an **open key**. A declaration that ends in `:ETC` is open too: its
values are suggestions.

Closed is a convention. Typing in a drawer is never blocked; the hint points out a value
that is not among the options, and that is all. Org's own `org-set-property` (`C-c C-x p`)
does insist on a declared option.

Supertag keeps no declaration of its own. Whether a key is closed is decided by Org's
`KEY_ALL`, and nothing is stored about it in the database.

## The hint

With point anywhere on a property line, the echo area shows the key, its type and its
options:

| Line | Hint |
|---|---|
| `:STATUS: done` | `STATUS · closed · todo doing done` |
| `:STATUS: active` | `STATUS · closed · todo doing done · active is not an option` |
| `:COUNTRY: Japan` | `COUNTRY · open · Japan \| France` |
| `:WEBSITE: https://…` | `WEBSITE · open` |

- A closed key lists its options in the order they were declared.
- An open key lists the values used more than once in the vault, most used first, at most
  `supertag-property-hint-max-values`. A key whose values never repeat shows its type only.
- Keys that programs maintain (`ID`, `CREATED`, `SUPERTAG_*` and the rest of
  `supertag-property-system-key-regexp`) get no hint. `SUPERTAG_ALIASES`, the node aliases
  you write yourself, is not one of them.

The hint is an ElDoc source, so Supertag enables ElDoc in Org buffers. Away from a
property line the echo area is left alone.

## Completion

Candidates are shown by Corfu.

**Values.** After `:KEY: `, a closed key offers its declared options in declared order. An
open key offers every value in use, most used first, each with the number of nodes using
it.

**Keys.** On a new drawer line, `:` and the first letters complete from the keys in use.
Keys used by nodes that share a tag with this heading come first. Each candidate shows its
type and how many nodes use it, as in `STATUS  closed · 15`. Keys already in the drawer and
keys that programs maintain are left out. `SUPERTAG_ALIASES` is offered even before any node
uses it, after the keys in use. Accepting a key inserts `: ` and goes on to its values.

Org's own `C-c C-x p` (`org-set-property`) offers `SUPERTAG_ALIASES` too, in every file,
while Supertag runs; without that Org would offer it only in a file that already has it.
This holds even with `supertag-property-hints` set to nil.

**Empty values.** An empty value offers its candidates at once after an edit: typing the
space after `:KEY:`, deleting a value, or accepting a key. Moving point over an empty value
shows nothing. This applies to closed keys and to open keys with repeated values; a
free-text key such as a URL never pops up. If you edit with commands of your own, add them
to `supertag-property-popup-commands`.

## Links in property values

Org reads a property value as plain text, so a link written there is not a link to Org.
Supertag reads it anyway:

```org
:PROPERTIES:
:ID:        a1b2
:SEE:       [[id:c3d4][Another note]]
:REFERENCE: [[chai:20261006T164701][A book]] [[chai:20260927T052022][Another book]]
:END:
```

- A link to a node (`id:`, `denote:`) is a reference of the node, the same as one written
  in the body. It appears in the target's backlinks, with nothing to configure.
- A link of any other type is recorded when its type is listed in
  `supertag-property-link-types`:

  ```elisp
  (setq supertag-property-link-types '("chai" "https"))
  ```

  One value can hold several links; each is recorded with the key it was written under.

To find the nodes that link to something, use the query condition `links-to`, or
`supertag-property-links-to` from Lisp:

```elisp
(links-to "chai:20261006T164701")
```

A link that goes on to a place inside the same target, such as
`chai:20261006T164701::42`, is found by the shorter form as well.

Notes already in the vault are read again when they are next saved. After changing
`supertag-property-link-types`, run `M-x supertag-reindex-org` to pick up the rest.

## The creation time

A heading's `CREATED` property is its creation time. Supertag writes the property when a
heading first gets a tag (`supertag-created-time-format`), and the Stream, the `created`
query conditions and the cards order nodes by it.

- The value may be plain (`2026-10-12 18:11`) or an Org timestamp (`[2026-10-12 Mon 18:11]`).
  A date without a time of day counts as midnight.
- Editing the property moves the node; the change is picked up when the file is saved.
- A heading without the property keeps the time Supertag first scanned it.
- Notes scanned by an older version take their date the next time their file is saved.
  `M-x supertag-reindex-org` applies it to every file at once.

## When a key means different things under different tags

A drawer holds one `STATUS`, and `STATUS_ALL` applies to a file or a subtree, not to a tag.
If a book and a task both need a status with different options, give the keys different
names, for example `BOOK_STATUS` and `STATUS`, and declare each. Supertag does not derive
anything from the prefix; it is only a name.

## Turning it off

Set `supertag-property-hints` to nil before Supertag starts. In one buffer,
`M-x supertag-property-mode` toggles it.

## For configuration authors

`supertag-property-usage` returns which keys the vault uses, how often, and with which
values; `supertag-property-names` returns every property name; and
`supertag-property-key-info` returns the type and values of one key at point. Use these
rather than reading the node collection.
