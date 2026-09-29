# U0 action review: 21 unresolved oversized owner-map rows

Checked the 21 `action_status: unresolved` rows in `oversized-owner-audit-part-2.json` against clean pre-merge Aiur candidate `0299daca28383a336682374e19e90d6434aa4e1a`. This is a proposed action decision, not a product edit, current-main recount, or permission to discard history. **Twelve rows now have a concrete safe action route** (eleven historical documents and the plan preview); **nine retain source/consumer gates** (eight CE skill files and one Build Order fixture). Every row still needs its implementation and validation on actual merged main.

## Eleven historical planning documents: preserve paths and original text

All eleven are historical plans or requirements. Their present paths are document entrypoints, and five have at least one literal in-repository inbound reference. An `rg -l -F <path>` search found no literal inbound reference for the other six, but cannot rule out external links or generated references. Git preserves the exact original at a commit even when the working-tree file changes. **Proposed action for each row:** at the implementation-base SHA, retain the original file path as a short historical index under 500 lines; link to its full immutable GitHub blob and map each existing heading fragment to the corresponding old-blob fragment. Keep date, title, outcome/provenance and known inbound links. Check all local links, heading anchors and an offline checkout before replacing the body. Do not silently delete or minify the record. This action settles the archival-versus-splitting policy; the link/anchor migration is its acceptance gate.

| Row | Historical entrypoint | V3 lines | Literal inbound paths | Largest H2 section |
| ---: | --- | ---: | ---: | ---: |
| 123 | `docs/plans/2026-06-12-002-fix-chat-control-lifecycle-ux-plan.md` | 998 | 0 | 680 |
| 133 | `src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md` | 964 | 0 | 544 |
| 143 | `src/docs/plans/2026-05-20-001-feat-opencode-prewarm-and-history-injection-plan.md` | 920 | 0 | 627 |
| 157 | `docs/plans/2026-07-12-004-feat-supervisor-decision-api-plan.md` | 859 | 0 | 428 |
| 162 | `docs/plans/2026-07-12-001-feat-decision-domain-persistence-plan.md` | 842 | 1 | 427 |
| 169 | `docs/plans/2026-07-06-001-refactor-production-readiness-planning-spike-plan.md` | 828 | 3 | 370 |
| 179 | `docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md` | 810 | 7 | 98 |
| 180 | `docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md` | 809 | 2 | 442 |
| 213 | `docs/plans/2026-06-15-002-feat-init-wizard-rework-plan.md` | 729 | 2 | 455 |
| 224 | `src/docs/plans/2026-05-31-002-feat-aiur-init-onboarding-plan.md` | 692 | 0 | 374 |
| 230 | `docs/plans/2026-05-24-003-feat-dashboard-events-panel-and-security-plan.md` | 676 | 0 | 384 |

Three H2 sections already exceed 500 lines, so a one-file-per-H2 split alone cannot close rows 123, 133 or 143. The path-preserving index avoids inventing nested arbitrary slices. Preserve Markdown heading slug behavior, including duplicate headings, when mapping fragments; a path-only redirect is insufficient for existing deep links. If an original section is still an active operator or implementation contract, move that contract into the current owning docs first and link it from the index; historical Git text alone must not become the live source of truth.

## Eight Compound Engineering files: upstream identity is not proved

