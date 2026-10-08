# U8-ACC — U8 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** U8-P00-T02

## Outcome

The Executor proves U8 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/U8/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (74)

- U8-P00-T01 — Decide and apply the tracked-lockfile disposition
- U8-P00-T02 — Close the U8 ledger: recount, adopt residue and hand the universal gate to U9
- U8-P01-T01 — Split CodingAgent into registry, contract and dispatch modules
- U8-P01-T02 — Split agent environment, process log, model discovery and accounts
- U8-P02-T01 — Split the agent runner core: runner, message handler, turn loop, tool executor
- U8-P02-T02 — Split session lifecycle, queue drain, queue store and shared app-server tests
- U8-P03-T01 — Split the offline analytics reducer and renderer; shrink fixtures
- U8-P04-T01 — Split the application module child specs and the application test
- U8-P05-T01 — Retire Build Order prototypes and split the handoff and chat records
- U8-P06-T01 — Make one canonical publication script tree and split its modules
- U8-P06-T02 — Regenerate or split Build Order pack JSON and the demo pack
- U8-P07-T01 — Split Build Order graph projection and GitHub graph tests
- U8-P07-T02 — Split Build Order ticket detail, history and context presenter
- U8-P07-T03 — Split planning source, pack status, Build Order presenter and LiveView test
- U8-P08-T01 — Split dashboard.css into assembled per-surface sheets
- U8-P08-T02 — Split the browser fixture server, docs capture fixture and units browser spec
- U8-P09-T01 — Split the build gate script, holder and Elixir wrapper
- U8-P10-T01 — Stop tracking oversized vendored Compound Engineering files
- U8-P11-T01 — Split CI and npm release workflows without renaming required jobs
- U8-P12-T01 — Split Claude telemetry and the Claude coding agent
- U8-P12-T02 — Split Claude Remote Control and the REPL agent test, or close on a U7 cut
- U8-P13-T01 — Split aiur-engine.sh into sourced libexec modules and split its tests
- U8-P13-T02 — Split the aiurdev shim, launcher test and Aiur.CLI
- U8-P14-T01 — Split the Codex event humanizer and Codex tests
- U8-P15-T01 — Finish Aiur.Config and the agent schema below 500 after MP-R1-C4
- U8-P15-T02 — Split the init and env test suites
- U8-P16-T01 — Split DecisionStore and its test suite
- U8-P16-T02 — Split decision event, projection, history, attention and their tests
- U8-P17-T01 — Re-extract the Stream Deck design source in modules
- U8-P18-T01 — Split the Stream Deck controller, art segments, main, rasterizer and channel
- U8-P19-T01 — Split StreamdeckLive, the channel, projection and emulator
- U8-P19-T02 — Finish StreamdeckLogs below 500 after MP-R6-C1-T01
- U8-P20-T01 — Split SPEC.md, src/README.md, AGENTS.md and two docs-app pages
- U8-P20-T02 — Split apis/github.md after the GitHub behavior splits
- U8-P21-T01 — Split webhook ingress: deposit, normalizer, mode registry and webhook tests
- U8-P21-T02 — Split the GitHub comments and CI pollers
- U8-P21-T03 — Split subscriptions, publisher, alerts, wake inbox and executor events
- U8-P22-T01 — Split the GitHub resource store
- U8-P22-T02 — Split GitHub quota and budget
- U8-P22-T03 — Split CI readiness, pull requests and the poll batches
- U8-P22-T04 — Split the read cache, its policy, transport and ingestion tests
- U8-P23-T01 — Split the GitHub quota and push guard scripts and the guard test
- U8-P23-T02 — Split github_budget.py and the GitHub client test
- U8-P24-T01 — Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS
- U8-P25-T01 — Archive historical plans as path-preserving short indexes (HIST_CE and HIST_PRODUCT)
- U8-P25-T02 — Archive the aiur-style plan after its build order finishes
- U8-P27-T01 — Build the ELK worker from a pinned package and split the layout worker spec
- U8-P28-T01 — Split the dispatcher and its test suites
- U8-P28-T02 — Split issue sync and its test suite
- U8-P28-T03 — Split the retry engine, rate-limit fallback and lifetime budget tests
- U8-P28-T04 — Finish comment wake and comment polling below 500 after MP-R1-C9-T03
- U8-P28-T05 — Split dispatch policy, push routing, operator messages and control-routing tests
- U8-P28-T06 — Finish the Orchestrator facade and State below 500 after MP-R1-C9
- U8-P29-T01 — Split the deactivate test suite by behavior
- U8-P29-T02 — Split the status report and status tests
- U8-P29-T03 — Split pause/resume and CI lifecycle
- U8-P29-T04 — Split control lifecycle, reconcilers and their tests
- U8-P29-T05 — Split current-run stores, snapshots, workflow store and progress retention
- U8-P29-T06 — Split the issue log, ticket activity projection, recent merge and open-ticket source
- U8-P30-T01 — Split the Linear client, or close on a U7 cut
- U8-P31-T01 — Split OpenCode attach pool, slots, tmux and AgentList TUI tests
- U8-P31-T02 — Split the OpenCode session writer and live conversation
- U8-P32-T01 — Split the website stylesheet and dashboard script
- U8-P33-T01 — Split the aiur-run skill, executor reference and skill helper scripts
- U8-P34-T01 — Split run telemetry: dataset, writer, sampler, lifecycle, dashboard
- U8-P34-T02 — Split usage envelope, grouped scopes, usage and provider-meter presenters
- U8-P35-T01 — Split the shared test support and test reset
- U8-P35-T02 — Split core_test and extensions_test by behavior
- U8-P36-T01 — Split DashboardLive and its test suite
- U8-P36-T02 — Split the operator control center run strip, units and presenter
- U8-P36-T03 — Split the analytics LiveView, presenter and charts
- U8-P37-T01 — Move mixed workspace_and_config_test cases to their owning suites
- U8-P37-T02 — Split RepoBase and WIP preservation
- U8-P37-T03 — Split workspace ownership guardian, provisioner and lifecycle regression test

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
