# Feature inventory

The confirmed feature list for this pack, as settled in the brainstorm on 2026-10-06. Each row gives the bucket, the feature's baseline status (from [baseline/capability-baseline.md](baseline/capability-baseline.md), pinned to `45a290e3`), the intended behaviour, and the owner design gate.

Decision numbers (D1–D20) refer to [context-and-decisions.md](context-and-decisions.md) § Key Decisions. Brief sections are in [brief.md](brief.md).

## Bucket 1 — Refactor (behaviour-preserving)

| ID | Feature | Baseline | Intended outcome | Owner gate |
| --- | --- | --- | --- | --- |
| MP-R1 | Modular platform and component map | PARTIAL (research only) | Extend prior U0–U9 and the 36-boundary map to cover the dashboard, GitHub listeners, orchestration, build orders, Commands and supporting services. Deliver a component and dependency map, public interfaces, required versus optional dependencies, config ownership, a capability matrix, and a migration plan. **Also delivers the public component directory page** (D20, MP-REQ4). | DESIGN-R1: confirm no user-facing change, and design the component directory page |
| MP-R2 | Standalone event bus | PARTIAL | Package the in-process topic exchange as its own component. Define event identity, ordering, replay and reconciliation, versioning, and an external subscriber API. Resolve which bus owns which facts (MP-Q5). | DESIGN-R2: confirm no user-facing change |
| MP-R3 | Optional Tailscale | EXISTS (already optional) | Record and test the existing optional state. Map URL and address ownership. Prove that disabling Tailscale never makes a sensitive endpoint public. Likely a small hardening and docs chunk. | DESIGN-R3: confirm no user-facing change |
| MP-R4 | Cloudflare / GitHub App relay | EXISTS (inbound webhook only) | Document `hooks.aiur.dev` as an inbound webhook tunnel. Put a replaceable provider boundary around relay transport. Assess reuse for push relay (MP-Q2) without requiring Cloudflare. | DESIGN-R4: confirm no user-facing change, plus relay config UX |
| MP-R5 | ElevenLabs speech-to-text | EXISTS (in core) | Extract `Aiur.ElevenLabs.Realtime` and its socket relay into an optional voice package. A missing key or an absent package must leave text interaction intact. | DESIGN-R5: confirm no user-facing change, plus key setup UX |
| MP-R6 | Stream Deck package | EXISTS (separate package) | Split the shared daemon-side projections (`StreamdeckLogs`, `StreamdeckProjection`, event-to-log anchors) from hardware presentation, so the dashboard can use them without the deck. | DESIGN-R6: confirm no user-facing change |
| MP-R7 | Harness adapter package | NEW (added in brainstorm) | Extract the per-model shims and wrappers (Codex app-server, Claude via aiur-claude, OpenCode and others) behind one harness-adapter interface. Behaviour-preserving. It is the substrate for MP-E2 native capture and MP-E7 listener modes (D14). | DESIGN-R7: confirm no user-facing change |

## Bucket 2 — Platform improvements

