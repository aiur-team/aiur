# opencode Pane Brainstorm

Issue: https://github.com/its-everdred/aiur/issues/60
Status: research only. No implementation commitment.
Last expanded: 2026-05-19

## Goal

Decide whether and how Aiur should replace its in-process conversation pane with
an opencode-driven pane while keeping Aiur's identity: issue lifecycle,
background agent automation, alerts, refresh loop, logs, and orchestration
semantics.

Before we can pick approaches, we need a foundational mental model of how
opencode actually works as a system. The bulk of this document is that model.
The candidate directions and recommendation come after.

## Current Aiur Pane Responsibilities

The pane today combines three responsibilities, and we should be deliberate
about which of them opencode takes over and which Aiur keeps.

- Terminal chat UX — `lib/aiur_pane/conversation.ex`, `lib/aiur_pane/viewport.ex`,
  `lib/aiur_pane/composer.ex`.
- Aiur event projection — `system`, `agent`, `user`, `cmd`, `alert` semantics
  driven by `lib/aiur/agent_events.ex` and the pane PubSub stream.
- Message routing — pane input flows through `Aiur.PaneRPC.send_operator_message/2`
  to `AgentChat.send/3`, into the running background agent.

The product behavior we must preserve is **semantic continuity** (the operator
can still read agent activity, send guidance, and receive alerts). The current
right-aligned user text and Aiur-specific tag layout are not load-bearing.

## opencode Foundational Architecture

This section is the foundation we kept fuzzy in the first pass. Everything
downstream depends on it.

### Process model

opencode is a **client/server system, not a single binary**.

- The server is a TypeScript service (Bun runtime, Hono HTTP framework). It
  owns all chat state, persistence, provider calls, tool execution, plugins,
  MCP, the bus, and the SSE event stream.
- The TUI is also TypeScript (Bun). It is **purely a client** that talks to a
  server over HTTP and SSE. It holds no authoritative state.
- `opencode` (no subcommand) starts a paired server+TUI in one process tree.
- `opencode serve` starts the server only.
- `opencode attach <url>` starts a TUI that connects to an existing server.
- `opencode run …` is a one-shot CLI that uses the server programmatically.

This is the critical fact: **anything the TUI can do, an HTTP client can do**,
and **anything that happens in opencode is visible on the bus / SSE stream**.
Aiur does not have to scrape terminal output to integrate; the integration
surface is the server.

### Server endpoints worth pinning down

Verified from `https://opencode.ai/docs/server/`:

- Lifecycle: `GET /global/health`, `GET /global/event` (SSE; first event is
  `server.connected`).
- Sessions: `GET/POST /session`, `GET/PATCH/DELETE /session/:id`,
  `POST /session/:id/abort`.
- Messages: `GET/POST /session/:id/message` (POST is synchronous send),
  `POST /session/:id/prompt_async` (async, 204), `POST /session/:id/shell`.
- TUI control (the most interesting endpoints for Aiur):
  - `POST /tui/append-prompt` — append text to the visible prompt buffer.
  - `POST /tui/submit-prompt` — submit the current prompt.
  - `POST /tui/show-toast` — display a toast in the TUI (`title`, `message`,
    `variant`).
  - `GET /tui/control/next`, `POST /tui/control/response` — control-channel for
    out-of-band TUI questions.
- Filesystem: `GET /find?pattern=…`, `GET /find/file?query=…`,
  `GET /find/symbol?query=…`, `GET /file/content?path=…`, `GET /file/status`.
- Config/providers: `GET/PATCH /config`, `GET /provider`,
  `POST /provider/{id}/oauth/authorize`.
- Discovery: `GET /command`, `GET /agent`.
- Logging/bus: `POST /log`, `GET /event` (SSE bus stream).
- OpenAPI 3.1 spec: `GET /doc`.

Auth: optional HTTP basic via `OPENCODE_SERVER_PASSWORD`.

### Port and discovery

- Default port `4096`, hostname `127.0.0.1`. Configurable with `--port` and
  `--hostname`.
- With `--port 0`, opencode prefers `4096` first then any free port.
- mDNS auto-discovery with `--mdns` / `--mdns-domain` (defaults to
  `opencode.local`).
