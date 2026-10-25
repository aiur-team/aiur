# U0 implementation owner ledger — 7fe2fca3f

Pinned implementation commit: `7fe2fca3ff118fc700e8cfc6f149ceba9d051648` (`main`, 2026-10-08).
[Ledger CSV](u0-owner-ledger-7fe2fca3f.csv) contains **378 paths in the existing 37 packages**.
This is a write-owner research record, not authorization to split, delete, or regenerate a file.

## Census and reconciliation

- 3,902 regular tracked blobs: 3,529 UTF-8 text and 373 binary; 41 symlinks excluded, never followed.
- 378 text paths exceed 500 physical lines. Count LF bytes, plus one for a nonempty unterminated final line;
  NUL-containing or invalid UTF-8 blobs are binary. Count committed blobs, not the working tree.
- Release ledger: 357 paths at `465aca643527ea94a4d0d6d7c178c5d23d2aaf57`; 21 new, zero retired.
- 115 release paths changed: 113 grew, 2 shrank, net +6,619 lines across survivors.
- The ticket's 373/16 census was at `58854d4c8`; this later pin adds five more paths.
- Zero missing or extra paths, zero duplicate rows, and every row has one package and a next action.
- No release owner changes. New-path boundary overrides are recorded below; no later U8 ledger
  or U8 ownership claims were present in this checked implementation tree. A live U8-title issue search
  and U8 branch search found no corresponding active package workers. Conflicts discovered at worker pickup
  must yield to an already-claimed U8 ticket and be recorded before concurrent writes.

## Review evidence and limits

`callers_checked` counts external matching **lines** from `rg --hidden --no-ignore -n -F`
against an isolated snapshot of pinned text blobs, excluding the file itself. Elixir searches use all
qualified `defmodule` names; other executable text searches use the filename. This is static evidence,
not a semantic call graph: grouped aliases, short aliases, dynamic calls and imports require seam review.
`behavior_test` selects the existing sibling test when present, otherwise up to three external test references.
A test module names itself because preserving its assertions is the split contract. No listed behavior tests
were run by this documentation ticket; workers must read and execute them before changing behavior.
Non-executable text records an explicit n/a reason. Generated/design artifacts name package validation;
no automated test found is recorded as a gap, not presented as coverage.

Lockfiles have regeneration commands with dependency-parity prerequisites. Frozen prototypes have candidate
removal and pinned-blob reproduction instructions; the imported build-home reference remains immutable until
design authority and browser parity are established. Snapshot generators not yet approved are explicitly gated;
`git show <pin>:<path>` reproduces their current bytes, not an invented regeneration recipe.

## New paths and boundary review

| Path | Lines | Write owner | Review / consulted domain |
| --- | ---: | --- | --- |
| `docs/aiur-style/plan.md` | 788 | `BROWSER` | DOCS consulted; shared style contract belongs with browser assets. |
| `packages/aiur-style/package-lock.json` | 753 | `BROWSER` | DOCS/SITE consulted; shared browser style package, regenerate with npm. |
| `src/lib/aiur/accounts.ex` | 724 | `TELEMETRY` | AGENT_CORE consulted; harness/account identity feeds provider telemetry. |
| `src/lib/aiur/config/schema/agent.ex` | 511 | `CONFIG` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/lib/aiur/decision_attention.ex` | 529 | `DECISIONS` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/lib/aiur/model_availability.ex` | 571 | `AGENT_CORE` | CONFIG consulted; model selection belongs to AGENT_CORE, overriding harness fallback. |
| `src/lib/aiur/workspace/wip_preservation.ex` | 671 | `WORKSPACE` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/lib/aiur_web/operator_control_center/provider_meters_presenter.ex` | 531 | `TELEMETRY` | WEB consulted; provider-meter directory rule retains TELEMETRY ownership. |
| `src/lib/aiur_web/operator_control_center/units_presenter.ex` | 501 | `WEB` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/test/aiur/accounts_test.exs` | 641 | `TELEMETRY` | AGENT_CORE consulted; follows Accounts owner. |
| `src/test/aiur/orchestrator/dispatcher_blocked_by_cost_test.exs` | 541 | `LIFECYCLE_DISPATCH` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/test/aiur/orchestrator/global_pause_test.exs` | 520 | `LIFECYCLE_STATUS` | LIFECYCLE_DISPATCH consulted; pause state belongs to status lifecycle. |
| `src/test/aiur/provider_meters_test.exs` | 507 | `TELEMETRY` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/test/aiur/run_telemetry/sampler_test.exs` | 548 | `TELEMETRY` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/test/aiur/workspace/wip_preservation_test.exs` | 988 | `WORKSPACE` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/test/aiur_web/operator_control_center/analytics/presenter_test.exs` | 516 | `WEB` | ANALYTICS/TELEMETRY consulted; web projection test stays WEB. |
| `src/test/aiur_web/operator_control_center/units_presenter_test.exs` | 524 | `WEB` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/test/fixtures/build_home/design-source/Aiur Dashboard.html` | 5134 | `BROWSER` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/test/fixtures/build_home/design-source/assets/analytics.js` | 612 | `BROWSER` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/test/fixtures/build_home/design-source/assets/build.css` | 1193 | `BROWSER` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |
| `src/test/fixtures/build_home/design-source/assets/build.js` | 1577 | `BROWSER` | Directory/domain rule; existing package validation and CSV behavior evidence apply. |

## Pre-refactor credits (separate from this refresh)

The frozen 359-row map lost these four paths before the 357-row release ledger:
`src/lib/aiur/github/budget_map.ex`, `src/test/aiur/github/cache_inspector_test.exs`,
`src/lib/aiur_web/live/github_cache_live.ex`, and `src/test/aiur_web/live/github_cache_live_test.exs`.
The old map attributed cache/dashboard removal to #2840/#2841. Current Git history identifies #2841
(`694f9d021`) as the dashboard removal; #2840 (`d04069711`) is titled “Remove local PR deletion guard”.
Do not claim all four deletions as #2840's work, this ticket's work, or future U8 savings.

Two earlier release additions remain separate: `src/test/aiur/orchestrator/status_report_test.exs`
(`LIFECYCLE_STATUS`) and `src/test/aiur_web/components/operator_control_center/units_table_test.exs`
(`WEB`). Their caller counts and behavior-test columns now name the preserved suites.
No release path retired or became binary at this pin, so no rename or reclassification decision is needed.

## Provenance and reproduction

The cited research directory was absent from implementation main. Restored only the existing generator,
release assignments/proposal, frozen owner map, and release census from research commit
`6732f5f9f448b1857a9643993849635f85321e19`. These are historical inputs, not a fresh census.
The generator's original no-argument release output remains unchanged; `--sha` adds the current review columns
without overwriting release assignments. This PR's new research files are outside the pinned census;
a later implementation pin must recount them as ordinary text, with no exemption.

```bash
python3 docs/research/refactor-2026-09-26/synthesis/u8-release-007/build.py --sha 7fe2fca3ff118fc700e8cfc6f149ceba9d051648
```

Independent committed-blob census compared the complete path/line map to the CSV: **378 equal rows**.
A second generator run produced identical bytes; the original release mode reproduced its 357-row CSV.
Synthetic committed-blob checks passed for 500/501 lines, terminated/unterminated final lines, empty text,
NUL/invalid UTF-8, CR-only text, and symlinks. Missing-row and wrong-count negative controls were rejected.
No runtime/CLI/config surface changed; focused Elixir and manual TUI tests are outside this research-only change.
