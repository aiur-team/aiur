# Tickets: M3 one daemon, many projects

Part of [the plan](../2026-11-06-multi-project-gateways.md). Conventions are in [tickets-m0-m1.md](tickets-m0-m1.md).
Paths are under `src/lib/aiur/` unless they start with `src/`, `packaging/` or `website/`.

**Shape fixed by KTD-4:** one BEAM per gateway; one supervision tree per project, registered under
`{:via, Registry, {Aiur.ProjectRegistry, {project_id, Module}}}`; a project context in each project process that
`Aiur.Config.settings/0` reads. The design ticket MPG-301 confirms or replaces this before any M3 implementation.

---

### Decide the multi-project process model

- Plan id: MPG-301 · `lane:multi-project` · complexity 4 · kind: design (no research ticket) · depends on: none
- **Outcome.** `docs/research/MPG-301.md`, an ADR that every M3 research ticket reads. It records:
  1. per-project vs machine-level ownership of each of the 27 `name: __MODULE__` singletons, the orchestrator and
     its helpers (list in `code-evidence.md` §5);
  2. how the project context reaches `Task`, `Task.Supervisor`, `GenServer` and ETS readers;
  3. which services stay machine-level (GitHub budget broker, HTTP endpoint, agent budget socket, usage ledger,
     handoff, alerts) and how they label output by project;
  4. the call-site migration order, sized so MPG-303..305 each touch fewer than 40 files.
- **Acceptance.**
  - [ ] Every singleton has exactly one row: `per-project` or `machine`, with its reason.
  - [ ] The ADR names the test helper that boots two project trees in one VM (used by MPG-302..306).
  - [ ] It states the single-project default: an empty `projects:` list boots exactly today's tree.
  - [ ] Alternative "one OS daemon per project behind a machine coordinator" is evaluated and its conflict with the decided "one daemon per machine" stated.
  - [ ] It decides how the planned `machine-gateway` process of `docs/research/aiur-mobile-and-platform/` (owner of the `~/.aiur/machine` `gateway`, `pairing`, `transport` sections) relates to the gateway daemon: folded in, or kept separate with a stated reason.

### Give each process a project context that config reads

- Plan id: MPG-302 · `lane:multi-project` · complexity 3 · depends on: MPG-301, MPG-302R
- **Outcome.** `Aiur.Project.Context.put/1` and `current/0` exist; `Aiur.Config.settings/0` and `settings!/0` return
  the current project's settings; `Aiur.Project.Task.async/1` copies the context. With no context, behaviour is
  today's.
- **Next action.** Create `project/context.ex` and `project.ex` (`%Aiur.Project{id, repo, config_path,
  state_root}`), then key the `WorkflowStore` ETS cache by project id in `workflow_store/cache.ex`.
- **Files.** `project.ex`, `project/context.ex`, `project/task.ex` (new); `config.ex`; `workflow.ex`;
  `workflow_store.ex`; `workflow_store/cache.ex`; tests `src/test/aiur/project/context_test.exs`,
  `src/test/aiur/config_project_test.exs`.
- **Acceptance.**
  - [ ] **[fails without]** Two contexts with configs naming repos `o/a` and `o/b`: `Config.settings!().tracker.github.repo` returns `o/a` in one process and `o/b` in the other.
  - [ ] A task started with `Aiur.Project.Task.async/1` sees its parent's project.
  - [ ] No context set: the full existing config test suite for `config_test.exs` passes unchanged.
- **Research MPG-302R** (complexity 2, depends on MPG-301). The memo in `config/settings_snapshot.ex` and how its key
  must include the project id.

### Register the orchestrator per project

- Plan id: MPG-303 · `lane:multi-project` · complexity 3 · depends on: MPG-302, MPG-303R
- **Outcome.** `Aiur.Orchestrator` starts once per project under a via-Registry name. The 32 default arguments and
  10 hard-coded `GenServer.call(Aiur.Orchestrator, ...)` sites resolve the orchestrator of the current project.
