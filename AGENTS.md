# Supertag agent notes

Before you write or change any view buffer (Node View, Tag Cards, Stream,
Tag Manager, or a new `supertag-view-*.el`), read `design.md`. It is the
single source of truth for how a view looks: one font size, accent colors
as filled blocks only, `NOUN / NOUN` label grammar, character-built
ornament, the five-band page skeleton and the three-part card template.
Node View is not exempt; it is the first page to bring in line with it.
Finish view work with the checks in its last section, including a text
render at widths 120 and 80.
