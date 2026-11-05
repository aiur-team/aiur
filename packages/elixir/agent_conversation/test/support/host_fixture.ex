defmodule AgentConversation.HostFixture do
  @moduledoc """
  A tiny external host: a scope for one game, a fixture transport, and the two
  function components a real host supplies (entry body and Command actions).

  Tests use it to prove the component works with host markup it has never seen.
  """

  use Phoenix.Component

  alias AgentConversation.{Host, Scope}

  @doc """
  Builds a host whose scope covers one game (`"game-1"`).

  Options: `:features` (mounted surfaces), `:actions` (granted actions for the
  conversation), `:principal`.
  """
  @spec host(String.t(), keyword()) :: {:ok, Host.t()} | {:error, atom()}
  def host(conversation_id, opts \\ []) do
    actions = Keyword.get(opts, :actions, [:read, :send, :voice, :answer_command])
    features = Keyword.get(opts, :features, %{send: true, voice: :dictation, commands: true})

    with {:ok, scope} <- Scope.new(games: ["game-1"], actions: [:read]),
         {:ok, scope} <- Scope.grant(scope, conversation_id, game: "game-1", actions: actions) do
      Host.new(
        principal: Keyword.get(opts, :principal, %{id: "operator-1", name: "Operator"}),
        scope: scope,
        transport: AgentConversation.FixtureTransport,
        features: features,
        title: "Agent conversation"
      )
    end
  end

  @doc "A host entry renderer: proves the host, not the package, renders bodies."
  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(assigns) do
    ~H"""
    <div class="host-content" data-host-renderer="true" data-kind={@entry.kind}>
      <strong>{@entry.body}</strong>
    </div>
    """
  end

  @doc "A host Command action renderer: the canonical answering boundary stand-in."
  @spec actions(map()) :: Phoenix.LiveView.Rendered.t()
  def actions(assigns) do
    ~H"""
    <button type="button" class="host-answer" data-command-id={@row.id} disabled={!@answerable}>Answer</button>
    """
  end
end
