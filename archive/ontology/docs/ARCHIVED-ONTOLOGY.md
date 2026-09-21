> Ontology and Policy are archived and retained for historical reference only.

## Ontology Policy

Each deployed Action is governed by one fail-closed Policy covering
`interactive-user`, `automation`, `llm`, and `external`. Decisions are
`allow`, `deny`, `confirm`, or `propose-only`. Use `M-x supertag-action-run`
from an Org heading or Node View; LLM-facing code should call
`supertag-ontology-action-propose` when its Policy grants proposal only. See
[`ONTOLOGY-POLICY-V11.md`](ONTOLOGY-POLICY-V11.md).

## Ontology LLM Tools

A deployed Function or Action is exposed to an LLM only when its Ontology
source declares `:llm-tool t`. Function tools remain read-only. Action tools
are filtered through the `llm` Policy rule: `allow` executes, `confirm` needs an
out-of-band one-use capability, `propose-only` returns a transient proposal,
and `deny` is omitted. Inspect the current provider-neutral catalog with
`M-x supertag-ui-tool-list` or copy its JSON with
`M-x supertag-ui-tool-copy-catalog-json`. See
[`ONTOLOGY-LLM-TOOL-V12.md`](ONTOLOGY-LLM-TOOL-V12.md).

---

### Ontology as code

Once a tag/field pattern stabilises, declare it in Elisp instead of maintaining
it by hand in Schema View:

```emacs-lisp
(supertag-defontology work
  :version 1
  (field status :label "Status" :type options :options (idea active blocked done))
  (type project :label "Project" :fields (status))
  (type task    :label "Task"    :fields (status))
  (link tasks :label "Tasks" :inverse-label "Project"
        :from project :to task :from-cardinality many :to-cardinality one))
```

Loading the file only registers the declaration. `M-x supertag-ontology-preview`
shows the deployment plan against the live Store, with every operation classed
as **SAFE** (new fields, types, links, label changes), **BEHAVIORAL** (Functions,
Actions, Policies — apply asks for explicit approval), or **DESTRUCTIVE** (field
type changes, removed options, tightened cardinality — apply refuses until a
matching migration exists). `M-x supertag-ontology-apply` deploys the plan in
one transaction; redeploying an unchanged declaration is a no-op.

A deployed Type answers to its declaration key as well as its label: with the
module above, `#project` and `#Project` both bind to the Project type, and
`:aliases (proj 项目)` on a `type` form adds more spellings. Aliases you add by
hand in Schema View are kept.

Typed links then enforce endpoint types and cardinality (`Link Tasks permits
only one source for target node …`), and queries can traverse them:
`(and (tag "Project") (link work/tasks (field "status" "blocked")))`. Node View
lists each node's typed links and — once you add `function`, `action`, and
`policy` forms — its computed Functions and runnable Actions. Start from
`examples/personal-work-ontology.el`; see `ONTOLOGY-LINK-WORKFLOW-V5.md` and
`ONTOLOGY-FUNCTION-ACTION-V10.md` for the full forms.

### Ontology migrations

Ordinary ontology deployment accepts safe additions and compatible updates. A
destructive change—such as converting a Field type, removing a Type/Field
association, or tightening Link cardinality—must be paired with an explicit
`supertag-defmigration` declaration. Loading migration files only registers
pure declarations; preview is read-only, and apply commits data actions, the
Schema deployment, derived-relation reconciliation, and the Store-owned applied
ledger through one transaction.

Preview also flags transforms that would silently clear data: when a
`transform-field` callback maps an existing value to `nil`, the plan shows a
`WARNING :transform-clears-value` issue and a `cleared=N` count. Return
`supertag-ontology-migration-drop` to remove a value on purpose.

Migration DSL v1 deliberately supports only `transform-field`, `detach-field`,
and `tighten-link`. Every destructive operation must have exact coverage; Type
or global Field deletion, parent/endpoint changes, and rebinding remain blocked
instead of being hidden behind a force flag. See `ONTOLOGY-MIGRATION-V8.md` and
`examples/ontology-migration-v8-example.el`.

The legacy Embed and virtual-column implementations are archives: the default
package neither loads nor initializes or advertises them. Compatibility work
may explicitly load `supertag-ui-embed` or `supertag-virtual-column`; this makes
the archived Embed UI available. Automatic Embed save hooks additionally require
explicitly loading and initializing `supertag-services-embed`. Generated Embed
content remains excluded from document extraction.

