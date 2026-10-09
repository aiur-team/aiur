# MP-R1 capability and dependency matrix

Part of the [MP-R1 plan](plan.md). Component IDs are from
[component-map.md](component-map.md). Capability IDs and their wire shape are defined
in [contracts/identity-and-capabilities.md](../../contracts/identity-and-capabilities.md).

Base `45a290e3`. "Today" columns describe verified current behaviour; everything else
is the target after MP-R1. A capability is never reported as working when a component
it needs is absent: it is reported `unavailable` with a reason (brief §4 R1, KTD4).

## 1. Run shapes that exist today

`Aiur.Application.child_specs/1` (`src/lib/aiur.ex:244-486`) already composes the
supervision tree from five booleans. These are the seed of the capability registry:

| Flag | Source | Children it gates (verified) |
|---|---|---|
| `dashboard?` | `--no-dashboard` absent | `AiurWeb.ControlCenterCache`, `FinancialData.Supervisor`, `Aiur.HttpServer` (`aiur.ex:467-469`) — **the whole HTTP listener, not only the pages** |
| `headless?` | `--bg` | `Aiur.Opencode.PaneSupervisor` (`aiur.ex:473`) |
| `interactive_cli?` | foreground | tmux, pane manager, prewarm, agent list (`aiur.ex:260-272`) |
| `recording?` | always true in a real run | `Executor.Claims`, `ExecutorWakeInbox`, `ExecutorListener` (`aiur.ex:503`), `AllowedContributors` |
| `executor_mode?` | `aiur --executor` | `Executor.Principal` |

Facts that shape the matrix:

- `--no-dashboard` removes the HTTP endpoint, so it also removes the Stream Deck
  socket, the voice socket, the Supervisor Decision API and the Claude Remote Control
  hook (AGENTS.md: `--no-dashboard` is refused when Remote Control is on). The target
  splits `web-shell` (API and sockets) from `dashboard-ui` (pages) so that a client can
  have the API without the pages. That split is MP-R1-C6.
- Build orders are display-only for dispatch: no orchestrator module references
  `Aiur.BuildOrder` (verified), and `Readiness.from_edges/1` is used only by web
  presenters (baseline E1). Removing build orders cannot change dispatch.
- The orchestrator is always started (`aiur.ex:442`). There is no "no orchestration"
  run shape today; the target adds one only for `identity` + `pairing-discovery` +
  read-only surfaces (see §4).

## 2. Capability IDs

