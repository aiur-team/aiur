---
ticket_id: MP-E7-C6-T01
feature_id: MP-E7
chunk_id: MP-E7-C6
bucket: 2-platform
title: "Daemon endpoint: claim and render a listener batch for the attached Executor at a hook boundary"
status: blocked
blocked_by: [DESIGN-E7, DESIGN-E3, MP-E3-C1-T01, MP-E3-C1-T02, MP-E7-C3-T02, MP-E7-C6-T04]
repo: aiur-team/aiur
wave: 4
prior_units: [U3, U4]
prior_boundaries: [WEB, EXE, MSG (16)]
prior_features: [MP-E3]
prior_findings: [listener-mode contract §8; Khala deliver-core.ts limits]
size_owner: WEB (observability_api_controller is oversized — new controller module)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C6-T01 — Executor hook delivery endpoint

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C6 hook delivery into
  attached sessions.
- **User value:** a message the operator sends to the Executor (MP-E3-C5)
  reaches the operator's own Claude Code or Codex session at a proven hook
  boundary, according to the Executor's listener mode, without tmux typing.
- **Deliverable:** `POST /api/v1/executor/hook/deliver?harness=claude|codex`
  (PROPOSED path). Input: the raw hook stdin JSON. Output: `200` with the
  exact stdout the hook must print (the envelope), or `204` with an empty body
  when nothing is due. The daemon decides the boundary, claims the batch,
  marks it `harness_queued`, and renders the envelope.
- **Non-goals:** the hook command (C6-T02), installation (C6-T03), the
  renderer itself (C6-T04), idle wake of an Executor with no turn running
  (see Non-happy paths), any worker agent (workers use the scheduler, C3).

## Dependencies and blockers

- **DESIGN-E7** and **DESIGN-E3** (Executor attach is opt-in UX; E3 decides
  whether the Executor has a mode selector or a fixed mode, DESIGN-E7 §1.7).
- **MP-E3-C1-T01** (binding store: `current/0`, `binding_id`, `generation`,
  `provider_session_id`) and **MP-E3-C1-T02** (hook token file, bearer auth,
  and the payload normalizer returning `{event, session_id, …}`). This
  endpoint reuses both; it must not define a second token or normalizer.
  (MP-E3 chunks list them as "MP-E3-C1-T01/T02"; two-digit IDs assumed.)
- **MP-E7-C3-T02** (scheduler decision per mode × boundary) and
  **MP-E7-C6-T04** (Elixir envelope renderer).
- **Order:** MP-E3-C1 → this → MP-E3-C5-T01 (Executor send adapter). **May run
  concurrently with** C6-T02/T03 once the path and response contract below are
  fixed.

## Verified starting point (at `45a290e3`)

- The only hook sink today is `POST /api/v1/:issue_identifier/claude-hook`
  under `[:dashboard_auth, :api_write]`, outside `:require_writable`
  (`aiur_web/router.ex:166-178`), fed by a stdout-silent, `curl -m 2`,
  always-exit-0 command (`claude/hook_settings.ex:26-45`).
- MP-E3-C1-T02 plans `POST /api/v1/executor/hook` with a 0600 bearer token in
  `StatePaths.dir()/<repo>.<instance_key>.executor.hook-token` (per instance; read it
  only through `Aiur.Executor.HookToken.path/0`/`read/0`, and the daemon URL from the
  `…executor.hook-url` file at run time — listener-mode §8, Phase D CR-E3-4/5), always `202`, never blocking
  (MP-E3 `chunks.md` "MP-E3-C1"). That endpoint stays ingest-only and silent;
  delivery is a separate endpoint because its response body is printed into
  the session.
- `observability_api_controller.ex` is a large shared controller; add a new
  controller `AiurWeb.ExecutorHookDeliveryController` (PROPOSED).
- No Executor listener record exists (`git grep -n listen 45a290e3 --
  src/lib` finds only `Aiur.ExecutorListener`, an unrelated bus consumer —
  contract §1 name-collision note).

## Chosen design

Request handling, in order:

1. **Auth:** bearer token = MP-E3-C1-T02's hook token (constant-time
   compare). Remote IP must be loopback (`{127,0,0,1}` or `::1`), contract §12;
   otherwise `403`. Wrong/missing token → `401`, no state change.
   The loopback `remote_ip` check is defence in depth, not the boundary: a local tunnel or reverse proxy that forwards remote traffic to `127.0.0.1` passes it. The hook token is the boundary. (pairing contract security sibling §S3; same wording as MP-E3-C1-T02; security m10.)
2. **Normalize** with MP-E3's normalizer; reject if `session_id` ≠ the
   current binding's `provider_session_id` → `204` (a hook from another
   session must never receive Executor messages).
