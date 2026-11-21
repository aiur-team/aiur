# MIC-001 — Control call contract: allowlisted, literal-only calls with captured output

**Kind:** executable
**Provenance:** planned in plan v1
**Extends:** new; it is the server half of #5945's machine clients (it gives #5945's `read`/`write` scopes a per-command meaning)
**Complexity:** 3 — defines a new public contract and a security-critical parser
**Risk:** high (remote code execution if the validator is wrong)
**Lane:** PC
**Phase hint:** 1
**Depends on:** none
**Requirements:** R6, R7, R9, R20
**Researched at:** ab0c21424

Plan context: [plan](../../2026-10-23-001-feat-multi-instance-control-plan.md) (KTD1-KTD4, U1) · [pack index and graph](../README.md) · [decisions](../questions-or-commands.md)

## Outcome

The daemon has one function that takes the exact call string the CLI engine sends to `bin/aiur rpc`, decides whether it may run remotely and with which scope, and runs it with its printed output captured.

## Context and evidence

- Every daemon control command in the engine is one `run_control_rpc "<Elixir expression>"` call (`packaging/npm/aiur-cli/libexec/engine/control.sh:311-441`). Examples: `Aiur.AgentControlCLI.status()` (`engine/commands.sh:43`), `Aiur.AgentControlCLI.message("123", Base.decode64!("..."), "id")` (`engine/commands.sh:217`), `Aiur.AgentControlCLI.executor_wait(timeout_ms: 300000, json: true, ...)` (`engine/executor_commands.sh:235`).
- The control facade is `src/lib/aiur/agent_control_cli.ex:1-63`. Other RPC targets: `Aiur.Handoff.CLI`, `Aiur.HarnessSessionCLI.rpc`, `Aiur.TicketUsageCLI.rpc`, `Aiur.ExecutorSweep.CLI.rpc`, `Aiur.PrMerge.Record`.
- Results travel as stdout text with `__AIUR_CONTROL_EXIT__:<n>` and `__AIUR_CONTROL_ERROR__:` lines (`src/lib/aiur/control_cli/protocol.ex:5-6,144-156`). There is no shared JSON envelope, so forwarding output is the only way to keep remote output equal to local output.

## Scope

- `Aiur.ControlCall.parse(expression) :: {:ok, %{module, function, args, scope}} | {:error, reason}` with reasons `parse_error`, `not_allowlisted`, `non_literal_argument`, `option_not_allowed`, `denied_remote`, `unknown_on_build`.
- `Aiur.ControlCall.run(call, timeout_ms, actor) :: {:ok, output} | {:error, :timeout}` — runs in an unlinked task (`Task.Supervisor.async_nolink`) with a `StringIO` group leader, wrapped as `StatusCLI.Sections.capture/1` does: a raise or exit returns the captured output plus `__AIUR_CONTROL_ERROR__:<reason>` and `__AIUR_CONTROL_EXIT__:1`; the task closes its `StringIO` when it ends; on timeout a `:read` call is killed and a `:write` call is left to finish (KTD4). Inside the task, before the call, it stores the actor with `put_actor/1`; `Aiur.ControlCall.actor/0` returns it, or `local:$USER` when unset (local rpc). Functions that record an actor read it there.
- `parse/2` takes `max_scope` (`:read | :write`, default `:write`) and returns `{:error, :scope_exceeds_max}` when the parsed scope is higher (MIC-002 maps it to 403).
- `Aiur.ControlCall.Allowlist`: a map from `{segments, function, arity}` (segments as a literal list such as `[:Aiur, :AgentControlCLI]`, so the atoms exist for `existing_atoms_only`) to `%{class: :read | :write | :deny | (args -> :read | :write), options: %{key => constraint}}`, built from the read/mutating split below. `options` lists exactly the keyword keys the engine emits for that function, each with the constraint the engine wrapper checks in bash (regex, enum, integer range), not only a type; any other key is `option_not_allowed`, a value outside its constraint is `non_literal_argument`.
- Remote-only refusals: caller-supplied identity keys (`who:`, `actor:`, `set_by:`, `owner:`) and `env:` on `executor_wait` are `option_not_allowed` when `parse/2` is called with `remote: true`.
- Wire contract constants for `aiur.control.call` / `aiur.control.result` v1 (KTD1), as module attributes that MIC-002 and the client tests quote.

## Non-goals

