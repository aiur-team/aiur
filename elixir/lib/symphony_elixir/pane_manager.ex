defmodule SymphonyElixir.PaneManager do
  @moduledoc """
  Owns the mapping from `agent_identifier` to its tmux pane id and
  drives the 5-slot conversation-pane cycle around the persistent
  agent-list pane.

  Layout (tickets 1-5 each open a fresh slot; tickets 6+ cycle):

      +----------+----------+----------+
      | agent    | slot 1   | slot 2   |
      | list     | (top mid)| (top R)  |
      +----------+----------+----------+
      | slot 3   | slot 4   | slot 5   |
      | (bot L)  | (bot mid)| (bot R)  |
      +----------+----------+----------+

  Each slot has a deterministic split recipe anchored to either the
  agent-list pane or a previously-created slot pane. When the cycle
  pointer lands on a slot whose pane is alive, the running command is
  replaced via `respawn-pane`; when the slot's pane is gone (closed,
  crashed, or never created), the slot is recreated via the split
  recipe, falling back to a broader anchor when the primary anchor
  pane is also missing.

  Consumes tmux notifications via `SymphonyElixir.Tmux.subscribe_events/1`
  and treats `%pane-died` (and, when distribution is in play, `:nodedown`)
  as authoritative pane-closed signals.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentEvents, AgentPubSub, Tmux}

  @type agent_id :: AgentEvents.agent_identifier()
  @type pane_id :: String.t()

  @num_slots 5

  defstruct identifier_to_pane: %{},
            pane_to_identifier: %{},
            pane_to_slot: %{},
            slot_panes: %{1 => nil, 2 => nil, 3 => nil, 4 => nil, 5 => nil},
            cycle_index: 0,
            agent_list_pane: nil,
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
    agent_list_pane = Keyword.get(opts, :agent_list_pane, System.get_env("TMUX_PANE"))

    case Tmux.subscribe_events(tmux) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("PaneManager: tmux subscribe failed: #{inspect(reason)}")
    end

    :net_kernel.monitor_nodes(true, node_type: :hidden)

    {:ok, %__MODULE__{tmux: tmux, agent_list_pane: agent_list_pane}}
  end

  @impl true
  def handle_call({:open, identifier, command_to_run}, _from, state) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, existing_pane} ->
        # Identifier already mapped to a live (cached) pane. Verify
        # the pane still exists; if it's been killed externally, fall
        # through to allocating a fresh slot.
        case Tmux.command(state.tmux, "select-pane -t #{existing_pane}") do
          {:ok, _} ->
            {:reply, {:ok, existing_pane}, state}

          {:error, _reason} ->
            do_open(forget_pane_by_identifier(state, existing_pane), identifier, command_to_run)
        end

      :error ->
        do_open(state, identifier, command_to_run)
    end
  end

  def handle_call({:close, identifier}, _from, state) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, pane_id} ->
        _ = Tmux.command(state.tmux, "kill-pane -t #{pane_id}")
        {:reply, :ok, forget_pane_by_identifier(state, pane_id)}

      :error ->
        {:reply, {:error, :not_open}, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, state.identifier_to_pane, state}

  @impl true
  def handle_info({:tmux_event, {:notification, :pane_died, pane_id}}, state) do
    {:noreply, handle_pane_closed(state, pane_id)}
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}
  def handle_info({:nodeup, _node, _info}, state), do: {:noreply, state}
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}
  def handle_info({:tmux_event, _event}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Slot allocation ----------------------------------------------------------

  defp do_open(state, identifier, command_to_run) do
    wrapped = wrap_with_unique_node(command_to_run, identifier)
    slot = state.cycle_index + 1

    case open_in_slot(state, slot, identifier, wrapped) do
      {:ok, pane_id, new_state} ->
        AgentPubSub.broadcast_status_change(identifier, :pane_opened)
        {:reply, {:ok, pane_id}, advance_cycle(new_state)}

      {:error, reason} ->
        Logger.warning("PaneManager.open identifier=#{identifier} slot=#{slot} failed: #{inspect(reason)}")

        {:reply, {:error, reason}, state}
    end
  end

  defp advance_cycle(%__MODULE__{} = state) do
    %{state | cycle_index: rem(state.cycle_index + 1, @num_slots)}
  end

  defp open_in_slot(state, slot, identifier, wrapped) do
    case Map.get(state.slot_panes, slot) do
      nil ->
        create_pane_for_slot(state, slot, identifier, wrapped)

      existing_pane ->
        replace_in_slot(state, slot, existing_pane, identifier, wrapped)
    end
  end

  defp replace_in_slot(state, slot, existing_pane, identifier, wrapped) do
    case Tmux.respawn_pane(state.tmux, existing_pane, wrapped) do
      :ok ->
        new_state =
          state
          |> forget_identifier_for_pane(existing_pane)
          |> record_slot_pane(slot, existing_pane, identifier)

        {:ok, existing_pane, new_state}

      {:error, _} ->
        # The cached pane id is stale (tmux killed it under us). Forget
        # the dead pane and create a fresh one in this slot.
        create_pane_for_slot(forget_dead_slot(state, slot), slot, identifier, wrapped)
    end
  end

  defp create_pane_for_slot(state, slot, identifier, wrapped) do
    case try_split_chain(state, slot_anchor_chain(slot), wrapped) do
      {:ok, pane_id} ->
        new_state = record_slot_pane(state, slot, pane_id, identifier)
        {:ok, pane_id, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_split_chain(_state, [], _wrapped), do: {:error, :no_live_anchor}

  defp try_split_chain(state, [{anchor, direction, percent} | rest], wrapped) do
    case anchor_pane_id(state, anchor) do
      nil ->
        try_split_chain(state, rest, wrapped)

      target_pane ->
        case Tmux.split_pane(state.tmux, target_pane, direction, percent, wrapped) do
          {:ok, new_id} -> {:ok, new_id}
          {:error, _} -> try_split_chain(state, rest, wrapped)
        end
    end
  end

  defp anchor_pane_id(state, :agent_list), do: state.agent_list_pane

  defp anchor_pane_id(state, slot) when slot in 1..@num_slots,
    do: Map.get(state.slot_panes, slot)

  # Recipe table: each slot's anchor chain. The first tuple is the
  # canonical position; subsequent tuples are fallbacks used when the
  # primary anchor pane is gone (closed by the user).
  defp slot_anchor_chain(1), do: [{:agent_list, :horizontal, 67}]
  defp slot_anchor_chain(2), do: [{1, :horizontal, 50}, {:agent_list, :horizontal, 67}]
  defp slot_anchor_chain(3), do: [{:agent_list, :vertical, 50}]
  defp slot_anchor_chain(4), do: [{1, :vertical, 50}, {:agent_list, :vertical, 50}]

  defp slot_anchor_chain(5),
    do: [{2, :vertical, 50}, {1, :vertical, 50}, {:agent_list, :vertical, 50}]

  # State bookkeeping --------------------------------------------------------

  defp record_slot_pane(%__MODULE__{} = state, slot, pane_id, identifier) do
    %{
      state
      | identifier_to_pane: Map.put(state.identifier_to_pane, identifier, pane_id),
        pane_to_identifier: Map.put(state.pane_to_identifier, pane_id, identifier),
        pane_to_slot: Map.put(state.pane_to_slot, pane_id, slot),
        slot_panes: Map.put(state.slot_panes, slot, pane_id)
    }
  end

  defp forget_identifier_for_pane(%__MODULE__{} = state, pane_id) do
    case Map.get(state.pane_to_identifier, pane_id) do
      nil ->
        state

      old_identifier ->
        %{state | identifier_to_pane: Map.delete(state.identifier_to_pane, old_identifier)}
    end
  end

  defp forget_pane_by_identifier(%__MODULE__{} = state, pane_id) do
    identifier = Map.get(state.pane_to_identifier, pane_id)
    slot = Map.get(state.pane_to_slot, pane_id)

    new_state = %{
      state
      | pane_to_identifier: Map.delete(state.pane_to_identifier, pane_id),
        pane_to_slot: Map.delete(state.pane_to_slot, pane_id)
    }

    new_state =
      if identifier do
        %{new_state | identifier_to_pane: Map.delete(new_state.identifier_to_pane, identifier)}
      else
        new_state
      end

    if slot do
      %{new_state | slot_panes: Map.put(new_state.slot_panes, slot, nil)}
    else
      new_state
    end
  end

  defp forget_dead_slot(%__MODULE__{} = state, slot) do
    case Map.get(state.slot_panes, slot) do
      nil -> state
      pane_id -> forget_pane_by_identifier(state, pane_id)
    end
  end

  defp handle_pane_closed(state, pane_id) do
    case Map.fetch(state.pane_to_identifier, pane_id) do
      {:ok, identifier} ->
        AgentPubSub.broadcast_status_change(identifier, :pane_closed)
        forget_pane_by_identifier(state, pane_id)

      :error ->
        # Unknown pane (could be the agent-list pane itself, or a
        # transient probe). Still clear any stale slot mapping.
        forget_pane_by_identifier(state, pane_id)
    end
  end

  # Distribution wrapping ----------------------------------------------------

  defp wrap_with_unique_node(command, identifier) do
    safe_id = String.replace(identifier, ~r/[^A-Za-z0-9_-]/, "-")
    suffix = Integer.to_string(System.unique_integer([:positive]), 36)
    node_long = "pane-#{safe_id}-#{suffix}@127.0.0.1"

    # The pane BEAM uses a LONG node name (`name@127.0.0.1`) to match the
    # parent symphony BEAM. Long names with an explicit IP sidestep
    # `/etc/hosts` weirdness (Debian-style boxes map the hostname to
    # 127.0.1.1 while we listen on 127.0.0.1, and the IP mismatch shows up
    # as a silent `Node.connect -> false`).
    #
    # tmux passes the resulting string to `/bin/sh -c`, so the value of
    # ERL_AFLAGS is parsed once by /bin/sh and then again by the BEAM's
    # argv splitter. Double quotes around the value let us embed
    # `{127,0,0,1}` without /bin/sh's single-quote rules tripping on it.
    cookie_flag =
      case read_erlang_cookie() do
        cookie when is_binary(cookie) and cookie != "" -> " -setcookie #{cookie}"
        _ -> ""
      end

    dist_flags = " -proto_dist inet_tcp -kernel inet_dist_use_interface {127,0,0,1}"

    "env ERL_AFLAGS=\"-name #{node_long}#{cookie_flag}#{dist_flags}\" #{command}"
  end

  defp read_erlang_cookie do
    case System.get_env("SYMPHONY_ERLANG_COOKIE") do
      env when is_binary(env) and env != "" ->
        String.trim(env)

      _ ->
        path = Path.join(System.user_home!(), ".erlang.cookie")

        case File.read(path) do
          {:ok, contents} -> String.trim(contents)
          {:error, _} -> nil
        end
    end
  rescue
    _ -> nil
  end
end
