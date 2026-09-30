# Current-main refactor review at `b4bc11f`

This read-only checkpoint compares the frozen `3339b887` findings with `b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f` (`origin/main` on 2026-09-29). The two heads differ in 318 tracked paths. Two independent reviewers classified all 94 frozen P1 findings; their per-ID judgments are in `merged-main-b4bc-p1-dispositions.csv`. These are static judgments about code paths, not observed incident rates or proof of P1 impact. Two further reviewers reconciled the 12 differing labels into [mechanisms and behavior gates](merged-main-b4bc-p1-reconciliation.md); their static agreement still does not establish P1 severity.

| Review | Fixed | Narrowed | Impact unproven | Shared remediation | Source reachable |
| --- | ---: | ---: | ---: | ---: | ---: |
| A | 1 | 6 | 10 | 0 | 77 |
| B | 1 | 7 | 15 | 1 | 70 |

Both reviewers found the three frozen P0 mechanisms already repaired on this main: `agent-backends-oc-01` authorizes before marker dispatch in `src/lib/aiur/opencode/chat_completions.ex`; `agent-backends-oc-02` no longer inherits GitHub token names in `src/lib/aiur/open_ai_compat/command_runner.ex`; `nonelixir-shell-01` scopes stop/reap to the instance pidfile in `packaging/npm/aiur-cli/libexec/aiur-engine.sh`. Preserve their historical records but do not create new P0 repair work without a failing current-head test. Both reviewers also found P1 `nonelixir-shell-03` fixed: the shipped tmux config contains the Ctrl+C helper and Ctrl+Q, the launcher wires the helper, and the verification script targets that shipped config.

The most concrete residual P1 is a **narrower** `agent-runtime-01`: queued-turn pause now confirms containment (`queue_drain.ex:716-718`), while the between-turn `:pause_agent` receives at lines 40-57 and 130-146 still omit confirmation after `pause_resume.ex:1810-1835` arms containment and sends that tuple. Test that arm-to-receive path before changing it. `agent-runtime-02` likewise retains hard-matched queue RPCs but its restore-and-replace seam already has a bounded confirmation. `platform-misc-03` now releases a verified local provider hold after reboot; investigate only the remote or same-boot residual. Recount umbrella rescue findings `web-occ-06` and `web-rest-08` on retained surfaces; `github_cache_live.ex` was deleted. Keep `agent-backends-cc-04` as individual backend safety differences rather than a mandate to unify whole runtimes.

For focused implementation candidates, `github-a-04` remains source reachable: `Comments.fetch_classified_issue_comments/2` reads one `per_page=100` page through `Transport.fetch_json_list/4`, while the same module already has a complete issue-comment reader. A two-page test should fail on current code and require complete or explicitly held results, without a partial trusted context; the [focused contract](merged-main-b4bc-first-candidates.md) also covers workpad cutoff, ETag and cost attribution. `platform-misc-01` remains source reachable: `max_consecutive_noop_turns` is documented and declared in the agent schema but absent from its cast list; no shipped example sets it, so this is an opt-in config bug rather than observed default-run failure. `web-rest-03` has the same partial window parser in Stream Deck projection and run summary; one tolerant parser is smaller than two surface rewrites. `web-rest-01` retains Stream Deck control writes without the dashboard writable check. These are candidate contracts, not approved implementations or release saving claims.

The current tracked-text census is in `u0-main-size-census-2026-09-29.md`: 357 files exceed 500 lines, with two new test owner rows. A small first simplification to investigate is `src/lib/aiur/codex/event_humanizer.ex` (510 lines): it contains 60 mirrored atom-key path variants, while `Aiur.EventHumanizerHelpers.map_path/2` already tries alternate key forms at every segment. Preserve whole-path fallback for nil/false collisions, as the [focused contract](merged-main-b4bc-first-candidates.md) explains; record net lines removed and abandon the change if it merely relocates code. Extracting `build_order/pack_status.ex` solely to move roughly 75 lines into a new module is not a preferred first batch.

The conditional [`ui-29` dashboard component cut](ui29-current-main-2026-09-30.md) was also checked independently on this snapshot. Seven unrendered modules total 771 gross lines, with test and compile-time companion edits required; this is no net saving claim.

