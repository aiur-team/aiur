---
feature_id: MP-E3
base_main_sha: 45a290e3
date: 2026-10-06
parent: plan.md
---

# MP-E3 chunks

Every implementation ticket below is **blocked on DESIGN-E3** (MP-REQ2), even
backend ones, because the attach/opt-in UX and the status vocabulary are owner
decisions. Ticket fields to fill in Phase C: `Prior-units`, `Prior-boundaries`,
`Size-owner`, `Base-SHA`.

## MP-E3-C1 — Executor session binding and hook ingest

**Outcome.** One durable, opt-in binding per instance between aiur and the
operator's external Executor session, fed by authenticated hooks.

- **Deps:** MP-E4-C1 (journal + `ConversationRef{kind: "executor"}`); MP-R7
  hook-normalization interface (consume if landed; otherwise define the seam);
  identity contract (`instance_id`).
- **Prior:** U3 (claims), U4 (claude hooks). Boundaries EXE, CLD, WEB.
- **Design.**
  - Store: `<executor-state-dir>/<repo>.executor.session.json` (binding:
    `binding_id`, `generation`, `harness`, `provider_session_id`, `locator_hash`,
    `transcript_path` (server-side only), `cwd`, `attached_at`, `last_hook_at`,
    `consumer_id`), written under the same lock style as `Claims`
    (`claims.ex:28-35`).
  - Endpoint `POST /api/v1/executor/hook`: `dashboard_auth` is **not** used;
    bearer token from `<executor-state-dir>/hook-token` (0600). Outside
    `:require_writable` like `claude-hook` (`router.ex:166-178`). Always 202 to
    the hook; never blocks the harness (same invariant as
    `HookEvents.dispatch/2`, `hook_events.ex:58-80`).
  - Normalizer accepts Claude and Codex payload field sets (plan §2.3) and
    returns `{event, session_id, transcript_path, cwd, turn_id, agent_id,
    agent_type, source}`.
  - Single-binding rule and explicit takeover (plan §4.3).
- **Tickets.**
  - MP-E3-C1-T1 Binding store + `attach/detach/current` with lock and generation.
  - MP-E3-C1-T2 Token file + `POST /api/v1/executor/hook` + normalizer for both harnesses.
  - MP-E3-C1-T3 CLI `aiur executor-attach [--harness claude|codex] [--takeover] [--print-config]`, `executor-detach`, `executor-session` (status). Docs in `website/docs-app/reference/cli.md` (AGENTS.md docs rule).
  - MP-E3-C1-T4 Hook config generator: Claude user-scope settings snippet or plugin; Codex `hooks.json` entry. Command is stdout-silent, exits 0, reads the token from the file (pattern: `hook_settings.ex:26-45`).
- **Tests.** Token missing/wrong → 401 and no state change; second attach
  refused naming the first; takeover ends old session `superseded`; restart
  reloads binding; normalizer fixtures for each harness's documented fields;
  hook endpoint returns within 50 ms with the journal writer blocked.
- **Research.** RQ-E3-5/6 (payload fields); whether Claude plugin or settings
  file is the better install unit (Khala uses a plugin).

## MP-E3-C2 — Claude Executor transcript reader

**Outcome.** A Claude Code Executor's conversation lands in the MP-E4 journal,
backfilled from the session start and live after.

- **Deps:** C1, MP-E4-C1.
- **Design.** Reuse `Aiur.Claude.TranscriptTailer` (`from: :start`, stored byte
  offset) and `Claude.Transcript.extract_disk_record/2`. Retarget on
  `SessionStart` (`clear | compact | resume | fork`) → new journal session.
  Store the byte offset in the binding so a restart resumes without duplicates;
  entry `id`s make re-reads idempotent anyway. Map `queued_command` attachments
  (Remote Control messages) to `operator_message` with origin "remote control".
- **Tickets.**
  - MP-E3-C2-T1 `ExecutorTranscriptIngest` (Claude) supervised per binding; offset persistence.
  - MP-E3-C2-T2 Session-boundary handling from `SessionStart`/`SessionEnd`.
  - MP-E3-C2-T3 Version pin + unknown-record counting + one needs-attention alert on drift.
- **Tests.** Fixture transcripts (assistant text/thinking/tool_use, user string,
  tool_result list, `queued_command`); truncated file → new session; partial
  trailing line not emitted (existing behaviour, `transcript_tailer.ex:163-175`);
  restart mid-file → no duplicates.
- **Research.** RQ-E3-3 (flush latency).

## MP-E3-C3 — Codex Executor transcript reader

**Outcome.** A Codex TUI Executor's conversation lands in the journal, or the
feature states `unsupported` with a reason.

- **Deps:** C1, MP-E4-C1, RQ-E3-1, RQ-E3-2.
- **Design (selected pending research).** Primary: tail the rollout JSONL named
  by the hook's `transcript_path` with a new `Codex.RolloutTranscript` extractor,
  version-pinned. Alternative: read through `thread/turns/list` /
  `thread/items/list` with `cursor` (app-server v2, 0.160.0) if RQ-E3-2 proves a
  read-only second client is safe. The ticket must not ship both.
