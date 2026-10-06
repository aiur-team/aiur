---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-E3
bucket: 2-platform
base_main_sha: 45a290e3
date: 2026-10-06
owner_gate: DESIGN-E3
contracts_owned: []
contracts_consumed: [MP-CT-conversations-transcripts-anchors, harness-adapter (MP-R7), listener-mode (MP-E7), events-and-replay (MP-R2), command-request-resolution (MP-E2), identity]
prior_units: [U3, U4, U6, U8]
prior_boundaries: [EXE, CLD, CDX, RUN, WEB, BUS, DEC]
---

# MP-E3 — First-class Executor communication: plan

Chunk details are in [chunks.md](chunks.md). The conversation, transcript and
anchor contract is in
[../../contracts/conversations-transcripts-anchors.md](../../contracts/conversations-transcripts-anchors.md)
(owned by MP-E4). The owner gate is
[../../owner-design-tasks/DESIGN-E3.md](../../owner-design-tasks/DESIGN-E3.md).

## 1. Goal

Let the operator read the Executor's conversation and send it input from the
aiur dashboard, for Claude Code and Codex Executors, so that Claude Remote
Control is not the only path. Show the Executor's status, blockers and background
agents when the harness exposes them. Use the same conversation system as
workers (MP-E4), shown as a distinct Executor surface. Keep one Executor per
instance.

**The Executor is not a daemon-spawned worker.** It is an external interactive
Claude Code or Codex session that the human started (AGENTS.md "Orientation";
`src/README.md § Who operates a run`). aiur does not own its process, its PTY or
its transcript file. Everything in this plan follows from that.

## 2. Repository findings (extends baseline E3)

### 2.1 What aiur already knows about the Executor

| Fact | Evidence |
| --- | --- |
| The Executor is identified only as a wake-stream consumer: `id`, `role` (owner/observer), `host`, OS `pid`, lease times, ack counts. No harness, no session id, no transcript path. | `src/lib/aiur/executor/claims.ex:309-325` |
| Consumer id: `--as`, then `AIUR_EXECUTOR_ID`, then `<hostname>-<instance>`. | `claims.ex:185-193` |
| `Aiur.Executor.Principal` starts only on `aiur --executor` and renews the lease. | `executor/principal.ex:1-36`; `cli.ex:25` |
| The roster derives `active/idle/stalled/expired/unknown` from acknowledgement evidence only. Its moduledoc says "Multiple executors are a supported configuration". | `executor/roster.ex:1-41` |
| The Executor can publish only `executor.*` topics (`executor-emit`). | `agent_control_cli.ex:384-402`; `executor_events.ex:265-270` |
| Executor → human requests use a separate `aiur ask` store with no dashboard view. | baseline E2; no `Aiur.Asks` in `src/lib/aiur_web` |
| The `aiur-run` skill tells the Executor to post a periodic progress table "on a real cadence", not per tick. It is chat text in the Executor's own session; aiur never sees it. | `.claude/skills/aiur-run/SKILL.md:99-120` |
| No dashboard surface mentions the Executor's conversation. The router comment calls the worker message endpoint "Executor chat" (the Executor chatting to workers). | `src/lib/aiur_web/router.ex:55-62` |

### 2.2 Reusable prior art for reading and steering a Claude session

aiur already reads Claude transcripts and ingests Claude hooks, for its own
Remote-Control workers. This is the closest prior art for an external Executor.

