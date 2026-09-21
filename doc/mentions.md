# Unlinked Mentions: Behaviour Bounds

> 中文: [mentions_cn.md](mentions_cn.md)

Unlinked Mentions completes the create-or-link workflow without turning a possible
reference into a stored fact prematurely. This section appears only for concept nodes —
headings that live in the files your templates target and carry a persistent ID; ordinary
note nodes do not show it.

## What it looks for

For the current Node View node, Supertag scans the **source node's own body** for the target
title and aliases. The following are not candidates:

- existing Org links;
- source/example blocks, fixed-width text, inline code, verbatim regions.

If a source node already links the target anywhere (including in its heading), that source is
skipped entirely. Chinese does not use ASCII word-boundary rules; ASCII identifiers do.

## What Node View shows

One card per source node: the source title, the excerpt of the first occurrence, and a muted
`+N more` when the source mentions the target again. The section count is the number of source
nodes, and `supertag-mention-max-results` caps that number, so a single source cannot fill the
whole section.

Each candidate provides three actions:

- **Link** — replace the card's first occurrence with a canonical Org ID link;
- **Link all** — replace all live occurrences in that source node;
- **Ignore in node** — write a `SUPERTAG_IGNORE_MENTIONS` Org property on the source heading.

## Data bounds

- Candidates are disposable read models: there is no `:unlinked-mentions` collection and no
  second Backlink database; only an accepted Org link becomes a reference fact, through the
  existing document projection.
- The three actions are internal Node View actions, not standalone `M-x` commands.
- Mention search uses a temporary Org parse cache and a simple text prefilter; the cache is
  managed automatically and can be cleared programmatically with
  `supertag-mention-service-clear-cache`. It is never saved.
