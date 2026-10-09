# Brief: Experiments (feature performance measurement) — epic aiur-team/aiur#3774

You own ONE ticket area of this epic. This brief is the confirmed requirements (Product Contract) from the operator's brainstorm on 2026-10-09. Read it fully.

## What we're building (confirmed)
A standalone, reusable **Experiments** component with its own page. A skimmable experiment index sits in a left-side tab list; selecting one shows that experiment's charts and its written report. An experiment is a generic spec — a before/after line OR A/B cohorts (e.g. Claude vs Codex agents, model X vs model Y) — naming the metrics and the expected direction. Version bumps/releases and the merge of a tagged feature epic create a before/after experiment automatically. Similar to Build Orders, an **Experiment analyst agent** with its own skill drives the generation of each experiment (spec + report), especially feature experiments.

## Operator decisions (verbatim where it matters)
- Comparison styles: "This feature should be agnostic to these different styles of experiments ... before and after ... A/B tests ... comparing the execution of Claude agents versus Codex agents or different models. I think we should build for both."
- Automatic lines: version bump / release, and feature epic merged. NOT every daemon deploy or config change (a spec may still name one by hand).
- Output per experiment: "spec + report, lets have an index list the user can quickly skim through. perhaps a left side set of tabs that updates the content for the new experiment".
- Core metrics, all on by default: ticket flow times (start→PR open, PR open→merge, start→merge, blocker merge→dependent start, gaps between PRs), review and rework (PR ready→first review, review rounds, rework time, CI wait), throughput and capacity (merged/hour, agents vs cap, idle slot-hours, binding gate), cost and quality (spend and tokens per merged ticket, main-red events, reverts). "add analytics to capture if needed."
- Capture setting: "change it to a setting that the user has in their config defaulted to capture analytics but that they can deactivate." (Fact check: `observability.telemetry_enabled` already exists, default true — src/lib/aiur/config/schema/observability.ex:17. Verify what `--debug` still gates and remove any capture gate.)
- Generic: "This page may not be useful to a user of [aiur] that's working with it to develop another repo if we build it too hard-coded to [aiur] features. The definition of a feature needs to remain generic so that anyone can opt in and use this to measure their own relevant application stats" — PR/implementation-speed metrics ship as a built-in metric pack, not hard-coded.
- Modularity: "a standalone, modular, easily reusable, independent component, designed in anticipation of the refactor work" — fit the MP-R1 component map (components.json, declared facades, component-owned child specs; see docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1 on research/refactor-findings).
- Verdict rigor: medians + spread + sample counts, "not enough data" below a minimum count, compare same-complexity tickets where possible; no bare verdict word on the page.
- Analyst agent + skill: "have an agent drive the generation, especially for feature pages. That agent should have a skill specifically for this, so we can tell it important things like review unrelated PRs, bug fixes, and changes that occurred during the experiment phase that may have impacted the metrics. I'd like it to be thorough and structured in a way that data scientists would appreciate, with things like trying to anticipate the p-value based on how much data we have and other common data science experiment metrics and labels."
- Priority: "pull this in ahead of other work since we can then use it to measure future features." First experiment: optimistic dependent start, epic #3755 — its baseline must be captured before its first ticket (#3763) merges.

## Executor call-outs (part of scope)
- Telemetry retention (30 days / 64 MB, observability.ex:18-19) can delete the "before" window; freeze each experiment's baseline summary when the experiment is created.
- Capture gaps: the analytics presenter does not read pr_opened (presenter.ex:739-761); analytics/lib/analytics/reduce.py:366-368 takes a pr.opened timestamp from merged_at first. No version / experiment / cohort marker exists in telemetry or run summaries (only identity.ex:41 aiur_version).

