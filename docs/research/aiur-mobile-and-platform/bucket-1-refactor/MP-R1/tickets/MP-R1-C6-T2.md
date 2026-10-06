---
ticket_id: MP-R1-C6-T2
feature_id: MP-R1
chunk_id: MP-R1-C6
bucket: 1-refactor
title: Endpoint socket registration — components contribute their socket mounts
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T1]
prior_units: [U6]
prior_boundaries: ["WEB #34", "SD #35", "VOX #36"]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C6-T2 — Endpoint socket registration

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C6. Migration step S11.
- **User value:** none visible. MP-R5 (voice-stt) and MP-R6 (streamdeck-server) can move
  their socket declaration together with the socket module, so `AiurWeb.Endpoint` (web-shell)
  stops naming `AiurWeb.StreamdeckSocket` and `AiurWeb.VoiceSocket` directly.
- **Deliverable:** the three `socket/3` mounts in `endpoint.ex` move into per-component
  macros that the endpoint expands in the same order with the same options. The endpoint's
  socket table is unchanged.
- **Non-goals:** no auth change to either socket. No device-authenticated voice path (RC-16,
  MP-E5). No runtime enable/disable of a socket: absence is already handled at `connect/3`
  and channel join. No change to `Plug.Static` or the parsers.

## Dependencies and blockers

> **Size owner (RC-23).** `size_owner` comes from the U8 ledger pinned at `465aca643`, while this pack is at `45a290e3`. Re-resolve it at ticket start against the then-current U8 ledger (the MP-R1-C11-T2 sweep step). RC-19/RC-20: this ticket touches none of `issue_sync.ex`, `dispatch_policy.ex`, `github/labels.ex` or `github/issues.ex`; if a rebase brings one into scope, preserve the MP-E1-C1 hooks.

- **DESIGN-R1 §1** (no runtime change) — blocked until approved.
- **MP-R1-C1-T1** (manifest, C1–C5 researcher) for component ownership of the new files.
  It is soft: without C1-T1 this ticket can merge, and the paths go to C1-T1.
- **May run concurrently with:** MP-R1-C6-T1 (router only; disjoint files), C7/C8 tickets.
- **Precedes:** MP-R5 and MP-R6 module moves (path-map PR-04, PR-05), and MP-R1-C6-T3 only
  through shared review of `endpoint.ex` (T3 edits `authenticate_static_asset/2`; land T2
  first or rebase).

## Verified starting point

Base `45a290e3`.

- `src/lib/aiur_web/endpoint.ex` (86 lines):
  - `socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [:user_agent, session: @session_options]], longpoll: false)` (14-17).
  - `socket("/streamdeck", AiurWeb.StreamdeckSocket, websocket: true, longpoll: false)` (19-22).
  - `socket("/voice", AiurWeb.VoiceSocket, websocket: [connect_info: [session: @session_options], max_frame_size: 400_000], longpoll: false)`
    (24-29), with the comment at 24-25.
  - `@session_options` (8-12) is shared by `/live`, `/voice` and `plug(Plug.Session, …)` (82).
- `AiurWeb.StreamdeckSocket.connect/3` verifies a Stream Deck token and otherwise returns
  `:error` (`streamdeck_socket.ex:10-25`).
- `AiurWeb.VoiceSocket.connect/3` requires `dashboard_writable`, a valid CSRF token and a
  session context, and otherwise returns `:error` (`voice_socket.ex:20-37`).
- `Phoenix.Endpoint.socket/3` is a macro that defines a mount point
  (https://hexdocs.pm/phoenix/1.8.1/Phoenix.Endpoint.html#socket/3, accessed 2026-10-06;
  repo pins Phoenix 1.8.9 in `src/mix.lock`). A mount therefore has to be declared at
  compile time inside the endpoint module. The macro-expansion pattern chosen in
  MP-R1-C6-T1 applies here as well.
- Socket tests: none assert the endpoint's mount table. Channel tests exist (e.g.
  `src/test/aiur_web/` streamdeck and voice channel tests); they drive the socket modules
  directly.

## Chosen design

- New module per owner (all PROPOSED):
  - `AiurWeb.Sockets.LiveView.mount/1` (dashboard-ui): `/live`.
  - `AiurWeb.Sockets.Streamdeck.mount/1` (streamdeck-server): `/streamdeck`.
  - `AiurWeb.Sockets.Voice.mount/1` (voice-stt): `/voice`, with its comment.