The [usage-compaction cut](usage-compaction-current-main-2026-09-30.md) is dormant in the local instance sample but can still activate above 5,000 ledger positions. Existing retired segments require floor recovery, so the six-file 1,297-line footprint remains conditional on durable-state census and migration proof.

The [CODEOWNERS trust audit](codeowners-current-main-2026-09-30.md) narrows KTD9 to current failure paths: a team lookup error can look healthy, a second path resolver caches membership indefinitely, and one-page path reads can claim incomplete ownership. Event sanitization and digest filtering already exist; Executor rendering and age still need behavior proof.

The [Decision journal audit](decision-journal-current-main-2026-09-30.md) narrows KTD10 to ambiguous post-write sync errors, repair after a confirmed append, and request notifications that still publish across a failed projection rebuild. The existing corrupt-record and torn-tail tests cover different cases.

The [GitHub access seam audit](github-access-seam-current-main-2026-09-30.md) checks KTD11 against startup and caller contracts. One-page list readers, unacknowledged store deposits, checkpoint windows and mutation ambiguity need failure-path proof before consolidating callers.

The [oversized-file assignment review](owner-map-assignment-review-b4bc-2026-09-30.md) identifies owner and evidence corrections for the U0 refresh. The frozen CSV and b4bc delta remain separate; hash-pinned prototypes, release assets, canonical receipts, generated lockfiles and shared harnesses cannot be dispatched as generic splits or cuts.

The [reconciled P2/P3 check](p2p3-reconciled-b4bc-2026-09-30.md) confirms source reachability for the nine changed effective decisions and preserves their behavior gates. It does not establish incidence or update the other 880 dispositions.

The [P2/P3 cited-path exposure](p2p3-b4bc-path-impact.md) maps 356 of 889 findings to a changed cited file on b4bc, including 79 provisional fixes and 27 findings with a deleted citation. It is a re-trace queue, not a behavior or severity result.

The [eight deleted-citation fix trace](p2p3-deleted-fix-trace-b4bc.md) distinguishes three page-specific removals from five surviving findings. In particular, analytics SVG escaping remains a separate repair candidate after the cache page deletion.

The [analytics SVG path audit](analytics-svg-label-b4bc.md) traces provider model text into raw rendered SVG and defines a DOM-level regression. Browser execution and real-world incidence remain unproved.

The [Opencode slot seed trace](opencode-slot-seed-b4bc.md) checks provisional P2 `agent-backends-oc-18`: the slot still polls Orchestrator inside startup, but `AttachPool.seed/3` has no guaranteed handoff before that callback. Its nominal three-second sleep budget can include up to 31 separate 500 ms RPC waits. Replacing the poll with the pool's current list needs an ordering and first-open test; the duration is a source bound, not a measured stall.

The [Codex event path mirror audit](../../../refactor/humanizer-mirror-audit-b4bc.md) narrows the proposed first size reduction: `map_path/2` already handles atom and string forms at each segment, but present `nil` or `false` values in dual-key maps can make a whole-path mirror observable. Deletion needs an explicit collision contract and regression matrix; no unconditional line saving is claimed.

The [between-turn pause trace](agent-runtime-01-between-turn-pause-b4bc.md) narrows residual P1 `agent-runtime-01` to two worker receive branches that acknowledge pause without confirming an armed containment handle. Its regression contract also covers the send-before-arm race and successor generation. The [window parser trace](web-rest-03-window-parser-contract-b4bc.md) shows writer-reachable reset-only and zero-limit buckets that make both Stream Deck and dashboard projections raise; it confines shared parsing to the percentage calculation because timestamp display policies differ.

The [Stream Deck owner-map slice](owner-map-streamdeck-slice-b4bc-2026-09-30.md) supplies joint sidecar/server, hardware and browser-emulator validation gates for eight oversized paths before assigning generic split tickets. These are source contracts, not runtime acceptance or measured simplification.

Before promotion, refresh this checkpoint on the actual release main, run the named behavior gates, count live populations where a finding claims magnitude, and record the exact failing behavior test for each selected repair. The frozen two-review result remains valid for its snapshot; it does not automatically certify the changed main.
