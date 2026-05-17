defmodule SymphonyElixir.PaneManager do
  @moduledoc """
  Owns the mapping from `agent_identifier` to its tmux pane id.

  UI concern only. The data-side primitive for subscribing to an agent's
  events is `SymphonyElixir.Conversations.attach/1`. This GenServer
  coordinates the *visual* side: which tmux pane is currently showing a
  given agent's conversation.

  Consumes tmux notifications via `SymphonyElixir.Tmux.subscribe_events/1`
  and treats `%pane-died` (and, when distribution is in play, `:nodedown`)
  as authoritative pane-closed signals.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentEvents, AgentPubSub, Tmux}

  @type agent_id :: AgentEvents.agent_agent_id()
  @type pane_id :: String.t()

  defstruct identifier_to_pane: %{},
            pane_to_identifier: %{},
            tmux: nil

  # Public API ----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec open_conversation(GenServer.server(), agent_id(), String.t()) ::
          {:ok, pane_id()} | {:error, term()}
  def open_conversation(server \\ __MODULE__, identifier, command_to_run)
      when is_binary(identifier) and is_binary(command_to_run) do
    GenServer.call(server, {:open, identifier, command_to_run})
  end

  @spec close_conversation(GenServer.server(), agent_id()) :: :ok | {:error, term()}
  def close_conversation(server \\ __MODULE__, identifier) when is_binary(identifier) do
    GenServer.call(server, {:close, identifier})
  end

  @spec list_open_panes(GenServer.server()) :: %{optional(agent_id()) => pane_id()}
  def list_open_panes(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  # GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    tmux = Keyword.get(opts, :tmux, Tmux)

    case Tmux.subscribe_events(tmux) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("PaneManager: tmux subscribe failed: #{inspect(reason)}")
    end

    :net_kernel.monitor_nodes(true, node_type: :hidden)

    {:ok, %__MODULE__{tmux: tmux}}
  end

  @impl true
  def handle_call({:open, identifier, command_to_run}, _from, state) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, existing_pane} ->
        # The cache can hold a stale pane id if the user closed the pane via
        # Ctrl+C (which kills the pane outside of our control). Verify the
        # pane still exists before short-circuiting; if not, fall through to
        # a fresh split-window.
        case Tmux.command(state.tmux, "select-pane -t #{existing_pane}") do
          {:ok, _} ->
            Logger.debug("PaneManager.open identifier=#{identifier} re-focused existing pane=#{existing_pane}")

            {:reply, {:ok, existing_pane}, state}

          {:error, _reason} ->
            Logger.debug("PaneManager.open identifier=#{identifier} cached pane=#{existing_pane} is dead; respawning")

            do_open(forget_pane_by_identifier(state, identifier), identifier, command_to_run)
        end

      :error ->
        do_open(state, identifier, command_to_run)
    end
  end

  def handle_call({:close, identifier}, _from, state) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, pane_id} ->
        _ = Tmux.command(state.tmux, "kill-pane -t #{pane_id}")
        {:reply, :ok, forget_pane_by_identifier(state, identifier)}

      :error ->
        {:reply, {:error, :not_open}, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, state.identifier_to_pane, state}

  defp do_open(state, identifier, command_to_run) do
    wrapped_command = wrap_with_unique_node(command_to_run, identifier)

    Logger.debug("PaneManager.open identifier=#{identifier} command=#{inspect(wrapped_command)}")

    case Tmux.spawn_pane_for(state.tmux, identifier, wrapped_command) do
      {:ok, pane_id} ->
        new_state = record_pane(state, identifier, pane_id)
        AgentPubSub.broadcast_status_change(identifier, :pane_opened)
        Logger.debug("PaneManager.open identifier=#{identifier} -> pane_id=#{pane_id}")
        {:reply, {:ok, pane_id}, new_state}

      {:error, reason} ->
        Logger.warning("PaneManager.open identifier=#{identifier} failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:tmux_event, {:notification, :pane_died, pane_id}}, state) do
    {:noreply, handle_pane_closed(state, pane_id)}
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}
  def handle_info({:nodeup, _node, _info}, state), do: {:noreply, state}
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}
  def handle_info({:tmux_event, _event}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Internals -----------------------------------------------------------------

  defp wrap_with_unique_node(command, identifier) do
    safe_id = String.replace(identifier, ~r/[^A-Za-z0-9_-]/, "-")
    suffix = Integer.to_string(System.unique_integer([:positive]), 36)
    node_short = "pane-#{safe_id}-#{suffix}"

    # tmux passes the resulting string to `/bin/sh -c`, so single-quoting the
    # ERL_AFLAGS value is enough to keep `-sname <node>` together when env
    # parses it. ERL_AFLAGS overrides the parent BEAM's `-sname` so the pane
    # BEAM gets a unique node name and does not collide with the orchestrator.
    #
    # Cookie: the parent BEAM has `-setcookie <value>` baked into its own
    # ERL_AFLAGS (set by `scripts/agents`). When we replace ERL_AFLAGS for
    # the pane, we must re-inject the cookie or the pane's distributed
    # connection back to symphony fails silently with `Node.connect -> false`.
    cookie_flag =
      case read_erlang_cookie() do
        cookie when is_binary(cookie) and cookie != "" -> " -setcookie #{cookie}"
        _ -> ""
      end

    "env ERL_AFLAGS='-sname #{node_short}#{cookie_flag}' #{command}"
  end

  defp read_erlang_cookie do
    path = Path.join(System.user_home!(), ".erlang.cookie")

    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  defp record_pane(%__MODULE__{} = state, identifier, pane_id) do
    %{
      state
      | identifier_to_pane: Map.put(state.identifier_to_pane, identifier, pane_id),
        pane_to_identifier: Map.put(state.pane_to_identifier, pane_id, identifier)
    }
  end

  defp forget_pane_by_identifier(%__MODULE__{} = state, identifier) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, pane_id} ->
        %{
          state
          | identifier_to_pane: Map.delete(state.identifier_to_pane, identifier),
            pane_to_identifier: Map.delete(state.pane_to_identifier, pane_id)
        }

      :error ->
        state
    end
  end

  defp handle_pane_closed(state, pane_id) do
    case Map.fetch(state.pane_to_identifier, pane_id) do
      {:ok, identifier} ->
        AgentPubSub.broadcast_status_change(identifier, :pane_closed)
        forget_pane_by_identifier(state, identifier)

      :error ->
        state
    end
  end
end