- Each is a `defmacro mount(session_options)` returning `quote do socket(...) end`. It takes
  the session options as an argument, so `@session_options` stays defined once in the
  endpoint (web-shell owns the session).
- The endpoint expands them in today's order: LiveView, Stream Deck, Voice.
- Invariant: path, module and the full websocket/longpoll option list of every mount are
  unchanged.
- Why not a runtime registry: Phoenix mounts are compile-time. An "optional" socket stays
  compiled in, and capability absence is reported through `GET /api/v1/capabilities`
  (`streamdeck`, `voice.stt`; C3) and by the socket's own `connect/3` refusal. That is
  today's behaviour.

## Implementation steps

1. Add the mount-table test first, green on the base: assert
   `AiurWeb.Endpoint.__sockets__()` equals
   `[{"/live", Phoenix.LiveView.Socket, …}, {"/streamdeck", …}, {"/voice", …}]` with the
   exact option keyword lists. Phoenix generates `def __sockets__, do: unquote(Macro.escape(sockets))`
   (`@doc false`) in every endpoint
   (https://github.com/phoenixframework/phoenix/blob/v1.8.1/lib/phoenix/endpoint.ex#L692,
   accessed 2026-10-06). It is undocumented, so read the tuple shape from
   `src/deps/phoenix/lib/phoenix/endpoint.ex` at the pinned 1.8.9 before writing the
   literal, and name the dependency on a private function in the test's comment.
2. Create the three modules under `src/lib/aiur_web/sockets/` (PROPOSED), moving the mounts
   verbatim.
3. Replace `endpoint.ex:14-29` with `require` plus three expansion calls.
4. Update manifest paths (C1-T1).

Size: `endpoint.ex` 86 → ~75 lines; three new modules of about 15 lines each.

## Non-happy paths

- **Option drift** (for example losing `max_frame_size: 400_000` would make dictation frames
  fail). The mount-table test compares option lists.
- **Session-option divergence** (for example `/voice` and `Plug.Session` using different
  signing salts would reject every voice connect). Session options are passed in, not copied;
  the existing voice socket connect test with a real session catches a mismatch.
- **Absent component.** Unchanged: connect returns `:error`, and the capability report
  (C3-T2) states the reason.
- Concurrency, idempotency, privacy: n/a (no runtime path change).

## Compatibility and rollout

No config, flag or migration change. Rollback is a revert. No docs (internal refactor).

## Verification

From a worktree, with `HOME` isolated and GitHub tokens unset (see MP-R1-C6-T1):

```bash
env -C <worktree>/src mise exec -- mix test test/aiur_web/endpoint_sockets_test.exs \
  test/aiur_web/voice_channel_test.exs test/aiur_web/streamdeck_channel_test.exs \
  test/aiur_web/streamdeck_voice_latency_test.exs
env -C <worktree>/src mise exec -- mix compile --warnings-as-errors
```

(These three channel tests exist at `45a290e3`. Re-list them with
`git ls-files src/test/aiur_web | grep -E 'voice|streamdeck'` at the implementation head.)

| Test | Expected |
|---|---|
| `endpoint_sockets_test.exs` "socket mounts are unchanged by registration" (PROPOSED) | Equal to the base literal |
| existing voice and Stream Deck socket/channel tests | Green, unchanged |

**Mutation check.** In the refactored tree, change `max_frame_size` in
`AiurWeb.Sockets.Voice`, and separately reorder two expansions. Each must fail the
mount-table test. Restore and confirm green. The test passes on `main` by design (regression
guard); say so in the PR body.

**Manual.** Foreground `scripts/aiurdev --test`: open the dashboard (LiveView connects over
`/live`). Then, as AGENTS.md "Manual testing" requires, open a chat pane and send a message.
If a Stream Deck emulator page (`/streamdeck`) is available, confirm that it connects.
Capture the panes.

## Completion and handoff

- [ ] Mount table unchanged; three mounts owned by their components.
- [ ] Mutation check recorded.
- **Docs:** none.
- **Dependents:** MP-R5 (moves `AiurWeb.Sockets.Voice` with the voice component), MP-R6
  (moves `AiurWeb.Sockets.Streamdeck`), MP-E5's device-authenticated voice path (RC-16)
  adds its mount through the same pattern.
