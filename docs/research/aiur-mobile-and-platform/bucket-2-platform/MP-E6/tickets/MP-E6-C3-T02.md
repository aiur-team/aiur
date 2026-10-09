---
ticket_id: MP-E6-C3-T02
feature_id: MP-E6
chunk_id: MP-E6-C3
bucket: 2-platform
title: aiur voice setup [--repair] creates or repairs the private ElevenLabs agent
status: blocked
blocked_by: [DESIGN-E6, E6-OQ7, MP-E6-C1-T01, MP-E6-C3-T01, MP-E6-C2-T02]
prior_units: []
prior_boundaries: [VOX, CTL]
prior_features: [integrations-51]
prior_findings: []
size_owner: launcher (aiur-engine.sh, 4,260 lines — add one dispatch case and one small cmd function)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C3-T02 — `aiur voice setup`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C3.
- **User value:** one command creates the provider agent with privacy settings aiur can
  trust (no audio recording, shortest retention, overrides enabled), instead of the operator
  clicking through a web console and getting a privacy flag wrong.
- **Deliverable:** CLI `aiur voice setup [--repair] [--json]` →
  `run_control_rpc "Aiur.VoiceCLI.setup([...])"`; `Aiur.VoiceCLI.setup/1` (PROPOSED,
  `src/lib/aiur/voice_cli.ex`) that:
  - without `voice.conversation.agent_id`: `POST /v1/convai/agents/create` with the fixed
    settings below and prints the new `agent_id` and the exact line to add to
    `.aiur/config` (it does **not** edit the config: `.aiur/config` is operator-owned);
  - with an `agent_id`: `GET` the agent, compare to the fixed settings, print each mismatch;
    with `--repair` `PATCH` the mismatched fields.
- **Non-goals:** per-session preflight (C3-T03); key setup (MP-R5 / `aiur init`).

## Dependencies and blockers

- **Owner:** DESIGN-E6 (setup output is a user-facing surface, DESIGN-E6 §2 "Settings (or
  setup output)"), E6-OQ7 (LLM).
- **Spike:** MP-E6-C1-T01 confirms the request body accepted by `agents/create` and the
  retention field semantics (RQ-E6-3).
- **Predecessors:** C3-T01, C2-T02 (http seam and error mapping).

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| CLI pattern | `cmd_github_cost` parses flags and calls `run_control_rpc "Aiur.AgentControlCLI.github_cost([...])"` (`aiur-engine.sh:3032-3064`); dispatch table `case` (`:4142-4150`); usage text (`:465`) |
| Dedicated CLI module precedent | `Aiur.BuildOrdersCLI` (`src/lib/aiur/build_orders_cli.ex`, called by `cmd_build_orders`, `aiur-engine.sh:2961`) |
| Agents API | `POST /v1/convai/agents/create` with `conversation_config` and `platform_settings` (<https://elevenlabs.io/docs/api-reference/agents/create>, accessed 2026-10-06); audio storage flag `platform_settings.privacy.record_voice` (<https://elevenlabs.io/docs/agents-platform/customization/privacy/audio-saving>) |

## Chosen design

Fixed agent settings (aiur owns these; the operator cannot loosen them through aiur):

| Setting | Value |
| --- | --- |
| `platform_settings.privacy.record_voice` | `false` |
| retention | shortest value the spike shows is honoured (RQ-E6-3) |
| overrides enabled | `agent.prompt.prompt`, `agent.first_message`, `tts.voice_id` (and `agent.prompt.llm` if E6-OQ7 wants per-session choice) |
| LLM | `voice.conversation.llm` |
| client tools | the C5 tool list (names, descriptions, JSON schemas) with `expects_response: true` |
| audio formats | input `pcm_16000`; output `pcm_16000` (contract §3.6) |
| name | `aiur voice assistant (<instance label>)` |

- Output (text) per DESIGN-E6 copy; `--json` prints `{agent_id, created|ok|mismatches:[…],
  repaired:[…]}`.
- Exit codes: 0 ok, 1 mismatch without `--repair`, 2 provider/auth error, 64 usage (engine
  convention, `aiur-engine.sh:3042-3054`).

## Implementation steps

1. `cmd_voice` in `aiur-engine.sh` with subcommands `setup` (this ticket) and `transcripts`
   (MP-E6-C6-T03); add to usage and dispatch.
2. `Aiur.VoiceCLI.setup/1` with injected http.
3. `website/docs-app/reference/cli.md` entry; `apis/elevenlabs.md` Agents permission row (in
   this PR because the command needs it).

## Non-happy paths

- No key → exit 2 with the existing "not configured" guidance.
- Key without Agents permission → exit 2 naming the missing permission.
- Agent deleted at the provider → treat as "no agent", offer create (prints, does not edit
  config).
- Partial repair failure → reports per-field outcome; exit 2.

## Compatibility and rollout

New command; no effect unless run. Works with `--no-dashboard` (control RPC only). Rollback:
revert.

## Verification

| Test (`test/aiur/voice_cli_test.exs`) | Expected |
| --- | --- |
| "setup without an agent id creates a private agent" | fake http receives `record_voice: false` and the override flags; output names the new id and the config line |
| "setup reports each mismatch and exits 1" | fixture agent with `record_voice: true` |
| "--repair patches only mismatched fields" | PATCH body contains only those fields |
| "setup never edits .aiur/config" | config file mtime unchanged (temp dir) |
| `src/test/aiur_engine_test.exs` "voice without a subcommand prints usage" | `aiur voice` without a subcommand exits 64 |

```bash
env -C src mise exec -- mix test test/aiur/voice_cli_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Send `record_voice: true` in the create body: the first test fails.

## Completion and handoff

- [ ] CLI, RPC module, docs (`cli.md`, `elevenlabs.md`).
- **Dependents:** MP-E6-C3-T03, MP-E6-C9-T01.

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- Provisioning logic (create/update the provider agent with `record_voice=false` and the
  shortest retention) moves to the core as `VoiceConverse.Provider.ElevenLabsAgents.Provision`.
  It is exposed as `mix voice_converse.setup` for standalone hosts. `aiur voice setup
  [--repair]` is a thin CLI wrapper that builds the struct and calls the same function.