- For Aiur: the cleanest pattern is **Aiur picks the port** and spawns
  `opencode serve --port <chosen> --hostname 127.0.0.1`, then puts
  `opencode attach http://127.0.0.1:<chosen>` in the tmux pane. Aiur never
  has to parse stdout to discover the port.

### Storage

- SQLite database at `~/.local/share/opencode/opencode.db` holds sessions,
  messages, parts, projects, permissions (Drizzle ORM, `TxReentrantLock` for
  concurrency).
- File storage under `~/.local/share/opencode/storage/` holds diffs and large
  tool outputs (older JSON layout: `session/{projectHash}/{sessionID}.json`,
  `message/{sessionID}/msg_{messageID}.json`).
- Concurrency-locked; treat as **opaque to Aiur**. All Aiur reads/writes go
  through the HTTP API, not the disk.

### Message and part model

Messages are not flat strings. Each message has typed parts:

- text parts (assistant or user text)
- tool-call parts (model invoking a tool)
- tool-result parts (the result that came back)
- attachments

This matters for Aiur: when Aiur tails the SSE stream, it receives granular
`message.part.updated` and `message.part.removed` events, not just whole
messages. Tool activity is observable as it happens.

### Bus and SSE events

The SSE stream surfaces the same events that plugins can hook. The shapes Aiur
should care about:

- Session lifecycle: `session.created`, `session.updated`, `session.idle`,
  `session.status`, `session.error`, `session.diff`, `session.compacted`,
  `session.deleted`.
- Messages: `message.updated`, `message.removed`, `message.part.updated`,
  `message.part.removed`.
- Tools: `tool.execute.before`, `tool.execute.after`.
- Permissions: `permission.asked`, `permission.replied`.
- Filesystem: `file.edited`, `file.watcher.updated`.
- TUI: `tui.prompt.append`, `tui.command.execute`, `tui.toast.show`.
- Misc: `command.executed`, `lsp.client.diagnostics`, `lsp.updated`,
  `shell.env`, `todo.updated`, `server.connected`.

A long-lived consumer of `GET /event` from Aiur is sufficient to mirror almost
everything that's happening inside opencode. This is the primary integration
surface, not file tailing or pane scraping.

### Configuration stack

opencode merges 8 config layers (project `opencode.json`, `~/.config/opencode/`,
remote `.well-known/opencode`, env-injected inline config, etc.). Project
config wins over global, and a few options can be **patched at runtime via
`PATCH /config`**. For Aiur's purposes, the layers we'd write into a workspace
are:

- `opencode.json` — model, providers, default agent, MCP entries, plugin list,
  permission rules, instructions globs.
- `.opencode/agents/<name>.md` — markdown agents with YAML frontmatter
  (`description`, `mode: primary|subagent`, `model`, `temperature`,
  `permission`) and a system-prompt body.
- `.opencode/commands/<name>.md` — slash commands. Frontmatter supports
  `template`, `description`, `agent`, `model`, `subtask`. Body supports
  positional args (`$1`, `$ARGUMENTS`), shell injection (`` !`cmd` ``), and
  file injection (`@path/to/file`).
- `.opencode/plugins/*.ts` — Bun-runtime plugins.
- `.opencode/tools/*.ts` — custom tools, can shell to any language.
- `AGENTS.md` — implicit project system context (also reads legacy
  `CLAUDE.md`).

### Permissions

Three states per tool: `allow`, `ask`, `deny`. Glob-pattern subkeys for `bash`
(`"git *": "allow"`, `"rm *": "deny"`). Permissions are configurable globally
and **overridable per agent**. For Aiur this means we can:

- pre-allow the work the agent will routinely do (edit, git commands, test
  runners) so the operator does not see a permission prompt avalanche,
- still see `permission.asked` events on the bus when something escapes that
  envelope.

### Agent concept (important — don't confuse "opencode agent" with "Aiur agent")

In opencode, an **agent** is a reusable persona (system prompt + permission
profile + model). The runtime instance is a **session**. Multiple agents can
exist; you Tab between primary agents and `@mention` subagents. Built-ins:
`build` (full tools), `plan` (read-only), plus subagents `general`, `explore`,
`scout`.

