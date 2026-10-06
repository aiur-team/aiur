---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-E7
bucket: 2-platform
base_main_sha: 45a290e3
khala_ref: origin/main 99e72a43
date: 2026-10-06
owns_contracts: [listener-mode]
consumes_contracts: [harness-adapter, identity-and-capabilities, events-and-replay, conversations-transcripts-anchors, command-request-and-resolution]
owner_gate: DESIGN-E7
---

# feat: Shared agent-listener package (MP-E7)

## Summary

Give every aiur agent an operator-settable listener mode — `steer`, `sync`
or `async`, default `sync` (D13) — that decides when a conversation message
lands in the agent's session. The vocabulary, semantics, hook codecs and
conformance fixtures are one package shared with Khala. aiur implements the
scheduler in Elixir over its existing durable agent queue and the MP-R7
harness adapters; it also gains a hook path to deliver into sessions it does
not launch (the Executor, for MP-E3).

The contract is [../../contracts/listener-mode.md](../../contracts/listener-mode.md).
Chunks and tickets are in [chunks.md](chunks.md).

---

## Problem Frame

- Today the *sender* picks delivery, not the agent: the dashboard, Stream
  Deck and CLI interrupt the active turn (`agent_chat.ex:27`), the HTTP API
  waits for the next checkpoint (`operator_messages.ex:572`), and the TUI
  defers to the backend (`operator_dispatch.ex:46-50`) (R7 plan F3). The same
  message lands differently depending on which button was pressed.
- The default is a hard interrupt. It throws away in-flight work on
  app-server harnesses (`app_server/interrupts.ex:34-53`).
- There is no "leave me alone" mode: every message eventually wakes the agent.
- Khala already ships the same three modes for the same harnesses with
  tested hook delivery. Building a second, different vocabulary would split
  the operator's mental model across two products he runs side by side.

---

## Repository findings

aiur facts are in the R7 plan F1–F11 (not repeated). Additional:

**E7-F1. The queue already has what a scheduler needs.** Items are durable
(`agent_queue.ex:19-26`, `durability: :durable`), carry `priority`,
`consume_at`, `interrupt_requested`, an idempotent `message_id`
(`operator_messages.ex:854-858`) and statuses `pending → delivered →
consumed | failed | superseded` (`agent_queue_item.ex:6`;
`capabilities.ex:69-74`). Claim functions exist for checkpoint and operator
items (`operator_messages.ex:136-157`).

**E7-F2. Wake decision is centralized.** `DeliveryPolicy.notify_running_queue_update/3`
and `deliver_now?/3` (`delivery_policy.ex:50-143`) decide whether a queued
item wakes the running process. `async` is "never wake" here.

**E7-F3. Khala's shipped semantics** (Khala `origin/main` `99e72a43`):
- Contract: three literals, default `sync`, command `{v:1, agent, mode}` as
  encrypted room event `com.khala.listening_mode.v1`, echoed in member state
  `com.khala.listening_mode` (`packages/contracts/src/m1/listening-mode.ts:1-22`).
- Runtime: `packages/agent/src/harness/deliver-core.ts` — `PostToolUse`
  delivers only `steer` channels (:104-108, :218); `Stop` and fresh
  `UserPromptSubmit` deliver `steer` and `sync`; `async` never delivers.
  Golden fixtures `packages/agent/src/harness/__golden__/deliver-{claude,codex}-{PostToolUse,Stop,UserPromptSubmit}-{steer,sync,async}-{0,1,51}.json`.
- Async → other mode skips the unread backlog (`packages/agent/src/mode.ts:11-22`).
- Codec-less harnesses are forced to `async` (`client-impl.ts:50-51`).
- Harness capability flags `steer`, `sync`, `idleWake` per harness
  (`packages/contracts/src/m1/harness.ts:9-33`).
