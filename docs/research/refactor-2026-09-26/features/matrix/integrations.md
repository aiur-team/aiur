# Integrations feature use

Usage and raw recommendations are frozen research observations; challenged recommendations are continuing-researcher decisions and remain provisional until final synthesis. See the matching `raw/` feature and `challenges/` record for evidence and limits.

| ID | Feature | Observed use | Raw recommendation | Challenge |
| --- | --- | --- | --- | --- |
| integrations-01 | Tracker adapter boundary (Aiur.Tracker, TrackerIdentity) | heavy | simplify | pending |
| integrations-02 | GitHub tracker adapter (issues, labels, state, comments, PRs, trust) | heavy | simplify | pending |
| integrations-03 | Linear tracker (+ linear_graphql agent tool, Codex linear skill) | none-found | cut | holds |
| integrations-04 | Memory tracker | none-found | simplify | pending |
| integrations-05 | Backend registry and routing (agent.priority, agent.routing, model:/complexity: labels) | heavy | simplify | pending |
| integrations-06 | Shared app-server adapter layer | heavy | keep | pending |
| integrations-07 | Codex app-server backend | heavy | keep | pending |
| integrations-08 | Claude headless backend (via sibling aiur-claude app-server) | heavy | keep | pending |
| integrations-09 | Claude REPL transport and Remote Control (claude-repl, model:remote, +remote) | none-found | cut | overturned → cut |
| integrations-10 | OpenAI-compatible backends (DeepSeek, Kimi/Moonshot, OpenRouter) | occasional | externalize | pending |
| integrations-11 | opencode chat-pane bridge (TUI agent chat viewer) | rare | cut | overturned → simplify |
| integrations-12 | Agent dynamic tools (emit_event, emit_alert, blockers, subscriptions, review threads, set_ticket_state) | heavy | simplify | pending |
| integrations-13 | Provider rate/usage-limit detection, pause and fallback reroute | regular | simplify | pending |
| integrations-14 | Model catalog and provider model discovery | regular | simplify | pending |
| integrations-15 | Provider meters and account generations | occasional | simplify | pending |
| integrations-16 | Claude Code OTLP telemetry intake | none-found | cut | pending |
| integrations-17 | GitHub HTTP transport and client core | heavy | keep | pending |
| integrations-18 | GitHub budget broker and quota metering (github-cost, github-usage) | heavy | simplify | pending |
| integrations-19 | GitHub read cache, ResourceStore and agent gh state cache | heavy | merge | overturned → simplify |
| integrations-20 | GitHub cache inspector page (/github-cache) | occasional | cut | pending |
| integrations-21 | GitHub App auth, auth preflight and tracker health | regular | keep | pending |
| integrations-22 | GitHub credential pooling (tracker.github.credentials) | none-found | cut | overturned → simplify |
| integrations-23 | Agent gh/git guard (quota guard wrapper, push guard, token scrub) | heavy | simplify | pending |
| integrations-24 | GitHub polling loops (dispatch poll, comments, CI, firehose, ls-remote, cadence) | heavy | simplify | pending |
| integrations-25 | GitHub webhooks (ingress, delivery log, delivery modes, deposit/normalizer) | rare | cut | overturned → keep |
| integrations-26 | CI readiness, merge-queue detection and CI approval ledger | regular | simplify | pending |
| integrations-27 | Review threads (read, reply, resolve, resolution policy) | occasional | simplify | pending |
| integrations-28 | GitHub native issue dependencies (blocked_by) and blocker subscriptions | regular | keep | pending |
| integrations-29 | CODEOWNERS author allowlist | regular | merge | pending |
| integrations-30 | PR health scan and rework re-queue | occasional | merge | pending |
| integrations-31 | PR watch and /aiur PR comment commands | none-found | cut | pending |
| integrations-32 | Agent event bus (topics, subscriptions, publisher, sanitizer) | heavy | keep | pending |
| integrations-33 | Executor wake inbox and executor-wait (claims, roster, principal) | heavy | simplify | pending |
| integrations-34 | Executor event journal, listener and custom executor.* events (listen/emit/subscribe) | rare | simplify | pending |
| integrations-35 | Decision/Command store, delivery and Executor answer CLI | regular | simplify | pending |
| integrations-36 | Decision revisions, enrichment and decision latency metrics | none-found | cut | pending |
| integrations-37 | Supervisor Decision HTTP API (bearer token) | none-found | cut | pending |
| integrations-38 | Alert feed and ledger (aiur alerts, needs-attention) | heavy | keep | pending |
| integrations-39 | Asks (aiur ask / aiur asks) | rare | merge | pending |
| integrations-40 | Findings ledger (aiur findings) | regular | externalize | pending |
| integrations-41 | Executor takeover advisory alerts | regular | simplify | pending |
| integrations-42 | Executor handoffs | regular | keep | pending |
| integrations-43 | Executor-to-agent messages (aiur message) | heavy | keep | pending |
| integrations-44 | Build Order graph, catalog and CLI (daemon side) | regular | externalize | overturned → simplify |
| integrations-45 | Build Order dashboard pages | unknown | externalize | overturned → simplify |
| integrations-46 | aiur-build planning skill (Build Order pack authoring and publication) | occasional | externalize | holds |
| integrations-47 | Agent skill installer and bundled aiur agent skills (aiur-agent, aiur-debug, design-import) | heavy | keep | pending |
| integrations-48 | Vendored Compound Engineering skills (31 skills, pinned 3.19.0) | regular | simplify | pending |
| integrations-49 | Codex-native git skills (commit, push, pull, land, linear) | occasional | merge | pending |
| integrations-50 | Executor skills (aiur-run, aiur-monitor, aiur-meta, aiur-intro, release) | regular | externalize | pending |
| integrations-51 | ElevenLabs provider (speech-to-text, TTS, quota meter) | unknown | externalize | pending |
| integrations-52 | rtk output-compression integration | none-found | cut | pending |
