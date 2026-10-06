---
ticket_id: MP-R2-C7-T02
feature_id: MP-R2
chunk_id: MP-R2-C7
bucket: 1 (Bucket-2-enabling, RC-09)
title: Live feed — /events socket, events:feed channel, short-lived token, backlog then live, 25 s heartbeat
status: ready
blocked_by: [DESIGN-R2 §2, MP-R2-C7-T01, MP-R2-C6-T02]
prior_units: [U8]
prior_boundaries: [BUS #10, WEB #34, SD #35]
prior_features: [MP-R1 (web-shell socket registration, MP-R1-C6-T3)]
prior_findings: []
size_owner: n/a (new files < 300 lines each; endpoint.ex and router.ex gain ≤ 6 lines; re-check per RC-23)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C7-T02 — Live event channel

## Identity and outcome

- **Bucket 1, MP-R2, chunk C7. Bucket-2-enabling (RC-09)**, disabled by default.
- **User value:** a foreground client (phone app open, meta-dashboard) sees
  new events within a second instead of polling, and resumes exactly where
  it stopped after a reconnect.
- **Deliverable:** `POST /api/v1/events/token`, socket `/events`
  (`AiurWeb.EventsSocket`), channel `events:feed` (`AiurWeb.EventsChannel`):
  join with `{after, topics}` → backlog records then live records, a
  `heartbeat` every 25 s carrying `head_seq`, `reset`/`gap` records as in
  the pull API.
- **Non-goals:** no client-to-server messages except join; no publish;
  no device-token issuance (C7-T05).

## Dependencies and blockers

- DESIGN-R2 §2; **C7-T01** (reader adapter, filter/subset rule, error
  codes reused verbatim); **C6-T02** must emit the append notification
  below.
- MP-R1-C6-T3 (socket registration) is not required: if it has landed,
  register `/events` through it; otherwise add the `socket/3` line to
  `endpoint.ex` like the existing three.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Token issue: `Phoenix.Token.sign(Endpoint, "streamdeck-v1", %{generation, expires_at_ms})`, only when dashboard credentials are configured (`required?: true`) | `src/lib/aiur_web/streamdeck_auth.ex:7-21` |
| Token verify: `max_age: 300`, `expires_at_ms` in the future, current credential `generation` constant-time equal | `streamdeck_auth.ex:23-45` |
| Token endpoint under `:dashboard_auth_required`, returns `{token, expires_in_seconds}` or 401 | `router.ex:180-184`; `controllers/streamdeck_session_controller.ex:8-14` |
| Socket `connect/3` verifies the token, assigns generation and expiry; no params → `:error`; `id/1` nil | `src/lib/aiur_web/streamdeck_socket.ex:10-28` |
| Socket mounted with `websocket: true, longpoll: false` | `src/lib/aiur_web/endpoint.ex:19-22` |
| **Channel lifetime is bounded by the token:** join schedules `:streamdeck_auth_expired` at `expires_at_ms` and stops; a credential-generation change also stops it | `src/lib/aiur_web/streamdeck_channel.ex:37,238,240-243`; subscription `financial_data_access.ex:140` |
| Channel test harness (`Phoenix.ChannelTest`, `connect` with a real token, `subscribe_and_join`, credential-change invalidation test) | `src/test/aiur_web/streamdeck_channel_test.exs:1-3,122-160` |

PROPOSED: `src/lib/aiur_web/events_auth.ex`, `events_socket.ex`,
`events_channel.ex`, `controllers/events_session_controller.ex`, and
`src/test/aiur_web/events_channel_test.exs`.

## Chosen design

### Token lifetime and re-verification (decided)

Reuse the Stream Deck model exactly, with its own salt `"events-v1"`:

- Token `max_age` **300 s**; the channel stops itself at `expires_at_ms`
  and on any credential-generation change.
- Rationale (evidence): the Stream Deck sidecar is already a long-lived
  client that lives with this bound in production (`streamdeck_channel.ex:37,238`);
  the feed's `seq` cursor makes a reconnect lossless and cheap (the
  client rejoins with `after=<last applied seq>` and gets only the
  missed records), which the Stream Deck snapshot model does not have. A
  longer token would let a socket outlive a changed dashboard password or,
  after MP-N2, a revoked device; a shorter one adds reconnect churn with no
  security gain because the generation check already closes on change.
- Clients refresh the token (`POST /api/v1/events/token`) and reconnect
  before `expires_in_seconds` elapses; the server sends
  `{"type":"auth_expiring","in_ms":30000}` 30 s before stop so a client
  can reconnect without a gap in liveness.
- MP-N2 device bearers: C7-T05 adds the revocation-driven stop; this
  ticket's token endpoint is under `:dashboard_auth_required`, which
  MP-N2-C6 extends to device bearers.

### Live path

- **Append notification (C6-T02 requirement):** after each successful
  append the exporter does
  `Phoenix.PubSub.local_broadcast(Aiur.PubSub, "events:export", {:export_appended, head_seq, epoch})`.
  Per contract R-2 this is an invalidation with a version (`head_seq`), not
  data; the channel reads the records from the journal through
  `Aiur.Events.Export.read/3`. One reader of truth, no second serializer.
