---
ticket_id: MP-R1-C3-T02
feature_id: MP-R1
chunk_id: MP-R1-C3
bucket: 1-refactor (Bucket-2 enabling work, RC-12)
title: Core capability providers - api.http, orchestration, agents, commands, tracker/repository, executor
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C3-T01]
prior_units: [U6]
prior_boundaries: ["ORC #12", "DEC #27", "EXE #26", "TRK #3", "WEB #34"]
prior_features: [MP-E2, MP-E3]
prior_findings: []
size_owner: n/a (new provider files, each < 120 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C3-T02 — Core capability providers

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (RC-12 enabling), MP-R1, C3. Contract §2.2–§2.4,
  [capability-matrix.md §2–§3](../capability-matrix.md).
- **User value:** the report answers the questions every client asks first: is the API
  up, are agents running, can I message an agent, can I answer a Command, which
  repository, is there an Executor.
- **Deliverable:** five PROPOSED provider modules (the table below), each in its owning component's
  directory, registered in `config :aiur, :capability_providers`:

  | Provider (PROPOSED module) | Component | IDs / sections |
  |---|---|---|
  | `Aiur.HttpServer.CapabilityProvider` | web-shell | `api.http` |
  | `Aiur.Orchestrator.CapabilityProvider` | orchestration | `orchestration`, `instance.status`, `agents.run`, `agents.message` |
  | `Aiur.DecisionStore.CapabilityProvider` | commands | `commands.read`, `commands.answer`, `commands.supervisor_api` |
  | `Aiur.Tracker.CapabilityProvider` | tracker | `tracker.github`, `tracker.linear`; section `repository` |
  | `Aiur.Executor.CapabilityProvider` | executor-attention | `executor.wakes`, `executor.conversation`; section `executor` |
- **Non-goals:** optional components (T07: build orders, voice, streamdeck, webhooks,
  remote control, accounting, conversations); changing any existing gate or response.

## Dependencies and blockers

- DESIGN-R1 §1; C3-T01. **Concurrent:** T03, T04, T07 (T03/T04 can use the identity provider
  alone until this merges). **Dependents:** MP-E2 (adopts `commands.*`), MP-E3 (fills
  `executor.harness`, `executor.conversation`), MP-N3.

## Verified starting point (`45a290e3`)

- **HTTP:** `Aiur.HttpServer` is a child only when `dashboard?` (`aiur.ex:469`);
  `--no-dashboard` sets `:no_dashboard` (`aiur.ex:67`).
- **Orchestrator:** `{Aiur.Orchestrator, name: Aiur.Orchestrator}` (`aiur.ex:442`).
  `SnapshotStore.read/3` reads `:persistent_term` (`snapshot_store.ex:213-232,351`), and
  returns `:orchestrator_unavailable` only when no snapshot is cached and the process is
  dead (`:381-390`); a cached snapshot is returned even when the orchestrator has died.
  So the provider checks `Process.whereis(Aiur.Orchestrator)` **first**.
- **Writable gate:** browser/API agent writes go through `:require_writable`
  (`router.ex:153-164`), the Supervisor Decision API writes too
  (`router.ex:81-87`); the flag comes from `observability.dashboard_writable`
  (`config/schema/observability.ex:12`, default `true`; live bug #3010 about comment
  drift, not about behaviour).
- **Commands:** `{Aiur.DecisionStore, name: Aiur.DecisionStore}` (`aiur.ex:407`); answer
  delivery to agents needs the orchestrator (capability-matrix §5).
  `AIUR_SUPERVISOR_TOKEN` classification `Aiur.SupervisorToken.classify/1`
  (`supervisor_token.ex:17-28`): `:missing`, valid, `:invalid` (invalid aborts startup,
  AGENTS.md "Auth").
- **Tracker:** `Aiur.Tracker.project_identity/0` (`tracker.ex:152-159`), adapter by
  `tracker.kind` (`tracker.ex:161-168`).
- **Executor:** `Aiur.Executor.Claims.owner/1` (`claims.ex:120-132`) returns the live
  owner; `Aiur.Executor.Roster.build/1` with `record?: false` does not record an
  observation (`roster.ex:47-66`); recording children run only when `recording?`
  (`aiur.ex:503-504`, default true in a real run).

## Chosen design

Mapping (first matching row wins per ID):

| ID | Condition | Entry |
|---|---|---|
| `api.http` | `run_shape.http_listener == false` | `unavailable/not_installed` |
| | `Process.whereis(Aiur.HttpServer)` nil | `unavailable/not_running` |
| | else | `available` |
| `orchestration` | process nil | `unavailable/not_running` |
| | `SnapshotStore.read` → `:snapshot_unpublished` | `degraded/snapshot_unpublished` |
| | `{:stale, _, meta}` | `degraded/snapshot_stale` plus `observed_at` from meta |
| | `{:current, _, _}` | `available` |
| `instance.status` | `orchestration` not available | `degraded/dependency_unavailable`, `depends_on: ["orchestration"]` |
| | else | `available` |
| `agents.run` | `orchestration` `unavailable` | `unavailable/dependency_unavailable` |
| | else | `available` (global pause is a state, not an absence; shown by `instance.status`) |
| `agents.message` | `api.http` not available | `unavailable/dependency_unavailable`, `depends_on: ["api.http"]` |
| | `orchestration` unavailable | `unavailable/dependency_unavailable` |
| | `dashboard_writable == false` | `unavailable/disabled` |
| | else | `available` |
| `commands.read` | DecisionStore process nil | `unavailable/not_running` |
| | `api.http` not available | `unavailable/dependency_unavailable` |
| | else | `available` |
| `commands.answer` | `commands.read` not available | same entry |
| | `dashboard_writable == false` | `unavailable/disabled` |
| | `orchestration` unavailable | `degraded/dependency_unavailable` (recorded, not delivered) |
| | else | `available`, `version: 1` |
| `commands.supervisor_api` | token `:missing` | `unavailable/not_configured` |
| | `api.http` not available | `unavailable/dependency_unavailable` |
| | else | `available` |
| `tracker.github` / `tracker.linear` | kind matches | `available`; other kind → `unavailable/not_configured` |
| `executor.wakes` | recording children absent (`Process.whereis(Aiur.ExecutorWakeInbox)` nil) | `unavailable/not_running` |
| | else | `available` |
| `executor.conversation` | always in this ticket | `unavailable/executor_not_managed` (MP-E3 changes it) |

Sections:
- `repository`: GitHub `"owner/name"` → `%{kind: "github", owner, name}`; Linear slug →
  `%{kind: "linear", owner: nil, name: slug}`; `"memory"` → memory; nil/raise → `nil`.
- `executor`: `Claims.owner/1` `{:ok, e}` → state from `Roster.build(record?: false)`
  entry with the same id (`active|idle|stalled|expired|unknown`), `consumer_id: e["id"]`,
  `harness: nil`; `:none` and no entries at all → `%{state: "absent", consumer_id: nil}`;
  `:none` with only expired entries → `expired`; any raise/exit → `%{state: "unknown"}`.
- **Live Executor (RC-37, X-02).** The section reports the state only; it never collapses
  it. Consumers read "live" as `state ∈ {active, idle}`; `stalled`, `expired`, `absent`
  and `unknown` are not live (D9 then routes to the human). Test row: roster
  `[idle, stalled]` with the owner idle → `state: "idle"`; a helper
  `Aiur.Executor.CapabilityProvider.live?/1` returns `true` for `active`/`idle` only, and
  the table test fails if `idle` is dropped from it.

Cross-ID dependencies are computed inside one provider when possible; where an ID depends
on another provider's ID (`api.http`), the provider reads the same inputs directly (run
shape, `Process.whereis`) instead of reading another provider's output, so providers stay
order-independent.

