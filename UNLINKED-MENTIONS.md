# Unlinked Mentions

Unlinked Mentions completes the create-or-link workflow without turning a
possible reference into a stored fact prematurely.

For the current Node View target, Supertag scans direct source-node content for
the target title and aliases.  It excludes existing Org links, source/example
blocks, fixed-width text, inline code, and verbatim regions.  Chinese terms do
not use inappropriate ASCII word-boundary rules; ASCII identifiers do.

Each candidate provides:

- **Link** — replace one exact occurrence with a canonical Org ID link;
- **Link all in node** — replace all live occurrences in that source node;
- **Ignore in node** — store a source-owned `SUPERTAG_IGNORE_MENTIONS` Org
  property on the source heading.

Candidates are disposable read models.  There is no `:unlinked-mentions`
collection and no second Backlink database.  Only an accepted Org link becomes
a reference fact through the existing document projection pipeline.

Discovery uses a small non-persistent Org parse cache and a cheap text prefilter.
The cache can be cleared with `M-x supertag-mention-service-clear-cache` and is
never saved.
