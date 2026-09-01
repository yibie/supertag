# Ontology Policy v11

Policy v11 adds fail-closed authorization in front of deployed Ontology
Actions.  It does not change the meaning of Function or Action:

- Function reads and computes.
- Action checks business preconditions and changes Semantic Facts.
- Policy decides whether an actor may invoke an Action and whether one explicit
  confirmation is required.

## Declaration

Every Action must have exactly one Policy, and that Policy must cover all four
actor classes exactly once:

```elisp
(supertag-defontology work
  :version 11

  (type project :label "Project")

  (action complete-project
    :subject project
    :effects (...)
    :confirmation :never)

  (policy complete-project-access
    :action complete-project
    :actors
    ((user allow)
     (automation deny :reason "Only an explicit caller may complete it")
     (llm confirm)
     (external deny))))
```

The accepted actor classes are:

| Actor | Meaning |
| --- | --- |
| `user` | Interactive user invocation |
| `automation` | Supertag Automation invocation |
| `llm` | LLM or Agent invocation |
| `external` | Other adapters and integrations |

The accepted decisions are `allow`, `deny`, and `confirm`.

Execution must supply the actor explicitly.  A missing actor is not assumed to
be an interactive user.

Missing Policy, duplicate Policy, missing actor coverage, an unknown actor, or
malformed deployed Policy state fails closed.

## Action confirmation floor

The Action v10 `:confirmation` field remains a minimum safety floor:

| Action mode | Effect |
| --- | --- |
| `:never` | Policy decision is unchanged |
| `:always` | Every `allow` becomes `confirm` |
| `:llm` | An LLM `allow` becomes `confirm` |
| `:external` | An external `allow` becomes `confirm` |

The floor can strengthen `allow` to `confirm`; it cannot weaken `deny` or a
Policy-declared `confirm`.

## Confirmation

For a `confirm` decision, build an Action preview and request a token through
the trusted interactive confirmation boundary:

```elisp
(let* ((plan (supertag-ontology-action-preview
              'complete-project project-id arguments))
       (token (supertag-ontology-policy-request-confirmation plan :user)))
  (supertag-ontology-action-execute
   'complete-project project-id arguments :user token))
```

The token is:

- held only in runtime memory;
- valid for `supertag-ontology-policy-confirmation-ttl` seconds;
- consumable once;
- bound to the Action contract, Policy contract, subject, actor, and arguments.

A changed contract, different arguments, different actor, expired token, or
second use is rejected before the Action transaction starts.

## Audit

A successful Action ledger record now includes:

```text
actor kind and optional stable actor ID
effective allow/confirm decision
Policy runtime and logical identity
Policy contract hash
bounded confirmation metadata
```

The opaque token is never persisted.  Rejected attempts produce no successful
Action ledger entry.

## Deliberate exclusions

Policy v11 does not add role hierarchies, identity providers, arbitrary Policy
callbacks, Org text mutation, shell/network effects, external confirmation
services, or LLM Tool Generation.  Those require separate adapters or later
contracts.