- **Join** `"events:feed"` payload `{"after": int | null, "topics": [..], "epoch": str | null}`:
  1. export disabled → `{:error, %{reason: "feature_disabled"}}`;
  2. validate like C7-T01 (`invalid_cursor`, `topic_not_exported`) → join error;
  3. subscribe to `events:export` **before** reading the backlog (so no
     append between read and subscribe is lost — the ExecutorListener
     "subscribe first, then replay" order, contract §7.1);
  4. read from `after` in pages of 500 and push each record as
     `"record"`; `reset` is pushed alone and the channel then continues
     from `head_seq` (client re-snapshots);
  5. remember `last_pushed_seq`; on `{:export_appended, head, _}` read
     `(last_pushed_seq, head]` and push; duplicates impossible because the
     read is by `seq > last_pushed_seq`.
- **Heartbeat:** `Process.send_after(self(), :heartbeat, 25_000)` →
  push `"heartbeat"` `{"head_seq", "observed_at"}`. 25 s keeps the
  WebSocket under common 30–60 s idle proxy timeouts; the client marks
  stale on missing heartbeats, never on event silence (plan §7).
- **Back-pressure:** if a single append notification reveals more than
  2 000 unread records (slow client), push one `reset` and continue from
  `head_seq`; the client re-snapshots instead of the server buffering.

## Implementation steps

1. `EventsAuth` (copy of `StreamdeckAuth` with salt `"events-v1"`; share
   the `secure_equal?/2` helper by extracting it only if both files would
   otherwise duplicate it verbatim — acceptable either way, ≤ 10 lines).
2. `EventsSessionController.create/2` and route
   `post("/api/v1/events/token", EventsSessionController, :create)` in the
   `:dashboard_auth_required` scope (`router.ex:180-184`); disabled export
   → 404 `feature_disabled`.
3. `EventsSocket` (connect/id like `StreamdeckSocket`), endpoint
   `socket("/events", AiurWeb.EventsSocket, websocket: true, longpoll: false)`.
4. `EventsChannel` per the live path; uses C7-T01's parser module.
5. C6-T02 append notification (if C6 is already merged without it, add the
   one `local_broadcast` line to the exporter in this PR and a test).

## Non-happy paths

- **Credential change / expiry:** channel stops (`{:stop, :normal, _}`), as
  Stream Deck; client gets a socket close and reconnects with a new token.
- **Exporter crash / corrupt journal:** read returns
  `{:error, :events_unavailable}` → push `{"type":"error","code":"events_unavailable"}`
  and stop; the C6 alert already fired.
- **Exporter restart:** its boot `gap` record arrives like any record.
- **Multiple devices:** each socket has its own `last_pushed_seq`; no
  per-device server state survives the socket.
- **Disabled while connected:** the exporter stops → no notifications; the
  channel's next heartbeat read sees `enabled? == false` → pushes
  `feature_disabled` error and stops.
- **PubSub down:** cannot happen while the endpoint runs (PubSub starts at
  boot, `aiur.ex:302`); not handled separately.

## Compatibility and rollout

New socket path `/events` and route; both inert while
`events.export.enabled: false` (token endpoint 404, join refused). MP-R3 bind
rules apply unchanged (loopback by default). Rollback: revert.

## Verification

`events_channel_test.exs` (temp runtime dir, fixture journal through C6's
writer, credentials configured as in `streamdeck_channel_test.exs`):

1. `"only a valid events token connects"` — no token / garbage token /
   a Stream Deck token (different salt) → `:error`. Fails if the salt is
   shared (Stream Deck token accepted).
2. `"join replays records after the cursor, then live"` — fixture 1..5,
   join `after: 3` → `"record"` pushes seq 4, 5; append seq 6 via the
   exporter → push seq 6. Fails if subscribe happens after the backlog read
   (inject an append between read and subscribe with a test hook in the
   fake reader → seq lost).
3. `"stale cursor gets one reset"` — oldest 50, `after: 3` → exactly one
   `reset` push, then live.
4. `"heartbeat carries head_seq every 25 s"` — `send(channel_pid, :heartbeat)`
   → `"heartbeat"` with `head_seq: 5`.
5. `"channel stops when the token expires"` — token with
   `expires_at_ms` = now + 50 ms (test-only issue helper) → channel exits
   `:normal`. Fails if the expiry timer is not scheduled.
6. `"channel stops when dashboard credentials change"` — mirror
   `streamdeck_channel_test.exs:153` → exits.
7. `"disabled export refuses join and token issuance"`.
8. `"a slow client gets reset instead of an unbounded backlog"` — append
   2 001 records before the notification → one `reset`.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur_web/events_channel_test.exs test/aiur_web/streamdeck_channel_test.exs \
  test/aiur_web/controllers/events_controller_test.exs
```

Mutation check: remove the expiry `send_after` → test 5 fails; read
backlog before subscribing → test 2 fails; reuse `"streamdeck-v1"` →
test 1 fails.

Manual: `scripts/aiurdev --test` with export enabled; connect with
`websocat "ws://127.0.0.1:<port>/events/websocket?token=<token>&vsn=2.0.0"`
and send the Phoenix join frame for `events:feed`; observe backlog, a live
record when an agent emits progress, a heartbeat within 25 s, and a close
at 300 s. Record the transcript in the PR.

## Completion and handoff

- [ ] Tests 1–8 added and mutation-checked; Stream Deck tests unchanged.
- [ ] Docs: extend the "External event feed" section in
      `website/docs-app/concepts/message-bus.md` (C7-T01) with the socket,
      token lifetime (300 s), heartbeat and reconnect rule.
- Dependents: C7-T05 (device revocation closes these channels), MP-N3,
  MP-N6-C6-T01, MP-N1 foreground clients.
