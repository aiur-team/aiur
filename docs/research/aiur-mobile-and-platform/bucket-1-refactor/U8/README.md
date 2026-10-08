# U8 — Retire the file-size debt: implementation tickets

Planning pack for unit U8 of the [refactor plan](../../../../plans/2026-09-29-001-refactor-production-readiness-plan.md)
(goal: zero tracked UTF-8 text paths above 500 lines). It turns the
[37-package ledger](../../../refactor-2026-09-26/synthesis/u8-release-007/proposal.md)
(assigned at `465aca643`) into tickets for one Build Order. Research only; no product
code changed.

- Tickets: [tickets/](tickets/) (nine sections each, brief §9). Edges: [edges.md](edges.md).
- **Every U8 ticket waits on U0:** the review gate (U0-T01), the refreshed owner ledger
  (U0-T02, which adopts the new rows below) and the transitional size gate (U0-T03).
  U-unit tickets are in [../U-units/](../U-units/) (written in parallel; IDs as of
  2026-10-07).
- Size-owner lookups for MP tickets (RC-23, MP-R1-C11-T02 Procedure B) use the
  ledger plus "New rows" below until U0 publishes a refreshed ledger.

## Census result

- **Date:** 2026-10-07. **Commit:** `origin/main` `58854d4c8` ("Hand off Claude
  sessions at account limits (#3038)").
- **Method:** U0 counting rule on Git blobs (not the working tree): LF bytes, plus one
  for a nonempty unterminated last line; a blob is text when it decodes as UTF-8 and
  has no NUL byte; symlinks are not followed. The same script reproduces the release
  census exactly at `465aca643`: 3,348 text files, 1,188 above 200, **357 above 500**,
  and an identical path/count set.

| Measure | `465aca643` (ledger) | `58854d4c8` (now) |
| --- | ---: | ---: |
| Tracked blobs (symlinks excluded) | 3,395 | 3,831 |
| Symlinks | 41 | 41 |
| UTF-8 text files | 3,348 | 3,463 |
| Non-text blobs | 47 | 368 (359 PNG, 4 WOFF2, 5 other media) |
| Text files above 200 lines | 1,188 | 1,217 |
| **Text files above 500 lines** | **357** | **373** |
| Lines in files above 500 | 417,065 | 431,196 |

Reconciliation with `assignments.csv`:

- **357 of 357** ledger rows are still above 500. **0** shrank to 500 or less.
  **0** were deleted or renamed. No ledger path moved, so no owner row is stale.
- **Drift:** 88 ledger rows grew and 1 shrank, net **+4,285 lines**. The
  transitional gate is not on `main` yet, so the debt still grows. Largest growth:
  `dispatcher_test.exs` +310, `agent_control_cli_test.exs` +233, `github_budget.py`
  +193, `session_lifecycle.ex` +165, `launcher.test.mjs` +158, `agent_control_cli.ex` +152.
- **16 new oversized paths** with no ledger owner (9,846 lines): 6 new
  files and 10 files that crossed 500 since the release. Provisional owners below.

### New rows (provisional owners for U0-T02 to adopt)

| Path | At `465aca643` | Now | Package | Ticket | Reason |
| --- | ---: | ---: | --- | --- | --- |
| `src/test/aiur/workspace/wip_preservation_test.exs` | absent | 988 | WORKSPACE | U8-P37-T02 | workspace (build.py rule) |
| `docs/aiur-style/plan.md` | absent | 788 | HIST_CE | U8-P25-T02 | live plan; archive under the HIST policy when finished |
| `packages/aiur-style/package-lock.json` | absent | 753 | SITE (lockfile) | U8-P00-T01 | lockfile class |
| `src/lib/aiur/accounts.ex` | absent | 724 | AGENT_CORE | U8-P01-T02 | agent identity (build.py `AGENT_CORE` rule needs a new token) |
| `src/lib/aiur/workspace/wip_preservation.ex` | absent | 671 | WORKSPACE | U8-P37-T02 | workspace (build.py rule) |
| `src/test/aiur/accounts_test.exs` | absent | 641 | AGENT_CORE | U8-P01-T02 | agent identity (build.py `AGENT_CORE` rule needs a new token) |
| `src/lib/aiur/model_availability.ex` | 421 | 571 | AGENT_CORE | U8-P01-T02 | model choice |
| `src/test/aiur/run_telemetry/sampler_test.exs` | 496 | 548 | TELEMETRY | U8-P34-T01 | run telemetry (build.py rule) |
| `src/test/aiur/orchestrator/dispatcher_blocked_by_cost_test.exs` | 500 | 536 | LIFECYCLE_DISPATCH | U8-P28-T01 | dispatch (build.py rule) |
| `src/lib/aiur_web/operator_control_center/provider_meters_presenter.ex` | 487 | 531 | TELEMETRY | U8-P34-T02 | provider meters (build.py rule) |
| `src/lib/aiur/decision_attention.ex` | 477 | 529 | DECISIONS | U8-P16-T02 | decisions (build.py rule) |
| `src/test/aiur_web/operator_control_center/units_presenter_test.exs` | 485 | 524 | WEB | U8-P36-T02 | web (build.py rule) |
| `src/test/aiur/orchestrator/global_pause_test.exs` | 489 | 520 | LIFECYCLE_STATUS | U8-P29-T03 | pause/resume is status-owned; build.py would say DISPATCH |
| `src/lib/aiur/config/schema/agent.ex` | 496 | 514 | CONFIG | U8-P15-T01 | config (build.py rule) |
| `src/test/aiur/provider_meters_test.exs` | 486 | 507 | TELEMETRY | U8-P34-T02 | provider meters (build.py rule) |
| `src/lib/aiur_web/operator_control_center/units_presenter.ex` | 461 | 501 | WEB | U8-P36-T02 | web (build.py rule) |

### Rows already owned by an MP ticket (no U8 ticket)

| Path | Lines | Owning ticket | Why |
| --- | ---: | --- | --- |
| `src/lib/aiur/agent_control_cli.ex` | 3514 | MP-R1-C9-T10..T14 | That ticket already splits the file to under 500 (C9-T14 exit: `agent_control_cli.ex` under 200 lines; E5-C1-T02: three files under 500). A second U8 ticket would duplicate it. U8-P00-T02 waits on it. |
| `src/test/aiur/agent_control_cli_test.exs` | 4358 | MP-R1-C9-T10..T14 | That ticket already splits the file to under 500 (C9-T14 exit: `agent_control_cli.ex` under 200 lines; E5-C1-T02: three files under 500). A second U8 ticket would duplicate it. U8-P00-T02 waits on it. |
| `src/priv/static/conversation-voice-controller.js` | 539 | MP-E5-C1-T02 | That ticket already splits the file to under 500 (C9-T14 exit: `agent_control_cli.ex` under 200 lines; E5-C1-T02: three files under 500). A second U8 ticket would duplicate it. U8-P00-T02 waits on it. |

### Census method

```bash
# python3 census.py <repo> <rev>  -> path,lines for every text blob above 500
import subprocess,sys
repo,rev=sys.argv[1],sys.argv[2]
ls=subprocess.run(['git','-C',repo,'ls-tree','-r','-z',rev],capture_output=True).stdout.split(b'\0')
items=[(p.decode(),m.split()[2].decode()) for m,p in (e.split(b'\t',1) for e in ls if e)
       if m.split()[1]==b'blob' and m.split()[0]!=b'120000']
cat=subprocess.run(['git','-C',repo,'cat-file','--batch'],input=''.join(s+'\n' for _,s in items).encode(),capture_output=True).stdout
i=0; over=[]
for path,_ in items:
    j=cat.index(b'\n',i); size=int(cat[i:j].split()[2]); data=cat[j+1:j+1+size]; i=j+2+size
    try: data.decode('utf-8')
    except UnicodeDecodeError: continue
    if b'\0' in data: continue
    n=data.count(b'\n')+(1 if data and not data.endswith(b'\n') else 0)
    if n>500: over.append((path,n))
print('path,lines'); [print(f'{p},{n}') for p,n in sorted(over,key=lambda x:-x[1])]
```

Use the U0 gate instead once U0-T03 installs it; the two must agree.

## Ticket granularity

The ledger's 37 packages are write-ownership domains, not tickets
(proposal.md: "assignments, not promised standalone tickets"). The rule used here:

1. **One ticket = one agent session = one cohesive module family** (a module, its
   split-off parts and its tests), usually 3,000–7,000 current lines. A ticket may
   ship as a short series of green PRs; it never mixes two U-unit start contracts.
2. **Split a package** when it is too big for one session (LIFECYCLE_DISPATCH and
   LIFECYCLE_STATUS 6 each, GH_ACCESS 4, EVENTS 3, WEB 3, …) or when part of it has a
   different gate: an MP ticket that restructures the file first (config.ex,
   comment_polling, orchestrator.ex/state.ex, streamdeck_logs), a U7 cut decision
   (Claude Remote Control, Linear), or an MP ticket that needs the split first
   (coding_agent.ex, Claude and Codex files for MP-R7-C4).
3. **Merge small packages** that share one gate: HIST_CE and HIST_PRODUCT share the U0
   archival policy (one ticket, U8-P25-T01). The four lockfiles from DECK_PKG, DOCS and
   SITE share one decision (U8-P00-T01).
4. **Do not duplicate MP tickets** that already split a file (three rows above).
5. **Keep tiny packages separate** when they carry their own authority decision
   (LINEAR, DECK_DESIGN, CE, CI, APP_BOOT).

Result: **74 tickets** = 72 package tickets + U8-P00-T01 (lockfiles) + U8-P00-T02
(ledger close and U9 hand-off). P26 (HIST_PRODUCT) has no ticket of its own; it is
inside U8-P25-T01. Ticket IDs: `U8-Pxx-Tyy`, where `Pxx` is the package's position in
the proposal's ledger table (01 AGENT_CORE … 37 WORKSPACE) and `P00` is cross-package.

## Tickets

"Predecessors" excludes U0-T01, U0-T02 and U0-T03, which every ticket has. U-unit
predecessors (U1–U7) come from file overlap: a U ticket that edits a file in a U8
ticket's scope lands first (plan: shared paths wait for the owning U1–U7 contract). "Start contract" is the
owning U-unit contract from the ledger table. Complexity is 1 (mechanical) to 5
(large stateful module with many callers).

| ID | Title | Package | Files (current lines) | Start contract | Predecessors | Needed by | Cx |
| --- | --- | --- | --- | --- | --- | --- | ---: |
| [U8-P00-T01](tickets/U8-P00-T01.md) | Decide and apply the tracked-lockfile disposition | DECK_PKG, DOCS, SITE (lockfile rows) | `packages/streamdeck/package-lock.json` 3028; `website/package-lock.json` 1657; `packages/aiur-style/package-lock.json` 753; `website/docs-app/bun.lock` 593 | U0 lockfile decision; owner decision OWNER-U8-LOCK | OWNER-U8-LOCK | — | 2 |
| [U8-P01-T01](tickets/U8-P01-T01.md) | Split CodingAgent into registry, contract and dispatch modules | AGENT_CORE | `coding_agent.ex` 1179; `coding_agent_test.exs` 1026; `open_ai_compat/coding_agent_test.exs` 1001 | U4 backend contract | — | MP-R7-C4-T03 | 4 |
| [U8-P01-T02](tickets/U8-P01-T02.md) | Split agent environment, process log, model discovery and accounts | AGENT_CORE | `agent_environment.ex` 643; `agent_environment_test.exs` 950; `agent_process_log.ex` 576; `agent_log_test.exs` 753; `model_discovery.ex` 827; `model_discovery_test.exs` 564; `model_availability.ex` 571; `accounts.ex` 724; `accounts_test.exs` 641 | U4 contract | — | — | 3 |
| [U8-P02-T01](tickets/U8-P02-T01.md) | Split the agent runner core: runner, message handler, turn loop, tool executor | AGENT_TURN | `agent_runner.ex` 749; `agent_runner_test.exs` 804; `agent_runner/message_handler.ex` 671; `agent_runner/message_handler_test.exs` 539; `agent_runner/turn_loop.ex` 613; `agent_runner/tool_executor.ex` 908; `agent_runner/tool_executor_test.exs` 1966 | U4 turn/pause contract | U2-T01, U4-T01, U4-T02 | — | 4 |
| [U8-P02-T02](tickets/U8-P02-T02.md) | Split session lifecycle, queue drain, queue store and shared app-server tests | AGENT_TURN | `agent_runner/session_lifecycle.ex` 1289; `agent_runner/session_lifecycle_test.exs` 1110; `agent_runner/provider_lifecycle_test.exs` 511; `agent_runner/queue_drain.ex` 834; `agent_runner/queue_drain_test.exs` 1003; `agent_queue_store.ex` 597; `agent_queue_test.exs` 538; `app_server_test.exs` 1402; `app_server/adapter_test.exs` 574 | U4 turn/pause contract | U4-T01, U4-T02 | — | 4 |
| [U8-P03-T01](tickets/U8-P03-T01.md) | Split the offline analytics reducer and renderer; shrink fixtures | ANALYTICS | `analytics/lib/analytics/reduce.py` 979; `analytics/lib/analytics/render.py` 521; `fixtures/analytics/builds/test-build/build-summary.json` 1227; `fixtures/analytics/runs/boot-a/run-summary.json` 1042 | U6 telemetry schema | — | — | 3 |
| [U8-P04-T01](tickets/U8-P04-T01.md) | Split the application module child specs and the application test | APP_BOOT | `aiur.ex` 628; `application_test.exs` 835 | U0/U2 startup contract; U5 access-child order | — | — | 3 |
| [U8-P05-T01](tickets/U8-P05-T01.md) | Retire Build Order prototypes and split the handoff and chat records | BO_DESIGN | `docs/build-order/prototype/Aiur Operator Control Center.2026-07-13-refresh.html` 3515; `docs/build-order/prototype/Aiur Operator Control Center.html` 3369; `docs/build-order/plan-preview.html` 712; `docs/build-order/EXECUTOR-HANDOFF.md` 3436; `docs/build-order/AGENT-CHAT.md` 1854 | design-authority decision | OWNER-U8-DESIGN | — | 2 |
| [U8-P06-T01](tickets/U8-P06-T01.md) | Make one canonical publication script tree and split its modules | BO_PUBLISH | `.claude/skills/aiur-build/scripts/publication/publication_operator.py` 1867; `.claude/skills/aiur-build/scripts/publication/publication_rendering.py` 805; `.claude/skills/aiur-build/scripts/publication/publication_live_graph.py` 770; `.claude/skills/aiur-build/scripts/publication/publication_receipt_authority.py` 605; `docs/build-order/scripts/publication_rendering.py` 798; `docs/build-order/scripts/publication_live_graph.py` 770; `docs/build-order/scripts/publication_receipt_authority.py` 605; `docs/build-order/scripts/execution_amendment.py` 764; `docs/build-order/scripts/execution_amendment_live.py` 656; `docs/build-order/scripts/capture_progress_estimates.py` 560; `docs/build-order/scripts/tests/test_publication_operator.py` 1111; `docs/build-order/scripts/tests/test_publication_rendering.py` 961 | U0 fixture/receipt decision | — | — | 4 |
| [U8-P06-T02](tickets/U8-P06-T02.md) | Regenerate or split Build Order pack JSON and the demo pack | BO_PUBLISH | `docs/build-order/build-order.json` 7822; `src/priv/build_orders/croptracker-demo.json` 1611; `src/priv/build_orders/aiur-build-order.json` 729 | U0 fixture/receipt decision | U8-P06-T01 | — | 4 |
| [U8-P07-T01](tickets/U8-P07-T01.md) | Split Build Order graph projection and GitHub graph tests | BO_RUNTIME | `build_order/graph_projection.ex` 1844; `build_order/graph_projection_test.exs` 1432; `build_order/github_graph_test.exs` 1781; `build_order/shared_resource_store_test.exs` 588 | U2 graph contract | — | — | 4 |
| [U8-P07-T02](tickets/U8-P07-T02.md) | Split Build Order ticket detail, history and context presenter | BO_RUNTIME | `build_order/ticket_detail_coordinator_test.exs` 1339; `build_order/ticket_detail_test.exs` 900; `build_order/ticket_history_provider.ex` 627; `build_order/ticket_history_provider_test.exs` 566; `build_order/ticket_context_presenter.ex` 793 | U2 graph contract; U6 status contract | — | — | 3 |
| [U8-P07-T03](tickets/U8-P07-T03.md) | Split planning source, pack status, Build Order presenter and LiveView test | BO_RUNTIME | `build_order/planning_source.ex` 933; `build_order/planning_source_test.exs` 1066; `build_order/pack_status.ex` 515; `build_order/pack_status_test.exs` 917; `build_order_presenter.ex` 1046; `build_order_presenter_test.exs` 639; `live/build_order_live_test.exs` 1866 | U6 status contract | — | — | 4 |
| [U8-P08-T01](tickets/U8-P08-T01.md) | Split dashboard.css into assembled per-surface sheets | BROWSER | `src/priv/static/dashboard.css` 10417 | U6 web contracts | — | — | 4 |
| [U8-P08-T02](tickets/U8-P08-T02.md) | Split the browser fixture server, docs capture fixture and units browser spec | BROWSER | `browser/fixture_server.exs` 2640; `manual/executor_control_center_docs_fixture.exs` 946; `src/browser/tests/units.browser.spec.mjs` 872 | U6 web contracts | — | — | 3 |
| [U8-P09-T01](tickets/U8-P09-T01.md) | Split the build gate script, holder and Elixir wrapper | BUILD_GATE | `src/priv/build_gate.bash` 1912; `src/priv/build_gate_holder.py` 1025; `build_gate.ex` 797; `build_gate_test.exs` 3231 | U0 transitional gate | — | — | 4 |
| [U8-P10-T01](tickets/U8-P10-T01.md) | Stop tracking oversized vendored Compound Engineering files | CE | `.claude/skills/ce-babysit-pr/scripts/pr-snapshot` 2096; `.claude/skills/ce-riffrec-feedback-analysis/scripts/analyze_riffrec_zip.py` 1122; `.claude/skills/ce-sweep/scripts/analyze_riffrec_zip.py` 1122; `.claude/skills/ce-code-review/scripts/peer-job-runner.py` 1030; `.claude/skills/ce-doc-review/scripts/peer-job-runner.py` 1030; `.claude/skills/ce-pov/scripts/peer-job-runner.py` 1030; `.claude/skills/ce-plan/SKILL.md` 816; `.claude/skills/ce-doc-review/scripts/cross-model-doc-review.sh` 806; `.claude/skills/ce-sweep/scripts/sweep-state.py` 793; `.claude/skills/ce-compound/SKILL.md` 755; `.claude/skills/ce-code-review/scripts/cross-model-adversarial-review.sh` 737; `.claude/skills/ce-pov/scripts/cross-model-pov.sh` 728; `.claude/skills/ce-compound-refresh/SKILL.md` 679; `.claude/skills/ce-optimize/SKILL.md` 667; `.claude/skills/ce-brainstorm/references/html-rendering.md` 634; `.claude/skills/ce-ideate/references/html-rendering.md` 634; `.claude/skills/ce-plan/references/html-rendering.md` 634; `.claude/skills/ce-compound/scripts/session-history/extract-skeleton.py` 575; `.claude/skills/ce-code-review/SKILL.md` 541 | U0 provenance overlay decision | OWNER-U8-CE | — | 3 |
| [U8-P11-T01](tickets/U8-P11-T01.md) | Split CI and npm release workflows without renaming required jobs | CI | `.github/workflows/ci.yml` 770; `.github/workflows/release-npm.yml` 600 | U0 gate installed; U9 release contract | U1-T03 | — | 3 |
| [U8-P12-T01](tickets/U8-P12-T01.md) | Split Claude telemetry and the Claude coding agent | CLAUDE | `claude/telemetry.ex` 666; `claude/telemetry_test.exs` 821; `claude/coding_agent.ex` 543; `claude/coding_agent_test.exs` 815 | U4 backend contract | U4-T03 | MP-R7-C4-T04 | 3 |
| [U8-P12-T02](tickets/U8-P12-T02.md) | Split Claude Remote Control and the REPL agent test, or close on a U7 cut | CLAUDE | `claude/remote_control.ex` 726; `claude/remote_control_test.exs` 633; `claude/repl_agent_test.exs` 1352 | U4 backend contract; U7 integrations-09 decision | — (cond.: U7-T01) | MP-R7-C4-T04 | 3 |
| [U8-P13-T01](tickets/U8-P13-T01.md) | Split aiur-engine.sh into sourced libexec modules and split its tests | CLI | `packaging/npm/aiur-cli/libexec/aiur-engine.sh` 4352; `aiur_engine_test.exs` 4471; `regression/engine_control_test.exs` 997 | U1 P0 check; U4/U6 controls | U1-T02, U1-T03 | — | 5 |
| [U8-P13-T02](tickets/U8-P13-T02.md) | Split the aiurdev shim, launcher test and Aiur.CLI | CLI | `scripts/aiurdev` 937; `scripts_aiurdev_test.exs` 2048; `packaging/npm/aiur-cli/test/launcher.test.mjs` 1134; `cli.ex` 670; `cli_test.exs` 590 | U1 P0 check | U8-P13-T01 | — | 3 |
| [U8-P14-T01](tickets/U8-P14-T01.md) | Split the Codex event humanizer and Codex tests | CODEX | `codex/event_humanizer.ex` 510; `codex/turn_loop_test.exs` 987; `dynamic_tool_test.exs` 1004; `codex/account_generation_test.exs` 760; `codex/approvals_test.exs` 585 | U4 privacy/retry decision | — | MP-R7-C4-T04 | 3 |
| [U8-P15-T01](tickets/U8-P15-T01.md) | Finish Aiur.Config and the agent schema below 500 after MP-R1-C4 | CONFIG | `config.ex` 1480; `config/schema/agent.ex` 514; `config/schema_test.exs` 1024 | U0 config key baseline | MP-R1-C4-T01, MP-R1-C4-T02, MP-R1-C4-T03 | — | 3 |
| [U8-P15-T02](tickets/U8-P15-T02.md) | Split the init and env test suites | CONFIG | `init_test.exs` 2266; `env_test.exs` 645 | U0 config key baseline | — | — | 2 |
| [U8-P16-T01](tickets/U8-P16-T01.md) | Split DecisionStore and its test suite | DECISIONS | `decision_store.ex` 4826; `decision_store_test.exs` 4866 | U6 authority matrix | U6-T01, U6-T02 | — | 5 |
| [U8-P16-T02](tickets/U8-P16-T02.md) | Split decision event, projection, history, attention and their tests | DECISIONS | `decision_event.ex` 1057; `decision_projection.ex` 1039; `decision_projection_test.exs` 1036; `decision_api_test.exs` 967; `decision_query_test.exs` 809; `decision_revision_store_test.exs` 766; `decision_withdrawal_test.exs` 594; `decision_history.ex` 540; `decision_attention.ex` 529; `decision_attention_test.exs` 719 | U6 authority matrix | U6-T02, U8-P16-T01 | — | 4 |
| [U8-P17-T01](tickets/U8-P17-T01.md) | Re-extract the Stream Deck design source in modules | DECK_DESIGN | `docs/design/streamdeck/streamdeck.design.js` 663 | U0 design-authority/re-extract decision | OWNER-U8-DESIGN | — | 2 |
| [U8-P18-T01](tickets/U8-P18-T01.md) | Split the Stream Deck controller, art segments, main, rasterizer and channel | DECK_PKG | `packages/streamdeck/src/controller.ts` 1102; `packages/streamdeck/test/controller.test.ts` 1369; `packages/streamdeck/src/art/segments.ts` 1135; `packages/streamdeck/test/art/segments.test.ts` 1119; `packages/streamdeck/src/main.ts` 734; `packages/streamdeck/src/rasterizer.ts` 595; `packages/streamdeck/src/channel.ts` 587; `packages/streamdeck/test/dial.test.ts` 549 | package-manifest decision | — | — | 4 |
| [U8-P19-T01](tickets/U8-P19-T01.md) | Split StreamdeckLive, the channel, projection and emulator | DECK_WEB | `live/streamdeck_live.ex` 1802; `live/streamdeck_live_test.exs` 1807; `streamdeck_channel.ex` 609; `streamdeck_channel_test.exs` 1337; `streamdeck_projection.ex` 540; `src/priv/static/streamdeck-emulator-hook.js` 606; `src/browser/tests/streamdeck-emulator.browser.spec.mjs` 1312 | U6 web contract; DECK_PKG interface | — | — | 4 |
| [U8-P19-T02](tickets/U8-P19-T02.md) | Finish StreamdeckLogs below 500 after MP-R6-C1-T01 | DECK_WEB | `streamdeck_logs.ex` 637; `streamdeck_logs_test.exs` 565 | U6 web contract | MP-R6-C1-T01 | — | 2 |
| [U8-P20-T01](tickets/U8-P20-T01.md) | Split SPEC.md, src/README.md, AGENTS.md and two docs-app pages | DOCS | `SPEC.md` 2292; `src/README.md` 854; `AGENTS.md` 639; `website/docs-app/reference/configuration.md` 880; `website/docs-app/concepts/ticket-lifecycle.md` 662 | owning behavior contracts | — | — | 3 |
| [U8-P20-T02](tickets/U8-P20-T02.md) | Split apis/github.md after the GitHub behavior splits | DOCS | `website/docs-app/apis/github.md` 779 | U5 access contract | U5-T01, U5-T04, U5-T05, U8-P22-T01, U8-P22-T02, U8-P22-T03, U8-P22-T04, U8-P23-T01, U8-P23-T02, U8-P24-T01 | — | 2 |
| [U8-P21-T01](tickets/U8-P21-T01.md) | Split webhook ingress: deposit, normalizer, mode registry and webhook tests | EVENTS | `events/github_webhook/deposit.ex` 996; `events/github_webhook/deposit_test.exs` 1530; `events/github_webhook/normalizer.ex` 837; `events/github_webhook_test.exs` 1002; `github_webhook_test.exs` 547; `events/github_webhook_equivalence_test.exs` 980; `events/webhook_poll_reconciliation_test.exs` 727; `webhooks/mode_registry.ex` 502 | U3 ordering contract; U5 GitHub read contract | U5-T03 | — | 4 |
| [U8-P21-T02](tickets/U8-P21-T02.md) | Split the GitHub comments and CI pollers | EVENTS | `events/github_comments_poller.ex` 863; `events/github_comments_poller_test.exs` 1570; `events/github_ci_poller.ex` 816; `events/github_ci_poller_test.exs` 1227; `events/github_firehose_test.exs` 730 | U3 ordering contract; U5 GitHub read contract | — | — | 4 |
| [U8-P21-T03](tickets/U8-P21-T03.md) | Split subscriptions, publisher, alerts, wake inbox and executor events | EVENTS | `events/subscription_store.ex` 748; `events/subscription_store_test.exs` 611; `events/publisher.ex` 539; `alerts.ex` 746; `alerts_test.exs` 1388; `executor_wake_inbox.ex` 619; `executor_events.ex` 525 | U3 ordering and wake-receipt contracts | U3-T01, U3-T03 | — | 4 |
| [U8-P22-T01](tickets/U8-P22-T01.md) | Split the GitHub resource store | GH_ACCESS | `github/resource_store.ex` 2261; `github/resource_store_test.exs` 1950; `github/resource_fetch_test.exs` 563; `github/view_state_sweep_test.exs` 616 | U5 access contract | U5-T03, U5-T04 | — | 4 |
| [U8-P22-T02](tickets/U8-P22-T02.md) | Split GitHub quota and budget | GH_ACCESS | `github/quota.ex` 1380; `github/quota_test.exs` 1002; `github/budget.ex` 928; `github/budget_test.exs` 1252 | U5 access contract | U5-T04 | — | 4 |
| [U8-P22-T03](tickets/U8-P22-T03.md) | Split CI readiness, pull requests and the poll batches | GH_ACCESS | `github/ci_readiness.ex` 1149; `github/ci_readiness_test.exs` 1704; `github/pull_requests.ex` 954; `github/comment_poll_batch.ex` 595; `github/comment_poll_batch_test.exs` 652; `github/ci_poll_batch_test.exs` 634 | U5 access contract | U5-T01 | — | 4 |
| [U8-P22-T04](tickets/U8-P22-T04.md) | Split the read cache, its policy, transport and ingestion tests | GH_ACCESS | `github/read_cache.ex` 555; `github/read_cache/policy.ex` 545; `github/read_cache_test.exs` 1437; `github/transport.ex` 860; `github/mutation_write_through_test.exs` 807; `regression/github_ingestion_test.exs` 790 | U5 access contract | U5-T01, U5-T04 | — | 4 |
| [U8-P23-T01](tickets/U8-P23-T01.md) | Split the GitHub quota and push guard scripts and the guard test | GH_GUARD | `src/priv/github_quota_guard.sh` 3403; `src/priv/github_push_guard.sh` 509; `agent_github_guard.ex` 541; `agent_github_guard_test.exs` 5762 | U5 access contract; GH_ACCESS API | — | — | 5 |
| [U8-P23-T02](tickets/U8-P23-T02.md) | Split github_budget.py and the GitHub client test | GH_GUARD | `src/priv/github_budget.py` 1112; `github_client_test.exs` 2252 | U5 access contract; GH_ACCESS API | — | — | 3 |
| [U8-P24-T01](tickets/U8-P24-T01.md) | Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS | GH_TRUST | `github/issues.ex` 1263; `github/issues_test.exs` 1367; `github/issue_state_test.exs` 523; `github/config.ex` 1090; `github/config_test.exs` 918; `github/auth_preflight.ex` 549; `github/auth_preflight_test.exs` 687; `github/dispatch_authorization.ex` 768; `github/dispatch_authorization_test.exs` 1051; `codeowners.ex` 657 | U5 trust contract | U5-T01, U5-T02, U5-T03, MP-E1-C1-T01, MP-E1-C1-T02, MP-E1-C1-T03, MP-E1-C1-T04, MP-E1-C1-T05 | — | 4 |
| [U8-P25-T01](tickets/U8-P25-T01.md) | Archive historical plans as path-preserving short indexes (HIST_CE and HIST_PRODUCT) | HIST_CE + HIST_PRODUCT | `docs/plans/2026-05-24-001-feat-event-system-foundation-plan.md` 1716; `docs/plans/2026-06-12-002-fix-chat-control-lifecycle-ux-plan.md` 998; `docs/plans/2026-07-12-004-feat-supervisor-decision-api-plan.md` 859; `docs/plans/2026-07-12-001-feat-decision-domain-persistence-plan.md` 842; `docs/plans/2026-07-06-001-refactor-production-readiness-planning-spike-plan.md` 828; `docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md` 810; `docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md` 809; `docs/plans/2026-06-15-002-feat-init-wizard-rework-plan.md` 729; `docs/plans/2026-05-24-003-feat-dashboard-events-panel-and-security-plan.md` 676; `docs/plans/2026-06-22-001-feat-repo-agnostic-prewarm-plan.md` 639; `docs/plans/2026-07-12-003-feat-operator-control-center-ui-plan.md` 632; `docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md` 616; `docs/plans/2026-07-12-003-feat-decision-revisions-plan.md` 579; `docs/plans/2026-07-11-003-refactor-orchestrator-dispatch-lifecycle-extraction-plan.md` 572; `docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md` 567; `docs/plans/2026-05-22-001-feat-shared-prewarm-opencode-plan.md` 547; `docs/plans/2026-05-27-001-feat-subscriptions-and-inbox-plan.md` 545; `docs/plans/2026-07-11-006-feat-daemon-run-telemetry-plan.md` 542; `docs/plans/2026-07-15-002-feat-financial-data-authentication-plan.md` 521; `docs/plans/2026-05-28-001-feat-deactivated-state-plan.md` 520; `docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md` 518; `docs/plans/2026-07-13-003-feat-applied-unit-controls-plan.md` 510; `src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md` 964; `src/docs/plans/2026-05-20-001-feat-opencode-prewarm-and-history-injection-plan.md` 920; `src/docs/plans/2026-05-31-002-feat-aiur-init-onboarding-plan.md` 692; `src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md` 656; `src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md` 650; `src/docs/opencode-pane-brainstorm.md` 551 | U0 path/anchor archival policy | — | — | 3 |
| [U8-P25-T02](tickets/U8-P25-T02.md) | Archive the aiur-style plan after its build order finishes | HIST_CE (provisional, new row) | `docs/aiur-style/plan.md` 788 | U0 archival policy; aiur-style build order complete | U8-P25-T01, AIUR-STYLE-DONE | — | 1 |
| [U8-P27-T01](tickets/U8-P27-T01.md) | Build the ELK worker from a pinned package and split the layout worker spec | LAYOUT | `src/priv/static/vendor/elk/0.11.1/elk-worker.min.js` 6312; `src/priv/static/vendor/elk/0.11.1/aiur-layout-worker.js` 507; `src/browser/layout/aiur-layout-worker.js` 507; `src/browser/tests/layout-worker.browser.spec.mjs` 1185 | U0 offline asset/hash decision | — | — | 3 |
| [U8-P28-T01](tickets/U8-P28-T01.md) | Split the dispatcher and its test suites | LIFECYCLE_DISPATCH | `orchestrator/dispatcher.ex` 2686; `orchestrator/dispatcher_test.exs` 3507; `orchestrator/dispatcher_blocked_by_cost_test.exs` 536 | U2 state contract | U2-T01, MP-E1-C1-T05, MP-E1-C1-T06 | — | 5 |
| [U8-P28-T02](tickets/U8-P28-T02.md) | Split issue sync and its test suite | LIFECYCLE_DISPATCH | `orchestrator/issue_sync.ex` 2301; `orchestrator/issue_sync_test.exs` 3084 | U2 state contract | U2-T01, U2-T02, MP-E1-C1-T02, MP-E1-C1-T05, MP-E1-C1-T06 | — | 5 |
| [U8-P28-T03](tickets/U8-P28-T03.md) | Split the retry engine, rate-limit fallback and lifetime budget tests | LIFECYCLE_DISPATCH | `orchestrator/retry_engine.ex` 1557; `orchestrator/retry_engine_test.exs` 1826; `orchestrator/rate_limit_fallback.ex` 763; `orchestrator/rate_limit_fallback_test.exs` 902; `orchestrator/lifetime_dispatch_budget_test.exs` 732 | U2 state contract | U2-T01, U2-T02, U2-T03, U6-T04 | — | 4 |
| [U8-P28-T04](tickets/U8-P28-T04.md) | Finish comment wake and comment polling below 500 after MP-R1-C9-T03 | LIFECYCLE_DISPATCH | `orchestrator/comment_wake.ex` 1718; `orchestrator/comment_wake_test.exs` 1554; `orchestrator/comment_polling.ex` 1057; `orchestrator/comment_polling/target_selection.ex` 526 | U2 state contract | U2-T01, U2-T02, MP-R1-C9-T03 | — | 4 |
| [U8-P28-T05](tickets/U8-P28-T05.md) | Split dispatch policy, push routing, operator messages and control-routing tests | LIFECYCLE_DISPATCH | `orchestrator/dispatch_policy.ex` 1298; `orchestrator/dispatch_policy_test.exs` 1156; `orchestrator/push_routing.ex` 1087; `orchestrator/operator_messages.ex` 1167; `orchestrator_control_routing_test.exs` 1012 | U2 state contract | MP-E1-C1-T05 | — | 4 |
| [U8-P28-T06](tickets/U8-P28-T06.md) | Finish the Orchestrator facade and State below 500 after MP-R1-C9 | LIFECYCLE_DISPATCH | `orchestrator.ex` 1010; `orchestrator/state.ex` 1037; `regression/orchestrator_blocking_http_test.exs` 1229; `regression/orchestrator_lifecycle_test.exs` 767 | U2 state contract | MP-R1-C9-T09, MP-E1-C1-T06 | — | 4 |
| [U8-P29-T01](tickets/U8-P29-T01.md) | Split the deactivate test suite by behavior | LIFECYCLE_STATUS | `orchestrator_deactivate_test.exs` 7657 | U0 test isolation contract (tests only) | — | — | 3 |
| [U8-P29-T02](tickets/U8-P29-T02.md) | Split the status report and status tests | LIFECYCLE_STATUS | `orchestrator/status_report.ex` 1489; `orchestrator/status_report_test.exs` 578; `orchestrator_status_test.exs` 4966 | U2/U6 state projection contract | U2-T04, U6-T04 | — | 4 |
| [U8-P29-T03](tickets/U8-P29-T03.md) | Split pause/resume and CI lifecycle | LIFECYCLE_STATUS | `orchestrator/pause_resume.ex` 2490; `orchestrator/auto_resume_test.exs` 527; `orchestrator/global_pause_test.exs` 520; `orchestrator/ci_lifecycle.ex` 1708; `orchestrator_ci_lifecycle_test.exs` 1733 | U2/U6 state projection contract | U2-T01, U4-T01, MP-E1-C1-T05 | — | 5 |
| [U8-P29-T04](tickets/U8-P29-T04.md) | Split control lifecycle, reconcilers and their tests | LIFECYCLE_STATUS | `orchestrator/control_lifecycle.ex` 950; `orchestrator/reconciler.ex` 845; `orchestrator/reconciler_test.exs` 1057; `orchestrator/merged_ticket_reconciler_test.exs` 532; `orchestrator/orphaned_workers_test.exs` 523; `orchestrator/rework_requeue_test.exs` 522 | U2/U6 state projection contract | U2-T02 | — | 4 |
| [U8-P29-T05](tickets/U8-P29-T05.md) | Split current-run stores, snapshots, workflow store and progress retention | LIFECYCLE_STATUS | `current_run_projections_test.exs` 1374; `current_run_membership_store_test.exs` 785; `orchestrator/snapshot_store.ex` 554; `workflow_store.ex` 542; `progress_retention.ex` 532; `coordination_tasks_test.exs` 510 | U2/U6 state projection contract | U6-T04 | — | 3 |
| [U8-P29-T06](tickets/U8-P29-T06.md) | Split the issue log, ticket activity projection, recent merge and open-ticket source | LIFECYCLE_STATUS | `issue_log.ex` 1049; `ticket_activity/projection.ex` 605; `recent_merge.ex` 558; `open_ticket_source.ex` 509; `open_ticket_source_test.exs` 524 | U2/U6 state projection contract | U2-T01 | — | 3 |
| [U8-P30-T01](tickets/U8-P30-T01.md) | Split the Linear client, or close on a U7 cut | LINEAR | `linear/client.ex` 599 | U7 integrations-03 decision | U7-T01 | — | 2 |
| [U8-P31-T01](tickets/U8-P31-T01.md) | Split OpenCode attach pool, slots, tmux and AgentList TUI tests | OPENCODE | `opencode/attach_pool.ex` 969; `opencode/slot.ex` 617; `opencode/slot_policy_test.exs` 527; `pane_manager_test.exs` 535; `tmux.ex` 571; `agent_list/renderer_test.exs` 1257; `agent_list/app_test.exs` 545 | U1 P0 check; U4 backend contract | — | — | 4 |
| [U8-P31-T02](tickets/U8-P31-T02.md) | Split the OpenCode session writer and live conversation | OPENCODE | `opencode/session_writer.ex` 817; `opencode/session_writer_test.exs` 560; `live_conversation.ex` 691; `live_conversation_test.exs` 1071; `live_e2e_test.exs` 802 | U4 backend contract | — | — | 4 |
| [U8-P32-T01](tickets/U8-P32-T01.md) | Split the website stylesheet and dashboard script | SITE | `website/src/styles.css` 815; `website/src/dashboard.ts` 688 | website dependency decision | — | — | 2 |
| [U8-P33-T01](tickets/U8-P33-T01.md) | Split the aiur-run skill, executor reference and skill helper scripts | SKILLS | `.claude/skills/aiur-run/SKILL.md` 1293; `.claude/skills/aiur-run/references/executor.md` 662; `.claude/skills/aiur-run/scripts/executor-retrospective.sh` 906; `.claude/skills/aiur-run/scripts/tests/executor-retrospective_test.sh` 859; `aiur_agent_skill_test.exs` 842; `.claude/skills/aiur-meta/scripts/capture-dashboard.mjs` 664; `.codex/skills/land/land_watch.py` 621 | U0 operator contract; BO_PUBLISH API | U8-P06-T01 | — | 3 |
| [U8-P34-T01](tickets/U8-P34-T01.md) | Split run telemetry: dataset, writer, sampler, lifecycle, dashboard | TELEMETRY | `run_telemetry/dataset.ex` 1264; `run_telemetry/dataset_test.exs` 773; `run_telemetry/writer.ex` 628; `run_telemetry/writer_test.exs` 935; `run_telemetry/sampler.ex` 867; `run_telemetry/sampler_test.exs` 548; `run_telemetry/lifecycle.ex` 557; `run_telemetry/dashboard.ex` 619 | U6 aggregate/freshness contract | — | — | 4 |
| [U8-P34-T02](tickets/U8-P34-T02.md) | Split usage envelope, grouped scopes, usage and provider-meter presenters | TELEMETRY | `usage_envelope.ex` 640; `usage/grouped_scopes.ex` 621; `operator_control_center/usage_summary_presenter.ex` 718; `usage_ledger/recovery_test.exs` 561; `usage/price_table_test.exs` 553; `provider_meter_probe_test.exs` 754; `provider_account_generation_test.exs` 663; `operator_control_center/provider_meters_presenter.ex` 531; `provider_meters_test.exs` 507 | U6 aggregate/freshness contract | — | — | 4 |
| [U8-P35-T01](tickets/U8-P35-T01.md) | Split the shared test support and test reset | TEST_HARNESS | `support/test_support.exs` 1664; `test_reset.ex` 847; `test_reset_test.exs` 632 | U0 test isolation contract | U2-T01 | — | 4 |
| [U8-P35-T02](tickets/U8-P35-T02.md) | Split core_test and extensions_test by behavior | TEST_HARNESS | `core_test.exs` 4130; `extensions_test.exs` 1880 | U0 test isolation contract | U8-P35-T01 | — | 3 |
| [U8-P36-T01](tickets/U8-P36-T01.md) | Split DashboardLive and its test suite | WEB | `live/dashboard_live.ex` 2960; `live/dashboard_live_test.exs` 6680 | U6 status/presenter contract | — | — | 5 |
| [U8-P36-T02](tickets/U8-P36-T02.md) | Split the operator control center run strip, units and presenter | WEB | `components/operator_control_center/run_summary_strip.ex` 791; `components/operator_control_center/run_summary_strip_test.exs` 1667; `operator_control_center_components_test.exs` 1550; `presenter.ex` 595; `presenter_test.exs` 695; `operator_control_center/units_row_test.exs` 597; `components/operator_control_center/units_table_test.exs` 519; `operator_control_center/units_presenter.ex` 501; `operator_control_center/units_presenter_test.exs` 524 | U6 status/presenter contract | U6-T04 | — | 4 |
| [U8-P36-T03](tickets/U8-P36-T03.md) | Split the analytics LiveView, presenter and charts | WEB | `operator_control_center/analytics/presenter.ex` 1101; `operator_control_center/analytics/charts.ex` 666; `live/analytics_live.ex` 714; `live/analytics_live_test.exs` 1154 | U6 status/presenter contract | U6-T05 | — | 3 |
| [U8-P37-T01](tickets/U8-P37-T01.md) | Move mixed workspace_and_config_test cases to their owning suites | WORKSPACE | `workspace_and_config_test.exs` 3648 | U2 lifecycle contract | — | — | 3 |
| [U8-P37-T02](tickets/U8-P37-T02.md) | Split RepoBase and WIP preservation | WORKSPACE | `repo_base.ex` 1539; `repo_base_test.exs` 1599; `workspace/wip_preservation.ex` 671; `workspace/wip_preservation_test.exs` 988 | U2 lifecycle contract; U7 workspace decisions | — | — | 4 |
| [U8-P37-T03](tickets/U8-P37-T03.md) | Split workspace ownership guardian, provisioner and lifecycle regression test | WORKSPACE | `workspace/ownership/guardian.ex` 819; `workspace/ownership_test.exs` 1244; `workspace/provisioner.ex` 777; `regression/workspace_lifecycle_test.exs` 847 | U2 lifecycle contract; U7 workspace decisions | U2-T05 | — | 4 |
| [U8-P00-T02](tickets/U8-P00-T02.md) | Close the U8 ledger: recount, adopt residue and hand the universal gate to U9 | all | (all) | all U8 tickets | all 73 other U8 tickets; MP-R1-C9-T14; MP-E5-C1-T02 | U9-T02 | 2 |

## Serialization cliques

Tickets in one clique must not be in progress at the same time. A clique sets no
order; an order is an edge in [edges.md](edges.md).

### Package single-writer cliques (proposal: one active writer per package)

- **U8-P00** (DECK_PKG, DOCS, SITE (lockfile rows)): U8-P00-T01, U8-P00-T02
- **U8-P01** (AGENT_CORE): U8-P01-T01, U8-P01-T02
- **U8-P02** (AGENT_TURN): U8-P02-T01, U8-P02-T02
- **U8-P06** (BO_PUBLISH): U8-P06-T01, U8-P06-T02
- **U8-P07** (BO_RUNTIME): U8-P07-T01, U8-P07-T02, U8-P07-T03
- **U8-P08** (BROWSER): U8-P08-T01, U8-P08-T02
- **U8-P12** (CLAUDE): U8-P12-T01, U8-P12-T02
- **U8-P13** (CLI): U8-P13-T01, U8-P13-T02
- **U8-P15** (CONFIG): U8-P15-T01, U8-P15-T02
- **U8-P16** (DECISIONS): U8-P16-T01, U8-P16-T02
- **U8-P19** (DECK_WEB): U8-P19-T01, U8-P19-T02
- **U8-P20** (DOCS): U8-P20-T01, U8-P20-T02
- **U8-P21** (EVENTS): U8-P21-T01, U8-P21-T02, U8-P21-T03
- **U8-P22** (GH_ACCESS): U8-P22-T01, U8-P22-T02, U8-P22-T03, U8-P22-T04
- **U8-P23** (GH_GUARD): U8-P23-T01, U8-P23-T02
- **U8-P25** (HIST_CE + HIST_PRODUCT): U8-P25-T01, U8-P25-T02
- **U8-P28** (LIFECYCLE_DISPATCH): U8-P28-T01, U8-P28-T02, U8-P28-T03, U8-P28-T04, U8-P28-T05, U8-P28-T06
- **U8-P29** (LIFECYCLE_STATUS): U8-P29-T01, U8-P29-T02, U8-P29-T03, U8-P29-T04, U8-P29-T05, U8-P29-T06
- **U8-P31** (OPENCODE): U8-P31-T01, U8-P31-T02
- **U8-P34** (TELEMETRY): U8-P34-T01, U8-P34-T02
- **U8-P35** (TEST_HARNESS): U8-P35-T01, U8-P35-T02
- **U8-P36** (WEB): U8-P36-T01, U8-P36-T02, U8-P36-T03
- **U8-P37** (WORKSPACE): U8-P37-T01, U8-P37-T02, U8-P37-T03

### Shared-file cliques with MP tickets and other units

| Shared file(s) | Members | Note |
| --- | --- | --- |
| `src/lib/aiur.ex` (APP_BOOT) | U8-P04-T01, MP-R7-C4-T01, MP-R2-C6-T02, MP-R2-C2-T07, MP-R1-C6-T03 | child-order changes go through APP_BOOT |
| `orchestrator/dispatcher.ex`, `issue_sync.ex`, `dispatch_policy.ex`, `state.ex`, `orchestrator.ex`, `comment_polling*.ex` | U8-P28-T01, -T02, -T04, -T05, -T06, MP-R1-C7-T08, MP-R1-C9-T01, -T02, -T03, -T07, -T08, -T09, MP-E1-C1-T02, -T05, -T06 | MP-E1-C1 hooks land first (RC-19); U8 rebases over them and keeps them |
| `orchestrator/pause_resume.ex`, `ci_lifecycle.ex`, `reconciler.ex`, `status_report.ex` | U8-P29-T02, -T03, -T04, MP-R1-C9-T06, -T08, -T09, -T14, MP-R2-C2-T09, MP-E2-C7-T03 | |
| `github/issues.ex`, `issue_state` tests, `dispatch_authorization.ex` | U8-P24-T01, MP-E1-C1-T01..T05 | E1-C1 first (RC-19) |
| `website/docs-app/apis/github.md` | U8-P20-T02, MP-R4-C1-T01, all GH behavior tickets | docs after behavior (proposal); read the page first |
| `events/subscription_store.ex`, `publisher.ex`, `executor_events.ex`, `alerts.ex` | U8-P21-T03, MP-R2-C2-T01, -T03, -T05, -T06, -T10, MP-R2-C3-T01, -T02 | MP-R2 tickets are shrink-only on these |
| `live/dashboard_live.ex` | U8-P36-T01, MP-R5-C2-T01, MP-E5-C2-T03, MP-E4-C5-T01, -T04, MP-E3-C6-T01 | MP tickets add new modules, never grow it |
| `streamdeck_channel.ex`, `streamdeck_projection.ex`, `streamdeck_logs.ex` | U8-P19-T01, -T02, MP-R5-C1-T01, -T03, MP-R6-C1-T01, MP-R6-C2-T01, MP-E4-C7-T01 | |
| `packaging/npm/aiur-cli/libexec/aiur-engine.sh` | U8-P13-T01, U1, MP-R2-C7-T04, MP-N2 | U1 P0 check first |
| `agent_control_cli.ex` | MP-R1-C9-T10..T14 only | U8 does not edit it |
| `decision_store.ex`, `decision_projection.ex`, `decision_event.ex` | U8-P16-T01, -T02, MP-E2-C1-T01, MP-R2-C2-T10 | |
| `repo_base.ex`, `workspace/ownership/guardian.ex`, `workspace/provisioner.ex` | U8-P37-T02, -T03, MP-R1-C7-T05 | MP-R1-C7-T05 says it must not run during a WORKSPACE split |
| `github/ci_readiness.ex`, `orchestrator/dispatcher.ex` | U8-P22-T03, U8-P28-T01, MP-R1-C7-T08 | |
| `.github/workflows/ci.yml` | U8-P11-T01, U0-T01 (gate install), MP-R1-C10-T04 | |
| `AGENTS.md` | U8-P20-T01, MP-R1-C10-T05 | |
| `workspace_and_config_test.exs` targets | U8-P37-T01, U8-P15-T02, U8-P30-T01 | P37-T01 moves cases into CONFIG/LINEAR suites |
| `website/src/styles.css` | U8-P32-T01, aiur-style build order (`docs/aiur-style/plan.md` §12) | aiur-style consolidates website components |

## Cross-ticket findings (from reading the code at `58854d4c8`)

These affect many tickets. Each ticket repeats the part that applies to it.

1. **Coverage ignore list — needs a U0 decision (OWNER-U8-COVER).** `src/mix.exs`
   sets an 85% coverage threshold and an `ignore_modules` list of about 89 entries.
   Many U8 targets are on it (for example `Aiur.Tmux`, `AttachPool`, `Slot`,
   `SessionWriter`, `IssueLog`, `Linear.Client`, `Orchestrator`, `DashboardLive`,
   `Presenter`, `Config`, `CodingAgent`, `EventHumanizer`, `Codeowners`). The plan
   forbids new ignore entries. Code that moves out of an ignored module into a new
   module then counts toward the threshold. Recommended rule for U0: a module
   extracted verbatim from an ignored parent may replace the parent's entry with its
   own entries, and the PR lists them; no module that was covered becomes ignored.
   Without a rule, a split PR can fail coverage with no behavior change.
2. **Test support loading.** `src/test/test_helper.exs` loads support files with
   `Code.require_file`, and `src/mix.exs` lists them in `test_ignore_filters`. A new
   support file needs both edits. U8-P35-T01 owns `test_support.exs`; U8-P29-T01 and
   U8-P12-T01 add support files and must coordinate with it.
3. **Browser specs are listed by name** in `src/browser/package.json`. A split spec
   that is not added there does not run, and CI stays green (U8-P08-T02, U8-P19-T01,
   U8-P27-T01).
4. **npm package `files` list.** New launcher modules must be in the npm manifest, or
   the installed `aiur` breaks (U8-P13-T01).
5. **Source-scan tests read files by path** (`File.read!` on `aiur-engine.sh`,
   `attach_pool.ex`, `slot.ex`, `session_writer.ex`, `dashboard.css`, skill files).
   They must point at the new files in the same PR.
6. **Line-anchor citations in docs** (for example `concepts/ticket-lifecycle.md`
   cites `pause_resume.ex` and `ci_lifecycle.ex` lines). Fix them in the same PR.
7. **No CI job runs the Build Order publication test suites** (U8-P06-T01); the
   ticket runs them by hand and records the command.
8. **The ELK engine file is marked `-text` in `.gitattributes`** but decodes as UTF-8,
   so the census counts it. U8-P27-T01 needs the U0 offline-asset decision.

## Decisions made without the owner

The operator was away. These are judgment calls; each is reversible by editing the
spec and regenerating the tickets.

1. **Granularity:** 74 tickets by module family and gate (above), not one per package
   (37) and not one per file (373).
2. **New-row owners:** the 16 new oversized paths got provisional owners (table
   above). `global_pause_test.exs` goes to LIFECYCLE_STATUS although `build.py` would
   say LIFECYCLE_DISPATCH, because pause/resume is status-owned. `accounts.ex` goes to
   AGENT_CORE; `build.py` would drop it into TEST_HARNESS by its fallback rule.
   `docs/aiur-style/plan.md` goes to HIST_CE, archived only after the aiur-style build
   order finishes, because agents still follow its §12 anchors.
3. **No duplicate tickets** for `agent_control_cli.ex` (+test) and
   `conversation-voice-controller.js`: MP-R1-C9-T10..T14 and MP-E5-C1-T02 own them.
4. **Order with MP tickets:** where an MP ticket restructures a file anyway, the MP
   ticket goes first and U8 finishes the residue (MP-R1-C4 → config.ex; MP-R1-C9-T03 →
   comment polling; MP-R1-C9-T09 → orchestrator.ex/state.ex; MP-R6-C1-T01 →
   streamdeck_logs; MP-E1-C1 → issues/issue_sync/dispatch_policy/dispatcher per
   RC-19). Where an MP ticket needs the split, U8 goes first (MP-R7-C4-T03 and -T04).
   Elsewhere only a conflict clique, no order.
5. **Lockfiles are an owner decision (OWNER-U8-LOCK),** not a split. Recommended:
   a narrow, tool-verified lockfile class in the U0 gate. That contradicts the plan's
   "no permanent exclusions", so it is not applied without the owner.
   Untracking lockfiles was rejected: it weakens supply-chain pinning.
6. **Vendored CE files (OWNER-U8-CE)** and **design extracts/prototypes
   (OWNER-U8-DESIGN)** are blocked on owner decisions. Local edits would fork
   pinned upstream bytes.
7. **U7-gated rows** (Claude Remote Control + REPL test, Linear client) are separate
   tickets that close with no split if U7 cuts the feature.
8. **Ledger refresh stays with U0.** This pack does not edit `assignments.csv`
   (MP-R1-C11-T02: consumers never edit it). U0-T02 adopts "New rows".
9. **U8-P12-T02** waits only on U0. The U7 Remote Control decision gates only the
   session code and `repl_agent_test.exs`; the process-kill block moves anyway, and it
   follows MP-R1-C5-T02's names so the two tickets do not create it twice.
10. **Coverage rule (finding 1)** is raised to U0 as OWNER-U8-COVER with a
   recommendation; no ticket adds an ignore entry on its own.
11. **Private data:** two Build Order docs and two analytics fixtures hold a private
   network address or a per-user path. The tickets name the problem without quoting
   the values, and U8-P03-T01 and U8-P05-T01 remove them.
12. **`ponytail` skill** was not loaded at session start. It was read from the plugin
   cache later and applied: fewer tickets, reuse of existing MP tickets, and no cut to
   validation, error handling or security in any ticket.

