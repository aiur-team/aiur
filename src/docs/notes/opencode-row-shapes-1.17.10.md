# opencode 1.17.10 SQLite row shapes

Reference for Aiur's direct-INSERT path (`Aiur.Opencode.Db`, `Aiur.Opencode.Protocol`). Re-validated against a live `opencode serve` **1.17.10** on 2026-06-24 (sandboxed `XDG_DATA_HOME`). Re-validate against this file whenever opencode is bumped.

> **Bump note (1.15.6 → 1.17.10).** The row JSON shapes Aiur injects are unchanged and continue to render: a synthetic user root + assistant message + step/text parts were injected via direct SQLite and read back (`GET /session/<id>/message` → 200) and **painted in the real `opencode attach` TUI** (footer `Build · issue-1 · Aiur` + the injected text part). The two material differences vs 1.15.6 are noted inline below: (1) the `message`/`part` tables now carry **Drizzle foreign-key constraints**; (2) opencode's own assistant `tokens` object **no longer includes `total`** (Aiur still sends `total: 0` and it is accepted). No `Aiur.Opencode.Protocol` change was required.

## Tables

```sql
CREATE TABLE `message` (
  `id` text PRIMARY KEY,
  `session_id` text NOT NULL,
  `time_created` integer NOT NULL,
  `time_updated` integer NOT NULL,
  `data` text NOT NULL,
  CONSTRAINT `fk_message_session_id_session_id_fk`
    FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
)

CREATE TABLE `part` (
  `id` text PRIMARY KEY,
  `message_id` text NOT NULL,
  `session_id` text NOT NULL,
  `time_created` integer NOT NULL,
  `time_updated` integer NOT NULL,
  `data` text NOT NULL,
  CONSTRAINT `fk_part_message_id_message_id_fk`
    FOREIGN KEY (`message_id`) REFERENCES `message`(`id`) ON DELETE CASCADE
)
```

Columns are unchanged from 1.15.6. **New in 1.17.x:** both tables are now created by Drizzle with `FOREIGN KEY … ON DELETE CASCADE`. This imposes an insertion order on Aiur's replay path — the `session` row must exist before its `message` rows, and a `message` row before its `part` rows. `SessionWriter.replay_history/1` already inserts in that order (session created via `POST /session` → synthetic user root → assistant message → parts) inside one transaction, so the constraint is satisfied. (SQLite enforces FKs only when `PRAGMA foreign_keys=ON`, which is per-connection; Aiur's writes are valid regardless of that pragma because the order is correct.)

`id`, `session_id`, `message_id` are stored as SQL columns. The `data` column carries the type-specific JSON without those id fields — opencode composes the full `Message`/`Part` API shape from column + data at read time.

## ID format

`^msg[A-Z0-9]+` and `^prt[A-Z0-9]+` (Crockford base32 from monotonic time + entropy).
- Observed example (1.17.10): `msg_efc396bb1001B5Zzc32LoGCqAE`
- Aiur's generators (`Aiur.Opencode.Db.msg_id/0` etc.) match opencode's `^(msg|prt|call)[A-Z0-9]+` regex; the exact bit layout is irrelevant.

## Assistant message data (real 1.17.10 row, opencode-generated)

```json
{
  "parentID": "msg_efc396bb1001B5Zzc32LoGCqAE",
  "role": "assistant",
  "mode": "build",
  "agent": "build",
  "path": { "cwd": "/private/tmp/oc-repro/capture/ws", "root": "/" },
  "cost": 0,
  "tokens": {
    "input": 0,
    "output": 0,
    "reasoning": 0,
    "cache": { "write": 0, "read": 0 }
  },
  "modelID": "issue-1",
  "providerID": "aiur",
  "time": { "created": 1782348082217, "completed": 1782348083630 },
  "finish": "stop"
}
```