- Designed but **not implemented**: CAS mode command, capability-evidence
  map, batch-token ack, agent-side mode change
  (`packages/contracts/src/delivery/listening-mode.ts` is unused at runtime;
  no `khala mode` CLI, `src/cli.ts:23`).
- `khala_read` pages history; it is not a cursor pull (`src/mcp/tools.ts:78-85`).

**E7-F4. Khala already treats aiur wire shapes as a contract.**
`packages/contracts/src/m1/from-aiur.ts:53-61` maps aiur bus events, wake
records and alerts, with 15 JSON fixtures in
`packages/contracts/fixtures/aiur-events/`. Cross-repo JSON fixtures are an
established pattern between the two products.

**E7-F5. Release facts relevant to MP-Q1.**
- Khala: pnpm workspace (`pnpm@10.34.5`), Node `22.23.2`; every `@khala/*`
  package is `private` 0.0.0 and exports raw TS
  (`packages/contracts/package.json:2-10`); only `khala-cli` and
  `khala-opencode` are published, by tag via npm OIDC
  (`.github/workflows/release-npm.yml:13-23,113-125`); published packages
  need Node `^22.18.0 || >=24.11.0` (`packages/agent/package.json:6-8`).
  No JSON Schema or codegen for contracts.
- aiur: one Mix app (`src/mix.exs:6-7`, version 0.0.9); npm
  `aiur-cli` 0.0.9 with Node `>=18` (`packaging/npm/aiur-cli/package.json`);
  in-repo TS package `packages/streamdeck` (private). Precedent for a
  versioned JSON Schema read by two languages:
  `analytics/schema/run-summary.v1.json` (Python reducer, Elixir presenter).

---

## MP-Q1 — package home and release path (resolved, with owner confirmation)

| Option | For | Against | Verdict |
| --- | --- | --- | --- |
| **A. Spec-first package in the Khala monorepo** (`packages/listener`, published): JSON Schema + scheduler table + goldens + TS reference; aiur vendors the JSON at a pinned version and runs goldens against its Elixir code | Khala owns the only running implementation and its tests (E7-F3); one release workflow already exists; JSON fixtures are an existing cross-repo pattern (E7-F4); aiur's BEAM needs no Node | Khala must publish a package it keeps private today; aiur's Elixir is a second implementation kept honest only by goldens | **Recommended** |
| B. Package in the aiur monorepo (`packages/agent-listener`), Khala consumes it | aiur has `packages/` and npm publishing | Khala would depend on a less mature implementation; moves Khala's tested code across repos; aiur has no TS release workflow for libraries | Rejected |
| C. New third repository (`aiur-team/agent-listener`) | Neutral ownership | A third release train with no existing owner or CI; both products still re-implement the BEAM side | Rejected for now; revisit if a third consumer appears |
| D. aiur shells out to `khala hook deliver` | Real code reuse | Raises aiur's Node floor from 18 to 22.18 (E7-F5), couples aiur's runtime to the Khala product, and covers only hook delivery — not daemon-launched workers | Rejected as a dependency; allowed for the Node-side hook command only if it is the shared package, not `khala-cli` |
| E. Hex package for Elixir + npm for TS from one source (codegen) | Typed both sides | No codegen exists in either repo; building one is more work than the contract it carries | Rejected |

Decision proposed: **A**, interpreted as "one package = one versioned
specification with a TypeScript reference implementation and
language-neutral conformance fixtures". D13 says "one package"; an Elixir
daemon cannot load a TS runtime, so a single runtime implementation is not
possible without making Node a daemon dependency. Owner question E7-Q1
confirms this interpretation and that Khala will publish the package.

Release path: Khala tag `listener-v<semver>` → npm publish (OIDC, existing
workflow extended) → aiur `scripts/` vendor step copies the JSON artifacts
into `src/priv/listener_spec/v<major>/` with a recorded sha256 → aiur CI runs the
goldens. The package is a **build-time input only** (RC-36): aiur never loads
it at runtime, and no aiur npm package depends on it. C6 renders the Executor
hook envelope in the daemon (Elixir), so RQ-E7-5 is moot.

