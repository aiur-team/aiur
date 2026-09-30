# U0 action review: 21 unresolved oversized owner-map rows

Checked the 21 `action_status: unresolved` rows in `oversized-owner-audit-part-2.json` against clean pre-merge Aiur candidate `0299daca28383a336682374e19e90d6434aa4e1a`. This is a proposed action decision, not a product edit, current-main recount, or permission to discard history. **Twelve rows now have a concrete safe action route** (eleven historical documents and the plan preview); **nine retain source/consumer gates** (eight CE skill files and one Build Order fixture). Every row still needs its implementation and validation on actual merged main.

## Eleven historical planning documents: preserve paths and original text

All eleven are historical plans or requirements. Their present paths are document entrypoints, and **seven have at least one in-repository inbound source file** when legacy `elixir/docs/...` spellings are included. The initial exact-path search missed rows 133 and 143 because their readers retain that old prefix. No reference found for the other four cannot rule out external links or generated references. Git preserves the exact original at a commit even when the working-tree file changes. **Proposed action for each row:** at the implementation-base SHA, retain the original file path as a short historical index under 500 lines; link to its full immutable GitHub blob and map each existing heading fragment to the corresponding old-blob fragment. Keep date, title, outcome/provenance and known inbound links. Check both current and legacy spellings, all local links, heading anchors and an offline checkout before replacing the body. Update known `elixir/docs/...` readers to the canonical `src/docs/...` path or provide an equivalent path-preserving redirect; a short index only at the current path will not repair those old references. Do not silently delete or minify the record. This action settles the archival-versus-splitting policy; the link/anchor migration is its acceptance gate.

| Row | Historical entrypoint | V3 lines | Known inbound source files | Largest H2 section |
| ---: | --- | ---: | ---: | ---: |
| 123 | `docs/plans/2026-06-12-002-fix-chat-control-lifecycle-ux-plan.md` | 998 | 0 | 680 |
| 133 | `src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md` | 964 | 2 | 544 |
| 143 | `src/docs/plans/2026-05-20-001-feat-opencode-prewarm-and-history-injection-plan.md` | 920 | 2 | 627 |
| 157 | `docs/plans/2026-07-12-004-feat-supervisor-decision-api-plan.md` | 859 | 0 | 428 |
| 162 | `docs/plans/2026-07-12-001-feat-decision-domain-persistence-plan.md` | 842 | 1 | 427 |
| 169 | `docs/plans/2026-07-06-001-refactor-production-readiness-planning-spike-plan.md` | 828 | 3 | 370 |
| 179 | `docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md` | 810 | 7 | 98 |
| 180 | `docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md` | 809 | 2 | 442 |
| 213 | `docs/plans/2026-06-15-002-feat-init-wizard-rework-plan.md` | 729 | 2 | 455 |
| 224 | `src/docs/plans/2026-05-31-002-feat-aiur-init-onboarding-plan.md` | 692 | 0 | 374 |
| 230 | `docs/plans/2026-05-24-003-feat-dashboard-events-panel-and-security-plan.md` | 676 | 0 | 384 |

Three H2 sections already exceed 500 lines, so a one-file-per-H2 split alone cannot close rows 123, 133 or 143. The path-preserving index avoids inventing nested arbitrary slices. Preserve Markdown heading slug behavior, including duplicate headings, when mapping fragments; a path-only redirect is insufficient for existing deep links. If an original section is still an active operator or implementation contract, move that contract into the current owning docs first and link it from the index; historical Git text alone must not become the live source of truth.

The missed readers are concrete: row 133 is named by `src/docs/opencode-pane-brainstorm.md:4` and row 143's own plan at `:910`; row 143 is named twice by `src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md` (`:77`, `:653`) and twice by `src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md` (`:82`, `:648`). These are historical `elixir/docs/...` references to the same basenames now under `src/docs/...`. Count distinct reader files in the table, not mention occurrences. The implementation gate must migrate these references and verify where they land; an exact current-path `rg` check is insufficient.

## Eight Compound Engineering files: source identity proved, regeneration gate open

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

The [full source-provenance audit](u0-ce-source-provenance-2026-09-29.md) found that all eight audited Aiur files match upstream commit `4aeaf6853074efe021409e880ad27958bf07bca6` byte-for-byte. Across all 259 managed files, 254 match that commit; a five-file overlay patch reproduces the current Aiur tree exactly. The source-identity question is resolved, but **keep these eight regeneration action gates open**: the current updater neither pins that commit nor reapplies the overlay, so a refresh from the named `3.19.0` tag would lose behavior. Split from the proved source/overlay and verify regenerated Claude and Codex trees, `Aiur.AgentSkills` workspace dispatch and skill-relative references before closing a row.

## Build Order fixture and preview

| Row | Decision | Gate |
| ---: | --- | --- |
| 215 `src/priv/build_orders/aiur-build-order.json` (729 lines) | **Candidate cut; consumer gate open.** The 54-ticket pack is not in normal `PackPaths` discovery, and `AIUR_BUILD_ORDER_DEMO` alone does not select it. The documented explicit `:build_order_planning_pack` override can still load it. `docs/build-order/build-order.json` has the same ticket IDs but a different repository identity and schema, so it is not an interchangeable replacement. See [current-main audit](u0-build-order-fixture-current-main-2026-09-29.md). | Check supported external/effective configuration for explicit consumers and obtain the product retirement choice. If unused, delete this bundled snapshot and update its README while retaining PlanningSource and the canonical docs pack. If used, preserve the path and plan a compatible migration. Do not one-line minify the tracked JSON or claim a saving before measuring it. |
| 222 `docs/build-order/plan-preview.html` (712 lines) | **Action route resolved: extract local assets.** The self-contained preview has an inline style block of about 217 lines and an inline script block of about 451; moving each unchanged body to sibling `.css` and `.js` files leaves the HTML entrypoint below 500, with both assets individually below 500. | Preserve the existing preview path and its accepted visual contract in `docs/build-order/tickets/BO-020-render-plan-breakdowns.md`. Open the result through `file://` and the served docs route with network disabled, compare rendered tables, theme toggle and graph to the original, and ensure no external runtime asset is introduced. |

## Reproduction and scope

The row set is exactly eleven historical documents, eight CE files, one fixture and one preview. V3 row line and literal-reference counts came from the clean candidate tree; upstream comparison used the public `compound-engineering-v3.19.0` tag and fetched history, plus Aiur's updater, manifest, docs and `AgentSkills` source. A separate canonical LF-byte census of that same v3 tree reports 3,422 tracked paths, 3,336 text, 47 binary, 39 symlinks, 1,185 above 200 and 355 above 500. This corroborates the oversized count but is still a candidate, not merged main. All row actions are planning proposals. They do not reduce the current tracked-file census, establish a net line saving, or replace the mandatory merged-main source and owner recheck.
