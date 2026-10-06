# Capability baseline — Bucket 1 (refactor, R1–R6)

Part of the [capability baseline](capability-baseline.md) (Phase A), split out to keep each file under 500 lines. Verified against `origin/main` @ `45a290e3`; the status legend (EXISTS, PARTIAL, NEW), method and summary table are in the [index](capability-baseline.md). Other parts: [bucket 1](capability-baseline-bucket-1.md), [bucket 2](capability-baseline-bucket-2.md), [bucket 3](capability-baseline-bucket-3.md).

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

