---
title: "Provider Meter Surface - Plan"
type: feat
date: 2026-07-27
topic: provider-meter-surface
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

# Provider Meter Surface - Plan

## Goal Capsule

- **Objective:** Make Codex and Claude token usage and rate limits render real values on every Aiur surface — dashboard, CLI, and TUI — by having the daemon publish a projected meter snapshot the read side can consume without holding a provider capability.
- **Product authority:** Kevin Weaver (operator and sole dogfooder).
- **Open blockers:** None block planning. The `/usage` probe's failure modes (AE4) are the largest unknown and are expected to be resolved during planning.

---

## Product Contract

### Summary

Add a daemon-owned meter projection that resolves provider bindings internally and publishes an identity-free snapshot, so the dashboard, CLI, and TUI can all show current token usage and limit headroom. The daemon establishes a baseline at boot, refreshes on a configurable interval while agents are running, and every surface shows the most recent observation with its age.

---

### Problem Frame

The meter feature is already built and merged. DASH-012, DASH-013, DASH-020, DASH-015, and DF-013 landed the ingest path, the snapshot model, the authorization facade, and the rendering. None of it reaches a screen.

The read side was never connected. `provider_binding/1` in `src/lib/aiur_web/operator_control_center/provider_meter_source.ex` returns `nil` unconditionally, with a comment noting that no consumer-facing accessor exposes the daemon's active binding. Every read therefore resolves to the unknown-identity snapshot, so a fully authorized dashboard on a daemon holding live meter data still renders empty cards. `docs/plans/2026-07-13-003-feat-provider-account-generation-plan.md` deferred that accessor to follow-up work that never happened.

Two properties of the ingest path compound it. Meters are observed only as side-channel notifications on live agent sessions, so an idle daemon has nothing to show even once the read path works. And nothing retains the last observation past session end, so the numbers would vanish the moment work stops — which is exactly when an operator opens the dashboard to decide whether to start more.

The cost is a blind operator. Aiur runs agents against metered accounts, and the operator cannot see how much headroom is left before starting a build order.

---

### Key Decisions

- **The daemon publishes a projection; the read side never holds a binding.** (session-settled: user-directed — chosen over exposing a consumer-facing binding accessor: the accessor is the smaller change, but `Aiur.ProviderAccountGeneration` states that bindings are local capabilities and never account identifiers, and handing one to a web connection trades a documented security property for diff size.) Binding resolution stays inside the daemon where the capability already lives. Consumers read an identity-free projected snapshot.

- **Built for the coming package split.** Aiur will be decomposed into independent packages — dashboard, CLI, TUI, GitHub polling — in a future build order. That decomposition is out of scope here, but it is the reason the projection is a published contract rather than an internal reach-through: a consumer package can depend on the snapshot shape without depending on the daemon's capability model. This also makes one projection serve all three surfaces rather than each inventing its own read.

- **A read-model, not a new pattern.** `Aiur.CurrentRunProjections` already establishes the supervised read-model with cadence control and stale-but-serving semantics. The meter projection follows it rather than introducing a fourth way to expose live-daemon state.

- **Poll only when polling can tell you something.** (session-settled: user-directed — chosen over always-on polling: continuous polling burns provider sessions to observe a fleet that is not consuming anything.) One baseline probe at boot, then refresh only while agents are running.

- **Stale-but-labeled beats blank.** (session-settled: user-directed.) Surfaces always show the most recent observation with its age rather than hiding a value that has stopped refreshing. A never-observed meter is distinct from a stale one and reads as unknown, not as zero.

- **Authorization is unchanged.** The existing `AiurWeb.FinancialData` capability gate keeps governing whether a dashboard connection may display meter values. The projection changes what is readable, never who may read it.

---

### Requirements

**Exposure surface**

- R1. The daemon owns a supervised meter projection that resolves provider bindings internally and publishes a snapshot carrying no binding, credential, or provider account identifier.
- R2. The projection is the single source for all consumer surfaces, so dashboard, CLI, and TUI render from the same published shape.
- R3. Each provider projects independently: one provider's failure or unknown state never degrades the other's values.
- R4. The snapshot distinguishes never-observed from observed-but-stale, and carries the observation time needed to render age.

**Freshness and cadence**

