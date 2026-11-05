# Embedding the agent conversation

`packages/elixir/agent_conversation` is a standalone Phoenix-component package
that renders an agent conversation inside any web host. It depends on no Aiur
code, holds no credentials, and calls no service directly: the host passes in an
authenticated principal, the scope that principal may address, and a transport
module.

The dashboard's own `/conversations/:id` page renders through this package, so
the clean-vs-embedded boundary is one implementation instead of two.

## The host contract

A host supplies four things to `AgentConversation.Host.new/1`:

- `principal` — any value the host uses to identify the reader. The package never
  interprets it; it only carries it to the transport.
- `scope` — an `AgentConversation.Scope` naming the tickets, games and
  conversations this principal may address, plus the actions allowed on each.
- `transport` — a module implementing `AgentConversation.Host.Transport`.
- `features` — which surfaces to mount: `:send`, `:voice`, `:commands`, `:media`,
  `:minimap`, `:reveal`. Every surface defaults to off.

The transport implements reads, sends, Command answers and voice capabilities.
Each callback receives the host record and the conversation id, and is expected
to repeat its own authorization check: the package's scope is a client-side
guard, never the only one.

## Scope decides what is reachable

A conversation outside the host's scope is refused before any transport call.
`AgentConversation.Client.mount/3` returns `{:error, :out_of_scope}` for a
conversation that was never registered, and `:permission_denied` for one that was
registered without the action being asked for.

Read, send, voice and Command answering each check their own action, so a host
can follow a conversation it may not write to. Command answers go through the
transport's `answer_command/4`, which is how an embed keeps its existing
answering boundary instead of growing a second one.

## What renders

`AgentConversation.Components.conversation/1` renders the whole surface from an
`AgentConversation.Client`:

- activity and reply rows, with session dividers and truncation notices,
- a right-edge minimap of activity rows or the host's own jump anchors,
- inline images, animated images, video and audio, with a labelled fallback when
  an artifact is unsupported, sourceless or served from a host the embed refuses,
- pending Commands inline at their transcript position, or pinned above the
  transcript when the position is unknown,
- text composition plus one-way dictation and two-way voice through the host's
  own voice client, stating unavailable, permission-denied and reconnecting
  states. The client is wired in through `voice_capabilities/2`, so the component
  never learns a second voice protocol,
- loading, empty, unavailable and denied headers.

Hosts that already render inside LiveView can use the leaf components
(`entry/1`, `minimap/1`, `media/1`, `command_card/1`, `composer/1`, `status/1`)
and keep their own stream container.

## Keyboard, focus, motion and narrow screens

The transcript is a focusable region with `data-keyboard-nav="entries"`; entries
carry `tabindex="-1"` so a host can move focus to a position. Minimap ticks are
real buttons with an `aria-label` naming the position and its event.

A host passes `motion: :reduced` to stop animations and render an animated image
as a still link instead of a playing one. `viewport: :narrow` puts the layout in
one column with a horizontal minimap strip, and the default stylesheet also
switches at 700px.

## Mounting it

```elixir
{:ok, host} =
  AgentConversation.Host.new(
    principal: %{id: "player-1"},
    scope: scope,
    transport: MyApp.ConversationTransport,
    features: %{send: true, voice: :dictation, commands: true}
  )

{:ok, client} = AgentConversation.Client.mount(host, conversation_id)

html = AgentConversation.Components.render(%{client: client})
```

`Components.render/1` returns an HTML string for a Plug, controller or job. In a
LiveView, render `Components.conversation/1` with `client` as an assign and pass
`entry_content` when you want your own markdown and sanitizer.

`packages/elixir/agent_conversation/examples/standalone_host.exs` is a complete,
runnable host with an in-memory transport and no credentials:

```bash
cd packages/elixir/agent_conversation
mix run examples/standalone_host.exs
```

## Keeping the boundary honest

The package must not reference Aiur. `scripts/check-agent-conversation-isolation.sh`
fails on any `Aiur`/`AiurWeb` reference in the package, and the
`agent-conversation-standalone` CI job compiles and tests the package on its own.
Aiur's dashboard consumes it as a path dependency, so a change that would only
work inside the dashboard breaks that job first.
