# Supertag Query Guide

> 中文: [query_cn.md](query_cn.md)

A query is an S-expression. Both Org block flavours and the Lisp entry points share the same
parser and executor:

- **Babel code block** `supertag-query-block`: run manually, results land in an Org table;
- **Dynamic block** `supertag-query`: refreshed by Org's own refresh commands;
- `M-x supertag-query-build` assembles a query interactively, and
  `M-x supertag-query-describe-syntax` shows a quick reference.

Lisp entry points:

```elisp
(supertag-query-node-ids QUERY)   ; list of matching node IDs
(supertag-query-evaluate QUERY)   ; full result, including aggregate modifiers
(supertag-query-validate QUERY)   ; syntax check only
```

## Writing it in Org

### Babel block (run manually)

```org
#+BEGIN_SRC supertag-query-block :results raw
(and (tag "task") (todo "TODO"))
#+END_SRC
```

`M-x supertag-add-query-block` asks for the query expression and then inserts a
`#+BEGIN_SRC supertag-query-block :results raw` template. Press `C-c C-c` on the block to run
it; `supertag-query-block` is the only registered query-block language, and `:results raw` is
that language's default. The executor loads with Supertag itself, so there is no need to add
it to `org-babel-load-languages`.

### Dynamic block (refreshable)

```org
#+BEGIN: supertag-query :query "(and (tag \"project\") (after \"-30d\"))" :sort modified :order desc :limit 20 :columns ("status" "priority")
#+END:
```

A dynamic block has no `#+RESULTS:` container — the result is written into the block itself.
It does not update on its own: it recomputes only when you run a refresh command, i.e.
`C-c C-c` on the block, `org-dblock-update` or `org-update-all-dblocks`.

The difference: a Babel block is run by you, with results stored under `#+RESULTS:`; a
dynamic block is recomputed by Org's refresh commands, with the body as the result. Both
accept the same optional parameters:

| Parameter | Meaning |
|---|---|
| `:sort` | `title`, `created`, `modified` or a property name |
| `:order` | `asc` (default) or `desc` |
| `:limit` | a positive integer, applied after sorting |
| `:columns` | explicit property columns, overriding the derived ones |

A bad query or bad parameters do not break Org: the block renders a single `Error: ...` line.
Dates inside blocks also accept the `<%today%>`, `<%yesterday%>` and `<%tomorrow%>` variables.

## What the result looks like

An ordinary query renders as an Org table: the `Node` (title link) and `Tags` columns are
always there, plus one column per property mentioned in `(property ...)` clauses; `:columns`
replaces the derived property columns with yours. With no matches it writes
`No results found.` An aggregate query is a single `Aggregate` row; with `group-by` it is a
`Group`/`Aggregate` pair.

Links rendered by a block are generated content: the sync extractor does not treat links in
dynamic-block bodies or `#+RESULTS:` containers as document links. Queries read the
**properties already synchronized into the Store**; edits still sitting unsaved in a buffer
are not projected yet and cannot be found.

## Boolean composition

```elisp
(and CONDITION...)   ; intersection
(or CONDITION...)    ; union
(not CONDITION...)   ; exclude the union of these conditions
```

```elisp
(and (tag "task")
     (not (property "status" "done")))
```

## Basic conditions

| Condition | Meaning |
|---|---|
| `(tag NAME)` | nodes carrying a tag |
| `(property KEY VALUE)` | Org property; keys are case-insensitive, values match exactly. `field` is an older input alias; new queries should use `property` |
| `(term WORD)` | case-insensitive substring match in title and body |
| `(todo STATE...)` | the heading's Org TODO keyword; case-sensitive, several states match any. `task` is an older spelling and still works |
| `(priority PRIORITY...)` | the heading's priority; several values match any |

`todo` reads the heading state, not a custom property; likewise `tag` is never treated as a
same-named property. To query drawer properties named `todo` or `tag`, write
`(property "todo" "custom")`.

**An unknown single-string form is property shorthand**:

```elisp
(and (status "doing") (priority "A"))
;; (status "doing") is (property "status" "doing")
```

The shorthand requires exactly one string argument; a misspelled name yields an empty result
rather than an error. Built-in operators take precedence — a known operator with the wrong
arity or argument type errors out.

## Date conditions

```elisp
(after DATE)  (before DATE)  (between START END)
(recent-days N)  (in-month "YYYY-MM")  (in-year "YYYY")
```

Dates compare against a node's timestamp and accept absolute dates (`"2026-08-27"`, `"now"`)
as well as relative forms (`"-7d"`, `"+2w"`, `"-1m"`, `"1y"`).

## Named Org links

A named link in Org text looks like `[[supports:target][description]]`, where `supports` is
the relation name and `target` is the target node's ID (not its title). Query that relation
with the conditions below; `REL` is the relation name, given as a string or a symbol (e.g.
`"supports"`, `work/tasks`):

```elisp
(link REL TARGET-QUERY)          ; sources with a named link to a node matching TARGET-QUERY
(exists-link REL TARGET-QUERY)   ; synonym of link
(reverse-link REL SOURCE-QUERY)  ; targets linked from a node matching SOURCE-QUERY
(has-link REL)                   ; at least one outgoing link of that relation
(has-reverse-link REL)           ; at least one incoming link of that relation
```

```elisp
(and (tag "project")
     (link work/tasks (property "status" "blocked")))
```

The relation name cannot be empty. A valid traversal with no matches simply returns an empty
list.

## Result modifiers

Modifiers belong inside `and`:

```elisp
(sort-by KEY [asc|desc])
(group-by KEY)
(sum KEY)  (count)  (avg KEY)  (min KEY)  (max KEY)
(first KEY)  (last KEY)  (unique-count KEY)  (concat KEY)
```

```elisp
(and (link work/tasks (tag "task"))
     (sort-by "modified" desc))
```

An in-query `sort-by` defaults to `desc`, unlike the block parameter `:order` whose default
is `asc`; when the query carries its own `sort-by`, it wins and the block's `:sort`/`:order`
give way.

Plain node-list queries use `supertag-query-node-ids`; queries with aggregate modifiers use
`supertag-query-evaluate` (Babel and dynamic blocks pick for you).

## Builder and quick reference

```text
M-x supertag-query-build
M-x supertag-query-describe-syntax
```

## Failure behaviour

- A known operator with the wrong arity or argument type: error;
- an unknown single-string form: treated as property shorthand, may yield an empty result;
- other shapes (empty operator, keyword operator, shorthand with wrong arity): error;
- a valid query with no matches: empty list.

Property conditions read the Org properties already synchronized into the Store, not unsaved
file content.
