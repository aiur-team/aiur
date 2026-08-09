# Spike: Complexity-Gated Agent Background Tasks / Subagents

**Status:** research and design only — no runtime behavior is proposed for this
PR.

**Review revision (PR #932, rework round):** this revision addresses the
`CHANGES_REQUESTED` review of head `e2072153` by (1) removing fixed child
quotas, one-child-per-parent accounting, and the recursive-spawn ban in favor
of topology-neutral host-pressure admission (the #1430/#1560 admission gate);
(2) re-running and version-stamping the capability matrix against the installed
codex-cli 0.146.0 and the current aiur backend registry; (3) demoting the
"non-bypassable owned proxy" from a hard safety control to an optional
cross-backend telemetry contract, with measured host-pressure admission as the
hard control; and (4) replacing the three-sample p95 measurement rule with a
pre-registered choice between a defined tail estimator and an explicit
worst-case/no-regression threshold.

## Decision summary

Do not treat higher reasoning effort or an extra prompt sentence as parallelism.
If aiur ever enables intra-ticket subagents, it must be a **backend capability
grant** — the backend must expose a real task/subagent boundary and aiur must
wire the grant through it. Child work is then just work: it counts as real
measured host pressure and is admitted through the same topology-neutral
admission gate the fleet already uses (#1430/#1560), which slows *new* admissions
when the host is saturated and never kills or forbids work already in flight.
Until the capability grant exists, ticket-level decomposition remains the
preferred way to obtain parallelism.

The smallest experiment worth considering is a **Claude headless-only canary**:
one explicitly selected complexity-5 ticket type whose children are investigation
work, gated only by the complexity/backend policy and the existing host-pressure
admission gate — not by a fixed child count or a spawn proxy that pretends to
own the backend's native boundary. Claude Code already exposes agents plus tool
allow/deny controls, aiur already *observes* Claude subagent usage in telemetry,
and the sibling `aiur-claude` adapter catalog exposes a `Task` tool whose
argument builder emits `--allowedTools`. Wiring that grant is a future
implementation prerequisite rather than an enablement switch that exists today.

---

## Brainstorm synthesis: problem, scope, and success criteria

The desired outcome is shorter elapsed time for a *single* large ticket when it
contains genuinely independent investigation or implementation work. The risk
is that a parent agent plus children consumes more memory, model capacity, and
Mix capacity than several ordinary tickets — but that risk is exactly the
quantity the #1430 host-pressure admission gate exists to bound, provided child
work is *observed* as real pressure rather than hidden behind per-parent
quotas.

In scope for a later implementation:

- A per-workflow, complexity-gated backend capability policy.
- A backend-specific enforced task-spawn path (Claude `Task` / `--allowedTools`)
  and an optional prompt nudge.
- Child work counted against the same host-pressure signals the fleet uses:
  memory, run queue, load, build leases, file descriptors, and provider limits.
- Optional cross-backend child lifecycle telemetry (start/end/cancel).
- A measured comparison with ordinary ticket decomposition.

Out of scope for this spike:

- Any schema, prompt, routing, `aiur-claude`, or runtime change.
- Shell backgrounding (`cmd &`) as a parallelism mechanism — it is unmanaged
  process fan-out, not a schedulable agent capability.
- Automatic ticket splitting without an explicit backend task request.
- Any fixed topology quota (e.g. "one child per parent", "children may not
  recurse") as a *safety* mechanism — fan-out width and depth are governed by
  host-pressure admission, exactly as they are for the rest of the fleet.

Success means a canary is measurably faster than the baseline without exceeding
the configured fleet budgets, increasing CI failures/conflicts, or degrading
the decomposed-ticket alternative.

Before funding a canary, the operator must identify at least two representative
historical or queued tickets, explain why normal decomposition was impractical
for each, and record the observed elapsed-time or coordination cost. This is a
demand-evidence gate: the feature is not justified by a hypothetical large
ticket alone.

---

## Research findings

### Capability matrix (version-stamped, re-verified this revision)

Verified against the installed `codex-cli 0.146.0` (`codex features list`) and
the current `Aiur.CodingAgent.backends/0` registry. Claude facts come from the
operator review of this PR plus the in-repo aiur telemetry contract, which pins
the Claude Code emitter version; the sibling `aiur-claude` checkout is not
present in this agent workspace, so its source is cited as version-stamped
review evidence rather than re-read here.

| Aiur backend | True subagents / task boundary | Shell backgrounding | Current enable/disable point in aiur | Design status |
| --- | --- | --- | --- | --- |
| `codex` (`codex app-server`) | **Backend-native fan-out exists:** `codex-cli 0.146.0` reports the `multi_agent` feature as `stable`/effective `true` (`codex features list`, verified in this workspace); the operator review additionally reports spawn / follow-up / interrupt / list operations on the app-server surface. **No aiur-owned boundary:** `Aiur.Codex.CodingAgent` drives `codex app-server` via `Aiur.Codex.AppServerPort` and never enables or routes `multi_agent`; it only appends `--config model` / `--config model_reasoning_effort`. | A shell can use `cmd &`, but it is not a schedulable child-agent capability. | `src/lib/aiur/codex/app_server_port.ex` builds the app-server command; there is no `--enable multi_agent` or task-routing seam today. | Unsupported in v1. The capability is real but unexposed to aiur; do not offer an `enabled` setting that implies it works. |
| `claude` (headless via `aiur-claude`) | **Yes.** Claude Code (emitter version `claude-code-2.1.210` per `Aiur.Claude.Telemetry.Contract`; the review cited Claude Code 2.1.179) exposes agents plus tool allow/deny controls. The sibling `aiur-claude` app-server adapter catalog exposes a `Task` tool and its argument builder emits `--allowedTools` for dynamic tools (operator review; sibling source absent in this workspace). aiur already recognizes `subagent` query sources and the built-in `Explore`/`Plan` subagents in `Aiur.Claude.Telemetry.Contract`. | Possible, but not a supported parallelism mechanism. | `src/lib/aiur/claude/coding_agent.ex` sends `"permissionMode"` only (`permissionMode` at `claude/config.ex`); it does not yet pass `--allowedTools` or a task policy to `aiur-claude`. | Candidate for the first canary only after the real `--allowedTools` / task-policy grant is wired through the adapter. |
| `claude-repl` | Native Claude agents exist at the CLI, but **no per-ticket task policy seam in aiur**: the REPL drives the `claude` CLI directly (`src/lib/aiur/claude/repl/command.ex`) with permission mode and resume behavior. Tool allow/deny would be a CLI policy argument aiur does not currently construct. | Possible, but unmanaged. | `src/lib/aiur/claude/repl/command.ex` constructs the direct CLI command; no task-policy argument today. | Explicitly excluded from v1 (remote-control promotion fails closed for this feature). |
| OpenAI-compat backends (`kimi`, `deepseek`, `openrouter`) | No. Chat-completions/responses transports with no agent or multi-agent primitive, hence no task boundary at all. | Not applicable. | `src/lib/aiur/open_ai_compat/registry.ex` registers the entries merged into `Aiur.CodingAgent.backends/0`. | Excluded. No setting can grant what the transport cannot express. |

The production backend registry in `src/lib/aiur/coding_agent.ex` is `codex`,
`claude`, `claude-repl`, plus `Aiur.OpenAICompat.Registry.entries()` (`kimi`,
`deepseek`, `openrouter`). A registry entry (even the sibling catalog's `Task`)
is not proof that a tool is permitted at runtime: the Claude CLI's tool policy
and task lifecycle must be observable to aiur before this feature can be safe,
and for codex the `multi_agent` feature flag plus its task routing must be
wired into the adapter, not just present in the CLI.

### Complexity and prompting are separate from capability

`complexity:N` is already parsed as the highest well-formed label by
`Aiur.CodingAgent` and routed through `agent.routing`; the grammar in
`src/lib/aiur/config/routing_value.ex` carries backend, model, effort, and
`+remote`. Effort is backend-native reasoning depth, not tool availability.

First-turn prompts are assembled in `Aiur.AgentRunner.TurnLoop` through
`Aiur.AgentRunner.TurnPrompt.build_turn_prompt/4`, which delegates to
`PromptBuilder` on a cold first turn. Existing `agent.complexity_prompts` are
guidance strings. They can explain an already-granted capability, but cannot
make a forbidden tool appear or reliably keep a resource-sensitive action
within budget.

This distinction matches the repository's enforcement direction: the build
gate and Mix scheduler cap exist because prompts alone did not bound expensive
work. The current gate injects `BASH_ENV` and lease settings from
`Aiur.AgentEnvironment.workspace_env/1`; `src/priv/build_gate.bash` serializes
`mix compile`, `mix test`, and `mise exec -- mix …` through shared leases.
`AgentEnvironment` also injects `ELIXIR_ERL_OPTIONS` with the configured
`agent.mix_scheduler_cap` (default four).

---

## Proposed configuration contract

This is a proposed YAML shape, not a change to the current schema. It grants a
capability; it does **not** encode topology quotas.

```yaml
agent:
  parallelism:
    enabled: false
    min_complexity: 5
    backends: [claude]
    prompt_nudge: true
```

Semantics:

1. Omitted or `enabled: false` grants no task capability and adds no prompt
   guidance. This must be the default.
2. An issue is eligible only when its resolved **final session transport** is
   in `backends`, its `complexity:N` level is at least `min_complexity`, and it
   is present in the rollout allowlist. The resolver runs after remote-control
   transport selection; a `+remote` route, `model:remote`, or global
   remote-control promotion to `claude-repl` fails closed for this feature.
   Model override labels do not bypass the final-backend check.
3. The backend registry owns whether a backend can honor this setting. A
   configuration mentioning `codex`, `claude-repl`, or an OpenAI-compat backend
   must fail validation until that backend declares an enforced capability
   adapter (`codex` has a real but unwired `multi_agent`; the others have no
   task boundary).
4. Fan-out width and recursion are **not** fixed by this config. They are
   bounded by the same topology-neutral host-pressure admission the rest of the
   fleet uses (#1430): a child spawn is admitted only while the host has
   headroom, and children that are already in flight are never killed or
   forbidden when pressure rises. An operator *may* cap fan-out locally as a
   preference, but a per-parent quota is never the safety mechanism and must not
   be marketed as one.
5. `prompt_nudge` is a best-effort flag: when a granted policy exists, the
   first-turn builder may append a short nudge to use the granted capability
   for independent work while the parent owns integration and final
   verification. It is disabled unless the capability was actually granted; a
   nudge is never the enforcement point.

The implementation would add a normalized `parallelism` embedded config beside
`routing` and `complexity_prompts` in `src/lib/aiur/config/schema/agent.ex`.
A pure eligibility helper should use the existing `CodingAgent.complexity_level`
and resolved backend rather than reparse labels elsewhere. Complexity is
therefore a coarse outer gate, not evidence that arbitrary ticket work is
independent.

The configuration does **not** use an `effort` field. `RoutingValue` already
shows why: effort belongs to model selection and must not be overloaded into a
tool-authority switch.

---

## Enforced policy versus best-effort guidance

| Concern | Must be hard code/config | May be prompt guidance |
| --- | --- | --- |
| Whether `Task` exists for this turn | Backend capability resolver plus the backend's actual tool policy (`aiur-claude` `--allowedTools`; codex `multi_agent` wiring); deny by default. | Explain that the capability is available only when granted. |
| Which tickets may request it | Normalized config, resolved backend, and complexity threshold. | Suggest considering it only for independent work. |
| Fan-out width and recursion | **Topology-neutral host-pressure admission** (`DispatchPolicy.admission_gate/1`): defer new spawns/admissions when memory, run queue, load, build pressure, FDs, or provider limits saturate. No fixed per-parent quota, no recursion ban, no killing of in-flight children. | Ask the parent to keep ownership of final integration. |
| Mix/CPU/memory safety | Shared `max_concurrent_builds` lease, `mix_scheduler_cap`/`ELIXIR_ERL_OPTIONS` inheritance, and the host-pressure admission gate. Child build work must hold the same global lease as any other fleet work. | Explain why read-only research is the v1 child class. |
| Quality and completion | Parent-owned diff integration, scoped checks, CI, and ordinary review. | Give the child a narrow deliverable and request a concise handoff. |
| Observability | Optional cross-backend child lifecycle telemetry (start/end/cancel) — **observability, not a capability gate**. aiur already observes Claude `subagent` sources in telemetry. | — |

The critical correction from this review round: the previously proposed
"non-bypassable owned proxy" is **not** the hard safety control, because it
cannot sit on either backend's native spawn boundary — dynamic MCP tools do not
wrap Claude `Task`, and there is no owned boundary around Codex native
multi-agent today. The hard safety control is measured host-pressure admission,
which is topology-neutral and already shipped by #1430. If child lifecycle
telemetry is useful, specify an optional cross-backend start/end/cancel event
contract without making it a capability gate.

---

## Required resource accounting

The host has observed CPU spikes from compile/test/lint and becomes
memory-constrained around a large fleet; the 2026-07-31 capacity run measured
saturation near ~19–20 concurrent agents on a 16-core host (load ~14 of 16), and
`Config.default_max_concurrent_agents/1` derives the default ceiling from that
(`schedulers + schedulers / 4`). A parent plus children must not be able to
exceed the very controls intended to protect the fleet — but the answer is to
make child work *visible* to the existing controls, not to ban it.

1. **Host-pressure admission is the hard safety control (topology-neutral).**
   `DispatchPolicy.admission_gate/1` (`src/lib/aiur/orchestrator/dispatch_policy.ex`,
   added by #1430/#1560) reads measured host state — available memory
   (`agent.min_free_memory_mb`), file descriptors (10% reserve), instantaneous
   run queue (`agent.run_queue_threshold`), 1-minute load
   (`agent.max_load_average`/`target_load_average`), **concurrent build
   pressure** (`BuildGate.status/0` active/queued leases), and configured
   provider limits — and returns `:dispatch` or `{:hold, signal}`. Because it
   reads the whole host rather than per-parent topology, subagent-spawned
   mix/compile/test work raises the same signals and slows new admissions the
   same way ordinary fleet work does. It limits **new** admissions only: running
   agents and agent-spawned sub-agents are never terminated
   (`website/docs-app/reference/configuration.md`, "Host-pressure fleet
   admission"). This is the requirement: child spawns are admitted under the
   same gate, so intra-agent fan-out cannot silently exceed the memory/CPU
   ceiling without being seen.
2. **Build leases and scheduler caps stay per-process and shared.** The #881
   build gate serializes `mix compile`/`mix test`/`mise exec -- mix …` through
   shared leases owned by the shell hook, so a child `mix` command naturally
   holds one global `max_concurrent_builds` slot and raises `BuildGate.status/0`
   `active`/`queued` — which feeds the admission gate above. Children must
   inherit the same `BASH_ENV`, `AIUR_BUILD_GATE_*`, `ELIXIR_ERL_OPTIONS`, and
   `AIUR_AGENT_MIX_SCHEDULERS` policy as the parent
   (`AgentEnvironment.workspace_env/1`), so no child can clear or bypass the
   scheduler cap. The future spawn contract needs direct Mix and
   `mise exec -- mix` child tests.
3. **Spawn-side admission, not post-hoc reading.** Reading load *after* a child
   starts is too late for burst prevention. A child spawn should be admitted
   (or deferred) through the same `admission_gate` path as a new ticket, so a
   spawn is denied while the envelope has no headroom. This is the only "gate
   at the spawn boundary" the design keeps, and it is topology-neutral: it
   never counts children per parent, it just refuses to add more concurrent work
   to an already-saturated host.
4. **Lifecycle hygiene is not a topology gate.** Parent cancellation should
   tree-reap descendants through the existing containment/reaper path, and
   child reservations/telemetry must be released on completion, abort, timeout,
   or reaper cleanup so the dashboard/status count stays truthful. This is
   correctness, not a per-parent quota.
5. **Optional child telemetry contract.** If child telemetry is useful, specify
   an optional cross-backend start/end/cancel event contract (parent ticket,
   child identity, started/completed/cancelled state, peak live children) purely
   as observability. aiur already parses Claude `subagent` query sources and the
   built-in `Explore`/`Plan` subagents in `Aiur.Claude.Telemetry.Contract`, so
   the Claude side of this is partially present today. Missing telemetry is a
   reporting gap, not a fail-closed spawn failure.

`src/lib/aiur/config/schema/agent.ex` already owns the relevant static knobs:
`max_concurrent_agents`, `max_concurrent_builds`, `max_load_average`,
`target_load_average`, `min_free_memory_mb`, `run_queue_threshold`, and
`mix_scheduler_cap`. The load-envelope design in
`docs/plans/2026-07-09-001-refactor-load-concurrency-envelope-plan.md` and the
#1430 host-pressure admission together already change future admission only —
which is exactly the boundary this design extends to child spawns instead of
weakening.

---

## Is intra-agent parallelism worth it?

Probably not as the default. Aiur's stronger, already-available mechanism is
ticket-level decomposition: independent tickets receive separate workspaces,
separate reviewable commits, visible scheduler slots, and the existing load
controls. It also prevents a parent from becoming a serial integration bottleneck
or having children edit overlapping files.

Use a measured decision rather than intuition. For two or more representative
large tickets, compare these arms under the same fixed host and fleet settings:

| Arm | Treatment |
| --- | --- |
| A. Monolithic baseline | One eligible Claude ticket, no `Task` capability. |
| B. Fleet decomposition | The same scoped work decomposed into independent, linked tickets; normal fleet dispatch. |
| C. Canary intra-ticket | One Claude parent using the granted `Task` capability, admitted under the same host-pressure gate. |

For each arm collect wall-clock from issue activation to green CI, parent and
child model time/tokens/cost where available, peak resident memory, peak CPU and
load, build-lease queue time, retries, test/CI failures, merge conflicts, and
human-review churn.

**Pre-register the sample-count rule before running (this revision's fix for the
three-sample p95 flaw).** A p95 (or any tail) resource bound cannot be estimated
from three runs per arm. Choose one of the following and write it into the plan
before collecting data:

- **Defined tail estimator (larger N).** Run enough comparable samples per arm
  for the chosen tail statistic to be estimable — for a p95/p99 peak-memory or
  peak-load bound, ≥ 20–30 samples per arm (report n and the estimator/CI, and
  pre-register the quantile).
- **Explicit worst-case/no-regression rule (small N).** If the operator only
  funds three runs per arm, drop any p95 claim and instead pre-register an
  absolute ceiling: C's maximum observed peak memory/CPU/load across the three
  runs must stay under the configured envelope (`min_free_memory_mb`, load
  envelope) and must not regress the worst case observed in arm A or B by more
  than a pre-registered percentage. The decision rule then reads the *max*, not
  a tail estimate.

Either way, also pre-register the elapsed-time decision rule: C must improve
median elapsed time by at least 20% over A and by at least 10% over B; C may
introduce no additional CI failure, merge conflict, or median review round. If C
is within 10% of B, select decomposition for its lower maintenance cost rather
than a new subagent control plane.

---

## Smallest safe rollout

1. Pass the demand-evidence gate, then implement and test the backend policy
   seam for headless `claude` only: wire `aiur-claude`'s `--allowedTools` /
   `Task` grant through `Aiur.Claude.CodingAgent` and add the
   `agent.parallelism` config with validation. Do not expose the configuration
   publicly until the Claude CLI task-policy and lifecycle signals are proved.
2. Verify child work participates in the existing host-pressure admission:
   child `mix`/`compile`/`test` holds one global `max_concurrent_builds` lease
   and raises `BuildGate.status/0`, and a child spawn is admitted/deferred
   through `DispatchPolicy.admission_gate/1` like any new work. Exercise
   final-transport denial, allowlist admission, cleanup, and parent
   cancellation with focused tests. No fixed child quota or recursion ban is
   added — safety comes from the admission gate plus shared build/scheduler
   limits.
3. Start with one explicitly selected complexity-5, investigation-heavy ticket
   whose children are read-only research only, under the host-pressure gate.
   Keep `codex` (unwired `multi_agent`), `claude-repl`, and the OpenAI-compat
   backends rejected by validation.
4. Optionally add the cross-backend child lifecycle telemetry event contract
   (start/end/cancel) as observability.
5. Run the pre-registered measurement plan (either enough samples for a defined
   tail estimator, or the explicit worst-case rule for a three-run arm) and
   compare against a decomposed-ticket control before lowering the complexity
   threshold or adding another backend.

Immediate stop conditions: a child bypasses the build gate/scheduler cap,
host memory or load exceeds the configured envelope without the admission gate
deferring new work, parent cancellation leaves descendants alive, or the canary
fails to beat decomposition.

---

## Adversarial review and resolutions

This document was reviewed against the following failure modes before the draft
PR was opened, and re-reviewed against the PR #932 `CHANGES_REQUESTED` feedback:

| Challenge | Resolution in this design |
| --- | --- |
| “A prompt at complexity 5 is enough.” | Rejected. Capability and accounting are enforced separately; the prompt is explicitly secondary. |
| “The existing build gate automatically makes native children safe.” | Rejected. Inheritance is required and testable, but a server-created child could bypass it; the spawn contract must prove propagation and admission. |
| “Count only Mix commands; agents themselves are cheap.” | Rejected. Model workers consume the memory-limited resource, so children are visible through the same measured host pressure the fleet uses. |
| “The load envelope already solves burst risk.” | Rejected. It governs new ticket admission; this design extends the same admission gate to child spawns so intra-agent fan-out is equally visible. |
| “Enable all backends that happen to have a shell.” | Rejected. Shell backgrounding is unmanaged process parallelism, not an agent capability. v1 is Claude headless only. |
| “Parallelism must always beat splitting tickets.” | Rejected. The rollout uses decomposition as the control arm and adopts only on measured benefit. |
| “A complexity tag proves the work is independently parallelizable.” | Rejected. Complexity is only an outer gate; v1 accepts a single typed read-only-research task through the granted capability. |
| “Inherited `BASH_ENV` makes child Mix work enforced.” | Rejected. A child can bypass environment policy; child commands must hold the shared build lease and scheduler cap, and spawn admission is gated by host pressure. |
| “A Claude route is necessarily the headless Claude transport.” | Rejected. Eligibility is evaluated after remote-control transport resolution and rejects all `claude-repl` promotion. |
| “Any faster sample validates the feature.” | Rejected. The pre-registered three-arm thresholds make decomposition the default whenever the gain is small or resource/quality cost rises. |
| *(Review P1)* “Fixed child quotas, one-child-per-parent accounting, and a recursive-spawn ban are safe controls.” | Rejected. Those are topology restrictions; they forbid healthy native fan-out. Safety is topology-neutral host-pressure admission (#1430), which slows new admissions without killing or forbidding in-flight child work. |
| *(Review P1)* “The owned non-bypassable proxy is the hard safety control.” | Rejected. Dynamic MCP tools do not wrap Claude `Task`, and no owned boundary exists around Codex native multi-agent. Measured host-pressure admission is the hard control; child telemetry is optional observability, not a capability gate. |
| *(Review P2)* “Three samples per arm support a p95 resource gate.” | Rejected. Small-N arms use an explicit maximum/no-regression threshold; a defined tail estimator (p95/p99) requires enough samples and is pre-registered with n and the estimator. |

## Source map

- `src/lib/aiur/coding_agent.ex` — backend registry (`codex`, `claude`,
  `claude-repl`, plus OpenAI-compat entries), effort vocabularies, and the
  distinction between headless Claude and `claude-repl`.
- `src/lib/aiur/codex/coding_agent.ex` and `src/lib/aiur/codex/app_server_port.ex`
  — codex app-server session start and `--config model` /
  `model_reasoning_effort` argument construction; no `multi_agent` wiring today.
- `src/lib/aiur/claude/coding_agent.ex` and `src/lib/aiur/claude/config.ex` —
  headless Claude adapter; sends `permissionMode` only, no `--allowedTools`.
- `src/lib/aiur/claude/repl/command.ex` — `claude-repl` direct CLI construction.
- `src/lib/aiur/open_ai_compat/registry.ex` — OpenAI-compat entries (`kimi`,
  `deepseek`, `openrouter`) merged into the backend registry; no task boundary.
- `src/lib/aiur/agent_runner/turn_loop.ex` and
  `src/lib/aiur/agent_runner/turn_prompt.ex` — first-turn prompt assembly.
- `src/lib/aiur/prompt_builder.ex` — existing complexity prompt guidance.
- `src/lib/aiur/config/schema/agent.ex`, `src/lib/aiur/config/routing_value.ex`,
  and `src/lib/aiur/github/labels.ex` — configuration and complexity routing.
- `src/lib/aiur/agent_environment.ex`, `src/lib/aiur/build_gate.ex`, and
  `src/priv/build_gate.bash` — inherited Mix limits and shared build leases.
- `src/lib/aiur/orchestrator/dispatch_policy.ex` and
  `src/lib/aiur/orchestrator/dispatcher.ex` — the #1430/#1560 topology-neutral
  host-pressure admission gate (memory, FDs, run queue, load, build, provider)
  that this design extends to child spawns.
- `src/lib/aiur/config.ex` — `max_concurrent_agents/0` and
  `default_max_concurrent_agents/1` (host-calibrated default ceiling),
  `run_queue_threshold/0`.
- `src/lib/aiur/claude/telemetry/contract.ex` — Claude telemetry contract pinning
  `claude-code-2.1.210` and already recognizing `subagent` query sources plus
  built-in `Explore`/`Plan` subagents (observability evidence).
- `website/docs-app/reference/configuration.md` — the "Host-pressure fleet
  admission" section documenting that new admissions are gated by total observed
  host pressure and that running agents and agent-spawned sub-agents are never
  terminated.
- `docs/plans/2026-07-09-001-refactor-fleet-mix-build-gate-plan.md`,
  `docs/plans/2026-07-09-001-refactor-bound-agent-test-concurrency-plan.md`, and
  `docs/plans/2026-07-09-001-refactor-load-concurrency-envelope-plan.md` — the
  resource controls this proposal extends, never bypasses.
- `aiur-claude` sibling app-server (`Task` tool catalog; `--allowedTools`
  argument builder) — cited from the operator review of PR #932 with version
  stamping; the sibling checkout is not present in this agent workspace.
