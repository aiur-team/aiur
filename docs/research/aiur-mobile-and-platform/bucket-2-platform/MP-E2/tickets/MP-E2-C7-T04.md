---
ticket_id: MP-E2-C7-T04
feature_id: MP-E2
chunk_id: MP-E2-C7
bucket: 2-platform
title: aiur commands — route, age and escalation columns and the needs-you filter
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C2-T03, MP-E2-C1-T04]
prior_units: [U6]
prior_boundaries: [CLI #31]
prior_features: [MP-R1-C9-T05 (CLI split; rebase)]
prior_findings: [DESIGN-E2 §3 CLI row (copy and column set), AGENTS.md computed-age rule]
size_owner: "CLI (commands_cli.ex 246)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C7-T04 — `aiur commands`: route, age and escalation columns; `needs-you` filter

## Identity and outcome

- Bucket 2, MP-E2, chunk C7. **Visible (CLI) — blocked on DESIGN-E2 §3.**
- **User value:** from the terminal (you or the Executor) you see which Commands need the
  human, how old they are, and why they escalated; `--filter needs-you` is the human's
  to-do list.
- **Deliverable:** human output gains route, age and escalation-cause columns (approved
  headers); filters gain `needs-you`, `with-executor`, `from-executor`; JSON gains
  `observed_at`, `age_ms`, `freshness` per row (AGENTS.md: the CLI emits these and a web
  surface that computes them must render them).
- **Non-goals:** new subcommands (C2-T04, C6-T01).

## Dependencies and blockers

- **DESIGN-E2 §3** CLI copy and column set (`[decide]`). C2-T03, C1-T04 data.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/commands_cli.ex:7` `@filters ~w(all open blocking resolved)a`; `:9-20`
  `run/1` (`--json` or `print_human/1`); `:24-57` `build/1` envelope with `snapshot.captured_at`,
  `sources` (`observed_at: nil` today, `:146-150`).
- Engine `commands)` dispatch `packaging/npm/aiur-cli/libexec/aiur-engine.sh:4122`.
- Test `src/test/aiur/commands_cli_test.exs`.

## Chosen design

- Filters map to provider params (`route=…`, `requester=executor`) from C7-T01/C6-T04 —
  one query path shared with the dashboard.
- Columns (draft headers pending §3): `ID`, `ROUTE`, `AGE`, `WHY` (last escalation
  cause), `ASKS` (short_label), `TICKET|EXECUTOR`.
- Row JSON: `age_ms = captured_at - created_at`; `needs_you_ms = captured_at -
  human_visible_at` (nil when not human-visible); `freshness` = `:fresh | :partial |
  :unavailable` from the existing source health.
- Unknown route renders `?` (approved symbol) — never a guessed state.

## Implementation steps

1. `commands_cli.ex`: filters, columns, JSON fields (≈60 lines; extract the human printer
   to `commands_cli/printer.ex` if the file passes 300).
2. Engine usage text for the new filter values.
3. Docs: `reference/cli.md` (`aiur commands` filters, columns, JSON fields).

## Non-happy paths

- Store unavailable: existing error path, exit 1.
- Partial retained data: `freshness: partial` and a human footer line saying so.

## Compatibility and rollout

- Additive JSON fields; human output changes (column set) per §3.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/commands_cli_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "--filter needs-you returns only human-visible open Commands" | ids equal fixture | filter mapping |
| "--json rows carry age_ms and needs_you_ms computed from the injected clock" | exact integers | JSON fields |
| "unknown route prints ? not with-executor" — replace that branch with a default and confirm failure | `?` | unknown branch |
| "partial source prints the partial footer" | footer present | freshness |

Mutation check per row.

## Completion and handoff

- [ ] Approved columns; filters; JSON ages.
- Docs: `reference/cli.md`.
- Dependents: C8-T02 (Executor triage uses `--filter with-executor`).
