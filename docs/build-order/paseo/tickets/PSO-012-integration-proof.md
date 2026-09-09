# PSO-012 — Integration proof: end to end, fallback, restart re-attach

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — no new design; one Elixir integration test against the real sidecar, one small core transcript clause, one CI wiring step, and the recorded manual proof

**Risk:** high

**Phase hint:** 4

**Depends on:** PSO-001, PSO-002, PSO-003, PSO-007, PSO-009, PSO-010, PSO-011

**Serializes with:** none

**External gates:** none

**Requirements:** R5, R6, R7, R8, R10, R11, R12, R14

**Decisions:** DEC-002, DEC-003, DEC-004, DEC-005, DEC-007, DEC-008, DEC-012, DEC-013

**Design evidence:** 00-design.md sections 6, 8, 9, 12; 01-spike-report.md sections 3, 4, 6, 9, 11

**Researched at:** aiur `8199f5373`, paseo `726067b4`, aiur-claude 1.1.0

**Suggested labels:** `complexity:3`, `model:claude`, `phase:4`, `build-lane:paseo-integration`; never `agent:todo`

## Outcome

The whole path is proven twice: once by an Elixir integration test that drives the real built `aiur-paseo` binary through `Aiur.AppServer.GenericBackend` against the package's fake daemon, and once by hand against a real Paseo daemon with the evidence recorded in the pack. After this ticket, "Paseo support works" is a statement backed by a green CI job and a dated evidence file, not by the sum of unit tests.

## Context and evidence

Core enters the path at `Aiur.AgentRunner.SessionLifecycle.start_agent_session/3` (`src/lib/aiur/agent_runner/session_lifecycle.ex` lines 904-943): `start_fun.(workspace, opts)`, and on `{:error, reason}` it looks up `CodingAgent.fallback_backend(backend)` and calls `start_fallback_session/6` once, stripping `:remote_control`, emitting `Aiur.Perf.event(:repl_start_fallback, ...)` and a warning. `test/aiur/orchestrator/rate_limit_fallback_test.exs` shows the repo's assertion style for backend fallback decisions (pure function, explicit `primary_backend`/`fallback_backend` options).

Transcript rendering enters at `Aiur.Claude.Transcript.extract/2` (`src/lib/aiur/claude/transcript.ex`): `item/created` with `params.item.type` dispatched by `event_from_item/4`, clauses for `"text"`, `"thinking"`, `"tool_call"`, `"tool_result"`, and a final `_type -> :skip` at line 326. There is no `"user"` clause; the on-disk path (`extract_user_record/2`) already builds `:user` events with `AgentEvents.transcript_event(:user, text, ...)`, which is the shape to reuse.

CI runs the Elixir suite as `coverage (N/4)` partitions with `MIX_TEST_PARTITION` (`.github/workflows/ci.yml` lines 191-246) and a separate `streamdeck` package job (line 465). The integration test needs the package built before `mix test`, so the partition job gains a Node setup and `npm ci && npm run build` step scoped to `packages/aiur-paseo`.

The sidecar's fake daemon (`packages/aiur-paseo/src/paseo/fake-daemon.ts`, PSO-006) is a scripted WebSocket server; this ticket adds a CLI wrapper so Elixir can start it as a child process.

## Scope

### Part 1: Elixir integration test

