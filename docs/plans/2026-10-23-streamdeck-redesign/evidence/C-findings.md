# Group C findings — deck ticket page (SD-301..SD-304)

Researched at `6a7d6b445`. Paths are relative to the worktree root. Line numbers are at that commit.

## 1. What the desktop ticket modal reads today

The modal is part of `AiurWeb.BuildLive` (`src/lib/aiur_web/live/build_live.ex`). It has three reads.

| Modal part | Server owner | Source |
| --- | --- | --- |
| Header: number, title, status, agent, PR link | `AiurWeb.Build.Ticket.open/2` (`build/ticket.ex:6-37`) | `DataSource.call(source, :ticket, [id, opts])` → `Build.IndexSource` / `IndexReader` row, wrapped by `Build.Payload.ticket/3` (`payload.ex:105`), plus `Controls.read_body/2` for the pause control |
| Pause/resume control | `AiurWeb.Build.Controls.request/2` (`controls.ex:14-22`) → `OperatorControlCenter.UnitControls.pause/resume` → `Aiur.AgentChat.pause/resume` (`agent_chat.ex:103-113`) → `Orchestrator.pause_agent/resume_agent` | `TicketControl.encode/3` gives `%{action, state, title, status}` |
| Conversation body | `AiurWeb.Build.Conversation` (`build/conversation.ex`) — LiveView-bound (uses `assign`, `push_event`) | `Build.ConversationSource` behaviour (`conversation_source.ex`), default `ConversationSource.Wave0b` |
| Command card | `AiurWeb.Build.CommandCard` + `OperatorControlCenter.DecisionCommands.record_answer/4` | `Aiur.Commands.answer/4` on `DecisionStore` |

Client side: status label and tone come from `priv/static/build-home/modal/header.js:13-21` (row
`sec` + `agent.state` through `now-state.js` `AST`). The PR link is `repo.url + "pull/" + pr.num`
(`header.js:33-41`), shown only when the row has `pr`.

### Conversation read path (the one SD-303/SD-304 must share)

- `ConversationSource.Wave0b.prepare/2` (`wave0b.ex:11-51`) finds the running entry from
  `Orchestrator.dashboard_snapshot/2`, the workspace (`Layout.issue_workspace_path`), the
  `logs/agent.ndjson` path and the `LiveConversation` generation handle.
- `tail/3` and `page/3` (`wave0b.ex:54-58, 78-122`) read the workspace transcript with
  bounded pages: `Conversation.History.workspace_paged_tail|since|before` →
  `Aiur.AgentLog.PageReader` (64 KiB reads, opaque line cursors). Remote agents and agents
  with no log fall back to the live projection (`projection_view/2`, `wave0b.ex:153-159`).
  Legacy `agent.md` and "not retained" states are explicit (`wave0b.ex:126-147`).
- Entries are mapped by `ConversationSource.Entries` (`entries.ex`) into the wire shape
  `%{id, at, k: "say"|"op"|"sys"|"tool", text | name/arg/res/bad}`. Text is capped at 8,000 chars.
- View shape: `%{state, reason, entries, before, last, more?, live?, observed_at, note, evicted}`
  (`wave0b.ex:181`). States: `live ended known_empty stale unavailable restart_unknown not_retained`
  (`conversation_payload.ex:6`).
- Live updates: `subscribe/2` → `History.live_subscribe/1` (`LiveConversation.subscribe_handle`)
  sends `{:live_conversation_changed, snapshot}` / `{:live_conversation_restarted, ...}` to the
  **calling process**; `Build.Conversation` also polls the tail with `log_since` on a timer
  (`conversation.ex:75-92`). Events beside the chat come from `ConversationSource.Wave0bEvents`
  (`TicketHistoryProvider`) through `ConversationEventFeed`.
- `Conversation.Anchors` (`conversation/anchors.ex`) is used today only by `StreamdeckLogs`; the
  modal does not use it. `Conversation.History` re-exports it.

