---
ticket_id: MP-E2-C5-T02
feature_id: MP-E2
chunk_id: MP-E2-C5
bucket: 2-platform
title: aiur handles Claude requestUserInput through NativeCapture; minimum aiur-claude version
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C5-T01, MP-E2-C4-T03, MP-E2-C4-T04]
prior_units: [U4, U6]
prior_boundaries: [CLD #22, RUN #18, DEC #27]
prior_features: [MP-R7 (adapter callbacks; MP-R7-C5 protocol fixture must gain this method)]
prior_findings: [R-Q2, plan §1.4 (catch-all at coding_agent.ex:385-399)]
size_owner: "CLAUDE (claude/coding_agent.ex 534 — already over 500: add one delegating clause, move ≥ equal lines out or coordinate with the U8 CLAUDE owner)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C5-T02 — aiur handles Claude `requestUserInput`; minimum `aiur-claude` version

## Identity and outcome

- Bucket 2, MP-E2, chunk C5.
- **User value:** Claude workers' native questions become Commands, held and answered
  exactly like Codex ones.
- **Deliverable:**
  1. Config `decisions.native_capture.claude` (default `false`); when on, `thread/start`
     sends `nativeQuestions: true`.
  2. `Aiur.Claude.CodingAgent.handle_method/5` clause for `item/tool/requestUserInput`
     delegating to PROPOSED `Aiur.Commands.NativeCapture.Claude` (same `{:held, …}`
     contract as C4-T02; reply/release frame writers for the Claude shape).
  3. Minimum `aiur-claude` version check when the gate is on (install hint names it).
  4. `native.hold` = `:deferred` (Variant A) or `:in_band` (Variant B) per C5-T00.
- **Non-goals:** sibling change (C5-T01); `claude-repl` (RQ-E2-1, `:none`).

## Dependencies and blockers

- **DESIGN-E2**; C5-T01 released; C4-T03/T04 (shared hold/reply/release machinery).
- MP-R7-C5-T01's protocol fixture must add `item/tool/requestUserInput`; if it exists,
  extend it here.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/claude/coding_agent.ex:302-383` explicit methods; `:385-399` catch-all
  logs any other method as a notification (a request with an `id` would never be answered —
  the turn would hang until the idle timeout). File is 534 lines.
- Shared loop: `app_server/turn_loop.ex:95-98` routes `method` frames to
  `state.backend.handle_method/5`; the same `held_native_questions` state (C4-T02).
- Provider: `coding_agent/providers/claude.ex:19-21` (`default_command: "aiur-claude"`,
  `install_hint: "install it with: npm install -g aiur-claude"` — no version);
  `claude/config.ex:8-9,33-37` (command, permission mode).
- `thread/start` from aiur: `claude/coding_agent.ex:227-236`.

## Chosen design

- New clause before the catch-all:
  `def handle_method(session, state, %{"method" => "item/tool/requestUserInput", "id" => id, "params" => p}, raw, _)`
  → `NativeCapture.Claude.handle(session, state, id, p, raw)` returning `{:continue, state}`
  (held, with `held_native_questions` entry) or the release reply.
- With the gate **off** but an older/newer sibling sending the method anyway: reply with
  today's non-interactive answer shape so the turn never hangs (defensive).
- Version gate: `aiur-claude --version` (or `initialize` result `serverInfo.version`) ≥
  the C5-T01 release; below it, log once, report capability `:none` with
  `reason: :sibling_too_old`, and do not send `nativeQuestions`.
- Reply/release use the shared C4-T03/T04 paths; only the frame writer differs
  (`{"id": id, "result": {"answers": {qid: {"answers": [..]}}}}` — same as Codex by
  C5-T01 design).

## Implementation steps

1. Config field + accessor + `reference/configuration.md` entry.
2. PROPOSED `src/lib/aiur/commands/native_capture/claude.ex` (≈100 lines).
3. `claude/coding_agent.ex`: one clause; extract an equal number of lines (e.g. the
   rate-limit clause body) into `claude/coding_agent/notifications.ex` to keep net growth
   ≤ 0, or record the U8 CLAUDE owner's agreement in the PR.
4. `thread/start` param when gated; version check at session start.
5. `coding_agent/providers/claude.ex:21`: install hint names the minimum version.

## Non-happy paths

- Session gone while deferred (sibling restart): `reply` returns `{:error, :session_gone}`
  → C4-T03 fallback (message to the next worker; Command open).
- Gate off + method received: non-interactive answer (no hang).
- Version probe fails: treat as too old (`:none`).

## Compatibility and rollout

- Default off. Requires the new sibling release; documented in the config entry and
  install hint. Rollback: gate off.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/claude/coding_agent_test.exs test/aiur/commands/native_capture/claude_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "gate on: requestUserInput fixture (from C5-T00/T01) is held and creates one Command" | no response frame; `held_native_questions` has the ref; Command `native.harness == :claude` | step 3 clause |
| "gate off: requestUserInput is answered non-interactively, never hangs" | one response frame | defensive branch |
| "sibling below minimum: nativeQuestions not sent, capability :none sibling_too_old" | `thread/start` params lack the key | version gate |
| "answer delivered in-band writes the Claude reply frame" | frame equals fixture shape | writer |

Mutation check per row. Manual: wrapper-tmux `aiurdev --test` with
`decisions.native_capture.claude: true`, a Claude worker asked to use AskUserQuestion;
answer in `/commands`; pane `0.1` shows the agent continuing with the answer.

## Completion and handoff

- [ ] Clause, gate, version check, install hint; net size rule respected.
- Docs: `reference/configuration.md` (`decisions.native_capture.claude`); install docs
  mention the minimum `aiur-claude` version.
- Dependents: C5-T03, C8-T04.
