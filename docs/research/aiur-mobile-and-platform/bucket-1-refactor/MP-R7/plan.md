---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-R7
bucket: 1-refactor
base_main_sha: 45a290e3
date: 2026-10-06
owns_contracts: [harness-adapter]
consumes_contracts: [identity, capabilities, events]
owner_gate: DESIGN-R7
---

# refactor: Harness adapter package (MP-R7)

## Summary

Extract aiur's per-harness shims (Codex app-server, Claude through the
`aiur-claude` sibling, the Claude persistent REPL, Muse, the OpenAI-compatible
backends) behind one harness-adapter interface and package. This is
behaviour-preserving. Most of the seam already exists:
`Aiur.CodingAgent.Backend` is a real `@behaviour` with a registry. The work is
to (1) pin today's delivery behaviour with characterization tests, (2) declare
the delivery primitives each harness actually has, (3) remove the upward leaks
from runner, orchestrator and workspace into backend internals, and (4) move
the adapters into a package once MP-R1 fixes the physical layout.

R7 is the substrate for MP-E7 listener modes (D14) and for MP-E2 native
question capture (D10). It adds no listener mode and captures no questions.
Chunks and tickets are in [chunks.md](chunks.md). The contract draft is
[../../contracts/harness-adapter.md](../../contracts/harness-adapter.md).

---

## Problem Frame

- Delivery semantics are spread over five layers (entry point, queue item,
  orchestrator policy, runner drain, backend). Each entry point picks its own
  default policy (see Finding F3). MP-E7 cannot set a mode per agent until one
  interface states what each harness can do.
- The runner, orchestrator and workspace call backend internals directly
  (Finding F5), so a backend cannot be packaged, and the prior refactor
  research names the same cycles (boundaries 17–24).
- OpenCode is called a "harness" in the brief. It is not one (Finding F6).
  Packaging it as an adapter would create a false boundary.

---

## Repository findings (verified at `45a290e3`)

All paths are repo-relative. The baseline sections E2/E3/E4 in
[../../baseline/capability-baseline.md](../../baseline/capability-baseline.md)
are not repeated here.

**F1. The adapter seam exists.** `src/lib/aiur/coding_agent/backend.ex:1-148`
defines callbacks `start_session/2`, `run_turn/4`, `stop_session/1`,
`normalize_event/1`, `send_operator_message/2` and optional `interrupt/1`
(:117-147), and a `capabilities` registry-entry type (:80-115) with delivery
flags `can_interrupt`, `safe_checkpoints`, `immediate_delivery`,
`control_application_confirmation`, `remote_control`, `remote_transport`,
`fallback_backend`, `resumable`. The moduledoc (:5-15) states the rule that a new
backend needs only an adapter module and a registry entry.

**F2. Harness inventory.** `src/lib/aiur/coding_agent/registry.ex:7-16` registers:

| Key | Adapter | Transport | Delivery today | Interrupt | Resume |
| --- | --- | --- | --- | --- | --- |
| `codex` | `Aiur.Codex.CodingAgent` | `codex app-server` JSON-RPC stdio (`providers/codex.ex:21`) | `turn/start` frame (`codex/frames.ex:92-104`) at a safe checkpoint; `safe_checkpoints: [:notification, :tool_result]` (`providers/codex.ex:24`) | `turn/interrupt` (`app_server/interrupts.ex:55-73`) | `thread/resume` (`codex/frames.ex:57-69`) |
| `claude` | `Aiur.Claude.CodingAgent` | sibling `aiur-claude` app-server (`providers/claude.ex:19`) | `turn/start` (`claude/coding_agent.ex:114-139`); `safe_checkpoints: [:notification]` (`providers/claude.ex:23`) | `turn/interrupt` via shared `AppServer` | no (`providers/claude.ex:34-40`) |
| `claude-repl` | `Aiur.Claude.ReplAgent` | interactive `claude` in a tmux pane, hooks over HTTP | tmux `send-keys -l` + Enter, folded in by Claude's native input queue (`claude/repl/operator_inject.ex:31-43`); `immediate_delivery: true` (`providers/claude.ex:101-103`) | Ctrl+C out of band (`operator_inject.ex:60-62`) | `--resume` (`providers/claude.ex:117-122`) |
| `muse` | `Aiur.Muse.CodingAgent` | Muse MSP stdio | `turn/start` with `ifBusy: "queue"` (`muse/coding_agent.ex:21-27`); receipts accept disposition `started`/`queued`/`steered` (`muse/protocol.ex:87-89`) | native `turn/interrupt` (`muse/turn_control.ex:6-18`) | yes (`providers/muse.ex:31`) |
| `kimi`, `deepseek`, `openrouter` | `Aiur.OpenAICompat.CodingAgent` | in-process HTTP loop | appends a `user` message to the session's message list (`open_ai_compat/coding_agent.ex:117-123`) | none (`can_interrupt: false`, `open_ai_compat/registry.ex:113`) | no (:124) |
| `fake` | test-only (`registry.ex:20-29`) | — | — | — | — |

