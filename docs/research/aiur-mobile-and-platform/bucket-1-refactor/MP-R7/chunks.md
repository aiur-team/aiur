# MP-R7 chunks

Feature plan: [plan.md](plan.md). Contract: [../../contracts/harness-adapter.md](../../contracts/harness-adapter.md).
Every ticket is blocked on **DESIGN-R7** (confirm no user-facing change) and
carries `Prior-units`, `Prior-boundaries`, `Size-owner`, `Base-SHA: 45a290e3`.
Every ticket is behaviour-preserving: the C1 characterization suite must pass
unchanged before and after.

```text
C1 characterize ──► C2 declare primitives ──► C3 cut leaks ──► C4 package move (needs MP-R1 layout)
        └──────────► C5 sibling protocol fixture
C2 ──► (MP-E7-C3, MP-E2 native capture)          C6 contributor docs (after C4)
```

---

## MP-R7-C1 — Characterize delivery and the backend contract

- **Outcome:** tests that pin today's behaviour, so every later move is proved
  behaviour-preserving.
- **Dependencies:** none. Cross-feature: none.
- **Prior-units:** U4. **Prior-boundaries:** CA, CDX, CLD, OAI, RUN.
  **Size-owner:** AGENT_TURN (test files only).
- **Tickets:**
  - MP-R7-C1-T1 — Registry contract test: for every entry in
    `CodingAgent.Registry.entries/0`, the adapter exports the behaviour
    callbacks, required capability keys exist, `immediate_delivery` ⇒
    `safe_checkpoints == []`, `remote_transport`/`fallback_backend` name a
    registered key.
  - MP-R7-C1-T2 — Delivery matrix test: entry point (`AgentChat.send/3`,
    HTTP `messages`, OpenCode `:auto`, `DecisionDispatch`) × harness
    capability set → normalized policy, queue item `delivery` map
    (`agent_queue.ex:9-25`), and accepted policies
    (`capabilities.ex:79-81`). Fixture-driven table.
  - MP-R7-C1-T3 — Provider-frame golden tests: the exact frame each adapter
    writes for an operator message (`codex/frames.ex:92-104`,
    `claude/coding_agent.ex:121-133`, `muse/coding_agent.ex:24`,
    REPL sanitized pane text `operator_inject.ex:103-108`, OpenAI-compat
    appended message `open_ai_compat/coding_agent.ex:121`).
  - MP-R7-C1-T4 — Single-writer lock test: a checkpoint item is not claimed
    while `outstanding_turns > 0` (`app_server/operator_delivery.ex:48-51`),
    and is delivered at the turn boundary. (Guard test; it already passes on
    main — named as such.)
- **Test strategy:** pure unit and fixture tests; no live harness. Each new
  test passes on `45a290e3`, by design (characterization). Mutation check per
  AGENTS.md: replacing a policy default (for example `:interrupt` →
  `:checkpoint` at `agent_chat.ex:27`) must turn T2 red.
- **Research for Phase C:** whether existing `operator_delivery_test.exs` and
  `agent_chat_test.exs` already cover parts of T2/T4 (avoid duplicates).

## MP-R7-C2 — Declare delivery primitives

- **Outcome:** a derived `delivery_primitives` descriptor per running agent
  (contract §3) and a `transport` field, computed from existing registry flags.
  `issue_control_capabilities/3` output is unchanged; the new descriptor is
  added to an internal read model only.
- **Dependencies:** C1.
- **Prior-units:** U4. **Prior-boundaries:** CA. **Size-owner:** AGENT_CORE.
- **Tickets:**
  - MP-R7-C2-T1 — `Aiur.Harness.Capabilities.delivery_primitives/1` (pure),
    with a table test equal to contract §3 values.
  - MP-R7-C2-T2 — Reserve optional callbacks (`steer/3`,
    `reply_native_question/3`, `release_native_question/3`) in the
    behaviour with `@optional_callbacks`, no implementations; a test proves
    every adapter reports `:none` for them.
  - MP-R7-C2-T3 — Expose the descriptor next to (not inside) the existing
    control capabilities map, behind no UI. Byte-identical check of the old
    map on C1 fixtures.
- **Test strategy:** table tests; byte-identical comparison of
  `issue_control_capabilities/3` output.
- **Research:** RQ-R7-1 (REPL mid-turn semantics) and RQ-R7-4 (OpenAI-compat
  tool-round boundary) decide whether `mid_turn_inject` is `:native` for
  those two; until settled the descriptor says `:none`.

## MP-R7-C3 — Remove upward leaks

- **Outcome:** runner, orchestrator, workspace and web code call harness
  behaviour only through the contract or the agent-sandbox boundary
  (prior 17), never `Aiur.Codex.*` / `Aiur.Claude.*` internals.