- **Next action.** Add `Aiur.Project.whereis(module)` in `project.ex`; replace each `\\ Aiur.Orchestrator` default in
  `orchestrator/client.ex` with `Aiur.Project.whereis(Aiur.Orchestrator)`.
- **Files.** `orchestrator/client.ex`, `orchestrator/client_delegates.ex`, `control_cli/park.ex`,
  `agent_runner/bootstrap_digest.ex`, `orchestrator/command_delivery_target.ex` and the other sites the research
  lists; `application/children.ex`; test `src/test/aiur/orchestrator/project_registration_test.exs`.
- **Acceptance.**
  - [ ] **[fails without]** Two project trees in one VM: `Aiur.Orchestrator.Client.snapshot/0` called from each project's process returns that project's snapshot.
  - [ ] The regexes in `code-evidence.md` §5 for hard-coded calls (`GenServer.call/cast`, `Process.whereis`, aliased or not) and for `\\ Aiur.Orchestrator` defaults return zero matches outside `project.ex`.
- **Serializes with.** MPG-304, MPG-305 (`application/children.ex`). Merge order: 303, 304, 305.
- **Research MPG-303R** (complexity 2, depends on MPG-301). Exact site list with line numbers at pickup.

### Register the workflow, queue, feature and snapshot stores per project

- Plan id: MPG-304 · `lane:multi-project` · complexity 3 · depends on: MPG-302, MPG-304R
- **Outcome.** `Aiur.WorkflowStore`, `Aiur.BuildQueue.Server`, `Aiur.BuildOrder.Features`,
  `Aiur.Orchestrator.TrackedSet`, `SnapshotCache`, `SnapshotStore`, `SnapshotPublisher` are per-project; their named
  ETS tables carry the project id.
- **Next action.** Change each module's `start_link` from `name: __MODULE__` to the via-Registry name and its ETS
  table name to `{table, project_id}` lookups through a registry of table refs.
- **Files.** `workflow_store.ex`, `build_queue/server.ex`, `build_order/features.ex`, `orchestrator/tracked_set.ex`,
  `orchestrator/snapshot_cache.ex`, `orchestrator/snapshot_store.ex`, `orchestrator/snapshot_publisher.ex`;
  test `src/test/aiur/project/store_isolation_test.exs`.
- **Acceptance.**
  - [ ] **[fails without]** Adding item `#5` to project A's build queue leaves project B's `queue.json` unchanged.
  - [ ] Each store's existing tests pass with no project context.
- **Research MPG-304R** (complexity 2, depends on MPG-301).

### Register the remaining per-project singletons

- Plan id: MPG-305 · `lane:multi-project` · complexity 3 · depends on: MPG-302, MPG-305R
- **Outcome.** Every singleton the ADR marks per-project and MPG-303/304 did not cover is per-project.
- **Next action.** Work through the ADR table rows marked `per-project`, `MPG-305`, one module per commit.
- **Files.** listed by MPG-305R; test `src/test/aiur/project/singleton_inventory_test.exs` that fails when a module
  with `name: __MODULE__` is neither in the ADR's machine list nor per-project.
- **Acceptance.**
  - [ ] **[fails without]** The inventory test lists zero unclassified singletons, and its classification equals the MPG-301 ADR table row for row (a module the ADR marks per-project cannot pass as machine-level).
- **Research MPG-305R** (complexity 2, depends on MPG-301).

### Boot one project tree per configured project

- Plan id: MPG-306 · `lane:multi-project` · complexity 4 · depends on: MPG-303, MPG-304, MPG-305, MPG-002, MPG-306R
- **Outcome.** With `projects:` set in `~/.aiur/machine`, the daemon starts one `Aiur.Project.Supervisor` per entry.
  One project failing to boot logs, alerts and leaves the others running. With `projects:` empty, today's tree starts.
