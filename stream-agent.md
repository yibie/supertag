# Supertag Stream agents: a Stream laid out for its kind of note

`supertag-stream-agent.el` implements this contract. A rule marked
**Enforced** is checked by code and has a test in
`test/stream-agent-test.el`; keep it that way. A rule marked **Prompted** is
only asked of the model.

## 1. What it is

The user says one sentence about a tag, such as "people I haven't contacted
for a month rise to the top; when I've contacted one, a key notes it and it
sinks". A model writes an agent once. From then on the agent runs without a
model, every time a Stream it matches is drawn.

An agent customises the Stream; it does not replace it. Stream still draws
every title, tag and body, owns selection, opening, editing, narrowing and
refresh, and follows `design.md`. The agent decides the grouping, the order
within groups, one line after each title, the fields it writes and the keys
that write them.

A summary panel (`summary.md`) is the other half: a page for looking back
over a whole tag. A Stream agent is for working through the notes one by
one.

## 2. Who decides what

| Part | Decided by | Form |
|---|---|---|
| Scope | the tag the user names | `(:tag TAG-ID)` |
| View: groups, order, one line per node | the model | a `(lambda (data width) …)` string |
| Fields the agent writes, their shape and choices | the model, from the sentence | data |
| Actions: key, label, field, value | the model | data |
| Frame, titles, bodies, selection, Stream keys | Stream | code |
| Where a value written by a key comes from | Supertag | code |

Agents are files, `stream-agents/NAME.eld`, beside the notes as summary's
`summaries/` are, so they travel with the vault. `supertag-stream-agent-directory`
overrides the place.

## 3. Matching, not inheritance

- **Enforced.** An agent applies to every Stream whose nodes all lie in its
  scope: the tag's Stream, a Stream narrowed from it, and a query Stream over
  the same notes alike. There is no rule of inheritance between Streams.
  (`…-arranges-the-stream-of-its-tag`, `…-matches-by-scope-not-by-inheritance`)
- **Enforced.** When several scopes hold a Stream, the smallest wins.
  (`…-smallest-scope-wins`)

## 4. The view

- **Enforced.** The view runs in the child Emacs of
  `supertag-summary-runner`, with the same whitelist as summary. It returns
  data only: `(:header :notes :groups ((:label :rows ((:ref :line) …)) …))`.
  (`…-lines-fit-the-width`)
- **Enforced.** A node the view leaves out is drawn in a last group, "其余".
  An agent can reorder and annotate; it cannot hide a note.
  (`…-cannot-hide-a-node`)
- **Enforced.** A view that fails says so above every node in one group, and
  the agent's keys stay bound so it can be revised in place.
  (`…-that-fails-still-shows-every-node`)
- **Enforced.** `(funcall 'days …)` and `(funcall #'days …)` are read as
  `(funcall days …)`: models write the quote often enough that refusing it
  cost real attempts. (`…-days-is-called-either-way`)
- **Enforced.** A field's choices are listed with commas: Stream is an Org
  buffer, and `a/b/c` would be read as `/italic/` markup.
  (`…-arranges-the-stream-of-its-tag`)
- **Prompted.** Lines separate items with `,` or `·`, never Org's markup
  characters `/ * _ = ~ +`.
- **Prompted.** Whatever the sentence asks for that the view cannot do is
  said in `:notes`.

## 5. Fields are made for the need

Properties in Supertag have no schema decided in advance; they exist because
a user needed them. So an agent declares the fields its actions write.