**F3. Delivery policy is chosen by the entry point, not by the agent.**
- Policies: `:immediate`, `:checkpoint`, `:interrupt`, plus `:auto`
  (`orchestrator/operator_messages/delivery_policy.ex:14-48`). Accepted sets
  per agent: `[:immediate]` when `immediate_delivery`, else
  `[:checkpoint, :interrupt]` or `[:checkpoint]`
  (`operator_messages/capabilities.ex:79-81`).
- Queue item shape: `:interrupt` sets `interrupt_requested`, priority `:now`;
  `:immediate` sets `consume_at: :immediate` (`agent_queue.ex:9-25`).
- Defaults by caller:

| Entry point | Policy | Evidence |
| --- | --- | --- |
| `AgentChat.send/3` (dashboard drawer, Stream Deck, `aiur message`) | `:interrupt`, fallback `:queue_next` | `agent_chat.ex:27-28`; callers `aiur_web/live/dashboard_live.ex:2693`, `aiur_web/streamdeck_channel.ex:468`, `agent_control_cli.ex:1477-1482` |
| HTTP `POST /api/v1/:id/messages` | `:checkpoint` (no policy passed; default) | `aiur_web/controllers/observability_api_controller.ex:186-192`, `orchestrator/operator_messages.ex:572` |
| TUI OpenCode chat pane | `:auto` | `opencode/chat_completions/operator_dispatch.ex:46-50` |
| Command (Decision) answers | `:interrupt`, fallback `:queue_next` | `decision_dispatch.ex:51-63` |

**F4. "Checkpoint" is effectively "turn boundary" on app-server backends.**
`app_server/operator_delivery.ex:41-51` refuses to claim or deliver a
checkpoint item while `outstanding_turns > 0` (single-writer lock, because a
second `turn/start` makes `aiur-claude` spawn a second CLI writer). The
declared `safe_checkpoints` lists therefore do not produce mid-turn delivery
for `codex` or `claude`. `:interrupt` is a hard cut: `turn/interrupt`, then the
queued item starts the next turn (`app_server/interrupts.ex:34-53`,
`app_server/turn_loop.ex:31-33`).

**F5. Upward leaks into backend internals.** Files outside
`codex/ claude/ muse/ open_ai_compat/ coding_agent/providers/` that reference
those namespaces (`git grep` at `45a290e3`) include:
`agent_runner/checkpoint_delivery.ex:13` (`Codex.SessionRecovery`),
`agent_runner/{queue_drain.ex:21,tool_executor.ex:25,turn_loop.ex:8}`
(`Codex.DynamicTool`), `agent_runner/session_lifecycle.ex:6`
(`Claude.{DisplayTailer,RemoteControl,Telemetry}`),
`app_server/adapter.ex:11-12` (`Claude.RemoteControl`, `Codex.DynamicTool`),
`orchestrator/{interrupts.ex:7,remote_control_mode.ex:7}` (`Claude.ReplAgent`),
`workspace/ownership/guardian.ex`, `process_reaper.ex`, `pause_containment.ex`,
`shutdown.ex`, `orchestrator/agent_teardown.ex`, `git.ex`, `config.ex`,
`agent_control_cli.ex`, `aiur_web/controllers/observability_api_controller.ex`.
This matches the prior survey (boundaries 18, 20–22 in
`docs/research/refactor-2026-09-26/codebase/feature-boundaries.md`).

**F6. OpenCode is a renderer and an input surface, not a harness.** The
`Opencode.*` tree is the chat-pane bridge "that pretends to be an LLM so
opencode renders agent turns" (prior boundary 24). Its only write path calls
`AgentChat.send/3` with `:auto` (`operator_dispatch.ex:46`). R7 keeps it out of
the adapter package; it consumes the adapter's events.

