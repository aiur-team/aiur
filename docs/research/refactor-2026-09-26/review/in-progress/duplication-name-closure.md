# Remaining literal-name duplication: bounded closure

Frozen source: `3339b887196d5e9aefb273117a14bf33391ee41f`. The indexed population is **651 cross-module names / 1,977 clauses**. The disjoint tail ledgers inspect all indexed source heads and immediate bodies: A covers indices 0–325, B covers 326–650. Those ledgers carry the per-family definition and local-caller anchors. This note reconciles their dispositions.

| Tail disposition | Families | Source-screen decision |
| --- | ---: | --- |
| A: different contract or policy | 81 | No extraction from name equality. |
| A: no shared policy proposed | 116 | Local negative screen; representative checks below. |
| A: delegation or boundary wrapper | 95 | Preserve owner/facade boundary; representative checks below. |
| A: shared-policy lead | 34 | Reconciled below. |
| B: distinct or local | 177 | No extraction from name equality. |
| B: existing facade or delegation | 64 | Preserve facade boundary. |
| B: plausible shared-policy lead | 84 | Reconciled below. |

The **118 leads** partition into 27 body-finding source-span overlaps, 52 more raw-finding name-text hits, and 39 with neither. The 27 overlaps touch 22 distinct `dup-by-body` IDs. Of the 52 text hits, `duplication-name-caller-trace.json` links 42 to raw findings locating both definition files, seven to one file, and three to neither. The one-file cases are indices 58, 122, 422, 496, 506, 545, and 640; the unlocated text hits are 512 `stringify`, 535 `table`, and 576 `tracker_paused?`. These ten remain unmatched at source level and are not inherited findings by assertion. Both matching methods are navigation, not proof of the same contract. Existing IDs remain primary where source contracts match. No additive line or saving claim follows from a repeated name.

## Leads without an automatic raw-unit pointer

The indices below refer to the source-anchored rows in `duplication-name-tail-a.json` or `duplication-name-tail-b.json`. The direct source checks here resolve why an unmatched lead is retained, deferred, or discarded; they do not assert whole-call-graph equivalence.

| Index | Name | Source-level disposition |
| ---: | --- | --- |
| 1 | `known_relationships` | Same `:unknown` rejection; fixed versus caller-supplied dimensions. Tiny helper only after dimension ownership is settled. |
| 35 | `make_runnable` | FIFO plus membership-set mechanics already represented by `dup-by-body-58`; no additive finding. |
| 78 | `merged_pull_request_event?` | Firehose and RecentMerge admission/replay differ; see name draft 03. |
| 86 | `mint_topic` | Same prefixed 24-byte topic in adjacent Continuity/State; small helper candidate. |
| 130 | `normalized_percent` | Shared presentation rule; see name draft 05. |
| 200 | `positive_opt` | Exact positive-integer option fallback within TicketActivity; trivial helper, no separate material finding. |
| 241 | `public_lkg` | Public last-known-good snapshot accessor, adjacent to `platform-misc-31`; preserve projection owner. |
| 295 | `recommended?` | Same nil/option-id display predicate; trivial guard. |
| 319 | `reject_duplicate` | Decision duplicate rejection, adjacent to `dup-by-body-02`; preserve error boundary. |
| 389 | `retire_binding` | Claude/Codex return and failure handling differ; keep backend-specific. |
| 398 | `rework_attempt_alert_opts` | Map versus keyword caller contract. |
| 399 | `rewrite_segment` | Recovery enforces lstat and sync; live-store rewrite does not. Preserve durability boundary. |
| 405–406 | `routing_effort`, `routing_model` | CodingAgent wrappers delegate policy to RoutingValue. |
| 418 | `safe_config` | Distinct supervisor config reads with owner-specific fallback. |
| 421 | `safe_evidence` | Normalizer and presenter differ in output and unknown behavior. |
| 432 | `safe_unsubscribe` | SubscriptionStore catches exits; ExecutorEvents only rescues. |
| 433 | `safely_invoke_provider_delivery` | Same Claude REPL callback exception shield; local subsystem helper candidate. |
| 443 | `schedule_timeout` | Different timeout tags and correlation state. |
| 450 | `select_worker_host` | Dispatcher wrapper calls Slots owner. |
| 456 | `selected_status` | Route and presenter status vocabularies differ. |
| 488 | `source_connection` | Same Build Order direction fallback; see name draft 06. |
| 489 | `source_facts` | Codex thread total and turn delta differ in scope. |
| 513–514 | `structurally_defective?`, `structurally_valid?` | GraphProjection, Member and SelectedRoot validate different structures. |
| 537 | `take_sample` | Similar bounded ring mechanics; different producers. |
| 539 | `target_entry` | Both resolve delivered PR identity; comment path also loads review-thread snapshot and repo identity. |
| 540 | `target_task_results` | CI and comment poll target validation differs. |
| 556 | `ticket_number_from_variables` | GitHub attribution already covered by `github-b-05`. |
| 573 | `total_for` | Nil query cursor can coexist with known total; preserve availability meaning. |
| 588 | `unavailable_message` | Different UI nouns and reasons for unavailable state. |
| 602 | `usage_bar` | Similar bar math; widths and field owners differ. |
| 608 | `valid_name?` | Build Order rejects slash; CI requires nonblank. |
| 609 | `valid_request_id?` | Telemetry regex binary versus ControlLifecycle binary or positive integer. |
| 611 | `valid_run_id` | Shared run-ID policy; see name draft 04. |
| 621 | `validate_workspace_cwd` | Claude `Path.expand` versus Codex PathSafety canonicalization; existing agent backend finding. |
| 635 | `window_freshness` | Live view renders upstream freshness; projection derives stale from age/provider. Preserve unknown. |
| 642 | `worker_host_for_log` | Identical nil-to-local host label; tiny presentation helper. |
| 645 | `workspace_write_policy?` | Shared type check; see name draft 07. |

