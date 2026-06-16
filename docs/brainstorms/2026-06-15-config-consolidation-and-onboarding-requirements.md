---
date: 2026-06-15
topic: config-consolidation-and-onboarding
---

# Config Consolidation, Cleanup & New-Repo Onboarding

## Problem Frame

`.aiurconfig` has drifted: four sections (`github`, `claude`, `linear`, `prompt_file`)
are read ad-hoc by separate `*.Config` modules and bypass `Aiur.Config.Schema`
entirely, so config-reading is duplicated and `linear` settings exist in two places
(a vestigial `tracker.*` set + the real `linear:` section). Dead settings linger
(`claude.version` has zero consumers). Onboarding is broken in two ways: the real
`aiur init` wizard is unreachable via `aiurdev init` ("no command"), and there's no
committed `.aiurconfig.example` to anchor it. Finally, every repo needs its own full
config — there's no global fallback. Only this repo uses aiur today, so breaking
config changes are acceptable (no back-compat shim).

This work unifies the config surface, restructures it shared-vs-provider-specific,
fixes + extends onboarding, and adds a global config.

---

## Actors

- A1. Developer onboarding a new repo: runs `aiurdev init` / `aiur init`, picks repo-local or global.
- A2. Developer running aiur in a repo with no local config: expects the global config + auto-detected repo to just work.
- A3. aiur runtime: loads/validates one config surface and resolves local-vs-global.

---

## Requirements

**A. Config consolidation & cleanup**
- R1. Every setting is defined and validated in `Aiur.Config.Schema`. The `github`/`claude`/`linear`/`prompt_file` sections move into the schema; `Aiur.GitHub.Config`, `Aiur.Claude.Config`, `Aiur.Linear.Config` keep their public getters but delegate to the parsed `Config.settings!()` struct instead of reading raw YAML. No setting is read in two places.
- R2. Tracker is shared-vs-specific: `tracker.{kind, active_states, terminal_states}` shared; provider-specific nested as `tracker.github.{repo, label_prefix, bot_account}` and `tracker.linear.{api_key, project_slug, endpoint, assignee}`. The flat `tracker.{endpoint,api_key,project_slug,assignee}` fields are removed.
- R3. Agent is shared-vs-specific: shared on `agent` = `kind`, `remote_control`, `routing`, `complexity_prompts`, `max_concurrent_agents`, `max_concurrent_agents_by_state`, `max_turns`, `max_retry_attempts`, `max_retry_backoff_ms`, plus `turn_timeout_ms` + `stall_timeout_ms` (promoted from codex as backend-agnostic). Provider-specific nested: `agent.claude.{command, model, permission_mode}` and `agent.codex.{command, approval_policy, thread_sandbox, turn_sandbox_policy, read_timeout_ms, thrash_max_per_window, thrash_window_seconds}`. The `agent.codex_thrash_*` knobs move into `agent.codex.thrash_*`.
- R4. Dead settings removed: `claude.version`; the vestigial flat `tracker.*` Linear fields.
- R5. `opencode` stays a top-level section (chat bridge, not an agent backend); `prompt_file` becomes a top-level schema field.
- R6. Hard cutover — no back-compat shim. This repo's `.aiurconfig` is migrated to the new shape as part of the change.

