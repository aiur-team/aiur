---
ticket_id: MP-E7-C7-T04
feature_id: MP-E7
chunk_id: MP-E7-C7
bucket: 2-platform
title: "Flip :listener_send_routing default to :listener and delete the legacy send policies"
status: blocked
blocked_by: [DESIGN-E7 (decision E7-D6), MP-E7-C3-T03, MP-E7-C3-T05, MP-E7-C7-T01, MP-E7-C7-T03, MP-E7-C4-T02]
repo: aiur-team/aiur
wave: 4
prior_units: [U3]
prior_boundaries: [MSG (16), CTL, WEB]
prior_features: [MP-R7]
prior_findings: [phase-b-reconciliation RC-05; MP-R7 plan F3]
size_owner: MSG
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C7-T04 — Make listener routing the default (the E7-D6 behaviour change)

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C7.
- **User value:** every conversation message lands according to the
  agent's mode (default `sync`), instead of according to which button was
  pressed. The dashboard, Stream Deck and `aiur message` stop cutting off the
  agent's turn by default.
- **Deliverable:** set `config :aiur, :listener_send_routing` default to
  `:listener` (introduced by MP-E7-C3-T03 with default `:legacy`), then in
  the same PR delete the `:legacy` branch and the flag, so there is one send
  path. If DESIGN-E7 chooses E7-D6 "keep a per-surface send-now override",
  implement that override as a one-message `steer` (contract §4) on the named
  surfaces only.
- **Non-goals:** Command answers and orchestrator digests keep their own
  policies (contract §2); they are not touched.

## Dependencies and blockers

- **DESIGN-E7 decision E7-D6** (RC-05: the default change is an owner item).
  Without it this ticket must not merge.
- **MP-E7-C3-T03** (flag + listener path), **MP-E7-C3-T05** (conformance),
  **MP-E7-C4-T02** (so `steer` on Codex is non-destructive before users rely
  on it), **MP-E7-C7-T01/T03** (operators can see and change the mode
  before the default changes under them).
- **Must not run concurrently with** any other C3 edit.

## Verified starting point (at `45a290e3`)

Today's per-entry-point defaults (to be replaced):

| Entry point | Policy | Evidence |
| --- | --- | --- |
| `AgentChat.send/3` (dashboard, Stream Deck, `aiur message`) | `:interrupt`, fallback `:queue_next` | `agent_chat.ex:27-28`; callers `dashboard_live.ex:2689-2695`, `streamdeck_channel.ex:468`, `agent_control_cli.ex:1478-1483` |
| HTTP `POST /api/v1/:id/messages` | `:checkpoint` (default) | `observability_api_controller.ex:186-192`, `operator_messages.ex:572` |
| TUI OpenCode chat pane | `:auto` | `opencode/chat_completions/operator_dispatch.ex:46-50` |
| Command answers | `:interrupt` (unchanged) | `decision_dispatch.ex:51-63` |

The MP-R7-C1 characterization suite (MP-R7-C1-T02 delivery matrix) pins
these rows; this ticket intentionally changes the message rows and must
update those expectations in the same PR, leaving the Command-answer row
unchanged.

## Chosen design

- Remove `delivery_policy` defaulting in `AgentChat.send/3` for conversation
  messages; the listener scheduler decides. Keep the explicit
  `delivery_policy:` option for internal callers and Command dispatch
  (MP-E7-C3-T03 kept that seam).
- Delete the `:legacy` branch and `Application.get_env(:aiur,
  :listener_send_routing, …)` reads; delete the flag from config files.
- E7-D6 override (only if chosen): an option `send_now: true` on the named
  surface's send call that enqueues one item with `steer` for that item.

## Implementation steps

1. Flip default; run full suite; update R7-C1-T02 expectations for message
   rows only.
2. Delete legacy branch + flag in a second commit in the same PR (so the
   first commit is a clean revert point).
3. Optional override per E7-D6.
4. Docs (with C7-T05 or here): `reference/cli.md:117` `aiur message` text
   ("Aiur may interrupt at a safe point…" becomes false), `guide/gui.md`,
   `guide/stream-deck.md`, `guide/tui.md` where they describe send behaviour.

## Non-happy paths

- **Stream Deck dictation mid-turn** now waits for the turn end under
  `sync` — the exact behaviour E7-D6 accepts; document it.
- **Agent never ends its turn** (stuck): message waits; the existing stall
  detector and operator interrupt control are unchanged.
- **Rollback:** revert the second commit restores the flag at `:listener`;
  revert both restores `:legacy`.

## Compatibility and rollout

Behaviour change for every operator (Bucket 2). Ship in a release note.
No migration: queue items already in flight keep the policy they were
enqueued with (contract §3 rule 6).

## Verification

- `agent_chat_test.exs`: `"dashboard send to a mid-turn codex agent in sync
  does not interrupt"` — **mutation (MP-E7 chunks):** restore
  `delivery_policy :interrupt` at `agent_chat.ex:27` → fails.
- R7-C1-T02 delivery matrix: message rows updated, Command-answer row
  unchanged — mutation: route Command answers through the listener → the
  Command row fails.
- `"no code reads :listener_send_routing"` — a source-scan test (pattern of
  RC-11's scan test) so the flag cannot return.
- Commands: `env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec --
  mix test` (full suite; CI green on the head SHA per memory "narrow test runs
  hide bugs").
- Manual (AGENTS.md recipe): `aiurdev --test`; Codex agent mid-turn; type in
  chat pane `0.1` and send from the dashboard drawer; both show the message
  delivered after the turn ends, no interrupt marker; repeat with the agent
  in `steer` and see mid-turn delivery (C4-T02).

## Completion and handoff

- [ ] E7-D6 answer cited; both commits; manual captures.
- [ ] Docs pages above corrected in this PR (AGENTS.md: changes documented
  behaviour).
- Dependents: none; closes RC-05's flag.
