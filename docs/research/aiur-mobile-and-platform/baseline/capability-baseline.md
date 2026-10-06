# Capability baseline — aiur mobile and platform research (Phase A)

| Field | Value |
| --- | --- |
| Verified against | `origin/main` @ `45a290e3053423100a73b534c620fdd12ebe11ad` ("Default dashboard binding to loopback (#2995)", 2026-10-06 08:17 -0700) |
| Baseline date | 2026-10-06 |
| Method | `git archive origin/main` snapshot, read-only; four parallel code surveys, then spot re-verification of load-bearing claims (marked **[re-verified]**) |
| Research branch | `research/refactor-findings` (worktree `.worktrees/refactor-census-ed742`), pushed to `origin`, merge-base with main `e09dfbdae` (2026-09-30), 45 commits behind `origin/main` |
| Draft PR for the research branch | **None found.** `gh pr list --head research/refactor-findings --state all` returns `[]`. Earlier refactor-research PRs (#2865, #2912, #2913, #2915, #2919, #2921) are merged; #2921 removed the research files from `main`. |

Scope: features R1–R6, E1–E6, N1–N7 from `../brief.md`. Statuses mean:

- **EXISTS** — the capability the brief describes is present and working on main.
- **PARTIAL** — some of it is present. The gaps are listed.
- **NEW** — nothing material exists. The searches are listed.

Paths are repository-relative unless noted. Local operator-machine facts (outside the repo) are labelled **[host]**. They are not product behavior.

---

## 0. Summary table

| ID | Feature | Status | One-line verdict |
| --- | --- | --- | --- |
| R1 | Modular platform / component map | PARTIAL (research only) | Prior research has a 36-boundary map and a carve order. Code is one Mix app, and 35 of the 36 boundaries form one strongly connected component. Only `packages/streamdeck` and `packages/aiur-style` are separate packages. |
| R2 | Standalone event bus | PARTIAL | In-process topic exchange with durable IDs, per-ticket cursors, an issue-log replay for agents, and a durable `executor.*` journal. No reusable package boundary, no external subscriber API, and system topics cannot be replayed. |
| R3 | Optional Tailscale | EXISTS (already optional) | Tailscale auto-detection was removed in #2995. No code calls `tailscale`. The dashboard defaults to `127.0.0.1` and refuses a non-loopback bind without credentials. |
| R4 | Cloudflare / GitHub App relay | EXISTS (inbound webhook only) | Domain `hooks.aiur.dev`. It is an operator-run `cloudflared` tunnel, path-scoped to `/api/v1/github/webhook`, with HMAC verification. The repo has no relay code and it has no push or outbound role. |
| R5 | ElevenLabs STT | EXISTS (in core, not packaged) | `Aiur.ElevenLabs.Realtime` (`scribe_v2_realtime`), relayed by the daemon over `/voice` and `/streamdeck` sockets. The key is held only by the daemon. The transcript comes back to the client; a human presses Send. |
| R6 | Stream Deck package | EXISTS (separate package) | `packages/streamdeck` (`@aiur/streamdeck`, TypeScript sidecar). Hold-to-dictate captures audio in the sidecar. Targeting is the focused agent. The event-keyed log is built daemon-side in `AiurWeb.StreamdeckLogs`. |
| E1 | Build queue | PARTIAL | Dispatch skips `agent:todo` tickets with open `blocked_by`. They become eligible when the blocker closes, which works like auto-promotion only for pre-labelled tickets. There is no queue component, no relabelling, and no executor-created queue model. |
| E2 | Command capture, executor awareness, escalation | PARTIAL | Rich `Aiur.Decision`/`DecisionStore` model ("Commands" in the UI): authority, options, executor answer/escalate, supervisor API. Native Claude/Codex questions are **not** captured; they are auto-answered or bypassed. |
| E3 | First-class executor communication | NEW (primitives only) | Executor wake inbox, claims and roster exist. No executor conversation capture, no executor harness identity, and no dashboard executor surface. Remote Control is worker-only. |
| E4 | Dashboard conversations / event navigation | PARTIAL | Conversation drawer, agent log modal, `/chat/...` route and event feed exist. Event→transcript anchoring exists only on the Stream Deck (timestamp-based). No commit jump points; no Command→transcript link. |
| E5 | Dashboard voice input | EXISTS (worker chat only) | Conversation drawer has mic toggle, device picker, waveform, and dictate-review-Send. Not on Command answers in the dashboard. No Executor target. |
| E6 | Conversational voice component | PARTIAL (prototype-shaped) | Dashboard "voice conversation" mode = STT → auto-submit to the worker → TTS of the worker's reply. It is half-duplex, with no assistant persona, no pre-context and no ElevenLabs Conversational AI. |
| N1 | Cross-platform app | NEW | No React Native, Expo, Capacitor, PWA manifest or service worker. The dashboard is responsive (39 `@media` rules, viewport meta, apple-touch-icon). |
| N2 | Pairing and discovery | NEW (local seed exists) | Per-machine instance records in `~/.config/aiur/instances/*.instance` (launcher-internal). No pairing, device credentials, QR or network discovery. |
| N3 | Meta-dashboard | NEW | No multi-instance UI or "list instances" command. Per-instance counts exist ("units awaiting commands"). |
| N4 | Encrypted push | NEW | No APNs, FCM, web push or relay. Notifications are local sounds (`Aiur.Alerts`). Khala (separate product) is E2E-encrypted chat, not a push relay. |
| N5 | Notification preferences | NEW | Only `alerts.*` sound settings. The data for PR merge events and build-order % exists. |
| N6 | Contextual command response | PARTIAL (dashboard/deck) | Options, recommendation and context exist on `Aiur.Decision`. The dashboard and Stream Deck can answer. No phone/watch client or deep link. |
| N7 | Watch apps | NEW | Nothing found. |

---

## 1. Bucket 1 — Refactor

### R1 — Modular platform and reusable applications — PARTIAL (research exists; code is monolithic)

**Prior research to reconcile with (on `research/refactor-findings`):**
- `docs/research/refactor-2026-09-26/README.md`. Its eight research questions cover census, recurring problems, idle gaps, fixes, agent failure modes, feature boundaries, code review and feature inventory.
- `docs/research/refactor-2026-09-26/codebase/feature-boundaries.md` (111 KB).
  - §2 proposes 36+ boundaries in families A–G (Foundation, Integrations, Spine, Orchestration, Agent execution, Executor-facing, Surfaces and delivery).
  - §3 has the dependency graph.
  - §7 has the carve order.
  - Key findings:
    - 35 of the 36 candidate boundaries form one strongly connected component.
    - 320 of the 2,123 cross-boundary edges point "upward". Every feature calls `Aiur.Alerts` and `RunTelemetry` directly.
    - `Orchestrator.State` has 100 top-level fields.
  - The carve order ends with the repository candidates "Stream Deck sidecar (35) … Build Order (30), Decisions (27)…". Voice (36) and Stream Deck (35) are in step 8.
- `docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`. Units U0–U9 are behaviour-preserving repairs plus file-size migration. They are not package splits. The plan says: "Possible eventual package seams are GitHub access, agent/backend runtime, lifecycle/Executor state, and presentation. They are options, not four preapproved repositories." U3 owns `events/subscription_store.ex`, `executor/claims.ex` and `executor_wake_inbox.ex`. U6 owns `decision_store.ex`.
- `docs/brainstorms/2026-09-29-aiur-refactor-requirements.md`, `synthesis/STATUS.md` (2026-09-30) and `synthesis/open-questions.md`.

**Current code layout (origin/main):**
- One Elixir Mix application in `src/`: `src/lib/aiur/**` (core) and `src/lib/aiur_web/**` (Phoenix dashboard and API).
- The separately packaged parts:
  - `packages/streamdeck` (npm `@aiur/streamdeck`, private)
  - `packages/aiur-style`
  - `packaging/npm/aiur-cli` (launcher engine `libexec/aiur-engine.sh` plus platform release packages)
  - `website/` (VitePress docs)
- There is no umbrella app and no internal Hex packages.
- Compile-time coupling between core and the Stream Deck package: `src/lib/aiur_web/streamdeck_key_face_contract.ex` reads `packages/streamdeck/src/key-face-contract.json` at compile time.

**Capability detection by clients today:** none found.
- There is no capability or feature endpoint.
- `GET /api/v1/state` returns the dashboard snapshot. Clients infer what is available from missing fields (for example, the ElevenLabs meter is absent with no key) and from channel join errors (for example, voice `unconfigured`).

**Gaps relevant to the brief:**
- No capability matrix in code.
- No versioned client protocol. The launcher-to-daemon control path is RPC over distributed Erlang (`AgentControlCLI`). The dashboard API is unversioned beyond the `/api/v1` prefix.
- The prior research has not mapped the new mobile-facing contracts: pairing, push, executor conversation and capabilities.

### R2 — Standalone shared event bus — PARTIAL

**Core modules** (`src/lib/aiur/events/`):

| Module | Role | Evidence |
| --- | --- | --- |
| `Aiur.Events.Topic` (`topic.ex`) | Matcher in the style of an AMQP topic exchange. Topics are dot-separated; `*` matches one segment and `#` matches zero or more. Functions `matches?/2`, `specificity_score/1`. `Aiur.Alerts` reuses it. | `test/aiur/events/topic_test.exs` |
| `Aiur.Events.Exchange` (`exchange.ex`) | A GenServer with an ETS `:duplicate_bag` of `{pattern, pid, monitor_ref}` rows. `subscribe/2`, `unsubscribe/2`, `publish/3`, `bindings_for/2`. Delivery is `send(pid, {:event, event})`: in-process, fire-and-forget, no backpressure. | `exchange_test.exs`, `event_delivery_test.exs` |
| `Aiur.Events.Publisher` (`publisher.ex`) | The single publish boundary. `publish/3` applies these filters in order, then assigns an ID and records a publisher-log marker:<br>1. `decision.requested\|acknowledged\|resolved` must use the durable path (`{:error, :decision_requires_durable_publish}`).<br>2. GitHub-sourced `executor.*` is refused.<br>3. Bot self-loops are `:filtered`.<br>4. Untracked issues are `:filtered`.<br>5. `ResourceStore.processed?` dedups (survives restarts).<br>6. An ETS dedup window applies (1 h).<br>`publish_persisted/4` takes a pre-reserved ID (used by DecisionStore and ExecutorEvents). Returns `{:ok, id, subscriber_count} \| :filtered \| :deduped \| {:error, _}`. | `publisher_test.exs`, `publisher_identity_mode_test.exs` |
| `Aiur.Events.IdGenerator` (`id_generator.ex`) | One global monotonic integer ID that survives restarts (`event-id.json` in `Paths.runtime_state_dir()`, reserved in batches). `next_id/1`, `peek/1`, `reserve_durable_id/1`. | `id_generator_test.exs` |
| `Aiur.Events.SubscriptionStore` (`subscription_store.ex`) | One GenServer per ticket (Registry plus DynamicSupervisor). Persists `<runtime-state>/subscriptions/<repo>.<id>.subscriptions.json`: `subscribed_to[{topic, reason, subscription_created_at_event_id}]`, `last_seen_event_id`, `open_attentions`. Delivers to `Aiur.Orchestrator` (`{:enqueue_event_digest, ...}`) and advances its cursor only on success. It retries up to 3 times, then dead-letters (`system.subscription_store.event_dead_lettered`), and holds later events behind a stall so order is kept. | `subscription_store_test.exs` |
| `Aiur.AgentRunner.BootstrapDigest` (`agent_runner/bootstrap_digest.ex`) **[re-verified]** | Replay for agents. On an agent's first turn after a (re)start, it reads `Aiur.IssueLog.event_history(publisher_id, since_id: cursor)` for each `ticket.<N>.…` subscription and enqueues one digest. Its own comment says system topics are not replayable: "Patterns under `system.…` aren't backed by an issue log today … (Executor-facing system events can't be replayed on restart yet)." | — |
| `Aiur.Events.UniversalSubscriptions` | Bindings every ticket gets automatically: `system.<base>.branch.push`, `system.config.base_branch.changed`, `ticket.<id>.issue.commented`, `ticket.<id>.pr.review_comment`, `ticket.<id>.ci.passed\|failed`, `ticket.<id>.operator.progress_request`. | `universal_subscriptions_test.exs` |
| `Aiur.Events.AgentSubscriptionPolicy` | An agent's manual subscriptions must name one literal ticket. `executor.*`, `system.*` and wildcards are refused. | — |
| `Aiur.Orchestrator.AutoSubscriptions` | On a blocker edge, the blocked ticket subscribes to the blocker (`blocker:auto`) and the blocker subscribes back (`blockee:auto`). | `orchestrator/auto_subscriptions_test.exs` |

**Topic grammar (verified in code and in `.claude/skills/aiur-agent/event-taxonomy.md`):**
- `ticket.<id>.<surface>.<verb>`, e.g. `ticket.N.pr.merged`, `ticket.N.ci.failed`, `ticket.N.branch.push`.
- `ticket.<id>.agent.<name>` for agent-emitted events.
- `system.<base_branch>.branch.push` and `system.<area>.<…>`.
- `executor.*`.

**Event shape:**
- A plain map: payload plus `id`, `topic` and `ticket_observation`. There are no structs per event type.
- Versioning is in the `Aiur.TicketObservation` envelope (`ticket_observation.ex`): `version: 1`, `payload_version: 1`, `status`, `tracker_identity`, `source`, `event_id`, `provenance`, `occurred_at`, `observed_at`, `attributes`.

**Producers:**
- GitHub sources in `events/`: `github_firehose.ex`, `ls_remote_ticker.ex`, `github_comments_poller.ex`, `github_ci_poller.ex`, `pr_command_scanner.ex`, `github_webhook.ex` and `github_webhook/{normalizer,deposit}.ex`.
- Orchestrator: `orchestrator/{ci_lifecycle,comment_wake,rework_gate,ready_for_review_transitions,command_scan,push_routing}.ex`.
- Others: `alerts.ex`, `decision_store.ex`, `executor_events.ex`, `progress_checkin/worker.ex`, `allowed_contributors/state.ex`, and `agent_runner/tool_executor.ex` (the agent `emit_event` tool).

**Consumers:**
- `SubscriptionStore` feeds the orchestrator digest, which reaches agents through `agent_runner/events_digest.ex`.
- `Aiur.Orchestrator.Lifecycle`.
- `Aiur.ExecutorListener`.
- `Aiur.DecisionMetrics`.
- Stream Deck and dashboard feeds through `Aiur.AgentEventFeed` (`bus_events/2` reads `IssueLog`).

**Executor journal and wake inbox:**
- **`Aiur.ExecutorEvents`** (`executor_events.ex`): a durable journal for **`executor.*` only**.
  - Functions: `publish/3`, `replay/2`, `listen/1`, `subscribe/1`, `reconcile_subscriptions/1`.
  - Files are under `~/.aiur/repo/<owner>/<repo>/executor/` (`Aiur.Executor.StatePaths`):
    - `<repo>.executor.events.ndjson`
    - `.wakes.ndjson`
    - `.wakes.cursor.json`
    - `.wakes.pending.json`
    - `.subscriptions.json`
    - `.listener.watermark.json`
    - `.claims.json`
- **`Aiur.ExecutorBindings`**: the default Executor allowlist.
  - `executor.#`
  - `system.dispatch.*`, `system.fleet.*`, `system.tracker.auth_preflight_failed`, `system.github.connectivity_lost`
  - `ticket.*.pr.{opened,merged,ready_for_review,parked_ready}`, `ticket.*.branch.push`, `ticket.*.ci.{passed,failed}`
  - `ticket.*.agent.{attention.*,paused,error.tokens_exhausted,retry_exhausted}`
  - `ticket.*.issue.opened.allowed_contributor`
- **`Aiur.ExecutorListener`** turns non-executor events into wake records with `Aiur.ExecutorWakeProjection.project/1`. The records hold identifiers only: `wake_id`, `topic`, `topic_class`, `ticket`, `pr_number`, `head_sha`, `action`, `ci_conclusion`, `count`, first and last seen.
- **`Aiur.ExecutorWakeInbox`**:
  - Merges records by `{topic_class, ticket}`. Debounce is 2000 ms. The cap is 10,000 records, with an `executor.wakes.overflow` alert.
  - `wait/2` and `acknowledge_as/3` are lease-checked through `Aiur.Executor.Claims`.
- **CLI** (`Aiur.AgentControlCLI`):
  - `executor-wait [--timeout] [--json] [--as]`, `executor-listen`, `executor-emit`
  - `executor-subscribe` / `executor-unsubscribe` / `executor-subscriptions`
  - `executor-fast-forward`, `executor-claim` / `executor-release` / `executor-revoke`, `executor-roster`
  - `aiur status` prints `WAKES CURSOR <id> PENDING <count>`.
  - Not found: `aiur events`, `aiur wake`, `aiur inbox`.
- **Tests:** `executor_wake_inbox_test.exs`, `executor_listener_test.exs`, `executor_wake_projection_test.exs`, `executor_events_test.exs`, `executor_bindings_test.exs`.

**Webhook ingestion:**
- **Endpoint:** `POST /api/v1/github/webhook` (`router.ex:74`, pipeline `:github_webhook`). It sits outside dashboard basic auth.
- **Verification:**
  - `AiurWeb.GithubWebhook.Auth` and `Signature.verify/3` check HMAC-SHA256 on `X-Hub-Signature-256`. SHA-1 is rejected.
  - The secret is `AIUR_GITHUB_WEBHOOK_SECRET`. If it is missing, the request gets a 401 and the alert `system.github_webhook.secret_missing` fires.
  - Bodies over 25 MB are refused.
- **Controller:** `AiurWeb.GithubWebhookController.create/2` always returns 202. `Aiur.Webhooks.Ingest.accept` runs inline with a 5 s fail-open check. `Aiur.Events.GithubWebhook.handle_delivery/3` then runs asynchronously.
- **Dedup:** `Aiur.Webhooks.DeliveryLog` writes `webhook_deliveries.ndjson` in `decision_state_dir`. It keys on `X-GitHub-Delivery` plus a semantic key and keeps per-scope watermarks.
- **Delivery modes** (`Aiur.Webhooks.DeliveryMode`, `ModeRegistry`): `:never_configured | :configured_unproven | :webhook_backed | :degraded`.
- **Normalizer:**
  - Comments, reviews and threads publish the same topics as the pollers.
  - `issues`, `pull_request` and `check_*` deliveries call `Aiur.Orchestrator.request_refresh/0`.
  - `sub_issues` and `issue_dependencies` are only deposited into `ResourceStore`.
- **Tests:** `test/aiur_web/github_webhook*_test.exs`, `test/aiur/events/github_webhook*_test.exs`, `webhook_poll_reconciliation_test.exs`, `test/aiur/webhooks/*`.
- **Docs:** `website/docs-app/concepts/message-bus.md`, `website/docs-app/apis/github.md`.

**Other event logs:**
- `Aiur.EventPublicationLog` writes `<log_root>/event-publications.ndjson`. It is written once per launch, write-only and fsynced, from `agent_runner/tool_executor.ex`. Nothing in the daemon reads it.
- `Aiur.IssueLog` writes the per-issue transcript plus a publisher event log under `<logs-root>/log`. `event_history/2` reads it, `read_tail/2` pages it, and it keeps 100 events in memory. This is the de facto durable per-ticket event log.

**Gaps for R2:**
1. **No external subscription surface.** No websocket, SSE or HTTP API exposes bus topics to clients. Dashboard and Stream Deck read projections through Phoenix PubSub and channels, not bus topics.
2. **System topics are not replayable.** Ticket topics replay to agents only, from IssueLog via BootstrapDigest. `executor.*` replays from the executor journal. The Executor wake inbox cannot replay ticket or system wakes that arrived while no listener was subscribed.
3. **One global ID, no per-topic sequence.** Cursors exist per ticket store and per Executor consumer only.
4. **No schema registry or per-topic payload contract.** Only the `TicketObservation` envelope is versioned.
5. **Coupling:** `SubscriptionStore` delivers by calling `Aiur.Orchestrator`, so the bus cannot run without orchestration. The prior research's step 1 ("kernel and signal port") addresses part of this.

### R3 — Optional Tailscale integration — EXISTS (already optional; no code dependency)

**Evidence:**
- **#2995** (`45a290e30`, the HEAD of this baseline) changed `default_dashboard_host()` in `packaging/npm/aiur-cli/libexec/aiur-engine.sh`.
  - It used to call `tailscale ip -4` and use the `100.x` address when both dashboard credentials were set. Auto-detection was originally added in #1302 (`a3e80dea8`, 2026-07-24).
  - It now returns `${AIUR_DEFAULT_DASHBOARD_HOST:-127.0.0.1}`.
  - Also changed: `.aiur/examples/config.example`, `website/docs-app/reference/cli.md`, `src/test/aiur/init/templates_test.exs`, and `src/test/aiur_engine_test.exs`. The last one has the new test "dashboard defaults to loopback even with Tailscale and dashboard credentials", which stubs a `tailscale` binary.
- **Host precedence:** `--host` > `server.host` > `AIUR_DEFAULT_DASHBOARD_HOST` > `127.0.0.1`.
  - `src/lib/aiur/config.ex` `default_server_host/0` applies only when the key is absent.
  - Schema `src/lib/aiur/config/schema/server.ex` (`port`, default 0; `host`, default `"127.0.0.1"`).
  - Env schema `src/lib/aiur/env/schema.ex`.
- **Searches:** `tailscale|tailnet|ts.net|magicdns|100.64|funnel` across `src/lib`, `packaging`, `scripts` and `packages` find **no code calls**. Remaining mentions:
  - Docs: `AGENTS.md`, `src/README.md`, `website/docs-app/reference/configuration.md` (`server.host`), and `website/docs-app/reference/optional-optimizations.md` § Tailscale ("There is no automatic Tailscale detection in code").
  - An alert string in `src/lib/aiur/webhooks/mode_registry.ex`: "a tailnet-only or loopback-bound dashboard cannot receive GitHub deliveries".
  - A cautionary note in `.claude/skills/aiur-meta/SKILL.md`.
- **Bind guard** (`src/lib/aiur/http_server.ex`, `guard_dashboard_credentials/3`):
  - A **non-loopback bind without `AIUR_DASHBOARD_USERNAME`/`AIUR_DASHBOARD_PASSWORD` refuses to start**.
  - A loopback bind without credentials starts but fails closed: every request gets a 401 or 503.
  - So disabling Tailscale cannot silently expose endpoints. The remaining exposure risk is an explicit `server.host: 0.0.0.0` with credentials set.
- **Auth layers:**
  - Dashboard: Basic Auth (`AiurWeb.FinancialDataAccess.authenticate_request/2`, realm "Aiur"), plus a signed session proof re-checked in LiveView `on_mount`.
  - Writes: same-origin plus `X-Aiur-Request: 1` (the `:api_write` pipeline), and `observability.dashboard_writable`.
  - Supervisor API: a bearer token (`AIUR_SUPERVISOR_TOKEN`, `AiurWeb.SupervisorAuth`).
  - No loopback-only HTTP routes were found.
- **URL ownership:**
  - No `public_url`, `dashboard_url` or `external_url` config key exists.
  - The dashboard URL is derived at runtime by `Aiur.HttpServer.base_url/0`, and `display_host/1` maps `0.0.0.0` to `127.0.0.1`.
  - The launcher prints `Dashboard: <url>` (`probe_dashboard_status`).
  - The default `server.port: 0` picks a fresh random port each boot.

**Current terminology:** "dashboard", "server.host", "loopback", "tailnet IPv4".

**Gaps for the brief:**
- There is no advertised or reachable URL concept separate from the bind address. A phone needs a stable URL, and port 0 breaks that.
- No device authorization beyond shared Basic Auth credentials (N2).
- Reachability and authorization are the same thing today: whoever can reach the port and knows the password has full access.

**[host]** This repo's dogfood `.aiur/config` sets `server: {host: 0.0.0.0, port: 4000}`, an explicit all-interfaces bind.

### R4 — Existing Cloudflare / GitHub App relay — EXISTS (inbound webhook transport only)

**Domain:** **`hooks.aiur.dev`** (the owner's "Ayer dot dev" is `aiur.dev`). It appears only in docs and tests:
- `website/docs-app/apis/github.md` (§ Optional webhook, § Cloudflare tunnel boundary, lines ~714 and ~749)
- `website/docs-app/reference/optional-optimizations.md` (step 4: "`hooks.aiur.dev` is one operator's choice, not a requirement")
- `website/tests/gui-docs.spec.ts`
- `docs/measurements/2026-08-17-comment-poll-webhook-reconciliation.md`

Other domains in the repo:
- `aiur.team`: docs and marketing.
- `khala.aiur.team` and `archon.aiur.team`: sibling products.

**Relay or worker code:** none in the repo. Searched for `*wrangler*`, `*cloudflared*`, `*tunnel*` and `cloudflare|wrangler` outside docs; the only hits were marketing lines in `README.md` and `packaging/npm/aiur-cli/README.md`. There is no Workers code and no tunnel config in the repo.

**[host]** On the owner's machine:
- `~/.cloudflared/config.yml` routes `hostname: hooks.aiur.dev`, `path: ^/api/v1/github/webhook$` to the daemon (a tailnet `100.x` address on port 4000), followed by a catch-all `http_status:404`.
- It runs as the systemd user unit `cloudflared-aiur-webhook.service` ("Cloudflare tunnel for the aiur GitHub webhook receiver").

**Purpose and flows (authoritative source: `website/docs-app/apis/github.md`):**
- **Original purpose:** poll latency and GitHub API budget.
  - A proven webhook widens polls by `webhooks.poll_widen_factor` (2.0, so 120 s becomes 240 s).
  - It raises the read-cache TTL from 30 s to 1 h.
  - It wakes dispatch on actionable deliveries (#2369, #2992).
- **Boundary:** "Cloudflare is transport for the GitHub webhook, not an API Aiur calls."
  - Two independent locks protect it: path-only tunnel routing, and the HMAC signature.
  - No inbound firewall rule is needed (`cloudflared` dials out).
  - Quick tunnels (`cloudflared tunnel --url`) are the documented no-domain option.
- **Config:** `webhooks.repos`, `webhooks.silence_threshold_seconds` (900), `webhooks.sweep_interval_seconds` (60), `webhooks.poll_widen_factor` (2.0) in `src/lib/aiur/config/schema/webhooks.ex`; env `AIUR_GITHUB_WEBHOOK_SECRET`.
- **GitHub App relationship:** independent of the tunnel.
  - The App is the daemon's API identity: `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY_PATH | GITHUB_APP_PRIVATE_KEY`, and `tracker.github.github_app.account` (must end in `[bot]`).
  - Code: `src/lib/aiur/github/{app_credentials,app_token,app_token_refresher}.ex`. Installation tokens last about 1 h and refresh 5 min before expiry.
  - App credentials replace `GITHUB_TOKEN` for daemon calls.
  - The webhook can be an App webhook or a repo webhook. Aiur only sees signed POSTs.
- **What it does not do:** no outbound relay, no device fan-out, no push, no client authentication, no encryption beyond TLS to Cloudflare.

**Gaps for the brief:**
- Reusing it for mobile would be a new outbound/relay role.
- The current tunnel deliberately exposes only one path. Widening it would break the "a host-wide tunnel would expose the dashboard" rule in `apis/github.md`.

### R5 — ElevenLabs speech-to-text — EXISTS (inside core; not a separate package)

**Config:**
- Schema `Aiur.Config.Schema.ElevenLabs` (`src/lib/aiur/config/schema/eleven_labs.ex`, embedded as `:elevenlabs`):
  - `elevenlabs.api_key` (literal value, or a `$ELEVENLABS_API_KEY` reference)
  - `elevenlabs.language_code` (default `eng`)
  - `elevenlabs.voice_id` (used for TTS replies)
- Env var `ELEVENLABS_API_KEY`.
- Accessors `Aiur.Config.elevenlabs_api_key/0`, `elevenlabs_language_code/0`, `elevenlabs_voice_id/0`.
- `aiur init` prompts for it (`src/lib/aiur/init/eleven_labs.ex`, the `{{ELEVENLABS_SECTION}}` placeholder in `.aiur/examples/config.example`).
- Docs: `website/docs-app/reference/configuration.md` § elevenlabs and `website/docs-app/apis/elevenlabs.md`.
- The daemon scrubs every `*_API_KEY` from agent environments.

**Capture → transport → transcription → delivery:**

| Stage | Stream Deck | Dashboard |
| --- | --- | --- |
| Capture | Sidecar: `packages/streamdeck/src/audio/capture.ts` (`parec`, 16 kHz mono s16le) | Browser: `src/priv/static/conversation-voice-controller.js` + `voice-capture-worklet.js` (`getUserMedia`, AudioWorklet, downsampled to 16 kHz) |
| Transport | Phoenix socket `/streamdeck`, channel `streamdeck:fleet`, events `voice_start` / `voice_audio` (base64 PCM) / `voice_stop` | Phoenix socket `/voice` (`AiurWeb.VoiceSocket`, `max_frame_size` 400,000), channel `voice:dictation` or `voice:conversation` (`AiurWeb.VoiceChannel`), events `audio` / `stop` |
| Transcription | Daemon `Aiur.ElevenLabs.Realtime` (`src/lib/aiur/eleven_labs/realtime.ex`): `wss://api.elevenlabs.io/v1/speech-to-text/realtime`, model `scribe_v2_realtime`; `start/1`, `push/2`, `commit/1`, `stop/1`; owner messages `{:elevenlabs_transcript, :partial \| :final, text}` | Same module |
| Return | `voice` / `voice_error` / `voice_closed` channel events to the sidecar | `transcript` events into the composer |
| Delivery to agent | Human presses Send on the deck: `say {identifier, text}` → `AiurWeb.StreamdeckChannel` → `Aiur.AgentChat.send/3` | Human presses Send: `send-operator-message` → `DashboardLive` → `Aiur.AgentChat.send/3` |
| Downstream | `Aiur.AgentChat` → `Aiur.Orchestrator.send_operator_message/2` → `Aiur.Orchestrator.OperatorMessages` (the same path as typed chat) | Same path |

- **No HTTP audio route.** Audio travels only over the two websocket channels.
- **Limits** (`AiurWeb.VoiceSessionLimiter`): 256 KiB per chunk and 9.6 MB per session (about 5 minutes).
- **TTS:** `Aiur.ElevenLabs.TTS` (`eleven_flash_v2_5`, `pcm_44100`).
- **Quota meter:** `Aiur.ElevenLabs.Quota` (`GET /v1/user/subscription`) feeds the Units page.

**Missing key:**
- `Realtime.start` returns `{:error, :unconfigured}`.
- Joining the dashboard channel fails with "ElevenLabs speech-to-text is not configured. Dictation is unavailable…".
- The deck receives `unconfigured`, and `StreamdeckProjection.voice/0` advertises availability ahead of time.
- Text chat is unaffected.

**Tests:**
- `src/test/aiur/eleven_labs/{realtime,tts,quota}_test.exs` and `realtime/mint_socket_test.exs`
- `src/test/aiur_web/voice_channel_test.exs`, `streamdeck_voice_latency_test.exs`, `streamdeck_channel_test.exs`
- `test/aiur/config/schema_test.exs`, `test/aiur/env_test.exs`

**Current terminology:** "dictation", "voice input", "speech to text", "spoken replies", "interactive conversation".

**Gaps for R5:**
- Voice is not packaged separately. `Aiur.ElevenLabs.*` and `AiurWeb.VoiceChannel` live in core and web.
- The only gates are "key present" and `dashboard_writable`. There is no feature flag or module-absent path.
- Voice cannot target the Executor; every path targets a ticket agent identifier.
- An unwired sidecar TTS provider exists: `packages/streamdeck/src/audio/elevenlabs-tts.ts` is exercised only by tests and would need an API key in the sidecar, which contradicts the documented rule that the sidecar never holds the key.

### R6 — Stream Deck integration — EXISTS (separate package)

**Package:** `packages/streamdeck`.
- npm name `@aiur/streamdeck` (private, ESM, TypeScript, vitest, Node 24). Dependencies `@napi-rs/canvas` and `usb`.
- Entry point `src/main.ts`; shipped as `bin/aiur-streamdeck` via `scripts/build-package.mjs`.
- Runs as the systemd user unit `systemd/aiur-streamdeck.service`, with `EnvironmentFile=%h/.config/aiur/streamdeck.env`. Udev rule `udev/70-streamdeck.rules`.
- Rolling nightly releases (#2636). Linux x64 only, experimental.
- **[host]** `aiur-streamdeck.service` is active on the owner's machine.

**Daemon link** (`src/channel.ts`):
1. `POST /api/v1/streamdeck/token` with Basic Auth returns a 300 s `Phoenix.Token` (`AiurWeb.StreamdeckAuth`).
2. Websocket to `/streamdeck/websocket`, channel `streamdeck:fleet`.
- Env: `AIUR_PHOENIX_URL`, `AIUR_DASHBOARD_USERNAME`, `AIUR_DASHBOARD_PASSWORD`.
- The sidecar follows one daemon only. To follow another, change `AIUR_PHOENIX_URL` and restart it.

**Channel events:**
- **In:** `focus`, `unfocus`, `control` (pause/resume/implement), `say`, `voice_start`, `voice_audio`, `voice_stop`, `commands_page`, `answer_command`.
- **Out:** `snapshot`, `fleet`, `usage`, `transcript`, `logs`, `control`, `alert`, `decisions`, `commands`, `voice`, `voice_error`, `voice_closed`.

**Hold-to-dictate:**
- `controller.ts`: key-down on the Mic key calls `holdMic()`; key-up calls `releaseMic()`, which sends `voice_stop`, and the daemon commits.
- Text accumulates across holds. Send calls `sendTranscript(identifier)` → `channel.say(identifier, text)`. Cancel clears the text.
- `aiur-speech.ts` `normalizeAiurDictation` corrects "aeor/iyer/ayer" to "Aiur".

**Targeting:**
- Keys are not bound to fixed agents. Grid mode assigns agents to keys dynamically.
- Pressing an agent key calls `focus(identifier)` and enters `cmd` mode. Every action then targets `state.focusedIdentifier`.
- Commands mode answers the focused agent's Commands only (checked server-side in `validate_focused_command`). A dictated answer becomes a `custom_response` with actor `%{kind: :operator, id: "streamdeck"}` (#2156).
- Modes: `grid | cmd | logs | settings | commands`. There is also an Implement key that queues an agent-less ticket (#2617).
- The Executor is never a target.

**Event-organized log:**
- **Daemon side:** `AiurWeb.StreamdeckLogs` (`load/1`, `wire/1`, `project/1`) merges `Aiur.AgentEventFeed.bus_events/2` with `AgentEventFeed.list/2`.
  - The first gives one key per ticket event: progress, phase, comment, CI, PR, decision, attention.
  - The second gives the provider transcript.
  - Each transcript entry attaches to the **last event at or before its timestamp**. Each key carries `start` (a row index), `transcript_offset` and `event_starts`.
  - A synthetic "Ticket opened" key and a pinned LIVE key are added.
  - `AiurWeb.StreamdeckTranscriptRelay` streams live updates with throttling.
- **Sidecar presentation:** `src/logs.ts`, `src/touchStrip/{chatLog,typewriter,agentDetail}.ts`.

**Shared vs hardware-specific:**
- **Shared (daemon-side, reusable):** `StreamdeckProjection`, `StreamdeckLogs`, `StreamdeckCommands`, `StreamDeckGrid`, the `streamdeck:fleet` channel, and `GET /api/v1/streamdeck/grid` (exists but unused by the sidecar).
- **Hardware-only:** `rasterizer.ts`, `keys/*`, `touchStrip/*`, `art/*`, `usb-backend.ts`, `hidraw-backend.ts`, `lifecycle.ts`, `dial.ts`.

**The dashboard does not need the hardware.**
- `AiurWeb.StreamdeckLive` at `/streamdeck` is a browser emulator. It calls the same projections directly.
- Its mic key is UI state only and captures no audio.
- Remaining coupling: the compile-time read of `key-face-contract.json` noted in R1.

**Tests:**
- Package (vitest): `packages/streamdeck/test/**` (audio, voiceHost, voicePanel, channel, controller, logs, mode, commands, aiur-speech, touchStrip, keys, art) and `scripts/test/build-package.test.mjs`.
- Elixir: `src/test/aiur_web/streamdeck_{channel,commands,control_agreement,key_face_contract,logs,projection,strip,voice_latency}_test.exs`, `stream_deck_grid_test.exs`, `live/streamdeck_live_test.exs`.

**Docs:** `website/docs-app/guide/stream-deck.md`, `packages/streamdeck/README.md`, `docs/research/streamdeck-{direct-hid-spike,end-to-end-proof}.md`.

**Gaps for R6:**
- The event→transcript association lives in `AiurWeb.StreamdeckLogs`, a web module named after the device. It is the most reusable anchor in the codebase (see E4) but is not exposed under a neutral name or API.
- The package boundary is already clean apart from the compile-time contract file.

---

## 2. Bucket 2 — Platform improvements

### E1 — Build queue — PARTIAL

**Build orders:**
- A root is a GitHub issue labelled **`build-order`**.
  - Members are its GitHub **sub-issues**. Edges are native GitHub **`blockedBy`** issue dependencies.
  - Lanes and phases come from `build-lane:*` and `phase:*` labels.
  - GraphQL lives in `src/lib/aiur/build_order/github_graph/queries.ex`.
- Modules in `src/lib/aiur/build_order/`: `GitHubGraph` (`fetch_catalog/1`, `fetch_selected_root/2`), `GraphProjection*`, `Catalog`, `CatalogStore`, `RootSummary`, `Member`, `Dependency`, `DependencyChain`, `GraphAnalysis`, `EdgeState`, `ProgressRenderer`, `PackStatus`, `AdHocSource`.
  - `EdgeState.classify/2` returns `:cleared | :blocking | :terminal_unsatisfied | :unknown | :cyclic`.
- The catalog is event-sourced from `sub_issues` and `issue_dependencies` webhooks (#2336).
- **Progress %** (`github_graph/normalizer.ex`): `round(closed_completed / resolved_members * 100)`. It is stored in `RootSummary.progress` and rendered by `ProgressRenderer.terminal/1` and `json/1`. `not_planned` counts as resolved but not completed.
- **`Aiur.BuildOrder.Readiness.from_edges/1`** is display-only. It is used by `aiur_web/build_order_presenter.ex`, `build_order_view_model.ex` and `build_order/ticket_context_adapter.ex`. No orchestrator module references `Aiur.BuildOrder`.
- **`AdHocSource`** is a runtime overlay for `build-lane:adhoc` tickets created during a run.
- **CLI:** `aiur build-orders [<root>] [--json]` (`Aiur.BuildOrdersCLI`), read-only.
- **Dashboard:** `/build-orders` and `/build-orders/:root_number` (`AiurWeb.BuildOrderLive`).
- **Config:** `build_order.*` (cadences, caps).
- **Tests:** `test/aiur/build_order/*`, `test/aiur/build_orders_cli*_test.exs`, `test/aiur_web/build_order/*`, `test/aiur_web/live/build_order_live_test.exs`.

**Readiness labels and dispatch:**
- **State labels** (`src/lib/aiur/github/labels.ex`), with the `agent:` prefix: `todo in-progress ci-wait human-review rework merging done error cancelled canceled`.
- **Marker labels:** `watch`, `paused`, `parked`, `rate-limit-fallback`.
- **There is no `agent:backlog` label** (searched for it).
- `agent:todo` triggers dispatch. Its authorization depends on who applied the label (`github/dispatch_authorization.ex`).
- **Dispatch eligibility** (`src/lib/aiur/orchestrator/dispatch_policy.ex`, `dispatch_state_decision/4`) checks, in order:
  1. `blocked_on_decision?` → `{:skip, :blocked_on_decision}`
  2. `todo_issue_blocked_by_non_terminal?/2` (line ~1001) → `{:skip, :dependency}`. This applies only to `todo`.
  3. `:already_running`
  4. `:state_capacity`
  5. `:worker_capacity`
- Blocker edges come from `Aiur.GitHub.BoundedBlockedBy`, cached up to 15 min.
- **Ordering among ready tickets** **[re-verified]:** `dispatch_policy.ex` sorts by `{priority_rank(issue.priority), created_at, identifier}`, where priority is 1–4 (tracker priority) and anything else ranks 5.
- **Capacity:**
  - `agent.max_concurrent_agents`, changeable at runtime with `aiur set max-agents <n>`
  - `agent.max_concurrent_agents_by_state`, `agent.max_concurrent_builds` (4)
  - Load governor: `agent.max_load_average`, `target_load_average`, `load_ramp_step`, `load_cooldown_seconds`
  - Overflow alert: `system.dispatch.todo_capacity_exceeded`
- **Operator queueing:**
  - `aiur --todo <ids> [--only]` queues tickets. `--only` removes `agent:todo` from other pending tickets, bounded to 50.
  - The idle backoff (`polling.idle_widen_factor` 5.0) is collapsed by `--todo`.
- **Planning convention** (skills `aiur-build` / `aiur-run`): every executable member gets `agent:todo` **when it is created**, blocked or not. Parked work uses `needs-triage` or `human:todo`.

**On merge** (`MergedTicketReconciler`, `PushRouting`):
- The blocker becomes `done` only if the PR body says `Closes|Fixes|Resolves #N`.
- `PushRouting.maybe_resume_blockees_on_merged_ticket/2` resumes only **running, paused** blockees (`paused_reason: :blocker_dependency`).
- `ticket.<blocker>.pr.merged` is in the mid-turn drain set (#2566, `b80971f89`).
- A **dependent still in `todo` is not relabelled**. On the next poll, made faster by the `issues.closed` webhook → `request_refresh`, it is simply no longer skipped and dispatches if capacity allows.
- Tests: `orchestrator/blocker_merge_wake_test.exs`, `push_routing_test.exs`, `merged_ticket_reconciler_test.exs`, `merged_ticket_dispatch_test.exs`, `dispatch_policy_test.exs`, `dispatcher_blocked_by_cost_test.exs`.

**Gaps for E1:**
- No queue entity: no membership, order or controls beyond labels and `--todo`.
- No relabel-on-unblock. Promotion only works because dependents are labelled `agent:todo` ahead of time.
- No executor-created queue without build-order data. The closest thing is `--todo --only`.
- **Semantic mismatch:** dispatch treats a `not_planned`-closed blocker as cleared (any GitHub-closed blocker counts), while the Build Order view classifies it `:terminal_unsatisfied`.
- Merge-to-ticket association relies on closing keywords in the PR body.

### E2 — Native command capture, executor awareness, human escalation — PARTIAL

**Terminology:**
- The code says **Decision** (`Aiur.Decision`, `Aiur.DecisionStore`).
- The UI, CLI and docs say **Command** (`src/lib/aiur/decision_command_type.ex`: "Data-driven classification of Command types").
- Exact UI strings **[re-verified]**:
  - `"1 unit awaiting commands"` / `"#{open} units awaiting commands"` (`components/operator_control_center/overview.ex`)
  - aria `"#{@open} Commands awaiting you, #{@blocking} blocking"`
  - CTA `Issue commands`
  - Nav `Commands` (`route_registry.ex`, path `/commands`)
  - Fleet table column `Commands` (`fleet_table.ex`, value `row.open_decision_count`)
  - `Commands inbox`, `No Commands match this filter.` (`decision_inbox.ex`)
  - `Command history`, `Executor answer`, `Deferred to Executor`, `Handed to the Executor` (`history.ex`)
  - `Defer to Executor` / `Notify Executor again`, `Retry delivery` (`decision_action.ex`)
- Not found: "commands requested", "commands needed".

**Model:** `Aiur.Decision` (`src/lib/aiur/decision.ex`).
- Identity and content fields: `decision_id`, `ticket`, `source{agent_id, session_id, event_id}`, `kind`, `authority`, `urgency`, `blocking`, `reversibility`, `question`, `context{short_summary, long_context_markdown}`.
- Options and advice: `options[{id, label, description, benefits, drawbacks, risk}]`, `recommendation{option_id, reason}`, `consequence_of_delay`, `artifacts`.
- Lifecycle fields: `decision_status`, `delivery_status`, `answer`, `revisions`, `dispatch_attempts`, `acknowledgement(s)`, `resolution(s)`, `content_hash`.
- **authority:** `:human_required | :supervisor_allowed | :supervisor_preferred`.
- **decision_status:** `:open | :deferred | :expired | :dismissed | :moot | :decided | :acknowledged | :resolved`.
- **delivery_status:** `:not_dispatched | :pending | :queued | :delivered | :consumed | :failed`.

**Authority policy** (`Aiur.DecisionAuthority`):
- `human_required` is absolute. The Executor may answer only `:reversible` items.
- Config `decisions.supervisor_allowed_kinds` (default `[]`) and `decisions.supervisor_allow_non_reversible` (default false).
- Kind defaults (`DecisionCommandType`):
  - `rework_review` → `supervisor_preferred`
  - `sequencing` → `supervisor_allowed`
  - `legacy_attention` → `human_required`
  - Anything else → `supervisor_allowed` + reversible

**Raising a Command:**
- There is no dedicated tool. The agent calls `emit_event` (`codex/dynamic_tool/emit_event.ex`) with:
  - `decision.requested` (structured payload), or
  - `attention.<slug>` (legacy, human-required), or
  - `blocked` / `pause.request` with `{reason: "operator_decision", question}`.
- Wiring in `agent_runner/tool_executor.ex`: `DecisionStore.request/2`, `DecisionAttention.open_with_decision/6`.
- `Aiur.DecisionAttention` re-asks every 15 min. The alert prefix is `"Executor decision required: "`.

**Store:** `Aiur.DecisionStore` (single-writer GenServer).
- **Persist before notify:** append and fsync to `decisions.ndjson`, update the `decisions.json` projection, then publish on the Exchange and on PubSub.
- Directory: `Config.Paths.decision_state_dir/0`.
- **Functions:** `request`, `answer/5`, `escalate_executor_command/4`, `dismiss`, `defer`, `expire`, `moot`, `supersede`, `revise`, `retry_dispatch`, `deliver_pending_answers/2`, `agent_lifecycle`, plus retained reads.
- **Event types:** `requested`, `enriched`, `decision_{expired,dismissed,deferred,mooted}`, `executor_escalated`, `answer_recorded`, `revision_recorded`, `dispatch_queued`, `delivered`, `restored`, `consumed`, `failed`, `acknowledged`, `resolved`, and others.

**Delivery to the worker:**
- `Aiur.DecisionDispatch.dispatch/2` → `OperatorMessages.send_correlated_operator_message/3`. The answer is addressed to the **ticket**, not the asking session. Maximum 7,800 characters.
- Redelivery to a newly spawned worker: `deliver_pending_answers/2` (#2713).
- An answer resumes a self-paused worker (`orchestrator/operator_messages.ex`, `PauseResume.input_pause_reason?/1` = `[:agent_pause_request, :input_required]`; #2738).

**Who answers, and from where:**
- **Dashboard:** `/commands`, `/commands/:decision_id`. Events `answer-decision`, `defer-decision`, `dismiss-decision`, `retry-decision`, `revise-decision` (`operator_control_center/decision_events.ex`).
- **Stream Deck:** `answer_command`.
- **CLI:**
  - `aiur commands [id] [--filter …] [--json]`
  - `aiur executor-answer ID --expected-version --rationale --idempotency-key (--option|--custom-response)`
  - `aiur executor-escalate ID --expected-version --reason`
  - `aiur executor-moot ID …`
- **Supervisor API** (bearer `AIUR_SUPERVISOR_TOKEN`): `GET /api/v1/decisions[/:id]`, `POST /api/v1/decisions/:id/{enrich,decide,revise}`.
- Answers carry optimistic concurrency (`expected_version`, `idempotency_key`). This is the existing mechanism for conflicting responders.

**Executor → human requests (separate store):**
- `aiur ask "Title" [--body|--body-file] [--urgency] [--blocking]` and `aiur ask --done ID` (`Aiur.Asks`, `asks_store.ex`). IDs start with `ask_` and the store is append-only.
- **Not shown in the dashboard:** `src/lib/aiur_web` has no references to `Aiur.Asks`.

**Native question capture:** none **[re-verified]**.
- **Codex** (`src/lib/aiur/codex/approvals.ex`, `user_input_answers.ex`):
  - Approval requests are auto-approved (`acceptForSession`) or declined while paused.
  - `item/tool/requestUserInput` is auto-answered `"Approve this Session"` or `"This is a non-interactive session. Executor input is unavailable."`. Anything else ends the turn as `:input_required`.
- **Claude:**
  - `permission_mode` defaults to `bypassPermissions` (`src/lib/aiur/claude/config.ex`).
  - Hooks: `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure` (`hook_settings.ex`).
  - No `AskUserQuestion` or `PermissionRequest` handling.
- **Muse** maps `userInput/request` to `:native_user_input_required` (`muse/turn_loop.ex`).

**Tests:** about 35 `src/test/aiur/decision_*_test.exs` files, `decision_store/`, `executor_command_cli_test.exs`, `executor_command_attention_test.exs`, `codex/approvals_test.exs`, `user_input_answers_test.exs`, `aiur_web/supervisor_auth_test.exs`.

**Gaps for E2:**
- Native questions are not captured.
- No executor-first versus simultaneous routing policy. Today authority decides who *may* answer; routing order does not exist. The Executor is always made aware through `DecisionAttention` alerts and wakes.
- The Executor cannot raise a Command for itself; it uses `aiur ask`, a separate store with no UI.
- No suggested-response count rule (options are free-form).
- Answers are addressed to the ticket, not the session.

### E3 — First-class executor communication — NEW (only coordination primitives exist)

**What exists:**
- The wake inbox and CLI (R2).
- `Aiur.Executor.Principal`: started only by `aiur --executor`, with a 10-minute lease.
- `Aiur.Executor.Claims.resolve_consumer_id/1`: `--as`, then `AIUR_EXECUTOR_ID`, then `<hostname>-<instance>`.
- `Aiur.Executor.Roster`: states `active | idle | stalled | expired | unknown`; `aiur executor-roster`. Its moduledoc says "Multiple executors are a supported configuration".
- `Aiur.Executor.TakeoverAlert`, `Aiur.Executor.Handoff`.
- `Aiur.ExecutorCommandAttention`.

**Claude Remote Control is for worker agents only:**
- Config `agent.remote_control` (default false; `config/schema/agent.ex`) and the routing suffix `+remote` (`config/routing_value.ex`).
- `Aiur.Claude.ReplAgent` runs `claude --remote-control` in a hidden tmux pane.
- `Aiur.Claude.RemoteControl.parse_session_url/1` (`https://claude.ai/code/session_…`).
- The TUI `r` key; `Aiur.Orchestrator.RemoteControlMode`.
- Lifecycle hook endpoint `POST /api/v1/:issue_identifier/claude-hook` (this is why `--no-dashboard` is refused when RC is on).
- Dashboard units table: an RC deep link (`title="Remote control"`) and `"Under Remote Control"` disabled controls.
- The owner's current Executor RC usage is their own Claude Code session, outside Aiur.

**Not found:**
- An Executor harness type (Claude/Codex) in principal or claims.
- Executor transcript capture or ingestion.
- A dashboard Executor page or panel.
- An Executor input channel. Searched `src/lib/aiur_web` for executor + conversation/chat.

**Current terminology:** "Executor", "wake", "claim", "roster", "principal", "takeover".

**Gaps:** essentially the whole feature, including session identity, conversation history and normalized input across Claude and Codex.

### E4 — Dashboard conversations, logs, event navigation — PARTIAL

**Routes:**
- `/` (`DashboardLive :index`), `/chat/:owner/:repository/:identifier` (the same LiveView with the drawer open), `/commands[/:id]`, `/build-orders[/:root]`, `/analytics`, `/streamdeck`.
- JSON:
  - `GET /api/v1/state`
  - `GET /api/v1/:issue_identifier`
  - `GET /api/v1/:issue_identifier/events` (`AgentEventFeed.list/2`, limit 1–50, integer cursor)
- Writes:
  - `POST /api/v1/:issue_identifier/{messages,pause,resume}` and `POST /api/v1/refresh` (writable-gated)
  - `POST /api/v1/pane/{interrupt,hide}`

**Transcript sources:**
- `Aiur.AgentLog`: workspace `logs/agent.ndjson`, falling back to `logs/agent.md`, in an 80-message window.
- `Aiur.AgentEventLog` writes both files.
- `Aiur.IssueLog`: a per-issue transcript plus event history under `<logs-root>/log`.
- `Aiur.LiveConversation` (`live_conversation.ex` + `normalizer`, `compactor`, `retention`, `source`):
  - An in-memory projection isolated per generation (80 messages / 64 KB).
  - Snapshot `state`: `:live | :ended | :known_empty | :stale | :unavailable | :restart_unknown`.
  - PubSub `live-conversation:changed`.
  - It is not voice-related, despite its name.

**UI:**
- **Conversation drawer** (`components/operator_control_center/conversation_drawer.ex`):
  - Labels `Conversation`, `Agent log`, `Last observation`, `Messages`.
  - Placeholder `Message agent…`, buttons `Pause` / `Send`, dictation and voice controls.
  - Read-only text: `Read-only dashboard — use the TUI to message or pause this agent.`
- **Agent log modal** (`agent_log_modal.ex`).

**Milestone model:**
- **`emit_alert`** (`codex/dynamic_tool/emit_alert.ex`): `name`, `message`, `reason`, `needs_attention`, optional `severity`. Topics `ticket.<id>.agent.<name>`.
- **Phase events:** `phase.{brainstorm,plan,work,review}.{start,end}` (`.claude/skills/aiur-agent/turn-workflow.md`; stages validated in `ticket_observation.ex`).
- **Alerts:** `Aiur.Alerts` (categories) and `Aiur.AlertLedger` (`*.alerts.ndjson`, 8 MiB). `Aiur.AlertFeed.list/1` reads them.
- **Ticket activity:** `Aiur.TicketActivity` (PubSub `ticket-activity:changed`).
- **Workpad:** an `## Agent Workpad` GitHub comment. It is not rendered in `aiur_web`.
- **Progress updates every few minutes** **[re-verified]:** `Aiur.ProgressCheckin.Worker` publishes `ticket.<id>.operator.progress_request` to **worker** agents every 5 min (`@default_interval_ms 5 * 60 * 1_000`). Agents reply with `progress` / `progress.checkin`, which drive the "Executor bar". These are worker progress reports that the Executor sees. No Executor-authored progress stream was found.

**Jump points:**
- **Bus labels** (`Aiur.AgentEventFeed @topic_labels`): `Progress`, `Progress check-in`, `Phase change`, `Blocked`, `Unblocked`, `Paused`, `Resumed`, `Pause requested`, `Remote control`, `Tokens exhausted`, `Comment`, `PR opened`, `PR merged`, `Review comment`, `CI passed`, `CI failed`, `Decision requested`, `Decision seen`, `Decision resolved`.
- **Build Order ticket context** (`build_order/ticket_context_presenter.ex`):
  - Phase labels and "Pull request updated", "Branch updated", and similar.
  - Capability links `Issue`, `Pull request`, `Chat`, `Commands`, `Planning doc`.
  - #2891 opens Build Order worker chats.

**Event→conversation anchor:** only `AiurWeb.StreamdeckLogs`, using the timestamp-based "last event at or before" rule (R6). There are no byte offsets or line numbers.

**Tests:** `src/test/aiur/{agent_log,alert_feed,alerts,live_conversation,live_conversation_restart}_test.exs`, `aiur_web/streamdeck_logs_test.exs`, `aiur_web/dashboard_live_test.exs`, `aiur_web/operator_control_center/*`.

**Gaps for E4:**
- No commit jump point (`ticket.*.branch.push` exists on the bus but has no label in the feed).
- No Command→transcript link.
- No dashboard chronology view keyed by event (the Stream Deck has one).
- `LiveConversation` is bounded and in-memory. Full history must come from `IssueLog` and workspace logs.
- No Executor stream.

### E5 — First-party dashboard voice input — EXISTS for worker chat; PARTIAL against the brief

**Evidence:**
- Drawer controls: `data-voice-mic`, `data-voice-conversation`, `data-voice-device` (labelled "Browser microphone" / "Default microphone"), `data-voice-waveform` ("Microphone waveform"), `data-voice-status`, `data-voice-send`.
- Help text **[re-verified]**: `"Press the microphone to dictate. Review the text, then press Send."`
- Dictation is a toggle, not hold-to-talk. **The transcript is reviewed before sending in dictation mode** (the existing behaviour).
- JS: `src/priv/static/conversation-voice-controller.js` and `voice-capture-worklet.js`, loaded in `components/layouts.ex`.
- Channel `voice:dictation`. Browser test `src/test/browser/tests/units.browser.spec.mjs`.

**Gaps:**
- No mic on dashboard Command answers. The Stream Deck has dictated Command answers; the dashboard does not.
- No Executor target.
- No explicit cancel or delivery-state UX beyond the composer.

### E6 — Independent conversational voice component — PARTIAL (embedded, not independent)

**Evidence:**
- Channel `voice:conversation` (`AiurWeb.VoiceChannel`) is half-duplex.
  - The user presses, speaks and presses again.
  - On `stopped` the form auto-submits (`submitConversationTurn` → `form.requestSubmit`).
  - The client watches for the worker's next completed reply (`.conversation-message-agent[data-message-complete='true']`) and sends `speak`. The server streams TTS PCM back (`audio`, `audio_done`, `audio_error`).
- Config `elevenlabs.voice_id`.
- **Note:** this mode sends the spoken turn straight to the worker agent with no review step. That is a different contract from dictation mode.

**Not found:**
- ElevenLabs Conversational AI or Agents API (`convai`).
- An assistant persona or role pre-context.
- A transcript store for voice conversations separate from the agent conversation.
- A raw-audio retention policy. Audio is streamed and not stored.

**Gaps:** E6's "communication-oriented assistant that consults the agent" does not exist. Today the voice conversation *is* the worker conversation.

---

## 3. Bucket 3 — Mobile and watch

### N1 — Cross-platform application architecture — NEW

**Not found:** react-native, expo, capacitor, flutter, `manifest.json`/webmanifest, service worker, `PushSubscription`. Searched everywhere except `node_modules`, `_build` and `docs/`.

**Existing web foundations a WebView could reuse:**
- Phoenix LiveView dashboard with a viewport meta tag and `apple-touch-icon` (`components/layouts.ex`).
- `src/priv/static/dashboard.css` has 39 `@media` rules (320–1024 px) plus `forced-colors`.
- Earlier mobile layout fixes: "Narrow the mobile nav into a centered pill" (`815052386`) and "Fix build-order Fit on mobile" (`869ceab1c`).

**Constraints a WebView would hit:**
- Basic Auth on every request.
- Same-origin and `X-Aiur-Request` checks on writes.
- Session-proof LiveView sockets.
- The `/voice` socket requires a CSRF token plus a session.

### N2 — Machine-level pairing and discovery — NEW (local seed only)

**What exists:**
- **Per-instance identity** (`packaging/npm/aiur-cli/libexec/aiur-engine.sh`):
  - `aiur_instance_key()` = the first 10 hex characters of sha256(realpath(project root)).
  - Node name `aiur-$USER[-KEY]@127.0.0.1`; tmux socket and session `aiur-$USER[-KEY]`.
- **Instance records:** `write_aiur_instance_record()` writes `${XDG_CONFIG_HOME:-~/.config}/aiur/instances/<node-slug>.instance`, mode 0600. Fields: `AIUR_RECORD_{NODE,INSTANCE_KEY,SESSION,SOCKET,AGENT_TMPFILE,SURFACE_MODE,WORKSPACE_ROOT_FILE,PROJECT_ROOT,PROJECT_ROOT_SOURCE,WRITTEN_AT}`.
  - **The record does not hold the dashboard host or port.**
  - The only reader is `resolve_control_identity_from_records()`, which handles control-command fallback by probing node liveness.
  - **[host]** Stale records persist. The owner's machine has 8 records dating back to 2026-07-28.
- **Lifecycle journal:** `<repo>.control-lifecycle.json` records starts and stops with pid and hostname.
- **Global machine config:**
  - `~/.aiur/config` is the fallback config.
  - `~/.aiur/.env` holds global secrets.
  - `~/.config/aiur/` holds distribution state (cookie, instances, `streamdeck.env`).

**Not found:**
- Pairing, QR, device tokens or keys.
- mDNS, Bonjour or avahi.
- A user-facing `aiur instances` / list command (`aiur status` is per instance).

### N3 — Meta-dashboard — NEW

- No multi-instance UI.
- Per-instance data a meta view could aggregate already exists:
  - Open and blocking Command counts (the `overview.ex` banner).
  - Active agents and capacity (`aiur status`, `/api/v1/state`).
  - Build-order progress (`RootSummary.progress`).
  - Executor roster state (`aiur executor-roster`).
- A second instance on the same fixed port disables only its own dashboard (configuration.md § server).

### N4 — Private, encrypted, rich background notifications — NEW

**Not found:** apns, fcm, firebase, web push, ntfy, pushover, notify-send, Slack/Discord/Twilio sinks.

**Existing notification-adjacent pieces:**
- **Local sounds:** `Aiur.Alerts`, config `alerts.{enabled,use_os_default_sounds,sound_dir,alerts_file}`.
- **Alert ledger:** `aiur alerts`.
- **Executor wakes:** consumed by an agent through `executor-wait`.
- **Daemon heartbeat:** `daemon_heartbeat.ex`, `monitoring.daemon_heartbeat_stale_ms`.
- **"Push" in code means git push:** `Aiur.Orchestrator.PushRouting`.

**Khala** (a separate product, `aiur-team/khala`):
- "Encrypted chat between agents" at `khala.aiur.team` (`website/docs-app/khala/quick-start.md`: "one end-to-end encrypted channel"). It also has a local-only channel mode.
- In this repo it is docs only; no integration code exists in `src/lib`.
- It is a possible prior-art or reuse candidate for an encrypted relay. That is unverified and needs research in the Khala repo.

### N5 — Notification preferences and progress updates — NEW

- No preference model.
- Signals that already exist:
  - `ticket.*.pr.merged` (Executor bindings and the feed).
  - Build-order `RootSummary.progress`.
  - `ticket.*.branch.push`.
  - Comments (`ticket.*.issue.commented`).

### N6 — Contextual command response — PARTIAL (non-mobile surfaces)

- **The Command payload already carries what the response view needs:** `question`, `context.short_summary` (a candidate for the short notification summary), `options` (suggested responses), `recommendation`, `consequence_of_delay`, `urgency`, `blocking`.
- **Answer paths:** the dashboard and the Stream Deck, with focus targeting and dictated `custom_response`.
- **Concurrency:** answers are idempotent and carry `expected_version`.
- **Gaps:** no deep-link scheme. The closest is the route `/commands/:decision_id`. No phone or watch client.

### N7 — Watch applications — NEW

- Not found. Searched watchos, wearos and watch. The only hit is the unrelated test fixture directory name `watchos` in `src/test/aiur/init_test.exs`.

---

## 4. Repository facts that answer brief questions (do not ask the owner)

1. **Domain:** the Cloudflare hostname is **`hooks.aiur.dev`**. Its purpose is GitHub webhook ingress, to cut poll latency and API budget. It is inbound-only and path-scoped. It is not a relay, push or auth service, and the repo contains no worker or relay code.
2. **Tailscale is already optional.** Since #2995 no code depends on it. The default bind is loopback. A non-loopback bind without credentials refuses to start. The owner's private setup works by pinning `server.host` explicitly.
3. **The UI term for agent input requests is "Commands".**
   - Counts read "N units awaiting commands", with aria "N Commands awaiting you, M blocking".
   - The page is `/commands`, titled "Commands inbox".
   - Code calls them Decisions.
   - "Commands requested" and "commands needed" do not appear.
4. **The readiness label is `agent:todo`.** No backlog label exists. Blocked tickets are pre-labelled `agent:todo` and skipped by `{:skip, :dependency}` until every blocker is terminal or closed.
5. **Unblocked tickets are not "promoted".** They become eligible on the next poll after the blocker closes (sped up by webhook). Paused blockees that are already running get resumed on `ticket.<blocker>.pr.merged`.
6. **Authority values:** `human_required`, `supervisor_allowed`, `supervisor_preferred`. The Executor can answer only reversible, non-`human_required` items. Kinds are allowed through `decisions.supervisor_allowed_kinds`, which defaults to empty, so no kinds are allowed out of the box.
7. **Executor escalation already exists:** `aiur executor-escalate`, the `executor_escalated` event, and the "Deferred to Executor" / "Handed to the Executor" UI states.
8. **Native Claude/Codex questions are never surfaced.** Codex questions are auto-answered or end the turn as `input_required`. Claude runs `bypassPermissions` with no question hook.
9. **The Executor has no conversation in Aiur.** Remote Control is a worker-agent feature (`agent.remote_control`, `+remote`). The owner's Executor RC is outside Aiur.
10. **"Progress updates every few minutes"** are worker `progress.checkin` replies to a 5-minute `ticket.<id>.operator.progress_request`. They are not Executor-authored.
11. **Voice is daemon-relayed:**
    - ElevenLabs realtime STT, `scribe_v2_realtime`. The key is held only by the daemon.
    - Clients stream PCM over Phoenix websockets.
    - Delivery to an agent is always a human-pressed Send of reviewed text, except dashboard conversation mode, which auto-submits.
    - Voice never targets the Executor.
12. **Dashboard voice already exists:** dictation plus an STT→agent→TTS conversation mode. E5 and E6 extend it rather than starting from nothing. The "review before send" question is answered *for dictation* by current behaviour ("Review the text, then press Send"). Conversation mode does not review.
13. **The Stream Deck is already a separate package** (`packages/streamdeck`, `@aiur/streamdeck`). It uses only the `streamdeck:fleet` channel plus a token endpoint. The dashboard emulator (`/streamdeck`) needs no hardware. The event-keyed log is built daemon-side in `AiurWeb.StreamdeckLogs`.
14. **Instances per machine** are keyed by a project-root hash and recorded in `~/.config/aiur/instances/*.instance`. The records lack the dashboard URL and are never garbage-collected. No list command exists.
15. **Dashboard auth is one shared Basic Auth pair** (`AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD`) plus an optional supervisor bearer. There are no per-device credentials.
16. **The default `server.port` is 0** (a random port each boot). Any phone or tunnel needs a pinned port or an advertised URL.
17. **Bus replay:** ticket topics replay to agents from `IssueLog` (`BootstrapDigest`), and `executor.*` replays from the executor journal. System topics and Executor wakes for ticket or system events cannot be replayed. There is no external client subscription API.
18. **Khala** is a sibling E2E-encrypted chat product (`khala.aiur.team`). This repo contains no Khala integration.
19. **No draft PR exists for the research branch**, so Phase A cannot rely on PR discussion. The prior plan's U3 and U6 units already own the files that R2 and E2 touch: `subscription_store.ex`, `executor/claims.ex`, `executor_wake_inbox.ex`, `decision_store.ex`.

## 5. Questions that remain for the owner (not answerable from the repo)

These are listed only so that they are not confused with the facts above. They are product decisions.

- **E2:** the executor-first versus simultaneous default.
- **E5/E6/N6:** dictation versus live conversation when the mic is activated. Today dictation reviews before sending, and conversation mode auto-sends.
- **E1:** queue ordering beyond tracker priority and age, and the controls and visibility the queue should have.
- **E4:** what "write" means in the dashboard (messages already exist; steering and interrupt are partly there through `pane/interrupt`).
- **E6:** raw-audio retention.
- **N4:** whether Khala's encryption model should be evaluated as a reuse candidate.

## 6. Search log for "not found" claims

| Claim | Searched |
| --- | --- |
| No relay or worker code | `find -iname '*wrangler*' -o -iname '*cloudflared*' -o -iname '*tunnel*'`; `grep -ri 'cloudflare\|wrangler'` outside `docs/` |
| No Tailscale code | `grep -rli 'tailscale\|tailnet\|ts.net\|magicdns\|100.64\|funnel'` over `src/lib packaging scripts packages .aiur .claude src/examples` (one skill hit only) |
| No mobile, push or pairing code | `react.native\|expo\|capacitor\|apns\|fcm\|firebase\|PushSubscription\|serviceWorker\|webmanifest\|qrcode\|mdns\|bonjour\|avahi\|wearos\|watchos\|ntfy\|pushover\|notify-send` |
| No native question capture | `AskUserQuestion\|elicitation\|PermissionRequest` in `src/lib`; read `codex/approvals.ex`, `codex/user_input_answers.ex`, `claude/config.ex`, `claude/hook_settings.ex` |
| No auto-promotion | `promote\|auto_promote\|backlog\|unblock` in `src/lib/aiur/orchestrator` and `build_order`; callers of `Tracker.update_issue_state(.., "todo")` (only `auto_resume.ex`, `pause_resume.ex`, `human_review.ex`) |
| No Executor dashboard surface | `executor` with `conversation\|chat` in `src/lib/aiur_web`; no `Aiur.Asks` reference in `src/lib/aiur_web` |
| No ConvAI | `convai\|conversational` in `src/lib`, `packages/streamdeck/src`, `website/docs-app` |
| No system-topic replay | `bootstrap_replay\|replay_from\|def replay` in `src/lib` (only DecisionLog, ExecutorEvents, DecisionMetrics.Log, CurrentRunMembership); `BootstrapDigest` comment |
| No research-branch PR | `gh pr list --repo aiur-team/aiur --head research/refactor-findings --state all` → `[]` |
