# U8 dependency edges

New edges this pack adds (`from` must finish before `to`). `U0-T01 → every U8
ticket` is one edge per ticket; it is listed once here. Conflict cliques (no order) are in
[README.md](README.md#serialization-cliques).

| From | To | Kind | Reason |
| --- | --- | --- | --- |
| U0-T01 | every U8-Pxx-Tyy (74) | gate | U0 review gate |
| U0-T02 | every U8-Pxx-Tyy (74) | gate | refreshed owner ledger (adopts the 16 new rows) |
| U0-T03 | every U8-Pxx-Tyy (74) | gate | transitional 500-line gate |
| OWNER-U8-LOCK | U8-P00-T01 | owner decision | Decide and apply the tracked-lockfile disposition |
| U8-P01-T01 | MP-R7-C4-T03 | U8 first | MP-R7-C4-T03 moves the file; the transitional gate rejects a moved file above 500 |
| U2-T01 | U8-P02-T01 | U ticket edits file first | Split the agent runner core: runner, message handler, turn loop, tool executor |
| U4-T01 | U8-P02-T01 | U ticket edits file first | Split the agent runner core: runner, message handler, turn loop, tool executor |
| U4-T02 | U8-P02-T01 | U ticket edits file first | Split the agent runner core: runner, message handler, turn loop, tool executor |
| U4-T01 | U8-P02-T02 | U ticket edits file first | Split session lifecycle, queue drain, queue store and shared app-server tests |
| U4-T02 | U8-P02-T02 | U ticket edits file first | Split session lifecycle, queue drain, queue store and shared app-server tests |
| OWNER-U8-DESIGN | U8-P05-T01 | owner decision | Retire Build Order prototypes and split the handoff and chat records |
| U8-P06-T01 | U8-P06-T02 | U8 order | Regenerate or split Build Order pack JSON and the demo pack |
| OWNER-U8-CE | U8-P10-T01 | owner decision | Stop tracking oversized vendored Compound Engineering files |
| U1-T03 | U8-P11-T01 | U ticket edits file first | Split CI and npm release workflows without renaming required jobs |
| U4-T03 | U8-P12-T01 | U ticket edits file first | Split Claude telemetry and the Claude coding agent |
| U8-P12-T01 | MP-R7-C4-T04 | U8 first | MP-R7-C4-T04 moves the file; the transitional gate rejects a moved file above 500 |
| U8-P12-T02 | MP-R7-C4-T04 | U8 first | MP-R7-C4-T04 moves the file; the transitional gate rejects a moved file above 500 |
| U1-T02 | U8-P13-T01 | U ticket edits file first | Split aiur-engine.sh into sourced libexec modules and split its tests |
| U1-T03 | U8-P13-T01 | U ticket edits file first | Split aiur-engine.sh into sourced libexec modules and split its tests |
| U8-P13-T01 | U8-P13-T02 | U8 order | Split the aiurdev shim, launcher test and Aiur.CLI |
| U8-P14-T01 | MP-R7-C4-T04 | U8 first | MP-R7-C4-T04 moves the file; the transitional gate rejects a moved file above 500 |
| MP-R1-C4-T01 | U8-P15-T01 | MP first | Finish Aiur.Config and the agent schema below 500 after MP-R1-C4 |
| MP-R1-C4-T02 | U8-P15-T01 | MP first | Finish Aiur.Config and the agent schema below 500 after MP-R1-C4 |
| MP-R1-C4-T03 | U8-P15-T01 | MP first | Finish Aiur.Config and the agent schema below 500 after MP-R1-C4 |
| U6-T01 | U8-P16-T01 | U ticket edits file first | Split DecisionStore and its test suite |
| U6-T02 | U8-P16-T01 | U ticket edits file first | Split DecisionStore and its test suite |
| U6-T02 | U8-P16-T02 | U ticket edits file first | Split decision event, projection, history, attention and their tests |
| U8-P16-T01 | U8-P16-T02 | U8 order | Split decision event, projection, history, attention and their tests |
| OWNER-U8-DESIGN | U8-P17-T01 | owner decision | Re-extract the Stream Deck design source in modules |
| MP-R6-C1-T01 | U8-P19-T02 | MP first | Finish StreamdeckLogs below 500 after MP-R6-C1-T01 |
| U5-T01 | U8-P20-T02 | U ticket edits file first | Split apis/github.md after the GitHub behavior splits |
| U5-T04 | U8-P20-T02 | U ticket edits file first | Split apis/github.md after the GitHub behavior splits |
| U5-T05 | U8-P20-T02 | U ticket edits file first | Split apis/github.md after the GitHub behavior splits |
| U8-P22-T01 | U8-P20-T02 | U8 order | Split apis/github.md after the GitHub behavior splits |
| U8-P22-T02 | U8-P20-T02 | U8 order | Split apis/github.md after the GitHub behavior splits |
| U8-P22-T03 | U8-P20-T02 | U8 order | Split apis/github.md after the GitHub behavior splits |
| U8-P22-T04 | U8-P20-T02 | U8 order | Split apis/github.md after the GitHub behavior splits |
| U8-P23-T01 | U8-P20-T02 | U8 order | Split apis/github.md after the GitHub behavior splits |
| U8-P23-T02 | U8-P20-T02 | U8 order | Split apis/github.md after the GitHub behavior splits |
| U8-P24-T01 | U8-P20-T02 | U8 order | Split apis/github.md after the GitHub behavior splits |
| U5-T03 | U8-P21-T01 | U ticket edits file first | Split webhook ingress: deposit, normalizer, mode registry and webhook tests |
| U3-T01 | U8-P21-T03 | U ticket edits file first | Split subscriptions, publisher, alerts, wake inbox and executor events |
| U3-T03 | U8-P21-T03 | U ticket edits file first | Split subscriptions, publisher, alerts, wake inbox and executor events |
| U5-T03 | U8-P22-T01 | U ticket edits file first | Split the GitHub resource store |
| U5-T04 | U8-P22-T01 | U ticket edits file first | Split the GitHub resource store |
| U5-T04 | U8-P22-T02 | U ticket edits file first | Split GitHub quota and budget |
| U5-T01 | U8-P22-T03 | U ticket edits file first | Split CI readiness, pull requests and the poll batches |
| U5-T01 | U8-P22-T04 | U ticket edits file first | Split the read cache, its policy, transport and ingestion tests |
| U5-T04 | U8-P22-T04 | U ticket edits file first | Split the read cache, its policy, transport and ingestion tests |
| U5-T01 | U8-P24-T01 | U ticket edits file first | Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS |
| U5-T02 | U8-P24-T01 | U ticket edits file first | Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS |
| U5-T03 | U8-P24-T01 | U ticket edits file first | Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS |
| MP-E1-C1-T01 | U8-P24-T01 | MP first | Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS |
| MP-E1-C1-T02 | U8-P24-T01 | MP first | Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS |
| MP-E1-C1-T03 | U8-P24-T01 | MP first | Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS |
| MP-E1-C1-T04 | U8-P24-T01 | MP first | Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS |
| MP-E1-C1-T05 | U8-P24-T01 | MP first | Split GitHub issues, config, auth preflight, dispatch authorization and CODEOWNERS |
| U8-P25-T01 | U8-P25-T02 | U8 order | Archive the aiur-style plan after its build order finishes |
| AIUR-STYLE-DONE | U8-P25-T02 | external | Archive the aiur-style plan after its build order finishes |
| U2-T01 | U8-P28-T01 | U ticket edits file first | Split the dispatcher and its test suites |
| MP-E1-C1-T05 | U8-P28-T01 | MP first | Split the dispatcher and its test suites |
| MP-E1-C1-T06 | U8-P28-T01 | MP first | Split the dispatcher and its test suites |
| U2-T01 | U8-P28-T02 | U ticket edits file first | Split issue sync and its test suite |
| U2-T02 | U8-P28-T02 | U ticket edits file first | Split issue sync and its test suite |
| MP-E1-C1-T02 | U8-P28-T02 | MP first | Split issue sync and its test suite |
| MP-E1-C1-T05 | U8-P28-T02 | MP first | Split issue sync and its test suite |
| MP-E1-C1-T06 | U8-P28-T02 | MP first | Split issue sync and its test suite |
| U2-T01 | U8-P28-T03 | U ticket edits file first | Split the retry engine, rate-limit fallback and lifetime budget tests |
| U2-T02 | U8-P28-T03 | U ticket edits file first | Split the retry engine, rate-limit fallback and lifetime budget tests |
| U2-T03 | U8-P28-T03 | U ticket edits file first | Split the retry engine, rate-limit fallback and lifetime budget tests |
| U6-T04 | U8-P28-T03 | U ticket edits file first | Split the retry engine, rate-limit fallback and lifetime budget tests |
| U2-T01 | U8-P28-T04 | U ticket edits file first | Finish comment wake and comment polling below 500 after MP-R1-C9-T03 |
| U2-T02 | U8-P28-T04 | U ticket edits file first | Finish comment wake and comment polling below 500 after MP-R1-C9-T03 |
| MP-R1-C9-T03 | U8-P28-T04 | MP first | Finish comment wake and comment polling below 500 after MP-R1-C9-T03 |
| MP-E1-C1-T05 | U8-P28-T05 | MP first | Split dispatch policy, push routing, operator messages and control-routing tests |
| MP-R1-C9-T09 | U8-P28-T06 | MP first | Finish the Orchestrator facade and State below 500 after MP-R1-C9 |
| MP-E1-C1-T06 | U8-P28-T06 | MP first | Finish the Orchestrator facade and State below 500 after MP-R1-C9 |
| U2-T04 | U8-P29-T02 | U ticket edits file first | Split the status report and status tests |
| U6-T04 | U8-P29-T02 | U ticket edits file first | Split the status report and status tests |
| U2-T01 | U8-P29-T03 | U ticket edits file first | Split pause/resume and CI lifecycle |
| U4-T01 | U8-P29-T03 | U ticket edits file first | Split pause/resume and CI lifecycle |
| MP-E1-C1-T05 | U8-P29-T03 | MP first | Split pause/resume and CI lifecycle |
| U2-T02 | U8-P29-T04 | U ticket edits file first | Split control lifecycle, reconcilers and their tests |
| U6-T04 | U8-P29-T05 | U ticket edits file first | Split current-run stores, snapshots, workflow store and progress retention |
| U2-T01 | U8-P29-T06 | U ticket edits file first | Split the issue log, ticket activity projection, recent merge and open-ticket source |
| U7-T01 | U8-P30-T01 | U7 decision | Split the Linear client, or close on a U7 cut |
| U8-P06-T01 | U8-P33-T01 | U8 order | Split the aiur-run skill, executor reference and skill helper scripts |
| U2-T01 | U8-P35-T01 | U ticket edits file first | Split the shared test support and test reset |
| U8-P35-T01 | U8-P35-T02 | U8 order | Split core_test and extensions_test by behavior |
| U6-T04 | U8-P36-T02 | U ticket edits file first | Split the operator control center run strip, units and presenter |
| U6-T05 | U8-P36-T03 | U ticket edits file first | Split the analytics LiveView, presenter and charts |
| U2-T05 | U8-P37-T03 | U ticket edits file first | Split workspace ownership guardian, provisioner and lifecycle regression test |
| every other U8 ticket (73) | U8-P00-T02 | join | ledger close |
| MP-R1-C9-T14 | U8-P00-T02 | MP first | owns the `agent_control_cli.ex` split |
| MP-E5-C1-T02 | U8-P00-T02 | MP first | owns the `conversation-voice-controller.js` split |
| U8-P00-T02 | U9-T02 | join | integrated acceptance and before/after census |
| U7-T01 | U8-P12-T02 | U7 decision (conditional) | gates only the Remote Control session code and its REPL test |
| OWNER-U8-COVER | every U8 code ticket | owner decision | coverage ignore-list rule (README cross-ticket finding 1); resolved inside U0-T01 |

## Edges to retire in other tickets' text

- MP-R7-C4-T03 `blocked_by` "U8 AGENT_CORE split of coding_agent.ex" = **U8-P01-T01**.
- MP-R7-C4-T04 `blocked_by` "U8 CLAUDE splits" = **U8-P12-T01** and **U8-P12-T02**; "U8 CODEX split" = **U8-P14-T01**.
- MP-E5-C1-T02 "coordinate with U8": U8 makes no BROWSER ticket for that file; E5-C1-T02 is the owner.
- MP-R1-C11-T02 Procedure B: look up `size_owner` in this README's ticket table (by path) as well as the ledger.
