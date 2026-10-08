---
ticket_id: MP-E7-C7-T05
feature_id: MP-E7
chunk_id: MP-E7-C7
bucket: 2-platform
title: "Docs: listener modes concept, CLI reference, config key (only if E7-D7), aiur-agent skill note"
status: ready
blocked_by: [DESIGN-E7, MP-E7-C7-T03, MP-E7-C5-T01]
repo: aiur-team/aiur
wave: 4
prior_units: []
prior_boundaries: [DOCS]
prior_features: []
prior_findings: [AGENTS.md "Docs ship with the change"]
size_owner: n/a (docs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C7-T05 — Listener-mode documentation

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C7.
- **User value:** an operator can learn what `steer`, `sync` and `async`
  mean, how each harness supports them, and how to change them; an agent
  knows when to call `aiur_read_messages`.
- **Deliverable:**
  - a section on listener modes in `website/docs-app/concepts/` — prefer
    extending `concepts/operating-aiur.md` or `concepts/executor.md` over a
    new page (AGENTS.md "Prefer editing an existing page"); if a new page is
    unavoidable, add it to `website/docs-app/.vitepress/config.ts` sidebar;
  - `reference/configuration.md` entry **only if** DESIGN-E7 E7-D7 adds a key
    (e.g. `agent.listen_mode`); `scripts/check-config-docs.py` then enforces
    it in the `lint` job;
  - `reference/cli.md`: confirm C7-T03's rows and the C7-T04 `aiur message`
    rewrite are present and consistent;
  - `.claude/skills/aiur-agent/SKILL.md` note on `aiur_read_messages`
    (when, and that it consumes);
  - `skills.md` only if the skill's documented surface changes.
- **Non-goals:** inventing copy; all mode names, labels and reasons come from
  DESIGN-E7.

## Dependencies and blockers

- **DESIGN-E7** (copy, E7-D4/D6/D7 answers). **MP-E7-C7-T03** (CLI names),
  **MP-E7-C5-T01** (tool name).
- **May run concurrently with** C7-T01/T02; must merge with or after C7-T04
  for the "default" statement to be true.

## Verified starting point (at `45a290e3`)

- Pages: `website/docs-app/concepts/{executor,operating-aiur,message-bus,commands}.md`,
  `reference/cli.md` (`aiur message` rows `:117-118`, outcome text `:127`),
  `reference/configuration.md`, `guide/{gui,tui,stream-deck}.md`.
- `guide/tui.md:62` describes `Ctrl+C` in chat as interrupting active work —
  stays true (control, not a mode).
- Config-doc checker: `scripts/check-config-docs.py` (AGENTS.md).

## Chosen design

One concept section with: the three modes (contract §1), what obeys the mode
and what does not (contract §2 table: Command answers, digests and controls
do not), requested vs effective (§4) with the per-harness table (§9, final
values after C4), the async read tool, and the Executor hook delivery (C6)
in two sentences with a link to the attach command.

## Implementation steps

1. Concept section. 2. CLI reference check. 3. Config entry if E7-D7.
4. Skill note. 5. Build the docs site to confirm links:
`env -C website/docs-app bun install --frozen-lockfile && env -C
website/docs-app bun run build` (the sequence used by
`website/package.json:17`).

## Non-happy paths

n/a — documentation only; the risk is a false statement, guarded by review
against the merged code and DESIGN-E7.

## Compatibility and rollout

Merge with or after C7-T04 so docs never describe a default that is not live.

## Verification

- `python3 scripts/check-config-docs.py` passes (and fails if E7-D7 adds a
  key and the entry is removed — the existing guard
  `scripts/test-check-config-docs.sh` covers the checker).
- Docs site build succeeds; reviewer checks every harness row against the
  listener-mode contract §9 at merge time.

## Completion and handoff

- [ ] Every page AGENTS.md lists for a CLI flag, config key and new surface is
  updated; no page describes the removed interrupt default.
