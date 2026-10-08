---
ticket_id: MP-E5-C8-T01
feature_id: MP-E5
chunk_id: MP-E5-C8
bucket: 2-platform
title: Device voice ticket endpoint and /voice/device socket for paired phones and watches (RC-16)
status: ready
blocked_by: ["DESIGN-E5 (waived for this ticket: no dashboard UI; native UI is DESIGN-N6/N7)", MP-E5-C2-T01, MP-N2-C1-T03, MP-N2-C6-T01, MP-N2-C6-T03]
wave: 5  # RC-29: needs MP-N2 device auth
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-08, integrations-51]
prior_findings: []
size_owner: WEB (router.ex, endpoint.ex; new modules are small)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C8-T01 — Device-authenticated voice entry point

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C8 device-authenticated voice path
  (new chunk added in Phase C for reconciliation RC-16).
- **User value:** a paired phone or watch can dictate or converse through the same daemon
  voice service as the dashboard, without a dashboard password, CSRF token or browser
  cookie, and without ever holding the ElevenLabs key (V4).
- **Deliverable (contract §3.5 steps 1–2, 4–6):**
  1. `POST /api/v1/device/voice-ticket` → `AiurWeb.DeviceVoiceTicketController.create/2`
     (PROPOSED) returning `{ticket, expires_in_seconds: 60}`.
  2. `AiurWeb.DeviceVoiceTicket` (PROPOSED) — `issue(device_id)` / `verify(ticket)` over
     `Phoenix.Token`, salt `"device-voice-v1"`, `max_age: 60`.
  3. `AiurWeb.DeviceVoiceSocket` (PROPOSED) mounted at `/voice/device` in `endpoint.ex`,
     serving `voice:dictate` (→ `AiurWeb.VoiceChannel`) and, once MP-E6-C7-T01 lands,
     `voice:converse` (→ `AiurWeb.VoiceConverseChannel`).
  4. `VoiceChannel.join/3` accepts `voice_authority = %{kind: :device, device_id}` and uses
     `"device:" <> device_id` as the limiter authority.
- **Non-goals:** periodic revocation re-check and auth-change stop (MP-E5-C8-T02); any
  native UI; the transport-security choice (RQ-TRANSPORT, MP-N2).

## Dependencies and blockers

- **Predecessors:** MP-E5-C2-T01 (dictate topic + target validation); MP-N2-C1-T03
  (`Machine.Store.verify_token/1` and device rows); MP-N2-C6-T01 (`AiurWeb.DeviceAuth` plug).
- **Contract requests (MP-N2, `CONTRACT-REQUESTS.md` R-2, R-3), resolved in Phase D:** the
  `:device_auth` pipeline (MP-N2-C6-T01) sets `conn.assigns.device_id` (one name for every
  consumer, with MP-N5/MP-N6; R-2 modified); the store exposes
  `Machine.Store.device_active?(device_id) :: boolean` (MP-N2-C1-T03, mtime-cached, fail
  closed). Joins made with the phone's device credential may carry
  `client.kind: "watch"` (voice-session §3.5 item 5; attribution only).
- **Consumers:** MP-N6-C4-T02/T03, MP-N7 voice relay.
- **May run concurrently with:** MP-E5-C3..C6 (different files).

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Browser socket needs cookie + CSRF | `voice_socket.ex:21-35` |
| Endpoint sockets | `endpoint.ex:14-29` (`/live`, `/streamdeck`, `/voice` with `max_frame_size: 400_000`) |
| Precedent: ticket then socket | `POST /api/v1/streamdeck/token` (`router.ex:180-184`, `:dashboard_auth_required`) → `StreamdeckSessionController.create/2` (`controllers/streamdeck_session_controller.ex:9-14`) → `StreamdeckAuth.issue_token/0` / `verify_token/1` with `Phoenix.Token`, salt `"streamdeck-v1"`, max age 300 s, secure compare (`streamdeck_auth.ex:7-45`) → `StreamdeckSocket.connect/3` (`streamdeck_socket.ex:11-23`) |
| Write gates | `:api_write` (`router.ex:50-53`), `:require_writable` (`:60-62`) |
| Limiter | `VoiceSessionLimiter.acquire(authority, owner)` takes any binary authority (`voice_session_limiter.ex:22-25`); caps 2 per authority, 8 global (`:12-13`) |
| Channel authority today | `voice_authority: %{configuration_generation, connection_generation}` (`voice_channel.ex:37-45`); FinancialDataAccess generation check (`:47-51`) |
| Endpoint `check_origin: false` | `src/config/config.exs:17` — native WebSocket clients are not origin-checked |