- Add `packages/aiur-paseo/scripts/fake-daemon.mjs --port N --script <path.json>` that starts the fake daemon from `dist/`, prints `READY <port>` on stdout, records every inbound request to `<script>.recorded.json` on exit, and replays the scripted `agent_update` and `agent_stream` events on `send`. Script format documented in the script header: `{agents: [{onCreate: [...events], onSend: [[...events per send]]}], status: {version, serverId}}`.
- Add `src/test/aiur/app_server/generic_backend_paseo_test.exs`, `async: false`, tagged `:paseo_sidecar`. Setup: skip with `@moduletag skip: "node or packages/aiur-paseo/dist missing"` unless `System.find_executable("node")` and `packages/aiur-paseo/dist/cli.js` exist; start `fake-daemon.mjs` on a free port; set `agent.backend_configs.paseo-claude` to `%{enabled: true, command: "node <dist>/cli.js --provider claude"}` and `PASEO_HOST`/`PASEO_PASSWORD` in the port env through the existing test config helpers (`test/support/test_support.exs`).
- Cases:
  1. `CodingAgent.start_session(workspace, backend: "paseo-claude", identifier: "repo#1")` → recorded `create_agent_request` has `config.cwd == workspace`, `labels.aiur_issue == "repo#1"`, `env["AIUR_AGENT_BIN"]` present, `config.mcpServers.aiur.type == "stdio"`; session has `thread_id` equal to the fake `agentId`, `surface.kind == "paseo"`, `session_url` starting `paseo://h/`.
  2. `run_turn/4` with scripted `timeline` events (assistant text, shell tool running and completed, reasoning) then `turn_completed {usage}` → the `on_message` callback receives `item/created` messages; feeding them through `Aiur.Claude.Transcript.extract/2` yields `:assistant`, `:command`, `:tool`, `:reasoning` events in order; result is `{:ok, %{result: ...}}` and the usage event carries `input_tokens`.
  3. Scripted foreign `user_message` → an `item/created` with `type: "user"`; `Transcript.extract/2` returns a `:user` event whose payload has `source: :phone`.
  4. Scripted `tool_call` on the MCP socket: the fake daemon script asks the sidecar to run a tools/call through the shim (the fake daemon owns a tiny MCP client for this) → core receives `item/tool/call` and `ToolExecutor` answers; assert the reply reached the fake MCP client and the `:tool_call_completed` event fired.
  5. Restart: `stop_session/1`, then `start_session` with `resume_thread_id: <agentId>` → sidecar sends `thread/resume` (PSO-007, PSO-011) → recorded `list_agents`/lookup, no new `create_agent_request`, session `resumed: true`, same `thread_id`.
  6. Fallback: start with `PASEO_HOST` pointing at a closed port → `start_session` returns `{:error, {:paseo_unreachable, _}}`; through `SessionLifecycle.start_agent_session/3` with an injected `start_fun` the fallback backend `claude` is attempted exactly once and `Aiur.Perf.event(:repl_start_fallback, backend: "paseo-claude", ...)` is observed; the attention text names `paseo_unreachable`.
- Core change owned here: add `event_from_item("user", item, turn_id, timestamp)` to `src/lib/aiur/claude/transcript.ex` returning `AgentEvents.transcript_event(:user, text, timestamp: timestamp, turn_id: turn_id, msg_id: id, payload: %{source: source_atom})` where `source_atom` is `:phone` for `"phone"` and `:executor` otherwise; skip when text is empty. Unit test in `test/aiur/claude/transcript_test.exs`.
- CI: in `ci.yml` add to the `coverage-partition` job, before the test step, `actions/setup-node` (24.18.0, cache `npm`, `cache-dependency-path: packages/aiur-paseo/package-lock.json`) and `npm ci && npm run build` with `working-directory: packages/aiur-paseo`. Document in the workflow comment why (integration test spawns the built sidecar). Keep the step under 60 s; if it is slower, cache `dist/` keyed on the package lockfile and `src/` hash.

### Part 2: manual proof

- Execute 00-design.md section 12 steps 1 to 6 on this machine with the real Paseo daemon and a `--test` issue labelled `model:paseo-claude`, then once more with `model:paseo-codex` for steps 3 and 4.
- Record `docs/build-order/paseo/evidence/<YYYY-MM-DD>-e2e.md`: the exact commands, the `aiur status --json` excerpt showing `surface`, the sidecar stdout excerpt for `emit_alert` round trip, `pgrep -af "claude|codex"` output showing one provider process parented by the daemon, the restart re-attach showing the same `agentId`, and the fallback attention text. Screenshots under `docs/build-order/paseo/evidence/<date>/` for: Paseo web UI or desktop app agent view, the opencode pane with a phone-originated user row, the dashboard row with 📱 Paseo.
- Update the status block in `docs/build-order/paseo/README.md` with the evidence path and date.

## Non-goals

- New sidecar features; any gap found is filed against the owning PSO ticket or as a follow-up, and this ticket lands the test with the case marked `@tag :skip` and the issue number.
- Permission bridging (PSO-014), mid-run move (PSO-015).
- Making the integration test run without Node; it skips with a reason.

## Existing owner and reuse target

`Aiur.AppServer.GenericBackend` (PSO-001, PSO-007) is exercised, not modified. `Aiur.Claude.Transcript` gains one clause. The package's fake daemon (PSO-006) gains a CLI wrapper. Test helpers in `test/support/test_support.exs` for config overrides are reused.

## Contract and invariants