| Capability | Provided by | Needs (required components) | Detected today by |
|---|---|---|---|
| `identity` | identity | — (`identity.json` readable, `AIUR_INSTANCE_KEY` valid) | none (new, Phase C) |
| `api.http` | web-shell | run shape with the HTTP listener | `--no-dashboard` absent (new, Phase C) |
| `orchestration` | orchestration (provider reads `Process.whereis/1` and `Orchestrator.SnapshotStore.read/3`, never the orchestrator mailbox) | harness-adapters (≥1), agent-runner, workspace, tracker, listener-modes, commands | `orchestrator_unavailable` in `GET /api/v1/state` (`presenter.ex:33`); `degraded/snapshot_stale` when the snapshot ages past its budget (X-19) |
| `instance.status` | control-cli, projections | orchestration | `aiur status`, `GET /api/v1/state` |
| `agents.run` | orchestration | harness-adapters (≥1), agent-runner, workspace, tracker | always on |
| `agents.message` | orchestration (`AgentChat.send/3`, which delegates to the required listener-modes send router `Aiur.Listener.send/3`, RC-36) | listener-modes; `api.http` for remote; control-cli locally | `observability.dashboard_writable`; drawer read-only text |
| `commands.read` | commands | web-shell (remote) | `/commands` page, `GET /api/v1/decisions` |
| `commands.answer` | commands | orchestration (delivery to the agent) | same, gated by writable + auth |
| `commands.supervisor_api` | commands, web-shell | `AIUR_SUPERVISOR_TOKEN` set | route returns 401/503 without the token |
| `build_orders` | build-orders | github (GraphQL graph), tracker | `/build-orders` page; `aiur build-orders` |
| `build_orders.progress` | build-orders (owns `Aiur.BuildProgress`, RC-40; MP-E1-C7 writes the code, and the queue is one producer) | build_orders; **not** build_queue, so D18's default progress notifications work without the queue | `RootSummary.progress` |
| `build_queue` | build-queue (MP-E1); provider ticket **MP-E1-C3-T08** (X-21) | tracker, event-bus | none (new). Status mapping: `running` → `available`; `disabled` → `unavailable/disabled`; `unsupported_tracker` → `unavailable/unsupported_tracker`; `store_unavailable` → `unavailable/store_unavailable`; `writes_paused` → `degraded/writes_paused` |
| `build_queue.build_order_source` | build-queue; provider ticket **MP-E1-C3-T08** | build_orders | none (new). `available` when the BuildOrder `DependencySource` is selected; `unavailable/dependency_unavailable` with `depends_on: ["build_orders"]` when build orders are not available, or `["build_queue"]` when the queue itself is not |
| `conversations.read` | conversations | agent-runner logs | `/chat/...` drawer, `GET /api/v1/:id/events` |
| `conversations.anchors` | conversations | event-bus history (`IssueLog`) | Stream Deck logs mode only |
| `executor.wakes` | executor-attention | recording on | `executor-wait` |
| `executor.conversation` | executor-attention (registered by MP-R1-C3-T02; MP-E3 fills `executor.harness` and `session_ref`) | an Executor harness that exposes a session | none (new); entry carries `route` (`/executor`, MP-E3-C6-T01; CR-N3-1) |
| `executor.background_agents` | executor-attention (MP-E3-C4-T02) | an attached Executor harness with subagent hooks | none (new); read `Aiur.Executor.BackgroundAgents.snapshot/0`; `unavailable` + reason when the harness is unsupported, never an empty list (CR-N3-3) |
| `harness.<id>.native_question` | harness-adapters (MP-R7 provider) | that harness | none (new); entry carries `mode` ∈ `in_band_hold`, `defer_resume`, `none` (CR-E2-6) |
| `events.export` | event-bus external API (MP-R2; carries `{v, retention}`) | `api.http` | none (new); when the operator turns it off it reports `unavailable/disabled`, never an absent ID (X-07) |
| `listener_modes` | listener-modes (MP-E7, a **required** core component: the send router, RC-36); provider ticket **MP-E7-C3-T06** (X-21) | harness-adapters; build-time input `listener-spec` | none (new). The capability says whether the *modes* work, not whether sends work: sends always work. Spec valid and routing flag on → `available`; flag `:listener_send_routing` = `:legacy` → `unavailable/disabled`; vendored spec absent → `unavailable/not_installed`; checksum or schema failure → `unavailable/spec_invalid`. In every unavailable case the router uses `:legacy` routing |
| `voice.stt` | voice-stt | web-shell, `elevenlabs.api_key` | channel join error "not configured" |
| `voice.tts` | voice-stt | same + `elevenlabs.voice_id` | conversation mode controls |
| `voice.conversation` | voice-conversation (MP-E6; the aiur adapter computes it from `VoiceConverse.availability/1`, MP-E6 plan §17) | voice-stt (`voice.stt` available; ElevenLabs provider only, since an OpenAI provider needs no voice-stt), listener-modes (send path, voice V7); `commands` and `conversations` are optional ports with fallbacks (MP-E6 §2, X-28); `voice.conversation.agent_id` set, last privacy preflight not failed; `degraded` (text-only) when `voice.tts` is unavailable (voice-session §7; E6 R-4) | prototype `voice:conversation` |
| `streamdeck` | streamdeck-server | web-shell, dashboard credentials | `POST /api/v1/streamdeck/token` |
| `webhook_ingress` | github-listeners | web-shell, `AIUR_GITHUB_WEBHOOK_SECRET`, an operator tunnel | `Webhooks.DeliveryMode` (`:never_configured` .. `:degraded`) |
| `remote_control` | harness-adapters (Claude) | web-shell (hook endpoint) | `agent.remote_control`, `+remote` |
| `pairing` | pairing-discovery (MP-N2) | identity, machine-gateway (its own listener; works with `--no-dashboard`, MP-N2 plan; X-27) | none (new) |
| `push` | push-relay (MP-N4) | pairing, commands, event-bus, `runtime.crypto`; reported in every run shape with the event bus, including `--no-dashboard` (CR-N4-4) | none (new) |
| `runtime.crypto` | push-relay (MP-N4-C1-T01 runtime guard) | OTP `:crypto` with X25519, Ed25519 and the HPKE primitives | none (new) |
| `tracker.github`, `tracker.linear` | github, linear | tracker | `tracker.kind` |
| `accounting.meters` | accounting | provider keys | Units page meters absent when unconfigured |

