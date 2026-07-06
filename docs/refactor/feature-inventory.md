# Feature Inventory — the Anti-Regression Contract

The authoritative, exhaustive map of every feature and behavior in aiur, built
for the production-readiness refactor whose first rule is **no feature is
removed**. Every refactor ticket lists the `Inventory-IDs:` it touches;
reviewers verify a PR against exactly those entries. Generated 2026-07-06.

Sections live in `docs/refactor/feature-inventory/` (split for reviewability;
the brief's single-file wording is deviated deliberately — see
`00-overview.md`).

## Method

- **Two-angle extraction:** 17 subsystem slices plus 5 cross-cutting sweeps
  (every CLI command/flag, every config option, every event/alert name, every
  runtime artifact, every doc-claimed feature), so each feature had two
  independent chances to be found. 1,230 raw entries.
- **Completeness critics:** two independent passes (repo-tree walk;
  docs/SPEC/skills claims) surfaced 9 gaps — tracker adapters, custom mix-task
  gates, codex-native skills, the Docker warm-base pipeline — which were then
  extracted at full depth.
- **Merge/dedup:** per-section merge preferring sweep granularity for
  enumerations and slice depth for behaviors; 1,062 final entries.
- Every entry cites code evidence (path:line), names its existing test
  coverage (or `none`), and carries a refactor-risk rating. High-risk entries
  with no tests carry a one-line `Check:` probe where an obvious manual probe
  exists.

## Entry format and ID scheme

```
- **FI-<SECTION>-NNN · <name>** [<kind>] — <behavior, with evidence paths>. Tests: <files|none>. Risk: <low|medium|high>.
```

IDs are stable: never reused, never renumbered; new entries append. Tickets
reference entries via their `Inventory-IDs:` field; the consistency check
script verifies every referenced ID resolves.

## Sections

| Section | File | Entries |
|---|---|---:|
| CLI & control surface | [feature-inventory/cli.md](feature-inventory/cli.md) | 74 |
| Configuration & personalization | [feature-inventory/cfg.md](feature-inventory/cfg.md) | 104 |
| Event bus, agent events & alerts | [feature-inventory/evt.md](feature-inventory/evt.md) | 116 |
| GitHub integration & PR monitoring | [feature-inventory/gh.md](feature-inventory/gh.md) | 72 |
| Tracker adapters (Linear, Memory, dispatch) | [feature-inventory/trk.md](feature-inventory/trk.md) | 15 |
| Orchestrator & agent lifecycle | [feature-inventory/orc.md](feature-inventory/orc.md) | 81 |
| Coding-agent registry & Codex backend | [feature-inventory/cdx.md](feature-inventory/cdx.md) | 60 |
| Claude backends (headless + REPL/RC) | [feature-inventory/cld.md](feature-inventory/cld.md) | 67 |
| Opencode chat-pane bridge | [feature-inventory/oc.md](feature-inventory/oc.md) | 61 |
| Repo prewarm | [feature-inventory/pw.md](feature-inventory/pw.md) | 31 |
| Tmux, panes & agent-list TUI | [feature-inventory/tui.md](feature-inventory/tui.md) | 81 |
| LiveView dashboard & HTTP server | [feature-inventory/web.md](feature-inventory/web.md) | 38 |
| Workspaces, init & test modes | [feature-inventory/ws.md](feature-inventory/ws.md) | 35 |
| Engine scripts, packaging, build & dev-tooling gates | [feature-inventory/eng.md](feature-inventory/eng.md) | 80 |
| Skills (driver, workspace-installed & codex-native) | [feature-inventory/skl.md](feature-inventory/skl.md) | 62 |
| Website & terminal sim | [feature-inventory/site.md](feature-inventory/site.md) | 42 |
| Runtime artifacts & persistence contracts | [feature-inventory/art.md](feature-inventory/art.md) | 36 |
| Doc-drift: documented but absent or contradicted | [feature-inventory/doc.md](feature-inventory/doc.md) | 7 |
| **Total** | | **1,062** |

Artifact entries (FI-ART) deliberately complement behavior entries elsewhere:
they pin the artifact *contract* (path, format, readers/writers, retention)
even where a behavior entry covers the same feature from the runtime angle.

## Known wiring gaps and drift (pre-existing — preserve, don't silently "fix")

The extraction surfaced behaviors that are inconsistent or inert **today**.
Refactor tickets must not silently change them; each needs an explicit
preserve-or-fix decision (default: preserve behavior, file a `needs-triage`
issue for the fix):

- `attention.*` events are not wired into `open_attentions` (see FI-EVT
  section notes).
- The custom-event quota config knob is accepted but unenforced.
- `issue.state.changed` has an alert definition but no emitter.
- The repo's own `.aiur/alerts.yaml` still uses pre-`phase.` alert keys.
- `events.codeowners_refresh_seconds` exists in the schema but is not wired to
  the CodeOwners GenServer (FI-GH-036).
- `Aiur.Claude.EventHumanizer` appears latent/dead — no caller besides the
  behaviour declaration (FI-CLD-025).
- Doc-drift entries (FI-DOC) cover documented-but-absent features: the
  chat-pane ANSI recorder (`log/record/chat.<issue>.ansi`), the `--record`
  `screen.ansi` capture, the stale `make -C elixir` reference, and the
  PR-template vs dev-loop contradiction. Each carries a restore-or-fix-docs
  decision for the checkpoint.

## How this document is used

1. **Ticket authoring (U10):** every ticket's `Inventory-IDs:` field lists the
   entries its files implement or touch; risky tickets also carry
   `Characterization-tests:`.
2. **PR review:** the loop-running agent at merge time confirms the listed
   entries' behavior survives — named tests still pass unmodified, `Check:`
   probes pass where present.
3. **Scoped verification, not exhaustive:** a PR checks only the
   Inventory-IDs it touches; a phase, at exit, checks the union of features
   it touched (and may do so while the next phase runs). The full
   1,062-entry sweep runs **once**, at final `v2` acceptance. See
   `RUNBOOK.md` §7.
4. **Regression-safety mapping (pass 2):** after ticket generation,
   `regression-safety.md` maps every FI entry to its coverage: a
   characterization test, a named existing test, a `Check:` probe, or an
   explicit no-coverage rationale.
