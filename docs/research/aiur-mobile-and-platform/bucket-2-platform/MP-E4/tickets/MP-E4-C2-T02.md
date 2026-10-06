---
ticket_id: MP-E4-C2-T02
feature_id: MP-E4
chunk_id: MP-E4-C2
bucket: 2-platform
title: "Read-only JSON routes for conversations: entries, sessions, anchors, resolve"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C2-T01]
prior_units: [U8]
prior_boundaries: [WEB]
prior_features: [MP-R3 (bind and auth guards), MP-N2 (paired-device auth later)]
prior_findings: [contract conversations-transcripts-anchors §7, §12]
size_owner: "U8 WEB owner (router.ex 361 lines)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C2-T02 — Conversation JSON API

## Identity and outcome

- Bucket 2 · MP-E4 · C2 · T02.
- **User value:** scripts, the Executor and later the phone read a full
  conversation over the existing authenticated dashboard HTTP surface.
- **Deliverable:** `AiurWeb.ConversationApiController` and four GET routes,
  read-only, behind `:dashboard_auth`.
- **Non-goals:** any write route (sends stay on the listener path, contract §9);
  paired-device auth (MP-N2).

## Dependencies and blockers

- DESIGN-E4; MP-E4-C2-T01.
- Concurrent with: C3, C5-T01.

## Verified starting point

- Router scopes (`src/lib/aiur_web/router.ex`): the read scope
  `pipe_through(:dashboard_auth)` at `:186-199` holds
  `get("/api/v1/:issue_identifier/events", …)`, `get("/api/v1/:issue_identifier", …)`
  and the catch-all `match(:*, "/*path", …, :not_found)`. A literal
  `/api/v1/conversations` placed after it would be captured by
  `/api/v1/:issue_identifier` — the same ordering hazard the Decision routes
  document (`router.ex:77-80`).
- Response helpers and error shape: `ObservabilityApiController.events/2`
  (`controllers/observability_api_controller.ex:38-45`) with
  `error_response(conn, status, code, message)`.
- Route tests: `src/test/aiur_web/router_auth_test.exs`.

## Chosen design

New scope inserted **before** the read scope at `router.ex:186`:

```elixir
scope "/", AiurWeb do
  pipe_through(:dashboard_auth)
  get("/api/v1/conversations/resolve", ConversationApiController, :resolve)
  get("/api/v1/conversations/:conversation_id/entries", ConversationApiController, :entries)
  get("/api/v1/conversations/:conversation_id/sessions", ConversationApiController, :sessions)
  get("/api/v1/conversations/:conversation_id/anchors", ConversationApiController, :anchors)
  match(:*, "/api/v1/conversations/*path", ConversationApiController, :method_not_allowed_or_not_found)
end
```

| Route | Params | 200 body | Errors |
| --- | --- | --- | --- |
| `entries` | one of `tail`, `before`, `after`, `around`, `from_start`; `limit` 1..200; `kinds` comma list | `History.list_entries/2` page; entries JSON per contract §5 | 422 `invalid_cursor` / `invalid_limit`; 404 `conversation_not_found`; 503 `conversation_unavailable` |
| `sessions` | — | `{sessions: [...]}` (no raw paths; `locator_hash` only) | 404 / 503 |
| `anchors` | `kinds`, `pos_from`, `pos_to` | `{anchors: [...]}` strongest per event | 404 / 503 |
| `resolve` | `subject=executor`, or `subject=worker&owner=&repository=&identifier=` | `{conversation_id, subject}` | 404 `subject_not_found` (no conversation has that subject, or no Executor attached); 422 `invalid_subject` |

- `resolve` first tries the current units snapshot (the drawer's lookup for
  `/chat/:owner/:repository/:identifier`, `dashboard_live.ex:209-234`) and
  `Conversation.Ref.worker/1`; for a ticket no longer in the run it uses the
  `subject.json` index (`History.resolve_worker/3`, PROPOSED, an ETS cache
  filled on first call and updated by the writer at creation). It never
  derives an id from the display number alone. If two conversations claim the
  same display identifier (the issue was transferred), it returns 409
  `ambiguous_subject` with both ids.
- All responses carry `Cache-Control: no-store` (bodies may hold secrets,
  contract §12).
- No write verbs; a POST to these paths is 405 via the method catch-all.

## Implementation steps

1. Controller with `@spec` per action; param parsing into `History` options
   (strings → integers; reject negatives and non-integers).
2. Router scope above `router.ex:186`.
3. Docs: add "Read a conversation over HTTP" to `website/docs-app/guide/gui.md`
   (routes, cursors, auth, the secrets warning). AGENTS.md: a new user-facing
   surface ships its docs in the same PR.

## Non-happy paths

- **Auth:** same as every dashboard read (Basic Auth when configured;
  loopback rules unchanged). Read-only dashboards can read (D15: read stays
  available).
- **Route capture:** test that `GET /api/v1/conversations` is not answered by
  the issue controller.
- **Large pages:** 200 entries × 2 bounded fields (≤ 64 KiB each) caps a page
  near 26 MiB in the worst case. The contract limit stays; the bound that
  MP-E4-C1-T00 chooses sets the real worst case, and the PR body records it.
  The dashboard (C5) requests 50 per page.
- **Unknown conversation vs empty:** 404 vs `200` with `entries: []` and
  `head_pos: 0` — distinct, never collapsed (AGENTS.md "collapsed causes").

## Compatibility and rollout

- Additive routes. No config. Rollback: remove the scope.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/conversation_api_controller_test.exs test/aiur_web/router_auth_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "GET entries tail returns positions and cursors" | 200, ascending `pos`, `next_cursor: nil` | controller |
| "GET /api/v1/conversations/x/entries is not routed to the issue API" | `ConversationApiController` handles it | scope placed before `router.ex:186` |
| "two cursors → 422 invalid_cursor" | 422 | param validation |
| "unknown id → 404; known empty → 200 with head_pos 0" | distinct | the not_found/empty split |
| "POST entries → 405" | 405 | method catch-all |
| "requires dashboard auth when configured" (router_auth_test) | 401 without credentials | `:dashboard_auth` pipe |
| "resolve executor when none attached → 404 subject_not_found" | 404 | resolve branch |
| "response has Cache-Control: no-store" | header present | header line |

## Completion and handoff

- [ ] Routes, controller, tests; `make ci` green on the head SHA.
- [ ] `guide/gui.md` section merged in the same PR.
- Dependents: MP-N6 (phone), MP-E3-C6 (Executor resolve).
