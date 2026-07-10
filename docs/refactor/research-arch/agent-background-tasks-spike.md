# Spike: Complexity-Gated Agent Background Tasks / Subagents

**Status:** research and design only — no runtime behavior is proposed for this
PR.

## Decision summary

Do not treat higher reasoning effort or an extra prompt sentence as parallelism.
If aiur ever enables intra-ticket subagents, it must be a backend capability
grant, charged at the backend's actual task-spawn boundary, with child work
participating in the existing build gate, scheduler cap, and fleet admission
budget. Until that is true, ticket-level decomposition remains the preferred
way to obtain parallelism.

The smallest experiment worth considering is a **Claude headless-only** canary:
one explicitly selected complexity-5 ticket, one read-only-research child
maximum, and an Aiur-owned spawn proxy that reserves actor and command capacity
before it starts anything. The current `aiur-claude` source advertises `Task`,
but does not yet expose an allowed-tool argument or task lifecycle callback, so
this is a future implementation prerequisite rather than an enablement switch
that exists today.

---

## Brainstorm synthesis: problem, scope, and success criteria

The desired outcome is shorter elapsed time for a *single* large ticket when it
contains genuinely independent investigation or implementation work. The risk
is that a parent agent plus children consumes more memory, model capacity, and
Mix capacity than several ordinary tickets, while hiding that load from aiur's
fleet controls.

In scope for a later implementation:

- A per-workflow, complexity-gated backend capability policy.
- A backend-specific, enforced task-spawn path and optional prompt nudge.
- Child-process accounting against model actors, `mix compile` / `mix test`,
  scheduler threads, and host-load admission.
- A measured comparison with ordinary ticket decomposition.

Out of scope for this spike:

- Any schema, prompt, routing, `aiur-claude`, or runtime change.
- Codex pseudo-subagents created with `cmd &`.
- Unbounded recursive fan-out, cross-workspace children, or automatically
  splitting tickets without an explicit backend task request.

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

### Capability matrix

| Aiur backend | True subagents | Shell backgrounding | Current enable/disable point | Design status |
| --- | --- | --- | --- | --- |
| `codex` | No aiur-controllable `Task`/subagent primitive was found in the installed `codex app-server` contract or Aiur adapter. | A shell can use `cmd &`, but it is not a schedulable child-agent capability. | `src/lib/aiur/codex/coding_agent.ex` starts an app-server session; its app-server CLI surface exposes config/sandbox controls, not an Aiur task grant. | Unsupported. Do not offer an `enabled` setting that implies it works. |
| `claude` (headless) | Potentially yes: `~/github/claude-app-server/src/tools.ts` advertises a `Task` tool. | Possible, but not a supported parallelism mechanism. | The adapter currently sends only `permissionMode` (`src/lib/aiur/claude/coding_agent.ex`); the sibling server's `buildClaudeArgs` sends `--permission-mode` but no allowed/disallowed tool setting. The exact Claude CLI policy argument and propagation must be verified and wired before a grant can exist. | Candidate for the first canary only after a real capability gate exists. |
| `claude-repl` | Unverified as an aiur-controlled per-ticket capability. It drives the Claude CLI directly and has no per-ticket task policy seam. | Possible, but unmanaged. | `src/lib/aiur/claude/repl/command.ex` constructs the direct CLI command with permission mode and resume behavior, not a task policy. | Explicitly excluded from v1. |

These are the three currently registered backends in
`src/lib/aiur/coding_agent.ex`; there is no fourth generic backend that should
inherit a default parallelism behavior. The catalog entry is not sufficient
proof that a tool is permitted at runtime: `aiur-claude/src/server.ts` invokes
the local Claude CLI, whose policy and task lifecycle must be observable to
aiur before this feature can be safe.

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

This is a proposed YAML shape, not a change to the current schema:

