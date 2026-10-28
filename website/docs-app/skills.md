---
title: Skills
---

# Skills

The `aiur-run` Executor announces fallback to `~/.aiur/config` when no local config exists. It can launch a new GitHub repository without per-repository `init`: startup ensures workflow/marker and complexity labels, while models are selected by configuration. It does not seed model/effort labels.

Shared credentials can live in `~/.aiur/.env` outside Git. Local settings, permission requirements, pauses and human decisions retain precedence.

`aiur-intro` explains one-time home setup and per-repository readiness: GitHub access, base branch, CODEOWNERS or dispatch allowlist, labels and validation. The Executor tells the user what was configured and what still blocks startup or worker publication.

Aiur ships Agent Skills under `.claude/skills/`, with shared links for Codex under `.codex/skills/` and Muse under `.agents/skills/` in the source checkout. They split into two families by **where they run**:

- **Agent-workspace skills** are copied into every ticket workspace, so the agent working a ticket can load them on any repository.
- **Executor skills** stay in this repository and load in the Executor's own session, whether that Executor is a human or an agent driving Aiur.

## Agent-workspace skills

These four skills, together with the complete pinned Compound Engineering set, are installed in every ticket workspace under `<workspace>/.claude/skills/`. Codex discovers per-skill symlinks under `<workspace>/.codex/skills/`. Muse receives copies under `<workspace>/.agents/skills/`.

Local and remote Codex sandboxes make `.agents/` and `.codex/` writable for Git merges. The pre-merge hook moves conflicting untracked skill files aside: identical copies are removed; differing copies are saved under Git metadata.

CI rejects tracked changes under `.codex/skills` and `.agents/skills`, and tracked symlinks under `.claude/skills`. Regular `.claude/skills` source files remain editable.

Muse loads workspace skills and rules only when `agent.backend_configs.muse.trust_workspace` is explicitly enabled.

| Skill | Loaded when | Covers |
| --- | --- | --- |
| [aiur-agent](../../.claude/skills/aiur-agent/SKILL.md) | Every ticket turn, via the shared per-turn prompt pointer | The `agent:*` label lifecycle, the brainstorm→plan→work→review flow, the Agent Workpad, milestone alerts, complexity routing, the dev loop, and [Message Bus](/concepts/message-bus) events, subscriptions, blockers, and attentions. |
| [aiur-debug](../../.claude/skills/aiur-debug/SKILL.md) | Run, daemon, agent, or workspace failure | Correlated evidence and safe recovery order. |
| [aiur-experiment](../../.claude/skills/aiur-experiment/SKILL.md) | Experiment analysis ticket or local analyst brief | Blind pre-registration, engine statistics, complete confounder ledger, and validated CLI report submission. Analysis tickets produce no PR and finish after verified submission. |
| [design-import](../../.claude/skills/design-import/SKILL.md) | Large frontend design import | Disk-first import without overflowing agent context. |

Executor skills are deliberately excluded from this set: an issue worker has no reason to run Aiur itself.

For Aiur changes, workers run `mise exec -- python3 scripts/check-pr-structure.py --base <base-sha>` after committing, before every push and after every base integration.

In a clean worktree it checks file size, docs paragraph/table prose, component ownership and reference boundaries, bare receives, formatting and the `State` writer allowlist — the cheap gates CI would otherwise fail a full cycle on.

For refactor reports, run `python3 scripts/check-file-size.py --census <base> <head>`
from the repository root; add `--json` for machine-readable output. The table
reports tracked-text totals and added, removed and moved lines by source, test,
docs, generated/vendor and other areas.

Git-detected rename/copy pairs credit
unchanged lines as moved to the original area; edits count as added/removed.

Copies and cross-area moves can change area totals without text churn. Binary
changes are file counts; symlink blobs are excluded. This report does not enforce
a CI limit or claim savings.