- **Tickets.**
  - MP-E3-C3-T1 Research spike (no product code): fixtures for 0.160.x rollouts; app-server read test against a live TUI thread in a private `CODEX_HOME`.
  - MP-E3-C3-T2 Selected reader + session boundaries.
  - MP-E3-C3-T3 Capability record `codex_executor_read: proven | unsupported` with tested version.
- **Tests.** Fixture rollouts per pinned version; reader refuses unknown major
  layout with `unsupported`, never partial garbage.

## MP-E3-C4 — Executor status, blockers and background agents

**Outcome.** A single `Executor.Status.snapshot/0` that every surface (dashboard,
CLI, MP-N3 meta-dashboard) reads.

- **Deps:** C1; MP-E2 (Executor-originated Commands); existing roster and wake inbox.
- **Design.** Plan §5 table. Every field carries `observed_at`, `age_ms`,
  `freshness` (CLI parity, AGENTS.md "Computed ages"). Unknown and unsupported are
  distinct atoms (`:unknown`, `:unsupported`), never coerced (AGENTS.md
  "collapsed causes").
- **Tickets.**
  - MP-E3-C4-T1 Harness-state machine from hooks with TTL to `unknown`.
  - MP-E3-C4-T2 Background-agent roster from subagent/task hooks (start, stop, last message; transcript link only if RQ-E3-4 passes).
  - MP-E3-C4-T3 Blocker aggregation: Executor Commands (E2), `aiur ask` open items, fleet blockers; per-source availability.
  - MP-E3-C4-T4 (optional, OQ-E3-6) aiur-run skill emits `executor.progress` on its progress-table cadence.
  - MP-E3-C4-T5 `aiur status` / `aiur executor-session --json` print the snapshot.
- **Tests.** Mutation guards: replace `:unknown` with `:idle` → test fails;
  replace `:unsupported` background agents with `[]` → test fails; one blocker
  source erroring renders "unavailable", not an empty list.

## MP-E3-C5 — Executor input through the listener-mode package

**Outcome.** The operator sends a message to the Executor from aiur; it arrives
at a proven boundary or the UI says why not.

- **Deps:** C1; MP-E7 package with an Executor binding route; MP-E4-C6 (shared
  composer + delivery overlay).
- **Design.** `Listener.send(%ConversationRef{subject: executor}, text,
  client_request_id)`; display receipts (`harness_queued`, `in_context`,
  `failed`, `outcome_unknown`) per the E7 contract; match the later journal
  `operator_message` by `delivery_id`. Mode selector belongs to E7 (DESIGN-E7);
  E3 shows effective mode and support status read-only.
- **Tickets.**
  - MP-E3-C5-T1 Executor send adapter over E7 + capability gating (composer disabled with reason when `effective: null`).
  - MP-E3-C5-T2 Delivery overlay ↔ journal entry reconciliation (shared with E4-C6).
- **Tests.** No E7 → composer disabled, reason shown; E7 refusal keeps message
  pending, never "delivered"; a static check that the Executor path has no
  `Aiur.Tmux` call.

## MP-E3-C6 — Dashboard Executor surface

**Outcome.** The DESIGN-E3 surface: Executor conversation, status header,
blockers, background agents, composer.

- **Deps:** C2 (or C3), C4, C5, MP-E4-C5 (conversation component), **DESIGN-E3 approved**.
- **Design.** New LiveView or component (not in `dashboard_live.ex`, 2,903
  lines). Route proposal `/executor` (and `/executor/at/:pos` for anchors);
  final route set by DESIGN-E3. Same entry rendering as worker conversations,
  distinct header and colour per design.
- **Tickets.** MP-E3-C6-T1 route + LiveView; T2 status header; T3 blockers +
  background-agents panels; T4 browser tests (`src/test/browser/`), including
  read-only and not-attached states; T5 docs `website/docs-app/guide/`.
- **Tests.** LiveView tests per state in DESIGN-E3; browser test at phone width.

## MP-E3-C7 — Setup, docs and skills

**Outcome.** An operator can opt in, verify, and opt out without reading code.

- **Deps:** C1, DESIGN-E3 copy.
- **Tickets.** MP-E3-C7-T1 `aiur executor-attach --check` (hook installed?
  trusted? last hook age? transcript readable?); T2 docs (`concepts/` page on
  the Executor conversation, privacy statement); T3 `aiur-run` and `aiur-intro`
  skills mention the opt-in.
- **Tests.** `--check` outputs each failure distinctly (not installed / not
  trusted / no hook yet / unreadable).

## Dependency sketch

```text
MP-E4-C1 ─┬─► E3-C1 ─┬─► E3-C2 ─┐
          │          ├─► E3-C3 ─┤ (research-gated)
          │          ├─► E3-C4 ─┤
MP-E7 ────┴──────────┴─► E3-C5 ─┼─► E3-C6 (DESIGN-E3)
MP-E4-C5/C6 ────────────────────┘
E3-C1 ─► E3-C7
```

C2 and C3 can run in parallel after C1. C4 can run in parallel with C2/C3.
