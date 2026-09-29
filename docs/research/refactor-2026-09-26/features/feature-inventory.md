# Reconciled feature inventory

This inventory describes the complete frozen `3339b887` snapshot through five
product surfaces: CLI, configuration, integrations, subsystems and UI. The
[usage matrix](usage-matrix.md) indexes all 216 entries; [features.json](features.json)
retains each source ID, source file, module/entry-point list, use evidence, raw
LOC estimate, original rationale, exact skeptical verdict and its note. A
working decision is a planning classification, not an authorized deletion.

| Surface | Entries |
| --- | ---: |
| CLI | 46 |
| Configuration | 39 |
| Integrations | 52 |
| Subsystems | 46 |
| UI | 33 |
| **Total** | **216** |

The observed-use labels are heavy 61, regular 48, occasional 34, rare 24,
none-found 47 and unknown 2. The evidence samples configurations, transcripts,
logs, callers and source; it is not a complete telemetry history or a census
of all operators. `none-found` cannot by itself justify removal.

## Skeptical decisions

All 53 raw cuts, 22 raw merges and 16 raw externalizations received a skeptical
review. Thirty-five original proposals held and 56 were overturned or narrowed.
After interpreting qualified verdicts without discarding their exact wording,
the working mix is 67 keep, 110 simplify, 10 merge, 24 cut and 5 externalize.
The 125 original keep/simplify entries were not independently challenged; their
working status remains provisional. Some overturned proposals still have a
narrower cut or merge, so these counts are classifications rather than a count
of untouched versus deleted product capabilities.

The 24 working cuts are:

| Boundary | IDs | Required condition before removal |
| --- | --- | --- |
| Linear | config-10, integrations-03 | Count dynamically exposed `linear_graphql` tool use as well as tracker configuration; preserve tracker migration and skill contracts. |
| Config-only | config-14, config-23, config-27, config-28, config-35 | Remove named knobs, not safety floors or live debounce/diagnostic behavior; update schema, examples, documentation and tests together. |
| RTK | config-24, integrations-52, subsystems-41 | One shared integration, counted once; communicate the explicit prior user request before product deletion. |
| PR watch | config-32, integrations-31 | One shared feature; check final configs and compatibility, keep ordinary PR review and command delivery. |
| Claude transport/OTLP | integrations-09, integrations-16 | `integrations-09` is a narrowed transport cut, not removal of all Remote Control; preserve coverage requirements before dropping OTLP intake. |
| Auxiliary runtime | subsystems-07, subsystems-14, subsystems-20, subsystems-26 | Retention, diagnostics and failure evidence need explicit replacement or product decisions; unused readers alone are insufficient. |
| UI/demo/report | ui-12, ui-19, ui-26, ui-29, ui-30, ui-33 | Keep deterministic render fixtures and offline export if required; recheck dynamic browser hook reachability; ui-33 is a documentation correction with zero code LOC. |

Working merges: cli-08, cli-10, cli-14, cli-46, integrations-30,
integrations-49, subsystems-03, subsystems-05, subsystems-06 and
subsystems-29. `integrations-49` is limited to overlapping commit/push wording
after command parity; `subsystems-03` and `subsystems-29` are narrowed from
raw cuts. Merge means consolidate ownership and duplicated paths, not erase
behavior. Working externalizations: cli-36, cli-44, integrations-40,
integrations-46 and subsystems-42. They move developer or planning concerns
across a package/release boundary, so relocated lines are not LOC saved.

## Later release direction

The user separately requested removal of the local PR deletion guard
(`cli-38`, PR #2840) and GitHub cache dashboard (`integrations-20`/`ui-13`,
PR #2841) in 0.0.6. These are **pending release removals** until the PRs are
merged and the published release is verified. The frozen skeptical decision
for the cache inspector remains `keep` as historical research evidence; the
later user direction is recorded separately as a release override in
`features.json`. Do not re-plan either capability as retained after those
removals land, and do not count either PR's removed lines as future refactor
savings. See the independent [current-head validation](../synthesis/current-head-validation-2026-09-28.md).

## Coverage boundary and omissions

The source snapshot has 3,378 tracked paths, while these 216 records are a
feature-oriented inventory. The raw module strings often name shared modules,
sub-file branches, globs or prose; they are not a one-to-one file attribution.
The five surfaces include packaging, scripts, skills, examples and the Stream
Deck sidecar where named by a feature, but do not claim every tracked test,
documentation page, website component, generated/vendor asset or developer
script is itself a separate product feature. The complete file-size census and
32 code-review units cover these other files for structural and defect
analysis. Final planning must assign every >500-line tracked text file to an
owner even when it has no feature row. Do not infer that an unlisted path is
dead code or that a named feature owns every line in its listed modules.

| Outside the five-row feature taxonomy | Treatment in the rewrite |
| --- | --- |
| `.github/` CI workflows and repository policy | Delivery/quality infrastructure; carry their gates into the implementation plan rather than calling them unused product features. |
| `website/` documentation app and most `docs/` pages | Operator-facing documentation and publication system; audit for behavior changes and the hard file-size rule. `config-37` names the docs checker, but does not inventory every page. |
| `.claude/` and `.codex/` skill copies beyond individually named integrations | Agent instructions and distribution assets; preserve contracts and deduplicate with skill-specific review, not automatic file deletion. |
| Tests, fixtures, examples, generated and vendored assets | Evidence, portable setup or shipped runtime assets; all tracked text remains subject to the 500-line gate. |
| `Dockerfile`, root `Makefile`, package metadata and development setup | Build/distribution support, partially described by CLI/config rows; audit as an implementation boundary rather than infer no use from missing feature IDs. |

The frozen inventory predates later Muse and release changes. Revalidate
candidate callsites, operator use, config compatibility and the file-size
census on the implementation base before removing code. The
[cross-report contradiction audit](../synthesis/report-wide-contradictions.md)
records ownership conflicts that the rewrite must settle before merging or
splitting adjacent features.