- The integration test passes against the built package at the same commit; a protocol drift between core and sidecar fails here first.
- The evidence file is dated, names the daemon version (`paseo --version`), the sidecar version, and the aiur commit.
- Fallback engages once and only once; a second failure surfaces as the normal spawn error.

### Requirements

- PSO-012-R1. An integration test drives the real sidecar binary through core's backend against the fake daemon and covers create, turn, phone message, tool round trip, resume, and fallback.
- PSO-012-R2. `Aiur.Claude.Transcript` renders `item/created {type: "user", source}` as a `:user` event with `payload.source`.
- PSO-012-R3. CI builds the package before the Elixir partitions so the test runs, and the test skips with a clear reason when the build is absent locally.
- PSO-012-R4. The manual proof in 00-design.md section 12 is executed for claude and codex and recorded under `docs/build-order/paseo/evidence/`.
- PSO-012-R5. The pack README status names the evidence.

## Refreshable implementation notes

- Free port: bind `:gen_tcp.listen(0, ...)`, read the port, close, pass to the script.
- Start the fake daemon with `Port.open({:spawn_executable, node}, [:binary, :exit_status, args: [...], line: 4096])` and wait for `READY`.
- The sidecar reads `PASEO_HOST` and `PASEO_PASSWORD` from its environment; set them through the `env:` option that `Aiur.AppServer.Adapter.start_port/4` forwards (`port_env/1`), or through `telemetry_launch: %{env: ...}` as `Aiur.Claude.CodingAgent.start_port/3` does.
- For the tool round trip, the fake daemon script step `{callTool: {name: "emit_alert", arguments: {...}}}` makes the fake daemon connect to the socket path it saw in `mcpServers.aiur.args[1]` and send an MCP `tools/call`.
- Screenshots: the Paseo web UI needs `paseo daemon start --web-ui`; the desktop app deep link is `paseo://h/<serverId>/agent/<agentId>`.

### Key technical decisions

- Test the real binary, not a fake sidecar: the point of this ticket is the contract between two packages at one commit.
- One `async: false` test module rather than many: it owns two child processes and env.
- The `user` transcript clause lives in core because rendering is core's job; it is the only Elixir change here and is under ten lines.

## Acceptance and verification

### Agent gate

- `mix test test/aiur/app_server/generic_backend_paseo_test.exs` green locally with the package built; skips cleanly with `rm -rf packages/aiur-paseo/dist`.
- `mix test test/aiur/claude/transcript_test.exs` covers the `user` clause for `phone` and `executor` sources and empty text.
- `make all` in `src/` green; `mix specs.check` green.
- `npm test` in the package green (the fake-daemon CLI has a smoke test).

### At-merge gate

- CI green on the exact head, including the new build step in all four partitions and the package job.
- Evidence file and screenshots committed; README status updated.

### Human/manual evidence

- 00-design.md section 12 executed on this machine for both providers; the evidence file is the deliverable. The Executor reads it and opens the recorded deep link on a phone or the desktop app to confirm the agent is visible and answers a message.

## Failure, security, migration, and accessibility cases

- The evidence file must not contain `PASEO_PASSWORD`, bearer tokens, or the relay pairing offer; redact deep links only to the extent they embed nothing secret (they do not).
- The integration test must kill the fake daemon and the sidecar on exit (`on_exit` with `Port.close` plus `kill -TERM` by os pid) so a failing run leaves no orphans; assert `pgrep -f fake-daemon.mjs` is empty after the module.
- If the CI build step fails, the partition fails loudly; it must not silently skip the test in CI (set `AIUR_REQUIRE_PASEO_SIDECAR=1` in CI so the skip becomes a failure).

## Surfaces

- Reads: sidecar stdout frames; fake daemon recordings; `aiur status --json`; Paseo UI.
- Writes: `test/aiur/app_server/generic_backend_paseo_test.exs`, `transcript.ex` clause and test, `ci.yml` step, `packages/aiur-paseo/scripts/fake-daemon.mjs`, `docs/build-order/paseo/evidence/*`, README status.
- Contracts: 00-design.md section 6 and section 12.

## Sibling boundaries and open gates

PSO-009, PSO-010, PSO-011 own sidecar behaviour; PSO-001, PSO-003, PSO-007 own core behaviour. This ticket only proves them together and adds the one transcript clause. PSO-013, PSO-014, PSO-015 depend on this proof.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
