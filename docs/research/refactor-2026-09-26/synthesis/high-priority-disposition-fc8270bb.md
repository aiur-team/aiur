# Canonical P0/P1 action disposition at released main

The [97-row ledger](high-priority-disposition-fc8270bb.json) is pinned to `fc8270bb6d30cf44a860b142b365ad10e5c906a1`. It joins all 3 P0 and 94 P1 canonical IDs in `review/findings.json` to both independent skeptic verdicts, the exact release-head citation check, a proposed action, a component owner, and a remaining evidence gate. The two skeptic reviews each covered 182 raw high-priority entries; six lower-priority aliases were merged into these 97 canonical IDs and were not separately reviewed as high-priority entries. Every canonical ID itself has both reviews.

| Action | Rows | Meaning |
| --- | ---: | --- |
| `fix` | 84 | Four exact mechanisms are statically addressed in release PRs; 80 are proposed future fixes subject to their row's behavior gate. |
| `defer` | 12 | Architecture, cost, root-discovery, or broad rescue changes await the stated measurement or owner decision. |
| `keep` | 1 | The 16 KiB ticket-detail rejection is an explicit fail-closed contract; an incomplete-preview UX needs a separate decision. |
| `invalid` | 0 | Neither independent skeptic rejected a canonical high-priority claim. A stale citation alone never makes the finding invalid. |

The four release-addressed rows are `agent-backends-oc-01` (#2827), `agent-backends-oc-02` (#2845), `nonelixir-shell-01` (#2846), and `nonelixir-shell-03` (#2858). Their action remains `fix` with `implementation_state=addressed_in_release`; this records the change without claiming a live incident count or that all adjacent behavior was proven. `web-rest-08` is deferred because removing the GitHub-cache page removes one cited file while broad surviving rescue paths require individual review. The released-main citation scan reports 69 byte-identical, 26 changed/unresolved, and two stale high-priority citations; it is a locator, not a behavioral verdict. All three P0 citations are changed/unresolved because their implementations moved.

Six P1 canonical severities differ from skeptic B's P0 recommendation: `agent-runtime-01`, `build-order-01`, `events-webhooks-executor-01`, `loose-4-01`, `loose-4-02`, and `orch-b-02`. The ledger retains both severity values. They require incident-boundary and failure-path checks before priority is raised or lowered; the canonical P1 label has not been silently overwritten.

## Remaining research gates

1. **Release fixes:** Re-run the merged-main focused regressions and red/green mutation proof for the four addressed rows. Installed TUI/CLI acceptance, where applicable, is a separate check. Count the reachable population before asserting a saving or incident-rate reduction.
2. **80 proposed fixes:** Reproduce each named behavior on its implementation head, choose the correct owner contract, and add a regression test that fails without the production change. The ledger gives a row-specific gate for the most consequential paths; its generic gate means no stronger source-specific acceptance contract has yet been approved.
3. **12 deferred rows:** Measure the named cost or replay population, or settle the named ownership/UX decision, before opening a refactor ticket. Source review does not establish the benefit or authorize removal.
4. **One preserved contract:** Confirm the Build Order owner's fail-closed policy and improve the oversize error if needed. Do not interpret the frozen truncation suggestion as an approved fix.
5. **Citation and severity review:** Re-anchor 26 changed/unresolved cited paths, review the two stale rows against surviving behavior, and resolve the six severity disagreements with runtime impact evidence. This does not require repeating the completed P2/P3 triage or 359-row owner map.

Reproduce the exact source status and disposition from a checkout containing the pinned commits:

```bash
python3 docs/research/refactor-2026-09-26/tooling/current_head_static_triage.py \
  --findings docs/research/refactor-2026-09-26/review/findings.json \
  --base 3339b887196d5e9aefb273117a14bf33391ee41f \
  --head fc8270bb6d30cf44a860b142b365ad10e5c906a1 \
  --output /tmp/refactor-fc-triage.json
python3 docs/research/refactor-2026-09-26/tooling/high_priority_disposition.py \
  --triage /tmp/refactor-fc-triage.json \
  --output /tmp/refactor-high-priority-disposition.json
```

The generator asserts 97 unique canonical IDs, both skeptic reviews for each, the exact release SHA, and 103 unique source IDs represented by these canonical rows. The four action totals sum to 97. No row asserts measured production incidence.
