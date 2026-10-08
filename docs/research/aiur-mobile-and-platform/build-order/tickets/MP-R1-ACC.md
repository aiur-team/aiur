# MP-R1-ACC — MP-R1 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-R1-C1-T06, MP-R1-C3-T04, MP-R1-C3-T05, MP-R1-C3-T06, MP-R1-C3-T07, MP-R1-C4-T02, MP-R1-C4-T03, MP-R1-C4-T04, MP-R1-C4-T05, MP-R1-C5-T01, MP-R1-C5-T04, MP-R1-C5-T05, MP-R1-C5-T06, MP-R1-C6-T02, MP-R1-C6-T04, MP-R1-C7-T05, MP-R1-C7-T08, MP-R1-C8-T02, MP-R1-C8-T04, MP-R1-C8-T06, MP-R1-C8-T09, MP-R1-C10-T05

## Outcome

The Executor proves MP-R1 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-R1/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (69)

- MP-R1-C1-T01 — Component manifest, schema and file-ownership check in the required lint job
- MP-R1-C1-T02 — Elixir module-reference walker with undeclared-dependency and private-module rules behind a ratchet allowlist
- MP-R1-C1-T03 — Layer (R-down) and required-to-optional (R-optional) rules with cycle report
- MP-R1-C1-T04 — TypeScript import walker for packages/* and the R-client rule
- MP-R1-C1-T05 — Ratchet enforcement - stale allowlist entries fail, remove-only update mode, CI summary
- MP-R1-C1-T06 — Absorb MP-E1's build-queue source-scan test into manifest seam rules (RC-11, X-1)
- MP-R1-C2-T01 — Machine identity store created at first daemon boot (identity.json, no-clobber, no silent regeneration)
- MP-R1-C2-T02 — Aiur.Identity facade - instance_id from AIUR_INSTANCE_KEY, machine and instance sections
- MP-R1-C3-T01 — Capability registry - provider behaviour, crash-proof table, monitor, report assembly with boot_id and revision
- MP-R1-C3-T02 — Core capability providers - api.http, orchestration, agents, commands, tracker/repository, executor
- MP-R1-C3-T03 — GET /api/v1/capabilities, typed capability_unavailable error encoder, and the Capabilities concepts page
- MP-R1-C3-T04 — aiur capabilities [--json] control verb, aiurdev routing, and CLI reference entry
- MP-R1-C3-T05 — Publish system.capabilities.changed on every revision change
- MP-R1-C3-T06 — packages/aiur-contracts - JSON Schema and TypeScript types for identity and capabilities, with a cross-language golden test
- MP-R1-C3-T07 — Optional-component capability providers - build orders, voice, Stream Deck, webhooks, Remote Control, accounting, conversations
- MP-R1-C4-T01 — Registered semantic config checks - Aiur.Config.validate!/0 stops calling GitHub, Claude and Opencode config modules
- MP-R1-C4-T02 — Registered turn-sandbox root contributors - codex runtime settings stop calling AgentEnvironment, GitHub.Budget and BuildGate
- MP-R1-C4-T03 — Move feature accessors out of Aiur.Config and pure helpers down into config (build-order options, max turns, poll widening, allow-list parsing, Codex approval policy, project identity source)
- MP-R1-C4-T04 — Environment and global-config startup edges - Dotenv parser down, credential checks registered, GlobalConfigStartup reassigned to github
- MP-R1-C4-T05 — Config, env-var and state ownership in the manifest, with checker rules that every section and env var has exactly one owner
- MP-R1-C5-T01 — Rename the crash-safe append journal Aiur.DecisionLog to kernel Aiur.Journal and update its 17 callers
- MP-R1-C5-T02 — Kernel helpers - Bounded and process signalling (kill, tree, process groups, pidfd reaping) move into the kernel; MapAccess and CoordinationTasks reassigned
- MP-R1-C5-T03 — Signal port - Aiur.Signal alert and refresh with a registered sink; Alerts becomes the sink; core stops calling AiurWeb.ObservabilityPubSub
- MP-R1-C5-T04 — Lifecycle telemetry through the signal port; Perf and LogFile reassigned to the signal component
- MP-R1-C5-T05 — Migrate alert emitters outside the orchestrator (39 files, 69 sites) from Aiur.Alerts to Aiur.Signal
- MP-R1-C5-T06 — Migrate orchestrator alert emitters (22 files, 91 sites) from Aiur.Alerts to Aiur.Signal
- MP-R1-C6-T01 — Split AiurWeb.Router into component-owned route modules composed in a fixed order
- MP-R1-C6-T02 — Endpoint socket registration — components contribute their socket mounts
- MP-R1-C6-T03 — Internal run shape with the HTTP listener and JSON API but without dashboard pages
- MP-R1-C6-T04 — Operator launch flag for the API-without-pages run shape
- MP-R1-C7-T01 — Split the Tracker contract into IssueTracker and CodeHost ports
- MP-R1-C7-T02 — Register tracker adapters instead of naming them in a case
- MP-R1-C7-T03 — Give the agent sandbox a boundary below the backends and the workspace (non-GitHub edges)
- MP-R1-C7-T04 — Move the GitHub parts of the agent environment behind a registered contributor
- MP-R1-C7-T05 — Give the workspace component a boundary (GitHub preflight, attention, process kill, ledger validation)
- MP-R1-C7-T06 — Declare the GitHub family as one logical component and remove its upward edges (KTD11, no new package)
- MP-R1-C7-T07 — Route Dispatcher's candidate fetch, blocked_by hydration and revalidation retry through the tracker facade
- MP-R1-C7-T08 — Extract Dispatcher's CI-readiness gate and remove its remaining direct GitHub calls
- MP-R1-C8-T01 — Commands component facade (Aiur.Commands) and external caller migration
- MP-R1-C8-T02 — Invert Command answer delivery into an orchestration-provided delivery target port
- MP-R1-C8-T03 — Projections component — move the Units row model and policy out of the web namespace
- MP-R1-C8-T04 — Projections component — remaining edges (orchestrator snapshot read, configured repository) and manifest reassignments
- MP-R1-C8-T05 — Move the display sanitizer out of build-orders into kernel so conversations stop depending on build-orders
- MP-R1-C8-T06 — Conversations component — read facade (Aiur.Conversation.History) over transcripts, bus log and anchors
- MP-R1-C8-T07 — Build-orders component — cut the GitHub family's references into build-order modules
- MP-R1-C8-T08 — Build-orders component — declared facades, component-owned child specs, and a separate ticket-context component
- MP-R1-C8-T09 — Move the build queue from its wave-0 seam to its final component shape
- MP-R1-C9-T01 — GitHub listener supervisor and the firehose listener (firehose cursor fields leave Orchestrator.State)
- MP-R1-C9-T02 — Comment poll reads plain inputs and one nested cursor struct instead of Orchestrator.State (in place, no process change)
- MP-R1-C9-T03 — Comments listener process owns the comment-poll cursor and the owned-poll protocol
- MP-R1-C9-T04 — PR command-scan listener owns the repo-wide command-scan cursor
- MP-R1-C9-T05 — Move PRHealthScanner out of the Orchestrator namespace into the pr-lifecycle component
- MP-R1-C9-T06 — Move ReworkRequeue out of the Orchestrator namespace into pr-lifecycle (after U2 names the transition owner)
- MP-R1-C9-T07 — Orchestrator.State field-owner table, owner map in code, and a write-site ratchet test
- MP-R1-C9-T08 — Remove non-transition facade back-calls (sub-modules call their sibling owner directly)
- MP-R1-C9-T09 — Transition back-calls return effects to U2's lifecycle owner instead of calling the Orchestrator facade
- MP-R1-C9-T10 — Control-CLI kernel — extract the RPC output protocol and the shared reason renderer from AgentControlCLI
- MP-R1-C9-T11 — Move the Executor verbs (executor-emit/-subscribe/-listen/-wait/-roster/-claim/-release/-revoke/-fast-forward) into the executor-attention component
- MP-R1-C9-T12 — Move the control verbs (pause, resume, reset-budget, global pause/resume, message, set max-agents) into the orchestration component's control CLI
- MP-R1-C9-T13 — Move the --todo verb into the orchestration component; keep MP-E1's queue verb on its own module
- MP-R1-C9-T14 — Move the read verbs (status, agents, watch, alerts, usage) to their components after U6's shared status read model
- MP-R1-C10-T01 — Public manifest fields and the generated planned-features list in components.json
- MP-R1-C10-T02 — Build-time VitePress data loader for the component directory, and an unlisted placeholder page
- MP-R1-C10-T03 — Render the component directory to the approved DESIGN-R1 page design
- MP-R1-C10-T04 — Docs-sync rules in check-components.py, run on docs-only PRs, and rebuild docs on manifest changes
- MP-R1-C10-T05 — Publish the component directory page (sidebar, AGENTS.md docs rule, go-live)
- MP-R1-C11-T01 — Plan-refresh tool — path map, stale citations and size owners between two commits
- MP-R1-C11-T02 — Per-move plan refresh and ticket-start size-owner resolution (recurring runbook)
- MP-R1-C11-T03 — Final post-refactor plan refresh — gate before wave 2 (MP-E2) and before the directory page goes live

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
