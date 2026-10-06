---
ticket_id: MP-R2-C7-T01
feature_id: MP-R2
chunk_id: MP-R2-C7
bucket: 1 (Bucket-2-enabling, RC-09)
title: Pull API GET /api/v1/events and GET /api/v1/events/catalog over the export journal (off by default)
status: ready
blocked_by: [DESIGN-R2 §2, MP-R2-C6-T02, MP-R2-C6-T03, MP-R2-C5-T01, MP-R2-C5-T02]
prior_units: [U6, U8]
prior_boundaries: [BUS #10, WEB #34]
prior_features: [MP-R1 (web-shell, RC-12), MP-R3 (bind guards)]
prior_findings: [MP-R2 F4, RQ-7]
size_owner: router.ex (WEB; re-check at start per RC-23); new controller < 200 lines
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C7-T01 — Pull API for the export feed

## Identity and outcome

- **Bucket 1, MP-R2, chunk C7. Bucket-2-enabling (RC-09):** adds an API,
  disabled by default, scheduled just before its first consumer (MP-N4/N5
  daemon-side do not need it; MP-N3's stream switch and MP-N6-C6 do).
- **User value:** a remote client (phone, meta-dashboard) can resume the
  event feed after a disconnect with `after=<seq>` and learn when it must
  re-read snapshots (`reset`/`gap`), instead of polling every snapshot API.
- **Deliverable:** `AiurWeb.EventsController` with `index/2`
  (`GET /api/v1/events`) and `catalog/2` (`GET /api/v1/events/catalog`)
  inside the existing `:dashboard_auth` scope, declared before the
  `:issue_identifier` routes. Response shapes per contract §10.
- **Non-goals:** no write endpoint; no live push (C7-T02); no CLI (C7-T04);
  no device auth work (MP-N2-C6 makes device bearers valid on every
  `:dashboard_auth` route, so this route inherits it). The existing
  `GET /api/v1/:issue_identifier/events` (transcript feed, F4) is unchanged.

## Dependencies and blockers

- **DESIGN-R2 §2** (S4 reset rule; KQ-R2-3 identifiers-only content).
- **C6-T02/T03:** the journal, `export.meta.json` (`epoch`, `oldest_seq`,
  `head_seq`) and the read function below. **C5-T01/T02:** catalog entries
  and the external envelope (records are stored already serialized).
- Concurrent with C7-T03; C7-T02 and C7-T04 reuse this ticket's reader
  adapter, so land T01 first.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| `:dashboard_auth` scope with `/api/v1/state`, the transcript feed and the catch-alls | `src/lib/aiur_web/router.ex:186-199` |
| Shadowing: `get "/api/v1/:issue_identifier"` (`:193`) would match `/api/v1/events`; `/api/v1/events/catalog` would fall to `match :*, "/*path"` not_found (`:198`) | `router.ex:191-198` (RQ-7) |
| `:dashboard_auth` never passes an unauthenticated request: configured credentials must be proven; unconfigured → 401 challenge or 503 | `src/lib/aiur_web/financial_data_access.ex:50-84`; pipeline `router.ex:9-11,201-211` |
| Error JSON convention `{error: {code, message}}` | `src/lib/aiur_web/controllers/observability_api_controller.ex:153-157` |
| Existing transcript route (keep) returns `422 invalid_limit`, `503 events_unavailable` | `observability_api_controller.ex:37-45` |
| Controller test harness (Endpoint.call with basic-auth header) | `src/test/aiur_web/controllers/observability_api_controller_test.exs:47-80` |
| Device bearer accepted on every `:dashboard_auth` route (future) | `contracts/pairing-and-instance-registry.md` §4.4; MP-N2-C6-T1 |

PROPOSED: `src/lib/aiur_web/controllers/events_controller.ex`,
`src/test/aiur_web/controllers/events_controller_test.exs`.

## Chosen design

### Interface consumed from C6 (C6 tickets must expose exactly this)

```elixir
Aiur.Events.Export.enabled?() :: boolean()
Aiur.Events.Export.read(after_seq :: non_neg_integer(), limit :: 1..500, patterns :: [String.t()]) ::
  {:ok, %{epoch: String.t(), head_seq: integer(), oldest_seq: integer(), records: [map()]}}
  | {:reset, %{epoch: String.t(), head_seq: integer(), oldest_seq: integer()}}
  | {:error, :events_unavailable}
Aiur.Events.Catalog.exported() :: [%{pattern: String.t(), class: atom(), payload_version: pos_integer()}]
```

`read/3` returns records with `seq > after_seq` in `seq` order, already in
external-envelope form (C5-T02), including `gap` control records; it
filters `event` records by `patterns` but always keeps `gap` records.

### HTTP

| Request | Response |
| --- | --- |
| export disabled | `404 {"error":{"code":"feature_disabled","message":"event export is disabled (events.export.enabled: false)"}}` (DESIGN-R2 §3 wording) |
| `GET /api/v1/events?after=<seq>&limit=<n>&topics=<p1,p2>` | `200 {"instance": <instance_id or null>, "epoch", "head_seq", "oldest_seq", "records": [...]}` |
| `after` omitted | treated as `head_seq` (no backlog): the bootstrap rule (contract §7.2 step 1) is "note head_seq, read snapshots, then follow" |
| `after < oldest_seq - 1`, or `epoch` query param ≠ current epoch | `200` with `records: [{"type":"reset","oldest_seq":…,"head_seq":…}]` and nothing else (S4) |
| `limit` not an integer in 1..500 | `422 invalid_limit` (default 100) |
| `after` not a non-negative integer | `422 invalid_cursor` |
| `topics` contains a pattern that is not a subset of an exported catalog pattern, or is malformed per `Aiur.Events.Topic` | `422 topic_not_exported` (contract §10: filters only narrow) |
| journal corrupt / unreadable | `503 events_unavailable` |
| `GET /api/v1/events/catalog` | `200 {"v":1,"topics":[{"pattern","class","payload_version"}]}`; disabled → 404 `feature_disabled` |

- Pattern subset rule: a requested pattern is accepted iff every concrete
  topic it can match is matched by some exported pattern. Implemented
  conservatively: accept only if the requested pattern equals an exported
  pattern, or is the exported pattern with one or more `*`/`#` segments
  replaced by literals. Anything else → 422. (Precise and testable; no
  general pattern-containment algorithm.)
- `instance` comes from the C5-T04 provider; `null` until MP-R1-C2 ships
  (clients must treat `null` as "single instance on this connection").
- Method guard: `match(:*, "/api/v1/events", …, :method_not_allowed)` and
  the same for `/catalog`, mirroring `router.ex:192,195-197`.
- Response header `cache-control: no-store`.

### Router placement

Add, as the first lines of the `:dashboard_auth` scope at `router.ex:186-188`
(before `/api/v1/state` is fine; must be before `:191`):

```elixir
get("/api/v1/events", EventsController, :index)
get("/api/v1/events/catalog", EventsController, :catalog)
match(:*, "/api/v1/events", EventsController, :method_not_allowed)
match(:*, "/api/v1/events/catalog", EventsController, :method_not_allowed)
```

## Implementation steps

1. Confirm C6's `Aiur.Events.Export.read/3` and `enabled?/0` match the
   interface above; if names differ, adapt here, not in C6.
2. Add `EventsController` (param parsing, subset check, mapping table above).
3. Router lines above (4 lines; `router.ex` stays under its size ceiling).
4. Tests below.

## Non-happy paths

- **Capability absent:** disabled → 404 `feature_disabled`, never `200` with
  an empty list (an empty list would read as "nothing happened").
- **Stale data:** every 200 carries `head_seq`; clients judge freshness by
  response time (contract §7.2 step 5). No server-side "stale" here.
- **Daemon restart:** the exporter's boot `gap(scope:"*")` record is
  returned in order like any record; the client re-reads snapshots.
- **Epoch change (journal re-created):** `reset`.
- **Auth:** 401/503 from `:dashboard_auth` happen before the controller, so
  no event content is ever rendered unauthenticated (DESIGN-R2 §3
  "Permission denied").
- **Privacy:** records are allowlisted at export time (C5-T02); the
  controller never re-adds fields. The webhook pipeline is untouched.
- **Large backlog:** bounded by `limit ≤ 500`; client pages with `after`.
- **Concurrency:** read-only file reads; the reader must not hold the
  exporter's process (C6 owns read isolation).

## Compatibility and rollout

- Off by default (`events.export.enabled: false`, C6-T01). With it off, the
  only observable change is that `GET /api/v1/events` returns
  `404 feature_disabled` instead of the generic `404 not_found` it would
  return today via `/api/v1/:issue_identifier` lookup of issue "events"
  (`issue_not_found`). Both are 404s; document it.
- Rollback: revert; no state.

## Verification

Tests in `events_controller_test.exs` (temp `runtime_state_dir`, a fixture
journal written through C6's writer, Basic-Auth credentials set in env as
the existing controller test does):

1. `"returns 404 feature_disabled when export is off"` — fails if the
   disabled branch is removed (would 500 or 200).
2. `"GET /api/v1/events is not shadowed by the issue route"` — export on,
   returns 200 with `head_seq`; **fails if the routes are placed after
   `router.ex:193`** (would hit `issue/2` → 404 `issue_not_found`).
3. `"catalog route is reachable"` — 200 with the fixture catalog; fails if
   placed after `:198`.
4. `"resume returns exactly the records after seq"` — fixture seq 1..10,
   `after=4&limit=3` → seqs `[5,6,7]`, `head_seq: 10`.
5. `"a cursor older than retention returns one reset record"` — fixture
   oldest_seq 50, `after=3` → `records == [%{"type" => "reset", "oldest_seq" => 50, "head_seq" => _}]`.
   Mutation: return the backlog instead → fails.
6. `"gap records survive a topic filter"` — fixture has a gap at seq 6;
   `topics=ticket.*.pr.merged` keeps it.
7. `"a non-exported topic filter is 422"` — `topics=ticket.*.agent.custom.#`
   (not exported, C5-T01) → 422 `topic_not_exported`.
8. `"unauthenticated request gets no event content"` — wrong password →
   401, body contains no `"records"`.
9. `"limit outside 1..500 is 422"`.
10. `"corrupt journal is 503 events_unavailable"` — truncated fixture.
11. Existing `observability_api_controller_test.exs` "GET
    /api/v1/:issue_identifier/events returns a bounded durable feed"
    (`:324`) unchanged and green.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur_web/controllers/events_controller_test.exs \
  test/aiur_web/controllers/observability_api_controller_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check (clean worktree, `git status --porcelain` shows only the
reverted hunk): move the four router lines below `router.ex:193` → tests
2–3 fail; replace the reset branch with a backlog read → test 5 fails;
drop the subset check → test 7 fails.

Manual (AGENTS.md: an API is not the TUI, so this is an API check, not a
"manually tested" claim): with `events.export.enabled: true` in a
`scripts/aiurdev --test` run, `curl -u "$AIUR_DASHBOARD_USERNAME:$AIUR_DASHBOARD_PASSWORD"
http://127.0.0.1:<port>/api/v1/events?after=0` shows the boot `gap` and
live records as agents work.

## Completion and handoff

- [ ] Routes declared before `router.ex:191`; tests 1–10 added and mutation-checked.
- [ ] Docs (AGENTS.md "Docs ship with the change" — new user-facing API):
      add a "External event feed" section to
      `website/docs-app/concepts/message-bus.md` (request/response, reset,
      gap, auth, disabled behaviour), linking the config keys from C6-T01.
- [ ] `packages/aiur-contracts` (MP-R1-C3-T6) gains the response schema if
      that package exists when this lands; otherwise note it in C4-T04's
      plan refresh.
- Dependents: C7-T02 (shares the reader adapter), C7-T04 (CLI reads
  through the same function), MP-N3 stream switch, MP-N6-C6-T01.
