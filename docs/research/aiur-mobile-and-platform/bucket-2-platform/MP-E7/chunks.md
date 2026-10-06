# MP-E7 chunks

Feature plan: [plan.md](plan.md). Contract: [../../contracts/listener-mode.md](../../contracts/listener-mode.md).
Every implementation ticket is blocked on **DESIGN-E7**. Tickets in C1 that
change the Khala repository are also blocked on owner question E7-Q1.

```text
C1 shared spec (Khala) ──► C2 aiur mode store ──► C3 scheduler (sync/steer-emulated/async-hold)
R7-C2 primitives ──────────────────────────────┘        │
                                   C4 native steer ◄────┤
                                   C5 async pull tool ◄─┤
MP-E3 attached Executor ──► C6 hook delivery (Executor) ◄─ C1 codecs
C2..C5 ──► C7 surfaces + docs (DESIGN-E7)
```

## Phase C changes (2026-10-06)

Ticket docs are in [tickets/](tickets/README.md) with two-digit IDs. Where this
file and a ticket disagree, the ticket wins. Binding inputs: RC-05 (waves),
RC-08 (topic), RC-22 (Gemini).

- **Waves (RC-05):** C1–C3 are wave 3, ahead of MP-E3-C5 and MP-E4-C6. C4–C7
  and the new C2-T05 are wave 4.
- **Flag (RC-05):** C3 routes every send through the listener entry point
  behind the internal app env `config :aiur, :listener_send_routing`
  (`:legacy` default | `:listener`). `:legacy` keeps today's per-entry-point
  policies, so the MP-R7-C1 characterization suite passes unchanged. New
  ticket **C7-T04** flips the default and deletes the legacy branch after
  DESIGN-E7 decision E7-D6.
- **C1:** Khala tickets are cross-repo, cite Khala `origin/main` `99e72a43`
  and are blocked on E7-D1. Khala's existing goldens stay in Khala; new
  envelope-only goldens are added. T05 (optional fields) lands **before** T03
  (first publish), because Khala's decoders reject unknown keys. T03 also
  needs owner action OWNER-NPM-FIRST-PUBLISH.
- **C2:** the CLI command, `POST /api/v1/:id/listen-mode` and the snapshot
  field move to **C7-T03**, because `issue_control_capabilities` is
  serialized into `/api/v1` JSON (`aiur_web/presenter.ex:323,452`). The bus
  event splits out as **C2-T05** (wave 4, needs MP-R2-C5). C2-T01 also waits
  on E7-D5. C2-T04 also fixes finding R7-C1-F1 (stale `:control` flags).
- **C3:** no batching in wave 3 (one item per turn boundary). `sync` is never
  claimed at a tool boundary, including the OpenAI-compat `:tool_result`
  checkpoint. `Aiur.Listener.send/3` takes a ticket identifier; the
  `ConversationRef` overload belongs to C6/MP-E3.
- **C4:** **T01 is the precondition ticket**: fix the `aiur-claude`
  `turn/steer` text drop in the sibling repo (cross-repo). Codex, Muse and
  `claude-repl` steer are T02–T04. No Gemini steer ticket (RC-22: Gemini is
  `emulated_interrupt` only).
- **C5:** the pull tool is `aiur_read_messages`.
- **C6:** no Node hook in `aiur-cli`. The daemon renders the envelope in
  Elixir (T04) and the hook is a plain `curl` command (T02), because
  `aiur-cli` requires Node `>=18` and Khala's packages need `>=22.18`.
- **C7:** T01 dashboard, T02 TUI, T03 CLI + HTTP control, T04 flag flip,
  T05 docs. T01/T02 hide the selector while routing is `:legacy`.

---

## MP-E7-C1 — Shared listener specification package

- **Outcome:** a versioned, published package containing
  `listening-mode.v1.schema.json`, `scheduler.v1.json`, hook goldens and the
  TS reference (moved from Khala `packages/contracts/src/m1/listening-mode.ts`,
  `delivery/listening-mode.ts` support statuses, and
  `packages/agent/src/harness/{deliver-core.ts,codecs/claude-style.ts}`).
  Khala keeps working unchanged against it.
