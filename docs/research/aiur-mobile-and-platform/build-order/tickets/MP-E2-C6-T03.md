---
ticket_id: MP-E2-C6-T03
feature_id: MP-E2
chunk_id: MP-E2-C6
bucket: 2-platform
title: Make aiur ask an alias that raises an Executor Command
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C6-T01, MP-E2-C6-T02]
prior_units: [U6, U7]
prior_boundaries: [CLI #31, DEC #27]
prior_features: []
prior_findings: [plan §1.5 (Asks store has no UI), contract §11]
size_owner: "CLI (asks_cli.ex, aiur-engine.sh run_asks)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C6-T03 — Make `aiur ask` an alias that raises an Executor Command

## Identity and outcome

- Bucket 2, MP-E2, chunk C6.
- **User value:** existing Executor habits and skills that run `aiur ask` keep working, but
  the question now lands where you look (the Commands inbox) instead of a hidden file.
- **Deliverable:** `aiur ask "<title>" [--body] [--urgency] [--blocking]` creates an
  Executor Command through `Aiur.Commands.ExecutorRequestCLI` (title → question, body →
  long context, no options ⇒ free-text answer); `aiur ask --done <id>` maps to moot for a
  Command id and keeps the legacy resolve for an `ask_` id; `aiur ask --list` shows legacy
  asks plus a pointer to `aiur commands` for Executor Commands. Deprecation note.
- **Non-goals:** migrating old `ask_` records into the Command store (they stay readable
  history; contract §11). Removing `Aiur.Asks` (a later U7 cut once usage is zero).

## Dependencies and blockers

- **DESIGN-E2** (§3 CLI copy); C6-T01, C6-T02.
- May run concurrently with C6-T04.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/asks_cli.ex:1-95` commands `{:create, …}`, `{:done, …}`, `{:list, …}`,
  output "Created <id> (BLOCKING)." `:19-27`; repository via `GitHubConfig.repo/0`.
- `src/lib/aiur/asks.ex:13-35` (`ask_` prefix, urgencies `low normal high`, fields
  `title/body/urgency/blocking`); `src/lib/aiur/asks_store.ex` (JSONL + sqlite lock).
- `src/lib/aiur/cli.ex:115,157` runs `Aiur.AsksCLI` locally, **without the daemon**;
  engine `run_asks` `aiur-engine.sh:628-630` ("distribution-free, no daemon/tmux").
- Tests: `src/test/aiur/asks_cli_test.exs`, `asks_test.exs`.

## Chosen design

- `{:create, attrs}` → control RPC to `ExecutorRequestCLI.request/2` with
  `question: title`, `context.long_context_markdown: body`, `urgency` (mapping `low |
  normal | high` unchanged), `blocking` (ask default `false` is kept for the alias — it is
  the old semantics), `options: []` (custom response only; the suggested-responses rule
  warns, which is accurate). Output keeps the old shape with the new id:
  "Created <decision_id> (BLOCKING)." plus one deprecation line pointing to
  `aiur command request`.
- **Daemon required:** the alias moves `aiur ask` from a local file write to an RPC. If the
  daemon is down: exit 1 with "aiur ask now raises a Command and needs the running daemon"
  (no silent fallback to the hidden store — that would recreate the invisible-question
  problem). Engine: `ask` dispatch switches from `run_asks` to the control-RPC path;
  `asks` (list) keeps the local path for legacy records.
- `{:done, %{id: "ask_…"}}` → legacy resolve; 16-hex id → `executor-moot` with
  `reason_class: "executor_withdrew"`.

## Implementation steps

1. `asks_cli.ex`: route `:create` and Command-id `:done` to the new module via an injected
   `rpc_fun` (tests stub it).
2. `aiur-engine.sh`: `ask` uses `run_control_rpc`; `asks` unchanged.
3. Docs: `reference/cli.md` (`aiur ask` → alias, deprecation), `skills.md` if it lists ask.

## Non-happy paths

- Daemon down: explicit failure (above).
- Legacy id passed to `--done` after migration: legacy path still works.
- Scripts parsing "Created ask_…": id format changes to 16 hex — called out in the
  deprecation note and in the PR body (census: `git grep -n "aiur ask"` across `.claude/`
  and `src/prompts/` at implementation; update every hit in this PR).

## Compatibility and rollout

- Behaviour change for `aiur ask` (daemon required). One release with the deprecation
  line; removal of the alias is a later decision.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/asks_cli_test.exs test/aiur/asks_test.exs
bash -n packaging/npm/aiur-cli/libexec/aiur-engine.sh
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "ask create raises an executor Command via RPC" | rpc stub called with question = title, blocking false | step 1 |
| "ask create with daemon down fails loudly and writes no ask_ record" | exit 1; asks store unchanged (temp HOME) | no-fallback rule |
| "ask --done <decision id> moots the Command" | moot called with `executor_withdrew` | id routing |
| "ask --done ask_… resolves the legacy record" | legacy resolve | legacy branch |
| "asks list still shows legacy records" | listed | unchanged path |

Mutation check per row.

## Completion and handoff

- [ ] Alias, legacy read path, docs, every in-repo `aiur ask` usage updated.
- Docs: `reference/cli.md`.
- Dependents: C8-T02.
