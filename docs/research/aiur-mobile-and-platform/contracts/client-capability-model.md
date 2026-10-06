---
contract_id: MP-CT-client-capability-model
owner_feature: MP-N1
status: reconciled (Phase C, 2026-10-06): RC-02, RC-04, RC-15 applied
base_main_sha: 45a290e3
date: 2026-10-06
consumes: [MP-CT-identity-and-capabilities (MP-R1), pairing credentials (MP-N2), command-request-and-resolution (MP-E2), events external API (MP-R2)]
consumers: [MP-N1, MP-N3, MP-N5, MP-N6, MP-N7; recommended for dashboard JS and MP-R6 Stream Deck]
---

# Contract: client capability model

How a client finds out what it can do for a given machine and instance, and how it
degrades when something is missing, stale or unreachable. The server side (what the
daemon reports) is owned by MP-R1 in
[identity-and-capabilities.md](identity-and-capabilities.md). This contract is the
**client side**: inputs, resolution rules, states, refresh, and what each UI
affordance requires.

Nothing here exists in code at `45a290e3`. Today clients infer availability from
missing JSON fields and channel join errors (baseline R1; `voice_channel.ex:253-254`).
The one explicit availability projection is `StreamdeckProjection.voice/0`
(`src/lib/aiur_web/streamdeck_projection.ex:34-38`, `%{available, reason}`), which this
model generalises.

## 1. Assumptions about MP-R1's contract (reconcile)

| # | Assumption | Status in the MP-R1 draft |
|---|---|---|
| C-A1 | `GET /api/v1/capabilities` returns `contract_version`, `revision`, `observed_at`, `age_ms`, `freshness`, and a `capabilities` map of `{state, reason?, version?, depends_on?}` | Matches §2.2 |
| C-A2 | `state ∈ {available, degraded, unavailable, unknown}`; reasons as listed | Matches §2.2 |
| C-A3 | A paired-device credential is accepted on that endpoint | Stated as an assumption to MP-N2 in §5 |
| C-A4 | `system.capabilities.changed` carries the new `revision` | Matches §2.1 |
| C-A5 | **Proposed addition:** a `boot_id` (random per daemon start) so a client can tell "same revision after restart" from "unchanged". MP-R1 §4 "Restart" leaves the choice between a persisted counter and a `boot_id` to Phase C. This contract works with either, but needs one. | **Accepted by RC-04**: MP-R1 adds `boot_id` to the report |
| C-A6 | **Proposed addition:** `min_client_version` per client kind (`phone`, `watch`) at top level, absent = no minimum | **Accepted by RC-04**: MP-R1 adds `min_client_version` |
| C-A7 | Write endpoints return a typed error naming the capability: `{error: "capability_unavailable", capability, state, reason}` | §3 rule 6 says "a typed error that names the capability"; shape proposed here; **accepted by RC-04** as MP-R1's typed error |

## 2. Inputs

A client resolves each **affordance** (a thing the user can see or do) from five inputs:

| Input | Source | Examples |
|---|---|---|
| I1 Server capability | The capability report (MP-R1) | `commands.answer: available`; `voice.stt: unavailable/not_configured` |
| I2 Reachability | The client's last fetch outcome | `reachable`, `unreachable{since}`, `transport_error{kind}` with `kind ∈ {tls_untrusted, tls_name_mismatch, tls_pin_mismatch, cleartext_blocked, timeout, refused, unknown}`; plus the transport mode `https` or `http_degraded` (RQ-TRANSPORT, `pairing-and-instance-registry.md` §8.1) |
| I3 Authorization | Pairing state (MP-N2) | `paired`, `revoked`, `session_expired` |
| I4 Local platform | OS permissions and device state | notification permission, mic permission, camera, watch paired and reachable, push token present |
| I5 Client support | The client build | the client implements `voice.conversation` or not; contract versions it understands |

## 3. Affordance states

