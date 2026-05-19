# opencode Pane Brainstorm

Issue: https://github.com/its-everdred/aiur/issues/60

## Goal

Explore whether Aiur should replace its in-process conversation pane with an
opencode-driven pane session while retaining Aiur's automated refresh loop,
agent turns, alerts, events, and core orchestration behavior.

This is research only. It does not commit to an implementation.

## Current Aiur Pane Responsibilities

The current pane combines three responsibilities:

- Terminal chat UX: `lib/aiur_pane/conversation.ex`,
  `lib/aiur_pane/viewport.ex`, and `lib/aiur_pane/composer.ex`.
- Aiur event projection: `system`, `agent`, `user`, `cmd`, and `alert`
  semantics from `lib/aiur/agent_events.ex`.
- Message forwarding: pane input calls `Aiur.PaneRPC.send_operator_message/2`,
  which forwards operator text through `AgentChat.send/3`.

The important product behavior is semantic continuity, not exact visual parity.
The current right-aligned user text and custom tag layout are implementation
details that can give way to opencode defaults if the same information remains
available.

## opencode Findings

opencode's terminal UI is already a full chat surface for coding work. It
supports prompt input, file references, shell-command messages, slash commands,
session switching, undo/redo, export, model selection, themes, keybinds, and
attention notifications. Source: https://opencode.ai/docs/tui

opencode starts a server behind the TUI. The TUI is a client that talks to that
server, and the server exposes OpenAPI 3.1. This matters because Aiur may be
able to integrate with opencode without scraping terminal output. Source:
https://opencode.ai/docs/server/

The server exposes session and message APIs, including session creation, message
listing, synchronous message sending, asynchronous prompt sending, slash-command
execution, shell execution, TUI prompt append/submit/toast endpoints, and an SSE
event stream. Source: https://opencode.ai/docs/server/

The CLI supports non-interactive runs, JSON event output for `opencode run`,
headless `opencode serve`, attaching to a running server, session continuation,
session listing, export, and import. Source: https://open-code.ai/en/docs/cli

opencode plugins can subscribe to events including message updates, session
status, permission prompts, tool execution, shell environment, and TUI events.
Plugins can also add custom tools. Source: https://opencode.ai/docs/plugins/

opencode supports project-local custom tools in `.opencode/tools/`, and those
tools can be implemented in any language behind a JavaScript/TypeScript wrapper.
This is a plausible way for the opencode agent to call Aiur-specific operations.
Source: https://opencode.ai/docs/custom-tools

opencode supports local and remote MCP servers. MCP tools become available to
the LLM alongside built-in tools, and MCPs can be enabled globally or per agent.
This is a plausible lower-coupling way to expose Aiur event and coordination
tools to opencode. Source: https://opencode.ai/docs/mcp-servers

opencode supports many providers and custom provider configuration. This could
collapse much of issue 33's "choose Claude Code or Codex" surface into
opencode provider/model configuration instead of Aiur owning per-CLI adapters.
Source: https://opencode.ai/docs/providers

## Working Thesis

Aiur should not try to make opencode look like Aiur's current chat pane.
Instead:

- opencode owns the interactive chat UX.
- Aiur owns issue identity, agent lifecycle, background automation, alerts,
  refresh loop, logs, and coordination semantics.
- Aiur injects context and events into opencode through server APIs, plugins,
  MCP/custom tools, or session prompt mechanics.
- Aiur observes opencode through server events, plugins, exports, session APIs,
  or explicit handoff tools.

## Candidate Directions

### 1. opencode TUI plus Aiur sidecar bridge

Aiur opens opencode in the tmux pane with a known server port or session. A
separate Aiur-owned process uses opencode's HTTP and SSE APIs to inject initial
context, surface events, observe status, and map opencode session activity back
into Aiur logs.

Best when Aiur wants maximum opencode-default UX and minimal opencode-specific
code in the repo.

