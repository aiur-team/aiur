---
title: Skills
---

# Skills

The `aiur-run` Executor announces fallback to `~/.aiur/config` when no local config exists. It can launch a new GitHub repository without per-repository `init`: startup ensures workflow/marker and complexity labels, while models are selected by configuration. It does not seed model/effort labels.

Shared credentials can live in `~/.aiur/.env` outside Git. Local settings, permission requirements, pauses and human decisions retain precedence.

`aiur-intro` explains one-time home setup and per-repository readiness: GitHub access, base branch, CODEOWNERS or dispatch allowlist, labels and validation. The Executor tells the user what was configured and what still blocks startup or worker publication.

`aiur-run` and `aiur-intro` offer [Executor conversation attachment](/concepts/executor#talk-to-the-executor-from-the-dashboard) as a separate opt-in, explaining transcript retention, paired-device access and detachment first.

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
| [aiur-agent](../../.claude/skills/aiur-agent/SKILL.md) | Every ticket turn, via the shared per-turn prompt pointer | The `agent:*` label lifecycle, the brainstorm→plan→work→review flow, the Agent Workpad, milestone alerts, complexity routing, the dev loop, and [Message Bus](/concepts/message-bus) events, subscriptions, blockers, attentions, and consuming async message reads. For build-slot occupancy, agents use `aiur status` rather than raw files in `~/.aiur/build-gate/`. |
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

For a home-page lane, issue workers use `aiur_set_lane` or `aiur_feature`; Executors use `aiur lane set` or `aiur feature add`. An epic holds features, a feature holds tickets, and a lane is the technical column a ticket belongs to.

Only the Executor overrides estimates, with `aiur ticket estimate … --reason`. See the [CLI reference](/reference/cli) and filing skills.

## Matching skills to a ticket

Every ticket workspace installs the full skill set. A worker's cold prompt lists the skills that fit its ticket first, inlined in full, and every other installed skill after them as a name and description to load on demand.

`agent.skills` decides which skills fit. It maps a ticket's lane, owning feature, epic, label and complexity to skill names, and the matching sets are combined.

A lane is the technical column the work belongs to: it comes from a `lane:`, `area:` or `build-lane:` label suffix, or from a configured lane's label matchers. A configured lane therefore needs no GitHub relabel.

An epic is the build-order record above features. A ticket's epic is the one whose ordered feature list holds the ticket's owning feature; a feature no epic holds contributes no epic skills and no error.

### Merge order and precedence

| Source | Config key | Ticket value |
| --- | --- | --- |
| Label | `agent.skills.by_label` | Label, without its `skills:` prefix |
| Lane | `agent.skills.by_lane` | Lane slug |
| Feature | `agent.skills.by_feature` | Owning feature slug |
| Epic | `agent.skills.by_epic` | Owning feature's epic slug |
| Complexity | `agent.skills.by_complexity` | Complexity level |

Labels come first, then lanes, then the owning feature, then its epic, then complexity. Each source contributes its whole set and the sets combine; when two sources name the same skill, the earlier source owns the stated reason.

Matching is case-insensitive, and complexity keys accept both `3` and `"3"`.

### Per-ticket override

A `skills:<name>` label adds skills to one ticket without a config edit. It names a `by_label` entry when one exists, otherwise it names one skill directly.

```yaml
agent:
  skills:
    by_label:
      design: [design-import, ce-brainstorm]
```

A `Skills: a, b` line in the ticket body adds skills the same way. A `Skills only: a, b` line replaces the configured set for that ticket. A line inside a fenced code block is documentation and does not count.

### Worker prompt and the index

Mapped skills are inlined in full under `## Mapped skills (load first)`, each headed by the reason that selected it. Every other installed skill appears under `### Other installed skills (load on demand)` as its name and description.

`agent.skills.preload_max_bytes` caps the inlined instructions. Mapped skills past the cap are listed to load on demand and reported as truncated, never dropped.

A mapped name with no installed `SKILL.md` logs a warning naming the ticket, the skill and the reason. The prompt lists it under `### Mapped skills not installed here` and the worker carries on with the rest.

### Visibility

`aiur agents` shows each worker's mapped skills and their reasons on its status row. The ticket's dispatch record (`logs/agent.ndjson`, mirrored in `agent.md`) carries the full resolution: skills, reasons, missing names, truncated names and the inlined byte count.

### Configuration is read per dispatch

The mapping is read when a worker's prompt is built, so an edit applies to the next dispatch without a daemon restart. A resumed session keeps the prompt it started with.

### Example: a game repository

A game's features name the game domain a ticket works in, and its lanes name the discipline it is built with. Mapping both means a pixel-art ticket in the world feature starts with the art and world skills instead of the multiplayer, saves and CI ones.

```yaml
agent:
  skills:
    # Lanes are the technical columns: the discipline a ticket is built with.
    by_lane:
      art: [pixel-art, palette-discipline]
      audio: [audio-design, sound-budget]
      frontend: [ui-kit, design-import]
      backend: [save-schema, migration-safety]
      docs: [docs-style]
      qa: [playtest-checklists, regression-triage]
    # Features are the game domains: the part of the game a ticket works on.
    by_feature:
      foundation: [repo-conventions, ci-plumbing]
      world: [level-design, tilemap-editing]
      combat: [combat-tuning, balance-simulation]
      classes: [progression-design]
      items-ui: [ui-kit, design-import]
      story-quests: [narrative-writing, quest-authoring]
      audio: [audio-design]
      persistence: [save-schema]
      qa: [playtest-checklists]
    # An epic groups features under a milestone; its skills reach every ticket below it.
    by_epic:
      v1-launch: [launch-checklist]
    # A label adds skills to one ticket without a config edit.
    by_label:
      pixel-art: [pixel-art, palette-discipline]
    # Complexity is the last source, so it only fills in what the rest missed.
    by_complexity:
      1: [ce-work]
      3: [ce-plan, ce-work]
      4: [ce-brainstorm, ce-plan, ce-work, ce-code-review]
```

## Executor skills

These stay with the Executor and are not copied into ticket workspaces.

`aiur-run` emits `executor.progress` whenever it posts its periodic progress
table, using only `done`, `total`, and optional `blocked` counts. The event
provides a conversation jump point; a failed emission does not stop the run.

`aiur-run` runs `aiur executor-sweep` on every pass and follows its findings alongside the status-reported merge policy and local-test evidence; it must never run the human-only `aiur answer` command, which only a human operator may use from an interactive terminal; `aiur-handoff` records that policy and watcher state.

`aiur-run` triages `aiur commands --filter with-executor`, acknowledges with `aiur executor-ack`, and answers or escalates before the answer deadline.

It asks the human through `aiur command request`; `executor-wait` delivers answer identifiers for retrieval with `aiur commands <id> --json`. Executors cannot answer their own requests or overwrite direct operator answers.

For a multi-instance fleet, `aiur-run` uses one Executor with `aiur --instance all executor-wait --as <executor-id> --json`; stop the per-machine Executors so each wake stream has one owner. Handle printed records even when an unreachable instance makes the command exit nonzero.

The hourly dashboard visual check can discover the control URL and credentials from the running daemon outside its tmux session, then reports which sources supplied them without printing credential values.

| Skill | Trigger | Covers |
| --- | --- | --- |
| [aiur-intro](../../.claude/skills/aiur-intro/SKILL.md) | First contact or installation | Operating modes, setup, and first run. |
| [aiur-build](../../.claude/skills/aiur-build/SKILL.md) | Plan a large feature | Aiur's layer on the shared `build-order` skill: planning-pack formats, the continuous-build collection as one epic holding product features over lanes, approval freeze, GitHub promotion, and Executor handoff. |
| [aiur-run](../../.claude/skills/aiur-run/SKILL.md) | Operate a run | Executor sweep findings, per-ticket deep dives through `research-spike`, per-feature progress at `/?view=list&list=features`, accepted boundary through review and merge. |
| [aiur-monitor](../../.claude/skills/aiur-monitor/SKILL.md) | Inspect a live run | Status board and alert feed. |
| [aiur-meta](../../.claude/skills/aiur-meta/SKILL.md) | Hourly audit | Executor sweep findings, five dashboard surfaces and per-feature progress at `/?view=list&list=features`, feature-work share, bottleneck, and durable findings. |
| [aiur-handoff](../../.claude/skills/aiur-handoff/SKILL.md) | Executor handoff | Boot document for the next Executor. |
| [release](../../.claude/skills/release/SKILL.md) | Release | Version, tag, and GitHub release. |

Build-order publication runs the product `aiur` command from `PATH`. Set
`AIUR_FEATURE_CLI` to an executable `aiur` or `aiurdev` path when it is not
available there or you need to select a particular runtime instance.

`aiur-build` keeps only the Aiur-specific rules and defers the general
decomposition method to the shared `build-order` skill; `aiur-run` sends
per-ticket deep dives to `research-spike` the same way. Both general skills ship
with the shared skill set, so a run that plans or researches without them is
missing an install, not a section of these pages.

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

Run `python3 packages/newsletter/collect.py` from the repository to capture a
rolling 24-hour window (merges retain 48 hours) beneath the per-repository Aiur
state directory at `newsletter/snapshots/YYYY-MM-DD.json`. Repeating a UTC date
atomically replaces that file.

`--repo owner/repo` selects a repository;
`--state-dir <dir>` selects its local evidence directory and `--out <dir>`
selects the snapshot output directory.

Repeat `--instance <name>` for each
additional configured daemon to query through `aiur --instance <name>`. This
selects daemon queries; it does not expose that machine's local telemetry or
analytics files to the collector, so its allocation sections remain unavailable
unless those files are reachable in the collector's local state directory.

The collector uses the daemon's labels-only feature rule: `feature:*`,
`build-lane:*`, or exact `build-order`. Titles can only select non-feature classes.

GitHub reads use cursor pages and batched issue numbers, with a 40-request
ceiling below 50 GraphQL points; the snapshot records reported cost and marks
incomplete reads unavailable. See [GitHub budgets](/apis/github-budgets).

Meta summaries read timestamped `meta/*.md` files and Executor action records
read `executor/*/history.ndjson`.

Snapshots also include `allocation_evidence` blocks for `pc` and `nuc`, with
turn, intake, and feature-supply sections. Sections include records only when
the source can prove complete window coverage; missing intake history and
unreachable machine telemetry remain unavailable rather than zero.

Missing sources remain `null` with reasons;
stale daemon observations cannot produce current allocation counts. Units are
deduplicated by repository and issue number across daemons.

Per-class agent
hours remain unavailable until per-ticket active intervals cover the window.

Running build identity comes from each daemon's release stamp, separately
from merged changes; a merge alone does not establish deployment or verification.

Newsletter metrics use `packages/newsletter/metrics.py`'s pure
`compute(today, yesterday_or_none)` function. The report separates merge outcomes,
seven-day allocation per PC/NUC machine, program scope changes, lanes, and
meta/action evidence.

Each metric includes source-field paths. Missing daily baselines keep every delta
and trend `unavailable`; merge timestamps alone never prove a change is live.

Ancestry and Executor verification require explicit snapshot evidence, so their
counts remain unavailable when the collector cannot supply it. The input and
report contract is in `packages/newsletter/metrics-contract.md` in the repository.

The allocation headline compares feature turn-hours and distinct tickets worked
with the 95% target over seven days, separately for PC and NUC. Instant agent
counts are context. Separate lines show main-fix hours, unlabelled product,
non-feature intake by source, and observed feature-starved slot-minutes.

Each machine needs complete evidence for its window; absent or partial capture
shows `unavailable` for that machine. A 24-hour capture cannot substitute for
seven days, and current todo labels cannot establish first-dispatch intake.


### Build the daily PDF

Run `python3 packages/newsletter/newsletter.py build --repo owner/repo` to
collect a snapshot, compute metrics and compile the approved dark broadsheet.
Chromium or Google Chrome is required.

The command writes `report.json`,
`newsletter.html` and a checked one-page US Letter `newsletter.pdf` under the
repository state root at `newsletter/<UTC-date>/`.

`--state-dir <dir>` selects
a different root; repeat `--instance <name>` for additional daemon sources.

Use `--timezone <IANA-zone>` for the operator's printed window end (default:
local time). `--notes <file>` accepts Markdown paragraphs or editorial JSON with
`notes`, `blockers[{label,action}]`, `shipped[{icon,label}]` and
`bottlenecks[{problem,action,result,tone}]`. 

