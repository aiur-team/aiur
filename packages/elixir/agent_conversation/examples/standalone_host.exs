# An external host that mounts the agent conversation with nothing but its own
# auth, scope and transport. It talks to no Aiur service and needs no Aiur
# credentials: `ExampleTransport` is a plain in-memory map.
#
#   cd packages/elixir/agent_conversation
#   mix run examples/standalone_host.exs

defmodule StandaloneHost.Transport do
  @moduledoc "A host-side transport: whatever the host already uses for its own data."

  @behaviour AgentConversation.Host.Transport

  @entries [
    %{pos: 1, kind: "message", role: "agent", body: "I read the level file and found two unreachable platforms."},
    %{
      pos: 2,
      kind: "tool_result",
      role: "tool",
      body: "levels/cave.json",
      output: "unreachable: 2",
      meta: %{"tool" => "lint"}
    },
    %{pos: 3, kind: "message", role: "agent", body: "Shall I move the second platform up by two tiles?"}
  ]

  @media [
    %{kind: "image", name: "level-preview.png", url: "https://assets.example/level-preview.png"}
  ]

  @impl true
  def read_entries(_host, "game-cave", opts) do
    entries =
      case opts[:before] do
        nil -> @entries
        _pos -> @entries
      end

    {:ok,
     %{
       entries: entries,
       head_pos: 3,
       prev_cursor: 1,
       next_cursor: 3,
       complete_from_start: true,
       sessions: [],
       observed_at: DateTime.utc_now()
     }}
  end

  def read_entries(_host, _other, _opts), do: {:error, :not_found}

  @impl true
  def read_anchors(_host, "game-cave", _opts),
    do: {:ok, [%{pos: 3, kind: "command_requested", label: "Command requested"}]}

  def read_anchors(_host, _other, _opts), do: {:ok, []}

  @impl true
  def read_commands(_host, "game-cave") do
    {:ok, [%{id: "cmd-1", question: "Move the platform?", pos: 3, position: 3}]}
  end

  def read_commands(_host, _other), do: {:ok, []}

  @impl true
  def send_text(_host, "game-cave", text), do: {:ok, %{text: text, delivered: true}}
  def send_text(_host, _other, _text), do: {:error, :permission_denied}

  @impl true
  def answer_command(_host, "game-cave", command_id, action), do: {:ok, %{command_id: command_id, action: action}}
  def answer_command(_host, _other, _command_id, _action), do: {:error, :permission_denied}

  @impl true
  def voice_capabilities(_host, "game-cave"), do: {:ok, %{dictation: true, two_way: false}}
  def voice_capabilities(_host, _other), do: {:error, :unavailable}

  @doc "An attachment a host attaches to the last entry."
  def media, do: @media
end

defmodule StandaloneHost.Router do
  @moduledoc "The host's own route. The component is rendered into a plain Plug response."
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/games/:game_id/conversations/:id" do
    with {:ok, host} <- host(game_id, id),
         {:ok, client} <- AgentConversation.Client.mount(host, id) do
      html = AgentConversation.Components.render(%{client: client, commands_href: nil, retry_attrs: %{}})

      send_resp(conn, 200, html)
    else
      {:error, reason} -> send_resp(conn, 403, "denied: #{reason}")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # The allowed games come from the authenticated principal, never from the URL.
  @allowed_games ["game-1"]

  defp host(game_id, id) do
    with true <- game_id in @allowed_games,
         {:ok, scope} <- AgentConversation.Scope.new(games: @allowed_games, actions: [:read]),
         {:ok, scope} <-
           AgentConversation.Scope.grant(scope, id, game: game_id, actions: [:read, :send, :voice, :answer_command]) do
      AgentConversation.Host.new(
        principal: %{id: "player-1", name: "Player one"},
        scope: scope,
        transport: StandaloneHost.Transport,
        features: %{send: true, voice: :dictation, commands: true},
        title: "Cave level"
      )
    else
      false -> {:error, :out_of_scope}
      error -> error
    end
  end
end

conn = Plug.Test.conn(:get, "/games/game-1/conversations/game-cave") |> StandaloneHost.Router.call([])
html = conn.resp_body

IO.puts("status: #{conn.status}")

for marker <- [
      "data-conversation-id=\"game-cave\"",
      "conversation-entry",
      "conversation-minimap",
      "conversation-command-card",
      "conversation-composer"
    ] do
  IO.puts("contains #{marker}: #{String.contains?(html, marker)}")
end

denied = Plug.Test.conn(:get, "/games/other-game/conversations/game-cave") |> StandaloneHost.Router.call([])
IO.puts("cross-scope status: #{denied.status} (#{denied.resp_body})")