This terminology will collide with Aiur's "agent" (which is closer to an
opencode session bound to an issue). The brainstorm/spec needs a chosen
vocabulary. Suggestion: keep saying "Aiur agent" for the issue-bound worker,
and use "opencode session" and "opencode persona" for the opencode-side
concepts.

### Plugins, MCP, and custom tools — when to use which

Three extension points, decreasing in coupling cost:

1. **Plugin** (`@opencode-ai/plugin`, TS/JS, Bun runtime) — highest leverage.
   Subscribes to any bus event, registers custom tools, can shell out, has
   access to a project context and SDK client. Right tool when we need
   bidirectional behavior (react to events **and** add tools).
2. **MCP server** — local stdio or remote HTTP. Tools become available with
   `servername_toolname` prefix; per-agent enablement supported. Right tool
   when Aiur wants to expose a *toolset* without owning lifecycle inside
   opencode's process.
3. **Custom tool** (`.opencode/tools/*.ts`) — a tool definition wrapped in TS,
   can shell to any language. Right tool for one-off helpers that the model
   should call.

A plugin and an MCP server can both be Aiur-owned processes outside opencode;
the difference is whether opencode runs it (plugin) or whether opencode talks
to it (MCP). For Aiur, **an Aiur-hosted MCP server is the lowest-coupling
high-power option**: opencode just configures it, and Aiur owns the lifecycle
in BEAM.

### Things that are still open / unverified

- Exact wire format of message parts (have schema names from the API but not
  field-by-field shape). Will need to read `GET /doc` from a running instance.
