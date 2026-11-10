---
title: Multi-Instance Control Plane - Plan
type: feat
date: 2026-10-23
topic: multi-instance-control
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
deepened: 2026-10-23
researched_at_commit: ab0c21424
---

# Multi-Instance Control Plane - Plan

Planning pack (ticket contracts, typed graph, validation, handoff): `docs/plans/2026-10-23-multi-instance-control/README.md`.

---

## Goal Capsule

- **Objective:** one operator, or one Executor agent, on one machine reads and controls every Aiur instance that shares a repository (home PC, home NUC, Railway services) through the same CLI it uses locally: `aiur --instance <name> <cmd>`.
- **Product authority:** the operator request of 2026-10-23 (quoted in the pack README), then the settled decisions below, then this plan. GitHub owns ticket state after promotion; Aiur owns runtime state.
- **Boundary:** planning only. No GitHub issues, labels, or daemons change until the Executor promotes the pack.
- **Open blockers:** none. Every open decision carries a recommended default (pack `questions-or-commands.md`).
- **Stop condition for the later run:** MIC-010 records merged-base evidence that one Executor on one machine operated two live instances end to end.

---

## Product Contract

### Summary

Add a remote target to the existing CLI. A named instance resolves to an HTTPS URL and a bearer token. The daemon runs the same allowlisted control call the local CLI would run, and returns the same output and exit code. On top of that transport: fan-out reads (`--instance all`), runtime settings that the running build validates, ticket-ownership rules in per-instance config, and one Executor wait across all instances.

### Problem Frame

