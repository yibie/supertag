# Supertag summary: an information panel you can act on

This file states what a summary is, who decides which part of it, and what
guarantees each rule. Form (font size, fills, label grammar, page skeleton,
cards) is defined in `design.md`; this file refers to it and does not repeat
it.

**Status: stage 1 is in the package.** `supertag-summary.el` and
`supertag-summary-runner.el` implement the fact layer, the elements, the
actions, components, storage and acceptance described here; the reading
layer of section 3 is not built. Every rule marked **[Enforced]** or
**[Accepted]** has a test in `test/summary-test.el`. The experiments that
led here are recorded in
`.scratch/design/proposals/2026-10-07_Summary探索空间.md` (experiments seven
to nine).

## 1. What it is, and what it is not

A summary is the information panel of one tag. It draws the records under
that tag in a form suited to seeing them as a whole, and lets the user run
actions on entries from the panel. Each kind of information has its own
layout. The user describes the layout in one sentence and a model writes it
as code.

- **Not a workspace.** The place where the user works on information is
  Emacs and the Org files themselves. A summary is for seeing the whole and
  handling an entry or two on the way; it does not replace opening the file.
- **Not an editor.** The panel cannot change body text, and it neither shows
  nor edits Org properties.
- **Not a table view.** There is no "rows × columns × switchable layouts",
  and the user declares no schema in advance.
- **What "act on" means:** running commands Supertag already has on an
  entry. Supertag supplies the list of actions; see section 6.

## 2. Who decides what

| Who | Decides | Does not decide |
|---|---|---|
| User | One sentence saying what to see; one sentence to revise after looking | Code, field declarations |
| Model | Layout: which elements, how to group and sort, where things go | Data shape, actions, colors, font size |
| Store | Data shape: which fields a record has | — |
| Supertag | Element vocabulary, actions, masthead and colophon, safety checks, acceptance | Layout |

This is where flexible data is absorbed. The model writes the layout while
looking at real data from the user's vault, and the structure is fixed in
the layout code. When the data changes, the user says one sentence and the
layout is rewritten.

## 3. Data: two layers

A panel's data has two layers with different refresh rules.

| | Fact layer | Reading layer |
|---|---|---|
| Content | Records, titles, TODO states, tags, dates, counts | Text a model wrote after reading bodies (what happened, recurring themes) |
| Source | Queried from the Store | One model run, 20 to 100 seconds |
| Refresh | Fetched again on every open and after every action | A snapshot; recomputed only when the user asks |
| What is sent to the model | When designing a layout: the title, state and tags of the first few records | The body text of the nodes under this tag |

- The reading layer is optional; the user's sentence decides whether a panel
  has one. A panel with only the fact layer never sends body text to a model
  and opens at once.
- The reading layer is saved to disk with a timestamp. When source records
  change it is marked stale, not recomputed. **(Not built. Stage 1 panels
  have the fact layer only.)**
- A panel that has both layers and also carries actions has not been run.
  The diary panel of experiment eight had a reading layer and no actions;
  the `prj` panel of experiment nine had actions and no reading layer.
- Layout code computes grouping, order and counts from the records on every
  call. It never hard-codes a record or a number. **[Prompted]**
- Any field may be nil. **[Prompted]**

## 4. What a layout is made of

**Elements.** A model may use 11 element types. Any other type or attribute
is refused. **[Enforced]**
- Three layout elements from textui: Flex (row or column), Grid (equal
  columns), and a paragraph that wraps.
- Eight content elements supplied by Supertag: single line, fill label, node
  link, state button, ratio bar, density cells, ornament rule, character
  canvas.
- The attributes and limits of each element are those in the manual sent to
  the model (`supertag-summary--manual`), and `supertag-summary--keys` is
  the list the check uses.

**Components.** A model may save a way of drawing as a named component, and
later panels call it by name.
- A component decides only how something looks. It cannot carry an action.
  **[Enforced]**
- A component returns the same 11 elements and passes the same checks.
  **[Enforced]**
- A component is kept with the Tag and the demo layout it was shown with, so
  it can be drawn again later. Components kept before this have neither.
- `M-x supertag-summary-components` opens the gallery: one card per
  component on its own surface, with its sentence, its docstring, its demo
  drawn on the Tag's notes as they are now, and the panels and components
  that call it. A component without a kept demo shows only its text.
- From a card: CODE shows the component and its demo; DEMO opens the demo as
  a panel; REVISE (`supertag-summary-component-revise`) sends the current
  code and the user's feedback to the model, and the reply passes the same
  checks; DELETE (`supertag-summary-component-delete`) asks first and names
  every panel that calls the component, since those stop drawing.