| ID | Feature | Baseline | Intended outcome | Owner gate |
| --- | --- | --- | --- | --- |
| MP-E1 | Build queue | PARTIAL | A separately bounded queue component, shipped before the refactor on a seam (D2). It has an optional build-order dependency and an executor- or user-created ordered list with "after #N" edges (D5). Ready tickets are promoted to `agent:todo` at once, and dispatcher gates decide starts (D4). Ordering is critical path first, then priority, then age (D3). A failed prerequisite holds and alerts (D6). Un-promote if not yet claimed (D8). Controls: CLI plus a read-only dashboard view (D7). | DESIGN-E1: dashboard queue view, CLI output |
| MP-E2 | Native command capture and escalation | PARTIAL | Capture only native ask-the-user tools as Commands (D10). Route by declared authority (D9). The first answer wins, and a human can supersede until delivery (D11). Executor-originated Commands use the same system (D12). Never let a request vanish because the Executor did not act. Two or three suggested responses. | DESIGN-E2: Command request and response presentation, escalation states |
| MP-E3 | Executor communication | NEW (primitives only) | Read the Executor conversation and send it input through a harness-normalized interface, for Claude and Codex Executors. Show status, blockers and background agents when available. Same conversation system as workers, kept distinct in presentation. | DESIGN-E3: Executor conversation surface |
| MP-E4 | Dashboard conversations and event navigation | PARTIAL | Full worker and Executor transcripts in the dashboard, with event jump points (progress updates, commits, PR creation, merges, Command requests) anchored to conversation positions. Write access is limited to sending messages and answering that agent's open Commands (D15). | DESIGN-E4: conversation layout, event navigation |
| MP-E5 | Dashboard voice input | EXISTS (worker chat only) | Mic input on Command responses and on agent and Executor views, reusing MP-R5. An explicit dictate or converse button choice (D16). Recording, transcription, delivery and cancel states. A no-key fallback. No raw audio kept (D17). | DESIGN-E5: voice controls (shared with E6, N6) |
| MP-E6 | Conversational voice component | PARTIAL (prototype) | A reusable conversational assistant with configurable role pre-context. It works on a worker ticket or with the Executor on the project, and defines what becomes an instruction. Full local transcripts, no raw audio (D17). Provider choice is MP-Q3. | DESIGN-E6: conversational mode UX |
| MP-E7 | Shared agent-listener package | NEW (added in brainstorm; Khala has the contract) | One package shared with Khala that implements steer, sync and async listener modes over MP-R7 adapters, default sync (D13). The operator can set the mode per agent. Package home is MP-Q1. | DESIGN-E7: mode selector and status presentation |

## Bucket 3 — Mobile and watch

| ID | Feature | Baseline | Intended outcome | Owner gate |
| --- | --- | --- | --- | --- |
| MP-N1 | Cross-platform app architecture | NEW | An evidence-based framework recommendation for iOS and Android (MP-Q4), a web versus native boundary per surface, a code-sharing strategy, a capability model and packaging. | DESIGN-N1: confirm the native versus WebView split per surface |
| MP-N2 | Pairing and instance discovery | NEW (local seed) | Machine-level durable pairing by QR from global settings. Full access to every instance on that machine (D19). Revocable per device, with remote unpair-all. Discovery built on `~/.config/aiur/instances`. Authorization is separate from reachability. | DESIGN-N2: setup, pairing, revocation |
| MP-N3 | Meta-dashboard | NEW | A list of instances with repository, active agents, Executor state, Commands-awaiting count, build-order % and background agents. Unavailable and stale states are distinct from zero. Opens the instance dashboard; Executor chat is secondary. No combined inbox. | DESIGN-N3: meta-dashboard, per-instance navigation |
| MP-N4 | Encrypted background notifications | NEW | An outbound relay with end-to-end encrypted payloads through APNs and FCM, decryptable only on paired devices. Specify exactly what the relay sees. Cloudflare optional (MP-Q2). Physical-device validation plan. | DESIGN-N4: notification presentation |
| MP-N5 | Notification preferences | NEW | Defaults: blocker Commands always on, plus build-order 25% milestones and completion (D18). PR merges and other events are opt-in. Capability-aware settings, duplicate suppression, and no burst after reconnect. | DESIGN-N5: preferences UI |
| MP-N6 | Contextual command response | PARTIAL (dashboard/deck) | Notification → conversation context → suggested options or an explicit mic button choice (D16). Resolves machine, instance, agent and Command. Handles stale, resolved and duplicate submissions under D11. | DESIGN-N6: phone and watch response flow (shared with E2, E5) |
| MP-N7 | Watch apps | NEW | Apple Watch plus an Android watch target (MP-Q4): notifications, compact Command context, options, voice, and a compact instance and status list. No pause, resume or spawn. | DESIGN-N7: watch interactions |

## Shared contracts

These are specified once in `contracts/` and referenced by every feature that uses them (brief §7):

- **Identity:** machine, instance, repository, Executor, and worker or session.
- **Capabilities.**
- **Events and replay** (owned by MP-R2).
- **Command request and resolution** (MP-E2).
- **Conversations, transcripts and event anchors** (MP-E4).
- **Build progress and queue readiness** (MP-E1).
- **Listener mode** (MP-E7).
- **Notification destination and payload** (MP-N4).
- **Pairing credentials** (MP-N2).
