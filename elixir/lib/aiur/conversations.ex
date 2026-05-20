defmodule Aiur.Conversations do
  @moduledoc """
  Agent-native facade for opening and closing conversation surfaces.

  The CLI's `AgentList.App` calls `open/2` on Enter so that any future
  external consumer (MCP bridge, in-process automation agent) drives
  conversations through the same chokepoint:

  * `open/2`   — subscribe to the agent's event stream AND open a tmux
                 conversation pane in one step.
  * `close/1`  — kill the tmux pane AND unsubscribe.
  * `attach/1` — subscribe only (no pane). Useful for consumers that
                 want events without a TTY surface.
  * `detach/1` — unsubscribe only.

  This symmetric pair fixes the older `attach` / `detach`-only API,
  which leaked tmux panes if the consumer relied on `detach` for full
  cleanup.
  """

  alias Aiur.{AgentEvents, AgentPubSub, PaneManager}

  @type subscription_ref :: %{
          required(:identifier) => AgentEvents.agent_identifier(),
          required(:pid) => pid(),
          optional(:pane_id) => String.t()
        }

  @doc """
  Subscribe the calling process to the agent's PubSub topic.
  """
  @spec attach(AgentEvents.agent_identifier()) :: {:ok, subscription_ref()} | {:error, term()}
  def attach(identifier) when is_binary(identifier) do
    case AgentPubSub.subscribe_agent(identifier) do
      :ok -> {:ok, %{identifier: identifier, pid: self()}}
      error -> error
    end
  end

  @doc """
  Unsubscribe the caller from the agent's PubSub topic. Use `close/1`
  instead when the consumer also owns a tmux pane.
  """
  @spec detach(subscription_ref()) :: :ok
  def detach(%{identifier: identifier}) when is_binary(identifier) do
    Phoenix.PubSub.unsubscribe(Aiur.PubSub, AgentEvents.agent_topic(identifier))
  end

  @doc """
  Subscribe and open a tmux conversation pane in one call. Returns a
  subscription ref carrying the spawned `:pane_id` so callers can
  later pass it to `close/1`.
  """
  @spec open(AgentEvents.agent_identifier(), keyword()) ::
          {:ok, subscription_ref()} | {:error, term()}
  def open(identifier, opts \\ []) when is_binary(identifier) do
    pane_manager = Keyword.get(opts, :pane_manager, PaneManager)
    command = Keyword.get(opts, :command, default_command(identifier))

    with {:ok, ref} <- attach(identifier),
         {:ok, pane_id} <- PaneManager.open_conversation(pane_manager, identifier, command) do
      {:ok, Map.put(ref, :pane_id, pane_id)}
    end
  end

  @doc """
  Close the tmux pane (if any) AND unsubscribe. Accepts either the
  `subscription_ref` returned by `open/2` or a bare identifier (in
  which case the unsubscribe is best-effort for the caller's pid).
  """
  @spec close(subscription_ref() | AgentEvents.agent_identifier()) :: :ok
  def close(ref_or_identifier), do: close(ref_or_identifier, [])

  @spec close(subscription_ref() | AgentEvents.agent_identifier(), keyword()) :: :ok
  def close(%{identifier: identifier} = ref, opts) when is_binary(identifier) do
    pane_manager = Keyword.get(opts, :pane_manager, PaneManager)
    _ = PaneManager.close_conversation(pane_manager, identifier)
    detach(ref)
  end

  def close(identifier, opts) when is_binary(identifier) do
    close(%{identifier: identifier, pid: self()}, opts)
  end

  defp default_command(identifier) do
    "__aiur_opencode__ #{identifier}"
  end
end