- Whether `tui.show-toast` blocks or just decorates. Likely non-blocking.
- Whether `permission.asked` over the HTTP API gives an external client a way
  to respond (plugins can; the HTTP-side answer path is less obvious than the
  TUI's). The `/tui/control/next` + `/tui/control/response` endpoints suggest
  yes, but worth confirming against the live OpenAPI.
- How `opencode serve` handles concurrent sessions in one server (one server
  hosts many sessions, so per-issue isolation is a session, not a server,
  decision).
- Plugin hot-reload behavior and what happens to in-flight sessions when the
  plugin throws.

## Working Thesis (revised after 2026-05-19 clarification)

There is exactly **one agent per issue**: the Codex or Claude background agent
that the existing workflow file already configures. Aiur's current
`Aiur.AgentRunner` / `AgentChat` infrastructure for setting up, refreshing,
pausing, resuming, and handling turns of that agent **stays exactly as it is**.

This brainstorm is therefore not about introducing an opencode AI session. It
is about **swapping the chat *interface* under our existing agent**. The
operator should not be able to tell, by interacting with the pane, that
"opencode" is a thing — they just see a nicer chat UI sitting in front of the
same background worker.

Implications:

- **opencode owns the interactive chat UX** in the pane (TUI, scrollback,
  prompts, slash commands, attention notifications, undo/redo, themes).
- **Aiur still owns the agent**. The agent's transcript is canonical. Operator
  text typed in opencode is delivered to the Aiur background agent via
  `AgentChat.send/3` (or equivalent). Agent activity is delivered into the
  opencode chat as it happens.
- **opencode's own model loop must not run** for the chat in the pane.
  Whatever provider/configuration opencode uses for this session must not
  cause opencode to call an LLM in response to operator messages — that is
  the Aiur agent's job.
- **History is live, not snapshotted on open**: if the agent has been running
  for a minute before the operator attaches, the past minute of agent output
  is already visible in the opencode session when the pane appears. This
  means Aiur is feeding the session continuously, not lazily on attach.
- The bridge is the opencode **server API** plus opencode config files Aiur
  writes into the workspace. No pane scraping, no file tailing.

The non-trivial design problem is therefore: **how do we use opencode as a
display layer for an external agent runtime while preventing opencode's
built-in AI loop from competing for the same conversation?**

## Integration Mechanism Choices

opencode's design assumes it is the AI client. We need to bend it into a
display layer for an external agent. Four mechanisms span the design space.
Any chosen direction is some combination of "how does Aiur push activity in"
and "how does Aiur catch operator messages on the way out."

### A. Aiur is opencode's "provider" (LLM relay)

opencode supports custom providers via the Vercel AI SDK
(`@ai-sdk/openai-compatible`, Ollama, LM Studio, etc.). Aiur exposes a small
OpenAI-compatible HTTP endpoint (`POST /v1/chat/completions` with SSE
streaming) that opencode is configured to use as a provider. opencode
"calls the model" on submit; Aiur receives that call, forwards the operator's
prompt to the running background agent via `AgentChat.send/3`, and streams
the agent's output back in OpenAI chat-completion chunks.

- Push (Aiur → opencode) — agent activity that is *in response to operator
  text* rides on the model-response stream and appears in the natural
  position. Free-running agent activity (the operator-not-there case) is
  pushed in via `POST /session/:id/message` so it appears as new assistant
  parts on the session.
- Pull (opencode → Aiur) — operator submit *is* a model call. The shim is
  the routing event. No SSE-watching needed for this path.

Provider scope (verified): providers are configured at workspace level in
`opencode.json`. There is no per-session provider override, but the workspace
can declare multiple providers and the **default model** for new sessions is
the one Aiur pins. Sessions Aiur creates use that default; the operator could
in principle switch via `/models`, which we'd want to disable or document
away.

- Pro: matches opencode's expectations. Operator UX feels native — prompt →
  streaming response. No abort-jank.
- Con: requires an OpenAI-compatible HTTP shim in Elixir (small but real
  work). Need to map background-agent turn semantics into a single
  chat-completion response, including handling the case where the agent has
  already been producing output when the operator types.
- Footgun: operator switching the model via TUI breaks the relay assumption.
  Mitigate by configuring only Aiur's provider in the workspace, or by
  documenting that `/models` is not supported in pane sessions.

### B. Plugin neutralizes opencode's model, Aiur drives via HTTP

A generated `.opencode/plugins/aiur.ts` plugin hooks bus events and either
suppresses the model call or returns a stub response. Operator messages are
caught in the plugin and re-routed to Aiur over local HTTP.

**Verdict: not viable standalone (as of 2026-05-19).** Per opencode docs and
community discussion, current plugin hooks are observation-oriented; there
is no documented way to prevent or replace a model invocation from a
`BeforeInvocationEvent`-style hook. A plugin can react after the fact, but
can't intercept the chat loop. We could still use a plugin for *decoration*
on top of another mechanism (see D).

### C. opencode as dumb display; Aiur drives everything via server API

Aiur creates the session, posts every background-agent event as a message,
shows toasts for alerts. Operator submit is handled by **one of two
sub-mechanisms**:

- **C1 — abort-on-submit**: Aiur watches the SSE bus for the operator's
  submit, immediately calls `POST /session/:id/abort`, reads the operator
  text from the just-posted user message, and forwards it to the background
  agent. opencode shows a brief "interrupted" state per submit. Janky.
- **C2 — null provider**: Aiur exposes a no-op OpenAI-compatible endpoint
  configured as opencode's provider. It returns an empty stream immediately
  on every model call so opencode finalizes the assistant turn with nothing
  in it. Aiur then posts the real agent reply as a follow-on assistant
  message. Cleaner than C1 but the empty assistant turn is still visible
  unless we strip it via a plugin.

- Pro: no provider shim with real semantics (the shim, if any, is trivial);
  most BEAM-side; works regardless of `--model` selection.
- Con: visible UX jank on every operator turn. The chat scrollback contains
  artifacts (empty assistant messages or "interrupted" markers) that don't
  match how the rest of opencode looks.

### D. A + decorative plugin (recommended hybrid if A's shim is acceptable)

Use Mechanism A for the chat loop. Add a thin `.opencode/plugins/aiur.ts`
that:

- watches `tool.execute.before/after` and decorates tool activity as Aiur-
  style `cmd` parts in the visible chat;
- watches `session.idle` / `session.error` and forwards them as Aiur alerts;
- registers nothing model-facing.

This keeps the plugin role to *presentation*, where the hook API is
expressive enough. The chat loop stays in A.

These options determine what the chat looks like, what infrastructure Aiur
needs, and how much TS code we ship.

## Concrete Integration Sketch (mechanism-agnostic)

These steps are the same regardless of A/B/C/D; only the "submit" and "free-
running activity" mechanics differ.

### Per-workspace bootstrap

When Aiur opens a workspace for an issue (or refreshes one):

1. Write `AGENTS.md`, `opencode.json`, and `.opencode/` config (provider,
   permissions, persona — exact shape depends on chosen mechanism).
2. Pick a port (record in workspace state).
3. Spawn `opencode serve --port <port> --hostname 127.0.0.1` via the
   workspace's supervisor.
4. Wait for `GET /global/health` to return ready.
5. Open a long-lived `GET /event` SSE consumer in BEAM; project bus events
   into Aiur PubSub, logs, and alerts.

### Per-issue session — created at agent start, not at pane open

1. `POST /session` with a title derived from the issue.
2. Store the opencode session ID on the Aiur issue record so subsequent pane
   opens can deterministically attach to the right session.
3. As the Aiur agent runs, push each Aiur agent event into the session as it
   happens: `POST /session/:id/message` (or whatever shape the chosen
   mechanism uses). System/agent/user/cmd/alert tags map to opencode message
   parts.

### When operator opens the pane

1. Aiur's pane spawner runs
   `opencode attach http://127.0.0.1:<port> --session <session-id>` inside
   the tmux pane.
2. opencode loads the session from the server; the operator sees the full
   history that Aiur has been streaming in since agent start.

### When operator submits a message

Mechanism-dependent. In Mechanism A the provider call is the routing event;
Aiur forwards to `AgentChat.send/3` and streams the agent's response back as
a provider response.

### When the Aiur agent produces output while the operator is watching

Aiur posts new message parts via `POST /session/:id/message` (or, in
Mechanism A, returns them as streaming "model" output if the operator just
submitted; otherwise pushes as out-of-band parts). opencode renders them.

### When Aiur needs to alert the operator

`POST /tui/show-toast` from Aiur. Optionally `POST /tui/append-prompt` to
pre-fill an operator prompt with relevant context.

### When the operator closes the pane

The opencode session is kept alive on the server so that re-opening the pane
shows the same continuous history. The Aiur agent never noticed the pane
existed.

## Open Foundational Questions

Resolved as of 2026-05-19:

- **Per-session provider?** No. Provider config is workspace-level in
  `opencode.json`. Workspaces can declare multiple providers; only the
  default-model setting determines what new sessions use. (Verified.)
- **Can a plugin suppress a model call?** No (per current docs and community
  discussion). Plugins react to events but cannot cancel a model invocation
  from a `BeforeInvocationEvent`-style hook. (Verified — kills Mechanism B
  as a standalone path.)
- **Custom provider wire format**: opencode uses `@ai-sdk/openai-compatible`,
  hitting `/v1/chat/completions` with the standard OpenAI streaming shape.
  Aiur's shim would expose that.

Still open — worth probing during a spike:

- Exact opencode message-part schema (full field set, streaming chunk shape)
  from `GET /doc` on a real instance.
- Whether `permission.asked` is responsable over HTTP (TUI control endpoints
  hint yes) or only by the TUI itself.
- Server-per-workspace resource cost when running many workspaces (does Aiur
  need to share a server across workspaces? Probably not, but worth
  measuring).
- Session compaction behavior on long-lived Aiur-driven sessions — can we
  disable it for these sessions, or do we need to handle compaction events
  by re-posting context?
- Whether `/models` (the operator switching model mid-session) needs to be
  hidden in pane sessions, or whether opencode supports per-session
  model lock.
- How well opencode's "model call" abstraction tolerates very long
  responses (a background-agent turn can be minutes long) — does the
  Vercel AI SDK timeout, or stream indefinitely?

## Feature and Scope Questions (still open)

- Is opencode the only supported interactive pane surface for v1, or do we
  preserve native Claude Code / Codex pane adapters as a future option?
- Which Aiur tags map to which opencode message parts: `system`, `agent`,
  `user`, `cmd`, `alert`? Direct part-type mapping vs prefixed text vs
  Markdown blocks?
- Should Aiur preserve per-issue `logs/agent.md` and `logs/agent.ndjson` as
  the canonical transcript? (Yes — opencode storage is opaque and not
  intended to replace Aiur logs.)
- Should alerts interrupt the operator (toast), be appended into the chat,
  or only land in an event inbox? Hybrid is most likely.
- What happens when the operator opens the pane for an issue with **no
  running agent yet** (queued)? Show empty opencode session + status, or
  block pane open?
- Should the opencode session show Aiur-side metadata like work-state emoji
  in the title? (Today: pane viewport shows the work-state emoji from
  `Aiur.AgentEvents.state_emoji/1`.)
- Do we need a "send shell command without going through the agent" feature
  that today does not really exist?
- How much does v1 care about retaining all of today's pane keybinds (esc to
  cancel, `q` to quit aiur from pane) vs adopting opencode defaults?
