defmodule SymphonyElixir.Tmux do
  @moduledoc """
  tmux control-mode client.

  Owns a long-lived `tmux -CC attach` port. Parses the `%begin`/`%end`,
  `%output`, `%pane-died`, `%window-pane-changed`, and `%client-detached`
  notification stream into Erlang messages so other GenServers can subscribe.

  Scaffold: this module exists so callers can compile against the public API
  (`command/1`, `subscribe_events/0`, `spawn_pane_for/1`). Implementation
  lands in the dedicated tmux session of this plan; see brainstorm Phase 1
  task list for ordering.
  """

  alias SymphonyElixir.AgentEvents

  @typedoc "Notification messages emitted to subscribers."
  @type event ::
          {:tmux, %{type: :pane_died, pane_id: String.t()}}
          | {:tmux, %{type: :window_pane_changed, window_id: String.t(), pane_id: String.t()}}
          | {:tmux, %{type: :client_detached}}

  @typedoc "Command response from the tmux control socket."
  @type command_response :: {:ok, String.t()} | {:error, term()}

  @spec command(String.t()) :: command_response()
  def command(_argv_string), do: {:error, :not_implemented}

  @spec subscribe_events() :: :ok | {:error, term()}
  def subscribe_events, do: {:error, :not_implemented}

  @spec spawn_pane_for(AgentEvents.agent_identifier()) :: {:ok, String.t()} | {:error, term()}
  def spawn_pane_for(identifier) when is_binary(identifier), do: {:error, :not_implemented}
end
