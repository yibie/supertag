# Ontology Policy v11

## Purpose

Policy is the authorization layer in front of Ontology Action.

```text
Function / precondition
  Is this transition valid in the current world?

Policy
  May this actor invoke it, and is confirmation required?
```

A Policy is data. It does not run callbacks, mutate the Store, or replace
business preconditions.

## Declaration

```elisp
(supertag-defontology work
  :version 11

  (field status
    :type options
    :options (active done))

  (type project
    :fields (status))

  (action complete-project
    :subject project
    :effects
    ((set-field status :value "done")))

  (policy complete-project-access
    :action complete-project
    :actors
    ((interactive-user confirm
      :reason "A person must approve completion")
     (automation deny
      :reason "Automation may not complete projects")
     (llm propose-only
      :reason "The model may prepare a proposal")
     (external deny
      :reason "External callers are disabled"))))
```

Every deployed Action requires exactly one Policy. Every Policy covers exactly
one rule for each actor class:

```text
interactive-user
automation
llm
external
```

The compatibility name `user` normalizes to `interactive-user`.

## Decisions

### allow

The actor may execute after Action subject, arguments, preconditions, Field
constraints, Link endpoint Types, and cardinality are validated.

### deny

Execution is rejected before expensive Function preconditions. No proposal,
effect, or successful run record is created.

### confirm

The trusted interactive boundary displays the exact read-only proposal and
issues a one-use confirmation capability. The capability is bound to:

```text
Action contract hash
Policy contract hash
subject node
actor kind and optional actor ID
normalized arguments
exact planned effects
```

A changed Field value, Link conflict, target resolution, Action contract, or
Policy contract makes the token stale. Tokens are memory-only and expire.

### propose-only

The actor may build a transient proposal but cannot execute. Confirmation does
not elevate this decision. A different actor with `allow` or `confirm` must
perform the transition.

This is the intended first boundary for LLM use:

```text
LLM
  -> proposes the Action and arguments
  -> cannot mutate

interactive user
  -> reviews
  -> confirms or rejects
```

LLM Tool generation itself remains outside v11.

## Action confirmation floor

The Action's existing `:confirmation` declaration remains a minimum floor:

```text
Policy allow + Action confirmation always
  -> confirm

Policy deny
  -> deny

Policy propose-only
  -> propose-only
```

The floor may strengthen `allow`; it cannot weaken any restrictive Policy
decision.

## Invocation

Programmatic callers must state an actor explicitly:

```elisp
(supertag-ontology-action-execute
 'work/action/complete-project
 PROJECT-ID
 nil
 :automation)
```

An actor may also carry a stable audit ID:

```elisp
'(:kind :interactive-user :id "oliver")
```

The current Policy language authorizes only actor classes. The ID is retained
in successful audit records for future identity-aware Policy layers.

For a proposal-only caller:

```elisp
(supertag-ontology-action-propose
 'work/action/complete-project
 PROJECT-ID
 '((reason . "All tasks are finished"))
 :llm)
```

Proposals are transient projections and are never a second fact store.

## Interactive UI

In an Org heading or Node View:

```text
M-x supertag-action-run
```

Node View labels applicable Actions as:

```text
[Run]
[Propose]
[Denied]
```

`A` selects and runs/proposes an Action for the current node. Clicking an Action
row uses the same trusted `interactive-user` boundary.

Listing is static and does not execute Function preconditions. Preconditions
run only during proposal/preview and again inside the Action transaction.

## Fail-closed runtime

Policy evaluation returns deny when:

- no Policy governs the Action;
- multiple Policies govern it;
- the Action or Policy contract hash is missing;
- the actor class is missing or duplicated;
- a decision is outside the closed set.

The caller cannot replace a deployed Action or Policy by passing a crafted
plist. Runtime references are re-resolved from Store-owned contracts.

## Action transaction corrections

Policy v11 includes the Action contract corrections required before Policy can
be trusted:

```text
preview outside transaction
  -> informational only

inside Action-owned transaction
  -> re-resolve Action and Policy
  -> rebind arguments
  -> rerun Function preconditions
  -> reread Field and Link facts
  -> replan effects
  -> revalidate confirmation fingerprint
  -> apply canonical Field / Link Ops
  -> write successful audit
  -> commit
```

Ops notifications are deferred until the outer Action commits and are dropped
on rollback. Field old/new values are not copied into Action audit records.
Sensitive parameters and Link targets are redacted.

## Control-plane classification

Function, Action, and Policy changes are `:behavioral`:

```text
safe auto-apply
  -> structural safe changes only

behavioral changes
  -> explicit approval

destructive changes
  -> Migration DSL
```

Changing who may execute an Action is executable behavior, even though it does
not rewrite existing user data.

## Deliberate v11 limits

Policy v11 does not implement:

- roles or groups;
- actor-ID-specific allow lists;
- field-based or time-based Policy conditions;
- Policy callbacks or arbitrary expressions;
- durable proposal queues;
- LLM Tool schemas or transport adapters.

The next layer may generate LLM tools from Function and Action contracts, but
it must consume this Policy result rather than bypass it.