Risk: live event injection may feel intrusive unless carefully scoped.

### 2. opencode project plugin owns Aiur integration

Aiur provides a project plugin under `.opencode/plugins/` or generates
equivalent config. The plugin listens to opencode session, message, tool, and
permission events, then calls back into Aiur. It can also expose custom tools to
the model.

Best when Aiur wants durable event capture and opencode-native behavior.

Risk: introduces a JavaScript/Bun plugin surface into an Elixir project and
couples Aiur to opencode plugin hook stability.

### 3. Aiur exposes MCP/custom tools; opencode pulls events

Aiur exposes tools such as `aiur_get_context`, `aiur_check_events`,
`aiur_send_status`, and `aiur_handoff_back` through MCP or opencode custom
tools. opencode remains mostly default, and the agent is instructed to use those
tools.

Best when Aiur wants model-visible coordination and low live-injection
complexity.

Risk: event continuity depends on the agent following instructions unless
paired with sidecar observation or plugin hooks.

### 4. opencode replaces both pane and background agent runtime

Aiur schedules opencode sessions instead of only using opencode for foreground
pane chat.

Best when the long-term goal is one agent runtime.

Risk: much larger scope and likely inappropriate for a first milestone because
it threatens the current working background-agent model.

## Recommended First Shape

Start with direction 1 plus a small slice of direction 3:

- opencode TUI runs in the pane.
- Aiur sidecar bridge handles initial context, lifecycle state, and observation.
- Aiur exposes explicit context/event tools via MCP or opencode custom tools so
  event checking is durable and model-visible.
- Defer full plugin ownership until server APIs prove insufficient.

This keeps the first milestone anchored on the product question: can opencode
replace Aiur's custom chat surface without losing the important Aiur workflow
semantics?

## Feature And Scope Questions

- When the operator opens a pane, is this a takeover of a running background
  agent or an attached chat surface alongside the background agent?
- Should opening the opencode pane automatically pause the background worker,
  or should the user explicitly choose pause/takeover?
- Is opencode the only supported interactive pane surface for v1, or should the
  design preserve future Claude Code and Codex native pane adapters?
- Do we require live event injection into the visible opencode chat, or is an
  event tool/inbox plus visible toast/status enough?
- Which current tags are semantic requirements versus UI requirements:
  `system`, `agent`, `user`, `cmd`, `alert`?
- Should Aiur display historical background-agent transcript inside opencode, or
  only provide a summarized handoff prompt plus links/log access?
- Should user messages in opencode go to opencode's model only, the background
  agent only, or both depending on worker state?
- What should happen when there is no running agent for the selected issue:
  open opencode anyway with issue context, or show no-agent status and block
  chat?
- What is the minimum acceptable reverse handoff: session export, opencode
  summary, diff summary, explicit user command, or automatic on pane close?
- Should Aiur preserve per-issue `logs/agent.md` and `logs/agent.ndjson` as the
  canonical transcript, or should opencode session export become canonical?
- Should alerts interrupt the opencode user, appear as toasts, be appended into
  the chat, or only land in an event inbox?
- Does opencode get Aiur coordination through MCP/custom tools, server prompt
  injection, plugin hooks, or a file-based inbox?
- Should opencode provider/model selection be entirely opencode-native, or
  constrained by Aiur workflow config?
- How much does v1 care about offline/local model support?
- Is the next deliverable a working end-to-end pane spike, or a requirements doc
  that picks opencode versus issue 33?

## First Decision To Resolve

When an operator opens an issue pane in the opencode design, the primary mode
should be one of:

- Takeover: pause or hand off the background agent and let opencode own the work.
- Attach: keep the background agent running and use opencode as an
  observer/chat/control surface.
- Choose each time: pane opening offers attach versus takeover.

This decision drives the rest of the scope: message routing, event delivery,
background-agent state, no-agent behavior, and reverse handoff requirements.
