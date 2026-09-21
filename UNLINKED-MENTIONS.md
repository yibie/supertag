# Unlinked Mentions

Unlinked Mentions completes the create-or-link workflow without turning a
possible reference into a stored fact prematurely.

For the current Node View target, Supertag scans direct source-node content for
the target title and aliases.  It excludes existing Org links, source/example
blocks, fixed-width text, inline code, and verbatim regions.  It also skips a
source node that already links the target anywhere, including a link written in
that node's heading.  Chinese terms do not use inappropriate ASCII word-boundary
rules; ASCII identifiers do.

Node View shows one card per source node: the source title, the excerpt of the
first occurrence, and a muted `+N more` note when the source mentions the target
again.  The section count is the number of source nodes, and
`supertag-mention-max-results` caps that number, so one noisy source can no
longer hide other sources.

Each candidate provides:

- **Link** — replace the card's first occurrence with a canonical Org ID link;
- **Link all** — replace all live occurrences in that source node;
- **Ignore in node** — store a source-owned `SUPERTAG_IGNORE_MENTIONS` Org
  property on the source heading.

Candidates are disposable read models.  There is no `:unlinked-mentions`
collection and no second Backlink database.  Only an accepted Org link becomes
a reference fact through the existing document projection pipeline.
The candidate-taking mutation functions are internal Node View actions, not
standalone `M-x` commands.

Discovery uses a small non-persistent Org parse cache and a cheap text prefilter.
The cache is managed automatically and can be cleared programmatically with
`supertag-mention-service-clear-cache`; it is never saved.