- R5. The daemon establishes a baseline observation at boot so a surface opened before any agent runs shows real values.
- R6. While at least one agent is running, the daemon refreshes observations on an interval defaulting to one minute.
- R7. When no agents are running, the daemon performs no refresh beyond the boot baseline.
- R8. The refresh interval is operator-configurable through the workflow config, following the existing `polling.interval_seconds` pattern.
- R9. Sessions opened solely to observe usage are closed once the observation completes rather than being held open.

**Rendering**

- R10. The dashboard shows each provider's token usage and limit headroom, with the age of the observation.
- R11. The TUI shows usage bars for both providers in its header.
- R12. The CLI reports current usage and limits.
- R13. A value that has never been observed renders as explicitly unknown on every surface, never as a zero or a full bar.

---

### Acceptance Examples

- AE1. Idle daemon, freshly booted
  - **Covers R5, R10.**
  - **Given** the daemon booted five minutes ago and no agent has run.
  - **Then** every surface shows the boot-baseline values labeled roughly five minutes old, and no refresh has been attempted since boot.

- AE2. Agents finish and the fleet goes quiet
  - **Covers R4, R7, R10.**
  - **Given** agents ran and the last one finished twenty minutes ago.
  - **Then** surfaces still show the final observation, labeled twenty minutes old, and refreshing has stopped.

- AE3. One provider unreachable
  - **Covers R3, R13.**
  - **Given** Claude observations succeed and Codex observations fail.
  - **Then** Claude renders current values while Codex renders explicitly unknown, and neither borrows the other's facts.

- AE4. Usage probe fails or hangs
  - **Covers R9, R13.**
  - **Given** a probe session cannot authenticate, or does not return within its bound.
  - **Then** the probe is abandoned and its session closed, the prior observation continues to display with its true age, and no partial or invented value is published.

- AE5. Dashboard connection is not authorized for financial data
  - **Covers R13.**
  - **Given** the projection holds current values but the connection lacks the financial-data capability.
  - **Then** the dashboard shows the existing locked state rather than any meter value.

---

### Scope Boundaries

- The monolith decomposition into independent packages is a separate build order. This work is only designed to be compatible with it.
- No change to the financial-data authorization model, its capability, or its facade.
- No change to the ingest path: how Claude and Codex observations enter `Aiur.ProviderMeters` stays as built.
- No spend or cost-projection features; this is usage and limit headroom only.
- No persistence of meter observations across daemon restarts — the boot baseline replaces them.

---

### Dependencies and Assumptions

- Assumes the Claude and Codex CLIs expose a usage/limits command whose output can be parsed by a short-lived session. This is the load-bearing assumption behind R5 and R6, and the `/usage` probe does not exist in the codebase today — it is new work, not reuse.
- Assumes a provider binding is resolvable inside the daemon at the moment of observation. Ingest already proves this for session-scoped observations; the boot baseline needs it without a session.
- Depends on the existing `Aiur.ProviderMeters` store and `Aiur.ProviderAccountGeneration` owner remaining the source of meter facts.

---

### Outstanding Questions

**Resolve before planning**

- None.

**Deferred to planning**

- Whether the boot baseline probe and the periodic refresh share one mechanism or are separate paths.
- How a probe session authenticates when no agent session is active, and what bounds its runtime.
- Whether the projection publishes over PubSub, is pulled by consumers on demand, or both — the three existing live-daemon patterns each support a different answer.
- How the CLI and TUI reach the projection, given they do not pass through the web authorization facade.

---

### Sources

- `src/lib/aiur_web/operator_control_center/provider_meter_source.ex` — the stubbed `provider_binding/1` that blocks every read.
- `src/lib/aiur/provider_account_generation.ex` — binding semantics and the capability constraint that rules out the accessor approach.
- `src/lib/aiur/provider_meters/store.ex` and `src/lib/aiur/provider_meter_snapshot.ex` — the meter store and the snapshot's health and freshness model.
- `src/lib/aiur/current_run_projections.ex` — the supervised read-model pattern R1 follows.
- `src/lib/aiur_web/financial_data.ex` — the authorization facade that stays unchanged.
- `src/lib/aiur/config/schema/polling.ex` — the config pattern R8 mirrors.
- `docs/plans/2026-07-13-003-feat-provider-account-generation-plan.md` — deferred the consumer-facing accessor that this plan replaces with a projection.
