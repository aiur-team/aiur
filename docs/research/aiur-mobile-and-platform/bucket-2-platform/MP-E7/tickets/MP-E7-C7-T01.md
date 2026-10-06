---
ticket_id: MP-E7-C7-T01
feature_id: MP-E7
chunk_id: MP-E7-C7
bucket: 2-platform
title: "Dashboard: listener-mode selector, requested vs effective, receipts and unread count"
status: ready
blocked_by: [DESIGN-E7, MP-E7-C7-T03, MP-E7-C2-T03, MP-E7-C3-T04, MP-E7-C5-T02]
repo: aiur-team/aiur
wave: 4
prior_units: [U9]
prior_boundaries: [WEB]
prior_features: [MP-E3, MP-E4]
prior_findings: [AGENTS.md "Computed ages and collapsed causes"; unknown-path mutation rule]
size_owner: WEB (dashboard_live.ex is 2,903 lines — new component module only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C7-T01 — Dashboard listener-mode surfaces

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C7 surfaces and docs.
- **User value:** the operator sees and changes each agent's listener mode
  where DESIGN-E7 puts it, sees when a harness cannot do the requested mode
  and why, sees what happened to each sent message, and sees an async agent's
  unread count with its age.
- **Deliverable:** one new function component module (PROPOSED
  `aiur_web/components/operator_control_center/listener_mode.ex`) rendering
  the selector, effective-mode reason, receipts and unread count, mounted in
  the places DESIGN-E7 chooses (candidates: `fleet_table.ex`,
  `conversation_drawer.ex`, the composer); LiveView events that call the
  HTTP/control write from MP-E7-C7-T03; tests for every DESIGN-E7 §3 state.
- **Non-goals:** choosing placement, copy, or which states are distinct — all
  DESIGN-E7. Executor composer (MP-E3-C6 consumes this component if
  DESIGN-E7 §1.7 says "same selector").

## Dependencies and blockers

- **DESIGN-E7 approved** — placement (§1.1), requested/effective display
  (§1.2), receipt copy (§1.3), unread display (§1.4), all §3 states. Nothing
  here may be improvised.
- **MP-E7-C7-T03** (write API + names), **MP-E7-C2-T03** (`listener`
  read fields), **MP-E7-C3-T04** (receipt values),
  **MP-E7-C5-T02** (`unread_count`, `oldest_unread_at`).
- **May run concurrently with** C7-T02 and C7-T05 (docs reference final copy).

## Verified starting point (at `45a290e3`)

- Dashboard LiveView: `aiur_web/live/dashboard_live.ex` (2,903 lines) handles
  sends via `send_agent_message/3` → `AgentChat.send/3`
  (`dashboard_live.ex:2689-2695`) and per-action message ids (`:2682-2687`).
- Components: `operator_control_center/fleet_table.ex`,
  `operator_control_center/conversation_drawer.ex`.
- Routes: `live("/chat/:owner/:repository/:identifier", DashboardLive,
  :index)` (`router.ex:141`).
- Writes are gated by `observability.dashboard_writable`
  (`router.ex:56-62`; live bug #3010 notes the default mismatch).
- Tests: `src/test/aiur_web/live/dashboard_live_test.exs`; browser harness
  `src/test/browser/`.

## Chosen design

- Component takes `%{listener: listener_map | :unavailable, writable?: bool,
  now: DateTime}` and renders only from that map; no defaults invented.
- **States** (from DESIGN-E7 §3): loading, default, pending change (until
  `listen-mode.changed` with the new `version`, timeout per DESIGN-E7),
  conflict (409 → show winner), effective ≠ requested (reason text), steer
  emulated by interrupt (only if E7-D2 = offer), agent not running, paused,
  async unread N **with age** from `oldest_unread_at`, receipts per message,
  offline/stale (age of last update), permission denied (read-only), error.
- **Unknown/stale rendering:** `:unavailable` renders an explicit
  unavailable state, never `sync` (AGENTS.md unknown-path rule).
- LiveView handles `set_listen_mode` with `expected_version`, calls the
  C7-T03 control function, and subscribes to the change event.

## Implementation steps

1. Component module + stories in tests.
2. Mount points per DESIGN-E7 (small edits to the chosen components).
3. `dashboard_live.ex`: one `handle_event` clause delegating to a new
   `AiurWeb.ListenerModeEvents` module (keeps the oversized file from
   growing by more than the delegation).
4. Tests.

## Non-happy paths

- Read-only dashboard: selector disabled with the DESIGN-E7 reason.
- 409 conflict: show winner, keep the user's choice discardable.
- Event never arrives: pending state times out to an error with retry.
- Daemon unreachable: stale marker with age.

## Compatibility and rollout

Visible only after DESIGN-E7. Under `:legacy` routing the selector would set a
mode that does not affect delivery — **so this ticket merges together with or
after MP-E7-C7-T04** (flip), or hides the selector while routing is `:legacy`.
Decision: hide while `:legacy` (one boolean from C2-T03's map).

## Verification

- `listener_mode_component_test.exs`: one test per DESIGN-E7 §3 state,
  asserting both the rendered text and the value behind it (e.g. the
  effective mode atom). **Mutation (required):** replace the `:unavailable`
  branch with rendering `sync` → the unavailable test fails; replace the
  unread age with the current time → the age test fails.
- `dashboard_live_test.exs`: `"set_listen_mode with stale version shows
  conflict and winner"`; `"selector hidden under legacy routing"`.
- Browser test under `src/test/browser/` for the selector at phone width (per
  existing harness), including permission-denied.
- Commands: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec --
  mix test test/aiur_web`.
- Manual: `aiurdev --test`, open the dashboard, change a Codex agent to
  `async`, send two messages, see unread 2 with age, switch to `sync`, see the
  E7-D4 behaviour.

## Completion and handoff

- [ ] Every DESIGN-E7 §3 state tested; mutation checks in PR.
- [ ] Docs: `website/docs-app/guide/gui.md` section (AGENTS.md: new
  dashboard surface) — written in C7-T05 or here if C7-T05 has merged.
