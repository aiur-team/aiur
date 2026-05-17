defmodule SymphonyElixir.PaneManager do
  @moduledoc """
  Owns the mapping from `agent_identifier` to its tmux pane_id.

  UI concern only — `SymphonyElixir.Conversations.attach/1` is the
  data-side primitive. The pane manager consumes `Tmux.subscribe_events/0`
  and `:net_kernel.monitor_nodes/2` notifications, treating `:nodedown`
  as the authoritative pane-closed signal (per cited tmux issues #2483,
  #2882, where hooks fire inconsistently).

  Scaffold: implementation lands together with `Tmux`.
  """

  alias SymphonyElixir.AgentEvents

  @spec open_conversation(AgentEvents.agent_identifier()) :: {:ok, String.t()} | {:error, term()}
  def open_conversation(identifier) when is_binary(identifier), do: {:error, :not_implemented}

  @spec close_conversation(AgentEvents.agent_identifier()) :: :ok | {:error, term()}
  def close_conversation(identifier) when is_binary(identifier), do: {:error, :not_implemented}

  @spec list_open_panes() :: %{optional(AgentEvents.agent_identifier()) => String.t()}
  def list_open_panes, do: %{}
end