| Component | What it does | Evidence |
| --- | --- | --- |
| `Aiur.Claude.TranscriptTailer` | Tails a Claude transcript JSONL by byte offset (400 ms poll). Emits only complete lines. Detects truncation or replacement and restarts from 0. Fires a turn-end callback on a terminal `stop_reason`. | `claude/transcript_tailer.ex:1-260` |
| `Aiur.Claude.Transcript.extract_disk_record/2` | Maps on-disk Claude records (`assistant`, `user`, `attachment`/`queued_command`) to transcript events; ignores `system`, `file-history-snapshot`, `queue-operation` and others. Captures RC-origin messages. | `claude/transcript.ex:54-140` |
| `Aiur.Claude.DisplayTailer` | Learns `transcript_path` from the hook stream, tails `from: :start` (backfill), retargets when the session rotates. Read-only; never sends keys. | `claude/display_tailer.ex:1-60` |
| `Aiur.Claude.HookEvents` | Normalizes hook payloads (`session_id`, `cwd`, `prompt`, `last_assistant_message`, `tool_name`, `transcript_path`) and broadcasts on PubSub `claude_hook:<id>`. A hook POST never fails Claude. Notes that Claude 2.1.177 flushes the transcript lazily. | `claude/hook_events.ex:1-110` |
| `Aiur.Claude.HookSettings` | Generates `--settings` hooks for `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure`. The command is stdout-silent, `-m 2`, always exit 0, and sends `Origin` + `X-Aiur-Request` headers. | `claude/hook_settings.ex:13-45` |
| Hook endpoint | `POST /api/v1/:issue_identifier/claude-hook` behind `dashboard_auth` + `api_write`, deliberately outside the read-only gate. | `router.ex:166-178` |
| `Aiur.Claude.Repl.OperatorInject` | Delivers worker input by `tmux send-keys -l` + Enter into a pane aiur owns, with control bytes stripped. | `claude/repl/operator_inject.ex:14-108` |
| `Aiur.CodingAgent.Backend` | Worker contract: `send_operator_message/2`, optional `interrupt/1`, capability flags (`immediate_delivery`, `can_interrupt`, `safe_checkpoints`). | `coding_agent/backend.ex:40-148` |

`OperatorInject` does **not** transfer to the Executor: aiur does not own the
Executor's tmux pane. Typing into a terminal aiur did not create would be a PTY
wrapper, which Khala's research marks `blocked_without_wrapper` and requires an
operator decision (Khala `docs/product/internal-mode/listening-modes.md`,
origin/main `99e72a43`).

### 2.3 External harness capabilities (verified 2026-10-06)

Local versions: Claude Code `2.1.291`, `codex-cli 0.160.0`.

