# Supertag Automation Guide

> 中文: [automation_cn.md](automation_cn.md)

This document describes the behaviour of the current `supertag-automation.el`.

## Model

A rule is three pieces of data, stored in the database's `:automations` collection:

- **Trigger (WHEN)**: when it runs;
- **Condition (IF)**: whether it runs this time; optional;
- **Actions (THEN)**: what it does, in order.

The engine starts with Supertag, but it touches no file while there are no rules. Event rules
fire on Store changes (what sync brings in); scheduled rules are triggered by the scheduler.
Actions may write back to the source Org file (what `:call-function` does is up to you).
While one action runs, rules are not triggered again (recursion protection).

## Build rules with the template wizard (recommended)

1. `M-x supertag-automation-insert-template`;
2. pick a template from the list; each carries a one-line description;
3. fill in the parameters it asks for: tags and TODO keywords complete, files use file-name
   completion, the rest is plain input;
4. a preview buffer shows the rule plist that will be created; it is created only after you
   confirm with `y`.

To browse the templates first, use `M-x supertag-automation-list-templates`; `M-x supertag-menu`
has an entry too. A rule's name determines its storage ID (`auto-<rule name>`); the same name
replaces an existing rule, and the wizard asks before doing so.

Current templates (9):

| Template | Trigger | Effect |
|---|---|---|
| Tag added -> set TODO state | a tag is added | set the node's TODO keyword (e.g. adding `#done` sets DONE) |
| Tag added -> set a property | a tag is added | set a property to a fixed value (e.g. adding `#urgent` sets PRIORITY=A) |
| Tag added -> add another tag | a tag is added | add a second tag (implication, e.g. `#bug` implies `#needs-triage`) |
| Tag removed -> remove a derived tag | a tag is removed | remove a derived tag as well |
| Property change -> update another property | property change under a tag | set another property on that node to a fixed value |
| Property equals value -> move node to file | property change | move the node to a target file when a property equals a value |
| Property equals value -> add tag | property change | add a tag when a property equals a value |
| Scheduled daily -> set property on tagged nodes | daily schedule | set a property on every node carrying a tag |
| Tag added -> create follow-up node | a tag is added | create a new node with a given title and tags (no link back to the source node) |

## Triggers, conditions, actions

**Triggers** (`:trigger`):

- `(:on-tag-added "tag")`, `(:on-tag-removed "tag")`;
- `:on-property-change` — when a property changes;
- `:on-change`, `:always` — on any Store change;
- `:on-schedule` — timed, see the next section;
- `:manual` — a reserved word with no trigger entry point; it never fires automatically.

**Conditions** (`:condition`, optional): omit it or write `t` for unconditional execution. It
shares the query S-expression grammar, so `(property "STATUS" "ready")`, `(term "emacs")`,
`(recent-days 7)` all work; older spellings are accepted too: `(has-tag "task")`,
`(property-equals :status "ready")`, `(property-changed :status)` (the latter only has a
change to inspect under `:on-property-change`), `(property-test :status #'string= "ready")`.
Combine conditions with `and`, `or`, `not`. The full operator set is in
[query.md](query.md).

**Actions** (`:actions`, a list, run in order):

| Action | Parameters | Notes |
|---|---|---|
| `:update-property` | `:property` `:value` | write the Org property and refresh the projection |
| `:update-todo-state` | `:state` | set the TODO keyword |
| `:add-tag` | `:tag` | add a tag, creating the tag first if needed |
| `:remove-tag` | `:tag` | remove a tag; unresolved tags are skipped and logged |
| `:create-node` | `:title` `:target-file`, optional `:tags` | create a node |
| `:move-node` | `:target-file`, optional `:leave-link` `:target-level` | move a node; skipped when already in the target file |
| `:call-function` | `:function`, optional `:args` | the function receives node-id, context and `:args` |
| `:case` | `:on` + `:branches` | branching action, see below |

Each `:case` branch matches with one of `:equals` / `:in` / `:match` / `:test`, and
`:actions` holds that branch's actions (`:do` and `:then` are aliases); a `:default` branch is
allowed. Branches are a small program rather than a few scalar parameters, so the template
wizard does not generate them — write them by hand when needed.

## Scheduled rules

The easiest path is the wizard's "Scheduled daily -> set property on tagged nodes" template:
once a day at the given time it sets a property on the nodes carrying a tag. `:schedule`
currently only accepts `:time "HH:MM"` (24-hour), plus optional `:days-of-week` (1 to 7,
Monday is 1).

Note that registration only picks out `:call-function` actions: other action types in a
scheduled rule will not run (`:call-function` receives a nil node-id, with `:scheduled t` in
the context). The scheduler starts with Supertag and checks every 300 seconds by default
(`supertag-scheduler-check-interval`). The last-run date lives in `scheduler-state.json` in
the data directory, so a day does not run twice — but a day missed while Emacs was closed is
not caught up.

## Writing a rule by hand

When the templates do not cover it, pass a plist to `supertag-automation-create` yourself.
This rule turns "URGENT is set to yes" into "PRIORITY is set to A"; evaluate it once in
`M-x ielm`:

```emacs-lisp
(setq my/urgent-rule
      (supertag-automation-create
       '(:name "urgent sets priority A"
         :trigger :on-property-change
         :condition (property-equals :urgent "yes")
         :actions ((:action :update-property
                    :params (:property :priority :value "A"))))))
```

Rules live in the database, so creating one once is enough; there is no need to recreate them
at every startup. Inspecting, disabling and deleting all use Lisp functions:

```emacs-lisp
(plist-get my/urgent-rule :id)                        ; storage ID
(supertag-automation-get-by-name "urgent sets priority A")
(supertag-automation-update (plist-get my/urgent-rule :id)
                            (lambda (rule) (plist-put rule :enabled nil)))
(supertag-automation-delete (plist-get my/urgent-rule :id))
```

`(supertag-automation-list)` lists all rules (it takes an optional filter function); each
element is the rule's full plist. Setting `:enabled` to `nil` stops it from running. For
debugging, turn on `supertag-automation-verbose` (off by default) to log rule matching and
execution; every file write goes through the Org service, and errors show up in `*Messages*`.