- **Next action.** Create `project/supervisor.ex` and `project/registry.ex`; in `application/children.ex`, build the
  per-project children list from `Aiur.Machine.Settings.get/0`.
- **Files.** above; `application/children.ex`; tests `src/test/aiur/project/supervisor_test.exs`;
  docs `website/docs-app/concepts/operating-aiur.md` (new section "One daemon, several projects").
- **Acceptance.**
  - [ ] **[fails without]** `projects:` with two fixture repos (memory tracker): both orchestrators poll; `aiur status --json` lists both under `projects`.
  - [ ] A project whose config fails to parse: alert `system.project.boot_failed`, other project keeps polling.
  - [ ] Removing a project from `projects:` and running `aiur gateway reload` stops only that tree.
- **Research MPG-306R** (complexity 2, depends on MPG-301).

### Share machine capacity across projects

- Plan id: MPG-307 · `lane:scheduler` · complexity 3 · depends on: MPG-306, MPG-307R
- **Outcome.** `Aiur.Gateway.Capacity` grants slots machine-wide. A project's orchestrator dispatches only with a
  grant; total running agents never exceed `capacity.max_agents`; each project stays within `projects[].max_agents`.
- **Next action.** Create `gateway/capacity.ex` (GenServer: `request(project_id, n) -> granted`, `release/2`,
  monitors holders) and call it from `orchestrator/slots.ex` `available_slots/1`.
- **Files.** `gateway/capacity.ex` (new); `orchestrator/slots.ex`; `cli.ex` (`--max-agents` sets machine capacity);
  tests `src/test/aiur/gateway/capacity_test.exs`; docs `configuration-daemon.md`.
- **Acceptance.**
  - [ ] **[fails without]** Machine 12, project A max 8 with 10 ready, project B max 8 with 10 ready: running total is 12, A ≤ 8, B ≤ 8.
  - [ ] An orchestrator that crashes returns its grants (monitor) within one second.
  - [ ] With one project, `max_concurrent_agents` behaves as today (existing `slots_test` passes).
- **Policy.** Grants are first-come in this ticket; MPG-402 adds priority order.
- **Research MPG-307R** (complexity 2, depends on MPG-301). Interaction with `effective_concurrent_agents` (load
  envelope) and keep-agents adoption slots.

### Pause, reload and hand off one project without touching others

- Plan id: MPG-308 · `lane:multi-project` · complexity 3 · depends on: MPG-306, MPG-308R
- **Outcome.** `aiur pause --project o/r` pauses one project; bare `aiur pause` pauses the whole gateway. A config
  change in one project reloads only that project. A keep-agents restart compares the handoff fingerprint per project,
  so a change in one project falls back only that project's agents.
- **Next action.** Move the handoff record to `<project state root>/handoff/current.json` and compute
  `handoff/compatibility.ex` fingerprints per project.
- **Files.** `handoff/record.ex`, `handoff/compatibility.ex`, `handoff/adopter.ex`, `handoff.ex`,
  `orchestrator/global_pause_store.ex` (gateway file plus per-project file); tests
  `src/test/aiur/handoff/project_fingerprint_test.exs`, `src/test/aiur/orchestrator/project_pause_test.exs`;
  docs `cli-operations.md`.
- **Acceptance.**
  - [ ] **[fails without]** Two projects, change project A's `workspace.root`, keep-agents restart: B's agents are adopted, A's fall back.
  - [ ] **[fails without]** Pausing project A leaves project B dispatching.
  - [ ] Gateway pause survives restart and stays paused when its file is unreadable (existing invariant).
- **Research MPG-308R** (complexity 2, depends on MPG-301).

### Key the daemon by gateway and migrate per-repository state