| State | Meaning | Rendering rule |
|---|---|---|
| `ready` | Every requirement is met and data is fresh | Normal control |
| `degraded` | It works, with a stated limitation (server `degraded`, or a fallback path in use) | Control works; a qualifier is visible (for example "answers recorded, delivery pending") |
| `stale` | Last data is older than the freshness budget (§6), or the server says `freshness: stale` | Data shown with its age; writes allowed only where §5 says so |
| `unreachable` | No response from the instance or machine | Last data shown greyed with "last seen <age>"; writes disabled |
| `unavailable` | The server answered, and the capability is off | Absent, or shown disabled with the reason text. **Never rendered as 0 or as a working control.** |
| `needs_permission` | A local OS permission is missing | Disabled with a link to Settings |
| `needs_update` | Client or server version too old | Disabled with "Update the app" or "Update aiur on <machine>" |
| `revoked` | This device is no longer paired | The machine is removed from the UI after one notice |
| `unknown` | It cannot be classified (server `unknown`, unknown reason, or the ID is missing from an older server) | Shown as unknown, never as a specific cause (AGENTS.md "a collapsed cause names the collapse at the source") |

`unreachable`, `stale` and `unavailable` are always presented differently (brief N3).

## 4. Resolution precedence

Evaluate in order; the first match wins.

1. I3 `revoked` → `revoked` (for every affordance on that machine).
2. I3 `session_expired` → attempt one re-bootstrap; on failure → `unknown` with reason `auth`.
3. I2 `unreachable` → `unreachable`. I2 `transport_error` → `unreachable` carrying the `kind` (never collapsed into one cause; `unknown` when unclassified).
4. Server `contract_version` lower than the version that introduced the needed ID, or `min_client_version` above this client → `needs_update`.
5. Any required I1 capability `unavailable` → `unavailable` (carry its `reason`; if several, list all in `reasons` and show the first, AGENTS.md `reasons` pattern).
6. Any required I1 capability `unknown`, or an unknown `reason` → `unknown`.
7. I5 does not support the affordance → hidden (not `unavailable`: the server is not at fault).
8. Any required I4 permission missing → `needs_permission`.
9. Report age over budget, or `freshness: stale` → `stale`.
10. Any required I1 capability `degraded`, or an optional fallback in use → `degraded`.
11. Otherwise → `ready`.

## 5. Affordance requirements (v1)

Capability IDs are from MP-R1 capability-matrix.md §2. "Writes when stale" says
whether the action may be attempted in the `stale` state (the server re-checks every
write anyway, C-A7).

| Affordance | Required server capabilities | Optional (degrade if missing) | Local requirements | Writes when stale |
|---|---|---|---|---|
| Instance row in the meta-dashboard | `instance.status` | `build_orders.progress`, `executor.conversation` (background agents) | — | n/a |
| Commands-awaiting count | `commands.read` | — | — | n/a |
| Build-order % | `build_orders.progress` | — | — | n/a |
| Open instance dashboard (WebView) | `instance.status` + an established session | — | transport mode `https`, or `http_degraded` when the owner kept that mode (RQ-TRANSPORT; resolves to `degraded`) | n/a |
| Executor chat button | `executor.conversation` | — | — | n/a |
| Answer a Command (option or text) | `commands.answer` | — | — | **Yes**, with `expected_version`; the server rejects changed Commands |
| Send a message to an agent | `agents.message` | `listener_modes` (shows the delivery mode) | — | Yes |
| Mic → Dictate (server STT) | `voice.stt` | — | mic permission; transport mode `https` for WebView surfaces (`http_degraded` → `unavailable`, reason `insecure_context`) | Yes |
| Mic → Dictate (system recognizer, watch) | — (no server voice needed) | — | speech or dictation availability on the device | Yes |
| Mic → Converse | `voice.conversation` | `voice.tts` (spoken replies; text-only if missing → `degraded`) | mic permission | No: start requires `ready` or `degraded` |
| Receive push notifications | `push` | — | notification permission; push token | n/a |
| Build-order progress notifications (setting) | `push`, `build_orders.progress` | — | notification permission | n/a |
| PR-merge notifications (setting) | `push`, plus the event source MP-N5 names | — | notification permission | n/a |
| Watch: any server-backed action | the same as the phone affordance | — | watch reachable to phone (I4) | as the phone affordance |

Client-side reasons (added in Phase C, used with `unavailable`): `insecure_context` (the
WebView origin is HTTP-degraded, so `getUserMedia` cannot run) and `tls_websocket_untrusted`
(transport option T-B on iOS: WKWebView cannot apply a pinned trust to WebSockets, so `/voice`
cannot connect; MP-N2-C10-T04). They are client reasons, never sent by the server.