- **Dependencies:** C1, C2. Cross-feature: prior U4 if it lands first (rebase).
- **Prior-units:** U4, U7. **Prior-boundaries:** RUN, CA, CDX, CLD, WS, CTL.
  **Size-owner:** AGENT_TURN, CLAUDE, CODEX, `agent_runner/session_lifecycle.ex`
  (1,124 lines) owner.
- **Tickets:**
  - MP-R7-C3-T1 — Move `Codex.DynamicTool.*` to the agent tool surface
    (prior boundary 20 recommendation); update `agent_runner/{queue_drain,
    tool_executor,turn_loop}.ex` and `app_server/adapter.ex`.
  - MP-R7-C3-T2 — Replace `Codex.SessionRecovery` use in
    `agent_runner/checkpoint_delivery.ex:13` with the registry's existing
    `recoverable_session_error` capability.
  - MP-R7-C3-T3 — Put `Claude.{DisplayTailer,Telemetry,RemoteControl}` calls
    in `agent_runner/session_lifecycle.ex:6` behind capability-gated adapter
    hooks (`rc_display_tail`, `run_telemetry` already exist as registry keys).
  - MP-R7-C3-T4 — Orchestrator interrupts (`orchestrator/interrupts.ex:7`)
    call the optional `interrupt/1` callback through the registry instead of
    `Claude.ReplAgent`.
  - MP-R7-C3-T5 — Boundary check in CI: a script (or `mix xref` graph check)
    that fails when a module outside the harness namespace references an
    adapter namespace, with an explicit allowlist (RQ-R7-2).
- **Test strategy:** C1 suite unchanged; T5's check proved by adding a
  forbidden reference in a scratch branch and seeing it fail.
- **Research:** RQ-R7-2 allowlist; which of `process_reaper.ex`,
  `pause_containment.ex`, `shutdown.ex`, `git.ex`, `config.ex` references are
  sandbox concerns (prior 17) rather than leaks.

## MP-R7-C4 — Physical package

- **Outcome:** adapters live in the harness package selected by MP-R1
  (path-dependency app or namespaces-only), with `Aiur.CodingAgent.Backend`
  kept as an alias so no caller breaks.
- **Dependencies:** C3; **MP-R1 layout decision** (RQ-R7-3); prior boundary 17
  (agent sandbox) package must exist first, or C4 carries an explicit
  temporary dependency on core.
- **Prior-units:** U7, U8. **Prior-boundaries:** CA, CDX, CLD, OAI.
- **Tickets:**
  - MP-R7-C4-T1 — Create the package skeleton and move the contract,
    registry and `AppServer.*` core.
  - MP-R7-C4-T2 — Move Codex adapter.
  - MP-R7-C4-T3 — Move Claude (headless + REPL) adapter; the tmux transport
    dependency is declared optional.
  - MP-R7-C4-T4 — Move Muse and OpenAI-compat adapters.
  - MP-R7-C4-T5 — Release packaging check: the OTP release still contains
    every adapter (`scripts/aiurdev build`, `packaging/npm/platform`).
- **Test strategy:** whole test suite plus the C1 suite; foreground manual
  test per AGENTS.md (one Codex and one Claude agent, chat-pane message
  delivered and rendered).
- **Research:** RQ-R7-3; 500-line limit for moved files (KTD1) — files over
  500 lines in scope: `coding_agent.ex` (1,179), `claude/remote_control.ex`
  (726), `claude/telemetry.ex` (666); each needs its U8 owner's split first or
  in the same ticket.

## MP-R7-C5 — Sibling protocol fixture (`aiur-claude`)

- **Outcome:** a recorded fixture of the JSON-RPC methods aiur sends to and
  expects from `aiur-claude` (initialize, thread/start, turn/start,
  turn/interrupt, item/tool/call, notifications), so a sibling upgrade that
  breaks aiur fails a test.
- **Dependencies:** C1.
- **Tickets:**
  - MP-R7-C5-T1 — Protocol fixture + replay test against
    `Aiur.Claude.CodingAgent`.
  - MP-R7-C5-T2 — File (do not fix in R7) the `turn/steer` defect in the
    sibling (plan F7) as a tracked issue; MP-E7-C4 owns the fix.
- **Research:** pin the minimum `aiur-claude` version aiur supports today
  (install hint at `providers/claude.ex:21` names no version).

## MP-R7-C6 — Contributor documentation

- **Outcome:** `CONTRIBUTING.md` (or a `src/` README section) explains how to
  add a harness: adapter module, registry entry, capability keys, delivery
  primitives, boundary check. No user docs change (no user-facing surface).
- **Dependencies:** C4.
- **Tickets:** MP-R7-C6-T1 — contributor doc update.
- **Test expectation:** none — documentation only.

---

## Phase C research questions (all chunks)

RQ-R7-1 … RQ-R7-4 are listed in [plan.md](plan.md#open-questions). C4 is the
only chunk blocked on another feature (MP-R1).
</content>
</invoke>
