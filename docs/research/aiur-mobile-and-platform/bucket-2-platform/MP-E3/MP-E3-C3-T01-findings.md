# MP-E3-C3-T01 findings: Codex TUI Executor read spike (#4452)

Run 2026-11-20 on the PC host with `codex-cli 0.171.0`, in a private `CODEX_HOME`
with its own login, a scratch git repo, and capture hooks on `SessionStart`,
`UserPromptSubmit`, `PostToolUse`, `Stop`, `SubagentStart` and `SubagentStop`.
Three prompts: one shell command, one file edit, one subagent. The operator's real
`~/.codex` was not touched.

The ticket asked for 0.160.x. The local CLI is now 0.171.0, so every result below
is for 0.171.0, which is the version C3-T02 will meet first.

## Decision

**Codex Executor reader = tail the rollout file at the hook payload's
`transcript_path`, with an extractor keyed on `event_msg/item_completed` item
types.** Every hook payload carried `transcript_path`, and it always equalled the
session's rollout file, so C3-T02 needs no `session_id` to file-name mapping.
Subagents write their own rollout; `SubagentStop.agent_transcript_path` points at
it. RQ-E3-2 (reading through `codex app-server` `thread/read`) was not pursued, so
the rollout reader is the default.

## Checks

1. **Origin and version.** Both rollouts have `session_meta.originator =
   "codex-tui"` and `cli_version = "0.171.0"`. The subagent rollout carries two
   `session_meta` records: its own id, then the parent session's id.
2. **`transcript_path`** equals the rollout path in 16 of 16 hook payloads (never
   `null`). `SubagentStop.agent_transcript_path` equals the subagent's rollout.
3. **Item types** (counts from the run, both rollouts):
   - `event_msg/item_completed` items: `AgentMessage{content, id, phase}` 8,
     `CommandExecution` 5, `UserMessage{client_id, content, id}` 3,
     `SubAgentActivity` 2, `CollabAgentToolCall` 1.
   - New compared with the 0.160 census: `CollabAgentToolCall{agents_states, receiver_agents,
     receiver_thread_ids, sender_thread_id, status, tool}`;
     `SubAgentActivity{agent_path, agent_thread_id, kind, model, reasoning_effort}`;
     record type `inter_agent_communication_metadata`;
     `response_item` subtype `additional_tools`.
   - `CommandExecution` gained `duration, parsed_cmd, process_id, source, status`
     next to `aggregated_output, command, cwd, exit_code, id`.
   - Also seen: `response_item` `message` 34, `custom_tool_call(_output)` 9 each,
     `function_call(_output)`, `agent_message`; `event_msg` `token_count` 11,
     `task_started` 7, `task_complete` 6, `thread_settings_applied` 4,
     `turn_aborted` 1; `turn_context` 7, `world_state` 4, `token_usage_record` 11.
4. **Subagent hooks (RQ-E3-6).** Every hook has `cwd, hook_event_name, model,
   permission_mode, session_id, transcript_path` (plus `turn_id` after the first
   prompt).
   - `SubagentStart`: `+ agent_id, agent_type`.
   - `SubagentStop`: `+ agent_id, agent_type, agent_transcript_path,
     last_assistant_message, stop_hook_active`.
   - A `PostToolUse` fired inside the subagent also carries `agent_id, agent_type`.
   - `Stop`: `+ last_assistant_message, stop_hook_active`. `UserPromptSubmit`:
     `+ prompt`. `PostToolUse`: `+ tool_input, tool_name, tool_response, tool_use_id`.
5. **RQ-E3-2** (app-server `thread/read` on a live TUI thread): not pursued.
6. **Fixtures:** `src/test/fixtures/codex_rollouts/0.171/` holds
   `tui-main.jsonl`, `tui-subagent-1.jsonl` and `tui-hooks.jsonl`. Structure,
   `type`, ids and enum-like fields are kept. Every other string is
   `"<redacted>"`, and so is every account, user, org or workspace identifier. In
   the hooks file, transcript paths are replaced by `<rollout:tui-main>` or
   `<rollout:tui-subagent-1>`.

## Notes for C3-T02

- Hooks need the `codex_hooks` feature (`[features] codex_hooks = true`) and a
  one-time trust prompt in the TUI ("6 hooks are new or changed"). Without trust,
  they don't run.
- The TUI also asks to trust the folder before the first session starts.
- Key the extractor on item `type` and tolerate unknown types. Two new types
  appeared between 0.160 and 0.171.
- This doc stands in for "MP-E3/plan.md §10", which does not exist on main; the
  MP-E3 folder holds only ticket files.