**Required keys** (per `AssistantMessage` schema, with `id`/`sessionID` supplied by SQL columns):
- `role: "assistant"`
- `time: {created, completed}` — both ms-epoch ints
- `parentID` — MUST match `^msg`; chain or point to a synthetic root
- `modelID`, `providerID` — Aiur uses `providerID: "aiur"`, `modelID: "issue-<X>"`
- `mode`, `agent` — both `"build"` for normal flows
- `path: {cwd, root}` — opencode shows these in the sidebar; Aiur sets `cwd` to the agent's workspace, `root` to `/`
- `cost: 0`, `tokens: {input, output, reasoning, cache: {read, write}}` — all zero for Aiur-injected rows
- `finish: "stop" | "tool-calls" | …` — "stop" for assistant text, "tool-calls" when followed by a tool part

> **`tokens.total` drift (1.15.6 → 1.17.10).** opencode's own assistant rows now **omit** `tokens.total` (1.15.6 included it). `Aiur.Opencode.Protocol.assistant_message_data/1` still sends `"total" => 0`; this extra field is accepted (verified: injected row read back 200 and rendered), so no builder change is needed. If a future opencode strict-rejects unknown token keys, drop `total` from `assistant_message_data/1` and `step_finish_part_data/1`.

## User message data (real 1.17.10 row)

```json
{
  "role": "user",
  "time": { "created": 1782348082097 },
  "agent": "build",
  "model": { "providerID": "aiur", "modelID": "issue-1" },
  "summary": { "diffs": [] }
}
```

Unchanged from 1.15.6. Used by Aiur for the synthetic root that history-replay assistant messages chain off, AND for the live-update marker (`{type:"text", text:"__aiur_stream__:msg_…", synthetic:true}`). Note the user message's `model` object uses `modelID` (the `POST /session` create body uses `id` — see below).

## Part data shapes

Observed part types (1.17.10, opencode-generated turn): `text`, `step-start`, `step-finish`. Shapes unchanged from 1.15.6.

### text

```json
{ "type": "text", "text": "hello" }
```

Optional `synthetic: true` to mark a programmatically-inserted part. Optional `time: {start, end}`.

### reasoning

```json
{ "type": "reasoning", "text": "...", "time": { "start": 1779326938113, "end": 1779326938539 } }
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

`reason` is one of `"stop" | "tool-calls" | "length" | "content-filter"`. `cost` and `tokens` are required; all zero for Aiur-injected rows. (As with the assistant message, Aiur's `tokens.total` is accepted even though opencode's own rows omit it.)

## Session create + ownership

Aiur creates sessions via `POST /session` with body `{title, model: {providerID: "aiur", id: "issue-<X>"}}` and a `?directory=` query param (see `Aiur.Opencode.ApiClient.create_session/3`). The `POST /session` model schema is `{id, providerID, variant?}` (note: `id`, not `modelID`) and is unchanged across 1.15.6 → 1.17.10.

The custom `aiur` provider is registered in the slot's `opencode.json` via `Aiur.Opencode.Protocol.opencode_json/1` (`npm: "@ai-sdk/openai-compatible"`, `models: {"issue-<X>": {"name": "issue-<X>"}}`). On 1.17.10 this registers correctly — `GET /config/providers` lists `aiur` with its `issue-<X>` models, and `Provider.getModel("aiur", "issue-<X>")` resolves (the resolution code is byte-identical to 1.15.6: it looks up `state.providers["aiur"].models["issue-<X>"]`). Operator messages route through the bridge and the panes paint — no `ProviderModelNotFoundError`.

Aiur identifies its own sessions via `model.providerID == "aiur"` (see `Aiur.Opencode.Protocol.aiur_owned?/1`).

## Migration behavior (forward upgrade + downgrade)

opencode 1.17.x tracks applied migrations in `__drizzle_migrations` plus a `data_migration` service, and supports `OPENCODE_SKIP_MIGRATIONS`. Verified on a sandboxed DB:
- **Forward upgrade** (1.15.6-created DB → 1.17.10 serve): clean, serves OK, prior sessions still readable (`GET /session/<id>` → 200).
- **Downgrade** (1.17.10-migrated DB → 1.15.6 / 1.16.0 / 1.17.0 serve): all served OK; the "table already exists" failure described in #364 did **not** reproduce on any tested pair.
