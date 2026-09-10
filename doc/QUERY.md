The legacy schema/table/kanban/search/capture entry points described here are archived; see README for the current workflow.

# Supertag Query Language

Supertag queries are S-expressions. Public entry points include:

```elisp
(supertag-query-node-ids QUERY)
(supertag-query-evaluate QUERY)
(supertag-query-validate QUERY)
```

They are also used by saved queries, query blocks and the guided builder.

## Boolean composition

```elisp
(and CONDITION...)
(or CONDITION...)
(not CONDITION...)
```

Examples:

```elisp
(and (tag "task")
     (not (field "status" "done")))

(or (tag "work")
    (tag "personal"))
```

## Basic conditions

```elisp
(tag NAME)
(field KEY VALUE)
(term WORD)
(task STATE...)
(priority PRIORITY...)
```

## Date conditions

```elisp
(after DATE)
(before DATE)
(between START END)
(recent-days N)
(in-month "YYYY-MM")
(in-year "YYYY")
```

Dates accept absolute values such as `"2026-08-27"`, `"now"`, and relative
values such as `"-7d"`, `"+2w"`, `"-1m"` and `"1y"`.

## Typed-Link conditions

### Forward traversal

```elisp
(link REF TARGET-QUERY)
(exists-link REF TARGET-QUERY)
```

Returns source Nodes that have the referenced Link to at least one target
matching `TARGET-QUERY`.

```elisp
(link work/tasks
      (field "status" "blocked"))
```

### Reverse traversal

```elisp
(reverse-link REF SOURCE-QUERY)
```

Returns target Nodes that have an incoming referenced Link from at least one
source matching `SOURCE-QUERY`.

```elisp
(reverse-link work/tasks
              (tag "project"))
```

### Existence

```elisp
(has-link REF)
(has-reverse-link REF)
```

`has-link` returns sources with at least one outgoing instance.
`has-reverse-link` returns targets with at least one incoming instance.

### Link references

`REF` can be:

```text
runtime ID       "linkdef-..."
unique name      "Tasks"
unique key       tasks
module/key       work/tasks
```

Saved queries should use `module/key`. A short name or key raises an error when
ambiguous rather than selecting a relation by accident.

### Composition

```elisp
(and
  (tag "project")
  (link work/tasks
        (and
          (tag "task")
          (field "status" "blocked"))))
```

Nested traversal:

```elisp
(link work/projects
      (link work/tasks
            (field "status" "blocked")))
```

Negation:

```elisp
(and
  (tag "project")
  (not (has-link work/tasks)))
```

Reverse composition:

```elisp
(and
  (tag "task")
  (reverse-link work/tasks
                (field "status" "active")))
```

## Result modifiers

Modifiers belong inside `and`:

```elisp
(sort-by KEY [asc|desc])
(group-by KEY)
(sum KEY)
(count)
(avg KEY)
(min KEY)
(max KEY)
(first KEY)
(last KEY)
(unique-count KEY)
(concat KEY)
```

Example:

```elisp
(and
  (link work/tasks (tag "task"))
  (sort-by "modified" desc))
```

Aggregate queries use `supertag-query-evaluate`; plain node-list queries use
`supertag-query-node-ids`.

## Guided builder and help

```text
M-x supertag-query-build
M-x supertag-query-describe-syntax
```

The builder reads Link Definitions from the live Schema and emits a stable
reference when available.

## Failure behavior

The parser rejects:

- unknown operators;
- wrong operator arity;
- malformed nested queries;
- unknown Link Definitions;
- ambiguous Link names or keys.

A traversal that is valid but has no matching instances returns an empty list.