- Verified: a model wrote a component from one sentence, and a second panel
  called it unprompted.
- Open: components have no versions, so revising one overwrites it; and
  nothing keeps layouts consistent in style as components multiply.

**Page.** The page skeleton is the five bands of `design.md` section 5.
- Supertag draws the masthead, manifesto, action row and colophon. The model
  cannot change them. **[Enforced]**
- The model writes only the field.
- Those four bands have not been checked item by item against `design.md`
  section 8.

## 5. What guarantees each form rule

The rules of `design.md` fall into four levels here. Only the first two are
reliable; everything that drifted in the experiments was at the third.

| Level | Meaning | Rules at this level |
|---|---|---|
| **Enforced** | The model cannot produce a violation | One font size; no colored text; fills are not clickable; a fill pads one space on each side and uppercases English; tones are a closed set and Supertag picks the colors; buttons are traditional `[ ]` text buttons |
| **Accepted** | A violation is refused automatically and sent back to the model | The page lays out at 120 and at 80 columns; no line is wider than the page; the code uses only whitelisted functions |
| **Prompted** | Stated only in the prompt; the model may not comply | Labels read `NOUN / NOUN`; neighboring fills rotate 1, 2, 3; three-part cards; each card or group on a `:surface t` container, no borders; empty groups are not drawn as shells; overview before detail; single-line elements get enough width |
| **Judged** | Only the user can tell by looking | Whether the layout answers the sentence; whether something asked for is missing; how tight the spacing is; which records count as "tasks" |

The drift seen in the experiments was all at the last two levels:
- A fill label cut to `PRJ …` (the model left out the fill's side padding
  when computing width).
- A blank line between every line inside a section, which reads too loose.
- Links the user asked for were computed and then left out of the panel.
- Entries without a TODO state were treated as tasks.

So when adding a rule, first decide its level. A rule that can be an element
constraint or an acceptance check should not live only in the prompt.

## 6. Actions

- Supertag supplies actions; the model can only say which record. What a
  button shows and what it does cannot come from the model. **[Enforced]**
- If an element from the model contains `:action`, the whole panel is
  refused. **[Enforced]**
- After an action, the fact layer is fetched again, the panel is redrawn,
  and point returns to the same record. **(Verified; today the whole panel
  is redrawn, not one line.)**

| Action | Status |
|---|---|
| Open the node | Verified |
| Change TODO state (written to the source file and saved; chosen from that file's own keywords) | Verified |
| Others (new entry, add tag, archive, …) | Not built; which ones depends on what turns out to be missing in use |

The intended direction is that actions on an entry go through context
actions at point (embark style) instead of one kind of button per action.
**(Not built, not verified.)**

## 7. Safety

Code a model wrote never enters the user's Emacs session.
- The code is first checked against a function whitelist, by name.
  **[Enforced]**
- It then runs in a child Emacs process, which hands back only data.
  **[Enforced]**
- The main process rebuilds every element from that data: text is
  regenerated (text properties stripped), tones map to Supertag's own faces,
  and Supertag fills in the action of each link and button. **[Enforced]**

The limits, stated plainly:
- The whitelist is the real defense. The child process still has the user's
  file permissions; it only cannot reach the running session.
- The whitelist checks names, so it also refuses a variable that shares a
  name with a function. Today the error text steers the model to rename it.
- The reading layer sends node bodies to the model chosen by
  `supertag-summary-provider` (Superchat, gptel, or a function).
  The shipped feature must make explicit which tags may be sent and to whom.
  **(Not built.)**

## 8. Decided, and still open

- Decided and built: a panel is one data file, `NAME.org.summary`, under
  `summaries/` in the vault, bound to its tag by the tag's stable ID, and
  the Git layer syncs that file type. Components are stored the same way in
  `summaries/components/`. Still open: where reading-layer snapshots go, and
  whether a panel is inherited through `:extends`.
- A panel whose tag is merged into another tag or deleted keeps its file and
  says the tag is gone; nothing re-points it.
- How many panels a tag may have, and whether a panel is bound to a tag or
  to a query.
- Generate the prompt from this file and the element registry instead of
  copying it by hand. The "design rules" in today's prompt are a hand-made
  Chinese copy of `design.md`, which already makes two sources.
- How this relates to Stream: when an existing view is the
  right tool and when a summary is.
- Move every rule that can move from "Prompted" in section 5 down into an
  element constraint or an acceptance check.