## 3. What still works when a component is absent

`yes` = unchanged. `no` = unavailable, and the surface must say so. `partial` = the
cell explains. The rightmost column is the minimum companion that brings it back.

| Capability ↓ / absent → | dashboard-ui | web-shell (`--no-dashboard`) | orchestration | build-orders | voice-stt (no key or no package) | executor (no live Executor) | streamdeck | github-listeners webhook (polling only) | Tailscale | push-relay / pairing |
|---|---|---|---|---|---|---|---|---|---|---|
| `agents.run` | yes | yes | **no** | yes | yes | yes | yes | yes (slower; poll cadence) | yes | yes |
| `instance.status` | yes (CLI, API) | yes (CLI only) | partial: `orchestrator_unavailable` (`presenter.ex:33`) | yes | yes | yes | yes | yes | yes | yes |
| `agents.message` | yes (CLI, TUI, API) | yes (CLI, TUI) | **no** | yes | yes | yes | yes | yes | yes | yes |
| `commands.read` | partial: API and CLI only | partial: CLI only | yes (durable store) | yes | yes | yes | yes | yes | yes | yes |
| `commands.answer` | partial: CLI, API, deck | partial: CLI only | **no**: recorded but not delivered until orchestration returns | yes | yes (typed) | yes; human-only routing (D9) | yes | yes | yes | yes (other clients) |
| `build_orders` / `.progress` | partial: CLI `aiur build-orders` | partial: CLI only | yes (reads GitHub directly) | **no** | yes | yes | yes | yes | yes | yes |
| `build_queue` | yes (CLI, D7) | yes (CLI) | partial: promotes labels; nothing dispatches | partial: ad-hoc list only (D5) | yes | yes | yes | yes (slower) | yes | yes |
| `conversations.read` | partial: API only | partial: logs on disk, TUI | partial: history on disk; no live stream | yes | yes | yes | yes | yes | yes | yes |
| `executor.conversation` | partial: API (MP-E3) | **no** remote; local harness only | yes if the harness runs | yes | yes | **no** (`unavailable: executor_absent`) | yes | yes | yes | yes |
| `voice.*` | **no** in browser (deck still works) | **no** (sockets gone) | partial: dictation works, delivery fails | yes | **no**; text input unaffected (baseline R5) | yes | yes | yes | yes | yes |
| `streamdeck` | yes (sidecar uses API + socket, not pages) | **no** | partial: shows `orchestrator_unavailable` | yes (no BO keys) | partial: no mic | yes | **no** | yes | yes | yes |
| `push` (target) | yes | yes: the relay client needs the bus, identity and pairing only; loading context after a push needs `api.http` (X-27) | partial: Commands still notify; progress notifications stop | partial: no progress % notifications (D18) | yes | yes | yes | yes | yes | **no** |
| mobile meta-dashboard (target) | partial: counts only, "open dashboard" disabled | **no** (machine unreachable) | partial: instance shows `orchestration: unavailable` | partial: no build-order % (absent, not 0) | yes (mic hidden) | partial: Executor state `absent` | yes | yes | yes, if another private network or loopback tunnel is configured | **no** |

