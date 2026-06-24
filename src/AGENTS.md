# Aiur Elixir

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `.aiur/config` (pure YAML, optional `prompt_file:`/`hooks_file:`), with a backward-compatible fallback to a legacy root `.aiurconfig`, via `Aiur.Workflow` and `Aiur.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `Aiur.Config` instead of ad-hoc env reads.
- The interactive tmux chat pane runs opencode. Aiur owns the bridge boundary in
  `Aiur.Opencode.*`; opencode-specific config and wire shapes belong in
  `Aiur.Opencode.Protocol`. opencode stores a secondary copy of pane transcripts
  under its user data directory, so apply the same retention expectations as
  `logs/agent.ndjson`. If Aiur restarts while a pane is open, close and reopen
  the pane so opencode receives a fresh bearer token.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Coding-agent backend is resolved per issue, not globally. `Aiur.CodingAgent.backend_for/1`
  resolves a `model:<backend>` issue label first, then the `agent.routing` `complexity:N` table,
  then the `agent.kind` default. Resolve once at `start_session` and read `session[:backend]`
  for dispatch — never re-resolve from global config mid-session.
- Issue labels select the model in three layers: `model:claude`/`model:codex` (CLI default model),
  `model:claude-opus` (family default), `model:claude-opus-4-8` (exact version). The variant
  string is threaded verbatim through `start_session` into each adapter's model flag; the
  registry in `Aiur.CodingAgent` is the single source for known backends and their seedable labels.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

`make all` covers correctness of the code (format, lint, coverage,
dialyzer, test suite). It is **not** a manual test of the running
service. See `../AGENTS.md#manual-testing--the-only-definition` —
"manual testing" means running `scripts/aiurdev --test --force --allow-remote`
end to end and driving the TUI as a user would. Do not call the feature
"working" or "shipped" until you have actually used the running CLI and
observed the intended rendered output. HTTP API calls and `tmux
capture-pane` snapshots from outside the live session are not
substitutes.

Agent issue workspaces are blocked from running that manual-test path
directly. If the guard blocks `--test` / `--test3`, stop and report the
blocked manual verification; do not retry by copying the repo to `/tmp`,
cloning another checkout, or changing wrapper tmux names.

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/aiur/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `.aiur/config` (the `.aiurconfig.example` template + `examples/workflows/` reference configs) for config contract changes.