## Chosen design

- **Route.** A new scope in `router.ex`, placed before the `/api/v1/:issue_identifier`
  catch-alls (`:186-199`):

```elixir
scope "/", AiurWeb do
  pipe_through([:device_auth, :device_write, :require_writable])   # MP-N2-C6-T01 / C6-T03 pipelines
  post("/api/v1/device/voice-ticket", DeviceVoiceTicketController, :create)
  match(:*, "/api/v1/device/voice-ticket", ObservabilityApiController, :method_not_allowed)
end
```

  Device auth uses a bearer header, not a cookie, so the CSRF-oriented `:api_write`
  pipeline (`router.ex:41-53`, Origin + `X-Aiur-Request`) does not apply; a cross-site page
  cannot read or set an `Authorization` bearer without a CORS grant, which aiur never
  enables (`router.ex:47-49`).
- **Ticket.** `Phoenix.Token.sign(AiurWeb.Endpoint, "device-voice-v1", %{device_id: id,
  expires_at_ms: now + 60_000})`; verification also checks `expires_at_ms` and
  `device_active?/1` (as `streamdeck_auth.ex:24-34` re-checks the generation).
- **Single use (Phase D, security m7; voice-session §3.5 item 1).** New
  `AiurWeb.DeviceVoiceTicket.Used` (an ETS table owned by a small GenServer started next to the
  endpoint): `connect/3` calls `claim(sha256(ticket), expires_at_ms)` after `verify/1`; a
  second claim of the same hash before expiry returns `:already_used` and `connect` returns
  `:error` (the client reads it as `ticket_used`, §8.1: fetch a new ticket silently). Expired
  hashes are swept every 60 s. Atomicity: `:ets.insert_new/2`. A daemon restart empties the
  table, which is safe because the 60 s ticket life outlasts no restart that a client could
  exploit without also holding a valid bearer.
- **Socket.**

```elixir
def connect(%{"ticket" => t}, socket, _info) do
  with true <- AiurWeb.Endpoint.config(:dashboard_writable) == true,
       {:ok, device_id} <- AiurWeb.DeviceVoiceTicket.verify(t) do
    {:ok, assign(socket, :voice_authority, %{kind: :device, device_id: device_id})}
  else
    _ -> :error
  end
end
```

  Mounted with `websocket: [max_frame_size: 400_000], longpoll: false` and **no**
  `connect_info: [session: …]` (no cookie).
- **Channel.** `VoiceChannel.join/3` gets a second clause for `%{kind: :device}` that skips
  the FinancialDataAccess generation steps and acquires the lease with
  `"device:" <> device_id`. The legacy topics `voice:dictation` and `voice:conversation` are
  refused on this socket (`invalid_payload`): the device socket only routes `voice:dictate`
  (and later `voice:converse`).
- **Logging.** Log only `device_id` and the outcome. Add `"ticket"` to the socket's logged
  params filter: `Phoenix.Logger` filters connect params by the `:filter_parameters` config,
  which this repo does not set (`config/config.exs` has none) — set
  `config :phoenix, :filter_parameters, ["password", "ticket", "token"]` (Phoenix's default
  list is `["password"]`; <https://hexdocs.pm/phoenix/Phoenix.Logger.html>, accessed
  2026-10-06).

## Implementation steps

1. `device_voice_ticket.ex`, `device_voice_ticket_controller.ex`, `device_voice_socket.ex`.
2. `endpoint.ex`: `socket("/voice/device", AiurWeb.DeviceVoiceSocket, websocket:
   [max_frame_size: 400_000], longpoll: false)`.
