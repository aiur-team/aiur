# Review findings by boundary

This is a navigation view over [findings.json](findings.json) for frozen `3339b887`. The first cited source location chooses a primary boundary; every cited location adds an affected boundary. A finding can therefore appear in more than one boundary, and the affected counts below must not be summed. Module-name rules are in `tooling/boundary-map.json`; non-Elixir analytics, Stream Deck, website and skills have explicit path rules in `tooling/review_synthesis.py`.

| Boundary | Primary items | Affected items | P0/P1 affected | Selected high-priority IDs |
| --- | ---: | ---: | ---: | --- |
| Dev/test harness & mix tasks (`DEV`) | 63 | 108 | 3 | [loose-3-06](raw/loose-3.json), [tests-1a-cont-01](raw/tests-1a.json), [tests-1c-01](raw/tests-1c.json) |
| Build Order (`BO`) | 70 | 102 | 8 | [build-order-01](raw/build-order.json), [build-order-02](raw/build-order.json), [build-order-03](raw/build-order.json), [build-order-04](raw/build-order.json) |
| Agent runner runtime (`RUN`) | 59 | 99 | 17 | [agent-backends-oc-02](raw/agent-backends-oc.json), [nonelixir-shell-01](raw/nonelixir-shell.json), [agent-backends-cc-03](raw/agent-backends-cc.json), [agent-runtime-01](raw/agent-runtime.json) |
| Orchestrator core (`ORC`) | 39 | 94 | 14 | [agent-backends-oc-11](raw/agent-backends-oc.json), [agent-runtime-02](raw/agent-runtime.json), [github-a-01](raw/github-a.json), [loose-4-01](raw/loose-4.json) |
| Dashboard (Phoenix) (`WEB`) | 65 | 92 | 9 | [agent-backends-oc-11](raw/agent-backends-oc.json), [web-occ-04](raw/web-occ.json), [web-occ-05](raw/web-occ.json), [web-occ-06](raw/web-occ.json) |
| Dispatch & admission (`DSP`) | 25 | 75 | 8 | [events-webhooks-executor-03](raw/events-webhooks-executor.json), [loose-1-02](raw/loose-1.json), [loose-2-03](raw/loose-2.json), [loose-3-01](raw/loose-3.json) |
| GitHub tracker domain (`GHD`) | 40 | 75 | 9 | [github-a-01](raw/github-a.json), [github-a-02](raw/github-a.json), [github-a-04](raw/github-a.json), [github-a-07](raw/github-a.json) |
| Agent skills and prompts (`SKILL`) | 70 | 74 | 0 | — |
| Control plane / CLI / daemon lifecycle (`CLI`) | 47 | 73 | 8 | [nonelixir-shell-01](raw/nonelixir-shell.json), [loose-2-02](raw/loose-2.json), [loose-2-07](raw/loose-2.json), [loose-3-05](raw/loose-3.json) |
| Decisions (`DEC`) | 41 | 69 | 5 | [loose-1-02](raw/loose-1.json), [loose-1-03](raw/loose-1.json), [loose-2-05](raw/loose-2.json), [loose-2-07](raw/loose-2.json) |
| GitHub event ingestion (`ING`) | 34 | 68 | 5 | [events-webhooks-executor-03](raw/events-webhooks-executor.json), [events-webhooks-executor-04](raw/events-webhooks-executor.json), [events-webhooks-executor-05](raw/events-webhooks-executor.json), [github-b-02](raw/github-b.json) |
| GitHub budget governor (`GHB`) | 27 | 58 | 1 | [github-b-04](raw/github-b.json) |
| Config & workflow (`CFG`) | 17 | 52 | 7 | [agent-backends-cc-02](raw/agent-backends-cc.json), [loose-2-07](raw/loose-2.json), [loose-3-01](raw/loose-3.json), [loose-3-03](raw/loose-3.json) |
| PR/CI/review lifecycle (`PRL`) | 20 | 52 | 4 | [events-webhooks-executor-03](raw/events-webhooks-executor.json), [loose-4-03](raw/loose-4.json), [orch-a-01](raw/orch-a.json), [orch-a-04](raw/orch-a.json) |
| GitHub client/auth (`GHC`) | 19 | 51 | 5 | [github-a-01](raw/github-a.json), [github-a-02](raw/github-a.json), [github-a-04](raw/github-a.json), [github-a-07](raw/github-a.json) |
| GitHub resource store & read cache (`GHR`) | 24 | 51 | 4 | [events-webhooks-executor-04](raw/events-webhooks-executor.json), [github-b-02](raw/github-b.json), [github-b-03](raw/github-b.json), [tests-2-01](raw/tests-2.json) |
| Executor attention (wake/alerts) (`EXE`) | 23 | 50 | 8 | [events-webhooks-executor-02](raw/events-webhooks-executor.json), [loose-2-02](raw/loose-2.json), [loose-2-04](raw/loose-2.json), [loose-2-05](raw/loose-2.json) |
| Claude backend (`CLD`) | 28 | 48 | 8 | [agent-backends-cc-01](raw/agent-backends-cc.json), [agent-backends-cc-02](raw/agent-backends-cc.json), [agent-backends-cc-03](raw/agent-backends-cc.json), [agent-backends-cc-04](raw/agent-backends-cc.json) |
| Terminal UI (tmux) (`TUI`) | 27 | 48 | 2 | [agent-runtime-07](raw/agent-runtime.json), [nonelixir-shell-03](raw/nonelixir-shell.json) |
| Pause/resume & control lifecycle (`CTL`) | 18 | 46 | 5 | [agent-backends-cc-08](raw/agent-backends-cc.json), [agent-runtime-01](raw/agent-runtime.json), [orch-b-02](raw/orch-b.json), [orch-b-08](raw/orch-b.json) |
| opencode integration (`OC`) | 28 | 46 | 10 | [agent-backends-oc-01](raw/agent-backends-oc.json), [agent-backends-cc-03](raw/agent-backends-cc.json), [agent-backends-oc-03](raw/agent-backends-oc.json), [agent-backends-oc-06](raw/agent-backends-oc.json) |
| Current-run read models (`PRJ`) | 20 | 45 | 4 | [loose-2-07](raw/loose-2.json), [orch-a-01](raw/orch-a.json), [platform-misc-04](raw/platform-misc.json), [platform-misc-09](raw/platform-misc.json) |
| Stream Deck server side (`SD`) | 27 | 44 | 4 | [agent-backends-cc-03](raw/agent-backends-cc.json), [web-rest-01](raw/web-rest.json), [web-rest-03](raw/web-rest.json), [web-rest-08](raw/web-rest.json) |
| Event exchange & subscriptions (`BUS`) | 17 | 43 | 4 | [events-webhooks-executor-01](raw/events-webhooks-executor.json), [events-webhooks-executor-05](raw/events-webhooks-executor.json), [github-a-02](raw/github-a.json), [loose-3-04](raw/loose-3.json) |
| Coding-agent contract & routing (`CA`) | 23 | 43 | 3 | [agent-backends-oc-10](raw/agent-backends-oc.json), [loose-4-02](raw/loose-4.json), [web-rest-03](raw/web-rest.json) |
| Workspace & repo base (`WS`) | 22 | 43 | 8 | [loose-3-01](raw/loose-3.json), [loose-3-06](raw/loose-3.json), [platform-misc-03](raw/platform-misc.json), [platform-misc-04](raw/platform-misc.json) |
| Run telemetry & host health (`TEL`) | 21 | 41 | 4 | [loose-2-07](raw/loose-2.json), [loose-3-03](raw/loose-3.json), [loose-4-01](raw/loose-4.json), [platform-misc-08](raw/platform-misc.json) |
| Usage & pricing ledger (`USG`) | 24 | 34 | 6 | [telemetry-usage-01](raw/telemetry-usage.json), [telemetry-usage-02](raw/telemetry-usage.json), [telemetry-usage-03](raw/telemetry-usage.json), [telemetry-usage-04](raw/telemetry-usage.json) |
| Codex backend (`CDX`) | 15 | 33 | 6 | [agent-backends-cc-01](raw/agent-backends-cc.json), [agent-backends-cc-02](raw/agent-backends-cc.json), [agent-backends-cc-04](raw/agent-backends-cc.json), [agent-backends-cc-07](raw/agent-backends-cc.json) |
| Operator messaging to agents (`MSG`) | 12 | 30 | 2 | [agent-backends-cc-03](raw/agent-backends-cc.json), [orch-a-10](raw/orch-a.json) |
| Kernel primitives (`K`) | 9 | 22 | 2 | [agent-backends-cc-08](raw/agent-backends-cc.json), [platform-misc-04](raw/platform-misc.json) |
| Init wizard & upgrade (`INI`) | 5 | 19 | 0 | — |
| Provider meters & accounts (`PM`) | 9 | 18 | 1 | [loose-4-02](raw/loose-4.json) |
| OpenAI-compat backend (`OAI`) | 8 | 15 | 2 | [agent-backends-oc-02](raw/agent-backends-oc.json), [loose-4-02](raw/loose-4.json) |
| Linear adapter (`LIN`) | 2 | 10 | 2 | [agent-runtime-05](raw/agent-runtime.json), [tests-1c-01](raw/tests-1c.json) |
| Offline analytics tooling (`ANL`) | 6 | 8 | 0 | — |
| Tracker contract (+memory) (`TRK`) | 2 | 8 | 0 | — |
| Voice (ElevenLabs) (`VOX`) | 3 | 7 | 0 | — |
| Website and docs (`SITE`) | 3 | 4 | 1 | [platform-misc-01](raw/platform-misc.json) |

`primary items` sum to the 1,012 canonical findings. `Affected items` include cross-boundary findings and are nonadditive. Test findings are assigned to their tested module where the module name resolves; shared test support and unknown test modules remain in the dev/test boundary. These are candidate package boundaries, not proof that a finding belongs exclusively to that package. The full IDs and source locations are in `findings.json` under `boundary_finding_ids` and each claim.

## Cross-boundary work to keep together

- [Core-to-web dependency](raw/web-occ.json): projection and presentation code currently points from domain and CLIs into `AiurWeb`; move the shared data contract with callers, not just files.
- [Ticket-topic grammar](raw/orch-a.json): event producers and parsers span orchestration, agent runtime, wake and ingestion. Keep identifier and replay rules explicit.
- [GitHub request classification](raw/github-b.json): quota, logging, cache and credential selection disagree on mutation detection; the owner belongs below those consumers.
- [Usage dimension vocabulary](raw/telemetry-usage.json): one ordered five-token subset is shared; six raw fields and provider policies remain separate.
