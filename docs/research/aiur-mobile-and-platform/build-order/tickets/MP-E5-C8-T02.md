---
ticket_id: MP-E5-C8-T02
feature_id: MP-E5
chunk_id: MP-E5-C8
bucket: 2-platform
title: End device voice sessions on revocation or unpair-all within 15 seconds
status: ready
blocked_by: ["DESIGN-E5 (waived for this ticket: backend)", MP-E5-C8-T01, MP-N2-C7-T01]
wave: 5  # RC-29: needs MP-N2 device auth
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-08]
prior_findings: []
size_owner: WEB (voice_channel.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C8-T02 — Device voice session lifetime

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C8.
- **User value:** "remote unpair-all" (D19, pairing contract §4.5) really cuts a lost phone
  off — including a microphone session it already had open — within a bounded time.
- **Deliverable (contract §3.5 step 3):** while a device-authority channel is joined, the
  channel re-checks `device_active?/1` every 15 s and on every `stop`/`end`; a revoked device
  gets `error{reason_code: "auth_changed"}` and the channel stops, which (through the existing
  `terminate/2`) stops the transcriber and releases the lease.
- **Non-goals:** pushing revocation events (polling is enough at 15 s; the store is a file);
  the dashboard path (it already stops on credential rotation, `voice_channel.ex:184-191`).

## Dependencies and blockers

- **Predecessors:** MP-E5-C8-T01; MP-N2-C7-T01 (revoke writes the store).
- **May run concurrently with:** everything outside `voice_channel.ex`.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Dashboard precedent | `{FinancialDataAccess, :configuration_changed, generation}` stops the channel when the generation differs (`voice_channel.ex:184-191`); test `voice_channel_test.exs:405` |
| Cleanup on stop | `terminate/2` stops STT, kills TTS, releases the lease (`:195-216`) |
| Store semantics | instances read the store with an mtime cache; "a revoked device fails on the next request after the store changes" (pairing contract §4.4); unpair-all is one atomic store write (§4.5) |

## Chosen design

- On a device join: `Process.send_after(self(), :device_recheck, recheck_ms)` with
  `recheck_ms` from `Endpoint.config(:voice_device_recheck_ms) || 15_000` (test seam, same
  style as `:voice_max_session_audio_bytes`, `voice_channel.ex:328-330`).
- `handle_info(:device_recheck, socket)`: if `device_active?(id)` → reschedule; else push
  `error` `{reason: "This device was unpaired.", reason_code: "auth_changed"}` and
  `{:stop, :normal, socket}`. **Copy for DESIGN-N6/N7** (shown by the native client, not the
  dashboard); the code is the contract.
- The same check runs at the start of `handle_in("stop")` and `handle_in("cancel")`; a
  revoked device's `stop` does not commit (no transcript returned to a revoked device).
- A store read error is treated as **not active** (fail closed, pairing contract §9).
- Bound: revocation takes effect within `recheck_ms` (15 s) for an idle-listening session,
  immediately at the next `stop`.

## Implementation steps

1. Device-join clause schedules the first recheck.
2. Add `handle_info(:device_recheck, …)` and the guard in `stop`/`cancel`.
3. Tests with `voice_device_recheck_ms: 10` and a temp store.

## Non-happy paths

- Store briefly unreadable during an atomic rename: fail closed ends the session; the device
  can reconnect with a new ticket if it is still paired. Accepted: a false end is cheaper than
  a revoked device that keeps listening.
- Many device sessions: at most 8 global (limiter), so at most 8 timers.

## Compatibility and rollout

Device path only. No config key (the seam is endpoint config for tests). Rollback: revert.

## Verification

| Test (`test/aiur_web/device_voice_test.exs`) | Expected |
| --- | --- |
| "revoking the device ends an open dictation" | revoke in the temp store; within the 10 ms test interval the client gets `error{reason_code: "auth_changed"}` and the channel exits; fake transcriber `stop` called, `commit` not |
| "unpair-all ends every device session" | two devices joined; unpair-all; both channels exit |
| "stop from a revoked device returns no transcript" | revoke then `stop` → no `transcript` push, `auth_changed` error |
| "an unreadable store ends the session" | chmod 000 the temp devices file → channel exits |
| "an active device keeps its session across rechecks" | three intervals pass, channel alive, lease held |

```bash
env -C src mise exec -- mix test test/aiur_web/device_voice_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation checks.** Remove the reschedule-on-inactive branch (always reschedule): "revoking
… ends" fails. Treat a store error as active: "unreadable store" fails.

## Completion and handoff

- [ ] Recheck timer and stop/cancel guard; five tests green.
- [ ] Docs: one sentence in MP-N2's revocation docs ("open voice sessions end within 15
      seconds"); owned by MP-N2-C9, requested here.
- **Dependents:** MP-N6, MP-N7 device validation (revoke during dictation).
