---
ticket_id: MP-E5-C2-T02
feature_id: MP-E5
chunk_id: MP-E5-C2
bucket: 2-platform
title: Channel cancel event that discards the uncommitted utterance
status: ready
blocked_by: ["DESIGN-E5 (waived for this ticket: backend event only; the Cancel control is MP-E5-C6-T02)", MP-E5-C2-T01]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07, ui-08]
prior_findings: []
size_owner: WEB (voice_channel.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C2-T02 — `cancel` on the dictate channel

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C2.
- **User value:** a person who starts dictating by mistake can throw the utterance away
  without the provider committing it and without partial text reaching the field. Phone and
  watch (MP-N6/N7) need the same event, so it is server-side, not a browser-only trick.
- **Deliverable:** `handle_in("cancel", _, socket)` on `voice:dictate` / `voice:dictation`
  per contract §3.3: stop the transcription **without commit**, release the lease, push
  `stopped` with `{"cancelled" => true}`, and drop any transcript frame that arrives after.
- **Non-goals:** the Cancel button and the field restore (MP-E5-C6-T02 — the browser keeps
  `baseText`, `conversation-voice-controller.js:167,345-352`); cancel on the legacy
  `voice:conversation` topic (left as is until E5-OQ2).

## Dependencies and blockers

- **Predecessors:** MP-E5-C2-T01 (topic and `reason_code`), MP-R5-C1-T02 (facade
  `Aiur.Voice.stop/1`).
- **May run concurrently with:** MP-E5-C2-T03, MP-E5-C8-*.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| `stop` commits | `voice_channel.ex:108-116` calls `Realtime.commit/1`; `commit` seals then closes (`realtime.ex:106-112`) |
| Close without commit exists | `Realtime.stop/1` "Close a session immediately without committing the current utterance" (`realtime.ex:114-120`); `terminate/2` already uses it (`voice_channel.ex:196-203`) |
| Release | `release_stt/1` (`:218-222`) → `release_voice_lease/1` (`:224-231`) |
| Transcript relay | `handle_info({:elevenlabs_transcript, …})` pushes unconditionally (`:154-157`); after R5 the tag is `{:voice_transcript, …}` |
| Unknown events | `handle_in(_event, _payload, socket)` ignores them (`:151`), so today a `cancel` push is silently a no-op |

## Chosen design

```elixir
def handle_in("cancel", _payload, %{assigns: %{voice_mode: :dictation, stt: %{pid: pid}}} = socket) do
  :ok = Aiur.Voice.stop(pid)                      # no commit
  push(socket, "stopped", %{"cancelled" => true})
  {:noreply, socket |> assign(:voice_cancelled?, true) |> release_stt()}
end

def handle_in("cancel", _payload, socket) do      # nothing recording: idempotent
  push(socket, "stopped", %{"cancelled" => true})
  {:noreply, socket}
end
```

- After cancel, `handle_info({:voice_transcript, …})` and `{:voice_closed}` are dropped while
  `voice_cancelled?` is true (a late partial must never reach the field).
- A cancel after `stop` (commit in flight) still drops later finals: the human asked to
  discard. The client already restores its `baseText`.
- `voice_mode` stays `:dictation` internally for both topic names (`:70`).
- Invariant: after `cancel`, the channel pushes no `transcript` event. Audio already sent to
  the provider has left the machine (contract §10); cancel does not claim otherwise.

## Implementation steps

1. Add the two `handle_in("cancel", …)` clauses before the catch-all (`:151`).
2. Guard the transcript and closed `handle_info` clauses on `voice_cancelled?`.
3. After `release_stt/1`, a subsequent `audio` push must not reach a dead pid: the existing
   `audio` clause reads `socket.assigns.stt.pid` (`:90`), which would crash on `nil`. Add a
   clause `handle_in("audio", _, %{assigns: %{stt: nil}})` that pushes `error` with
   `reason_code: "invalid_payload"` and reason "Dictation is not active." (**copy for
   DESIGN-E5**; the client never sends audio after cancel, so this is a defensive path).
4. Tests below.

## Non-happy paths

- Double cancel: second call hits the idle clause; one more `stopped{cancelled}`; no crash.
- Cancel racing with `{:voice_closed}` from the provider: whichever comes first releases the
  lease once (`release_voice_lease/1` is idempotent on `nil`, `:224-231`).
- Daemon restart: channel gone; nothing to cancel; client shows transport loss (C6).

## Compatibility and rollout

Old clients never send `cancel`; behaviour unchanged for them. No config. Rollback: revert.

## Verification

| Test (`voice_channel_test.exs`, PROPOSED names) | Expected |
| --- | --- |
| "cancel stops the transcriber without committing" | fake transcriber records `stop` called, `commit` not called; client receives `stopped` with `cancelled: true` |
| "cancel drops late transcript frames" | after cancel, sending `{:voice_transcript, :final, "late"}` to the channel produces no `transcript` push (`refute_push`) |
| "cancel releases the session lease" | two cancelled sessions then two new joins succeed under the per-authority cap of 2 |
| "cancel with no active session is idempotent" | `stopped{cancelled: true}`, channel alive |
| "audio after cancel is refused without crashing" | `error` push with `reason_code: "invalid_payload"`; channel process still alive |

```bash
env -C src mise exec -- mix test test/aiur_web/voice_channel_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation checks.** Replace `Aiur.Voice.stop(pid)` with `Aiur.Voice.commit(pid)` in the
cancel clause: "without committing" fails. Remove the `voice_cancelled?` guard: "drops late
transcript frames" fails.

## Completion and handoff

- [ ] `cancel` implemented and tested; no user-visible change until C6-T02.
- [ ] Docs: none yet (C6-T02 documents the control).
- **Dependents:** MP-E5-C6-T02, MP-N6-C4-T02, MP-N7 dictation relay.
