defmodule AgentConversation do
  @moduledoc """
  An embeddable agent conversation for any web host.

  The package renders a transcript and its surrounding controls without knowing
  anything about the application it is mounted in. A host supplies three things:

    1. a `AgentConversation.Host` - the authenticated principal, the
       `AgentConversation.Scope` of tickets, games and conversations that
       principal may address, and a transport module,
    2. `AgentConversation.Host.Transport` callbacks for history pages, live
       subscriptions, sends, voice capabilities and Command answers,
    3. optional function components for rendering an entry's body and a
       Command's answer controls, so the host keeps its own markup, sanitizer and
       answering boundary.

  `AgentConversation.Client` holds the state. `AgentConversation.Components`
  renders it. `examples/standalone_host.exs` mounts the whole thing in a plain
  Plug with an in-memory transport and no service credentials at all.
  """

  @version Mix.Project.config()[:version]

  @doc "The package version."
  @spec version() :: String.t()
  def version, do: @version
end