Rules every client follows (from the contract):

1. A missing capability renders as **absent or explicitly unavailable**, never as 0,
   empty or "idle" (brief N3, AGENTS.md "unknown/unavailable rendering").
2. `unreachable` (instance did not answer) and `stale` (answer older than its freshness
   budget) are different states from `unavailable` (answered, capability off).
3. A client that does not recognise a capability ID ignores it.

## 4. Minimum useful combinations

| Use | Minimum components | Not needed |
|---|---|---|
| Run agents on tickets (headless) | kernel, config, event-bus, signal, identity, tracker + one of github/linear, agent-sandbox, workspace, harness-adapters (≥1), agent-runner, listener-modes (send router, RC-36), orchestration, commands (required: the dispatch gate fails closed on an unreadable store, CR-C8-3), projections, control-cli, launcher | web-shell, dashboard-ui, tui, build-orders, build-queue, listener-spec (routing falls back to `:legacy`), voice, streamdeck, push |
| Run agents with Commands answered by a human | above + (web-shell for remote, or CLI) | dashboard-ui (CLI suffices) |
| Keep the queue full (E1 outcome) | headless set + build-queue | build-orders (ad-hoc list works), dashboard-ui |
| Queue from a Build Order tree | above + build-orders + github | dashboard-ui |
| Executor operating the run | headless set + executor-attention + commands | dashboard-ui, voice |
| Stream Deck | headless set + web-shell + streamdeck-server + conversations + commands + sidecar | dashboard-ui pages, build-orders, voice (mic hidden) |
| Dashboard voice dictation | headless set + web-shell + dashboard-ui + voice-stt + key | streamdeck, build-orders |
| Phone: see instances, get blocker pushes, answer | headless set + commands + web-shell + identity + pairing-discovery + push-relay + aiur-contracts + mobile-app | dashboard-ui (needed only for "open instance dashboard"), build-orders, voice, Tailscale |
| Phone: build-order progress | phone set + build-orders | build-queue (RC-40) |
| Watch | phone set + watch-apps (MP-N7 decides companion vs standalone) | — |
| Pairing and discovery only (no agents) | kernel, config, identity, pairing-discovery, machine-gateway | orchestration and everything above it (brief N2: pairing must not need the whole stack) |

## 5. Minimum companion requirements (stated plainly)

- **Answering a Command needs orchestration to deliver it.** The answer is durable
  (`decisions.ndjson`, persist-before-notify) but reaches the agent only through
  `OperatorMessages` (baseline E2). A client must show "recorded, not delivered" while
  orchestration is down; it must not show "sent".
- **Every remote client that reads an instance needs `web-shell`.** That includes the
  Stream Deck, voice, the phone's instance views, the watch (through the phone or
  directly) and Remote Control. Pairing and push do not: the MP-N2 machine gateway is its
  own process, and the relay client needs only the bus (X-27).
- **Sends never depend on the listener spec.** The send router is required core
  (`Aiur.Listener.*`); the Khala-published spec is a build-time input. Without a valid
  spec the router uses `:legacy` routing and reports `listener_modes` unavailable (RC-36).
- **Voice needs a key and the daemon.** The key stays daemon-side; no client holds it
  (baseline R5; the unwired sidecar TTS provider is the known exception to remove in
  MP-R5).
- **Build-order % needs build-orders and GitHub, not the queue.** `Aiur.BuildProgress`
  belongs to build-orders (RC-40). With Linear there is no build order; the capability is
  `unavailable: unsupported_tracker`.
- **Executor conversation needs an Executor harness that exposes its session**
  (MP-E3). A Claude Executor outside Aiur (the owner's Remote Control today) is
  `unavailable: executor_not_managed` until MP-E3.
- **Push needs pairing.** An unpaired phone gets nothing; a paired phone that cannot
  reach the machine still gets encrypted pushes but cannot load context (MP-N4).
- **Tailscale is never required.** Reachability is the operator's choice (MP-R3);
  authorization is pairing (MP-N2). The capability report never says "Tailscale".