| Capability | Claude Code | Codex CLI | Source |
| --- | --- | --- | --- |
| Hook payload names the transcript | Every hook gets `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `permission_mode`; subagent hooks add `agent_id`, `agent_type`. | Every hook gets `session_id`, `transcript_path` (nullable), `cwd`, `hook_event_name`, `model`, `permission_mode`, `turn_id`. | [Claude hooks](https://code.claude.com/docs/en/hooks), Codex: `openai/codex` `codex-rs/hooks/src/schema.rs` @ `a9abdeaf` (Phase D pin, T-11); both read 2026-10-06 |
| Session boundaries | `SessionStart` with source `startup | resume | clear | compact | fork`; `SessionEnd`. | `SessionStart`, `SessionEnd`. | same |
| Background agents | `SubagentStart` (`agent_id`, `agent_type`), `SubagentStop` (adds `agent_transcript_path`, `last_assistant_message`); `TaskCreated`, `TaskCompleted`. | `SubagentStart` (`agent_id`, `agent_type`), `SubagentStop` (adds `agent_transcript_path`, `stop_hook_active`, `last_assistant_message`), per the pinned schema; local-binary capture still in MP-E3-C4-T02. | same |
| Add model context from a hook | `additionalContext` on `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SubagentStart/Stop` and others; `Stop` can `decision: "block"` with a reason. | Add context: `SessionStart`, `PreToolUse`, `PostToolUse`, `SubagentStart/Stop`, `UserPromptSubmit`, `Stop`. | same |
| Wake an idle session | `asyncRewake` hook: a background hook that exits 2 wakes Claude with its stderr as a system reminder. Khala proved an idle wake on 2.1.283 with a Stop-armed watcher (3,000 s lifetime). | `codex queue --thread <id> --message <text>` starts a turn in a live TUI. The text is in argv, there is no stdin form and no receipt; Khala uses it only for a fixed content-free wake. | Claude hooks page; Khala `experiments/internal-mode/listening-modes/claude/README.md`; `codex queue --help` (0.160.0); Khala `docs/product/internal-mode/interactive-codex.md` |
| Push a message into a running session | **Channels**: an MCP server pushes `notifications/claude/channel`. Research preview; custom channels need `--dangerously-load-development-channels`; no acknowledgement; events queue to the next turn. | No supported stdin, attach socket or IPC into a running TUI (Khala inventory, 0.154/0.156). 0.160 adds `codex agents` (sessions on a "shared local app-server daemon"); attach semantics unverified. | [Claude channels reference](https://code.claude.com/docs/en/channels-reference) read 2026-10-06; Khala `interactive-codex.md` |
| History read API | None documented. The transcript JSONL format is not documented as stable. | App-server v2 schema (0.160.0) has `thread/read`, `thread/turns/list` and `thread/items/list` with `cursor`/`limit`. Whether a second app-server can read a thread a live TUI is writing is unverified. | `codex app-server generate-json-schema` output, 0.160.0 |
| Trust gate | Hooks in user or project settings, or a plugin. | New or changed hooks run only after the user trusts them in the TUI's review dialog; trust is stored by hash. | Codex hooks page; Khala `interactive-codex.md` |

Khala's E09 research (origin/main `99e72a43`) already proved, on the user's own
interactive CLIs and under normal trust: Codex `steer`, `sync` and `async` plus
idle wake on 0.154.0 and 0.156.1; Claude busy `steer` (`PostToolUse`), busy and
idle `sync` (experimental), and `async` on 2.1.283. This is the substrate MP-E7
packages. MP-E3 consumes it and does not re-prove it.

## 3. Proposed boundaries

```text
aiur_executor (EXE, prior boundary #26)
  Aiur.Executor.Session          NEW  binding of the one attached external session (opt-in)
  Aiur.Executor.SessionIngest    NEW  hook ingest → session record, status, subagent roster
  Aiur.Executor.Status           NEW  projection: harness status + wake/claim/roster + blockers
  Aiur.Executor.{Claims,Roster,Principal,…}   existing, unchanged
harness adapters (MP-R7)
  claude: TranscriptTailer + Transcript.extract_disk_record   existing, reused for attached sessions
  codex:  RolloutTranscript (NEW extractor) or app-server history reader (research)
conversations (MP-E4)
  ConversationJournal            subject {kind: "executor"} — same store as workers
listener mode (MP-E7)
  send/receipts into the attached session — E3 calls it, never injects itself
aiur_web (WEB)
  Executor conversation surface  NEW, gated by DESIGN-E3; reuses the E4 conversation component
```

**Public interfaces (proposed; none exist at `45a290e3`):**

```text
Aiur.Executor.Session.attach(%{harness, provider_session_id, transcript_path, cwd, pid?, consumer_id?})
    -> {:ok, binding} | {:error, :already_attached | :invalid | :not_opted_in}
Aiur.Executor.Session.detach(binding_id, reason) -> :ok
Aiur.Executor.Session.current() -> {:ok, binding} | :none
Aiur.Executor.Status.snapshot() -> %{binding, harness_state, observed_at, freshness,
    wakes: %{pending, cursor}, roster, blockers: [...], background_agents: [...] | :unsupported}
POST /api/v1/executor/hook   (machine-to-machine, token, outside the read-only gate)
```

**Required dependencies:** EXE (claims, roster, wake inbox), MP-E4 journal.
**Optional:** MP-E7 (input; without it the surface is read-only), MP-E2 (Executor
Commands as blockers), voice (MP-E5). The dashboard is optional for capture: the
journal fills with the dashboard listener off, as long as the hook endpoint is
bound (same constraint as Remote Control today, AGENTS.md "Running").

## 4. Alternatives and recommendation

### 4.1 Reading the Executor conversation

| Option | For | Against |
| --- | --- | --- |
| A. **Opt-in hooks report `transcript_path`; aiur tails the provider transcript** into the MP-E4 journal | Works with the user's own CLI, no wrapper. Claude path reuses `TranscriptTailer`/`extract_disk_record` already in production for RC workers. Gives backfill and live. Both harnesses document `transcript_path`. | The transcript file format is undocumented and can drift; extraction must be version-pinned and fail soft. Claude flushes lazily (`hook_events.ex:7`), so live lag is bounded by flush, not by poll. |
| B. Launch the Executor under aiur (aiur-owned PTY or app-server) | Full control, like workers. | Contradicts the operating model (the human or their agent starts the Executor) and Khala's one-agent-process rule. Not chosen. |
| C. Claude Remote Control relay | Already used by the owner. | Claude-only, cloud-mediated, not aiur-native; the brief asks for an alternative. |
| D. Codex app-server `thread/turns/list` reader | Documented paging and stable item ids. | Experimental surface; reading a thread owned by a live TUI from a second app-server is unproven. |

**Recommendation:** A for both harnesses. For Codex, D is a research spike
(MP-E3.C3 research question RQ-E3-2); if it proves safe it replaces the rollout
parser because it has a typed schema.

### 4.2 Sending input to the Executor

| Option | For | Against |
| --- | --- | --- |
| A. **Through the MP-E7 listener-mode package** (hooks + idle wake; steer/sync/async) | Proven native routes on both CLIs (Khala). One send path for every client. Receipts and modes already designed. | Depends on E7 shipping; Claude `sync` idle rearm is still experimental. |
| B. tmux `send-keys` into the Executor's terminal | Simple. | aiur does not own the PTY; it is a wrapper (blocked without owner decision); typing races the human. |
| C. Claude channels | Native push into a running session. | Research preview; custom channel needs a `--dangerously-…` flag; no acknowledgement. |

**Recommendation:** A. E3 never implements delivery. With no proven route the
composer is disabled with the reason. C is recorded as a possible E7 route, not
an E3 default.

### 4.3 One Executor per instance

`Roster` accepts many consumers. The **conversation** binding is singular:
`attach` refuses while another binding is live (`:already_attached`, naming it),
unless the operator passes an explicit takeover, which ends the old session
(`end_reason: "superseded"`) and opens a new one. This mirrors the claims rule
"taking from a live owner is refused; revoke is explicit" (`claims.ex:18-20`).
Liveness = the last hook or tail activity inside a TTL (proposed 10 min, the
lease TTL, `claims.ex:53`).

## 5. Executor status, blockers and background agents

| Field | Source | Unknown/absent rendering |
| --- | --- | --- |
| Attached / not attached | `Executor.Session` | "No Executor session attached" + how to attach. Never "idle". |
| Harness state: `working | waiting_for_input | idle | ended | unknown` | `UserPromptSubmit` → working; `Stop` → idle; `Notification` (Claude, matchers to verify, RQ-E3-5) → waiting; `SessionEnd` → ended | `unknown` with age when no hook arrived inside the TTL |
| Last activity age | last hook / last tailed entry | rendered with `observed_at`, `age_ms` (AGENTS.md "If a surface computes an age, it renders the age") |
| Wake inbox | `aiur status` `WAKES CURSOR/PENDING`, `ExecutorWakeInbox` | existing |
| Roster | `Executor.Roster.build(record?: false)` | existing states |
| Blockers | Executor-originated Commands (MP-E2, D12) + open `aiur ask` items + `system.*` fleet blockers in `ExecutorBindings` | list empty only when every source answered; a failed source shows "unavailable" |
| Background agents | Claude `SubagentStart/Stop`, `TaskCreated/Completed`; Codex `SubagentStart/Stop` | `:unsupported` for a harness/version without the hook; never `0` |

The aiur-run "periodic progress table" stays chat text. E4 can anchor an
`executor_progress` jump point only for events the Executor actually emits with
`executor-emit`. Making the skill emit one is a follow-up skill change, listed as
MP-E3.C4-T04 and an owner question.

## 6. Non-happy paths

| Case | Behaviour |
| --- | --- |
| Hooks not installed (not opted in) | Executor surface shows "not attached" and setup steps. No scanning of `~/.claude` or `~/.codex` without opt-in. |
| Codex hooks not yet trusted in the TUI | No hook arrives; status `unknown`; setup check reports "hooks need review in Codex". |
| Transcript path unreadable / moved | Journal gap `source_unreadable`; status keeps hook-derived state; retry on next hook. |
| Transcript format drift (new record types) | Unknown records skipped and counted (`diagnostic_counts`, as `LiveConversation` does); a version mismatch raises a needs-attention alert once. |
| `/clear`, compaction, resume, fork | `SessionStart` source → new session in the same conversation; old one ended. |
| Daemon restart | Binding is durable; on boot, tail resumes from the stored byte offset; status `unknown` until the next hook. |
| Executor process dies without `SessionEnd` | TTL expiry → `ended` with `end_reason: "detached"` (inferred, labelled as such). |
| Two sessions try to attach | Second refused with the live one named; explicit takeover only. |
| Message sent while Executor busy | E7 mode decides (sync: next Stop; steer: next tool boundary). Overlay shows "queued for next boundary". |
| Message sent while Executor idle and no wake route | Overlay shows "waiting until the Executor's next turn"; never reported delivered. |
| Executor is itself waiting on a native question | **Not captured in v1** (X-55): MP-E2-C4/C5 capture native questions of daemon-run workers only, and no E2 ticket captures an attached Executor's native question from hooks. The Executor session shows its own prompt in the terminal; the blockers panel (C4-T03) lists only Commands the Executor raised with `aiur command request` (MP-E2-C6-T01). Hook-based capture is a candidate follow-up, not planned work. |
| Hook endpoint flooded / spoofed | Token required; per-binding rate limit; payload size cap (reuse webhook 25 MB guard pattern, smaller cap). |
| `--no-dashboard` | Hook endpoint needs the HTTP listener; attach refused with the same message shape as Remote Control (AGENTS.md "Running"). |
| Remote / multiple machines | Out of scope: the Executor must run on the daemon's machine (transcript is a local file). Phone reads go through MP-N2 pairing. |

## 7. Security and privacy

- **Opt-in only.** Installing the hooks is the opt-in: `aiur executor attach`
  installs or prints the hook config (user-scope Claude settings or plugin; Codex
  `~/.codex/hooks.json`) and the operator trusts it. `aiur executor detach`
  removes it and ends the binding.
- **Auth on the hook endpoint.** A per-instance random token in an owner-only file
  under the executor state dir (`Executor.StatePaths.dir/0`,
  `state_paths.ex:41`). The hook reads it from the file, never from argv. This is
  the same-UID trust boundary Khala documents; it is not attestation.
- **Message safety.** Operator text reaches the model only as structured hook
  context through E7, never as argv, env, shell or terminal bytes (Khala safety
  evidence, `interactive-codex.md` "Safety evidence").
- **Read scope.** The Executor transcript holds everything the operator typed.
  Dashboard auth gates it; the read-only dashboard can read but not send. Owner
  decision: whether paired phones (MP-N2 full access, D19) see it by default.
- **No log rewrite.** aiur never writes to the provider transcript.

## 8. Acceptance criteria

1. With hooks installed in a Claude Code 2.1.x Executor session, the dashboard
   Executor view shows the full conversation from the session's first record
   (backfill) and new entries within 2 s of the transcript flush.
2. Same for a Codex 0.160.x TUI Executor after hook trust, or the feature reports
   Codex as `unsupported` with the reason until RQ-E3-1/2 resolve.
3. `/clear` and compaction produce a visible session boundary; no entry is lost
   or duplicated across it (test: same provider record ingested twice → one entry).
4. A second `attach` while one is live is refused and names the live binding;
   explicit takeover ends the old session as `superseded`.
5. Status renders `unknown` with an age when no hook arrived inside the TTL, and
   a test fails if `unknown` is replaced with `idle` (AGENTS.md mutation rule).
6. Background agents render `unsupported` for a harness without subagent hooks;
   a test fails if replaced with `0`.
7. Sending a message goes only through the E7 service; with no proven route the
   composer is disabled with the capability reason; no tmux call targets a pane
   aiur did not create (test asserts no `Aiur.Tmux` call on the Executor path).
8. A hook POST without the token is rejected 401 and never changes state.
9. Restarting the daemon keeps the binding and continues the journal from the
   stored offset with no duplicate entries.
10. The view works with the dashboard in read-only mode (no composer).

## 9. Chunk summary (detail in [chunks.md](chunks.md))

| Chunk | Outcome | Depends on |
| --- | --- | --- |
| MP-E3-C1 | Executor session binding + authenticated hook ingest + CLI attach/detach/status | MP-E4-C1 contract; R7 hook normalization (or pre-refactor seam) |
| MP-E3-C2 | Claude Executor transcript → journal (reuse tailer) | C1, MP-E4-C1 |
| MP-E3-C3 | Codex Executor transcript → journal (rollout or app-server reader) | C1, RQ-E3-1/2 |
| MP-E3-C4 | Executor status, blockers, background-agents projection | C1, MP-E2 (Executor Commands) |
| MP-E3-C5 | Executor input through MP-E7, with receipts and overlay | C1, MP-E7-C3 (RC-05), MP-E4-C6; live delivery needs MP-E7-C6 (composer disabled until then) |
| MP-E3-C6 | Dashboard Executor surface | C2/C4/C5, MP-E4-C5, **DESIGN-E3** |
| MP-E3-C7 | Setup UX, docs, skill updates | C1, DESIGN-E3 (copy) |

## 10. Open questions

**Owner (Kevin), also in DESIGN-E3:**
- OQ-E3-1. Claude first and Codex second, or both required for the first release?
- OQ-E3-2. May paired phones/watch read the Executor transcript by default, or is it a separate opt-in?
- OQ-E3-3. Default listener mode for the Executor: D13's `sync`, or `steer` because the operator usually wants to redirect now? **Answered in DESIGN-E7 E7-D8** (the single owner, review G-7); DESIGN-E3 decision 2 links there.
- OQ-E3-4. Show reasoning and tool output in the Executor view, or messages only by default?
- OQ-E3-5. Takeover from the dashboard, or CLI-only?
- OQ-E3-6. Should the aiur-run skill emit `executor.progress` events so Executor progress becomes a jump point?

**Research (Phase C):**
- RQ-E3-1. Codex rollout JSONL record types at 0.160.x, and whether `migrate-rollouts` ("paginated thread history") changes the on-disk layout. Pin a fixture per version. **Census 2026-10-06 (types only, 200 + 40 local rollouts):** `event_msg/item_completed` carries typed items (`AgentMessage`, `Reasoning`, `CommandExecution`, `FileChange`, `UserMessage`, `DynamicToolCall`, `McpToolCall`, `SubAgentActivity`, `ContextCompaction`) at 0.157.1–0.160.1; no codex-tui rollout at 0.160 was present. MP-E3-C3-T01 closes that gap.
- RQ-E3-2. Can a separate `codex app-server` read `thread/turns/list` for a thread a live TUI owns, consistently and without side effects? Does the 0.160 shared app-server daemon let a second client subscribe to the TUI's thread?
- RQ-E3-3. Claude transcript flush latency on 2.1.29x (lazy flush noted at 2.1.177) — sets the live-lag acceptance number.
- RQ-E3-4. Is Claude `agent_transcript_path` stable enough to show subagent transcripts, or only start/stop rows?
- RQ-E3-5. Claude `Notification` hook matchers for "waiting for input" and Codex equivalent.
- RQ-E3-6. Codex `SubagentStart/Stop` payload fields.

## 11. Plan-refresh note

If MP-R1/R7 land first: `Aiur.Claude.TranscriptTailer` and
`Claude.Transcript.extract_disk_record/2` move into the harness-adapter package
(R7); C2 then calls the adapter's transcript-source interface instead of the
modules. `Aiur.Executor.*` moves to `aiur_executor` (boundary #26). The hook
endpoint moves with `aiur_web`. If MP-E3 starts before R7, it puts the
attached-session transcript reader behind the same narrow interface the R7
contract names (`transcript_source/1`) so R7 moves it, not rewrites it (D2
pattern). `dashboard_live.ex` is 2,903 lines at `45a290e3` (U8 `WEB` owner): the
Executor surface must be a new LiveView/component, not more lines in it.