Each machine that runs an Aiur daemon needs its own Executor agent today, because every control command reaches the daemon only over loopback Erlang distribution (`packaging/npm/aiur-cli/libexec/engine/control.sh:311-345`, `packaging/npm/aiur-cli/libexec/engine/identity.sh:283-302`). On 2026-10-22 the operator ran a primary and a secondary instance on two machines with two Executors that coordinated through chat. The Railway work (#5939-#5954) adds more instances, each a separate service with its own volume. Without a remote path, every new instance adds one more Executor to run and one more place to edit configuration. Tickets move between instances only by manual relabeling under the static `label_prefix` split (#5947 Problem).

### Actors

- A1. Operator: a human who runs `aiur` on any machine.
- A2. Executor: the operator's coding agent running `aiur-run`, now one per fleet instead of one per machine.
- A3. Instance: one Aiur daemon with its own state directory and dashboard listener.
- A4. Machine client: a non-browser caller holding a bearer token (#5945).

### Key Decisions

- **Remote transport forwards the CLI's own control call.** The daemon accepts the exact call expression the engine already builds for `bin/aiur rpc`, parses it, accepts it only if it is one allowlisted function applied to literal arguments, runs it with output captured, and returns the text with the existing exit markers. Every RPC command becomes remote-capable with no per-command code, and local and remote output cannot drift. Chosen over a separate REST API with its own JSON envelopes: there is no shared envelope helper, and many mutating commands print text only, so a parallel API would reimplement ~45 commands.
- **Scopes are #5945's `read` and `write`.** The allowlist classifies each control function as one or the other. No third scope name.
- **Remote configuration is `aiur set` with more keys.** The existing `aiur set max-agents` path extends to an allowlist of dotted config keys. Overrides live in a per-instance file that the config loader layers over YAML. The YAML file is never written remotely. Chosen over writing `.aiur/config` remotely: the operator config is protected from agents, and a write-time check by the receiving build is what makes the change build-aware.
- **Ticket ownership is per-instance config, published through #5947 heartbeats.** `instance.owns` lists the labels and ticket ids an instance reserves. The claim lease from #5947 keeps dispatch safe even when rules overlap. Chosen over one shared rules document in the lease store: the operator asked for a config setting, and a per-instance key is remotely settable through `aiur set` with no new store schema.
- **One Executor merges wake streams in the client.** `aiur --instance all executor-wait` long-polls every instance in parallel and keeps one acknowledgement cursor per instance. No server-side merged journal.
- **Erlang distribution stays on loopback on every launch path.** The daemon checks this at boot and refuses to run distributed otherwise. Today only the bash engine sets it.

### Requirements

**Remote targeting**

- R1. `aiur --instance <name> <cmd>` runs any daemon control command against a named instance; output and exit code match a local run on that instance's host.
- R2. With no `--instance`, every command behaves as today.
- R3. Instance names resolve from an operator-owned registry file that holds a URL and a token reference, never a token value.
- R4. `aiur --instance all <cmd>` runs a read-scope command on every registered instance, labels each result with its instance, and reports an unreachable instance as unreachable; it refuses write-scope commands. The one exception is `executor-wait` (R17), which is a write because it claims and acknowledges. The server enforces the read-only rule too: a fan-out call carries `max_scope: "read"`, and the daemon refuses any call whose parsed scope exceeds it.
- R5. Every command that does not call the daemon through `run_control_rpc` is refused with `--instance`, naming the reason. The full list is in MIC-003 (`stop`, `restart`, `run`, `--bg`, `init`, `login`, `logout`, `pr`, `findings`, `ask`, `doctor`, `upgrade`, `cleanup-stale`, `pre-pr`, `listen`, `--version`).

**Control API**

- R6. The daemon serves remote calls on one authenticated endpoint that runs only allowlisted control functions with literal arguments.
- R7. Each call needs a bearer token whose scope covers the function.
- R8. Every remote write call, and every refused call, appends one audit record: time, token name, function, outcome.
- R9. A function or setting unknown to the receiving build is refused with the build version in the message, never ignored.
- R10. The client refuses plain HTTP unless the target is loopback. Tailnet hosts use HTTPS (`tailscale serve` provides it).

**Runtime settings**

- R11. `aiur set <key> <value>` changes an allowlisted setting at runtime, locally or with `--instance`; the running build validates the merged configuration before storing it.
- R12. Overrides persist per instance across restarts, are listed with value, source, revision and actor, and can be removed.
- R13. A stored override that the current build rejects never stops boot; it is set aside and raised as an attention.

**Ticket ownership**

- R14. An instance can declare in config which tickets it owns, by label or ticket id.
- R15. A ticket that matches a live instance's ownership rule is dispatched only by that instance; a ticket that matches no live rule is taken by any pool instance.
- R16. When an owning instance's heartbeat expires, its tickets return to the pool with no relabeling.

**One Executor**

- R17. One Executor consumes wakes from every registered instance through one wait, and each record names its instance.
- R18. A wake is never lost when a remote response is lost; delivery is at least once.

**Distribution safety**

- R19. Erlang distribution and epmd listen on loopback only, on every launch path, and the daemon refuses to start distributed otherwise, or with the release's baked-in cookie.

**Human-only actions**

- R20. A function whose local CLI wrapper enforces a human, terminal, or non-agent check (for example `aiur answer --operator`) is local only. A token of any scope cannot call it, because the bash-side check does not travel over HTTP.

### Key Flows

- F1. Read one remote instance
  - **Trigger:** operator runs `aiur --instance nuc status`.
  - **Steps:** the engine resolves `nuc` in the registry, reads the token, sends the call `Aiur.AgentControlCLI.status()` to `https://<nuc>/api/v1/control`; the daemon checks the token's scope, validates the call, runs it with captured output, and returns the text; the engine parses the exit marker as it does for local RPC.
  - **Outcome:** the operator sees the NUC's status and the NUC's exit code.
  - **Covered by:** R1, R3, R6, R7, R10.
- F2. Change a remote setting
  - **Trigger:** `aiur --instance railway-1 set agent.max_concurrent_builds 2`.
  - **Steps:** the call reaches the daemon with a write token; the daemon merges the value over its YAML, validates with its own schema, writes the override file, and writes an audit record; the config store reloads within its 1 s poll.
  - **Outcome:** the new cap is live; `aiur --instance railway-1 set --list` shows it with revision and actor.
  - **Covered by:** R8, R9, R11, R12.
- F3. One Executor for the fleet
  - **Trigger:** the Executor runs `aiur --instance all executor-wait --as fleet-executor --json`.
  - **Steps:** one long-poll per instance, each acknowledging what the previous batch returned; the first non-empty answer returns; the others are cancelled with nothing consumed.
  - **Outcome:** records arrive tagged with their instance; nothing is lost if a reply is dropped.
  - **Covered by:** R17, R18.
- F4. Owner instance dies
  - **Trigger:** the NUC owns `build-lane:voice` and stops heartbeating.
  - **Steps:** its heartbeat expires in the #5947 store; other instances stop seeing its rules; the next poll treats voice tickets as pool tickets; the claim lease decides which instance takes each one.
  - **Outcome:** voice work continues on another instance with no label edits.
  - **Covered by:** R15, R16.

### Acceptance Examples

- AE1. **Covers R4.** Given `pc` and `nuc` are registered and `nuc` is down, when the operator runs `aiur --instance all agents`, then `pc`'s rows print under a `pc` heading, `nuc` prints `unreachable` with the transport error, and the exit code is nonzero.
- AE2. **Covers R4.** Given any registry, when the operator runs `aiur --instance all pause`, then the CLI refuses before any network call and names `write` scope as the reason. Given a client whose read list wrongly includes `alerts ack`, when it fans out `alerts ack` with write tokens, then each daemon returns 403 `scope_denied` because the call carries `max_scope: "read"`, and nothing runs.
- AE3. **Covers R7.** Given a read-scope token, when it calls `Aiur.AgentControlCLI.set_max_agents(3)`, then the daemon returns 403 `scope_denied` and writes one audit record with outcome `refused`.
- AE4. **Covers R9.** Given a client that knows `agent.max_concurrent_builds` and a daemon whose allowlist lacks it, when the client sets it, then the daemon refuses with `unknown setting on this build (<version>)` and nothing is stored.
- AE5. **Covers R13.** Given a stored override that a newer build rejects, when that build boots, then the daemon starts, the override is moved aside, and `aiur status` shows a `config.override_rejected` attention.
- AE6. **Covers R15.** Given `nuc` owns label `build-lane:voice` and both instances are live, when both poll a `todo` voice ticket, then only `nuc` tries to take its lease.
- AE7. **Covers R18.** Given the Executor received wakes 41-44 from `nuc` and the reply was lost in transit, when it waits again, then `nuc` delivers 41-44 again because the client acknowledged only through 40.
- AE8. **Covers R19.** Given a daemon started through a path that did not set `ERL_EPMD_ADDRESS=127.0.0.1`, so epmd listens beyond loopback, when it boots with distribution on, then it exits with a message naming epmd and the missing setting.

### Scope Boundaries

- Not a second CLI or a REST redesign: remote commands are the existing commands.
- No remote `stop`, `restart`, or launch: those manage processes on the host and stay with the host's service manager (`docker exec`, Railway restart, systemd).
- No streaming `listen` over HTTP in v1; `executor-wait` covers the Executor loop.
- No browser sign-in work (#5611, #5942), no worker protocol (#5953), no multi-repo routing (#5938).
- No dashboard view of remote instances; #5950 owns the roster page.

#### Deferred for later

- `aiur remote add` helper and roster-driven registry suggestions.
- An `AIUR_INSTANCE` environment default for agent sessions.
- Compare-and-set (`--expect-revision`) for concurrent `aiur set` writers.
- Auditing local (non-HTTP) control calls.
- Server-pushed wake streaming (SSE), which #5695 may cover.

### Dependencies / Assumptions

- #5945 provides the bearer-token plug, token store, and `read`/`write` scopes. This plan assumes the token part can merge before #5942 (see amendment A1 in the pack README).
- #5947 provides instance id, heartbeat, and the shared store. Only MIC-008 needs it.
- Remote instances are reachable over HTTPS: Railway terminates TLS at its edge; home machines are reached on the tailnet through `tailscale serve`, which the host allowlist already accepts for loopback listeners (`src/lib/aiur_web/host_allowlist.ex:15-29`, `src/lib/aiur/http_server.ex:69`).

### Sources / Research

- CLI transport: one `case` dispatch in `packaging/npm/aiur-cli/libexec/aiur-engine.sh:174-405`; every control command calls `run_control_rpc "<expr>"` (`packaging/npm/aiur-cli/libexec/engine/control.sh:311-441`); markers `__AIUR_CONTROL_EXIT__:` and `__AIUR_CONTROL_ERROR__:` (`src/lib/aiur/control_cli/protocol.ex:5-6`); facade `src/lib/aiur/agent_control_cli.ex:1-63`.
- HTTP: routes `src/lib/aiur_web/router.ex:75-102`, `src/lib/aiur_web/routes/api.ex:9-56`; bearer precedent `src/lib/aiur_web/supervisor_auth.ex:18-82`; bearer writes still need Origin and `X-Aiur-Request` (`src/lib/aiur_web/routes/decisions.ex:12`); no TLS listener (`src/lib/aiur/http_server.ex:76`).
- Config: unknown keys dropped by `cast` (`src/lib/aiur/config/schema.ex:202-214`); hot reload every 1 s (`src/lib/aiur/workflow_store.ex:16-22`); last-good kept on a rejected reload since #3980 (`src/lib/aiur/workflow_store/reload.ex:85-100`); boot has no fallback (`src/lib/aiur/workflow_store.ex:218-229`); `aiur set max-agents` persists in `control-lifecycle.json` (`src/lib/aiur/orchestrator/slots.ex:65-76`).
- Ownership: `instance.role` and `instance.ignore.*` (`src/lib/aiur/config/schema/instance.ex:1-51`, `src/lib/aiur/instance.ex`); dispatch scoping by `tracker.github.label_prefix` (`src/lib/aiur/config/schema/tracker.ex:30-32`).
- Executor: wake journal and cursor under the repo-keyed executor directory (`src/lib/aiur/executor/state_paths.ex:12-30`); `wake_id` is a per-file counter (`src/lib/aiur/executor_wake_inbox.ex:134`, `src/lib/aiur/executor_wake_inbox/storage.ex:132`); one cursor integer (`storage.ex:139-167`); print-then-acknowledge (`src/lib/aiur/executor_attention/cli.ex:162-168`).
- GitHub budget is host-local (`src/lib/aiur/github/budget.ex:2-6`; `website/docs-app/apis/github-budgets.md:5`). This plan adds no GitHub calls; #5949 owns the shared budget.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Wire contract `aiur.control.call` v1** (owned by MIC-001, quoted by MIC-002/003/004/006). Inherits Key Decision 1.

  ```text
  POST /api/v1/control
  Authorization: Bearer <token>
  {"contract":"aiur.control.call","contract_version":1,
   "expression":"Aiur.AgentControlCLI.agents(all: true)",
   "command":"agents","timeout_ms":10000,"max_scope":"read"}

  200 {"contract":"aiur.control.result","contract_version":1,
       "instance_id":"<machine-id>/<instance-key>","build":{"version":"0.x.y","commit":"abc1234"},
       "output":"...stdout text...\n__AIUR_CONTROL_EXIT__:0\n","elapsed_ms":84}
  401 {"error":{"code":"unauthenticated"}}
  403 {"error":{"code":"scope_denied","required_scope":"write"}}
  413 {"error":{"code":"body_too_large","limit_bytes":65536}}
  422 {"error":{"code":"call_refused","reason":"parse_error|not_allowlisted|non_literal_argument|option_not_allowed|denied_remote|unknown_on_build","detail":"<offending name>","build":{...}}}
  504 {"error":{"code":"timeout","timeout_ms":10000}}
  ```

  `output` is fed to the existing marker parser unchanged. `timeout_ms` is capped by the server at 660 000 for `executor_wait` (client `--timeout` ≤ 600 s plus margin) and 30 000 otherwise; the cap derives from the parsed function, not from `command`. `command` is informational only (it appears in client error messages); the server never uses it for a decision. `max_scope` is optional (`read` or `write`, default `write`); a call whose parsed scope exceeds it is 403 `scope_denied`. The body limit is real only if the endpoint reads this path with its own limit: `Plug.Parsers` runs in the endpoint before the router (`src/lib/aiur_web/endpoint.ex:74`, default 8 MB), so MIC-002 gives `/api/v1/control` a body reader with `length: 65_536` that answers 413 before any JSON decode, and checks the token before `Code.string_to_quoted`.
- KTD2. **Validator accepts a literal-only call with an argument schema.** `Code.string_to_quoted(expr, existing_atoms_only: true)`; the AST must be one remote call `Mod.fun(args)`. The module is matched on its alias segment list, never built with `Module.concat`. The allowlist writes each module as a literal segment list (`[:Aiur, :AgentControlCLI]`), so the segment atoms exist on every build; without that, `existing_atoms_only` refuses even loaded modules (`String.Chars.x()` fails with `unsafe atom does not exist: Chars` on Elixir 1.19). `{Mod, fun, arity}` must be in the allowlist. Each argument is a literal (string, integer, float, boolean, `nil`, existing atom, list, 2-tuple, keyword list) or `Base.decode64!("<literal>")`, up to nesting depth 6. Terms come from a hand-written walker, never `Code.eval_*`. Literal-only is not enough on its own: options such as `path:` (`src/lib/aiur/harness_session_cli.ex:14-15`), `telemetry_file:` (`src/lib/aiur/analytics_cli.ex:108`), `source:` (`src/lib/aiur/build_orders_cli.ex:41`, a module that is then called), `decision_store:` (`src/lib/aiur/commands_cli.ex:136`) and `server:` (`src/lib/aiur/build_queue_cli.ex:27`) would let a caller read files, call a module, or message any registered process. (`root:` on `build_orders` is a root ticket id that the engine sends; it stays allowed.) So each allowlist entry also lists the keyword keys the engine emits for that function, with a value constraint, not only a type: the regex, enum, or range the engine wrapper checks in bash before it builds the call (the census records each one). Any other key is refused. Caller-supplied identity keys (`who:`, `actor:`, `set_by:`, `owner:`) are refused on remote calls; the actor comes from the token (KTD4). `env:` on `executor_wait` is refused on remote calls (MIC-006). **One `unknown_on_build` rule (R9):** (1) every `existing_atoms_only` failure (`unsafe atom does not exist: <name>`, whether the atom is the module, function, a positional atom, or a keyword key; Elixir reports them identically) maps to `unknown_on_build` with `detail: <name>`; (2) a call to an allowlisted module whose `{fun, arity}` this build's allowlist lacks is `unknown_on_build`, because a newer function's name atom may already exist (`set`, `list`). A call to a module outside the allowlist is `not_allowlisted`; an existing-atom keyword key that the entry does not list is `option_not_allowed`. Every 422 body carries `build`. A client treats `unknown_on_build` and `option_not_allowed` for an option it sent on purpose (for example `defer_ack`) as "unsupported on this build": it reports that instance and never retries with fewer options. Rejected alternative: a structured `{fun, args}` JSON body, which would rewrite ~60 engine call sites.
- KTD3. **The allowlist is one module with a class per `{module, function, arity}`** (`Aiur.ControlCall.Allowlist`): `:read`, `:write`, `:deny` (local only), or a class function of the arguments. Targets: `Aiur.AgentControlCLI`, `Aiur.Handoff.CLI`, `Aiur.HarnessSessionCLI`, `Aiur.TicketUsageCLI`, `Aiur.ExecutorSweep.CLI`, `Aiur.PrMerge.Record`. Functions whose arguments decide read or write (`queue`, `epic`, `feature`, `experiments`, `alerts`, `executor_sweep`, `watch`) have a class function `(args -> :read | :write)`; `watch` is `:read` only for `mode: :full`, because its default changes mode overwrites one global baseline. **Human-only rule (R20):** any function whose engine wrapper enforces a human, TTY, or non-agent check is `:deny`; today that is `operator_answer/1` and `operator_answer_preview/1` (`packaging/npm/aiur-cli/libexec/engine/executor_commands.sh:87-114`; the daemon side checks only `operator: true` and the retyped id, both caller-supplied, `src/lib/aiur/operator_answer_cli.ex:57-90`). A test enumerates `Aiur.AgentControlCLI.__info__(:functions)` and fails on any unclassified function. Positional arguments are typed per entry, as option keys are: an atom is accepted in a positional slot only where the entry names that atom set. Facade functions the engine never calls remotely (`prepare_handoff`, `main_watch_*`, `usage/1` and `usage/2` (their argument is a server name, so they could call any registered process; only `usage/0` is `:read`), `usage_bar`, streaming `executor_listen`) and engine expressions that are not a single call (the handoff prepare block in `packaging/npm/aiur-cli/libexec/engine/handoff.sh:5-13`, the piped `Aiur.PrMerge.Record.publish` in `aiur-engine.sh:217`) are `:deny`.
- KTD4. **Output capture uses a group-leader swap in a task.** The call runs in an unlinked task (`Task.Supervisor.async_nolink`, so a crash cannot take down the HTTP handler and a write can outlive a 504) whose group leader is a `StringIO`. Inside the task the call is wrapped the way `StatusCLI.Sections.capture/1` does it: a raise or exit becomes the captured output plus `__AIUR_CONTROL_ERROR__:<one-line reason>` and `__AIUR_CONTROL_EXIT__:1`, returned as 200, as local rpc reports it. The task closes its `StringIO` when it ends, including after a 504; the HTTP handler returns its contents. Errors already travel as stdout markers (`src/lib/aiur/control_cli/protocol.ex:144-147`), as they do for local rpc. On timeout, a `:read` call is killed; a `:write` call runs to completion and the client gets 504 with outcome unknown, matching local rpc, where the call inside the daemon also finishes after the client gives up. **Actor channel:** `run/3` takes the actor (`token:<name>` for remote calls) and, inside the task, before it applies the function, stores it with `Aiur.ControlCall.put_actor/1`; functions that record an actor (`set`, `unset`, take/release) read `Aiur.ControlCall.actor/0`, which returns `local:$USER` when unset (local rpc). The value lives in the task's own process, so it is not lost across the `Task` boundary. Known difference from local output: `:io.columns()` has no terminal behind `StringIO` (`src/lib/aiur/github_cost_cli.ex:472`), so wide tables fall back to their default width.
- KTD5. **The machine endpoint skips `api_write`.** Bearer requests carry no cookies, so the Origin and `X-Aiur-Request` checks (`src/lib/aiur_web/router.ex:55-58`) do not apply; the route sits before the `/api/v1/:issue_identifier` catch-all (`src/lib/aiur_web/router.ex:77-102`).
- KTD6. **Audit file is daemon-owned.** `<run-log-root>/log/control-audit.ndjson`, next to `event-publications.ndjson` (AGENTS.md "Per-issue workspaces"). Records store the function, arity, and a SHA-256 of the expression, not argument text, because `message` arguments can hold anything.
- KTD7. **Registry file is `~/.aiur/remote-instances.yaml`.** The client refuses a `token_file` that is not mode 0600. Write tokens default to `token_env` (documented), and the daemon's agent-environment scrub (#2356) also removes `AIUR_TOKEN_*`, so agents on the Executor machine do not inherit fleet write tokens through the environment. The proposed `~/.aiur/instances.yaml` would sit beside the existing `~/.aiur/instances/<key>/` secret directory (`src/lib/aiur/http_server.ex:352-361`) and the engine's `instances/*.instance` records (`packaging/npm/aiur-cli/libexec/engine/instance.sh:8-18`), which name different things.

  ```yaml
  version: 1
  instances:
    nuc:
      url: https://nuc.example-tailnet.ts.net
      token_file: ~/.aiur/tokens/nuc-read   # mode 0600; read tokens only. Write tokens: token_env
    railway-1:
      url: https://aiur-1.example.com
      token_env: AIUR_TOKEN_RAILWAY_1
  ```

- KTD8. **Overrides merge where the workflow is loaded.** One function, `Aiur.Config.Overrides.apply/1`, merges the overrides into the workflow config map. It is called from `Reload.load_state` (`src/lib/aiur/workflow_store.ex:220`, `src/lib/aiur/workflow_store/reload.ex`) and from every path that loads the workflow without the store (`Workflow.load/1`, boot settings at `src/lib/aiur.ex:38`, the stale-cache and absent-store fallbacks, `reload_without_store`), so no path sees YAML alone. One validator, `ReloadRejection.validate/1` (via `Config.settings_from`), checks `set` candidates, reloads and boot; `WorkflowStore.init` does not validate today, so MIC-007 adds that call. Thus `ReloadRejection.validate` (`src/lib/aiur/workflow_store/reload_rejection.ex:29-35`), the last-good guard, and boot all see YAML plus overrides as one config. The overrides file joins the reload stamp (`reload.ex:167-181`), so a write goes live through the existing 1 s poll. The path comes from the environment only: `<dashboard secret root>/<instance key>/config-overrides.json`, with the key from `Aiur.Identity.instance_key/0` (the engine exports `AIUR_INSTANCE_KEY`) and the root from the same resolution the dashboard secret uses (`src/lib/aiur/http_server.ex:352-361`), so #5940's state volume moves both together. (`AIUR_STATE_DIR` does not exist in the code yet; #5940 owns it.) With no instance key, `set` is refused with a named error and the daemon boots with no overrides layer. It must not be derived from config: `decision_state_dir` (`src/lib/aiur/config/paths.ex:42-60`) resolves through `Config.settings!()`, which would loop. Load validates entry by entry: an entry whose key this build's allowlist lacks (for example after a rollback to an older build), or whose value fails `ReloadRejection.validate` together with YAML and the entries accepted before it, is moved to `config-overrides.rejected-<ts>.json`; the other entries stay live. Each rejected key is named in one `config.override_rejected` attention (R9, R13).
- KTD9. **`aiur set` keys v1** (each key states whether it applies live or at restart; MIC-007 lists them). `max-agents` keeps its current path (`src/lib/aiur/orchestrator/slots.ex:65-76`). New allowlisted dotted keys: `agent.max_concurrent_builds`, `agent.max_concurrent_agents_by_state`, `agent.priority`, `agent.routing`, `build_queue.max_active_sets`, `instance.ignore.tickets`; MIC-008 adds `instance.owns`. `instance.role` stays YAML-only because it is read once at boot (`src/lib/aiur.ex:77-83`).
- KTD10. **Deferred acknowledgement for remote waits.** `executor_wait(ack_through: N, defer_ack: true)` acknowledges through `N` before waiting and does not acknowledge the batch it returns. The client stores the highest delivered `wake_id` per instance and sends it on the next call. The local default keeps print-then-acknowledge. `ack_through` at or below the current cursor is a no-op; `ack_through` above the newest id in the journal returns a distinct `journal_reset` error (journal trimmed or replaced, for example a new volume), and the client then resets its cursor for that instance to 0 and warns. The client keys its cursor by the result's `instance_id`, not only by registry name.
- KTD11. **Ownership predicate.** A ticket is eligible on instance I when it matches one of I's `instance.owns` rules, or when it matches no rule of any live instance and I is a pool member (`instance.pool`, default true). Live means an instance-level heartbeat within the #5947 expiry, with `dispatching: true` (false while the instance is globally paused or its workflow is paused), so a paused owner does not hold its tickets. Instance heartbeats are separate from per-ticket leases (an idle owner holds no lease but still heartbeats); #5947 provides them and a list-live-instances read (amendment A3). Unknown store state fails closed for all new dispatch, owned tickets included, matching #5947 AC6: an owner that cannot reach the store cannot take a lease, and its peer may already hold one.

### High-Level Technical Design

```mermaid
flowchart LR
  subgraph Client["Operator or Executor machine"]
    CLI["aiur engine\nrun_control_rpc"] -->|no --instance| RPC["bin/aiur rpc\n(loopback distribution)"]
    CLI -->|--instance name| HTTP["remote transport\nregistry + token"]
  end
  HTTP -->|HTTPS, bearer| EP["POST /api/v1/control"]
  subgraph Daemon["Each instance"]
    EP --> AUTH["#5945 token plug\nread/write scope"]
    AUTH --> VAL["ControlCall validator\nallowlist + literals"]
    VAL --> RUN["captured call\nAiur.AgentControlCLI.*"]
    RUN --> AUD["control-audit.ndjson"]
    RPC --> FN["Aiur.AgentControlCLI.*\n(same functions)"]
    RUN --> OVR["config overrides file\n(aiur set)"]
    OVR --> CFG["Config.settings_from\nYAML + overrides -> Schema.parse"]
  end
  Daemon -. heartbeat with instance.owns .-> STORE[("#5947 lease store")]
```

Both transports end in the same function call, so parity is structural. The only new server code paths are the validator, the capture, the audit append, and the overrides layer.

### Implementation Constraints

- Docs ship with each ticket (AGENTS.md). `website/docs-app/reference/cli.md` is at its 500-line cap, so each CLI ticket consolidates rows in the same change.
- The engine has three command lists that must agree: `packaging/npm/aiur-cli/bin/aiur.js:226-233`, the engine `case`, and `cli.md` (checked by `website/docs-app/scripts/check-cli-reference.sh`).
- Tests that touch `~/.aiur` use a temp HOME (AGENTS.md "Reading real state").

### Sequencing

Leveled phases from the hard-dependency graph (pack `graph.json`):

| Phase | Tickets | Testable after merge |
|---|---|---|
| 1 | MIC-001, MIC-003, MIC-005, MIC-007, MIC-009, plus existing #5945 (amended) and #5947 | `aiur set --list` and new keys locally (MIC-007); boot refuses non-loopback distribution (MIC-009) |
| 2 | MIC-002, MIC-004, MIC-008 | **`aiur --instance nuc status`** (first remote slice); `--instance all agents`; `instance.owns` (needs #5947) |
| 3 | MIC-006 | one Executor for all instances |
| 4 | MIC-010 | merged-base acceptance on two live instances |

### System-Wide Impact

- **Auth boundary:** a new write path into the daemon from the network. Mitigated by the allowlist, literal-only arguments, scoped tokens, audit, HTTPS-or-tailnet-only client, and the loopback distribution check.
- **Executor workflow:** the `aiur-run` skill gains a fleet mode; per-machine Executors retire once MIC-006 lands (decision D10).
- **Config precedence:** a third layer (session `max-agents`, then overrides, then YAML) becomes visible in `aiur set --list`.

### Risks & Dependencies

| Risk | Mitigation |
|---|---|
| Validator bypass yields remote code execution | Literal-only walker, no eval, `existing_atoms_only`, property test with hostile expressions; security review on MIC-001 |
| #5945 stays blocked behind #5942 and #5611 | Amendment A1 splits the token part from the public-bind part |
| Remote `executor-wait` sends the caller's harness env (pid, cwd) that the daemon checks on its own host (`src/lib/aiur/harness_session.ex:79-113`) | Remote mode omits `env:` (MIC-006) |
| Long-poll through proxies times out | Client caps `--timeout` at 600 s for remote waits; Railway and tailscale serve hold idle HTTP longer than that (verify in MIC-010) |
| Ownership rules disagree across instances | Lease from #5947 prevents double dispatch; `aiur --instance all status` shows each instance's rules |
| cli.md 500-line cap collides across tickets | Hot-file exception (rebase-resolvable row edits, not an edge); each ticket consolidates rows |
| A write token is close to full control (it can message agents and change routing) | Docs say so; tokens live in 0600 files or env, scoped `read` by default; audit names the token |
| An agent on the Executor machine runs as the same Unix user and can read token files, then `curl` the endpoint directly; a write token can `message` an agent that has a shell, which is code execution on that instance | Write tokens in `token_env`, scrubbed from agent environments with `AIUR_TOKEN_*` (MIC-003 test); read tokens in 0600 files; the server-side `max_scope` and allowlist do not depend on the client; human-only functions are `:deny` (R20). Residual: an agent that can read the Executor's own process environment still sees it; run the fleet Executor outside agent workspaces |
| A client-side read list drifts from the server allowlist and `--instance all` fans out a write | Server enforces `max_scope: read` on fan-out (R4); the client list is only an early exit |
| A 504 on a write leaves the outcome unknown and a retry may repeat it | The client never retries a write automatically; it prints "outcome unknown" and the audit file records the call. Idempotency keys are deferred (DF-8) |
| Abandoned remote waits pile up on a daemon | One live wait per consumer per instance: a new wait ends the previous one (MIC-005) |

---

## Implementation Units

| U-ID | Title | Key files | Depends on |
|---|---|---|---|
| U1 (MIC-001) | Control call contract and validator | `src/lib/aiur/control_call.ex`, `src/lib/aiur/control_call/allowlist.ex` | — |
| U2 (MIC-002) | Machine control endpoint with audit | `src/lib/aiur_web/routes/control.ex`, `src/lib/aiur_web/controllers/control_controller.ex` | U1, #5945 |
| U3 (MIC-003) | CLI remote target and registry | `packaging/npm/aiur-cli/libexec/engine/remote.sh`, `control.sh`, `aiur-engine.sh` | — |
| U4 (MIC-004) | `--instance all` for reads | `packaging/npm/aiur-cli/libexec/engine/remote.sh` | U1, U3 |
| U5 (MIC-005) | Deferred acknowledgement for waits | `src/lib/aiur/executor_attention/cli.ex` | — |
| U6 (MIC-006) | One Executor across instances | `remote.sh`, `executor_commands.sh`, `.claude/skills/aiur-run/SKILL.md` | U2, U4, U5 |
| U7 (MIC-007) | Runtime settings overrides | `src/lib/aiur/config/overrides.ex`, `src/lib/aiur/config.ex` | — |
| U8 (MIC-008) | Ticket ownership rules | `src/lib/aiur/config/schema/instance.ex`, `src/lib/aiur/instance.ex` | U7, #5947 |
| U9 (MIC-009) | Loopback distribution check | `src/lib/aiur/distribution.ex`, `src/lib/aiur.ex` | — |
| U10 (MIC-010) | Feature acceptance on two instances | evidence only | U2, U4, U6, U7, U8, U9 |

Each unit's full contract (goal, acceptance, failing test, docs, files, edges, complexity, lane, first slice) is the ticket document in `docs/plans/2026-10-23-multi-instance-control/tickets/`. The ticket documents are authoritative; this section is the index.

### U1. Control call contract and validator

- **Goal:** one pure module that turns an expression string into an allowed `{module, function, args, scope}` or a named refusal, and runs it with captured output.
- **Requirements:** R6, R7, R9, R20.
- **Dependencies:** none.
- **Files:** `src/lib/aiur/control_call.ex`, `src/lib/aiur/control_call/allowlist.ex`, `src/test/aiur/control_call_test.exs`, `src/test/aiur/control_call/engine_census_test.exs`.
- **Approach:** KTD1-KTD4.
- **Test scenarios:** every static `run_control_rpc` template in `packaging/npm/aiur-cli/libexec/` parses and is `:read`, `:write`, or named `:deny`; hostile inputs (`System.cmd(...)`, `:os.cmd`, pipes, sigils, `&` captures, nested calls other than `Base.decode64!/1`, extra option keys such as `path:`, `server:`, `telemetry_file:`) are refused; an unknown function name returns `unknown_on_build`; an unclassified facade function fails the allowlist test; captured output includes the exit marker.
- **Verification:** `mix test test/aiur/control_call_test.exs test/aiur/control_call/engine_census_test.exs`.

### U2. Machine control endpoint with audit

- **Goal:** `POST /api/v1/control` runs a validated call for a bearer token with the right scope and writes an audit line.
- **Requirements:** R6, R7, R8, R9.
- **Dependencies:** U1, #5945.
- **Files:** `src/lib/aiur_web/routes/control.ex`, `src/lib/aiur_web/controllers/control_controller.ex`, `src/lib/aiur/control_call/audit.ex`, `src/lib/aiur_web/router.ex`, `src/test/aiur_web/controllers/control_controller_test.exs`.
- **Test scenarios:** Covers AE3; read token runs `status()` and gets the marker text; revoked token 401; write by write token appends audit; the route is not swallowed by `/api/v1/:issue_identifier`; timeout returns 504.
- **Verification:** controller tests pass; the route table in `website/docs-app/reference/` lists the endpoint.

### U3. CLI remote target and registry

- **Goal:** `aiur --instance <name> <cmd>` sends the engine's call over HTTPS and prints the remote output with the remote exit code.
- **Requirements:** R1, R2, R3, R5, R10.
- **Dependencies:** none (built against KTD1).
- **Files:** `packaging/npm/aiur-cli/libexec/engine/remote.sh` (new), `packaging/npm/aiur-cli/libexec/engine/control.sh`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `packaging/npm/aiur-cli/bin/aiur.js`, `packaging/npm/aiur-cli/test/launcher-remote.test.mjs`.
- **Test scenarios:** fake HTTPS server returns marker text, exit code propagates; no `--instance` path unchanged; `stop --instance nuc` refused before any network call; `http://` non-loopback, non-tailnet URL refused; token never printed in errors.
- **Verification:** `bun test packaging/npm/aiur-cli/test/launcher-remote.test.mjs`.

### U4. `--instance all` for reads

- **Goal:** fan a read-scope command out to every registry entry and label the results.
- **Requirements:** R4.
- **Dependencies:** U1 (read list fixture generated from the allowlist), U3.
- **Test scenarios:** Covers AE1, AE2.

### U5. Deferred acknowledgement for waits

- **Goal:** `executor_wait` can acknowledge through a client-supplied id and leave the returned batch unacknowledged.
- **Requirements:** R18.
- **Dependencies:** none.
- **Test scenarios:** Covers AE7; `defer_ack: true` leaves the cursor unchanged after return; `ack_through: N` advances to N before waiting; owner-only rule unchanged.

### U6. One Executor across instances

- **Goal:** `aiur --instance all executor-wait` merges wakes from every instance with at-least-once delivery.
- **Requirements:** R17, R18.
- **Dependencies:** U2, U4, U5.

### U7. Runtime settings overrides

- **Goal:** `aiur set <key> <value>`, `aiur set --list`, `aiur set --unset <key>` for allowlisted keys, validated by the running build.
- **Requirements:** R9, R11, R12, R13.
- **Dependencies:** none.
- **Test scenarios:** Covers AE4, AE5.

### U8. Ticket ownership rules

- **Goal:** `instance.owns` and `instance.pool` decide which instance may claim a ticket.
- **Requirements:** R14, R15, R16.
- **Dependencies:** U7, #5947.
- **Test scenarios:** Covers AE6; owner heartbeat expiry returns tickets to the pool (F4).

### U9. Loopback distribution check

- **Goal:** the daemon refuses to start distributed unless epmd and the distribution listener are loopback-only.
- **Requirements:** R19.
- **Dependencies:** none.
- **Test scenarios:** Covers AE8.

### U10. Feature acceptance on two instances

- **Goal:** merged-base evidence of F1-F4 on two real instances.
- **Dependencies:** U2, U4, U6, U7, U8, U9.

---

## Verification Contract

| Gate | Command or evidence | Applies to |
|---|---|---|
| Elixir unit and controller tests | `env -C src mise exec -- mix test <touched test files>` with an isolated HOME and GitHub tokens unset | U1, U2, U5, U7, U8, U9 |
| Launcher tests | `bun test packaging/npm/aiur-cli/test/<file>` | U3, U4, U6 |
| Docs checkers | `python3 scripts/check-config-docs.py`; `website/docs-app/scripts/check-cli-reference.sh` | U3, U4, U6, U7, U8 |
| Mutation check | revert the production hunk, the named test fails; restore, it passes (AGENTS.md) | every ticket |
| Security review | `ce-code-review` with a security lens on the validator and endpoint | U1, U2 |
| Manual end to end | AGENTS.md "Manual testing": real CLI against two running instances | U10 |

## Definition of Done

- Every ticket's acceptance list holds on current main, with its failing-without-change test named in the PR body.
- `aiur --instance nuc status`, `aiur --instance all agents`, `aiur --instance nuc set ...`, and `aiur --instance all executor-wait` work against two live instances (MIC-010 evidence). Railway-edge and container checks run when a container instance exists; otherwise MIC-010 records them as not run.
- Docs updated in the same PRs: `reference/cli.md` (≤ 500 lines), configuration reference entries for new keys, the quick-start two-instance section, and the `aiur-run` skill.
- No abandoned-attempt code remains in any diff.
