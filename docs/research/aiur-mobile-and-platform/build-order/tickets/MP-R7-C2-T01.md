---
ticket_id: MP-R7-C2-T01
feature_id: MP-R7
chunk_id: MP-R7-C2
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Declare per-harness delivery primitives (registry data + pure descriptor)
status: ready
blocked_by: [DESIGN-R7, MP-R7-C1-T01, MP-R7-C1-T03, MP-R7-C1-T04]
soft_conditions: ["PR #2870 (Gemini/ACP, draft): if merged before this ticket starts, add the gemini row (RC-22); otherwise leave a future-adapter note. Not a hard block."]
prior_units: [U4]
prior_boundaries: [CA (20)]
prior_features: []
prior_findings: [MP-R7 plan F2, F4, F8, F9; RQ-R7-1 and RQ-R7-4 resolved]
size_owner: "Aiur core / coding agent (registry data only; coding_agent.ex not edited)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C2-T01 — Declare per-harness delivery primitives

## Identity and outcome

- Bucket 1, MP-R7, chunk C2, ticket T01.
- **User value:** none visible. Gives MP-E7 (listener modes) and MP-E2 (native
  questions) one place that says what each harness *can* do, so neither feature
  branches on harness names.
- **Deliverable:** (a) an optional `:delivery` map in each provider registry
  entry, holding only facts that cannot be derived; (b) a pure module
  `Aiur.Harness.Capabilities` (PROPOSED, `src/lib/aiur/harness/capabilities.ex`)
  whose `delivery_primitives/1` returns the harness-adapter contract §3
  descriptor; (c) a table test equal to the values below.
- **Non-goals:** no caller reads the descriptor yet (C2-T03 exposes it);
  `issue_control_capabilities/3` and every delivery path are unchanged.

## Dependencies and blockers

- **DESIGN-R7**; C1-T01 (contract test extended here), C1-T03 (RQ-R7-4
  evidence), C1-T04 (suite run before/after).
- Concurrent with C2-T02 (different files: `backend.ex` vs providers).
  C5-T01 may run in parallel.
- RC-22 soft condition: Gemini row (below).

## Verified starting point (base `45a290e3`)

- Registry entries: `coding_agent/providers/codex.ex:9-80`,
  `providers/claude.ex:8-79` (headless) and :81-127 (repl),
  `providers/muse.ex:8-50`, `open_ai_compat/registry.ex:107-130` (shared
  defaults for `kimi`, `deepseek`, `openrouter`), `providers/fake.ex` (test).
- The entry type already admits extra keys (`optional(atom()) => term()`,
  `backend.ex:114`) and the moduledoc rule says variance is "a declared
  capability in the registry entry" (`backend.ex:11-14`). Pattern for
  optional-key accessors with defaults: `coding_agent.ex:997-1133`.
- Derivable today: `can_interrupt`, `immediate_delivery`, adapter export of
  `interrupt/1` (only `Aiur.Claude.ReplAgent`, `claude/repl_agent.ex:113`).
- Not derivable (needs declaration): transport kind, mid-turn inject, aiur
  tool reach (pull), hook boundaries.

Evidence for each declared value:

| Fact | Evidence |
| --- | --- |
| codex/claude transport = app-server stdio | `providers/codex.ex:21`, `providers/claude.ex:19`; shared `Aiur.AppServer.*` |
| claude-repl transport = tmux pane | `claude/repl/operator_inject.ex:38-39` (`Tmux.send_keys_literal`) |
| muse transport = MSP stdio | `muse/coding_agent.ex:1-27`, `muse/transport.ex` |
| openai-compat = in-process HTTP | `open_ai_compat/coding_agent.ex:135` (`Transport.complete`) |
| codex/claude: no non-cancelling mid-turn input | single-writer lock `app_server/operator_delivery.ex:41-51`; urgent path is `turn/interrupt` (`app_server/interrupts.ex:40-53`) |
| claude-repl: native mid-turn input (**RQ-R7-1 resolved, docs**) | Claude Code docs, "Queue messages while Claude works": "if you queue a message while Claude is running tool calls, Claude Code passes it to Claude as soon as those tool calls finish, within the same turn" — https://code.claude.com/docs/en/interactive-mode, accessed 2026-10-06 (page cites features of v2.1.275). aiur types into the pane with no Esc/Ctrl+C (`operator_inject.ex:14-43`). Caveat: aiur does not pin the `claude` CLI version (`providers/claude.ex:92`); a foreground capture is owned by MP-E7-C4 (claude-repl steer ticket) |
| muse: no steer used | aiur sends `ifBusy: "queue"` (`muse/coding_agent.ex:24`); a `steered` receipt is accepted (`muse/protocol.ex:86-89`) but an `ifBusy` steer value is unverified (RQ-E7-2) |
| openai-compat: native mid-turn inject (**RQ-R7-4 resolved, code**) | `open_ai_compat/coding_agent.ex:222-244` defers + flushes operator text after each tool result inside the turn; test `open_ai_compat/coding_agent_test.exs:638` |
| pull tool reach | codex/claude get `DynamicTool.tool_specs()` (`codex/frames.ex:52`, `claude/coding_agent.ex:234`); muse gets the aiur MCP server (`muse/session.ex:75`); openai-compat includes them (`open_ai_compat/tool_spec.ex:109`); claude-repl has no `--mcp-config` (`claude/repl/command.ex:28-36`) |
| hook boundaries (claude-repl) | `claude/hook_settings.ex:13-15`: `UserPromptSubmit`, `PostToolUse`, `Stop` (+`StopFailure`) |
| native_question = none everywhere | Codex auto-answers `requestUserInput` (harness-adapter contract §6.1); Muse maps `userInput/request` to `:native_user_input_required` (`muse/turn_loop.ex:116-120`) |