**B. Onboarding**
- R7. A committed `.aiurconfig.example` is a full, annotated reference of the cleaned-up settings, grouped into an **essential** block and a commented **`# --- advanced ---`** block, with placeholders for the prompt-filled values.
- R8. `aiur init` uses `.aiurconfig.example` as its template: it copies the example and substitutes the prompted values (tracker + repo, agents, concurrency) into the placeholders via text substitution (comments preserved), writing the result as the target config. The wizard still creates GitHub labels/tags, scaffolds `.env`/`.env.example`, and runs the (non-blocking) auth checks.
- R9. `aiurdev init` routes to the wizard (fix the wrapper's missing `init` subcommand) so `aiurdev init` ≡ `aiur init`.

**C. Global vs repo-local config**
- R10. `aiur init`'s **first** prompt asks repo-local vs global. Repo-local writes `./.aiurconfig`; global writes `~/.aiurconfig`. Neither overwrites an existing target (existing-config guard; `--force` overrides).
- R11. The global config omits repo-specific settings (`tracker.github.repo`, `prompt_file`) — it is general/shared across repos.
- R12. Config resolution for any aiur command: repo-local `./.aiurconfig` (at repo root) if present; else the global `~/.aiurconfig`; when the global is used, the repo identity is auto-detected from the cwd's git remote.

---

## Acceptance Examples

- AE1. **Covers R1.** Every `*.Config` getter resolves through `Config.settings!()`; a grep finds no `section_value`/raw-YAML config reads outside `Aiur.Config.Schema`.
- AE2. **Covers R2, R4.** A github config carries `tracker.github.repo`; `tracker.api_key`/`tracker.endpoint` no longer exist; `agent.claude.version` is gone.
- AE3. **Covers R3.** `agent.turn_timeout_ms` and `agent.stall_timeout_ms` are read for both codex and claude turns; codex-only knobs live under `agent.codex`.
- AE4. **Covers R7, R8.** `aiur init` in a fresh repo, answering the prompts, produces a config that is the annotated example with repo/agents filled in, and the GitHub labels are created.
- AE5. **Covers R9.** `aiurdev init` launches the wizard instead of failing with "no command".
- AE6. **Covers R10, R11, R12.** Choosing "global" writes `~/.aiurconfig` with no `tracker.github.repo`; later running an aiur command in a *different* repo that has no local `.aiurconfig` uses `~/.aiurconfig` plus the repo auto-detected from that repo's git remote.

---

## Success Criteria

- One validated config surface: adding/reading a setting touches `Aiur.Config.Schema` only; no parallel raw-YAML readers.
- A new repo can be onboarded with one command (`aiurdev init`) that produces a self-documenting `.aiurconfig` and creates the labels aiur needs.
- A developer can set up a global `~/.aiurconfig` once and run aiur in any repo without a local config.
- This repo's `.aiurconfig` is materially smaller/clearer, with no dead or duplicated settings.

---

## Scope Boundaries

- Not preserving backward compatibility with the old config shape (R6) — only this repo uses aiur.
- Not changing runtime behavior of the settings themselves beyond where they're read from (except promoting codex `turn_timeout_ms`/`stall_timeout_ms` to apply to all backends, R3).
- Not adding new tracker providers or agent backends.
- Not building a config-migration tool (hard cutover; this repo is migrated by hand in the PR).
- Not redesigning the wizard's prompt flow beyond the new first question (repo-local vs global) and sourcing the template from `.aiurconfig.example`.

---

## Key Decisions

- Shared-vs-provider-specific nesting (`tracker.{github,linear}`, `agent.{claude,codex}`) over flat top-level provider sections — the parent holds anything shareable; sub-sections hold only truly provider-specific settings (user directive).
- Global config at `~/.aiurconfig` (home dotfile), repo auto-detected from git remote on fallback (user choice).
- Hard cutover, no shim (breaking is acceptable).
- `aiur init` fills `.aiurconfig.example` via text substitution (preserves comments) rather than re-serializing YAML.
- Promote `turn_timeout_ms`/`stall_timeout_ms` to `agent` (shared) since a stalled/over-long turn is backend-agnostic; `read_timeout_ms` stays codex-specific (app-server protocol read).

---

## Dependencies / Assumptions

- Existing wizard `src/lib/aiur/init.ex` (+ `src/test/aiur/init_test.exs`), `src/lib/aiur/cli.ex` init handler, and `Aiur.Workflow.detect_run_folder_config/0` are the foundation to extend.
- `Aiur.Config.Schema` (Ecto embedded schemas) is the consolidation target; `Aiur.{GitHub,Claude,Linear}.Config` and `Aiur.Workflow` (`prompt_file`) are the readers to redirect.
- `scripts/aiurdev` case dispatch (~2168) needs an `init` passthrough to `bin/aiur init`.
- Claude turns honoring `agent.turn_timeout_ms`/`stall_timeout_ms` may need wiring (claude-repl turns are hook-driven) — confirm in planning.

---

## Outstanding Questions

### Resolve Before Planning

- (none — directions set)

### Deferred to Planning

- [Affects R3][Technical] Exactly how claude turns consume the promoted `agent.turn_timeout_ms`/`stall_timeout_ms` (claude-repl is hook-driven) — wire or document per-backend.
- [Affects R8][Technical] Placeholder/substitution format in `.aiurconfig.example` (e.g. `<REPO>` tokens) and how the wizard injects multi-line/list values while preserving comments.
- [Affects R12][Technical] Local-config detection boundary (cwd vs git repo root) and how repo auto-detect interacts with `tracker.kind` ≠ github.
- [Affects R1][Technical] Order of consolidation vs onboarding so the example/wizard target the already-cleaned schema.

---

## Next Steps

-> `/ce-plan` for structured implementation planning.