- **Dependencies:** owner E7-Q1. Cross-feature: none.
- **Tickets:**
  - MP-E7-C1-T1 (Khala) — Extract the package; Khala imports switch to it;
    existing goldens move with it and still pass.
  - MP-E7-C1-T2 (Khala) — Emit JSON Schema for the command, control record
    and support map; add `scheduler.v1.json` (mode × boundary × activity →
    deliver) generated from the TS scheduler and checked in.
  - MP-E7-C1-T3 (Khala) — Extend `release-npm.yml` to publish the package by
    a `listener-v*` tag; document in `packages/agent/docs/releasing.md`.
  - MP-E7-C1-T4 (aiur) — Vendor step: copy JSON artifacts to
    `src/priv/listener/v1/` with a sha256 manifest; CI fails on drift.
  - MP-E7-C1-T5 (both) — Add `backlog_on_leave_async` and
    `emulated_interrupt` to the spec as optional fields (contract §4, §6).
- **Test strategy:** Khala's existing goldens unchanged (`__golden__/deliver-*.json`);
  schema validation tests for every fixture; aiur manifest check.
- **Research:** RQ-E7-5 (Node floor); whether Khala's decoders that reject
  unknown keys block additive fields (contract §11).

## MP-E7-C2 — aiur mode store and control API

- **Outcome:** durable per-ticket-run mode record
  `{requested, version, actor, updated_at}`, default `sync`; effective mode
  derived from the running entry's `delivery_primitives`; CAS writes; the
  `listen-mode.changed` event.
- **Dependencies:** MP-R7-C2; MP-R2 topic registry (optional; PubSub-only
  fallback); DESIGN-E7 for command names.
- **Tickets:**
  - MP-E7-C2-T1 — `Aiur.Listener.ModeStore` (persist under the run state
    dir; restart-safe; cleared on ticket exit from active states).
  - MP-E7-C2-T2 — `Aiur.Listener.Effective.compute/2` (pure) against the
    contract §4 rules, table-tested with the shared support map.
  - MP-E7-C2-T3 — Control API: CLI command (name per DESIGN-E7), HTTP
    `POST /api/v1/:id/listen-mode` (writable-gated like `messages`), and a
    field in `issue_control_capabilities` (`requested`, `effective`,
    `effective_reason`, `version`).
  - MP-E7-C2-T4 — Recompute on fallback and RC promotion; emit event with
    `actor: system`.
- **Test strategy:** CAS conflict test (two writers, one 409); restart test
  (mode survives `Orchestrator` restart in test); transport-change test.
- **Research:** where ticket-run state lives today for similar records
  (`session_handle.ex` is per-issue durable; reuse its directory?).

## MP-E7-C3 — Scheduler: route every send through the mode

- **Outcome:** all conversation send paths (`AgentChat.send/3`, HTTP
  `messages`, TUI `:auto`, Stream Deck, voice) enqueue with
  `delivery: :listener` and the scheduler maps the effective mode to queue
  behaviour: `sync` → existing checkpoint/turn-boundary claim; `steer` →
  C4 primitive or `emulated_interrupt` (existing `:interrupt` path) when
  accepted; `async` → `held_async`, never notifies the running process.
  Command answers and digests keep their current policies (contract §2).
- **Dependencies:** C2; MP-R7-C1 characterization (to prove the
  non-message rows unchanged).
- **Tickets:**
  - MP-E7-C3-T1 — Queue item gains `listener_mode_at_claim`; `AgentQueue`
    builder for `:listener` items.
  - MP-E7-C3-T2 — `DeliveryPolicy.deliver_now?/3` respects `async`
    (never wake) and `sync` (no interrupt); unit tests per mode × entry state
    (idle, active, sleeping, paused, self-paused).
  - MP-E7-C3-T3 — Switch the four entry points; keep an explicit
    `delivery_policy:` override only for Command dispatch and internal
    callers.
  - MP-E7-C3-T4 — Receipt mapping (contract §7) exposed by
    `AgentChat.delivery_status/2` and the HTTP API.
  - MP-E7-C3-T5 — Elixir conformance test that runs `scheduler.v1.json`
    rows against the scheduler.
- **Test strategy:** mutation check per AGENTS.md — restore
  `delivery_policy :interrupt` at `agent_chat.ex:27` and confirm the
  "sync does not interrupt" test fails.
- **Research:** whether batching several pending `sync` messages into one
  turn changes `OperatorWaitLog` and transcript anchors (MP-E4).

## MP-E7-C4 — Native steer primitives