**F7. The `aiur-claude` sibling** (`github.com/its-everdred/claude-app-server`,
npm `aiur-claude` 1.1.0, local checkout at commit `b1ea979`) spawns
`claude --print --output-format stream-json` per turn (`src/server.ts:5`,
:690-725) and implements `turn/start`, `turn/steer`, `turn/interrupt`
(:284-286). `turn/steer` pushes text onto the *active* turn's `steer_queue`
(:505), but `turnStart` reads the queue of the *newly created* turn, which is
always empty (`createTurn` at :188-199, check at :466-469). Steered text
therefore appears to be dropped. aiur never calls `turn/steer`, so this has no
effect today; it matters for MP-E7.

**F8. Skill mounts are already registry data.** `skill_install` paths:
`.codex/skills` linked to `.claude/skills` (`providers/codex.ex:18`),
`.claude/skills` (`providers/claude.ex:16`), `.agents/skills`
(`providers/muse.ex:20`), consumed by `agent_skills.ex:46,100,121` through
`CodingAgent.skill_install_locations/0` (`coding_agent.ex:148-152`).
`claude-repl` declares none and inherits Claude's workspace copy.

**F9. Hooks exist only for `claude-repl`.** `claude/hook_settings.ex:15`
wires `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure` to a
fire-and-forget `curl -m 2` (:42-44) into
`POST /api/v1/:id/claude-hook`. The REPL launch command has no
`--mcp-config` (`claude/repl/command.ex:30-35`), so `claude-repl` does not get
aiur's dynamic tools. No Codex hooks are installed by aiur.

**F10. No Executor harness.** The Executor runs outside aiur; no adapter,
harness identity or transcript exists (baseline E3, re-checked:
`git grep -n "harness" 45a290e3 -- src/lib/aiur/executor*` returns nothing).

**F11. Tests.** 107 test files under `src/test/aiur/{codex,claude,muse,
open_ai_compat,coding_agent,app_server}`; delivery is covered by
`app_server/operator_delivery_test.exs`, `app_server/interrupts_test.exs`,
`claude/repl/operator_inject_test.exs`, `agent_chat_test.exs`,
`agent_queue_test.exs`, `agent_runner/queue_drain_test.exs`. There is **no**
registry-wide contract test asserting every entry's adapter implements the
behaviour and that capability flags are mutually consistent (searched
`src/test` for `contract|registry|backend`).

---

## Proposed boundary

```text
aiur_harness                     (package; MP-R7)
  contract   Aiur.Harness.Adapter      = today's Aiur.CodingAgent.Backend (kept as alias)
             Aiur.Harness.Capabilities = registry entry + derived DeliveryPrimitives
             Aiur.Harness.Registry     = providers register themselves
  core       Aiur.Harness.AppServer.*  = today's Aiur.AppServer.* (shared JSON-RPC core)
  adapters   codex | claude (headless, repl) | muse | openai_compat | fake(test)
required deps: aiur_kernel, aiur_config, aiur_agent_sandbox (prior boundaries 1, 2, 17)
optional deps: tmux transport (claude-repl only), telemetry signal port (prior 11)
not inside:  opencode (renderer, prior 24), agent tool surface / DynamicTool (prior 20),
             RemoteControl promotion policy (orchestrator), runner turn engine (prior 18)
```

- **Prior-units:** U4 (agent turn and backend lifecycles), U7 (physical package
  deferred), U8 owners `AGENT_CORE`, `AGENT_TURN`, `CLAUDE`, `CODEX`.
- **Prior-boundaries:** `CA` (20), `CDX` (21), `CLD` (22), `OAI` (23), with
  `RUN` (18) and agent sandbox (17) as neighbours.
- **Public interface:** the six existing callbacks plus a derived, read-only
  `delivery_primitives/1` (see contract). No new runtime callback is
  *required* in R7; optional callbacks for MP-E7 and MP-E2 are reserved in the
  contract and land in those features.

---

## Alternatives considered

