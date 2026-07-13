---
title: Add the Aiur Debug Context Overlay
type: feat
status: completed
date: 2026-07-13
---

# Add the Aiur Debug Context Overlay

## Summary

Add one canonical `/aiur-debug` context overlay with focused references for Aiur evidence, correlation, bounded triage, recovery safety, worked examples, and reporting. Expose the same source to Claude-compatible and Codex agents, bundle it into issue workspaces, and replace the legacy narrow Codex-only guidance without duplicating general debugging methods.

---

## Problem Frame

Aiur failures span launcher, BEAM, tmux, trackers, agent providers, workspaces, events, dashboards, and GitHub state. The existing Codex-only debug skill covers only a narrow log trace and cannot reliably distinguish orchestration defects from expected queueing, agent choices, provider transport failures, tracker drift, repository defects, or resource pressure.

---

## Requirements

- R1. Keep `/aiur-debug` strictly an Aiur context overlay that capability-detects and composes with native `/debug`, optional `/ce-debug`, and available provider diagnostics.
- R2. Map authoritative evidence, limitations, portable locations, correlation keys, timestamp normalization, and Aiur-specific classification rules.
- R3. Provide ten bounded, read-only-first diagnostic procedures with evidence gates, stopping conditions, and blast-radius-aware escalation.
- R4. Include worked examples for duplicate agent-issued commands, a tracker-paused ticket, a missing non-loopback dashboard listener, and a genuine orchestrator retry/replay defect.
- R5. Define a concise diagnostic report and sanitized bug-report checklist.
- R6. Make the skill discoverable from both backend paths and available in generated issue workspaces from one canonical source.
- R7. Add focused validation for metadata, required content, references, discovery, portability, and sanitization.

---

## Scope Boundaries

- Do not reproduce generic hypothesis formation, reproduction strategy, causal-chain analysis, or fix-validation handbooks.
- Do not add mutating diagnostic automation or runtime behavior.
- Do not hardcode an operator home directory, hostname, IP address, credential, account identity, or private content.
- Do not present logs, process counts, dashboard/API state, or tracker state as proof of a different layer without correlation.

---

## Context & Research

### Relevant Code and Patterns

- `.claude/skills/aiur-agent/` is the canonical-source-plus-focused-references pattern; `.codex/skills/aiur-agent` is its relative discovery symlink.
- `src/lib/aiur/agent_skills.ex` embeds issue-worker skills at compile time and installs matching Codex symlinks.
- `src/lib/aiur/log_file.ex`, `src/lib/aiur/agent_event_log.ex`, `src/lib/aiur/config/paths.ex`, and `packaging/npm/aiur-cli/libexec/aiur-engine.sh` define current evidence paths and runtime identity.
- `AGENTS.md` is authoritative for tracker slug semantics, workspace logs, and real non-TTY TUI verification.
- `.codex/skills/debug/SKILL.md` is the narrow guidance to supersede with a canonical link.

### Institutional Learnings

- `docs/refactor/research-history-hotspots.md` records recurring false classifications: dashboard listeners not wired, load gates ineffective, OpenCode transport churn, and retry-budget mistakes.
- Current runtime logging uses one `aiur.log` when debug is enabled and does not internally rotate it; older or externally rotated files are historical evidence, not an assumed current rotation mechanism.

---

## Key Technical Decisions

- Canonical source under `.claude/skills/aiur-debug/`: follows existing shared-skill convention and prevents backend drift.
- Three focused references: keep the entry skill scannable while separating the evidence/correlation map, diagnostic recipes, and examples/reporting.
- Capability-based composition: direct agents to inspect the active skill catalog, load native `/debug` first, add `/ce-debug` when present, and add provider-native diagnostics only for the implicated layer.
- Dedicated ExUnit contract test: documentation and symlink invariants are stable repository behavior and fit the existing `aiur_agent_skill_test.exs` pattern.

---

## Implementation Units

### U1. Canonical overlay and discovery

**Goal:** Add the complete Aiur-specific context overlay and expose it consistently to operators and issue workers.

**Requirements:** R1, R2, R3, R4, R5, R6

**Dependencies:** None

**Files:**
- Create: `.claude/skills/aiur-debug/SKILL.md`
- Create: `.claude/skills/aiur-debug/evidence-and-correlation.md`
- Create: `.claude/skills/aiur-debug/diagnostic-recipes.md`
- Create: `.claude/skills/aiur-debug/examples-and-reporting.md`
- Create: `.codex/skills/aiur-debug`
- Modify: `.codex/skills/debug/SKILL.md`
- Modify: `src/lib/aiur/agent_skills.ex`

**Approach:**
- Route from a concise entry document into focused references and existing maintained skills/docs.
- Start every recipe read-only; state authoritative evidence, counter-evidence, stopping/classification condition, and escalating recovery order.
- Preserve legacy `/debug` as a generic companion rather than a competing Aiur source of truth.

**Patterns to follow:**
- `.claude/skills/aiur-agent/SKILL.md`
- `.codex/skills/aiur-agent`
- `src/lib/aiur/agent_skills.ex`

**Test scenarios:**
- Integration: install issue-worker skills into a clean workspace -> canonical `aiur-debug` content and the relative Codex symlink both resolve.
- Integration: read either repository discovery path -> both expose byte-identical canonical guidance.

**Verification:**
- No second independently maintained Aiur debug handbook remains.

### U2. Skill contract validation

**Goal:** Prevent the overlay from drifting out of required scope or becoming undiscoverable, unsafe, or machine-specific.

**Requirements:** R1, R2, R3, R4, R5, R6, R7

**Dependencies:** U1

**Files:**
- Create: `src/test/aiur/aiur_debug_skill_test.exs`
- Modify: `src/test/aiur/aiur_agent_skill_test.exs`
- Modify: `src/test/aiur/agent_skills_test.exs`

**Approach:**
- Validate frontmatter, reference existence, discovery symlinks, issue-worker taxonomy, ten recipe headings, worked examples, companion-skill language, cross-links, report/sanitization content, and forbidden machine-specific or secret-like examples.

**Test scenarios:**
- Happy path: canonical skill tree satisfies every metadata, content, link, and discovery invariant.
- Edge case: legacy `debug` guidance cannot reintroduce an independent Aiur evidence map.
- Error path: a missing recipe/reference, wrong symlink target, machine-specific example, or copied secret pattern fails with a focused assertion.

**Verification:**
- The affected skill tests pass with the repository's four-case test cap.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Documentation claims drift from runtime | Anchor evidence statements to current source modules and protect key claims with focused assertions. |
| Overlay grows into a generic handbook | Keep method ownership explicit and test for native `/debug` plus optional `/ce-debug` composition. |
| Recovery advice causes collateral damage | Require preservation, scope statement, and evidence checkpoint before every relabel/restart/kill/reset action. |
| Backend copies diverge | Keep one canonical directory and a relative Codex symlink. |

---

## Sources & References

- Issue #1078
- `AGENTS.md`
- `src/docs/logging.md`
- `src/lib/aiur/log_file.ex`
- `src/lib/aiur/agent_event_log.ex`
- `src/lib/aiur/agent_skills.ex`
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