- Is the next deliverable a working end-to-end pane spike, or a requirements
  doc that picks opencode vs issue 33?

## Decisions (in order resolved)

### 2026-05-19: Single agent, opencode is a chat-UI swap only

There is no second AI. The Codex/Claude CLI configured by the workflow
remains the only agent. Aiur's existing `AgentRunner`/`AgentChat`/Orchestrator
infrastructure for setting up, refreshing, pausing, resuming, and handling
turns is preserved as-is. opencode replaces only `lib/aiur_pane/*` and
related rendering code.

### 2026-05-19: Server lifetime — lazy spawn, kill on close

opencode servers are not running by default. The first time the operator
opens the pane for an issue, Aiur spawns `opencode serve` for that
workspace, creates a fresh session, backfills the existing agent transcript
into it, then spawns `opencode attach` in the tmux pane. When the operator
closes the pane, Aiur kills the server and discards the session. Every
reopen is a cold start (transcript replayed from `logs/agent.ndjson`).

Implication: `logs/agent.ndjson` is the canonical transcript; opencode
storage is throwaway. The shim and the (separate) live-event push only need
to operate while the pane is open.

### 2026-05-19: Mechanism D — Aiur-as-provider + decorative plugin

Aiur ships:

- a small OpenAI-compatible HTTP shim in Elixir (`POST /v1/chat/completions`
  with SSE streaming) that opencode is configured to use as the provider for
  pane sessions. operator submit → shim hands the text to `AgentChat.send/2`
  → background agent reply streams back as an OpenAI chat-completion stream;
