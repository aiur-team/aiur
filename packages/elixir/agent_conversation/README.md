# AgentConversation

An embeddable, permission-aware agent conversation for any web host.

The package renders a transcript and its surrounding controls without knowing
anything about the application it is mounted in. It depends on no host code,
holds no credentials, and reaches no service by itself: the host supplies an
authenticated principal, a scope, a transport module and the surfaces it wants.

`mise exec -- mix test` runs the package's own suite, including an external-host
example that mounts the component in a plain Plug with an in-memory transport.
CI job `agent-conversation-standalone` compiles and tests this package alone and
fails on any reference to the host application
(`scripts/check-agent-conversation-isolation.sh`).

## The host contract

A host supplies four things to `AgentConversation.Host.new/1`:

- `principal` — any value the host uses to identify the reader.
- `scope` — an `AgentConversation.Scope` naming the tickets, games and
  conversations this principal may address, and the actions allowed on each.
- `transport` — a module implementing `AgentConversation.Host.Transport`.
- `features` — `:send`, `:voice`, `:commands`, `:media`, `:minimap`, `:reveal`.
  Every surface defaults to off.

Every transport callback receives the host record and the conversation id, and
repeats its own authorization check. The package's scope is a client-side guard,
never the only one.

## Reading, sending and answering

`AgentConversation.Client` holds the view state. Mounting it reads the tail,
anchors, pending Commands and voice capabilities; `load_older/1` and
`load_newer/1` page history; `receive_live/2` merges the live tail and
`reconnect/1` reconciles a catch-up page against entries buffered while the
subscription was down, discarding everything at or below the reported head.

Reads, sends, voice requests and Command answers each check their own scope
action. A Command answer always goes through the transport's `answer_command/4`
so an embed keeps its existing answering boundary.

## What renders

`AgentConversation.Components.conversation/1` renders activity and reply rows,
session dividers, a right-edge minimap, inline images, animated images, video and
audio with labelled fallbacks, pending Commands inline or pinned, a composer with
one-way dictation and two-way voice, and the loading, empty, unavailable and
denied headers.

Hosts keep their own markup where it matters: `entry_content` renders an entry's
body and `command_actions` renders the answer controls, both as function
components the package calls with the assigns it would otherwise have to guess.

## Styling

`priv/static/agent_conversation.css` styles the components and may be served,
copied or replaced wholesale. It switches to one column with a horizontal
minimap strip at 700px, honours `motion: :reduced`, and keeps every control's
focus outline.

## Example

`examples/standalone_host.exs` mounts the whole component in a plain Plug route
with an in-memory transport and no service credentials:

```bash
mix run examples/standalone_host.exs
```