---

## Proposed boundaries

```text
listener-spec (Khala repo, published; optional, build-time input only)
    schema, scheduler table, goldens, TS codecs
    vendored into src/priv/listener_spec/ with CHECKSUM (C1-T04)
listener-modes (aiur core, REQUIRED): Aiur.Listener.*
    send router Aiur.Listener.send/3 + mode store + scheduler + receipts + pull tool
  depends on: harness-adapters (MP-R7) delivery_primitives / steer callback,
              event-bus (listen-mode.changed), config, identity
  delivers through: behaviour Aiur.Listener.DeliveryTarget, implemented by
              orchestration (AgentQueueStore, DeliveryPolicy) and registered
              at the composition root
  called by: AgentChat.send/3 (orchestration delegates), MP-E4 send API,
             MP-E3 Executor send, dashboard/TUI/CLI selectors (DESIGN-E7)
Executor hooks (C6): daemon-rendered envelope + a plain `curl` hook command
```

- **RC-36 (Phase D).** The router is a required part of orchestration's send
  path, so it is core and required, not an optional package. The spec package
  is optional: if the vendored spec is absent or fails its checksum, the
  router uses today's routing (`:legacy`, RC-05) and reports capability
  `listener_modes` as `unavailable` with reason `not_installed` or
  `spec_invalid` (C3-T06). With a good spec and the flag at `:legacy` the
  reason is `disabled`.
- Required deps: harness adapters (R7-C2), event bus, config, identity.
  Orchestration (agent queue) is reached only through `DeliveryTarget`.
  Optional: MP-E3 (hook path is inert without an attached Executor).
- **Prior-units:** U3 (event delivery ordering), U4 (turn lifecycle).
  **Prior-boundaries:** MSG (16), RUN (18), CA (20).

---

## Alternatives for aiur-side semantics

- **Keep sender-chosen policies and add modes on top.** Rejected: two
  overlapping knobs; the receiver-side setting is the point of D13.
- **Map `steer` to today's interrupt everywhere.** Rejected as default:
  Khala's contract forbids treating cancellation as a mode. Kept only as
  `emulated_interrupt`, owner-accepted and labelled (contract §4).
- **Skip the async backlog like Khala.** Not adopted by default: aiur
  messages are operator instructions, and the brief forbids requests
  vanishing. Proposed `notice` (contract §6), owner decision E7-D4.

---

## Non-happy paths

- **Capability absence:** requested ≠ effective with a reason (contract §4);
  `async` unavailable where no pull path exists (`claude-repl`).
- **Transport change** (fallback, RC promotion): recompute effective mode;
  emit `listen-mode.changed` with `actor: system`.
- **Restart:** mode store is durable per ticket run. Correction (Phase C):
  pending items do **not** survive a daemon restart, because `AgentQueueStore`
  is in-memory (`agent_queue_store.ex:2-3`); their receipt becomes `unknown`.
  Within one daemon life, a claimed-but-unacknowledged item is restored
  (existing `restore_delivered_queue_items`).
