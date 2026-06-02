# Per-Complexity Agent Routing — Requirements

**Date:** 2026-05-30
**Scope:** Standard — feature (bounded architectural refactor of the backend-selection seam)
**Status:** Ready for planning
**Issue:** #215

## Problem

Aiur picks its coding-agent backend **once per run** from a single global setting. `Aiur.CodingAgent.adapter/0` and `transcript_module/0` (`elixir/lib/aiur/coding_agent.ex:24,39`) switch on `Aiur.Config.agent_kind()`, which is read from the WORKFLOW `agent.kind` field. Every issue in a run therefore uses the same backend — you cannot run Codex on some tickets and Claude on others in one aiur session.

We want backend selection driven by each issue's **complexity label** instead of a global toggle: high-complexity tickets go to Claude (stronger reasoning), routine tickets stay on Codex (faster/cheaper). Both backends must be able to run **concurrently** within a single aiur run.

## Goal

Route the coding-agent backend per issue from its `complexity:` label, configurable in the WORKFLOW file, so that Codex and Claude agents run side-by-side in one run with each issue behaving fully like its resolved backend — with no change to default behavior for repos that don't configure routing.

## Success Criteria

- An issue labeled `complexity:4` or `complexity:5` runs on Claude; `complexity:1/2/3` and unlabeled issues run on Codex (this repo's configured mapping).
- A single aiur run can have a Claude-routed issue and a Codex-routed issue active at the same time, each rendering and behaving as its own backend.
- The complexity→backend mapping is set in the WORKFLOW file (not hardcoded).
- When no routing config is present, behavior is identical to today (all issues use `agent.kind`).
- `make all` stays green (compile-Werror, format, lint, test, dialyzer).

## Actors & Flow

- **Operator** — sets the routing map in the WORKFLOW file and labels issues with `complexity:N`.
- **Orchestrator / AgentRunner** — resolves each issue's backend at run time and drives that backend's session, transcript, and delivery policy.

**Key flow:** Issue enters `agent:todo` with a `complexity:N` label → orchestrator/AgentRunner resolves backend from the label via the routing map (fallback to `agent.kind`) → that issue's agent process, transcript extraction, event humanization, and delivery-policy defaults all use the resolved backend → multiple issues with different resolved backends run concurrently.

## Requirements

1. **Per-issue backend resolution.** A single resolution point maps an `Aiur.Issue` (via its `complexity:` label) to `"codex" | "claude"`, falling back to `agent.kind` when the issue has no complexity label or the level is unmapped.
2. **Full functional routing.** Every functional read of `Config.agent_kind()` becomes per-issue: the agent process (`start_session`/`run_turn`/`stop_session`), `transcript_module`, `normalize_event`, `event_humanizer`, and the orchestrator's `default_can_interrupt?` / `default_safe_checkpoints`. A Claude-routed issue must not inherit Codex's delivery policy or humanizer (no split-brain).
3. **Configurable explicit per-level map.** The WORKFLOW `agent` block carries an explicit complexity-level → backend mapping (e.g. levels 4 and 5 → claude). Validated in `Aiur.Config.Schema`. This repo's WORKFLOW is seeded with `4,5 → claude`.
4. **Backward compatibility.** With no routing map configured, all issues resolve to `agent.kind` exactly as today.
5. **Concurrency safety.** Two issues resolving to different backends run in the same aiur run without interfering (each AgentRunner owns its resolved backend end-to-end).

## Scope Boundaries

**In scope**
- Per-issue backend resolution from the complexity label.
- Threading the resolved backend through all functional `agent_kind` read sites.
- WORKFLOW config schema for the routing map + seeding this repo with `4,5 → claude`.

**Deferred for later**
- Display surfaces (`presenter.ex:189`, `dashboard_live.ex:472` agent badge) may show the run's default `agent.kind` or a "mixed" indicator; a per-issue badge in the UI is a nice-to-have, not required for this change.
- Routing on any signal other than the `complexity:` label (e.g. per-label allowlists, cost budgets, priority).
- Pre-warm pool awareness of mixed backends, if it proves backend-specific during planning (flag as a planning risk to confirm).

**Outside this product's identity**
- Auto-classifying complexity (the operator sets the label; we only read it).

## Key Decisions

- **Full per-issue routing** (not minimal agent-only) — chosen for behavioral correctness so a routed issue behaves entirely like its backend.
- **Explicit per-level map** (not a single `claude_min_complexity` threshold) — chosen for flexibility to change which levels route where without assuming a monotonic rule.
- **Fallback = `agent.kind`** — unlabeled/unmapped issues and unconfigured repos keep today's behavior.

## Dependencies & Assumptions

- `Aiur.Issue` already carries `labels` and exposes `Aiur.Issue.label_names/1`; the orchestrator already reads labels via `issue_tag` — the same pattern reads `complexity:`.
- `AgentRunner` is already per-issue, so the resolved backend is available at every functional call site without new plumbing for the agent/transcript path.
- **Assumption to verify in planning:** the opencode pre-warm pool (`pre_warmed_sessions`) is backend-agnostic, or can warm/serve a mixed-backend run without binding the whole run to one backend.

## Open Questions (for planning)

- Where does backend resolution live (a new `Aiur.CodingAgent.backend_for/1` vs. resolving in each caller)? Planning decides the single seam.
- Exact WORKFLOW key/shape for the routing map and its schema validation.
- Does the orchestrator resolve once per issue and pass the backend down, or does each site re-resolve from the issue? (Consistency vs. plumbing trade-off.)
