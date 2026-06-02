# opencode 1.15.6 SQLite row shapes

Reference for Aiur's direct-INSERT path (`Aiur.Opencode.Db`, `Aiur.Opencode.Protocol`). Capture dumped from a live `opencode serve` 1.15.6 + `~/.local/share/opencode/opencode.db` on 2026-05-20. Re-validate against this file whenever opencode is bumped.

## Tables

- `message(id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)`
- `part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)`

`id`, `session_id`, `message_id` are stored as SQL columns. The `data` column carries the type-specific JSON without those id fields — opencode composes the full `Message`/`Part` API shape from column + data at read time.

## ID format

`^msg[A-Z0-9]+` and `^prt[A-Z0-9]+` (Crockford base32 from monotonic time + entropy).
- Observed example: `msg_e482660ac001usDysRIdSUvFse` (26 chars after prefix)
- Observed example: `prt_e482660ad001TaakqHYSQJCFx5` (26 chars after prefix)

## Assistant message data (real row)

```json
{
  "parentID": "msg_e482660ac001usDysRIdSUvFse",
  "role": "assistant",
  "mode": "build",
  "agent": "build",
  "path": { "cwd": "/home/orangekid", "root": "/" },
  "cost": 0,
  "tokens": {
    "total": 9198,
    "input": 9046,
    "output": 123,
    "reasoning": 29,
    "cache": { "write": 0, "read": 0 }
  },
  "modelID": "big-pickle",
  "providerID": "opencode",
  "time": { "created": 1779326935347, "completed": 1779326954087 },
  "finish": "tool-calls"
}
```

**Required keys** (per `AssistantMessage` OpenAPI schema, with `id`/`sessionID` supplied by SQL columns):
- `role: "assistant"`
- `time: {created, completed}` — both ms-epoch ints
- `parentID` — MUST match `^msg` pattern; chain or point to a synthetic root
- `modelID`, `providerID` — Aiur uses `providerID: "aiur"`, `modelID: "issue-<X>"`
- `mode`, `agent` — both `"build"` for normal flows
- `path: {cwd, root}` — opencode shows these in the sidebar; Aiur sets `cwd` to the agent's workspace, `root` to `/`
- `cost: 0`, `tokens: {input, output, reasoning, cache: {read, write}}` — all zero for Aiur-injected rows (cost belongs to codex, not opencode)
- `finish: "stop" | "tool-calls" | …` — "stop" for assistant text, "tool-calls" when followed by a tool part

## User message data (real row)

```json
{
  "role": "user",
  "time": { "created": 1779326935275 },
  "agent": "build",
  "model": { "providerID": "opencode", "modelID": "big-pickle" },
  "summary": { "diffs": [] }
}
```

Used by Aiur for the synthetic root that history-replay assistant messages chain off, AND for the live-update marker (`{type:"text", text:"__aiur_stream__:msg_…", synthetic:true}`).

## Part data shapes

### text

```json
{ "type": "text", "text": "hello" }
```

Optional `synthetic: true` to mark a programmatically-inserted part. Optional `time: {start, end}`.

### reasoning

```json
{
  "type": "reasoning",
  "text": "...",
  "time": { "start": 1779326938113, "end": 1779326938539 }
}
```

### tool

```json
{
  "type": "tool",
  "tool": "bash",
  "callID": "call_<id>",
  "state": {
    "status": "completed",
    "input": { "command": "ls" },
    "output": "<stdout>",
    "metadata": {},
    "title": "$ ls",
    "time": { "start": 1779326939230, "end": 1779326954061 }
  }
}
```

`callID` is opencode's own internal id; we generate `call_<random>` for our injected rows.

### step-start

```json
{ "type": "step-start" }
```

### step-finish

```json
{
  "reason": "tool-calls",
  "type": "step-finish",
  "tokens": { "total": 9198, "input": 9046, "output": 123, "reasoning": 29, "cache": { "write": 0, "read": 0 } },
  "cost": 0
}
```

`reason` is one of `"stop" | "tool-calls" | "length" | "content-filter"`. `cost` and `tokens` are required; all zero for Aiur-injected rows.

## Session row shape (excerpt)

```text
id TEXT PK
project_id TEXT (e.g. fa75e... or "global")
parent_id TEXT NULL
directory TEXT NOT NULL          -- inherits server cwd unless ?directory= override
title TEXT
workspace_id TEXT NULL
agent TEXT
model TEXT (JSON: { providerID, modelID })
... cost/token columns
```

Aiur identifies its own sessions via `model.providerID == "aiur"` (see `Aiur.Opencode.Protocol.aiur_owned?/1`).