- **Outcome:** `steer/3` implemented where the harness has non-cancelling
  mid-turn input.
- **Dependencies:** C3; MP-R7-C2-T2 (reserved callback).
- **Tickets:**
  - MP-E7-C4-T1 — Codex `turn/steer` with `expectedTurnId`; on
    `no active turn` or mismatch, fall back to the turn boundary (RQ-E7-1).
  - MP-E7-C4-T2 — Muse steer if `ifBusy` supports it (RQ-E7-2); else mark
    `unsupported`.
  - MP-E7-C4-T3 — `claude-repl`: classify pane input as steer if RQ-E7-3
    confirms mid-turn folding; sync for the REPL = type on the `Stop` hook.
  - MP-E7-C4-T4 (sibling `aiur-claude`) — Fix `turn/steer` queue carry-over
    (R7 F7) or remove the method; record that headless Claude has no true
    steer (RQ-E7-4).
- **Test strategy:** frame goldens per harness; foreground manual test with
  a long Codex turn: steer message appears in the chat pane before the turn
  completes and the turn is not marked interrupted.

## MP-E7-C5 — Async pull tool and unread count

- **Outcome:** agent tool `read_messages` (dynamic-tool surface for Codex,
  Claude headless, OpenAI-compat; MCP-bridged for Claude headless), cursor
  ack, unread count in control capabilities; async → sync transition
  behaviour per E7-D4.
- **Dependencies:** C3; MP-R7-C3-T1 (tool surface moved out of Codex).
- **Tickets:**
  - MP-E7-C5-T1 — Tool spec + handler; per-agent cursor with CAS.
  - MP-E7-C5-T2 — Unread count projection + PubSub update.
  - MP-E7-C5-T3 — Transition handler (`notice` or `skip`).
  - MP-E7-C5-T4 — Prompt guidance in `src/prompts/shared-agent-instructions.md`
    telling agents when to call `read_messages` (only when async is
    effective; the prompt is rebuilt per turn, `prompt_builder.ex`).
- **Research:** how `claude-repl` could get the tool (it has no
  `--mcp-config`); until then `async` is `unsupported` there.

## MP-E7-C6 — Hook delivery into attached sessions (Executor)

- **Outcome:** `aiur hook deliver --harness claude|codex` (Node, in
  `aiur-cli`, using the shared codecs) reads pending items for the attached
  Executor session from the daemon and renders the hook envelope; an
  installer writes Claude `--settings`/project hooks and merges Codex
  `hooks.json` without clobbering user hooks.
- **Dependencies:** C1, C3; **MP-E3** (attached-session identity and the
  Executor conversation record); RQ-E7-6.
- **Tickets:**
  - MP-E7-C6-T1 — Daemon endpoint: claim batch for an attached session by
    boundary (`tool|prompt|stop`), loopback-only.
  - MP-E7-C6-T2 — Node hook command using shared codecs; always exit 0.
  - MP-E7-C6-T3 — Installer + uninstaller for Claude and Codex hooks.
  - MP-E7-C6-T4 — Shared golden tests run in `aiur-cli`'s `bun test`.
- **Test strategy:** goldens; manual: an Executor Claude Code session
  receives a `sync` message at `Stop` as a continuation.

## MP-E7-C7 — Surfaces and documentation

- **Outcome:** mode selector and status per DESIGN-E7 in dashboard (unit row
  / conversation drawer), TUI, CLI output; Stream Deck shows nothing new
  unless DESIGN-E7 asks.
- **Dependencies:** C2–C5; DESIGN-E7 approved.
- **Tickets:**
  - MP-E7-C7-T1 — Dashboard selector + requested/effective + unread.
  - MP-E7-C7-T2 — TUI indicator and key (if DESIGN-E7 wants one).
  - MP-E7-C7-T3 — Docs: `reference/cli.md`, `reference/configuration.md`
    (default-mode key if added, checked by `scripts/check-config-docs.py`),
    a concepts section, `aiur-agent` skill note about `read_messages`.
- **Test strategy:** LiveView tests for each state in DESIGN-E7, including
  the unsupported/effective-differs and pending-confirmation states; the
  unknown-path mutation rule (AGENTS.md) for the effective-mode render.

---

## Phase C research questions

RQ-E7-1 … RQ-E7-6 in [plan.md](plan.md#open-questions), plus: per-chunk
items above.
</content>
</invoke>
