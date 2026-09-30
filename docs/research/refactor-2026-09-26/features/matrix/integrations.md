# Integrations feature use

Frozen-source use observations and working decisions. `none-found` means no use in the sampled evidence, not no users. Follow the feature ID in [features.json](../features.json) for the full evidence, caveats, exact challenge text and module list.

| ID | Feature | Observed use | Raw → working decision | Skeptical status |
| --- | --- | --- | --- | --- |
| integrations-01 | Tracker adapter boundary (Aiur.Tracker, TrackerIdentity) | heavy | simplify → simplify | not challenged |
| integrations-02 | GitHub tracker adapter (issues, labels, state, comments, PRs, trust) | heavy | simplify → simplify | not challenged |
| integrations-03 | Linear tracker (+ linear_graphql agent tool, Codex linear skill) | none-found | cut → cut | holds |
| integrations-04 | Memory tracker | none-found | simplify → simplify | not challenged |
| integrations-05 | Backend registry and routing (agent.priority, agent.routing, model:/complexity: labels) | heavy | simplify → simplify | not challenged |
| integrations-06 | Shared app-server adapter layer | heavy | keep → keep | not challenged |
| integrations-07 | Codex app-server backend | heavy | keep → keep | not challenged |
| integrations-08 | Claude headless backend (via sibling aiur-claude app-server) | heavy | keep → keep | not challenged |
| integrations-09 | Claude REPL transport and Remote Control (claude-repl, model:remote, +remote) | none-found | cut → cut | overturned / narrowed |
| integrations-10 | OpenAI-compatible backends (DeepSeek, Kimi/Moonshot, OpenRouter) | occasional | externalize → keep | overturned / narrowed |
| integrations-11 | opencode chat-pane bridge (TUI agent chat viewer) | rare | cut → simplify | overturned / narrowed |
| integrations-12 | Agent dynamic tools (emit_event, emit_alert, blockers, subscriptions, review threads, set_ticket_state) | heavy | simplify → simplify | not challenged |
| integrations-13 | Provider rate/usage-limit detection, pause and fallback reroute | regular | simplify → simplify | not challenged |
| integrations-14 | Model catalog and provider model discovery | regular | simplify → simplify | not challenged |
| integrations-15 | Provider meters and account generations | occasional | simplify → simplify | not challenged |
| integrations-16 | Claude Code OTLP telemetry intake | none-found | cut → cut | holds |
| integrations-17 | GitHub HTTP transport and client core | heavy | keep → keep | not challenged |
| integrations-18 | GitHub budget broker and quota metering (github-cost, github-usage) | heavy | simplify → simplify | not challenged |
| integrations-19 | GitHub read cache, ResourceStore and agent gh state cache | heavy | merge → simplify | overturned / narrowed |
| integrations-20 | GitHub cache inspector page (/github-cache) | occasional | cut → keep | overturned / narrowed; 0.0.6 cut pending PR #2841 |
| integrations-21 | GitHub App auth, auth preflight and tracker health | regular | keep → keep | not challenged |
| integrations-22 | GitHub credential pooling (tracker.github.credentials) | none-found | cut → simplify | overturned / narrowed |
| integrations-23 | Agent gh/git guard (quota guard wrapper, push guard, token scrub) | heavy | simplify → simplify | not challenged |
| integrations-24 | GitHub polling loops (dispatch poll, comments, CI, firehose, ls-remote, cadence) | heavy | simplify → simplify | not challenged |
| integrations-25 | GitHub webhooks (ingress, delivery log, delivery modes, deposit/normalizer) | rare | cut → keep | overturned / narrowed |
| integrations-26 | CI readiness, merge-queue detection and CI approval ledger | regular | simplify → simplify | not challenged |
| integrations-27 | Review threads (read, reply, resolve, resolution policy) | occasional | simplify → simplify | not challenged |
| integrations-28 | GitHub native issue dependencies (blocked_by) and blocker subscriptions | regular | keep → keep | not challenged |
| integrations-29 | CODEOWNERS author allowlist | regular | merge → simplify | overturned / narrowed |
| integrations-30 | PR health scan and rework re-queue | occasional | merge → merge | holds |
| integrations-31 | PR watch and /aiur PR comment commands | none-found | cut → cut | holds |
| integrations-32 | Agent event bus (topics, subscriptions, publisher, sanitizer) | heavy | keep → keep | not challenged |
| integrations-33 | Executor wake inbox and executor-wait (claims, roster, principal) | heavy | simplify → simplify | not challenged |
| integrations-34 | Executor event journal, listener and custom executor.* events (listen/emit/subscribe) | rare | simplify → simplify | not challenged |
| integrations-35 | Decision/Command store, delivery and Executor answer CLI | regular | simplify → simplify | not challenged |
| integrations-36 | Decision revisions, enrichment and decision latency metrics | none-found | cut → simplify | overturned / narrowed |
| integrations-37 | Supervisor Decision HTTP API (bearer token) | none-found | cut → simplify | overturned / narrowed |
| integrations-38 | Alert feed and ledger (aiur alerts, needs-attention) | heavy | keep → keep | not challenged |
| integrations-39 | Asks (aiur ask / aiur asks) | rare | merge → simplify | overturned / narrowed |
| integrations-40 | Findings ledger (aiur findings) | regular | externalize → externalize | holds |
| integrations-41 | Executor takeover advisory alerts | regular | simplify → simplify | not challenged |
| integrations-42 | Executor handoffs | regular | keep → keep | not challenged |
| integrations-43 | Executor-to-agent messages (aiur message) | heavy | keep → keep | not challenged |
| integrations-44 | Build Order graph, catalog and CLI (daemon side) | regular | externalize → simplify | overturned / narrowed |
| integrations-45 | Build Order dashboard pages | unknown | externalize → simplify | overturned / narrowed |
| integrations-46 | aiur-build planning skill (Build Order pack authoring and publication) | occasional | externalize → externalize | holds |
| integrations-47 | Agent skill installer and bundled aiur agent skills (aiur-agent, aiur-debug, design-import) | heavy | keep → keep | not challenged |
| integrations-48 | Vendored Compound Engineering skills (31 skills, pinned 3.19.0) | regular | simplify → simplify | not challenged |
| integrations-49 | Codex-native git skills (commit, push, pull, land, linear) | occasional | merge → merge | overturned / narrowed |
| integrations-50 | Executor skills (aiur-run, aiur-monitor, aiur-meta, aiur-intro, release) | regular | externalize → keep | overturned / narrowed |
| integrations-51 | ElevenLabs provider (speech-to-text, TTS, quota meter) | unknown | externalize → keep | overturned / narrowed |
| integrations-52 | rtk output-compression integration | none-found | cut → cut | holds |