- HTTP routing, auth, and audit (MIC-002).
- Changing any command's output.

## Existing owner and reuse target

- Parse with `Code.string_to_quoted(expr, existing_atoms_only: true)`.
- Mirror the exit-marker helpers in `src/lib/aiur/control_cli/protocol.ex`.
- Read-only vs mutating classification from the research census: read = status, usage, accounts, agents, commands, units, build_orders, analytics, github_cost, github_usage, capabilities, ticket-usage, alerts (no ack), executor_sweep (no apply), watch (`mode: :full` only; the default changes mode overwrites one global baseline, so it is `:write`), queue show, epic show/list, feature show, experiments read verbs, executor_roster, executor_session, executor_subscriptions; everything else write. `executor_wait` is write (it claims and acknowledges). Functions whose `argv:`/opts decide read vs write (`queue`, `epic`, `feature`, `experiments`, `alerts`, `executor_sweep`, `watch`) are classified `:write` unless the parsed opts select a read verb — the allowlist entry is a function `(args -> scope)` for these.

## Contract and invariants

Accepted AST: exactly one remote call `{{:., _, [{:__aliases__, _, mod}, fun]}, _, args}`, with `mod` matched as a segment list against the allowlist (never `Module.concat`). Each argument is a string, integer, float, boolean, `nil`, existing atom, list, 2-tuple, or keyword list of these, or `Base.decode64!(<string literal>)`, nested at most 6 deep. The `env: [{"CLAUDE_PID", "..."}]` tuple list that `executor_wait` receives (`packaging/npm/aiur-cli/libexec/aiur-executor-session.sh:23-31`) must parse. Terms come from a hand-written walker. `Code.eval_*` is never called. Anything else is refused. One rule for R9 (KTD2): (1) every `existing_atoms_only` failure (`unsafe atom does not exist: <name>`; module, function, positional atom or keyword key, which Elixir reports identically) returns `unknown_on_build` with that name; (2) a call to an allowlisted module whose `{fun, arity}` the allowlist lacks returns `unknown_on_build`, because a newer function's name atom may already exist. A module outside the allowlist is `not_allowlisted`; an existing-atom keyword key the entry does not list is `option_not_allowed`. The 422 body carries the build in every case. Positional arguments are typed per entry like option keys: an atom is accepted in a positional slot only where the entry names that atom set.

**Human-only functions are `:deny` (R20).** Any function whose engine wrapper enforces a human, TTY, or non-agent check is local only, because that check runs in bash and does not travel over HTTP. Today: `operator_answer/1` and `operator_answer_preview/1` (`engine/executor_commands.sh:87-114`; the daemon checks only `operator: true` and the retyped id, both caller-supplied, `src/lib/aiur/operator_answer_cli.ex:57-90`). The census records, for each engine wrapper, whether it has such a check, and a test fails if a wrapper with one maps to a non-`:deny` function.

```elixir
iex> Aiur.ControlCall.parse(~s|Aiur.AgentControlCLI.agents(all: true)|)
{:ok, %{module: Aiur.AgentControlCLI, function: :agents, args: [[all: true]], scope: :read}}
iex> Aiur.ControlCall.parse(~s|System.cmd("id", [])|)
{:error, :not_allowlisted}
iex> Aiur.ControlCall.parse(~s|Aiur.AgentControlCLI.message("1", File.read!("/etc/passwd"))|)
{:error, :non_literal_argument}
```

## Refreshable implementation notes

- New: `src/lib/aiur/control_call.ex`, `src/lib/aiur/control_call/allowlist.ex`.
- Tests: `src/test/aiur/control_call_test.exs`; `src/test/aiur/control_call/engine_census_test.exs` greps every `run_control_rpc "` template in `packaging/npm/aiur-cli/libexec/**/*.sh`, substitutes sample values for `$vars`, and asserts each parses and has a scope.
- Runtime-built expressions (`$expression`, `"$@"` in `engine/commands.sh:99,127,161`, `engine/handoff.sh:5-13`) are not visible to a grep: the census lists them by name with their expected class, and the handoff prepare block and the piped `Aiur.PrMerge.Record.publish` (`aiur-engine.sh:217`) are `:deny`.
- Settings entry point (MIC-007): if `Aiur.AgentControlCLI.set_setting`/`list_settings`/`unset_setting` exist when this ticket merges, classify them (`:write`, `:read`, `:write`); otherwise MIC-007 adds the entries. Same for the `executor_wait` keys `ack_through` and `defer_ack` (MIC-005): whichever ticket merges second adds them. Do not add keys a build does not implement: an old build that accepted `defer_ack` and ignored it would lose wakes.
- `:deny` (local only) also covers facade functions the engine never calls remotely: `prepare_handoff`, `main_watch_state`, `main_watch_inherited?`, `usage/1` and `usage/2` (the argument is a server name; only `usage/0` is `:read`), `usage_bar`, and streaming `executor_listen` (`src/lib/aiur/agent_control_cli.ex:4-7,33-34,60-62`).