The repository records CE version `3.19.0` in `.claude/skills/compound-engineering.version`; [`website/docs-app/skills.md`](../../../../website/docs-app/skills.md) identifies `EveryInc/compound-engineering-plugin` and `scripts/update-compound-engineering-skills`. The [public tag](https://github.com/EveryInc/compound-engineering-plugin/tree/1756c0b9f3cf94493f287ea29ae766ad668fb7cf) `compound-engineering-v3.19.0` resolves to `1756c0b9f3cf94493f287ea29ae766ad668fb7cf` and declares plugin version `3.19.0`. The updater copies `skills/` into `.claude/skills/`, recreates `.codex/skills/` symlinks, and replaces all managed skills. `Aiur.AgentSkills` embeds the Claude tree at compile time and dispatches it to workspaces; a local edit therefore ships to both agent hosts, but a later refresh can overwrite it.

| Row | Vendored path | V3 lines | Path at named upstream tag |
| ---: | --- | ---: | --- |
| 175 | `.claude/skills/ce-plan/SKILL.md` | 816 | Present, bytes differ |
| 184 | `.claude/skills/ce-doc-review/scripts/cross-model-doc-review.sh` | 806 | Absent |
| 190 | `.claude/skills/ce-sweep/scripts/sweep-state.py` | 793 | Present, bytes differ |
| 204 | `.claude/skills/ce-compound/SKILL.md` | 755 | Present, bytes differ |
| 208 | `.claude/skills/ce-code-review/scripts/cross-model-adversarial-review.sh` | 737 | Present, bytes differ |
| 216 | `.claude/skills/ce-pov/scripts/cross-model-pov.sh` | 728 | Absent |
| 229 | `.claude/skills/ce-compound-refresh/SKILL.md` | 679 | Present, bytes differ |
| 232 | `.claude/skills/ce-optimize/SKILL.md` | 667 | Present, bytes differ |

None of the eight Aiur blobs exactly matched a blob at the same path in fetched upstream history; all eight entered Aiur together in bundling commit `8c00340df`. **Keep these eight action gates open.** Before splitting, record whether Aiur's copy is a deliberate local overlay or an upstream snapshot from another commit; choose a reproducible source plus patch/overlay policy. Then split at that source, run the updater into a disposable checkout, compare both Claude and Codex installed trees, and test `Aiur.AgentSkills` workspace dispatch and skill-relative references. A manual split in only the bundled copy would be erased by the current updater. The version string alone does not establish byte-for-byte reproducibility.

## Build Order fixture and preview

| Row | Decision | Gate |
| ---: | --- | --- |
| 215 `src/priv/build_orders/aiur-build-order.json` (729 lines) | **Still unresolved.** The 54-ticket pack is a discoverable `priv` planning pack for the `AIUR_BUILD_ORDER_DEMO` path; `src/priv/build_orders/README.md` documents the pack contract. `docs/build-order/build-order.json` also has 54 tickets but differs in repository identity and schema fields, and no checked-in generator for this exact `priv` pack was found. | Decide whether this pack is still a supported demo input. If yes, define an authoritative compact set of sub-500 source records plus deterministic assembly into an untracked release artifact, then assert JSON/PlanningSource semantics and release inclusion match the current pack. If no, prove no documented/demo consumer before deletion. Do not one-line minify the tracked JSON. |
| 222 `docs/build-order/plan-preview.html` (712 lines) | **Action route resolved: extract local assets.** The self-contained preview has an inline style block of about 217 lines and an inline script block of about 451; moving each unchanged body to sibling `.css` and `.js` files leaves the HTML entrypoint below 500, with both assets individually below 500. | Preserve the existing preview path and its accepted visual contract in `docs/build-order/tickets/BO-020-render-plan-breakdowns.md`. Open the result through `file://` and the served docs route with network disabled, compare rendered tables, theme toggle and graph to the original, and ensure no external runtime asset is introduced. |

## Reproduction and scope

The row set is exactly eleven historical documents, eight CE files, one fixture and one preview. V3 row line and literal-reference counts came from the clean candidate tree; upstream comparison used the public `compound-engineering-v3.19.0` tag and fetched history, plus Aiur's updater, manifest, docs and `AgentSkills` source. A separate canonical LF-byte census of that same v3 tree reports 3,422 tracked paths, 3,336 text, 47 binary, 39 symlinks, 1,185 above 200 and 355 above 500. This corroborates the oversized count but is still a candidate, not merged main. All row actions are planning proposals. They do not reduce the current tracked-file census, establish a net line saving, or replace the mandatory merged-main source and owner recheck.