- a thin `.opencode/plugins/aiur.ts` plugin for in-chat decoration (e.g.,
  forwarding opencode bus events as Aiur alerts, ensuring custom parts render
  the way Aiur expects).

Free-running background-agent activity (when the operator is not actively
chatting) is pushed into the opencode session via
`POST /session/:id/message` so the chat shows continuous activity.

The Aiur shim and plugin live alongside the existing BEAM code; the
JSON-RPC port to Codex/Claude is unchanged.

### 2026-05-19: Backfill is event-by-event from `logs/agent.ndjson`

On every cold open Aiur walks the issue's transcript and posts each event as
the right opencode message/part:

| Aiur tag  | opencode rendering                                     |
| --------- | ------------------------------------------------------ |
| `user`    | user message, text part                                |
| `agent`   | assistant message, text part                           |
| `cmd`     | assistant message with native tool-call + tool-result parts (so it renders the same as opencode's own bash tool activity) |
| `system`  | (deferred — likely styled assistant text part)         |
| `alert`   | assistant text part with alert styling (see next)      |

The backfill is best-effort fidelity — chat should look the way a live
session would look if the operator had been watching from the start.

### 2026-05-19: Alerts surface both ways

Live alerts both fire `POST /tui/show-toast` AND post a styled chat entry
via `POST /session/:id/message`. On cold reopen, past alerts replay as chat
entries only (no toast — they already happened). The shim/plugin split
handles this: chat-entry path goes through the BEAM HTTP push, toast path
is the decorative plugin (or a direct HTTP call from Aiur, equivalently).

### 2026-05-19: Pane open for queued (not-yet-running) issue auto-starts on first submit

The pane is openable even when the issue is queued and has no port to route
to. opencode shows the issue context with empty transcript. If the operator
types and submits, Aiur uses that as the trigger to start the agent
(subject to existing slot rules) and treats the typed text as the first
operator message once the port is up. If no slot is available, the shim
returns a clear error that shows in the chat. This collapses "open pane"
and "press space to start" into one gesture.
