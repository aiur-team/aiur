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

  alias Aiur.Opencode.AttachPool.{Attachments, Paint, Seeding, Selection}
  alias Aiur.Opencode.{Protocol, Slot}

  defstruct attachments: %{},
            active_identifiers: [],
            fully_warmed_slots: MapSet.new(),
            # `{slot_index, identifier}` keys for attach tasks currently
            # in flight. Prevents duplicate broadcasts re-spawning the
            # same task.
            in_flight: MapSet.new(),
            # Slot indexes that have already received their initial
            # `kickoff_fan_out` leadoff assignment. A slot can broadcast
            # `:slot_ready` more than once over its lifetime (rebuild
            # paths post-`schedule_serve_rebuild`), but its rotational
            # leadoff must only fire ONCE — otherwise a re-ready races
            # against in-flight `set_visible` calls from `do_seed` and
            # displaces the assignment the user just triggered.
            fanned_out_slots: %{},
            slot_pids: %{}

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
  defdelegate topic, to: Attachments

  @doc """
  Seed (or re-seed) the ordered list of currently-active agent
  identifiers. Triggers attach fan-out across all running slots when
  the active set changes.

  Order matters: slot N's leadoff attach is `Enum.at(identifiers, N-1)`
  (1-based slot index → 0-based list index). Wraps for slots beyond
  the active list length.
  """
  @spec seed(GenServer.server(), [String.t()], [String.t()]) :: :ok
  def seed(server \\ __MODULE__, identifiers, retain_ids \\ [])
      when is_list(identifiers) and is_list(retain_ids) do
    GenServer.cast(server, {:seed, identifiers, retain_ids})
  end

  @doc """
  Find a slot that has `identifier` attached, drive Slot.set_visible
  on it, and return `{:ok, %{slot_index, pane_id}}`. Returns `:miss`
  when no slot has it attached.

  Options:

    * `:exclude_visible` — when true, skip slots whose pane is
      currently displaying a different identifier user-visibly. Use
      this for the "open in a new pane" flow so the call doesn't
      reuse a slot the user is already looking at.
  """
  @spec consume(String.t(), keyword()) ::
          {:ok, %{slot_index: pos_integer(), pane_id: String.t()}} | :miss
  def consume(identifier, opts \\ []) when is_binary(identifier) and is_list(opts) do
    GenServer.call(__MODULE__, {:consume, identifier, opts})
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
  def handle_cast({:seed, identifiers, retain_ids}, state) do
    {:noreply, Seeding.do_seed(state, identifiers, retain_ids)}
  end

  def handle_cast({:mark_visible, identifier, slot_index}, state) do
    {:noreply, Attachments.do_mark_visible(state, identifier, slot_index)}
  end

  def handle_cast({:clear_visible, identifier}, state) do
    {:noreply, Attachments.do_clear_visible(state, identifier)}
  end

  @impl true
  def handle_call({:consume, identifier, opts}, _from, state) do
    case Selection.find_slot_for_impl(state, identifier, opts) do
      {:ok, slot_index} ->
        case Seeding.slot_pid_for(slot_index) do
          {:ok, slot_pid} ->
            consume_via_slot(state, identifier, slot_index, slot_pid)

          :error ->
            {:reply, :miss, state}
        end

      :miss ->
        Aiur.Perf.event(:attach_pool_miss,
          identifier: identifier,
          exclude_visible: Keyword.get(opts, :exclude_visible, false),
          exclude_slots: opts |> Keyword.get(:exclude_slots, []) |> Enum.to_list()
        )

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
    {:reply, Selection.count_visible(state), state}
  end

  def handle_call({:find_slot_for, identifier, opts}, _from, state) do
    {:reply, Selection.find_slot_for_impl(state, identifier, opts), state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       attachments: state.attachments,
       fully_warmed_slots: state.fully_warmed_slots,
       visible_count: Selection.count_visible(state)
     }, state}
  end

  @impl true
  def handle_info({:slot_ready, slot_index, pid}, state) do
    # First time we've seen this slot ready — kick its initial attach
    # fan-out (leadoff + remaining active agents). On subsequent re-
    # readys (rebuild path), only re-attach non-leadoff identifiers so
    # the slot's existing leadoff isn't displaced.
    if Seeding.current_slot_pid(slot_index) == pid do
      state = Seeding.reset_replaced_slot(state, slot_index, pid)
      {:noreply, Seeding.kickoff_fan_out(state, slot_index)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:slot_terminated, slot_index, pid}, state) do
    {:noreply, Seeding.purge_slot_lifetime(state, slot_index, pid)}
  end

  def handle_info({:slot_attach_added, slot_index, identifier}, state) do
    {:noreply, Attachments.do_attach_added(state, slot_index, identifier)}
  end

  def handle_info({:slot_attach_removed, slot_index, identifier}, state) do
    {:noreply, Attachments.do_attach_removed(state, slot_index, identifier)}
  end

  def handle_info({:slot_visible_changed, slot_index, nil}, state) do
    # Find which identifier was visible in this slot and clear it.
    identifier =
      Enum.find_value(state.attachments, fn {id, att} ->
        if att.visible_in == slot_index, do: id
      end)

    if identifier do
      {:noreply, Attachments.do_clear_visible(state, identifier)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:slot_visible_changed, slot_index, identifier}, state)
      when is_binary(identifier) do
    {:noreply, Attachments.do_mark_visible(state, identifier, slot_index)}
  end

  def handle_info({:slot_session_changed, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info({:attach_warmed, identifier, slot_index, pane_id}, state) do
    new_state = Attachments.do_attach_added(state, slot_index, identifier)
    _ = pane_id
    {:noreply, new_state}
  end

  def handle_info({:attach_failed, identifier, slot_index, reason}, state) do
    Aiur.Perf.event(:attach_pool_failed,
      identifier: identifier,
      slot: slot_index,
      reason: reason
    )

    new_state = Attachments.do_attach_removed(state, slot_index, identifier)

    Attachments.broadcast_event({:attach_failed, identifier, slot_index, reason})
    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp consume_via_slot(state, identifier, slot_index, slot_pid) do
    case Slot.set_visible(slot_pid, identifier) do
      {:ok, pane_id} ->
        Aiur.Perf.event(:attach_pool_hit,
          identifier: identifier,
          slot: slot_index,
          pane_id: pane_id
        )

        new_state = Attachments.do_mark_visible(state, identifier, slot_index)
        Attachments.broadcast_event({:attach_consumed, identifier, pane_id, slot_index})
        {:reply, {:ok, %{slot_index: slot_index, pane_id: pane_id}}, new_state}

      {:error, reason} ->
        Logger.warning("attach_pool consume failed identifier=#{identifier} slot=#{slot_index} reason=#{inspect(reason)}")

        {:reply, :miss, state}
    end
  end

  @doc "See `Aiur.Opencode.AttachPool.Selection.free_slots_for/2`."
  @spec free_slots_for([{pos_integer(), String.t() | nil}], [String.t()]) :: [pos_integer()]
  defdelegate free_slots_for(slot_vids, active_identifiers), to: Selection

  @doc "See `Aiur.Opencode.AttachPool.Paint.ensure_hidden_geometry/0`."
  @spec ensure_hidden_geometry() :: :ok
  defdelegate ensure_hidden_geometry, to: Paint

  @doc false
  @spec wait_for_paint(String.t(), non_neg_integer()) :: :ok | :timeout
  defdelegate wait_for_paint(pane_id, budget_ms), to: Paint

  @doc false
  @spec _attach_command_for(String.t(), String.t()) :: String.t()
  def _attach_command_for(base_url, session_id),
    do: Protocol.attach_command(base_url, session_id)
end