## Acceptance and verification

### Acceptance criteria

1. Every static RPC template in the engine parses and is `:read`, `:write`, or named `:deny`; every runtime-built expression is listed with its class (census test).
2. Every public function of `Aiur.AgentControlCLI` is classified; adding an unclassified function fails a test.
3. Hostile expressions (shell calls, `:os` calls, pipes, sigils, captures, `apply/3`, nested calls other than `Base.decode64!/1`, a second top-level expression, nesting deeper than 6) refuse with a named reason; allowed functions with extra keys (`Aiur.HarnessSessionCLI.rpc(path: "/etc/passwd")`, `Aiur.AgentControlCLI.queue(server: :foo)`, `analytics(telemetry_file: "/x")`, `build_orders(source: SomeModule)`) refuse with `option_not_allowed`; with `remote: true`, `who:` and `executor_wait(env: [...])` refuse with `option_not_allowed`.
4. `run/3` returns the printed text including the exit marker; on timeout it returns `{:error, :timeout}`, kills a `:read` task, and leaves a `:write` task running to completion. A function called through `run/3` with actor `token:t` sees `actor() == "token:t"`; called directly it sees `local:<user>`.
5. Classification matches the read/mutating table above; `executor_wait` and `set_max_agents` are `:write`, `status` and `agents` are `:read`, `watch(mode: :full)` is `:read` and `watch()` is `:write`; `parse(expr, max_scope: :read)` of a `:write` call returns `{:error, :scope_exceeds_max}`.
6. `parse(~s|Aiur.AgentControlCLI.function_from_the_future()|)`, `parse(~s|Aiur.AgentControlCLI.executor_wait(future_key_qq: 1)|)`, and a call to an existing-atom function the allowlist lacks (for example `Aiur.AgentControlCLI.list()`) all return `{:error, :unknown_on_build}` with the name. `usage(:some_registered_name)` returns `denied_remote`.
9. A function that raises inside `run/3` returns `{:ok, output}` where output ends in `__AIUR_CONTROL_EXIT__:1` with an error marker, and the caller process is still alive.
7. `parse(~s|Aiur.AgentControlCLI.operator_answer(decision_id: "d", operator: true, option_id: "o", expected_version: 1, confirmation: "d")|)` returns `{:error, :denied_remote}`.
8. Every census expression parses through the real `existing_atoms_only` path in a test that does not pre-create atoms (no fixture that mentions the module segments first).

### Test that fails without the change

`control_call_test.exs`: `parse(~s|Aiur.AgentControlCLI.status()|)` returns `{:ok, %{scope: :read}}` and `parse(~s|System.cmd("id", [])|)` returns `{:error, :not_allowlisted}`. The module does not exist today, so the test fails to compile. Mutation checks after the change: replacing the walker with `Code.eval_string` fails the hostile-input cases; moving `operator_answer` to `:write` fails criterion 7; dropping the option constraint check fails criterion 3.

### Agent gate

Targeted tests and the census pass; mutation check per AGENTS.md.

### At-merge gate

CI green on the merge ref; `ce-code-review` with a security lens finds no bypass.

### Human/manual evidence

None; MIC-010 owns end to end.

## Docs to update

None user-facing (internal module). The wire contract is documented by MIC-002.

## Surfaces

- Writes: `src/lib/aiur/control_call*`.
- Contracts: `aiur.control.call` v1, `aiur.control.result` v1, allowlist scopes.

## Sibling boundaries and open gates

MIC-002 mounts it on HTTP. MIC-003 sends the expression. Decision D5 (wire format) is recorded with this default.

## First slice Kevin can try

None alone; with #5945, MIC-002 and MIC-003 merged, `aiur --instance nuc status`.
