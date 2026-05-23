defmodule Aiur.Opencode.AttachPool do
  @moduledoc """
  Multi-attach registry for opencode slot pre-warm.

  Tracks **which slots have which agents attached**, plus which slot
  currently has each agent visible in its chat pane. Drives the
  fan-out: every slot attaches every active agent, ordered so slot N
  starts with agent at position N. Reacts to active-agent set deltas
  by attaching newcomers to every warm slot and detaching agents that
  leave the active set.

  ## State per identifier

      %{
        attached_slots: MapSet.t(slot_index),
        visible_in:     slot_index | nil
      }

  `attach_count` for an identifier == `MapSet.size(attached_slots)`.
  `visible_count` globally == count of identifiers with non-nil
  `visible_in`. These two numbers drive AgentList's 4-state marker
  selection (⏳ / 🔘 / ⚪ / 🟢).

  ## Events emitted

  On `Aiur.PubSub` topic `topic/0`:

    * `{:attach_state_changed, identifier, attach_count, visible_in}` —
      any time an identifier's attach_count or visible_in changes.
    * `{:slot_fully_warmed, slot_index}` — slot has every active
      agent attached.
    * `{:slot_warmth_dropped, slot_index}` — slot lost full coverage
      (active set grew, or an attach failed).

  """

  use GenServer
  require Logger

  alias Aiur.Opencode.{Protocol, Slot, SlotRegistry}
  alias Aiur.Tmux

  @topic "attach_pool"

  defstruct attachments: %{},
            active_identifiers: [],
            fully_warmed_slots: MapSet.new(),
            # `{slot_index, identifier}` keys for attach tasks currently
            # in flight. Prevents duplicate broadcasts re-spawning the
            # same task.
            in_flight: MapSet.new()

  @type attachment :: %{
          attached_slots: MapSet.t(pos_integer()),
          visible_in: pos_integer() | nil
        }

  ## Public API ----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "PubSub topic for attach-state changes."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Seed (or re-seed) the ordered list of currently-active agent
  identifiers. Triggers attach fan-out across all running slots when
  the active set changes.

  Order matters: slot N's leadoff attach is `Enum.at(identifiers, N-1)`
  (1-based slot index → 0-based list index). Wraps for slots beyond
  the active list length.
  """
  @spec seed(GenServer.server(), [String.t()]) :: :ok
  def seed(server \\ __MODULE__, identifiers) when is_list(identifiers) do
    GenServer.cast(server, {:seed, identifiers})
  end

  @doc """
  Find a slot that has `identifier` attached, drive Slot.set_visible
  on it, and return `{:ok, %{slot_index, pane_id}}`. Returns `:miss`
  when no slot has it attached.
  """
  @spec consume(GenServer.server(), String.t()) ::
          {:ok, %{slot_index: pos_integer(), pane_id: String.t()}} | :miss
  def consume(server \\ __MODULE__, identifier) when is_binary(identifier) do
    GenServer.call(server, {:consume, identifier})
  catch
    :exit, _ -> :miss
  end

  @doc """
  Number of slots that have `identifier` attached.
  """
  @spec attach_count(GenServer.server(), String.t()) :: non_neg_integer()
  def attach_count(server \\ __MODULE__, identifier) when is_binary(identifier) do
    GenServer.call(server, {:attach_count, identifier}, 1_000)
  catch
    :exit, _ -> 0
  end

  @doc """
  Global count of identifiers currently visible in some pane.
  """
  @spec visible_count(GenServer.server()) :: non_neg_integer()
  def visible_count(server \\ __MODULE__) do
    GenServer.call(server, :visible_count, 1_000)
  catch
    :exit, _ -> 0
  end

  @doc """
  Find a slot with `identifier` attached. Options:

    * `:prefer` — slot index to return first if it has the identifier
      attached. Used by `:swap_in_last_used` so the same pane is reused.
    * `:exclude_visible` — when true, skips slots that currently have
      a DIFFERENT identifier visible (i.e. the user's looking at
      something else there). Default false.
  """
  @spec find_slot_for(GenServer.server(), String.t(), keyword()) ::
          {:ok, pos_integer()} | :miss
  def find_slot_for(server \\ __MODULE__, identifier, opts \\ [])
      when is_binary(identifier) do
    GenServer.call(server, {:find_slot_for, identifier, opts}, 1_000)
  catch
    :exit, _ -> :miss
  end

  @doc """
  Mark `identifier` visible in `slot_index`. Triggers
  :attach_state_changed.
  """
  @spec mark_visible(GenServer.server(), String.t(), pos_integer()) :: :ok
  def mark_visible(server \\ __MODULE__, identifier, slot_index)
      when is_binary(identifier) and is_integer(slot_index) do
    GenServer.cast(server, {:mark_visible, identifier, slot_index})
  end

  @doc "Clear visible flag for `identifier`."
  @spec clear_visible(GenServer.server(), String.t()) :: :ok
  def clear_visible(server \\ __MODULE__, identifier) when is_binary(identifier) do
    GenServer.cast(server, {:clear_visible, identifier})
  end

  @doc """
  Returns the full attachment map plus aggregate state for renderer
  consumption.
  """
  @spec snapshot(GenServer.server()) :: %{
          attachments: %{optional(String.t()) => attachment()},
          fully_warmed_slots: MapSet.t(pos_integer()),
          visible_count: non_neg_integer()
        }
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot, 1_000)
  catch
    :exit, _ -> %{attachments: %{}, fully_warmed_slots: MapSet.new(), visible_count: 0}
  end

  ## GenServer callbacks -------------------------------------------------

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Aiur.PubSub, Slot.slots_topic())
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:seed, identifiers}, state) do
    {:noreply, do_seed(state, identifiers)}
  end

  def handle_cast({:mark_visible, identifier, slot_index}, state) do
    {:noreply, do_mark_visible(state, identifier, slot_index)}
  end

  def handle_cast({:clear_visible, identifier}, state) do
    {:noreply, do_clear_visible(state, identifier)}
  end

  @impl true
  def handle_call({:consume, identifier}, _from, state) do
    case find_slot_for_impl(state, identifier, []) do
      {:ok, slot_index} ->
        case slot_pid_for(slot_index) do
          {:ok, slot_pid} ->
            consume_via_slot(state, identifier, slot_index, slot_pid)

          :error ->
            {:reply, :miss, state}
        end

      :miss ->
        Aiur.Perf.event(:attach_pool_miss, identifier: identifier)
        {:reply, :miss, state}
    end
  end

  def handle_call({:attach_count, identifier}, _from, state) do
    count =
      case Map.get(state.attachments, identifier) do
        %{attached_slots: slots} -> MapSet.size(slots)
        _ -> 0
      end

    {:reply, count, state}
  end

  def handle_call(:visible_count, _from, state) do
    {:reply, count_visible(state), state}
  end

  def handle_call({:find_slot_for, identifier, opts}, _from, state) do
    {:reply, find_slot_for_impl(state, identifier, opts), state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       attachments: state.attachments,
       fully_warmed_slots: state.fully_warmed_slots,
       visible_count: count_visible(state)
     }, state}
  end

  @impl true
  def handle_info({:slot_ready, slot_index}, state) do
    # First time we've seen this slot ready — kick its initial attach
    # fan-out (leadoff + remaining active agents).
    {:noreply, kickoff_fan_out(state, slot_index)}
  end

  def handle_info({:slot_attach_added, slot_index, identifier}, state) do
    {:noreply, do_attach_added(state, slot_index, identifier)}
  end

  def handle_info({:slot_attach_removed, slot_index, identifier}, state) do
    {:noreply, do_attach_removed(state, slot_index, identifier)}
  end

  def handle_info({:slot_visible_changed, slot_index, nil}, state) do
    # Find which identifier was visible in this slot and clear it.
    identifier =
      Enum.find_value(state.attachments, fn {id, att} ->
        if att.visible_in == slot_index, do: id
      end)

    if identifier do
      {:noreply, do_clear_visible(state, identifier)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:slot_visible_changed, slot_index, identifier}, state)
      when is_binary(identifier) do
    {:noreply, do_mark_visible(state, identifier, slot_index)}
  end

  def handle_info({:slot_session_changed, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info({:attach_warmed, identifier, slot_index, pane_id}, state) do
    new_state = do_attach_added(state, slot_index, identifier)
    _ = pane_id
    {:noreply, new_state}
  end

  def handle_info({:attach_failed, identifier, slot_index, reason}, state) do
    Aiur.Perf.event(:attach_pool_failed,
      identifier: identifier,
      slot: slot_index,
      reason: reason
    )

    new_state = do_attach_removed(state, slot_index, identifier)

    broadcast_event({:attach_failed, identifier, slot_index, reason})
    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals -----------------------------------------------------------

  defp do_seed(state, identifiers) do
    new_active = identifiers
    added = new_active -- state.active_identifiers
    removed = state.active_identifiers -- new_active

    new_state = %{state | active_identifiers: new_active}

    new_state =
      Enum.reduce(added, new_state, fn id, acc ->
        case Map.get(acc.attachments, id) do
          nil ->
            put_in(
              acc.attachments[id],
              %{attached_slots: MapSet.new(), visible_in: nil}
            )

          _ ->
            acc
        end
      end)

    new_state =
      Enum.reduce(added, new_state, fn id, acc ->
        Enum.reduce(running_slot_indexes(), acc, fn slot_index, acc2 ->
          start_attach_task(acc2, slot_index, id)
        end)
      end)

    new_state =
      Enum.reduce(removed, new_state, fn id, acc ->
        slots =
          case Map.get(acc.attachments, id) do
            %{attached_slots: slots} -> MapSet.to_list(slots)
            _ -> []
          end

        Enum.each(slots, fn slot_index ->
          case slot_pid_for(slot_index) do
            {:ok, pid} -> Slot.detach(pid, id)
            :error -> :ok
          end
        end)

        acc
      end)

    new_state
  end

  defp kickoff_fan_out(state, slot_index) do
    # Leadoff = active_identifiers at index (slot_index - 1), wrapping.
    n = length(state.active_identifiers)

    if n == 0 do
      state
    else
      start = rem(slot_index - 1, n)
      ordered = Enum.slice(state.active_identifiers, start, n) ++ Enum.take(state.active_identifiers, start)

      Enum.reduce(ordered, state, fn id, acc ->
        start_attach_task(acc, slot_index, id)
      end)
    end
  end

  defp start_attach_task(state, slot_index, identifier) do
    key = {slot_index, identifier}

    cond do
      MapSet.member?(state.in_flight, key) ->
        state

      identifier_already_attached?(state, slot_index, identifier) ->
        state

      true ->
        case slot_pid_for(slot_index) do
          {:ok, slot_pid} ->
            pool = self()

            Task.start(fn ->
              span =
                Aiur.Perf.span_begin(:attach_pool_attach,
                  identifier: identifier,
                  slot: slot_index
                )

              case Slot.attach(slot_pid, identifier) do
                {:ok, _session_id} ->
                  Aiur.Perf.span_end(span, identifier: identifier, slot: slot_index)
                  send(pool, {:attach_task_done, slot_index, identifier, :ok})

                {:error, reason} ->
                  Aiur.Perf.span_end(span,
                    result: :failed,
                    identifier: identifier,
                    slot: slot_index,
                    reason: reason
                  )

                  send(pool, {:attach_failed, identifier, slot_index, reason})
                  send(pool, {:attach_task_done, slot_index, identifier, {:error, reason}})
              end
            end)

            %{state | in_flight: MapSet.put(state.in_flight, key)}

          :error ->
            state
        end
    end
  end

  defp identifier_already_attached?(state, slot_index, identifier) do
    case Map.get(state.attachments, identifier) do
      %{attached_slots: slots} -> MapSet.member?(slots, slot_index)
      _ -> false
    end
  end

  defp do_attach_added(state, slot_index, identifier) do
    state = ensure_entry(state, identifier)
    att = Map.fetch!(state.attachments, identifier)
    new_att = %{att | attached_slots: MapSet.put(att.attached_slots, slot_index)}

    new_state =
      state
      |> put_in([Access.key!(:attachments), identifier], new_att)
      |> Map.update!(:in_flight, &MapSet.delete(&1, {slot_index, identifier}))
      |> maybe_update_fully_warmed(slot_index)

    broadcast_state_changed(identifier, new_att)
    new_state
  end

  defp do_attach_removed(state, slot_index, identifier) do
    case Map.get(state.attachments, identifier) do
      %{attached_slots: slots} = att ->
        new_slots = MapSet.delete(slots, slot_index)

        new_att =
          if att.visible_in == slot_index do
            %{att | attached_slots: new_slots, visible_in: nil}
          else
            %{att | attached_slots: new_slots}
          end

        new_state =
          state
          |> put_in([Access.key!(:attachments), identifier], new_att)
          |> Map.update!(:in_flight, &MapSet.delete(&1, {slot_index, identifier}))
          |> maybe_update_fully_warmed(slot_index)

        new_state =
          if MapSet.size(new_slots) == 0 and identifier not in new_state.active_identifiers do
            %{new_state | attachments: Map.delete(new_state.attachments, identifier)}
          else
            new_state
          end

        broadcast_state_changed(identifier, new_att)
        new_state

      _ ->
        state
    end
  end

  defp do_mark_visible(state, identifier, slot_index) do
    state = ensure_entry(state, identifier)
    att = Map.fetch!(state.attachments, identifier)

    state =
      Enum.reduce(state.attachments, state, fn {other_id, other_att}, acc ->
        if other_id != identifier and other_att.visible_in == slot_index do
          new_other = %{other_att | visible_in: nil}
          broadcast_state_changed(other_id, new_other)
          put_in(acc.attachments[other_id], new_other)
        else
          acc
        end
      end)

    new_att = %{att | visible_in: slot_index}
    new_state = put_in(state.attachments[identifier], new_att)

    broadcast_state_changed(identifier, new_att)
    new_state
  end

  defp do_clear_visible(state, identifier) do
    case Map.get(state.attachments, identifier) do
      %{visible_in: nil} ->
        state

      %{} = att ->
        new_att = %{att | visible_in: nil}
        new_state = put_in(state.attachments[identifier], new_att)
        broadcast_state_changed(identifier, new_att)
        new_state

      _ ->
        state
    end
  end

  defp ensure_entry(state, identifier) do
    case Map.get(state.attachments, identifier) do
      nil ->
        put_in(
          state.attachments[identifier],
          %{attached_slots: MapSet.new(), visible_in: nil}
        )

      _ ->
        state
    end
  end

  defp maybe_update_fully_warmed(state, slot_index) do
    active_set = MapSet.new(state.active_identifiers)
    attached_in_slot = attached_set_for_slot(state, slot_index)

    full? = MapSet.size(active_set) > 0 and MapSet.subset?(active_set, attached_in_slot)

    case {full?, MapSet.member?(state.fully_warmed_slots, slot_index)} do
      {true, false} ->
        broadcast_event({:slot_fully_warmed, slot_index})
        Aiur.Perf.event(:slot_fully_warmed, slot: slot_index)
        %{state | fully_warmed_slots: MapSet.put(state.fully_warmed_slots, slot_index)}

      {false, true} ->
        broadcast_event({:slot_warmth_dropped, slot_index})
        Aiur.Perf.event(:slot_warmth_dropped, slot: slot_index)
        %{state | fully_warmed_slots: MapSet.delete(state.fully_warmed_slots, slot_index)}

      _ ->
        state
    end
  end

  defp attached_set_for_slot(state, slot_index) do
    Enum.reduce(state.attachments, MapSet.new(), fn {id, att}, acc ->
      if MapSet.member?(att.attached_slots, slot_index), do: MapSet.put(acc, id), else: acc
    end)
  end

  defp find_slot_for_impl(state, identifier, opts) do
    case Map.get(state.attachments, identifier) do
      %{attached_slots: slots} ->
        prefer = Keyword.get(opts, :prefer)
        exclude_visible = Keyword.get(opts, :exclude_visible, false)

        candidates =
          if exclude_visible do
            visible_to_other =
              state.attachments
              |> Enum.filter(fn {id, att} -> id != identifier and not is_nil(att.visible_in) end)
              |> Enum.map(fn {_id, att} -> att.visible_in end)
              |> MapSet.new()

            slots
            |> MapSet.to_list()
            |> Enum.reject(&MapSet.member?(visible_to_other, &1))
          else
            MapSet.to_list(slots)
          end

        cond do
          candidates == [] ->
            :miss

          prefer != nil and prefer in candidates ->
            {:ok, prefer}

          true ->
            {:ok, Enum.min(candidates)}
        end

      _ ->
        :miss
    end
  end

  defp count_visible(state) do
    Enum.count(state.attachments, fn {_id, att} -> not is_nil(att.visible_in) end)
  end

  defp consume_via_slot(state, identifier, slot_index, slot_pid) do
    case Slot.set_visible(slot_pid, identifier) do
      {:ok, pane_id} ->
        Aiur.Perf.event(:attach_pool_hit,
          identifier: identifier,
          slot: slot_index,
          pane_id: pane_id
        )

        new_state = do_mark_visible(state, identifier, slot_index)
        broadcast_event({:attach_consumed, identifier, pane_id, slot_index})
        {:reply, {:ok, %{slot_index: slot_index, pane_id: pane_id}}, new_state}

      {:error, reason} ->
        Logger.warning("attach_pool consume failed identifier=#{identifier} slot=#{slot_index} reason=#{inspect(reason)}")

        {:reply, :miss, state}
    end
  end

  defp running_slot_indexes do
    SlotRegistry.all() |> Enum.map(fn {idx, _pid} -> idx end)
  end

  defp slot_pid_for(slot_index) do
    case Enum.find(SlotRegistry.all(), fn {idx, _pid} -> idx == slot_index end) do
      {_idx, pid} when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp broadcast_state_changed(identifier, %{attached_slots: slots, visible_in: visible_in}) do
    broadcast_event({:attach_state_changed, identifier, MapSet.size(slots), visible_in})
  end

  defp broadcast_event(payload) do
    Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, payload)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Tmux geometry + paint-detect helpers retained for slot-bound
  # callers (e.g. Slot's hidden-window setup) and as a stable target
  # for behavioral guards. Not invoked from inside this module.

  @hidden_target_width 600
  @hidden_target_height 60
  @paint_poll_interval_ms 100

  @doc false
  def ensure_hidden_geometry do
    target = Aiur.Config.max_vertical_panes() * 2 - 1
    desired_width = max(target * 110, @hidden_target_width)

    case Tmux.command(Tmux, "display-message -p -t aiur-orangekid-default:aiur-hidden \#{window_width}") do
      {:ok, [width_str | _]} ->
        current = width_str |> String.trim() |> String.to_integer()

        if current < desired_width do
          _ =
            Tmux.command(
              Tmux,
              "resize-window -t aiur-orangekid-default:aiur-hidden -x #{desired_width} -y #{@hidden_target_height}"
            )

          _ =
            Tmux.command(
              Tmux,
              "select-layout -t aiur-orangekid-default:aiur-hidden even-horizontal"
            )
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  def wait_for_paint(pane_id, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_wait_for_paint(pane_id, deadline)
  end

  defp do_wait_for_paint(pane_id, deadline) do
    case Tmux.command(Tmux, "capture-pane -p -t #{pane_id}") do
      {:ok, lines} ->
        if String.contains?(Enum.join(lines, "\n"), "Build · issue-") do
          :ok
        else
          retry_wait_for_paint(pane_id, deadline)
        end

      _ ->
        retry_wait_for_paint(pane_id, deadline)
    end
  end

  defp retry_wait_for_paint(pane_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      Process.sleep(@paint_poll_interval_ms)
      do_wait_for_paint(pane_id, deadline)
    end
  end

  @doc false
  @spec _attach_command_for(String.t(), String.t()) :: String.t()
  def _attach_command_for(base_url, session_id),
    do: Protocol.attach_command(base_url, session_id)
end
