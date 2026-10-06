---
ticket_id: MP-E7-C3-T03
feature_id: MP-E7
chunk_id: MP-E7-C3
bucket: 2-platform
title: "Route every conversation send entry point through :listener (dashboard, Stream Deck, aiur message, HTTP, TUI)"
status: blocked
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, MP-E7-C3-T02, MP-R7-C1-T02]
prior_units: [U4]
prior_boundaries: [MSG (16), WEB, CTL]
prior_features: [integrations-43, cli-15, ui-06]
prior_findings: []
size_owner: n/a for agent_chat.ex (147) and operator_dispatch.ex; CLI/WEB/DECK_WEB files untouched; observability_api_controller.ex +2 lines
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C3-T03 — Switch the send entry points to `:listener`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C3.
- **User value:** after the flag flips (MP-E7-C7-T04), a message from any
  surface lands according to the agent's mode. In wave 3 (flag `:legacy`)
  behaviour is identical to today; the point of shipping now is that MP-E3-C5
  and MP-E4-C6 build on the final call shape (RC-05).
- **Deliverable:**
  - `AgentChat.send/3` default becomes `delivery_policy: :listener,
    origin: :agent_chat` (`agent_chat.ex:27-28`); an explicit
    `delivery_policy:` opt still wins (internal callers).
  - `AgentChat.send/3` passes `origin` through to the Orchestrator payload
    (`agent_chat.ex:35-45`).
  - TUI chat bridge: `delivery_policy: :listener, origin: :tui` instead of
    `:auto` (`opencode/chat_completions/operator_dispatch.ex:46-50`).
  - HTTP `POST /api/v1/:id/messages`: payload gains
    `delivery_policy: :listener, origin: :http`
    (`aiur_web/controllers/observability_api_controller.ex:186-192`).
  - `Aiur.Listener.send/3` (PROPOSED, facade in `listener.ex`):
    `send(target, text, client_request_id)` → `AgentChat.send(target, text,
    message_id: client_request_id)`; the contract §7 send API that MP-E4-C6
    and MP-E3-C5 call.
- **Unchanged callers (they go through `AgentChat.send/3`'s default):**
  dashboard drawer (`aiur_web/live/dashboard_live.ex:2686-2694`), Stream Deck
  (`aiur_web/streamdeck_channel.ex:462-469`), `aiur message`
  (`agent_control_cli.ex:1477-1482`). Voice dictation has no server send path:
  `AiurWeb.VoiceChannel` returns text to the browser (`voice_channel.ex:84-115`)
  and the operator sends it through the dashboard composer.
- **Non-goals:** Command answers (`decision_dispatch.ex:51-63`,
  `decision_revision_dispatch.ex:128`) keep `:interrupt` via the correlated
  path; no CLI/HTTP output change; no new flag.

## Dependencies and blockers

- DESIGN-E7; MP-E7-C3-T02; MP-R7-C1-T02 (the characterization suite that must
  pass unchanged with the flag at `:legacy`).
- Concurrent with MP-E7-C3-T04.

## Verified starting point (aiur `45a290e3`)

- `AgentChat.send/3` default `:interrupt` / `:queue_next` (`agent_chat.ex:27-28`).
- HTTP sends pass no policy → `:checkpoint` default (`operator_messages.ex:572`).
- TUI passes `:auto` (`operator_dispatch.ex:46-50`).
- Correlated Command sends: `DecisionDispatch` default `send_fun` is
  `OperatorMessages.send_correlated_operator_message/3` (`decision_dispatch.ex:40`).
- Existing tests: `src/test/aiur/agent_chat_test.exs` ("send delegates to
  orchestrator control path", :15-18), `opencode/chat_completions/operator_dispatch_test.exs`,
  `aiur_web/controllers/observability_api_controller_test.exs`,
  `aiur_web/streamdeck_channel_test.exs`.

## Chosen design

- `origin` is a closed atom set (`:agent_chat | :http | :tui | :internal`);
  unknown origins are `:internal`, which resolves to an error under `:legacy`
  so a new caller cannot silently pick a policy.
- Because `:legacy` maps each origin to exactly its old policy (C3-T02 table),
  `AgentQueue.operator_message/3` receives the same keyword list as before for
  every caller.

## Implementation steps

1. `agent_chat.ex`: change the default and add `origin` to the payload (+3 lines).
2. `operator_dispatch.ex:46-50`: replace `:auto` (+1 line).
3. `observability_api_controller.ex:186-192`: add the two payload keys.
4. `listener.ex`: add `send/3`.
5. Tests.

## Non-happy paths

- Under `:legacy`, an unexpected `origin` atom from a future caller returns
  `{:error, :invalid_message}`; covered by a test so the failure is loud.
- Under `:listener` with `effective: nil`, `{:error, :listener_mode_unavailable}`
  reaches the caller: the dashboard shows its existing error path
  (`put_chat_error/3`), the CLI prints the reason, HTTP returns its existing
  error mapping. Copy for this case is a DESIGN-E7 item (§3 "Error"), so the
  wave-3 surfaces show the raw reason only behind the flag.

## Compatibility and rollout

- Flag `:legacy` (default): no observable change. The R7-C1-T02 entry-point
  suite is the proof.
- Flag `:listener` (dogfood only): sync becomes the default for dashboard,
  Stream Deck and `aiur message` — the E7-D6 behaviour change.
- Rollback: revert, or keep the code and the flag at `:legacy`.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/agent_chat_test.exs test/aiur/opencode/chat_completions/operator_dispatch_test.exs test/aiur_web/controllers/observability_api_controller_test.exs test/aiur_web/streamdeck_channel_test.exs
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/delivery_entry_points_test.exs test/aiur/orchestrator/operator_messages/delivery_matrix_test.exs
```

Tests:

- "AgentChat.send defaults to the listener policy with origin agent_chat" (asserts the payload the Orchestrator receives).
- "explicit delivery_policy still wins over the listener default".
- "TUI bridge sends origin tui with the listener policy".
- "HTTP messages endpoint sends origin http with the listener policy".
- "with routing :legacy every entry point produces today's queue item" (R7-C1-T02 suite unchanged; the guard that proves RC-05).
- "with routing :listener a dashboard message to a mid-turn codex agent is not interrupted" (enqueue → `interrupt_requested == false`, claimed after the turn).
- "Command answers keep interrupt under listener routing".

Mutation checks: restore `:interrupt` as the `AgentChat` default → the first
test fails, and with routing `:listener` the "not interrupted" test fails;
drop `origin` from the HTTP payload → the HTTP test fails.

Manual (AGENTS.md "Manual testing", Executor-run, local flag set to
`:listener`): `scripts/aiurdev --test` in the wrapper tmux, open a Codex
agent's chat pane mid-turn, type a message, confirm the pane shows it
`QUEUED` and delivered at the turn end with no interrupted turn; repeat with
the flag at `:legacy` and confirm today's interrupt behaviour.

## Completion and handoff

- [ ] Four entry points on `:listener`; legacy suite unchanged; `Listener.send/3` exists.
- [ ] PR body: mutation results and the manual capture for both flag values.
- Dependents: **MP-E4-C6-T3** ("Switch composer to MP-E7 + delivery overlay")
  and **MP-E3-C5-T1** ("Executor send adapter over E7") call `Aiur.Listener.send/3`;
  RC-05 puts this ticket ahead of both. MP-E7-C7-T04 flips the flag.
- Docs: none while `:legacy` (no documented behaviour changes); MP-E7-C7-T04
  updates `website/docs-app/reference/cli.md` (`aiur message`) and the
  concepts page when the default changes.