## Implementation steps

1. Write the five modules in the table (`api.http` is one of them), each implementing
   `Aiur.Capabilities.Provider`, with pure helpers taking injected inputs (process
   lookup fun, snapshot-read fun, settings) so tests do not boot the tree.
2. Register them in `src/config/config.exs`.
3. Add files to `components.json` under their owning components; the providers reference
   only their own component plus `Aiur.Capabilities.Provider` (identity facade).

## Non-happy paths

- Settings unavailable → `dashboard_writable` unknown → `agents.message` and
  `commands.answer` `unknown/unknown` (never assume writable).
- Claims GenServer slow → provider timeout in C3-T01 makes `executor.*` unknown and the
  section `nil`.
- Roster read must not record: covered by a test.
- No secrets: the token is classified, never included.

## Compatibility and rollout

Additive. Rollback: remove the providers from config (registry then reports their known
IDs as `not_installed`) or revert.

## Verification

PROPOSED `src/test/aiur/capabilities/core_providers_test.exs`, table-driven over the
mapping above, one test per row (names `"<id>: <condition>"`). Highlights:

| Test | Expected |
|---|---|
| `orchestration: dead process with cached snapshot is not_running` | not `available`, not `degraded` |
| `agents.message: writable false is disabled` | `unavailable/disabled` |
| `commands.answer: orchestrator down is degraded, not unavailable` | `degraded/dependency_unavailable` |
| `no_dashboard makes api-dependent ids dependency_unavailable` | `depends_on: ["api.http"]` |
| `executor: no claims is absent` | `state: "absent"` |
| `executor: roster read does not record an observation` | claims file `observation` unchanged (temp claims path) |
| `executor: raising roster is unknown, not absent` | `state: "unknown"` |
| `repository: linear slug has null owner` | `%{kind: "linear", owner: nil}` |
| `settings unavailable makes writable-gated ids unknown` | `unknown/unknown` |

Integration (one test, app booted with `--no-dashboard` shape via `child_specs/1`
options): `Aiur.Capabilities.report/1` contains every ID above with the expected states;
kill `Aiur.Orchestrator` (`Process.exit(pid, :kill)` with the restart suppressed via a
test-only supervisor) and assert `orchestration: unavailable/not_running` within one tick.

Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/capabilities/core_providers_test.exs`.

Mutation check: drop the `Process.whereis` check before the snapshot read → "dead
process with cached snapshot" fails; change roster `record?: false` to default → "does
not record" fails; map executor raise to `absent` → "raising roster is unknown" fails.

## Completion and handoff

- [ ] Providers registered; table-driven tests fail under the mutations.
- [ ] Capability matrix §2 updated if any ID wording changed.
- [ ] Docs: covered by the C3-T03 concepts page (lists every v1 ID with its meaning); if
      T03 merged first, add the rows there in this PR.
- **Dependents:** MP-E2 (answer path adopts `capability_unavailable`), MP-E3, MP-N3.
