---
artifact_contract: ce-unified-plan/v1
artifact_readiness: tickets-written (Phase C, 2026-10-06; see tickets/README.md)
feature_id: MP-N6
bucket: 3 (mobile and watch)
base_main_sha: 45a290e3
date: 2026-10-06
depth: deep
owns_contracts: [] # co-authors destination resolution rules, contracts/notification-destination-and-payload.md §3.1
consumes_contracts: [command-request-and-resolution (MP-E2), conversations-transcripts-anchors (MP-E4), pairing-and-instance-registry (MP-N2), notification-destination-and-payload (MP-N4), voice-session (MP-E5/MP-R5/MP-E6), identity-and-capabilities (MP-R1)]
design_gate: DESIGN-N6 (links DESIGN-E2, DESIGN-E5; watch layout with DESIGN-N7)
blockers: [DESIGN-N6, DESIGN-E2 approval, DESIGN-E5 approval, MP-N1 framework, MP-N2 device auth, MP-E2 answer contract, MP-E4 anchors, RQ-TRANSPORT (RC-15), MP-E5 device voice path (RC-16)]
---

# MP-N6 — Contextual Command response on phone and watch

Chunks: [chunks.md](chunks.md). Owner gate: [DESIGN-N6](../../owner-design-tasks/DESIGN-N6.md).

---

## 1. Summary

Tapping a Command notification opens the app directly on that Command, on the right
machine and instance, with the requesting agent (worker or Executor) and the conversation
anchor in reach. The screen shows the explanation, 2–3 suggested responses with the
recommended one marked, a custom response field, and an explicit microphone button. The
mic is never active until the user presses it, and pressing it always offers **Dictate**
or **Converse** (D16). Submissions go over the device's private path with optimistic
concurrency; stale, resolved and duplicate submissions follow D11 (first answer wins; a
human supersedes an undelivered Executor answer).

## 2. Requirements

- N6-R1. Flow: notification → correct machine / instance / agent-or-Executor / Command
  context → explanation + suggested options → choose an option, type, or explicitly start
  the mic (brief N6).
- N6-R2. Never a generic inbox or unrelated chat as the landing view; degrade by level
  with a visible note (contract §3.1 rule 2).
- N6-R3. No auto-record on tap; no recording inside a notification banner.
- N6-R4. Mic → explicit Dictate / Converse choice, same on dashboard, phone and watch (D16).
  Raw audio never retained (D17).
- N6-R5. D11 semantics for every submission outcome; responses delivered to the
  requesting worker/session or to the Executor when it asked (D12), unchanged routing.
- N6-R6. Works from a phone with only the relevant components installed: `commands`,
  `pairing`, `push`; voice and conversations are optional and shown unavailable when absent.
- N6-R7. Watch: compact context, options, mic choice; no pause/resume/spawn (brief N7).

## 3. Repository findings (extends baseline N6)

