# Ontology LLM Tool Generation v12

## Purpose

v12 turns explicitly exposed, deployed Ontology Function and Action contracts
into a provider-neutral tool catalog. It does not scan arbitrary Emacs Lisp
functions and it does not connect to an LLM provider.

```text
Ontology Function / Action
        |
        +-- explicit :llm-tool t
        |
        v
Policy-aware transient descriptor
        |
        v
JSON Schema + versioned tool name + invocation router
```

The generated catalog is a Projection. It is rebuilt from current Store-owned
contracts and is never persisted as a second registry.

## Explicit exposure

A Function or Action is invisible to the tool layer unless its Ontology
declaration opts in:

```elisp
(function project-progress
  :subject project
  :returns number
  :implementation work-project-progress
  :llm-tool t
  :tool-name "project_progress"
  :tool-description "Calculate current project progress")

(action complete-project
  :subject project
  :effects ((set-field status :value "done"))
  :llm-tool t
  :tool-name "complete_project")
```

`:tool-name` and `:tool-description` are optional. An explicit name must contain
1–48 ASCII letters, digits, underscores, or hyphens, beginning with a letter.
The final generated name receives a kind prefix and contract fingerprint:

```text
st_fn_project_progress_a8d14cb21f
st_act_complete_project_37f984c10a
```

A Function, Action, or Policy contract change therefore produces another tool
name. Calls using an old catalog fail closed as stale instead of silently
executing newer behavior.

## Policy mapping

Function tools are read-only and require explicit exposure. Action tools are
also filtered through the deployed `:llm` Policy rule:

| Policy decision | Generated behavior |
|---|---|
| `allow` | executable Action tool |
| `confirm` | tool returns a confirmation-required proposal until a trusted boundary supplies a one-use token |
| `propose-only` | proposal tool; it never executes |
| `deny` | omitted from the provider catalog |

A denied Action is not addressable by inventing its name. A `propose-only`
Action cannot consume a confirmation token to elevate itself.

## Input schema

Every tool uses one stable top-level object:

```json
{
  "subject_id": "NODE-ID",
  "arguments": {
    "parameter": "value"
  }
}
```

The generated JSON Schema carries:

- the required subject Type;
- ordered parameter names;
- primitive, optional, list, options, node-reference, and ontology-Type shapes;
- required fields and defaults;
- `writeOnly` and `x-supertag-sensitive` markers for sensitive parameters;
- `additionalProperties: false` at both levels.

Sensitive defaults are not copied into the catalog.

JSON `false`, JSON `null`, an omitted value, and an empty array retain distinct
semantics. `null` is accepted only by `(:maybe TYPE)` or `:any`; `false` is
accepted as false only for boolean-compatible contracts.

## Catalog API

```elisp
(supertag-ontology-tool-catalog '(:kind :llm :id "agent-1"))
(supertag-ontology-tool-list :llm)
(supertag-ontology-tool-catalog-json :llm t)
```

The JSON form is intentionally close to common function-tool formats:

```json
{
  "catalog_hash": "...",
  "actor": {"kind": "llm"},
  "tools": [
    {
      "type": "function",
      "name": "st_fn_project_progress_a8d14cb21f",
      "description": "...",
      "parameters": {"type": "object"},
      "x-supertag": {
        "kind": "function",
        "mode": "read",
        "logical_id": "work/function/project-progress",
        "tool_fingerprint": "...",
        "output_schema": {"type": "number"}
      }
    }
  ]
}
```

It deliberately omits implementation symbols, internal Store records, denied
Action definitions, and transport-specific metadata.

## Invocation

Programmatic invocation:

```elisp
(supertag-ontology-tool-invoke
 TOOL-NAME
 '(:subject_id "NODE-ID"
   :arguments (:horizon 30))
 nil
 '(:kind :llm :id "agent-1"))
```

JSON invocation:

```elisp
(supertag-ontology-tool-invoke-json
 TOOL-NAME
 "{\"subject_id\":\"NODE-ID\",\"arguments\":{\"horizon\":30}}"
 nil
 :llm)
```

The router re-resolves the current deployed definition and Policy. It never
trusts a caller-supplied descriptor as execution authority.

## Confirmation boundary

A `confirm` tool without a token returns a transient proposal envelope. A
trusted interactive boundary may request a memory-only capability:

```elisp
(supertag-ontology-tool-request-confirmation TOOL-NAME INPUT :llm)
```

The same typed argument conversion is used for both confirmation and execution.
The underlying Policy capability remains one-use, expiring, and bound to:

- Action and Policy contract hashes;
- subject and actor;
- normalized arguments;
- exact planned effects.

The token is not included in the generated tool schema or returned to an LLM by
the catalog layer. Transport adapters must keep that channel out-of-band.

## Result envelopes

Function result:

```json
{
  "status": "ok",
  "kind": "function",
  "tool": "...",
  "logical_id": "...",
  "result": 72
}
```

Action responses use `executed`, `proposal`, or `confirmation_required`. Typed
boolean false and nullable results are encoded as JSON `false` and `null`, not
as ambiguous strings.

## UI

```text
M-x supertag-ui-tool-list
M-x supertag-ui-tool-copy-catalog-json
```

The catalog buffer is read-only. `g` rebuilds it; `j` copies provider-neutral
JSON. This UI neither registers tools with a model nor opens a network
connection.

## Ownership and persistence

```text
Function / Action / Policy Store records
  own executable and authorization contracts

Tool generator
  owns transient descriptors and routing only

Provider adapter
  not implemented in v12
```

v12 adds no canonical collection such as `:ontology-tools`, `:tool-catalogs`,
or `:tool-proposals`.

## Deliberate limits

v12 does not implement:

- OpenAI, Anthropic, gptel, MCP, or HTTP adapters;
- automatic registration with a model runtime;
- arbitrary `defun` scanning;
- durable proposals or confirmation tokens;
- Policy roles, groups, or attribute conditions;
- automatic exposure of every Function or Action.

The next layer should be a thin provider adapter over this stable catalog and
invocation boundary, not another execution authority.
