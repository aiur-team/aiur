# Merged-main P0/P1 source delta at `ce0d2c450`

Read-only source audit of `465aca643` (published `v0.0.7`) through merged
`ce0d2c450`. The comparison uses the frozen raw findings and their cited paths;
a changed path is a recheck trigger, not proof that its finding was resolved.
No daemon, GitHub operation, mutation test, or behavior test was run for this
addendum.

## Frozen high-priority findings

No P0 finding cites a production path changed in this interval. The three
previous P0 source repairs remain subject to their separate behavior limits:
`agent-backends-oc-01` authenticates before marker dispatch at
`src/lib/aiur/opencode/chat_completions.ex:56-64`, `agent-backends-oc-02`
inherits only `LANG LC_ALL TERM` in
`src/lib/aiur/open_ai_compat/command_runner.ex:10,80-99`, and
`nonelixir-shell-01` selects the stopping instance's recorded pidfile at
`packaging/npm/aiur-cli/libexec/aiur-engine.sh:3511-13,3572-78`.
Their release-head tests are `src/test/aiur/opencode/bridge_test.exs:17-70`,
`src/test/aiur/open_ai_compat/command_runner_budget_test.exs:52-82`, and
`src/test/aiur_engine_stop_pidfile_test.exs:6-104`. The remaining narrow
checks are an unauthenticated coalesced text-plus-turn request with no agent
send, a real bubblewrap `env` with synthetic daemon credentials, and a real
two-live-instance stop. Recycled PID identity is separate issue #2844.

Twelve P1 findings cite paths changed by this merge:
`build-order-03/04/05/07/08/09/10/11`, `github-b-01/02`, `web-occ-01`, and
`web-rest-05`.

| Finding | Current source disposition at `ce0d2c450` | Narrow follow-up |
| --- | --- | --- |
| `build-order-04` | Original clear-then-first-100 truncation is **statically repaired**. `reconciliation.ex:65-90` refuses an incomplete nested connection, and `resource_store.ex:1111-52` replaces a complete membership set under a snapshot fence. | `reconciliation_test.exs:102-31` holds a tail edge after a 101-member response; `reconciliation_interleaving_test.exs:32-92` covers concurrent edge change and complete-set publication. Run those exact tests and their production-hunk mutation before marking behavior verified. |
| `build-order-03` | **Partial repair.** `graph_projection.ex:287-302` adds a timer independent of webhook mode; `graph_projection_membership_recovery_test.exs:54-68` exercises a failed-result retry. Completion still ignores `result` and stamps `last_reconciliation_ms` (`graph_projection.ex:335-47`); the `:DOWN` path still clears the marker without logging or health (`:358-66`). | Force a crashed reconciliation with an unproven webhook mode and assert retry, visible failure cause, and no false success observation. |
| `github-b-02` | **Partial repair for `:sub_issue` only.** `resource_store.ex:1111-52` and `membership_access.ex:9-21` fence and serialize membership replacement. Other order-sensitive writers described by the frozen finding are untouched. | Keep the membership interleaving test; separately race `Issues.put_issue_resource` fetch-then-put and read/write-through against a newer webhook version. |
| `build-order-05/07/08/09/10/11` | **Still source-live.** `catalog_store.ex:125-43` still caps metrics at 100; `graph_projection_policy.ex:185` still omits emitted `:permission`; `graph_projection_options.ex:114` still selects a store catalog reader while the labelled-read cadence remains (`graph_projection.ex:1439-64`). Projection grew to 1,842 lines. The due retry can still arm a zero-delay timer (`:1266-77`) while max-inflight defers without cancelling it (`:812-13`); subscription failures are still swallowed (`:1531-47`). | Preserve each as a separate behavior or carve gate; test the 101st member metric, emitted permission classification, unchanged-data labelled cadence, saturated retry timer, and failed subscription recovery. |
| `github-b-01` | **Still source-live.** `resource_store.ex` grew from 2,191 to 2,261 lines. `membership_access.ex` narrows one transaction seam but the shared mutable store still owns the frozen finding's broader responsibilities. | Keep GitHub access as one owner until cache authority and cross-package callers are mapped. |
| `web-occ-01`, `web-rest-05` | **Still source-live.** `build_orders_cli.ex:17-19,79-86` still imports `AiurWeb` data source, presenter, and grid model. The stale-read fix changes refresh timing, not the dependency direction. | Preserve the CLI/web boundary contract in the package plan. |

## File-size and owner-map delta

The release census had 357 tracked text files above 500 physical lines.
Inspection of every changed code/doc path at `ce0d2c450` found no new crossing
and no deletion of an oversized path, so the count remains **357**. Four
already oversized files grew *before* a file-size gate was installed:

| Existing owner | Path | Release → merged main |
| --- | --- | ---: |
| GitHub access | `src/lib/aiur/github/resource_store.ex` | 2,191 → 2,261 |
| Build Order | `src/lib/aiur/build_order/graph_projection.ex` | 1,825 → 1,842 |
| Event delivery | `src/lib/aiur/events/github_webhook/deposit.ex` | 991 → 996 |
| Operator documentation | `website/docs-app/apis/github.md` | 742 → 759 |

New `membership_access.ex` (25 lines), reconciliation timer (22 lines), and
four new tests (all under 500 lines) do not create owner-map rows. Freeze
per-file ceilings from the *gate installation HEAD*, not the older release
census; otherwise these four pre-gate increases would be mistaken for gate
regressions. The existing owner assignments remain GitHub access, Build Order,
Event delivery, and Operator documentation respectively. The timer belongs to
the Build Order package; membership serialization belongs to GitHub access.

## Limits

This is static source evidence, not a claim of production incidence or live
correctness. The prior catalog at 95 members and the later two Khala sub-issues
motivated the membership repair, but this audit did not poll Khala or inspect a
running projection. The merged GitHub API page documents the 15-minute safety
reconciliation at `website/docs-app/apis/github.md:49-63`; its later catalog
summary at line 295 still describes only boot/degradation listing and should be
reconciled with that new behavior in a documentation follow-up.