| Finding | Evidence | Consequence |
| --- | --- | --- |
| Command carries everything the screen needs | `src/lib/aiur/decision.ex:20-40,124-135` (`question`, `context.short_summary/long_context_markdown`, `options`, `recommendation`, `consequence_of_delay`, `urgency`, `blocking`, `authority`) | no new Command fields for the screen; E2 adds routing state |
| Answers are recorded with actor identity; payload actor fields ignored | `decision_store.ex:183-193` (`answer/5`, "`opts[:actor]` is trusted runtime identity") | the device API passes `actor = {kind: :operator}` + `client.device_id` from the device token, never from the body (E2 contract §9) |
| Optimistic concurrency and idempotency exist | `decision_store.ex:253,276-277` (`expected_version`, `idempotency_key` replay), `:767-820` stale-version errors | phone retries reuse the same `idempotency_key`; stale views get a conflict |
| Dashboard answers via LiveView event, deck via channel with actor `streamdeck` | `aiur_web/operator_control_center/decision_events.ex:30`; `aiur_web/streamdeck_commands.ex:15-19,71` | a third surface with a per-device actor fits the existing pattern |
| Supervisor API is Executor-credentialed, not a human device API | `aiur_web/router.ex:79-95` (`:supervisor_auth`, bearer `AIUR_SUPERVISOR_TOKEN`) | phone must **not** reuse it; needs device-authenticated routes (MP-N2) |
| Deep-linkable web route exists | `router.ex:142-143` (`/commands/:decision_id`) | WebView fallback target if MP-N1 keeps this surface web |
| Voice is a Phoenix socket requiring CSRF + session | `aiur_web/endpoint.ex:26` (`/voice`); baseline N1 constraints | a device-authenticated voice path is an MP-E5/MP-N2 dependency |
| Delivery to the agent addresses the ticket, dispatch cap 7,800 chars | `decision_dispatch.ex:22,30` | not the client limit (see next row) |
| **Phase C:** the answer validator caps `custom_response` at 4,000 chars and reports a stale version as `{:stale_version, expected, current}` | `decision_answer.ex:15,55-59,158-159` | the phone counts against 4,000; the device API maps stale version to `409 stale_version` |

## 4. Proposed boundaries

| Component | Interface | Notes |
| --- | --- | --- |
| Device Command API (daemon, per instance; requires a device token, pairing contract §4.4; own router scope before the `/api/v1/:issue_identifier` catch-alls; answers also need `x-aiur-request: 1` and `:require_writable`, MP-N6-C1-T01) | `GET /api/v1/device/commands/:id` → Command view (E2 presentation fields, routing state, version, anchor ref, requester); `POST /api/v1/device/commands/:id/answer` `{expected_version, idempotency_key, option_id \| custom_text, via: "tap"\|"dictate"\|"converse"}`; `GET /api/v1/device/commands?state=needs_you` | thin adapter over the MP-E2 contract; device auth plug from MP-N2; `commands.answer` capability |
| Destination resolver (app) | `resolve(destination) -> Screen` | owns contract §3.1 rules; pure + testable |
| Command response screen (phone) | native or WebView per MP-N1/DESIGN-N1 | presentation normative in DESIGN-E2 §4 |
| Watch Command card | MP-N7 app | compact; hands off to phone for long context |
| Mic choice + voice clients | E5 dictation service, E6 conversation component | N6 only places the button and passes Command context |