| Option | Verdict |
| --- | --- |
| **A. Finish the existing `CodingAgent.Backend` seam, declare primitives, cut leaks, then move to a package (recommended).** | Smallest diff; matches July backend `@behaviour` decision and prior boundary 20 recommendation; behaviour-preserving by construction. |
| B. New `Harness` abstraction modelled on Khala's `HarnessAdapter` (`packages/agent/src/harness/adapter.ts:24-49`). | Rejected. Khala's adapter is hook-and-install oriented for externally launched sessions; aiur launches and owns its sessions. Sharing the *vocabulary* (harness id, steer/sync capability) is enough; MP-E7 shares the hook codec separately. |
| C. One adapter per transport (stdio app-server, tmux, HTTP) instead of per harness. | Rejected. Capability differences are per harness (F2), not per transport (`codex` and `claude` share a transport but differ in resume and steer). |
| D. Separate repository now. | Rejected for R7. KTD3/KTD11 keep the first seam in-process; repo split is a U7/R1 decision. |

---

## Contracts

- **Owns:** `contracts/harness-adapter.md` (MP-CT-harness-adapter).
- **Consumes (assumptions for the coordinator):**
  - *Identity* (owner TBD by coordinator, likely MP-R1): R7 assumes an agent
    session is identified by `{instance_id, ticket identifier, backend key,
    thread_id}`, and that `thread_id` may be `nil` until the first turn
    (`backend.ex:24-27`). E2/E3 need a session id distinct from the ticket.
  - *Capabilities* (MP-R1): R7 publishes per-agent `delivery_primitives`;
    R1's capability model must carry them unchanged to clients.
  - *Events* (MP-R2): R7 emits no new bus topics. Turn-boundary events stay
    in-process; MP-E7 decides whether they become bus events.

---

## Non-happy paths

- **Fallback transport:** a failed `claude-repl` spawn degrades once to
  `claude` (`providers/claude.ex:106-110`). Capabilities must be read from the
  *running* entry (as `capabilities.ex:45-47` already does), never from the
  requested backend. Characterize this.
- **RC promotion** changes transport to `claude-repl` (`providers/claude.ex:26-30`);
  primitives change with it.
- **Restart:** resume differs per harness (F2); R7 must not change the
  clean-start fallback rules (`backend.ex:29-38`).
- **Sibling drift:** `aiur-claude` is versioned separately; R7 records the
  protocol methods aiur uses as a fixture so a sibling upgrade is detectable.
- **Privacy:** no change. Executor text still goes only to the harness.

---

## Acceptance criteria

1. Every registry entry passes a new contract test: adapter implements the
   behaviour, required capability keys exist, and
   `immediate_delivery` ⇒ `safe_checkpoints == []` holds.
2. A characterization suite fixes the F3 matrix (entry point × harness →
   policy, queue item flags, provider frame) and passes unchanged before and
   after every R7 chunk.
3. `git grep` for `Aiur.(Codex|Claude|Muse|OpenAICompat).` outside the
   harness package and the agreed allowlist returns nothing; a boundary check
   runs in CI.
4. `issue_control_capabilities/3` output is byte-identical for every harness
   on the characterization fixtures.
5. No config key, CLI command, flag or rendered string changes (DESIGN-R7).
6. Manual foreground run (`aiurdev --test`) shows a chat-pane message
   delivered to a Codex and a Claude agent exactly as before (AGENTS.md
   "Manual testing").

---

## Plan-refresh note

R7 depends on MP-R1's layout decision for its physical move (chunk C4 only).
Until then, chunks C1–C3 work in place under `src/lib/aiur/`. After R7 lands:
MP-E7 and MP-E2 cite `Aiur.Harness.*` paths, not `Aiur.Codex.*`/`Aiur.Claude.*`;
`contracts/listener-mode.md` support tables key on the harness registry ids.
If U4 (prior plan) lands first, C3 rebases onto its runner contract.

---

## Open questions

**Owner (Kevin):** none blocking. Confirm DESIGN-R7 (no user-facing change).

**Research (Phase C):**
- RQ-R7-1. Does `immediate_delivery` on `claude-repl` really land mid-turn,
  or at the next prompt boundary? Needs a foreground capture.
- RQ-R7-2. Exact allowlist for F5 leaks that are legitimate (process reaper
  registration may stay as a sandbox call).
- RQ-R7-3. Does MP-R1 choose an umbrella app, path dependencies, or
  namespaces-only for the first seam? Blocks C4.
- RQ-R7-4. Does OpenAI-compat delivery at `:tool_result` already happen
  between tool rounds (a native steer-like boundary)? Read
  `open_ai_compat/coding_agent.ex` run loop and the runner checkpoint hook.
</content>
</invoke>