- **Duplicates:** `client_request_id` idempotency (#2717); hook delivery
  de-duplicates by message id before render (Khala `inbox.ts:22-35`).
- **Multiple devices / conflicting mode sets:** CAS `expected_version`, 409
  with current record; UI shows the winner.
- **Stale UI:** selector shows pending until the change event confirms
  (Khala pattern, `AgentPresencePanel.tsx:150-214`, 15 s timeout).
- **Agent paused:** nothing delivers; queue depth visible.
- **Steer turn race:** Codex `turn/steer` with a stale `expectedTurnId`
  fails; scheduler falls back to the turn boundary and records it.
- **Hook failures** (Executor): hook exits 0, receipt stays `accepted`, the
  message retries at the next boundary.
- **Privacy:** async messages never enter context without a pull.

---

## Acceptance criteria

1. After C7-T04 flips the routing default (E7-D6): with no configuration,
   every agent's mode is `sync`; a dashboard, CLI, HTTP, Stream Deck or TUI
   message to a running Codex agent mid-turn is delivered at the turn
   boundary and the turn is not interrupted. Before C7-T04 (flag `:legacy`)
   every entry point behaves exactly as today.
2. `steer` on Codex delivers via `turn/steer` before the turn ends
   (foreground manual test shows the message in the chat pane mid-turn).
3. `async` messages never start a turn; `aiur_read_messages` returns them in
   order; the unread count drops after the pull.
4. Unsupported combinations show requested and effective mode with a reason
   in CLI and dashboard; nothing is downgraded silently.
5. aiur's Elixir scheduler passes every shared golden fixture for the
   pinned spec version.
6. Mode survives daemon restart and agent respawn.
7. Command answers and orchestrator digests are delivered exactly as before
   (characterization from R7-C1 unchanged for those rows).
8. Docs: `website/docs-app/reference/cli.md` (new command/flag),
   `reference/configuration.md` (any default key), a concepts page section.

---

## Plan-refresh note

E7 starts after MP-R7-C2 (primitives). C1–C3 are wave 3 (RC-05); only
C2-T05 (the bus event) needs MP-R2-C5, which is at the start of wave 4
(RC-31). If R7-C4 moves adapters, E7 tickets cite `Aiur.Harness.*`. MP-E4's
send API and MP-E3's Executor send call `Aiur.Listener.send/3` (C3-T03)
directly; there is no interim `AgentChat` step (CR-E4-8).

---

## Open questions

**Owner (Kevin)** — E7-Q<n> is recorded as decision E7-D<n> in DESIGN-E7 (E7-D7, a global default key, is design-only):
- E7-Q1. Accept "one package" = shared spec + TS reference + goldens homed in
  Khala and published; aiur implements in Elixir? (MP-Q1)
- E7-Q2 (D2 in DESIGN-E7). Offer `steer` as "interrupts current turn" on
  harnesses without native steering (headless Claude), or hide steer there?
- E7-Q3. May the Executor change a worker's mode, or only the human?
- E7-Q4 (D4). Async → sync backlog: notice (proposed) or skip (Khala)?
- E7-Q5. Does mode persist per ticket run (proposed) or per harness
  session (resets on respawn)?
- E7-Q6. Is the switch from today's interrupt default to `sync` acceptable
  for Stream Deck dictation and `aiur message`? (Behaviour change.)

**Research (Phase C):** RQ-E7-1..6 are answered in the tickets (see
[tickets/README.md](tickets/README.md)); RQ-E7-C6-1 and RQ-E7-C6-2 are new.
The Node-side hook command in this plan's release path is superseded: C6
renders the hook envelope in the daemon (Elixir) and needs no Node package.
- RQ-E7-1. Codex `turn/steer` availability in the Codex version aiur pins;
  error shapes; whether it emits item events for the steered input.
- RQ-E7-2. Muse `ifBusy` values; does `"steer"` exist?
- RQ-E7-3. `claude-repl`: does pane input mid-turn land at the next tool
  boundary (true steer) or after the turn? (= RQ-R7-1.)
- RQ-E7-4. Fix or replace `aiur-claude` `turn/steer` (R7 F7); can a
  `--print` turn accept mid-turn input at all (`--input-format stream-json`)?
- RQ-E7-5. Node floor of the shared TS package vs `aiur-cli` `>=18`.
- RQ-E7-6. How aiur installs Executor hooks without clobbering user hooks
  (Claude `--settings` composes, `hook_settings.ex:6-8`; Codex merges
  `hooks.json`, as Khala's `codex/hooks-config.mjs:6-59` does).
