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

  alias Aiur.{AgentEvents, AgentPubSub, Boot, Tmux}
  alias Aiur.Opencode.{AttachQueue, HiddenWindow, PersistentPane, SessionWriterRegistry}
  alias Aiur.PaneManager.Layout

  @type agent_id :: AgentEvents.agent_identifier()
  @type pane_id :: String.t()

  # Hard cap on how long the visible-open path will park while waiting
  # for AttachQueue's :pane_priority_attached event. Beyond this the
  # parked call is replied with {:error, :open_priority_timeout} so the
  # AgentList GenServer can keep handling keypresses.
  @open_priority_timeout_ms 7_000

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
            tmux: nil,
            # identifier => GenServer.from() — opencode opens parked while
            # AttachQueue finishes a background attach. Replied on the
            # `:pane_priority_attached` PubSub event from the queue.
            pending_opens: %{},
            attach_topic_subscribed?: false

  @type orientation :: :horizontal | :vertical

  # Public API ----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec open_conversation(GenServer.server(), agent_id(), String.t(), keyword()) ::
          {:ok, pane_id()} | {:error, term()}
  def open_conversation(server \\ __MODULE__, identifier, command_to_run, opts \\ [])
      when is_binary(identifier) and is_binary(command_to_run) and is_list(opts) do
    GenServer.call(server, {:open, identifier, command_to_run, opts})
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
  def handle_call({:open, identifier, command_to_run, opts}, from, state) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, existing_pane} ->
        case Tmux.command(state.tmux, "select-pane -t #{existing_pane}") do
          {:ok, _} ->
            Logger.info(
              "aiur_pane_manager phase=open_already_visible elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} pane_id=#{existing_pane}"
            )

            {:reply, {:ok, existing_pane}, state}

          {:error, _reason} ->
            do_open(forget_pane_by_identifier(state, existing_pane), identifier, command_to_run, opts, from)
        end

      :error ->
        do_open(state, identifier, command_to_run, opts, from)
    end
  end

  def handle_call({:close, identifier}, _from, state) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, pane_id} ->
        Logger.info(
          "[user-action] close_conversation identifier=#{identifier} pane_id=#{pane_id}"
        )

        close_opencode_or_generic(state, identifier, pane_id)

      :error ->
        # Visible state has no record. If the identifier is mid-attach in
        # AttachQueue, treat close as cancel — the resulting pane will land
        # in :hidden and won't be promoted to visible.
        case SessionWriterRegistry.get_pane(identifier) do
          {:ok, %{status: status}} when status in [:attaching, :pending] ->
            Logger.info(
              "aiur_pane_manager phase=close_cancel elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} status=#{status}"
            )

            :ok = AttachQueue.cancel(identifier)
            {:reply, :ok, state}

          _ ->
            {:reply, {:error, :not_open}, state}
        end
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

  def handle_info({:pane_priority_attached, identifier}, state) do
    case Map.pop(state.pending_opens, identifier) do
      {nil, _} ->
        {:noreply, state}

      {{from, timer_ref}, pending_opens} ->
        _ = Process.cancel_timer(timer_ref)
        new_state = %{state | pending_opens: pending_opens}

        case SessionWriterRegistry.get_pane(identifier) do
          {:ok, %PersistentPane{pane_id: pane_id}} when is_binary(pane_id) ->
            case promote_hidden_to_visible(new_state, identifier, pane_id, nil) do
              {:noreply, promoted_state} ->
                GenServer.reply(from, {:ok, pane_id})
                {:noreply, promoted_state}

              {:reply, reply, promoted_state} ->
                GenServer.reply(from, reply)
                {:noreply, promoted_state}
            end

          _ ->
            GenServer.reply(from, {:error, :pane_not_ready})
            {:noreply, new_state}
        end
    end
  end

  def handle_info({:pane_attached, _identifier}, state) do
    {:noreply, state}
  end

  def handle_info({:pane_attach_failed, identifier, reason}, state) do
    case Map.pop(state.pending_opens, identifier) do
      {nil, _} ->
        Logger.warning(
          "aiur_pane_manager phase=open_attach_failed identifier=#{identifier} reason=#{inspect(reason)}"
        )

        {:noreply, state}

      {{from, timer_ref}, pending_opens} ->
        _ = Process.cancel_timer(timer_ref)
        GenServer.reply(from, {:error, reason})
        {:noreply, %{state | pending_opens: pending_opens}}
    end
  end

  def handle_info({:open_priority_timeout, identifier}, state) do
    case Map.pop(state.pending_opens, identifier) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer_ref}, pending_opens} ->
        Logger.warning(
          "aiur_pane_manager phase=open_priority_timeout elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} timeout_ms=#{@open_priority_timeout_ms}"
        )

        GenServer.reply(from, {:error, :open_priority_timeout})
        {:noreply, %{state | pending_opens: pending_opens}}
    end
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

  defp do_open(state, identifier, command_to_run, opts, from) do
    case command_to_run do
      "__aiur_opencode__ " <> _ -> open_opencode_pane(state, identifier, opts, from)
      _ -> open_generic_pane(state, identifier, command_to_run, from)
    end
  end

  defp close_opencode_or_generic(state, identifier, pane_id) do
    case SessionWriterRegistry.get_pane(identifier) do
      {:ok, %{pane_id: ^pane_id}} ->
        # opencode pane — hide, don't destroy.
        hidden_window = HiddenWindow.window_name()

        case Tmux.move_pane_hidden(state.tmux, pane_id, hidden_window) do
          :ok ->
            _ =
              SessionWriterRegistry.update_pane(identifier, fn pane ->
                PersistentPane.with_status(pane, :hidden)
              end)

            new_state = forget_pane_by_identifier(state, pane_id)
            _ = apply_layout(new_state)

            Logger.info(
              "aiur_pane_manager phase=close_hide elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} pane_id=#{pane_id}"
            )

            {:reply, :ok, new_state}

          {:error, reason} ->
            Logger.warning(
              "aiur_pane_manager phase=close_hide_failed identifier=#{identifier} pane_id=#{pane_id} reason=#{inspect(reason)}"
            )

            # Fall back to kill so the user's close intent isn't silently lost.
            _ = Tmux.command(state.tmux, "kill-pane -t #{pane_id}")
            new_state = forget_pane_by_identifier(state, pane_id)
            _ = apply_layout(new_state)
            {:reply, :ok, new_state}
        end

      _ ->
        # Generic (non-opencode) pane — original kill behavior.
        _ = Tmux.command(state.tmux, "kill-pane -t #{pane_id}")
        new_state = forget_pane_by_identifier(state, pane_id)
        _ = apply_layout(new_state)
        {:reply, :ok, new_state}
    end
  end

  # Non-opencode commands (rare today; mostly the bare `echo ...` test paths)
  # still go through the classic "split + wrap with unique BEAM node" flow.
  defp open_generic_pane(state, identifier, command_to_run, _from) do
    wrapped = wrap_with_unique_node(command_to_run, identifier)
    slot = state.cycle_index + 1

    case open_in_slot(state, slot, identifier, wrapped) do
      {:ok, pane_id, new_state} ->
        AgentPubSub.broadcast_status_change(identifier, :pane_opened)
        _ = apply_layout(new_state)
        {:reply, {:ok, pane_id}, advance_cycle(new_state)}

      {:error, reason} ->
        Logger.warning(
          "PaneManager.open identifier=#{identifier} slot=#{slot} failed: #{inspect(reason)}"
        )

        {:reply, {:error, reason}, state}
    end
  end

  # opencode panes use the persistent pane model: AttachQueue keeps every
  # agent's opencode-attach process alive in the hidden warm window;
  # opening a pane is a `tmux move-pane` from hidden to visible, closing
  # is the inverse. If the agent's pane isn't attached yet, we ask the
  # queue to prioritize this identifier and park the open call until the
  # `:pane_priority_attached` PubSub event arrives.
  defp open_opencode_pane(state, identifier, _opts, from) do
    workspace = opencode_workspace_for(identifier)
    _ = File.mkdir_p(workspace)

    case SessionWriterRegistry.get_pane(identifier) do
      {:ok, %PersistentPane{status: :hidden, pane_id: pane_id}}
      when is_binary(pane_id) ->
        promote_hidden_to_visible(state, identifier, pane_id, from)

      {:ok, %PersistentPane{status: :visible, pane_id: pane_id}}
      when is_binary(pane_id) ->
        Logger.info(
          "aiur_pane_manager phase=open_already_visible_registry elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} pane_id=#{pane_id}"
        )

        {:reply, {:ok, pane_id}, state}

      _ ->
        # No persistent-pane ready. Two scenarios:
        #   (a) Background attach hasn't created this agent's pane yet.
        #   (b) Warm subsystem isn't running at all.
        # Either way, fall back to cold attach IMMEDIATELY so the user
        # is never blocked waiting for an async background step. Tell
        # AttachQueue about the user-priority intent so it skips this
        # identifier on the next background round (we already have a
        # visible pane after cold_attach finishes).
        _ = AttachQueue.cancel(identifier)

        Logger.info(
          "aiur_pane_manager phase=open_cold_fallback elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier}"
        )

        cold_attach(state, identifier, workspace, from)
    end
  end

  defp promote_hidden_to_visible(state, identifier, pane_id, from) do
    slot = state.cycle_index + 1
    started_at = System.monotonic_time(:millisecond)

    case Tmux.move_pane_visible(state.tmux, pane_id, state.window_target) do
      :ok ->
        _ =
          SessionWriterRegistry.update_pane(identifier, fn pane ->
            PersistentPane.with_status(pane, :visible)
          end)

        new_state = record_slot_pane(state, slot, pane_id, identifier)
        _ = apply_layout(new_state)
        AgentPubSub.broadcast_status_change(identifier, :pane_opened)

        Logger.info(
          "aiur_pane_manager phase=open_hidden_promoted elapsed_ms=#{Boot.elapsed_ms()} open_ms=#{System.monotonic_time(:millisecond) - started_at} identifier=#{identifier} pane_id=#{pane_id}"
        )

        case from do
          nil -> {:noreply, advance_cycle(new_state)}
          _ -> {:reply, {:ok, pane_id}, advance_cycle(new_state)}
        end

      {:error, reason} ->
        Logger.warning(
          "aiur_pane_manager phase=open_hidden_promote_failed identifier=#{identifier} pane_id=#{pane_id} reason=#{inspect(reason)}"
        )

        case from do
          nil -> {:noreply, state}
          _ -> {:reply, {:error, reason}, state}
        end
    end
  end

  # ensure_attach_topic_subscription/1 was used by the parked-open path.
  # That path is gone — cold_attach is the immediate fallback now — so
  # PaneManager no longer subscribes to the attach topic. The pending_opens
  # / attach_topic_subscribed? fields stay on the struct for the historical
  # `:pane_priority_attached` handler (no-op when pending_opens is empty).

  defp cold_attach(state, identifier, workspace, _from) do
    slot = state.cycle_index + 1

    case Aiur.Opencode.PaneSession.start(identifier, workspace) do
      {:ok, %{attach_command: attach_command, attach_url: base_url, session_id: session_id}} ->
        _ = Aiur.Opencode.SessionWriterRegistry.ensure(identifier, base_url)
        _ = session_id

        case open_in_slot(state, slot, identifier, attach_command) do
          {:ok, pane_id, new_state} ->
            AgentPubSub.broadcast_status_change(identifier, :pane_opened)
            _ = apply_layout(new_state)
            {:reply, {:ok, pane_id}, advance_cycle(new_state)}

          {:error, reason} = err ->
            Logger.warning(
              "opencode_pane cold_split_failed identifier=#{identifier} reason=#{inspect(reason)}"
            )

            {:reply, err, state}
        end

      {:error, reason} ->
        Logger.warning(
          "opencode_pane cold_start_failed identifier=#{identifier} reason=#{inspect(reason)}"
        )

        msg = "opencode pane failed: #{inspect(reason)}"
        escaped = Aiur.Opencode.Protocol.shell_escape(msg)
        fallback_cmd = "printf %s #{escaped}; sleep 15"

        case open_in_slot(state, slot, identifier, fallback_cmd) do
          {:ok, pane_id, new_state} ->
            {:reply, {:ok, pane_id}, advance_cycle(new_state)}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  defp opencode_workspace_for(identifier) do
    Aiur.Config.workspace_root()
    |> Path.expand()
    |> Path.join(Aiur.Opencode.Config.safe_identifier(identifier))
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
