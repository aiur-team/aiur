---
ticket_id: MP-E5-C6-T01
feature_id: MP-E5
chunk_id: MP-E5-C6
bucket: 2-platform
title: Voice input state machine, approved status copy and the unavailable presentation
status: blocked
blocked_by: [DESIGN-E5, E5-OQ4, MP-E5-C3-T01, MP-E5-C2-T01, MP-E5-C2-T03]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07]
prior_findings: []
size_owner: BROWSER (conversation-voice-controller.js after the C1-T02 split)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C6-T01 — States and copy

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C6 states, cancel, errors, delivery.
- **User value:** at every moment the operator can see what the mic is doing and why it is
  not available, in approved words, and typing always still works.
- **Deliverable:** an explicit state machine in the controller replacing today's boolean
  flags for the dictate path, one status line per state using the DESIGN-E5 §4–§5 copy, and
  the E5-OQ4 unavailable presentation driven by `voice.stt` (C2-T03) and `reason_code`
  (C2-T01).
- **Non-goals:** Cancel control (C6-T02); delivery states (C6-T03); converse states (MP-E6).

## Dependencies and blockers

- **Owner:** DESIGN-E5 (§4 states, §5 copy), E5-OQ4 (hide vs disabled-with-reason).
- **Predecessors:** C3-T01, C2-T01, C2-T03.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Flags today | `starting`, `recording`, `finishing`, `awaitingReply`, `speaking`, `conversationActive`, `unavailableReason` (`conversation-voice-controller.js:69-102,134-189`) |
| Copy today | "Requesting microphone permission…" (`:142`), "Listening… press the microphone again when you are finished." (`:173`), "Finishing transcription…" (`:264`), "Dictation ready. Review the text, then press Send." (`:232,351`), timeout (`:270`), permission/no-device (`:446-454`), insecure origin and no Web Audio (`:18-22`), transport loss (`:249-250`) |
| Unavailable today | only discovered at join (`voice_channel.ex:253-254`) |

## Chosen design

States (DESIGN-E5 §4) and transitions for `dictate`:

| State | Entered by | Left by | Controls |
| --- | --- | --- | --- |
| `unavailable{reason}` | mount with `voice.stt` ≠ available; insecure origin; no Web Audio | capability refresh to available | Dictate disabled (or hidden per E5-OQ4); typing enabled |
| `idle` | mount; after `ready`/`cancelled`/`error` | choice click | D16 choice enabled |
| `requesting_permission` | Dictate click | permission granted → `listening`; denied → `permission_denied` | none |
| `permission_denied` | `NotAllowedError`/`SecurityError` | choice click (retry) | choice enabled |
| `no_device` | `NotFoundError` | choice click | choice enabled |
| `listening` | channel joined and capture started | Stop → `finishing`; Cancel → `cancelled`; error | Stop, Cancel; field read-only |
| `finishing` | Stop | `stopped` → `ready`; 5 s timeout → `error{transport_lost}` | none |
| `ready` | `stopped` | edit/Send/choice | field editable; Send enabled |
| `cancelled` | Cancel (C6-T02) | immediate → `idle` | — |
| `error{reason_code}` | channel `error`, join refusal, transport loss | choice click | text so far kept |

- The state is reflected as `data-voice-state` on the component root (tests and CSS hook on
  it) and as the status line text.
- `reason_code` → copy is one table in the controller keyed by the contract §8 codes;
  unknown codes render the `unknown` copy (never a specific cause).
- E5-OQ4 (recommended): `not_configured` → disabled with reason + link to setup docs
  (`/apis/elevenlabs#configure-the-key`); `not_installed` → hidden; `disabled` (read-only)
  → the composer is not rendered at all (unchanged, `conversation_drawer.ex:167`).

## Implementation steps

1. Introduce `this.state` and a `transition(next, detail)` function; derive the old booleans
   from it for the legacy conversation path until C3-T03 removes it.
2. Copy table from DESIGN-E5; status line set only by `transition`.
3. Server-rendered unavailable state in `<.voice_input>` from `@capabilities["voice.stt"]`.
4. Docs: `concepts/units.md` voice section lists the states a user sees and the unavailable
   reasons; `apis/elevenlabs.md` "Configure the key" anchor target.

## Non-happy paths

All rows above; plus: capability changes from available to unavailable while `listening` —
the session continues (server is authoritative); the next activation shows unavailable.

## Compatibility and rollout

Copy changes are visible; ship only with DESIGN-E5 approval. Rollback: revert.

## Verification

| Test (browser, fake channel) | Expected |
| --- | --- |
| "steps through every dictate state" | scripted fake: click → permission → listening → stop → finishing → stopped → ready; `data-voice-state` and status text match the copy table at each step |
| "a join refusal shows its reason_code copy and keeps typed text" | refusal `target_stale` → `error` state, field text unchanged |
| "an unknown reason_code shows the unknown copy" | refusal `zzz` → unknown copy, not any specific cause |
| "voice.stt not_configured renders disabled with the setup link" (LiveView) | per E5-OQ4 |
| "voice.stt not_installed renders no voice controls" (LiveView, if E5-OQ4 = hide) | absent |
| "typing and Send work when voice is unavailable" (LiveView) | `send-operator-message` delivered with the key unset |

```bash
env -C src/browser npm run test:units
env -C src mise exec -- mix test test/aiur_web/components/voice_input_test.exs test/aiur_web/operator_control_center/conversation_drawer_test.exs
make -C src fmt-check lint
```

Run Elixir tests in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and
hash-check `~/.aiur/github-budget/agent-token` before and after.

**Mutation checks (AGENTS.md unknown-path rule).** Replace the `unavailable` branch of
`<.voice_input>` with the `available` markup: the not_configured LiveView test fails. Replace
the unknown-code copy with the `provider_unavailable` copy: the unknown test fails.

## Completion and handoff

- [ ] State machine, copy table, unavailable presentation; tests green; docs in PR.
- **Dependents:** MP-E5-C6-T02, MP-E5-C6-T03; DESIGN-N6/N7 reuse the state list.