The `aiur-agent` skill teaches 2–3 suggested responses, recommended first.
Agents prefer supported native questions when available in their current mode;
these retain the tool's option rules. Enforcement remains opt-in through
[`decisions.require_suggested_responses`](/reference/configuration-daemon#decisions).

The `aiur-agent` dev loop distinguishes a retryable GitHub budget hold from a
credential failure. A budget-held agent requests a typed, expiring pause and is
resumed automatically; it does not raise a credential attention for a healthy
token.

Issue workers select focused tests from the target repository's instructions,
package scripts, and CI configuration. The bundled `aiur-agent` skill's `mix`
examples apply to Aiur's Elixir core; a TypeScript workspace uses its own
runner.

The `aiurdev --test` / `--test3` guard prevents destructive Aiur
sandbox resets from issue workspaces, not ordinary repository tests.

For a home-page epic, issue workers use `aiur_set_epic` or `aiur_feature`; Executors use `aiur epic set` or `aiur feature add`. Only the Executor overrides estimates, with `aiur ticket estimate … --reason`. See the [CLI reference](/reference/cli) and filing skills.

## Executor skills

These stay with the Executor and are not copied into ticket workspaces.

`aiur-run` runs `aiur executor-sweep` on every pass and follows its findings alongside the status-reported merge policy and local-test evidence; it must never run the human-only `aiur answer` command, which only a human operator may use from an interactive terminal; `aiur-handoff` records that policy and watcher state.

`aiur-run` triages `aiur commands --filter with-executor`, acknowledges with `aiur executor-ack`, and answers or escalates before the answer deadline.

It asks the human through `aiur command request`; `executor-wait` delivers answer identifiers for retrieval with `aiur commands <id> --json`. Executors cannot answer their own requests or overwrite direct operator answers.

For a multi-instance fleet, `aiur-run` uses one Executor with `aiur --instance all executor-wait --as <executor-id> --json`; stop the per-machine Executors so each wake stream has one owner. Handle printed records even when an unreachable instance makes the command exit nonzero.

The hourly dashboard visual check can discover the control URL and credentials from the running daemon outside its tmux session, then reports which sources supplied them without printing credential values.

| Skill | Trigger | Covers |
| --- | --- | --- |
| [aiur-intro](../../.claude/skills/aiur-intro/SKILL.md) | First contact or installation | Operating modes, setup, and first run. |
| [aiur-build](../../.claude/skills/aiur-build/SKILL.md) | Plan a large feature | Requirements, ticket contracts, dependency graph, workstream icons and summaries, and Build Order handoff. |
| [aiur-run](../../.claude/skills/aiur-run/SKILL.md) | Operate a run | Executor sweep findings, per-feature progress at `/?view=list&list=features`, accepted boundary through review and merge. |
| [aiur-monitor](../../.claude/skills/aiur-monitor/SKILL.md) | Inspect a live run | Status board and alert feed. |
| [aiur-meta](../../.claude/skills/aiur-meta/SKILL.md) | Hourly audit | Executor sweep findings, five dashboard surfaces and per-feature progress at `/?view=list&list=features`, feature-work share, bottleneck, and durable findings. |
| [aiur-handoff](../../.claude/skills/aiur-handoff/SKILL.md) | Executor handoff | Boot document for the next Executor. |
| [release](../../.claude/skills/release/SKILL.md) | Release | Version, tag, and GitHub release. |

`aiur-handoff`, `aiur-meta`, and `release` are Claude-only.

`aiur-build` creates waiting members with `agent:queued` and adopts their root; `aiur-run` audits queue status, holds and attentions. A disabled queue uses todo labels instead.

## Codex-native git workflow

| Skill | Covers |
| --- | --- |
| [commit](../../.codex/skills/commit/SKILL.md) | Scope-aware commit creation. |
| [push](../../.codex/skills/push/SKILL.md) | Push and PR creation or update. |
| [pull](../../.codex/skills/pull/SKILL.md) | Merge-based integration from `origin/main`. |
| [land](../../.claude/skills/land/SKILL.md) | Conflict, CI, review, and squash-merge handling. |
| [debug](../../.codex/skills/debug/SKILL.md) | Log-tracing recovery. |
| [linear](../../.codex/skills/linear/SKILL.md) | Raw Linear GraphQL operations. |

## Compound Engineering

Aiur vendors the complete Compound Engineering **3.19.0** skill tree under [`.claude/skills/`](../../.claude/skills/), so every dispatched workspace receives the same pinned set.

| Skill | Purpose |
| --- | --- |
| `ce-brainstorm` | Clarify requirements and alternatives. |
| `ce-plan` | Produce an implementation-ready plan. |
| `ce-work` | Execute a concrete plan or request. |
| `ce-code-review` | Review bugs, regressions, tests, and standards. |
| `ce-doc-review` | Review documentation structure and accuracy. |
| `ce-debug` | Diagnose failing behavior. |

The complexity router invokes those skills directly, and they conditionally invoke sibling CE skills; the complete tree keeps those branches reproducible.

| Pin record | Location |
| --- | --- |
| Version | [`compound-engineering.version`](../../.claude/skills/compound-engineering.version) |
| Managed skill names | [`compound-engineering.skills`](../../.claude/skills/compound-engineering.skills) |
| Upstream MIT license | [`compound-engineering.LICENSE`](../../.claude/skills/compound-engineering.LICENSE) |

To update the vendored copy, clone the exact upstream release tag and run the guarded refresh script:

```bash
update_dir=$(mktemp -d)
git clone https://github.com/EveryInc/compound-engineering-plugin.git "$update_dir/compound-engineering"
git -C "$update_dir/compound-engineering" checkout <exact-release-ref>
scripts/update-compound-engineering-skills X.Y.Z "$update_dir/compound-engineering"
```

Choose the release ref whose `.claude-plugin/plugin.json` reports `X.Y.Z`; the refresh script rejects a mismatch.

Review the upstream release notes and the resulting skill diff, then run the AgentSkills tests before committing. The script replaces only previously managed CE skill paths, refreshes the license, version, and manifest files, and recreates the Claude-to-Codex links.

The complexity routing rules that pick which CE skill to run live in [complexity-routing.md](../../.claude/skills/aiur-agent/complexity-routing.md).

## Daily newsletter snapshots

Run `python3 scripts/newsletter/collect.py` from the repository to capture a
rolling 24-hour window (merges retain 48 hours) beneath the per-repository Aiur
state directory at `newsletter/snapshots/YYYY-MM-DD.json`. Repeating a UTC date
atomically replaces that file.

`--repo owner/repo` selects a repository;
`--state-dir <dir>` selects its local evidence directory and `--out <dir>`
selects the snapshot output directory.

Repeat `--instance <name>` for each
additional configured daemon to query through `aiur --instance <name>`.

The collector shares classification with the meta check's `feature-share.sh`.

GitHub reads use cursor pages and batched issue numbers, with a 40-request
ceiling below 50 GraphQL points; the snapshot records reported cost and marks
incomplete reads unavailable. See [GitHub budgets](/apis/github-budgets).

Meta summaries read timestamped `meta/*.md` files and Executor action records
read `executor/*/history.ndjson`.

Missing sources remain `null` with reasons;
stale daemon observations cannot produce current allocation counts. Units are
deduplicated by repository and issue number across daemons.

Per-class agent
hours remain unavailable until per-ticket active intervals cover the window.

Running build identity comes from each daemon's release stamp, separately
from merged changes; a merge alone does not establish deployment or verification.

Newsletter metrics use `scripts/newsletter/metrics.py`'s pure
`compute(today, yesterday_or_none)` function. The report separates merge outcomes,
instantaneous allocation, program scope changes, lanes, and meta/action evidence.
Each metric includes source-field paths. Missing daily baselines keep every delta
and trend `unavailable`; merge timestamps alone never prove a change is live.
Ancestry and Executor verification require explicit snapshot evidence, so their
counts remain unavailable when the collector cannot supply it. The input and
report contract is in `scripts/newsletter/README.md` in the repository.