## Chosen design

Declared data plus derived fields; derivation never reads a backend name.

```text
delivery_primitives(backend_key) :: {:ok, descriptor} | {:error, :unknown_backend}
descriptor = %{
  harness_id, transport,                         # declared (default :unknown)
  turn_boundary_start: adapter exports run_turn/4,
  mid_turn_inject: declared, default :none,
  hard_interrupt: cond do
                    not can_interrupt -> :none
                    adapter exports interrupt/1 -> :out_of_band
                    true -> :in_band end,
  native_queue: immediate_delivery == true,
  pull_tool: declared, default false,
  hook_boundaries: declared, default [],
  native_question: declared, default :none }
```

Unknown backend returns `{:error, :unknown_backend}`, never a guessed profile
(AGENTS.md "A collapsed cause names the collapse at the source").

Values this ticket must produce (and nothing more):

| harness | transport | turn_boundary_start | mid_turn_inject | hard_interrupt | native_queue | pull_tool | hook_boundaries | native_question |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| codex | app_server_stdio | true | none | in_band | false | true | [] | none |
| claude | app_server_stdio | true | none | in_band | false | true | [] | none |
| claude-repl | tmux_pane | true | native | out_of_band | true | false | [prompt, tool, stop] | none |
| muse | msp_stdio | true | none | in_band | false | true | [] | none |
| kimi / deepseek / openrouter | in_process_http | true | native | none | false | true | [] | none |
| fake (test) | :unknown (no declaration) | true | none | none | false | false | [] | none |
| gemini (only if PR #2870 merged; RC-22) | acp_stdio | true | none | in_band | false | true | [] | none |

Gemini evidence is at "PR #2870 @ c1fc6f84", not `45a290e3`:
`providers/gemini.ex` (`can_interrupt: true`, `safe_checkpoints: []`,
`default_command: "gemini --acp"`), `gemini/coding_agent.ex:20`
(`send_operator_message` → `{:error, :gemini_messages_require_queued_turn}`),
`gemini/turn.ex:103-112,220-223` (urgent → ACP `session/cancel`),
`gemini/turn.ex:17` (aiur MCP bound per turn). Provisional until re-read at
merge.

## Implementation steps

1. Add `delivery:` maps to `providers/codex.ex`, both entries in
   `providers/claude.ex`, `providers/muse.ex`, and the shared `entry/2`
   defaults in `open_ai_compat/registry.ex:107-130` (one map covers the three
   OpenAI-compatible backends). Comment each value with its evidence line.
2. Document `:delivery` in the `capabilities` typedoc (`backend.ex:58-79`) and
   add `optional(:delivery) => map()` to the type (doc/type only).
3. Create `src/lib/aiur/harness/capabilities.ex` with
   `delivery_primitives/1` (by key, reading `Aiur.CodingAgent.Registry.entries/0`)
   and `delivery_primitives_for_entry/2` (key + entry, for tests).
   Allowed value sets as module attributes; ≲ 90 lines.
4. Extend C1-T01's registry contract test: when `:delivery` is present its
   keys ⊆ the five declared fields and each value is in its allowed set.
5. Add `src/test/aiur/harness/capabilities_test.exs` (PROPOSED) with the table
   above as data. **RC-22 step:** if #2870 is merged when this ticket starts,
   add the gemini row and its `delivery:` map in `providers/gemini.ex`;
   otherwise add the comment `# future adapter: gemini (PR #2870)` above the
   table.
6. Update the harness-adapter contract §3 table to these values (the
   coordinator applies the contract edit; this ticket's PR quotes it).

## Non-happy paths

- Unknown key → `{:error, :unknown_backend}` (tested).
- Missing `:delivery` → conservative defaults, never `:native`/`true` (fake row).
- Fallback and RC promotion change the *running* backend; this function is by
  key only, and C2-T03 chooses which key (the running one).
- No runtime path reads `:delivery` yet, so a wrong value cannot change
  behaviour in this ticket; C1 suite must be unchanged.

## Compatibility and rollout

Additive registry data and a new module; no config, CLI, flag or rendered
change (DESIGN-R7 §1). Rollback: revert the PR.

## Verification

- `Aiur.Harness.CapabilitiesTest`:
  - `delivery primitives match the declared table for every registered harness` — new behaviour; fails before the change (module absent).
  - `an undeclared entry gets conservative defaults` (fake row).
  - `an unknown backend is reported, not defaulted`.
  - `hard_interrupt is out_of_band only for adapters exporting interrupt/1`.
- Registry contract test: `delivery declarations use only known fields and values`.
- Commands (from `src/`):
  `mise exec -- mix test test/aiur/harness/capabilities_test.exs test/aiur/coding_agent/registry_contract_test.exs`
  and `mise exec -- mix test --only r7_characterization` (unchanged count, all pass).
- Mutation witnesses: set `mid_turn_inject: :none` in the openai-compat
  defaults → table test fails; drop the `interrupt/1` export check in the
  derivation (always `:in_band`) → claude-repl row fails; replace the
  `{:error, :unknown_backend}` branch with the fake profile → unknown-backend
  test fails.

## Completion and handoff

- [ ] Registry `delivery:` maps with evidence comments; module + tests green.
- [ ] C1 suite count identical before/after (quoted in PR body).
- [ ] Gemini row added or future-adapter note left (RC-22), stated in PR body.
- Docs: none user-facing. Contract table update (harness-adapter §3) via the coordinator.
- Dependents: C2-T03, MP-E7-C2-T02 (effective-mode computation), MP-E7-C4, MP-E2.