Conclusion: the deck should call `ConversationSource.source()` + `ConversationSource.call/3`
(prepare, tail, page, subscribe, unsubscribe) from the channel process. `Build.Conversation`
itself cannot be reused: it is welded to the LiveView socket. A ~100-line deck controller is
the right size.

## 2. What the deck shows today for a focused agent

- Focus: `streamdeck_channel.ex:47-66` assigns `focused_agent`; `handle_info
  {:streamdeck_focus_changed,...}` (`:254-263`) starts `StreamdeckTranscriptRelay` and pushes
  `logs` and `commands`.
- `StreamdeckTranscriptRelay` (`streamdeck_transcript_relay.ex`) subscribes to
  `AgentPubSub.subscribe_agent/1` and throttles `{:transcript_event, _}` to one push per 250 ms.
  Each flush pushes `transcript` and a full re-read of `logs` (`streamdeck_channel.ex:294-298`).
- `StreamdeckLogs.load/1` (`streamdeck_logs.ex:489-497`) reads
  `History.transcript(identifier, %{"limit" => 50})` = `AgentEventFeed.list/2` (in-memory bus
  feed) + `History.bus_events/1`, then anchors with `Conversation.Anchors`. **This is a
  different source from the modal**: it is empty after a daemon restart and capped at 50
  entries, while the modal reads the workspace `agent.ndjson`. This is the root cause of #5181
  item 1.
- Sidecar: `main.ts:354-361` ignores `transcript` and feeds `logs` to `controller.setLogs`.
  `logs.ts` flattens events + entries; `touchStrip/chatLog.ts` maps scroll offset to the 7
  event keys + LIVE.
- Strip, cmd mode: `touchStrip/agentDetail.ts` + `art/chat-readout.ts:371-379` /
  `art/segmentPanels.ts:46-118` — the left quarter (`summaryWidth = width / 4`, 200 px) is a
  summary column (epic icon, provider mark, ticket id, BACK hint); title/bar/activity use the
  other 600 px. No chat is shown in cmd mode.
- Strip, logs mode: `stripLayout.ts:257-268` → one 800x100 `chatLog` panel, 5 rows
  (`chat-readout.ts:357-368`). Each row starts after a glyph and a role badge up to 72 px
  (`chat-readout.ts:135-141`).
- Status on the deck comes from `StreamDeckGrid` buckets and the grid agent DTO, not from the
  Build row (`agentDetail.ts:9-17`). Modes: `mode.ts:9` (`grid cmd logs settings commands`).

## 3. #5181 — cause and how this plan treats it

#5181 is OPEN, `agent:in-progress`, priority:2. It reports two things from the browser emulator
(2026-10-18): (1) Logs shows one event while `agent.ndjson` has 18k lines; (2) in Logs and
Commands modes the key block sits about 40 px right of grid mode. It is not a strip-only issue.

- Cause of (1): §2 above — deck Logs reads the in-memory `AgentEventFeed` (limit 50), not the
  workspace transcript.
- Cause of (2): emulator CSS list spacing (`priv/static/css/52-streamdeck-1.css`) shifts the
  key cells in the Logs/Commands templates.
- The "left-edge squeeze" the brief names is the cmd-mode strip: 200 px summary column
  plus, in logs mode, glyph + 72 px badge gutter before each line.
- PR #5284 (head `40ed8895`, last update 2026-10-19, **CHANGES_REQUESTED**) fixes (1) only in
  the emulator path (`StreamdeckLive` / `StreamDeckGrid` read `AgentLog.read_workspace` privately)
  and (2) in CSS. It adds a third transcript reader. The channel path (physical deck) is not fixed.

Recommendation: treat #5181 as **superseded** by SD-303 + SD-304 (transcript from
`ConversationSource`, full-width strip) and SD-104 (emulator shows server images, so the CSS
offset goes away). The Executor should park #5181 (`agent:paused`) now so its agent does not
keep rebasing into files SD-105 deletes, close PR #5284 with a pointer to SD-303/SD-304, and
close #5181 when SD-304 merges. Keep #5181's acceptance ("a seeded transcript shows on the deck;
the test fails on main") as an SD-304 acceptance criterion.