## Grounding
Dossier: /tmp/claude-1000/-home-everdred-github-everdred-aiur/050602fd-97c7-4f7d-8a56-e0498fba4c19/scratchpad/perf-grounding.md (read it). Analytics: src/lib/aiur_web/live/analytics_live.ex, src/lib/aiur_web/operator_control_center/analytics/{presenter,charts}.ex, src/lib/aiur/run_telemetry/*, analytics/ (Python reducer, schema/run-summary.v1.json, README). Prior plans: docs/plans/2026-07-11-006-feat-daemon-run-telemetry-plan.md, docs/plans/2026-07-24-001-feat-build-order-scoped-analytics-plan.md; measurements docs/measurements/*. Build Order pack/agent patterns (how an agent drives generation today): .claude/skills (build-order skills), website/docs-app/concepts/build-orders.md. Read code with `git -C /home/everdred/github/everdred/aiur show origin/main:<path>` / `git grep ... origin/main` (the main checkout is dirty; use origin/main).

## Ticket areas (the epic)
- **X1 capture:** complete, accurate metric events + generic cohort attributes per ticket record (version, backend/model, epic/feature tags, config hash, consumer-defined tags); capture default-on setting; fix the pr_opened gaps.
- **X2 spec + store:** generic experiment spec (line or cohorts, metric list, expected direction, min samples, windows), metric-pack model (built-in "delivery speed" pack; consumer repos add their own metrics), frozen baseline snapshots, storage location under the repo state node.
- **X3 automatic experiments:** version bump/release and tagged-epic-merged lines create experiments automatically.
- **X4 stats engine:** medians/IQR, sample guards, stratification by complexity, effect size, nonparametric test p-values (e.g. Mann-Whitney U), bootstrap CIs, power / minimum detectable effect / "samples needed", multiple-comparison handling, confounder annotations.
- **X5 page:** standalone Experiments page (left index tabs, per-experiment charts + rendered report), desktop + mobile, design consistent with the Claude Design source of truth (MP-E8).
- **X6 analyst agent + skill:** a skill (and a run flow like Build Orders) for the agent that creates/updates experiments: hypothesis, metric choice, review of unrelated PRs / bug fixes / config changes / incidents during the window as confounders, threats to validity, data-scientist-grade report (pre-registration, sample sizes, p-values, power, effect sizes, CIs, labels like "underpowered", "confounded").
- **X7 first experiment:** optimistic start (#3755) baseline capture now + experiment spec; gate #3763 on it.

## Method
1. Load `ce-brainstorm` (Skill tool) and run it for YOUR area only, unattended: the product decisions above are settled (carry them forward, do not re-ask); decide in-the-weeds choices yourself with reasons; collect only genuine operator questions under "Open questions for Kevin".
2. Load `ce-plan` and produce one implementation plan per ticket in your area (touch points file:line, tests that fail without the change, docs that ship, component boundaries per MP-R1, risks). Name the interface you assume from the other areas.
3. Read the code the change touches, not just files named here.

## Output, push, tickets
- Worktree ONLY `/home/everdred/github/everdred/aiur-worktrees/exp-<area>` from origin/research/refactor-findings (detached). Never `cd`; never touch the main checkout working tree, aiur-worktrees/runtime or aiur-worktrees/research.
- Write ONLY `docs/research/experiments/<area>/` (`brainstorm.md`, `plan-<slug>.md`). Area x2 ALSO commits this brief verbatim as `docs/research/experiments/requirements.md`.
- Commit as its-applekid via `git -C <wt> -c user.name=its-applekid -c user.email=its-applekid@users.noreply.github.com commit -F <msgfile under /home/everdred/.aiur/review-scratch/>`. NO AI attribution anywhere.
- Push loop (≤5): fetch + rebase origin/research/refactor-findings + `git -C <wt> -c credential.helper='!f(){ echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f' push origin HEAD:research/refactor-findings` with `export GITHUB_TOKEN=$(grep -E '^GITHUB_TOKEN=' /home/everdred/github/everdred/aiur/.env | cut -d= -f2-)`. Never print the token or put it in a URL.
- Tickets as its-everdred: `env -u GITHUB_TOKEN -u GH_TOKEN gh issue create --repo aiur-team/aiur --title "EXP-<AREA>-<n>: <imperative>" --body-file <f> --label agent:todo --label priority:1 --label complexity:<1-3>` (priority:1 for all — the operator pulled this ahead of other work). Body: problem, decided design (5-15 lines), testable acceptance criteria, links to `https://github.com/aiur-team/aiur/blob/research/refactor-findings/docs/research/experiments/<area>/plan-<slug>.md` and the brainstorm, "Part of #3774". Make each a sub-issue of the epic (`gh api -X POST repos/aiur-team/aiur/issues/3774/sub_issues -F sub_issue_id=<database id>`); add in-area blocked_by links only where real (`gh api -X POST repos/aiur-team/aiur/issues/<dep>/dependencies/blocked_by -F issue_id=<blocker database id>`).
- Remove your worktree at the end.

## Report (under 200 words)
Doc paths + commit SHA; tickets (number, title, complexity); in-area links; cross-area links you need (the Executor adds them); open questions for Kevin, one line each with your recommendation.