## Negative screens and wrappers

The A ledger's 116 local screens and 95 wrapper rows carry definition bodies; these are bounded screens. `duplication-name-caller-trace.json` systematically checks all 211 rows for parenthesized same-name calls and `&name/arity` captures in each definition file outside definition/spec/comment lines. It records 191 rows with at least one candidate local caller and 20 with none. All 20 caller-empty rows are exported `def` entries; the trace cannot see external callers. Their indices are 18, 25, 30–32, 40, 83, 92, 131, 190, 205, 217–218, 227, 247, 270, 301, 314, 320, and 323. The two private rows initially missed, A147 `option` and A216 `print_record`, are called as captures in both source files (`public_projection.ex:23`, `streamdeck_commands.ex:64`; `github_cost_cli.ex:399`, `units_cli.ex:262`). Representative high-similarity source checks include `positive_integer?` A198 (`agent_events.ex:312`, `decision_store.ex:2954`), the exact but trivial predicate; `method_not_allowed` A83 and `not_found` A131 (`decision_api_controller.ex:46,51`, `observability_api_controller.ex:144,149`), tiny API response adapters; and `meter_failure_recorder` A80 / `meter_ingester` A81 (`claude/account_meters.ex:77-79`, `codex/account_generation.ex:296-297`), provider callbacks under separate meter owners.

Further checks: `persisted_map` A184 (`decision_answer.ex:291`, `decision_revision.ex:343`) differs in fields and error tags. `rebuild_snapshot` A293 (`build_order/ad_hoc_source.ex:346`, `open_ticket_source.ex:404`) differs in fields, sort and truncation. `put_auth_mode` A247 (`claude/account_generation/context.ex:23`, `codex/account_generation/context.ex:19`) preserves atom versus binary forms. `recover_retained_binding` A309 (`claude/account_generation.ex:114`, `codex/account_generation.ex:167`) is backend-specific. `redispatch_admission` A311 (`orchestrator/rate_limit_fallback.ex:528`, `remote_control_mode.ex:218`) has different worker-host context. `refresh_open_drill` A315 (`build_order/usage_runtime.ex:376`, `dashboard_live.ex:1657`) carries different assigns and limits. `progress_fill_class` A223 and `reject_incomplete` A320 also yield different CSS classes and response destinations.

This closes the indexed **name-candidate screen** only. The B ledger records one local caller per module where found; the new trace records lexical immediate-caller candidates for the 211 A negative/wrapper rows. The 20 exported caller-empty A rows and ten one/zero-location raw text hits above are explicit residuals. Dynamic/generated calls, external callers, downstream error contracts, and full transitive call graphs remain outside this screen. Any extraction must check its actual callers and mutation-test its behavior.