## 4. Existing action APIs

| Action | API | Notes |
| --- | --- | --- |
| Pause / resume a ticket's agent | `Aiur.AgentChat.pause/1`, `resume/1` → `Orchestrator.pause_agent/resume_agent` | Deck already calls these: `streamdeck_channel.ex:84-96` (`control` event, `pause_agent/1` at `:387-392`). Same path as desktop `Controls`. `resume` also returns `:started`/`:reactivated` for a ticket without a live agent. |
| Answer a Command | `AiurWeb.StreamdeckChannel.CommandAnswers.record_command_answer/2` → `Aiur.Commands.answer/4` (actor `%{kind: :operator, id: "streamdeck"}`) | `answer_command` event, focused-ticket + version enforced (`streamdeck_channel.ex:157-174`). History via `StreamdeckCommands.history/3` (limit 8, opaque cursor). Already shared with the desktop's `DecisionStore`. |
| Priority up/down | `Aiur.BuildQueue.reorder(id, at)` (`build_queue.ex:66-67`; `ListMutations.reorder/3`) | Current position = row `qpos` (plan rows). Also `BuildQueue.hold/release`. No deck caller today. SD-206 owns the dial; the ticket page reuses the same handler. |
| Queue a ticket with no agent | `Aiur.AgentControlCLI.todo/2` | Deck `control` `implement` (`streamdeck_channel.ex:113-128`). |
| Open the desktop modal | URL `/build?ticket=<n>` (`routes/dashboard_pages.ex:47`, `Build.URLState` param `ticket`) | No deck-side opener exists. The sidecar has an injected `spawn` (`runtime.ts:42`, `line-source.ts`) that can run `xdg-open`. |
| Open the PR | `repo.url + "pull/" + num` (same as `header.js:40-41`) | Needs a PR number; see §5. |

## 5. PR/CI state sources

- Build row `pr` (`build_order/index/rows.ex:117, 158-159`): set **only for merged PRs**
  (`%{num, state: "merged"}`). Open PRs are absent, so the desktop modal shows no PR link for a
  ticket in review either.
- `Aiur.StartTrigger.ProgressStore.lookup/1` (`start_trigger/progress_store.ex:9, 15`):
  `%{pr_number, stage: :pr_opened | :pr_ci_green | :pr_approved | :pr_merged | nil,
  closed_unmerged?, head_sha, observed_at_ms, source}`. Fed by webhooks, the CI poller
  (`ci_identity/2`) and `BuildQueue.PRObserver`. This is the best open-PR + CI-green source.
- CI-red / CI-wait / merge-queued come through the agent state: `NowRows.agent_state/1`
  (`now_rows.ex:115-155`) returns the reason-label suffix (`ci-red`, `merge-queued`, `body-fix`,
  ...) or `ci_wait` / `usage_limited` / `parked` / `paused`; `agent.pause` = `ci_wait`.
  Labels are defined in `github/labels.ex:37-38, 248-249`.
- Recommendation: add the open PR to the shared Build row (Rows/NowRows `pr` from
  `ProgressStore`, with `ci` = stage) so the desktop modal gains the same field; the deck reads
  the row. If that is too wide for SD-301, SD-301 reads `ProgressStore.lookup/1` in the adapter
  and files the shared-row change as a follow-up. Default: put it in the shared row.

## 6. Renderer dependency

The current TS renderer already has an 800x100 `chatLog` panel and an 8-key event window, and
cmd mode already has Pause, Commands and Logs keys. All four tickets can ship on the current
renderer with new data. SD-102/SD-103/SD-104 then port the painters. None of SD-301..SD-304
needs SD-102. They all touch `mode.ts`/`controller.ts`/`surface.ts`, so they serialize with
SD-201 and with each other on those files.