3. **Boundary:** `PostToolUse → :tool`, `UserPromptSubmit → :prompt`,
   `Stop → :stop` (if `stop_hook_active == true` → no delivery, `204`, so a
   continuation cannot loop; contract §8 and Khala `deliver-core.ts:239-240`),
   `SessionStart → :none` (context only; this ticket returns `204`).
4. **Decide:** call the scheduler (C3) with `{mode, boundary, activity}` where
   mode is the Executor conversation's effective mode (C2 store keyed by the
   Executor `ConversationRef`, MP-E4-C1). The decision table is the vendored
   `scheduler.v1.json` (C1-T02/T04), the same rows C3-T05 tests.
5. **Claim:** in one orchestrator call, claim up to 50 pending Executor items
   in arrival order whose rendered frame fits 64 KiB (contract §8), mark them
   `:delivered` (`harness_queued`), record `delivered_via: :hook` and the hook
   event; persist.
6. **Render** via C6-T04 for the harness and event; respond `200` with
   `content-type: application/json`.
7. **Budget:** the whole call must finish in ≤ 1.5 s; on timeout respond
   `204` and leave items pending (the hook prints nothing, next boundary
   retries).

Response contract (fixed here so C6-T02 can proceed):
`200` → body is printed verbatim to the hook's stdout; any other status →
nothing printed.

Invariant: an item is marked delivered only in the same call that returns its
envelope. If the HTTP write fails after the mark, the item is lost to the
session but marked `harness_queued` — **mitigation:** mark first with
`delivery_attempt_id`, and if the controller's `send_resp` raises, restore in
an `after` block. Remaining risk (client killed after receive, before print)
is the same "delivery equals acknowledgement at hook emit" rule Khala uses
(contract §8).

## Implementation steps

1. Router: new scope with a plug pipeline `[:executor_hook_auth]` (token +
   loopback), outside `:require_writable`, like the claude-hook scope.
2. Controller (new module) implementing steps 1–7.
3. Orchestrator API `claim_executor_hook_batch(binding_id, boundary, limits)`
   in a new `orchestrator/operator_messages/executor_hook_claims.ex`.
4. Tests.

## Non-happy paths

- **No binding / detached:** `204`.
- **Executor idle (no turn running):** no hook fires, so `sync`/`steer`
  messages wait until the operator's next prompt (`UserPromptSubmit`). Khala
  needed a Stop-armed watcher to wake an idle Claude session and still rates
  that `experimental` (`experiments/internal-mode/listening-modes/claude/README.md`
  at Khala `origin/main` `99e72a43`). This ticket reports the idle case as
  receipt `accepted` with reason `executor_idle` (via C3-T04 receipts);
  idle wake is out of scope and recorded as RQ-E7-C6-1 for the parent.
- **Async:** never delivered by hooks; Executor `async` reads via a pull
  path that MP-E3 owns (contract §9 "aiur executor-wait-style pull").
- **Duplicate hooks** (two installs): second call finds nothing pending → `204`.
- **Daemon down:** curl fails, hook prints nothing, exit 0 (C6-T02).
- **Takeover/generation change:** items claimed under an old `generation` are
  not re-delivered; a new binding starts from pending items only.
- **Privacy:** response contains only Executor-addressed messages; no logging
  of bodies beyond the existing 500-byte preview rule.

## Compatibility and rollout

New endpoint, inert until an Executor is attached (opt-in, MP-E3) and the
hook command is installed (C6-T03). No config key. Rollback: remove the route;
installed hooks then get `404` and print nothing.

## Verification

- `executor_hook_delivery_controller_test.exs` (new):
  `"Stop with one pending sync message returns 200 with a block envelope and
  marks it harness_queued"`; **mutation:** skip the claim/mark step → item
  stays pending → fails.
  `"Stop with stop_hook_active returns 204 and claims nothing"` — mutation:
  remove the guard → fails.
  `"PostToolUse delivers steer but not sync"` (table row from
  scheduler.v1.json).
  `"hook from a different session id returns 204"`; `"non-loopback remote_ip
  returns 403"`; `"wrong token returns 401 without state change"`;
  `"render failure restores the item to pending"`.
- Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec --
  mix test test/aiur_web/controllers test/aiur/orchestrator`.
- Manual: see C6-T03 (end-to-end with a real Claude Code Executor session).

## Completion and handoff

- [ ] Tests and mutation checks in PR.
- [ ] Response contract (200 → print, else nothing) unchanged from this doc.
- Docs: C7-T05 (concepts: how the Executor receives messages); that page carries the sentence
  "The loopback `remote_ip` check is defence in depth, not the boundary: a local tunnel or
  reverse proxy that forwards remote traffic to `127.0.0.1` passes it. The hook token is the
  boundary."
- Dependents: C6-T02, C6-T03, MP-E3-C5-T01.
