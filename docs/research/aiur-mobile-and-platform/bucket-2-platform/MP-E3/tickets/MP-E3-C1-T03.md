---
ticket_id: MP-E3-C1-T03
feature_id: MP-E3
chunk_id: MP-E3-C1
bucket: 2-platform
title: "CLI: aiur executor-attach / executor-detach / executor-session"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C1-T01, MP-E3-C1-T02]
prior_units: [U3]
prior_boundaries: [EXE, CLI]
prior_features: []
prior_findings: [AGENTS.md "Docs ship with the change" (CLI command → reference/cli.md)]
size_owner: "U8 CLI owner (agent_control_cli.ex and aiur-engine.sh are large; add functions, do not restructure)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C1-T03 — Executor attach/detach/session CLI

## Identity and outcome

- Bucket 2 · MP-E3 · C1 · T03.
- **User value:** the operator opts in with one command, sees whether the
  Executor session is attached and alive, and opts out with one command.
- **Deliverable:** three commands in the shared launcher engine (so `aiur` and
  `aiurdev` both have them) backed by `Aiur.AgentControlCLI` functions over the
  control RPC: `executor-attach [--harness claude|codex] [--takeover]
  [--print-config]`, `executor-detach`, `executor-session [--json]`.
- **Non-goals:** writing hook config files (T04 owns install; this command calls
  it); `--check` diagnostics (MP-E3-C7-T01); status beyond the binding (C4-T05).

## Dependencies and blockers

- DESIGN-E3 (command names and output copy: "attached", "detached"; OQ-E3-5
  takeover from CLI). MP-E3-C1-T01, MP-E3-C1-T02.
- Concurrent with: MP-E3-C1-T04 (attach calls its installer; agree the function).

## Verified starting point

- Engine pattern for Executor commands: `cmd_executor_roster()` parses flags and
  calls `run_control_rpc "Aiur.AgentControlCLI.executor_roster(json: …)"`
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:3208-3220`); dispatch
  `case` entries (`aiur-engine.sh:4180-4192`); usage lines (`:470-475`).
- Elixir side: `Aiur.AgentControlCLI.executor_roster/1` prints
  `CURSOR … PENDING …` and a table (`src/lib/aiur/agent_control_cli.ex:682-700`).
- Launcher tests: `packaging/npm/aiur-cli/test/launcher.test.mjs` (run with
  `bun test`, `packaging/npm/aiur-cli/package.json:16`) already exercise
  `executor-roster` parsing.
- Listener-bound check: `Aiur.HttpServer.bound_port/1` (`http_server.ex:130`);
  AGENTS.md "Running": Remote Control is refused unless the HTTP listener is
  confirmed bound — the same rule applies to the Executor hook sink.

## Chosen design

| Command | Behaviour | Output (copy per DESIGN-E3) |
| --- | --- | --- |
| `executor-attach --harness claude` | refuse if `HttpServer.bound_port/1` is nil (`exit 69`, message "the Executor hook needs the dashboard listener; restart without --no-dashboard"); `HookToken.ensure/0`; `Session.attach/1`; then T04 `HookConfig.install(:claude, …)` or, with `--print-config`, print the config instead of writing it | `ATTACHED binding=<id> harness=claude state=awaiting_first_hook` + next step line |
| `executor-attach --harness codex` | same; Codex is print-only in T04 (hooks need trust in the TUI) | config block + "trust the hooks in Codex's review dialog" |
| `--takeover` | passes `takeover?: true`; prints the superseded binding | `SUPERSEDED binding=<old>` |
| `executor-detach` | `Session.detach(id, "stopped")`; T04 `HookConfig.uninstall/1`; `HookToken.rotate/0` (old hooks stop authenticating) | `DETACHED binding=<id>` |
| `executor-session [--json]` | binding public projection + live?, last hook age, foreign-session counter, not-attached counter | text table; `--json` emits `observed_at`, `age_ms`, `freshness` (AGENTS.md computed-age rule) |

- Exit codes follow the engine's conventions: `64` usage, `69` unavailable,
  `0` success; an already-attached refusal is `75` with the live binding named.
- `--harness` default: none; omitted → usage error (no guessing, D16-style
  explicit choice).

## Implementation steps

1. `AgentControlCLI.executor_attach/1`, `executor_detach/1`, `executor_session/1`
   with `@spec`.
2. Engine: `cmd_executor_attach`, `cmd_executor_detach`, `cmd_executor_session`,
   dispatch entries, usage lines.
3. `scripts/aiurdev`: nothing (it execs the engine); confirm these are control
   commands that use the existing release without a rebuild, like `status`
   (AGENTS.md "Layout": pure control commands list) — add them to that list in
   the shim if it is an explicit list.
4. Docs: `website/docs-app/reference/cli.md` entries for the three commands
   (AGENTS.md: CLI command → `reference/cli.md`, same PR).

## Non-happy paths

- Daemon not running → the engine's existing "no running session" error.
- Already attached → refusal names binding, harness and last hook age; suggests
  `--takeover`.
- Install fails (file not writable) → binding stays `awaiting_first_hook`, exit
  `73` with the path; `--print-config` still works.
- Empty `AIUR_INSTANCE_KEY` → T01's `:missing_instance_key` mapped to a clear
  message.

## Compatibility and rollout

- New commands only. Rollback: remove them; a stale binding file is harmless.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/agent_control_cli_executor_session_test.exs
env -C packaging/npm/aiur-cli bun test test/launcher.test.mjs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "attach refused without a bound listener" (bound_port stub nil) | exit 69 message | listener check |
| "attach prints ATTACHED and creates the token" | output + files | attach path |
| "second attach refused with exit 75 naming the binding" | message | T01 error mapping |
| "detach rotates the token" | old token rejected by the plug afterwards | `rotate/0` call |
| "session --json has observed_at, age_ms, freshness; no hook yet → age_ms null, freshness unknown" | keys; `unknown` not `fresh` | age fields (mutation: default 0 fails) |
| launcher "executor-attach without --harness is a usage error" | exit 64 | engine parser |

## Completion and handoff

- [ ] `reference/cli.md` updated in the same PR.
- Dependents: MP-E3-C1-T04 (installer called here), MP-E3-C7-T01 (`--check`).
