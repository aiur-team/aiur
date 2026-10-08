# U0 review at d7db05bee

Implementation SHA: `d7db05bee6ef712100340c2fd1b3c57d82d79621`, fetched from `origin/main` on 2026-10-08. PR integration base: `main`. This pin remains fixed if main moves.

Gate status: **pending Executor sign-off**. This record does not yet authorize downstream code work. U0-T02 is complete; U0-T03 remains its separate size gate.

## Release and source identity

Latest published GitHub release observed: [v0.0.8](https://github.com/aiur-team/aiur/releases/tag/v0.0.8), published 2026-09-30T21:07:40Z, tag commit `ed43c0e9442c46b9c2000ca23bddf40c13d2efb4`.
At the implementation pin, `packaging/npm/aiur-cli/package.json` names `aiur-cli` version `0.0.9` and optional packages `aiur-cli-linux-x64`, `aiur-cli-linux-arm64`, `aiur-cli-darwin-arm64` version `0.0.9`. This is implementation metadata, not a claim that those npm versions were published.

The original corpus and disposition inputs are absent from implementation main. Read them at immutable research commit [`6732f5f9f448b1857a9643993849635f85321e19`](https://github.com/aiur-team/aiur/tree/6732f5f9f448b1857a9643993849635f85321e19/docs/research/refactor-2026-09-26).
Corpus: `review/findings.json`, SHA-256 `d41c9ad45408edd1a61c3b3042fac292b049770353569e661e1329e857898b8b`.
Inherited decisions use `high-priority-disposition-fc8270bb.json`, all three `p2p3-triage-part-*.json` partitions, `p2p3-part-1-reconciliation.json`, and the nine-ID `p2p3-triage-reconciliation-overlay.md`. No raw claim descriptions or private-source prose are republished.

## Finding review

[Disposition overlay](u0-review-d7db05bee-dispositions.json) contains **986 canonical rows and 1,033 source IDs**, with the original source-ID-to-canonical mapping preserved exactly and zero orphans.

- Rechecked all 97 P0/P1 findings and 527 P2/P3 findings with a cited path changed in `git diff --stat 465aca643527ea94a4d0d6d7c178c5d23d2aaf57 d7db05bee6ef712100340c2fd1b3c57d82d79621`. The join uses the equivalent `--name-only` path set and every `source_claims[].claim.locations[].path`.
- Of 362 remaining P2/P3 findings, 360 retain their inherited disposition with `status: unchanged` and the note `path unchanged`. Two citations already absent at both comparison pins are `stale`: `web-rest-23` and `github-a-34`; their anchors point to the owner ledger's deletion evidence. Neither is a new repair.
- Status totals: changed 68, present 541, repaired 15, stale 2, unchanged 360.
- `present` means the cited source mechanism remains; `changed` records narrowed, moved, or partly repaired evidence; `repaired` identifies a merged repair; `stale` retires a citation. No status asserts observed runtime incidence, old census totals, latency, or savings. All P0/P1 use `present | repaired | changed | stale`.
- `provisional_action` and `inherited_verdict` preserve the effective historical decisions, including unknown/unsupported verdicts. They are provenance, not an instruction to reimplement a repaired row. Historical high actions remain 84 fix / 12 defer / 1 keep; lower actions remain 244 fix / 645 defer.

All 986 anchors were opened from the pinned tree and checked for a valid line. Semantic reviewers inspected the mechanisms for the 624 rechecked rows. Seeded spot selection (`random.Random(3255).sample(high_rows, 3)`) was independently opened: `agent-runtime-02` at `src/lib/aiur/agent_runner/queue_drain.ex:604` retains the fallible hard match; `agent-backends-oc-11` at `src/lib/aiur/opencode/active_turns.ex:171` retains lazy ETS ownership; `nonelixir-shell-01` at `packaging/npm/aiur-cli/libexec/aiur-engine.sh:3683` selects the current instance pidfile after the repair.

## Repairs and downstream scope

The following rows must not trigger duplicate implementation. Named U tickets retain only their remaining witness/guard scope. A repair absent from all U1..U7 `prior_findings` has no dedicated U ticket to close; it remains a corpus credit, with its existing guard preserved.

| Finding | Pinned evidence | Repair and remaining scope |
| --- | --- | --- |
| `agent-backends-oc-01` | `src/lib/aiur/opencode/chat_completions.ex:57` | Bearer authorization now precedes InputIdentity unwrap and every identified marker/operator branch; repair 57114d675 (#2827), U1-T01 retains its missing automated witness scope. Provisional action: fix. Static review only; live incidence unmeasured. |
| `agent-backends-oc-02` | `src/lib/aiur/open_ai_compat/command_runner.ex:10` | Inherited environment permits only LANG, LC_ALL and TERM; clearenv no longer reintroduces GitHub credentials; repair a03376137 (#2845), U1-T01 retains its missing automated witness scope. Provisional action: fix. Static review only; live incidence unmeasured. |
| `agent-runtime-36` | `src/test/aiur/tmux_test.exs:53` | Tmux task/mock handshake receives now carry explicit 1000 ms waits. Repaired by aac8a4532024b48e1cbb03073454cfa0832cb6a2 (#2937/#2796); no dedicated U1..U7 finding-owner ticket; retain the existing regression guard and do not reapply this repair. Provisional disposition retained. |
| `github-a-22` | `src/test/aiur_web/operator_control_center/route_registry_test.exs:9` | Removed in 694f9d021 (#2841) with the GitHub cache page; pinned-tree search finds no CacheInspector implementation. U7-T01 closes the already-cut integrations-20/ui-13 scope; this finding needs no extraction. Provisional action retained; static code review only. |
| `loose-3-06` | `src/lib/aiur/test_reset.ex:621` | 90bef167a delegates cleanup path to Layout.issue_workspace_path and expands workspace root, repairing re-derived local layout. U-unit owner: none dedicated; separate remote-fanout wording concern is not covered by this repair. Provisional action: fix. Static review only; live incidence unmeasured. |
| `nonelixir-shell-01` | `packaging/npm/aiur-cli/libexec/aiur-engine.sh:3683` | 12055bff2 (#2846) selects only current instance-record agent pidfile instead of sweeping every instance. U1-T02 is guard/live-witness only; independent recycled-PID hardening remains #2844. Provisional action: fix. Static review only; live incidence unmeasured. |
| `nonelixir-shell-03` | `packaging/npm/aiur-cli/share/aiur.tmux.conf:75` | a4e5f70ac (#2858) ships inline quoted C-c/C-q helper, packages it, sets launcher option and tests shipped conf; duplicate config removed. U1-T03 narrows to queued-message foreground witness, no binding implementation. Provisional action: fix. Static review only; live incidence unmeasured. |
| `nonelixir-shell-29` | `.claude/skills/aiur-agent/dev-loop.md:306` | Removed in d04069711 (#2840); pinned tree contains no guard-pr-deletions implementation. U7-T01 closes the already-cut cli-38 entry, so no guard repair/install belongs in that unit. Provisional action retained; static code review only. |
| `skills-prompts-cont-01` | `.claude/skills/aiur-agent/dev-loop.md:169` | Both local-gate and manual-verification passages now require mix lint/Credo; prohibition removed by 4d26fbe1c (#3248). No dedicated U1..U7 ticket cites this finding to shrink; any later policy cleanup should retain a guard. Provisional action: defer. Static review only; live incidence unmeasured. |
| `tests-1c-08` | `src/test/aiur/orchestrator_status_test.exs:3146` | All listed asynchronous receives now have explicit timeouts, including multiline operator messages. Repaired by aac8a4532024b48e1cbb03073454cfa0832cb6a2 (#2937/#2796); no dedicated U1..U7 finding-owner ticket; retain the existing regression guard and do not reapply this repair. Provisional disposition retained. |
| `tests-2-09` | `src/test/aiur_web/financial_data/change_bridge_test.exs:18` | All cited asynchronous receive families now use explicit 1000 ms waits, including task release and activation. Repaired by aac8a4532024b48e1cbb03073454cfa0832cb6a2 (#2937/#2796); no dedicated U1..U7 finding-owner ticket; retain the existing regression guard and do not reapply this repair. Provisional disposition retained. |
| `tests-3-04` | `src/test/aiur/eleven_labs/realtime_test.exs:101` | Cited runner/readiness/TTS/realtime/ownership receive families now use explicit timeouts. Repaired by aac8a4532024b48e1cbb03073454cfa0832cb6a2 (#2937/#2796); no dedicated U1..U7 finding-owner ticket; retain the existing regression guard and do not reapply this repair. Provisional disposition retained. |
| `tests-5-05` | `src/test/aiur/agent_runner/queue_drain_test.exs:185` | Queue/task/tmux receives now carry explicit timeouts. Repaired by aac8a4532024b48e1cbb03073454cfa0832cb6a2 (#2937/#2796); no dedicated U1..U7 finding-owner ticket; retain the existing regression guard and do not reapply this repair. Provisional disposition retained. |
| `tests-6-10` | `src/test/aiur/build_order/pack_status_test.exs:111` | Channel/aggregate and other cited receive families now carry explicit timeouts. Repaired by aac8a4532024b48e1cbb03073454cfa0832cb6a2 (#2937/#2796); no dedicated U1..U7 finding-owner ticket; retain the existing regression guard and do not reapply this repair. Provisional disposition retained. |
| `web-occ-12` | `src/lib/aiur_web/operator_control_center/analytics/charts.ex:617` | text/4 and title/1 now HTML-escape all bodies via escape_text. Repaired by 7c9af3316 (#2905); no dedicated U1..U7 finding-owner ticket; retain the existing regression guard and do not reapply this repair. Provisional disposition retained. |

Moved or partial repairs remain `changed`, with their new anchors and limitations in the overlay. In particular, `agent-runtime-01` still needs U4-T01's between-turn seam; logging repair does not claim exception containment; historical test timing counts were not remeasured.

## Owner-ledger gate

U0-T02 ([#3254](https://github.com/aiur-team/aiur/issues/3254), merged [#3311](https://github.com/aiur-team/aiur/pull/3311)) published the [378-path ledger](u0-owner-ledger-7fe2fca3f.csv) and [review record](u0-owner-ledger-7fe2fca3f.md). Read every row and confirmed nonempty package ownership and next action.

Independent census at this review pin: 3,931 regular tracked paths, 3,558 UTF-8 text and 373 binary; symlinks excluded. Text classification rejects NUL and invalid UTF-8; physical lines count LF bytes plus a nonempty unterminated final line. All 378 paths exceeding 500 lines match the ledger, with no new or retired oversized path; 18 line counts changed since its pin. The existing 37-package assignments and next actions still cover every oversized path. No new owner rows or U0-T03 size authorization are created here. These new evidence files are outside the pinned census and must be counted as ordinary text at the next pin.

## Privacy and validation

Contextual privacy review covered every new file in this PR and U0-T02's public ledger/review evidence. New notes were checked against public pinned code, public commits and public U-ticket contracts; they contain source IDs, public repository paths and short mechanism summaries, with no private ticket text, private run identifiers, host paths, credentials or raw journals. A lexical credential/host scan supplements that contextual pass. No new redaction was needed. The original privacy audit remains limited to its historical branch tip; future U-unit evidence must receive the same contextual review before publication and is not preapproved here.

Reproduction of the mapping/count gate (run from repository root; Python calls Git with explicit repository context):

```python
import json, subprocess
from pathlib import Path
workspace = str(Path.cwd())
corpus = json.loads(subprocess.check_output([
    'git', '-C', workspace, 'show',
    '6732f5f9f448b1857a9643993849635f85321e19:docs/research/refactor-2026-09-26/review/findings.json'
]))
overlay = json.loads(Path('docs/research/refactor-2026-09-26/synthesis/u0-review-d7db05bee-dispositions.json').read_text())
rows = overlay['findings']
assert len(rows) == 986
assert len({row['id'] for row in rows}) == 986
assert {row['id'] for row in rows} == {row['id'] for row in corpus['findings']}
pairs = [(sid, row['id']) for row in rows for sid in row['source_ids']]
assert len(pairs) == len(dict(pairs)) == 1033
assert dict(pairs) == corpus['source_id_to_finding']
```

The executed scratch validator also resolved every anchor at the pin and rejected missing-row, duplicate-source-ID and swapped-mapping negative controls. Documentation/data checks passed; no product code or tests changed. `python3 scripts/check-bare-assert-receive.py` passed across 928 test files. `mise exec -- mix lint` passed the specs check but failed the existing `persist_page` complexity violation at `src/lib/aiur/build_order/history/backfill.ex:247`, tracked in [#3430](https://github.com/aiur-team/aiur/issues/3430). This is an inherited lint failure, not a test flake or a dependency of this review. Full CI remains required before human-review handoff. No runtime/TUI behavior was exercised by this research-only ticket.

## Sign-off

Pending Executor review of this record and overlay. The completion line will be recorded only after the Executor signs off at the implementation SHA.