Prior refs: Prior-boundaries `DEC` (#27), `WEB` (#34), `VOX` (#36); Prior-units none.

## 5. Flow

```mermaid
sequenceDiagram
  participant N as Notification (OS)
  participant A as App
  participant R as Pairing registry (device)
  participant D as aiur instance (private path)
  N->>A: tap (destination from decrypted payload; no mic)
  A->>R: machine_id paired? reachable URLs?
  alt not paired
    A-->>A: "Not paired with this machine"
  else paired
    A->>D: GET /device/commands/:id (device credential)
    alt unreachable
      A-->>A: sealed summary + "Can't reach <machine>" + Retry
    else 200
      D-->>A: Command view (version v, routing, options, anchor)
      A-->>A: render context, 2–3 options, custom, mic
      A->>D: POST answer {expected_version v, idempotency_key k, option}
      D-->>A: outcome (accepted | already_resolved | superseded_executor | stale | withdrawn)
    end
  end
```

### 5.1 Landing and switching into an existing conversation

- Cold start: show a neutral loading state, then the Command; never flash an inbox.
- App already open on the same instance: push the Command screen on top of the current
  stack; if the requester's conversation (MP-E4) is already the visible screen, scroll to
  the Command anchor and open the response sheet instead of stacking a duplicate (V-N2).
- "Open conversation" on the Command screen opens the MP-E4 transcript at `anchor_id`;
  without an anchor, at the end with a note "position unavailable". Executor-originated
  Commands open the Executor conversation (MP-E3) secondary view, never the landing view
  (brief §3: Executor chat is secondary).

### 5.2 Submission outcomes (D11)

Outcomes are those of [command-request-and-resolution.md](../../contracts/command-request-and-resolution.md)
§6 and §9 (HTTP 409 `decision_conflict` extended with the winning answer). The device API
passes them through; the app maps them to DESIGN-E2 §4.4 copy.

| Store result | Meaning | App behaviour |
| --- | --- | --- |
| `{:ok, …}` + `delivery_status` | first answer | "Answer recorded. Delivering to #123…" then live delivery state |
| `:duplicate` | same `idempotency_key`, same content (safe retry) | identical to the original outcome; no second answer |
| `{:conflict, {:idempotency_conflict, _}}` | same key, different content | client bug; show error, do not retry automatically |
| `{:conflict, {:already_decided, _}}` + winner summary | someone answered first | show who/when/what. If the winner is undelivered and not in flight, offer **Replace** (human supersede: D11 for an Executor answer, contract §6 rule 5 for another human). Otherwise "Send a follow-up message" link to the conversation |
| `{:conflict, :answer_in_flight}` | Replace raced with delivery start | "Delivering now — can't replace"; refresh |
| `{:conflict, :answer_delivered}` | delivered before Replace | as already decided, without Replace |
| stale version (409) | Command revised since view | reload view, keep the user's draft and selection if the option ids still exist |
| refusal for `expired`, `moot`, `resolved` | withdrawn | "No longer needed: <reason>"; form disabled |
| `401 device_revoked` / `device_auth_disabled` (pairing contract §4) | device unpaired or mobile off | "This phone is no longer paired with <machine>" → pairing screen; wipe cached data for that machine |
| network error | unknown whether recorded | retry with **the same** `idempotency_key`; never generate a new key for a retry |

Duplicate submissions (double tap, watch + phone) are absorbed by the idempotency key per
answer attempt (one key per user action, stored with the draft) and by first-answer-wins.
The recorded actor is `{kind: :operator}` with `client: {surface: "phone"|"watch",
device_id}` taken from the device token, never from the body.

### 5.3 Microphone

- The mic button is visible only when `voice.stt` (dictate) or `voice.conversation`
  (converse) is available on that instance; otherwise it is shown disabled with the
  reason (capability rule), never hidden silently if DESIGN-E5 prefers disabled.
- Press → choice sheet: **Dictate** (single response; transcript reviewed before Send,
  matching today's dashboard dictation, baseline fact 12) or **Converse** (MP-E6 session
  seeded with the Command context; its outcome becomes an answer only when the user
  confirms it in the same response form). Exact copy and the review rule are DESIGN-E5.
- Microphone OS permission is requested at first press, not at app start and not on
  notification tap. Denied → explain and link to OS settings; text options keep working.
- Cloud processing disclosure: when the instance's voice provider is ElevenLabs, the
  choice sheet states that audio goes to that provider (brief §7); push encryption is not
  presented as making voice local.

### 5.4 Watch (with MP-N7)

- Card: short label, requester, question (2 lines), up to 3 option buttons (recommended
  first), Mic (→ Dictate/Converse choice), "Open on phone".
- Long context, option details and Converse may hand off to the phone (MP-N7 decides
  what runs on the watch; Converse on watch is a research item there).
- Answers use the same API and outcomes; the watch shows a compact outcome line.
- Direct answers from a notification action button (without opening the app) are **not**
  in v1: they bypass the context screen the brief requires and their background-launch
  and locked-device behaviour must be validated first (E-A8, V-W4). Revisit after DESIGN-N6.

## 6. Non-happy paths

- **Stale notification:** destination resolves but the Command is terminal → resolved
  view, no form (V-N3).
- **Unknown Command id** (store purged, instance re-initialized) → instance view with
  "This Command is no longer available".
- **Wrong instance at that key** (repo mismatch) → "Instance changed" with link to
  MP-N2 discovery.
- **Multiple paired machines** → resolution by `machine_id` only; never by display name.
- **Offline / unreachable** → draft stays on device (text and selected option), Retry;
  answers are **not** queued for automatic later send in v1 (a queued answer could land
  after the situation changed; OQ-N6-1).
- **App-level auth (optional):** if DESIGN-N6 requires Face ID / device unlock before
  submitting from a locked state, the submit button triggers it; reading context does not.
- **Executor-first awareness:** a human answer from the phone is recorded on the same
  Command, so the Executor sees it through existing Command events and wakes; no extra
  message through the Executor conversation (brief E2: do not reroute human responses).

## 7. Alternatives considered

| Alternative | Why not |
| --- | --- |
| Reuse the dashboard `/commands/:id` page in a WebView with Basic Auth | Shared Basic Auth credentials on a phone contradict per-device authorization (MP-N2); LiveView + CSRF voice socket; acceptable only as a fallback if MP-N1 picks WebView for this surface with device-auth bridging |
| Reuse the supervisor API with a per-device token | That API's identity is the Executor (`supervisor_auth`); answers would be attributed to the wrong actor and blur D11 human-vs-Executor precedence |
| Answer from notification action buttons only | Skips required context; dynamic per-Command option labels need runtime category registration (unverified); locked-device behaviour unvalidated |
| Auto-open conversation instead of Command screen | Brief requires the Command context first; conversation is one tap away |

## 8. Acceptance criteria

1. AC-N6-1 Tapping a Command notification lands on that Command on the right
   machine/instance within one screen, from cold start and warm start (V-N1, V-N4).
2. AC-N6-2 The mic is inactive after tap; recording starts only after pressing Mic and
   choosing Dictate or Converse (UI test asserts no audio session before both actions).
3. AC-N6-3 Two devices answer concurrently: exactly one `accepted`, the other
   `already_resolved` naming the first (integration test against the E2 store).
4. AC-N6-4 Executor answered but undelivered: phone shows Replace; Replace supersedes and
   the worker receives only the human answer (V-M3).
5. AC-N6-5 Network failure after submit, retry: one answer recorded (same key).
6. AC-N6-6 Revoked device gets `revoked` and no Command data in the response body.
7. AC-N6-7 With voice absent, mic shows unavailable with reason; text answering works.
8. AC-N6-8 The device API never accepts an actor from the request body (test sends a
   forged actor and asserts the recorded actor is the device).

## 9. Open questions

**Owner (Kevin):** OQ-N6-1 queue offline answers for later send (proposal: no);
OQ-N6-2 require Face ID / unlock to submit (proposal: OS unlock only; no extra prompt);
OQ-N6-3 watch: allow Converse on the watch or hand off to phone (with DESIGN-N7);
OQ-N6-4 multi-question native Commands on a phone/watch (follows DESIGN-E2 §6.5).
**Research:** RQ-N6-1 (resolved by voice-session contract: device credential) native
on-device transcription via `client_text` on the watch, with MP-N7;
RQ-N6-2 runtime notification category registration for dynamic option buttons (only if
OQ revisits banner actions); RQ-N6-3 (resolved) outcome names follow the E2 contract §6.

## 10. Plan refresh

Router, `DecisionStore` and voice socket paths are pre-refactor. After MP-R1 (web-shell,
commands package) and MP-E2 land, MP-N6-C1-T00 maps the device API onto the post-refactor
web-shell and the E2 contract's answer function.

## 11. Phase C ticket map

[tickets/README.md](tickets/README.md): 20 tickets (7 ready, 13 blocked by design content
or owner/research items). Destinations carry `instance_id` (RC-02). Every phone → instance
call depends on RQ-TRANSPORT (RC-15); Dictate/Converse on the phone use the MP-E5 device
voice path (RC-16, voice-session §3.5). Live sync on an open screen polls every 10 s in
v1 (MP-N6-C6-T01); the paired-device event feed (MP-R2-C7-T05) is a later switch.