These fields add context without replacing metrics. Missing inputs visibly say `unavailable`.

`preprocess` runs collection plus metrics without Chromium; `compile <report>`
prints an existing report, with the same notes/timezone options.

Fonts, logo and dark tokens are embedded from `packages/aiur-style`; rendering
needs no font network access. The page balances unfinished feature lanes across
both columns and excludes completed lanes.

When present, all blockers, five shipped items and two bottleneck cards are
retained while optional editorial items are trimmed to fit. Fonts stay readable
and all data stays in the report.

Overflow or missing Chromium fails
with a clear error. See `packages/newsletter/README.md` for the notes schema and
exact trimming order. This package does not send messages or schedule delivery.


### Enrich and deliver with the Executor

Invoke `/aiur-newsletter` to preprocess the daily report, add checked Executor
findings as a notes file, and compile the PDF. The skill checks operator decisions
in tracker items, open Commands and the latest handoff.

Its `blockers` entries use short `{label, action}` pairs without issue numbers.
A checked empty list displays
“Nothing blocked on you today”; missing blocker evidence remains `unavailable`.

The Executor attaches the PDF with Claude's `SendUserFile` and sends a one-line
Claude app push notification, checking each result. This requires those tools in
the Executor session; a local PDF alone is not delivery.

A delivery receipt avoids duplicate sends on repeated wakes.
Ask for a **dry-run** to produce and inspect the
PDF without sending it or notifying. The skill installs no scheduler or email path.
