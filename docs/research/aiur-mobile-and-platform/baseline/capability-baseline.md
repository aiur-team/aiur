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

## Index of parts

The per-feature sections 1–3 live in sibling files. Sections 4–6 stay here.

| Section | File | Features |
| --- | --- | --- |
| 1. Bucket 1 — Refactor | [capability-baseline-bucket-1.md](capability-baseline-bucket-1.md) | [R1](capability-baseline-bucket-1.md#r1--modular-platform-and-reusable-applications--partial-research-exists-code-is-monolithic), [R2](capability-baseline-bucket-1.md#r2--standalone-shared-event-bus--partial), [R3](capability-baseline-bucket-1.md#r3--optional-tailscale-integration--exists-already-optional-no-code-dependency), [R4](capability-baseline-bucket-1.md#r4--existing-cloudflare--github-app-relay--exists-inbound-webhook-transport-only), [R5](capability-baseline-bucket-1.md#r5--elevenlabs-speech-to-text--exists-inside-core-not-a-separate-package), [R6](capability-baseline-bucket-1.md#r6--stream-deck-integration--exists-separate-package) |
| 2. Bucket 2 — Platform improvements | [capability-baseline-bucket-2.md](capability-baseline-bucket-2.md) | E1–E6 |
| 3. Bucket 3 — Mobile and watch | [capability-baseline-bucket-3.md](capability-baseline-bucket-3.md) | N1–N7 |
| 4. Repository facts | this file, [§4](#4-repository-facts-that-answer-brief-questions-do-not-ask-the-owner) | — |
| 5. Questions for the owner | this file, [§5](#5-questions-that-remain-for-the-owner-not-answerable-from-the-repo) | — |
| 6. Search log | this file, [§6](#6-search-log-for-not-found-claims) | — |

A bare reference such as "baseline E3" elsewhere in this pack means the E3 section of the bucket file above.

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
