# MP-R1 acceptance evidence

Date: 2026-10-26. Tested main:
`889212aa39a2fb992da7942c6e4236f7b70be376` (isolated detached main checkout).
This is automated acceptance evidence plus an Executor smoke-test handoff.
No live daemon restart, TUI interaction, device test, or screenshot was performed
from this issue workspace. End-to-end acceptance remains unobserved here.

## Inputs and scope

The original issue's build-order mirror is no longer in the checkout.

The [pinned MP-R1 plan
§7](https://github.com/aiur-team/aiur/blob/6732f5f9f448b1857a9643993849635f85321e19/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/plan.md#7-acceptance-criteria)
was recovered through the GitHub contents API; its ten criteria drive this report.

Current companions are the [migration plan](../../bucket-1-refactor/MP-R1/migration-plan.md),
[component map](../../bucket-1-refactor/MP-R1/component-map.md), and
[final refresh](../../refresh/MP-R1-C11-T03/README.md).

DESIGN-R1 approval is recorded on [#3342](https://github.com/aiur-team/aiur/issues/3342#issuecomment-6067750595).

[Member receipts](members.md) cover 75 tasks: the original 69 plus GHA-1..6.
72 closing PR merges are ancestors of tested main; C6-T04 was explicitly not
planned and C11-T02 was accepted as a research publication. GHA-6 / #3828 is
open and explicitly deferred as conditional physical-promotion work (DF-016).

This report adds no implementation, new tests, product approval, or package promotion.

## Criteria and evidence

1. **Ownership:** `python3 scripts/check-components.py --require-elixir` passed.
   All 2,981 source files are owned. There are no current service sources to count.
2. **Forbidden references:** checker fixtures exercise private references,
   upward layers, required-to-optional dependencies, and client-to-core imports.
   Results of the full fixture command are recorded below.
3. **Ratchet:** current checker passed with no stale entries or new violations.
   It reported baseline keys: declared 197, private 35, down 84, optional 148.
   Historical allowance changes are reported separately below; a current pass
   alone does not prove each historical PR decreased violations.
4. **Capabilities — automated only; live check pending the Executor:** existing CLI engine, wire golden, core/optional providers,
   registry supervision, notifications, controller and run-shape tests passed.
   Core provider integration terminates the real test orchestrator and observes
   `unavailable/not_running`. Real CLI launches for all shapes remain post-deploy.
   `--no-dashboard` deliberately removes HTTP; only the CLI report exists there.
   Boot ID plus in-memory revision supersedes the early persistent-revision wording.
5. **Voice absence — automated only; live check pending the Executor:** optional-provider integration removes the configured key
   and checks that only `voice.stt` and `voice.tts` change to `not_configured`.
   Text input coverage is listed below. Sending and seeing text in the real TUI
   without a voice key remains post-deploy.
6. **No root — automated only; live check pending the Executor:** optional-provider tests assert unavailable build-order progress
   without numeric fields; root-summary/progress tests cover projections.
   These automate value semantics; no live root configuration was changed.
7. **Route order — automated only; live check pending the Executor:** controller and router-table tests passed; capabilities resolves
   through its dedicated route rather than the generic issue route.
8. **Config:** all 290 keys documented; checker passed with 30 sections, 7 scalar
   fields, 96 environment variables and 29 state paths owned exactly once.
9. **Directory:** 16 loader/render tests passed, manifest docs links validated,
   and the frozen-lockfile VitePress build completed successfully.
   The public page is generated from indexed component records.
10. **Manual surfaces — automated only; live check pending the Executor:** pending the exact Executor checks below. No claim is made
    about unchanged runtime UX after every historical move, or current rendered UX.

## Timestamped command output

Runtime, checker and docs commands were rerun in a clean detached checkout of current main
`889212aa39a2fb992da7942c6e4236f7b70be376`.
Each quoted output block records
its exact command, working directory, full SHA, UTC start/end times and exit code.

The output quotes support the counts above. Receipt/census reads run from the
report checkout against immutable merge objects and this same main SHA.

- [Core tests and lint](core-output.md).
- [Component/config/documentation checks](checker-output.md).
- [Positive and negative checker fixtures](fixtures-output.md).
- [Contracts and docs build](web-output.md).
- [72 merge ancestry checks](members.md#receipt-verification-output).
- [Historical allowance census](census-output.md).

The core suite's excluded quarantined case is not counted as passed. These
are existing tests: no new test or production change needs a mutation check.
Criteria 4–7 have automated evidence only; criterion 10 has no live observation.
All five remain **live check pending the Executor**, as detailed below.

## Post-deploy checks

These checks require an Executor checkout, outside an issue workspace, with
sandbox access and a terminal/browser. Use [the canonical wrapper-tmux recipe](../../../../manual-testing.md).
Capture the actual socket/session printed by that launch. Never use a guessed
socket, API message injection, or logs as a substitute for rendered output.

- Post-deploy check: from the Executor repo root on current `main`, record `git rev-parse HEAD`, run
  `scripts/aiurdev build` and `scripts/aiurdev restart`, then inspect `scripts/aiurdev status` and the release
  build stamp to confirm the loaded repo and commit match (operator: Executor).
- Post-deploy check: from the Executor repo root launch `scripts/aiurdev --test --force --allow-remote` using
  the wrapper-tmux recipe; wait for an agent to run, press Enter on its row, send “MP-R1 text smoke” through
  its chat input, and capture the rendered response with `tmux capture-pane` on the printed socket/session;
  open the dashboard and capture its agent/chat content (operator: Executor with browser).
- Post-deploy check: on that foreground sandbox run compare `scripts/aiurdev capabilities --json` with
  authenticated `GET /api/v1/capabilities`; verify v1 markers, boot ID, revision, freshness, run shape and
  typed capability states, and confirm `/api/v1/capabilities` is not an issue response (operator: Executor).
- Post-deploy check: repeat the capability report for sandbox `--bg`, `--bg --no-dashboard`, and `--executor`
  launches, stopping only the sandbox instance between launches; verify JSON API in listener-enabled shapes
  and CLI-only capabilities with HTTP unavailable for `--no-dashboard` (operator: Executor).
- Post-deploy check: in the isolated sandbox remove its ElevenLabs key, confirm `voice.stt` and `voice.tts`
  become `unavailable/not_configured`, send text through the actual TUI chat input and capture the response;
  restore the sandbox key (operator: Executor).
- Post-deploy check: in a sandbox with no build-order root confirm `build_orders.progress` is unavailable and
  dependent progress fields are absent rather than zero; inspect the dashboard and rendered TUI for
  regressions (operator: Executor with browser).
- Post-deploy check: open the built `/components` docs page, follow its sidebar entry, inspect current and
  planned entries and follow component documentation links; save screenshots of the desktop layout (operator:
  Executor with browser).

No physical Stream Deck check is required by the ten MP-R1 criteria; this capstone
changes no device interaction. Later device features retain their own acceptance.

## Historical allowance census and findings

For each of the 67 closing merge commits, enumerate
`scripts/components/allowlist/` with `git ls-tree -r --name-only`, then read each
file with `git show <merge>:<path>` and `<merge>^:<path>`.
Count non-empty, non-comment rows; compare each merge to its first parent.
This counts allowance keys rather than reference occurrences.

Five increases were observed:

- #3530 / C1-T02: 0 → 441 rows (initial declared/private baseline).
- #3578 / C1-T03: 405 → 747 rows (initial down/optional baseline).
- #4021 / C9-T11: 586 → 589 rows (moved Executor verbs).
- #4409 / C9-T12: 573 → 577 rows (moved control verbs).
- #5026 / C9-T14: 521 → 545 rows (moved read verbs).

The latter three diffs explicitly name the owning MP-R1 ticket and retained
shared protocol or existing caller edges. They are not unreported checker
failures.

Nevertheless, criterion 3's literal historical non-increase claim
is **not established**.

[DF-015](../../../../build-order/deferred-findings.md#df-015--mp-r1-historical-ratchet-criterion-needs-reconciliation)
records the P2 policy/documentation discrepancy; this report does not silently
mark it passed.

No P0/P1 runtime blocker was reproduced in the scoped checks.
The npm moderate advisory is a dependency-install observation, not an audited
exploit finding or a claim that all dependencies are secure.