- **Enforced.** An action writes only a field the agent declares, even one
  already in use in scope; otherwise the agent would fail the day that value
  is removed. A revision asks the model to declare any it missed. A field has a shape, `date`, `number`, `text` or `choice`;
  `choice` lists its values. Names are upper case and not reserved (`ID`,
  `CREATED`, `CATEGORY`, Org's own, `…_ALL`). (`…-refuses-what-the-rules-forbid`)
- **Enforced.** The declaration is the field's rule for every node in scope,
  whatever file it lives in. Org's `KEY_ALL` works per file or subtree, never
  per tag. (`…-declaration-holds-in-every-file`)
- **Enforced.** The values a key may write come first from Org's `KEY_ALL`
  where the node lives, then from the agent's declaration, then from values
  already in use. (`…-org-declaration-comes-first`)
- **Prompted.** Design for the sentence; reuse a field that means the same.
  The property guide is shared with summary
  (`supertag-summary-property-guide`).

## 6. Actions

- **Enforced.** An action writes one field on the node at point and nothing
  else. Its value is `today`, `created`, `choose` (the user picks one of the
  field's values), `ask` (the user types one), or a fixed value among the
  field's values. No action creates a note or runs on a timer.
  (`…-refuses-what-the-rules-forbid`)
- **Enforced.** `ask` follows the field's shape: a date field asks for a
  date, a number field for a number, a text field for one line. A `choice`
  field takes `choose`, never `ask`. (`…-ask-takes-what-the-user-types`)
- **Enforced.** Keys are single characters and never shadow Stream's own
  (`n p e v f u m g q`) or the agent's `R` and `C`.
- **Enforced.** After a write the Stream redraws and the cursor stays at the
  same row; the node moves, the cursor doesn't.
  (`…-action-writes-org-and-keeps-the-row`)
- **Enforced.** The keys work on the first draw of a Stream, without a
  refresh. (`…-keys-work-on-a-fresh-open`)
- **Enforced.** `R` revise, `C` code and `g` refresh are also buttons in the
  header. (`…-buttons-run-the-commands`)

## 7. Design, self-check and revision

- **Enforced.** Designing sends the sentence, the property names and six
  records with every non-date value masked; never a body.
  (`…-design-sends-no-body-and-no-value`)
- **Enforced.** A reply is checked as summary's are; a refused reply goes
  back with the reason, at most three times, and nothing is kept if none
  passes. (`…-design-keeps-nothing-when-no-reply-passes`)
- **Enforced.** A reply that runs is held to rules code can check, and
  refused like any other when one fails, so the model writes it again:
  every record is placed in one of its groups (`…-check-refuses-a-left-out-record`,
  `…-design-rewrites-an-agent-that-leaves-records-out`); the view draws a
  Stream of one note, as after narrowing
  (`…-check-refuses-a-view-that-breaks-on-one-note`); and it still draws
  after each key has written (`…-check-refuses-a-key-that-breaks-the-view`).
- **Enforced.** Before an agent is kept, the model is shown what it draws on
  the real records, without titles or values: the groups and their sizes,
  how many fall to "其余", and where each key would move a note. It answers
  OK or a corrected agent, for `supertag-stream-agent-self-check-rounds`
  rounds. (`…-design-self-checks-then-keeps`, `…-self-check-correction-is-kept`)
  Code that runs but does not do what was asked was the usual failure in
  the experiments; this is the check against it.
- **Enforced.** A revision shows the model the agent as it is and every
  change asked before. Only the user's own words are kept as revisions,
  never the model's checks. (`…-revision-keeps-only-the-users-words`)

## 8. Managing agents

- **Enforced.** `supertag-stream-agent-manage` lists every kept agent with
  its state and sentence: 启用, 停用, or 失效 with the reason (a file that
  can't be read, or one the rules refuse). From there an agent's Stream is
  opened, or the agent is shown, revised, stopped, started or deleted.
  (`…-list-shows-every-agent-and-why-one-fails`)
- **Enforced.** Stopping keeps the file and marks it `:disabled`; its tag's
  Stream is drawn as before until it is started again. Deleting asks, then
  removes the file. Open Streams redraw either way.
  (`…-stop-start-and-delete`)

## 9. Decided against

- **An action that creates a note.** Notes are only ever written in Org
  text; a note enters a Stream when the user tags it there. The Stream is
  a view of the text, never a place notes come from. The text is the only
  truth, so an agent only changes properties of notes that already exist.
- **Running when a note is opened.** Opening a tag's Stream is already the
  moment the agent works: its groups, lines and keys are the interface for
  that tag. A second, per-note moment adds nothing.

## 10. Still open

- Agents that run when a note arrives, to fill a field quietly.