3. `router.ex`: the scope above.
4. `voice_channel.ex`: device authority clause; refuse legacy topics for devices.
5. `config.exs`: `:filter_parameters`.
6. Tests below.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Mobile disabled / no machine store | the `:device_auth` pipeline returns `401 device_auth_disabled` (pairing contract §4.4) |
| Revoked or expired device token | `401` from the plug; no ticket |
| Read-only dashboard | `:require_writable` → today's refusal; socket `connect` also refuses |
| Ticket older than 60 s, or tampered | socket `connect` → `:error` (client re-requests a ticket) |
| Device revoked between ticket and connect | `device_active?/1` false → `:error` |
| Third concurrent session for one device | join `{:error, %{reason_code: "capacity"}}` |
| Store unreadable | fail closed (`connect` → `:error`); Basic Auth paths unaffected (pairing contract §9) |
| Privacy | the key never leaves the daemon; the ticket carries no access token; logs carry `device_id` only |

## Compatibility and rollout

- Additive: a new route and socket. Without MP-N2 enabled every call is `401` and nothing
  else changes. No config key. Rollback: revert.
- Packaging: none (daemon only). Native clients consume it in MP-N6/N7.

## Verification

| Test (PROPOSED: `test/aiur_web/device_voice_test.exs`) | Expected |
| --- | --- |
| "a paired device gets a 60-second voice ticket" | `POST` with a valid bearer (store fixture in a temp XDG dir) → 200, `expires_in_seconds: 60`, ticket verifies to the device id |
| "a revoked device gets no ticket" | revoked row → 401 |
| "a read-only dashboard refuses the ticket and the socket" | `dashboard_writable: false` → 403 and `connect` `:error` |
| "an expired ticket cannot connect" | ticket signed with `expires_at_ms` in the past → `:error` |
| "a device revoked after issue cannot connect" | revoke between issue and connect → `:error` |
| "a device dictation joins voice:dictate and streams transcripts" | fake transcriber; `transcript` push received |
| "the device socket refuses legacy topics" | `voice:conversation` join → `invalid_payload` |
| "device sessions are capped per device, not per dashboard" | two joins OK, third `capacity`; a dashboard session still joins |
| "the ticket never appears in logs" | `capture_log` around connect contains the device id and not the ticket string |
| "second connect with the same ticket is refused" | first `connect` ok; second with the same ticket → `:error`; a fresh ticket connects |
| "two concurrent connects with one ticket: exactly one succeeds" | two tasks race `connect`; one `{:ok, _}`, one `:error` |

```bash
env -C src mise exec -- mix test test/aiur_web/device_voice_test.exs test/aiur_web/voice_channel_test.exs
make -C src fmt-check lint
```

Tests use a temp `XDG_CONFIG_HOME` for the machine store (AGENTS.md "reading real state").
Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation checks.** Drop the `device_active?/1` check from `verify/1`: "revoked after
issue" fails. Use the dashboard authority string for devices: "capped per device" fails.
Remove `"ticket"` from `:filter_parameters`: the log test fails. Skip the `claim/2` call:
"second connect with the same ticket is refused" fails. Use `:ets.insert/2` instead of
`insert_new/2`: the race test fails.

Device test: with MP-N6's build, dictate from a physical phone over the tailnet and confirm
the transcript arrives (recorded in MP-N6's device validation).

## Completion and handoff

- [ ] Endpoint, socket, channel clause, log filter; tests green.
- [ ] Docs: `website/docs-app/apis/elevenlabs.md` "What voice does" table gains a "Paired
      phone or watch" row (the daemon still makes every ElevenLabs call); the device API
      itself is documented by MP-N2's API page.
- **Dependents:** MP-E5-C8-T02, MP-N6-C4-T02/T03, MP-N7. (MP-E6-C7-T01 is no longer a
  dependent: RC-30 removed that edge; dashboard Converse uses the browser voice path. When
  both exist, C7-T01's `voice:converse` channel is also routed on `/voice/device`.)