The Mic button itself is `ready` if **either** Dictate or Converse resolves to
`ready` or `degraded`. The choice sheet shows both options, each with its own state
(D16: the choice is always offered; an unavailable option is shown with its reason,
not removed silently).

## 6. Discovery and refresh

| Trigger | Action |
|---|---|
| Pairing completes | Fetch the machine's instance list (MP-N2), then each instance's report |
| App foreground | Refetch reports older than the budget |
| `system.capabilities.changed` (if `events.subscribe` is available) | Refetch that instance when `revision` differs |
| Reconnect after `unreachable` | Refetch before showing any write control as ready |
| Before a write | Use the cached state if younger than 10 s, else refetch (cheap GET) |
| A write returns `capability_unavailable` (C-A7) | Patch the cache from the error, re-render, then refetch |
| Polling fallback (no `events.subscribe`) | Every 30 s while foreground and visible; none in background |

**Freshness budget (proposed defaults; DESIGN-N3 may change the display, not the rule):**
a report is `stale` when the client-observed age exceeds 60 s in the foreground, or when
the server says `freshness: stale`. The client displays the server's `age_ms` plus its own
fetch age; it does not trust its own clock over the server's (MP-R1 §4 clock skew).

**Cache key:** `(machine_id, instance_id, boot_id, revision)` (`boot_id` per RC-04). A cache
from a previous `boot_id` is shown only as stale until refetched.

**Push-delivered hints** (a notification's capability-related fields) are never
authoritative. Opening a notification always refetches the Command and the report
before showing a write control as ready.

## 7. Watch projection

The watch never resolves capabilities. The phone resolves them and sends, in each
watch `snapshot` (MP-N7 §4):

```json
{ "as_of": "2026-10-06T16:00:00Z",
  "phone_reachable_to_machine": {"<machine_id>": "reachable|unreachable"},
  "instances": [
    { "instance_id": "…", "label": "aiur-team/aiur",
      "affordances": {
        "answer_command": {"state": "ready"},
        "mic_dictate_server": {"state": "unavailable", "reason": "not_configured"},
        "mic_dictate_system": {"state": "ready"},
        "mic_converse": {"state": "unknown"},
        "build_progress": {"state": "unavailable", "reason": "not_installed"} } } ] }
```

Affordance keys in the snapshot (v1): `answer_command`, `mic_dictate_server`,
`mic_dictate_system` (the watch's own system recognizer; needs no server voice, so the phone
sends `ready` unless the owner disabled it in DESIGN-N7 D-N7-2), `mic_converse`,
`build_progress`. The watch adds one local input: whether it can reach the phone now. If not, every
server-backed affordance renders as `unreachable` with "needs phone" and the snapshot's
age.

## 8. Failure and edge behaviour

| Case | Behaviour |
|---|---|
| Report endpoint missing (older daemon, 404) | All affordances `needs_update` ("Update aiur on <machine>"). Do not fall back to inference. |
| Report present, ID missing, `contract_version` ≥ the introducing version | `unavailable` with reason `unknown` (the server should list known-but-absent IDs; MP-R1 §2.4) |
| Capability flaps | Rendering is debounced (2 s); the cache is not |
| Multiple paired devices | Each device resolves independently; no cross-device capability sharing |
| Machine with many instances | Reports are fetched in parallel with a cap of 4 concurrent requests per machine |
| Restart mid-session | New `boot_id` → all cached data for that instance becomes stale until refetched |
| Privacy | Reports contain no secrets (MP-R1 §2.2). Clients log only capability IDs, states and reasons. |

## 9. Conformance

- Fixtures in `packages/aiur-mobile/fixtures/capability/`: one report per state and reason, plus older and newer `contract_version` cases.
- Each client implementation (TS phone, Swift and Kotlin brokers) runs the same fixture table: input report + I2..I5 → expected affordance states.
- Mutation guard: replacing the `unknown` or `unavailable` branch with `ready`, `0` or the last known value must fail at least one test (AGENTS.md "Tests must fail without the production change they guard").
- The dashboard JS and the Stream Deck sidecar may adopt this model; MP-R6 and the dashboard owners decide. This contract does not require them to.