- Plan id: MPG-309 · `lane:multi-project` · complexity 3 · depends on: MPG-306, MPG-206, MPG-309R
- **Outcome.** In multi-project mode the instance key is `gw-` + first 10 hex of sha256(gateway id), so control
  commands work from any directory. Existing per-repository state (`<state root>/<old key>/<repo leaf>/`) is moved or
  linked to `<state root>/<gateway key>/<repo leaf>/` once, with a dry run.
- **Next action.** Add `aiur_gateway_instance_key` to `engine/identity.sh` (used when `~/.aiur/machine` has
  `projects:`), then `aiur gateway migrate-state [--apply]` in `gateway/state_migration.ex`.
- **Files.** `packaging/npm/aiur-cli/libexec/engine/identity.sh`; `config/paths.ex`; `gateway/state_migration.ex`
  (new); tests `src/test/aiur/gateway/state_migration_test.exs`, `packaging/npm/aiur-cli/test/launcher-identity.test.mjs` (new);
  docs `cli-launch.md`.
- **Acceptance.**
  - [ ] **[fails without]** With `projects:` set, `aiur status` from `/tmp` reaches the gateway daemon.
  - [ ] Dry run lists each directory move and changes nothing; `--apply` is idempotent; a running daemon refuses migration.
  - [ ] Without `projects:`, the key is today's cwd-derived key.
- **Research MPG-309R** (complexity 2, depends on MPG-301). Every reader of `AIUR_INSTANCE_KEY` and of paths under
  `~/.aiur/instances/<key>/`.

### Explain where each config value comes from

- Plan id: MPG-310 · `lane:multi-project` · complexity 2 · depends on: MPG-306, MPG-310R
- **Outcome.** `aiur config explain <key> [--project o/r] [--json]` prints the effective value, its owning layer
  (L0-L6 in the plan), the source file, and each lower layer it overrode.
- **Next action.** Add `config/provenance.ex` that loads each layer separately and reports the first layer that sets
  the key, following the field-owner table.
- **Files.** `config/provenance.ex`, `config/provenance_cli.ex` (new); `packaging/npm/aiur-cli/libexec/engine/commands.sh`;
  allowlist entry (`read`); tests `src/test/aiur/config/provenance_test.exs`; docs `cli-operations.md`.
- **Acceptance.**
  - [ ] **[fails without]** `agent.max_concurrent_agents` set in the project file and overridden by `aiur set`: output names layer L5 and lists L3 as overridden.
  - [ ] A key set nowhere prints the default with layer L0.
  - [ ] Secret-valued keys print `<redacted>`.
- **Research MPG-310R** (complexity 1, depends on MPG-301).

### Target one project on a multi-project gateway

- Plan id: MPG-311 · `lane:gateway-cli` · complexity 2 · depends on: MPG-306, MPG-202, MPG-311R
- **Outcome.** Project-scoped commands accept `--project <owner/repo>`. Locally it defaults to the repo of the
  current directory; remotely it defaults to the gateway's only project, else exits 64 listing the projects.
  `set` sends `project` instead of `caller_cwd`.
- **Next action.** Parse `--project` in `aiur-engine.sh` after the selector and pass it as a keyword to every RPC;
  resolve it on the server in `control_call.ex` before `run`.
- **Files.** `aiur-engine.sh`; `engine/commands.sh` (remove `caller_cwd`); `control_call.ex`; allowlist keyword
  `project`; tests `launcher-remote.test.mjs`, `src/test/aiur/control_call_test.exs`; docs `cli-options.md`.
- **Acceptance.**
  - [ ] **[fails without]** `aiur --gateway nook queue show --project o/b` returns project B's queue on a two-project stub.
  - [ ] Omitted on a two-project gateway: exit 64 `pick a project: o/a, o/b`.
  - [ ] A single-project gateway ignores a matching `--project` and refuses a different one.
- **Research MPG-311R** (complexity 1, depends on MPG-301). Which commands are project-scoped vs gateway-scoped
  (use `code-evidence.md` §3.3 Target column).