```yaml
agent:
  parallelism:
    enabled: false
    min_complexity: 5
    backends: [claude]
    max_subagents_per_ticket: 1
    canary:
      ticket_allowlist: ["owner/repo#123"]
      max_active_parents: 1
      task_classes: [read_only_research]
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
3. `max_subagents_per_ticket` is a hard upper bound on live direct children;
   recursive children are forbidden in v1. It is intentionally not a request
   to use every slot.
4. `max_active_parents` is a fleet-wide reservation cap enforced at the same
   admission/spawn boundary; it makes "one active canary" a fact rather than
   an operator convention. A v1 child must declare the only supported class,
   `read_only_research`; any write-capable, verification, or uncategorized task
   request is rejected by the proxy.
5. The backend registry owns whether a backend can honor this setting. A
   configuration mentioning `codex` or `claude-repl` must fail validation until
   that backend declares an enforced capability adapter.

The implementation would add a normalized `parallelism` embedded config beside
`routing` and `complexity_prompts` in `src/lib/aiur/config/schema/agent.ex`.
A pure eligibility helper should use the existing `CodingAgent.complexity_level`
and resolved backend rather than reparse labels elsewhere. The first-turn
builder may append a small nudge only after that helper has returned a granted
policy: the parent may use the one read-only research child, then owns all
integration and final verification. Complexity is therefore a coarse outer
gate, not evidence that arbitrary ticket work is independent.

The configuration does **not** use an `effort` field. `RoutingValue` already
shows why: effort belongs to model selection and must not be overloaded into a
tool-authority switch.

---

## Enforced policy versus best-effort guidance

| Concern | Must be hard code/config | May be prompt guidance |
| --- | --- | --- |
| Whether `Task` exists for this turn | Backend capability resolver plus the Claude CLI/app-server tool policy; deny by default. | Explain that the capability is available only when granted. |
| Which tickets may request it | Normalized config, resolved backend, and complexity threshold. | Suggest considering it only for independent work. |
| Fan-out width and recursion | Reservation/token check at the actual spawn call; one direct child for v1. | Ask the parent to keep ownership of final integration. |
| Mix/CPU/memory safety | Shared actor budget, non-bypassable child launcher, build lease, scheduler cap, telemetry, and cancellation/reaping. | Explain why read-only research is the only v1 child class. |
| Quality and completion | Parent-owned diff integration, scoped checks, CI, and ordinary review. | Give the child a narrow deliverable and request a concise handoff. |

The exact spawn boundary is decisive. If the Claude CLI creates child workers
internally without an adapter callback, Aiur cannot honestly account for them.
In that case, a safe v1 requires a server-side task proxy/wrapper that acquires
a reservation before dispatch and releases it on completion/cancellation, or
the feature remains disabled. Parsing transcripts after a child begins is
observability, not admission control.

---

## Required resource accounting

The host has observed CPU spikes from compile/test/lint and becomes
memory-constrained around a large fleet. A parent plus unseen children would
let one ticket exceed the very controls intended to protect the fleet. The
following are release gates, not optimization ideas.

1. **Actor budget:** extend the same effective capacity calculation used by
   `agent.max_concurrent_agents`, state caps, and the adaptive load envelope.
   A parent reserves one actor; each live child reserves another actor before
   it starts. Reservations must contribute to the dashboard/status count and
   be released on completion, abort, timeout, or reaper cleanup. This prevents
   a nominal 10-agent fleet from silently becoming 10 parents plus 10 children.
2. **Non-bypassable command boundary:** environment inheritance from
   `AgentEnvironment.workspace_env/1` is necessary but insufficient; a
   child-controlled shell could clear `BASH_ENV` or `ELIXIR_ERL_OPTIONS`, and
   the existing parent build hook deliberately fails open when its own gate is
   unavailable. V1 avoids child shell/Mix access entirely by permitting only
   read-only research. Any later write-capable class must run commands through
   an Aiur-owned launcher/proxy that acquires capacity before command exposure,
   fails closed when its gate cannot be established, and rejects alternate
   command paths.
3. **Build lease and scheduler cap for future classes:** the owned launcher,
   not a prompt or an inherited variable alone, must supply the same shared
   `BASH_ENV`, `AIUR_BUILD_GATE_*`, `ELIXIR_ERL_OPTIONS`, and
   `AIUR_AGENT_MIX_SCHEDULERS` policy as the parent. A child `mix compile` or
   `mix test` must hold one global `max_concurrent_builds` lease and cannot
   replace or clear the scheduler cap. The future spawn contract needs direct
   Mix and `mise exec -- mix` child tests.
4. **Load envelope:** current `max_load_average` and the adaptive envelope
   admit *new tickets* and intentionally do not interrupt running work. Child
   reservations therefore have to reduce available capacity before spawn, and
   a spawn must be denied while the envelope has no headroom. Reading load
   after a child starts is too late for burst prevention.
5. **Lifecycle and telemetry:** record parent ticket, child identity, reserved
   actor units, started/completed/cancelled state, child Mix lease waits, and
   peak child count. Parent cancellation must terminate descendants through the
   existing containment/reaper path. Missing telemetry or an unreleaseable
   reservation is a fail-closed spawn failure.

`src/lib/aiur/config/schema/agent.ex` already owns the relevant static knobs:
`max_concurrent_agents`, `max_concurrent_builds`, `max_load_average`,
`target_load_average`, and `mix_scheduler_cap`. The load-envelope design in
`docs/plans/2026-07-09-001-refactor-load-concurrency-envelope-plan.md` also
documents its key limitation: it changes future admission only. The proposed
child reservation closes that gap instead of weakening those existing limits.

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
| C. Canary intra-ticket | One Claude parent plus at most one reserved child, only after all release gates above exist. |

For each arm collect wall-clock from issue activation to green CI, parent and
child model time/tokens/cost where available, peak resident memory, peak CPU and
load, actor/build-lease queue time, retries, test/CI failures, merge conflicts,
and human-review churn. Repeat enough times to avoid one unusually easy ticket
deciding the result. Pre-register the initial decision rule: at least three
comparable samples per arm; C must improve median elapsed time by at least 20%
over A and by at least 10% over B; C's p95 peak memory and CPU/load may be no
more than 10% above B; and C may introduce no additional CI failure, merge
conflict, or median review round. If C is within 10% of B, select decomposition
for its lower maintenance cost rather than a new subagent control plane.

---

## Smallest safe rollout

1. Pass the demand-evidence gate, then implement and test the backend policy
   seam for headless `claude` only. Do not expose the configuration publicly
   until the Claude CLI task-policy and lifecycle signals are proved.
2. Add the actor reservation and non-bypassable child contract before enabling
   any task. V1 must instead use an Aiur-owned, read-only task proxy; exercise
   final-transport denial, allowlist admission, cleanup, and parent
   cancellation with focused tests. Defer child build-gating and scheduler
   propagation tests until a write-capable child class is proposed.
3. Start with one explicitly selected complexity-5, investigation-heavy ticket
   whose child is read-only research only. Allow one direct child and one active
   canary parent at a time. Keep `codex` and `claude-repl` rejected by
   validation.
4. Run the measurement plan, publish the samples, and compare against a
   decomposed-ticket control before raising width, lowering the complexity
   threshold, or adding another backend.

Immediate stop conditions: a child bypasses the build gate/scheduler cap, actor
reservations leak, parent cancellation leaves descendants alive, host memory or
load exceeds the configured envelope, or the canary fails to beat decomposition.

---

## Adversarial review and resolutions

This document was reviewed against the following failure modes before the draft
PR was opened:

| Challenge | Resolution in this design |
| --- | --- |
| “A prompt at complexity 5 is enough.” | Rejected. Capability and accounting are enforced separately; the prompt is explicitly secondary. |
| “The existing build gate automatically makes native children safe.” | Rejected. Inheritance is required and testable, but a server-created child could bypass it; the spawn contract must prove propagation. |
| “Count only Mix commands; agents themselves are cheap.” | Rejected. Model workers consume the memory-limited resource, so every child consumes an actor reservation. |
| “The load envelope already solves burst risk.” | Rejected. It governs new ticket admission, not new work inside a running ticket. Child reservation is required before spawn. |
| “Enable all backends that happen to have a shell.” | Rejected. Shell backgrounding is unmanaged process parallelism, not an agent capability. v1 is Claude headless only. |
| “Parallelism must always beat splitting tickets.” | Rejected. The rollout uses decomposition as the control arm and adopts only on measured benefit. |
| “A complexity tag proves the work is independently parallelizable.” | Rejected. Complexity is only an outer gate; v1 accepts a single typed read-only-research task through the spawn proxy. |
| “Inherited `BASH_ENV` makes child Mix work enforced.” | Rejected. A child can bypass environment policy and the current parent hook can fail open; v1 forbids child shell/Mix, and later classes require an owned fail-closed launcher. |
| “A Claude route is necessarily the headless Claude transport.” | Rejected. Eligibility is evaluated after remote-control transport resolution and rejects all `claude-repl` promotion. |
| “Any faster sample validates the feature.” | Rejected. The pre-registered three-arm thresholds make decomposition the default whenever the gain is small or resource/quality cost rises. |

## Source map

- `src/lib/aiur/coding_agent.ex` — registered backends, effort vocabularies,
  and the distinction between headless Claude and `claude-repl`.
- `src/lib/aiur/agent_runner/turn_loop.ex` and
  `src/lib/aiur/agent_runner/turn_prompt.ex` — first-turn prompt assembly.
- `src/lib/aiur/prompt_builder.ex` — existing complexity prompt guidance.
- `src/lib/aiur/config/schema/agent.ex`, `src/lib/aiur/config/routing_value.ex`,
  and `src/lib/aiur/github/labels.ex` — configuration and complexity routing.
- `src/lib/aiur/agent_environment.ex`, `src/lib/aiur/build_gate.ex`, and
  `src/priv/build_gate.bash` — inherited Mix limits and shared build leases.
- `src/lib/aiur/config.ex` and `src/lib/aiur/orchestrator.ex` — fleet load
  gates and adaptive admission.
- `~/github/claude-app-server/src/tools.ts` and
  `~/github/claude-app-server/src/server.ts` — `Task` catalog declaration and
  current Claude CLI argument construction (local sibling repository; not part
  of this PR).
- `docs/plans/2026-07-09-001-refactor-fleet-mix-build-gate-plan.md`,
  `docs/plans/2026-07-09-001-refactor-bound-agent-test-concurrency-plan.md`,
  and `docs/plans/2026-07-09-001-refactor-load-concurrency-envelope-plan.md`
  — the three resource controls this proposal must extend, never bypass.
