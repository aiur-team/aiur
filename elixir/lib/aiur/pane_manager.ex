defmodule Aiur.PaneManager do
  @moduledoc """
  Owns the mapping from `agent_identifier` to its tmux pane id and drives
  the conversation-pane grid around the persistent agent-list pane.

  ## Layout model

  Every open / respawn / close routes through `Aiur.PaneManager.Layout`,
  which produces an explicit `tmux select-layout <string>` for the
  current window dimensions and slot occupancy. This sidesteps tmux's
  default auto-layout behaviour (and any `after-split-window` hooks) so
  the operator sees a deterministic grid regardless of which pane tmux
  happened to split from.

  With `max_vertical_panes: 3`, the fully-populated grid is:

      +----------+----------+----------+
      | agent    | slot 1   | slot 2   |
      | list     |          |          |
      +----------+----------+----------+
      | slot 3   | slot 4   | slot 5   |
      +----------+----------+----------+

  Empty slots collapse: row siblings expand evenly to fill the freed
  width. An entirely empty bottom row makes the top row span full height.

  ## Slot cycling

  `cycle_index` advances by 1 after every successful open. When the
  pointer lands on a slot whose pane is alive, the running command is
  replaced via `respawn-pane` and the pane id is preserved. When the
  pointer lands on an empty slot, a fresh pane is created via
  `split-window` (anchored to the agent-list pane — position is set by
  the layout string we apply right after).

  ## Anchor pane

  `agent_list_pane` is resolved at init time from
  `Aiur.Tmux.resolve_self_pane/1` (which validates `$TMUX_PANE` against
  the tmux server). If resolution fails, `init/1` refuses to start with
  `{:stop, :no_agent_list_pane}` rather than silently falling through to
  a broken anchor — that silent fallback was the root cause of the
  regression issue #34 tracks.

  Consumes tmux notifications via `Aiur.Tmux.subscribe_events/1` and
  treats `%pane-died` (and, when distribution is in play, `:nodedown`)
  as authoritative pane-closed signals.
  """

  use GenServer
  require Logger

  alias Aiur.{AgentEvents, AgentPubSub, Tmux}
  alias Aiur.PaneManager.Layout

  @type agent_id :: AgentEvents.agent_identifier()
  @type pane_id :: String.t()

  defstruct identifier_to_pane: %{},
            pane_to_identifier: %{},
            pane_to_slot: %{},
            slot_panes: %{},
            cycle_index: 0,
            max_vertical_panes: 3,
            slot_count: 5,
            agent_list_pane: nil,
            window_target: nil,
            orientation: :horizontal,
            tmux: nil

  @type orientation :: :horizontal | :vertical

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

  @spec orientation(GenServer.server()) :: orientation()
  def orientation(server \\ __MODULE__) do
    GenServer.call(server, :orientation)
  end

  @doc """
  Flip the grid between `:horizontal` (default — anchor sits in the top
  row) and `:vertical` (anchor sits at the top of the left column, slots
  stack downward, then continue in a second column). Re-applies the
  layout immediately so the operator sees the rotated grid without
  waiting for the next open/close.
  """
  @spec toggle_orientation(GenServer.server()) :: {:ok, orientation()}
  def toggle_orientation(server \\ __MODULE__) do
    GenServer.call(server, :toggle_orientation)
  end

  # GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    tmux = Keyword.get(opts, :tmux, Tmux)
    max_vertical_panes = Keyword.get(opts, :max_vertical_panes, Aiur.Config.max_vertical_panes())
    slot_count = slot_count(max_vertical_panes)
    orientation = Keyword.get(opts, :orientation, :horizontal)

    with {:ok, agent_list_pane} <- resolve_agent_list_pane(opts, tmux),
         {:ok, window_target} <- resolve_window_target(opts, tmux, agent_list_pane) do
      Logger.info(
        "PaneManager init agent_list_pane=#{agent_list_pane} window=#{window_target} " <>
          "max_vertical_panes=#{max_vertical_panes} slot_count=#{slot_count} " <>
          "orientation=#{orientation}"
      )

      case Tmux.subscribe_events(tmux) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("PaneManager: tmux subscribe failed: #{inspect(reason)}")
      end

      :net_kernel.monitor_nodes(true, node_type: :hidden)

      {:ok,
       %__MODULE__{
         tmux: tmux,
         agent_list_pane: agent_list_pane,
         window_target: window_target,
         max_vertical_panes: max_vertical_panes,
         slot_count: slot_count,
         slot_panes: empty_slot_panes(slot_count),
         orientation: orientation
       }}
    else
      {:error, reason} ->
        Logger.warning(
          "PaneManager: cannot resolve agent-list pane (#{inspect(reason)}). " <>
            "Aiur must run inside a tmux pane started by scripts/aiur. Refusing to start."
        )

        {:stop, :no_agent_list_pane}
    end
  end

  @impl true
  def handle_call({:open, identifier, command_to_run}, _from, state) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, existing_pane} ->
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
        Logger.info("[user-action] close_conversation identifier=#{identifier} pane_id=#{pane_id}")
        _ = Tmux.command(state.tmux, "kill-pane -t #{pane_id}")
        new_state = forget_pane_by_identifier(state, pane_id)
        _ = apply_layout(new_state)
        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_open}, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, state.identifier_to_pane, state}

  def handle_call(:orientation, _from, state), do: {:reply, state.orientation, state}

  def handle_call(:toggle_orientation, _from, state) do
    new_orientation =
      case state.orientation do
        :horizontal -> :vertical
        :vertical -> :horizontal
      end

    Logger.info("[user-action] toggle_orientation #{state.orientation} -> #{new_orientation}")
    new_state = %{state | orientation: new_orientation}
    _ = apply_layout(new_state)
    {:reply, {:ok, new_orientation}, new_state}
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

  # Anchor / window discovery ------------------------------------------------

  defp resolve_agent_list_pane(opts, tmux) do
    cond do
      pane = Keyword.get(opts, :agent_list_pane) ->
        {:ok, pane}

      pane = env_pane() ->
        {:ok, pane}

      true ->
        Tmux.resolve_self_pane(tmux)
    end
  end

  defp env_pane do
    case System.get_env("TMUX_PANE") do
      pane when is_binary(pane) and pane != "" -> pane
      _ -> nil
    end
  end

  defp resolve_window_target(opts, tmux, agent_list_pane) do
    case Keyword.get(opts, :window_target) do
      target when is_binary(target) and target != "" -> {:ok, target}
      _ -> Tmux.window_for(tmux, agent_list_pane)
    end
  end

  # Slot allocation ----------------------------------------------------------

  defp do_open(state, identifier, command_to_run) do
    wrapped = command_for_pane(command_to_run, identifier)
    slot = state.cycle_index + 1

    case open_in_slot(state, slot, identifier, wrapped) do
      {:ok, pane_id, new_state} ->
        AgentPubSub.broadcast_status_change(identifier, :pane_opened)
        _ = apply_layout(new_state)
        {:reply, {:ok, pane_id}, advance_cycle(new_state)}

      {:error, reason} ->
        Logger.warning("PaneManager.open identifier=#{identifier} slot=#{slot} failed: #{inspect(reason)}")

        {:reply, {:error, reason}, state}
    end
  end

  defp command_for_pane("__aiur_opencode__ " <> _rest, identifier) do
    workspace = Path.join(Aiur.Config.workspace_root(), Aiur.Opencode.Config.safe_identifier(identifier))

    case Aiur.Opencode.PaneSession.start(identifier, workspace) do
      {:ok, %{attach_command: command}} -> command
      {:error, reason} -> "printf %s #{Aiur.Opencode.Protocol.shell_escape("opencode pane failed: #{inspect(reason)}")}; sleep 15"
    end
  end

  defp command_for_pane(command_to_run, identifier) do
    wrap_with_unique_node(command_to_run, identifier)
  end

  defp advance_cycle(%__MODULE__{} = state) do
    %{state | cycle_index: rem(state.cycle_index + 1, state.slot_count)}
  end

  defp open_in_slot(state, slot, identifier, wrapped) do
    Logger.info(
      "PaneManager opening identifier=#{identifier} into slot=#{slot} " <>
        "agent_list_pane=#{state.agent_list_pane}"
    )

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
        # Cached pane id is stale (tmux killed it under us). Forget it
        # and create a fresh pane in this slot.
        create_pane_for_slot(forget_dead_slot(state, slot), slot, identifier, wrapped)
    end
  end

  defp create_pane_for_slot(state, slot, identifier, wrapped) do
    # Split anchor is always the agent-list pane. Position is irrelevant
    # — the layout string applied after the open will reposition every
    # pane in the window. Direction and percent are arbitrary defaults.
    case Tmux.split_pane(state.tmux, state.agent_list_pane, :horizontal, 50, wrapped) do
      {:ok, pane_id} ->
        new_state = record_slot_pane(state, slot, pane_id, identifier)
        {:ok, pane_id, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Layout application -------------------------------------------------------

  defp apply_layout(state) do
    with {:ok, {w, h}} <- Tmux.window_size(state.tmux, state.agent_list_pane),
         layout_string =
           Layout.build(
             w,
             h,
             state.max_vertical_panes,
             state.agent_list_pane,
             slot_panes_list(state),
             state.orientation
           ),
         :ok <- Tmux.select_layout(state.tmux, state.window_target, layout_string) do
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("PaneManager: layout apply failed: #{inspect(reason)}")
        err
    end
  end

  defp slot_panes_list(%__MODULE__{} = state) do
    for slot <- 1..state.slot_count, do: Map.get(state.slot_panes, slot)
  end

  defp slot_count(max_vertical_panes), do: max_vertical_panes * 2 - 1

  defp empty_slot_panes(slot_count) do
    Map.new(1..slot_count, fn slot -> {slot, nil} end)
  end

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
        new_state = forget_pane_by_identifier(state, pane_id)
        _ = apply_layout(new_state)
        new_state

      :error ->
        # Unknown pane (could be the agent-list pane itself, or a
        # transient probe). Still clear any stale slot mapping.
        new_state = forget_pane_by_identifier(state, pane_id)
        _ = apply_layout(new_state)
        new_state
    end
  end

  # Distribution wrapping ----------------------------------------------------

  defp wrap_with_unique_node(command, identifier) do
    safe_id = String.replace(identifier, ~r/[^A-Za-z0-9_-]/, "-")
    suffix = Integer.to_string(System.unique_integer([:positive]), 36)
    node_long = "pane-#{safe_id}-#{suffix}@127.0.0.1"

    # The pane BEAM uses a LONG node name (`name@127.0.0.1`) to match the
    # parent aiur BEAM. Long names with an explicit IP sidestep
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
    case System.get_env("AIUR_ERLANG_COOKIE") do
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
