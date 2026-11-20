# GUI conversations

How to read a worker or Executor conversation in the [GUI](/guide/gui), in the browser and over HTTP.

## Open a full conversation

Select **Open in conversation** from a Command with a known conversation position,
or navigate to `/conversations/:conversation_id`. The worker conversation drawer remains available from `/voice`; the legacy Units board has retired.

A conversation without recorded messages shows **No messages yet**. Until its
journal exists, it also says **Conversation not found**; storage failures show
**Conversation unavailable** instead. The first recorded message appears without
reloading the page.

The event navigation lists progress, pushes, PRs and Commands. Select an event
to jump to and highlight its transcript position. Filter chips include CI and
reviews when needed. **Approximate position** means the event was observed near
that entry; it does not claim an exact causal match.

On phones the event list
sits above the transcript and scrolls independently.

`/conversations/:conversation_id` opens the durable conversation page. Read-only
dashboards keep the transcript and event navigation available; sending requires
writable access and an available listener.

It starts with the latest 50 entries. **Load older**, **Jump to start**,
and **Load newer** browse earlier history; **Latest entries** returns to the
live tail.

Agent prose uses Markdown. Executor reasoning rows are hidden; worker reasoning
and command or tool output start collapsed. Select a summary to expand it.

File edits show diffs. Operator bubbles, session dividers and gap rows keep the
source and continuity visible. See
[Reading entries](/concepts/conversations#reading-entries) for masking and
truncation details.

The page keeps up to 500 entries on screen. When you scroll up,
new entries show a counter that returns you to the latest page.

The status distinguishes live, idle, ended, continuity unknown and unavailable
history. Journal failures keep the last readable content with a stale marker
and observation age. Imported history shows **Earlier history is not available**.

## Read a conversation over HTTP

These read-only routes use dashboard authentication or a read client token,
including when
`dashboard_writable` is false. Responses set `Cache-Control: no-store`:

- `GET /api/v1/conversations/resolve?subject=executor`
- `GET /api/v1/conversations/resolve?subject=worker&owner=OWNER&repository=REPO&identifier=NUMBER`
- `GET /api/v1/conversations/ID/entries`
- `GET /api/v1/conversations/ID/sessions`
- `GET /api/v1/conversations/ID/anchors`

Resolve returns `conversation_id` and `subject`. Worker lookup uses the full
repository and stored provider identity; multiple conversations matching a
transferred issue return `409 ambiguous_subject` with `conversation_ids`.
No matching subject returns `404 subject_not_found`.

Entries default to the last 50 positions in ascending order. Choose one of
`tail=true`, `from_start=true`, `before=POS`, `after=POS`, or `around=POS`,
with `limit=1..200` and optional comma-separated `kinds`. Follow `prev_cursor`
with `before` or `next_cursor` with `after`; null means that direction is
complete.

Pages include sessions, `head_pos`, `complete_from_start`, and
`observed_at`. An existing empty conversation returns an empty page with
`head_pos: 0`; an unknown ID returns `404 conversation_not_found`. Unreadable
storage returns `503 conversation_unavailable`; invalid cursors or limits
return 422.

Anchors accept `kinds`, `pos_from` and `pos_to` (inclusive).
Sessions contain no local source paths.

Conversation text can contain secrets. Body and output are masked by default;
`reveal=true` is honored only for an authenticated operator connecting from
loopback. Device principals and client tokens always remain masked. Basic Auth is refused
on public binds. Treat revealed content as sensitive.

Write verbs return 405; sends continue through the listener path.
