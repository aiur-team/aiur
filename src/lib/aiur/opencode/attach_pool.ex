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

  alias Aiur.Opencode.{Protocol, Slot, SlotRegistry, SlotSupervisor}
  alias Aiur.Tmux

  @topic "attach_pool"

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
            fanned_out_slots: %{}

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
    {:noreply, do_seed(state, identifiers, retain_ids)}
  end

  def handle_cast({:mark_visible, identifier, slot_index}, state) do
    {:noreply, do_mark_visible(state, identifier, slot_index)}
  end

  def handle_cast({:clear_visible, identifier}, state) do
    {:noreply, do_clear_visible(state, identifier)}
  end

  @impl true
  def handle_call({:consume, identifier, opts}, _from, state) do
    case find_slot_for_impl(state, identifier, opts) do
      {:ok, slot_index} ->
        case slot_pid_for(slot_index) do
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
    # fan-out (leadoff + remaining active agents). On subsequent re-
    # readys (rebuild path), only re-attach non-leadoff identifiers so
    # the slot's existing leadoff isn't displaced.
    state = %{state | fanned_out_slots: Map.delete(state.fanned_out_slots, slot_index)}
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

  defp do_seed(state, identifiers, retain_ids) do
    # Retained identifiers are agents the user paused (Ctrl+C once) but
    # whose opencode pane must stay open until an explicit close (second
    # Ctrl+C). They drop out of `identifiers` (the spawn-eligible set) so
    # they never claim a fresh leadoff, yet we fold the already-attached
    # ones back into `new_active` so they are neither detached (removed)
    # nor re-spawned (added). A retain id with no live attachment is a
    # no-op: it isn't active, so it can't be retained into a pane.
    retained = Enum.filter(retain_ids, &(&1 in state.active_identifiers))
    new_active = Enum.uniq(identifiers ++ retained)
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

    # Detach removed identifiers FIRST so Slot.detach clears the slot's
    # visible_identifier and broadcasts :slot_visible_changed nil. That
    # makes the slot show up as "free" in the next step, both for this
    # call AND for any future do_seed that arrives before another
    # agent is added (the user's actual scenario: pause then start are
    # two separate calls).
    new_state =
      Enum.reduce(removed, new_state, &detach_removed_identifier/2)

    # Find "free" slots: in production, ask each Slot directly for its
    # current visible_identifier (avoids the broadcast race where
    # AttachPool's own `visible_in` map lags). In tests with no live
    # Slot processes, fall back to AttachPool's attachments view.
    slot_indexes = running_slot_indexes()

    # Each active identifier needs at most ONE painted slot. A slot is
    # reclaimable when it is idle, still shows a now-inactive identifier,
    # or is a SURPLUS duplicate of an already-claimed active id. Without
    # this, a single boot agent painted across every pre-warmed slot by
    # kickoff_fan_out leaves zero free slots, stranding post-boot agents
    # at ⏳ (#372). Reclaiming surplus slots lets each post-boot `added`
    # identifier pair with a slot and paint via Slot.set_visible — one
    # slot per agent, no fan-out (respects #409's FD limits).
    slot_vids =
      if slot_indexes == [] do
        slot_vids_from_attachments(new_state.attachments)
      else
        Enum.map(slot_indexes, &visible_identifier_snapshot/1)
      end

    free_slots = free_slots_for(slot_vids, new_active)

    leadoff_pairs = Enum.zip(added, free_slots)
    paired_added = Enum.map(leadoff_pairs, fn {id, _} -> id end)

    if added != [] do
      Aiur.Perf.event(:do_seed_pairing_check,
        new_active: new_active,
        added: added,
        removed: removed,
        slot_vids: slot_vids,
        free_slots: free_slots,
        pairs: leadoff_pairs
      )
    end

    Enum.each(leadoff_pairs, fn {id, slot_index} ->
      _ = start_leadoff_task(new_state, slot_index, id)
    end)

    if leadoff_pairs != [] do
      Aiur.Perf.event(:seed_leadoff_reassignment,
        paired: length(leadoff_pairs),
        added_ids: paired_added,
        free_slots: free_slots
      )
    end

    # Leadoff-only fan-out (#409): each slot paints exactly its one
    # leadoff identifier (the `leadoff_pairs` above). Non-leadoff
    # agents — including post-boot additions that found no free slot —
    # are NOT attached anywhere. Opening one goes through
    # `AttachPool.consume` → `:miss` → `PaneManager.open_with_placeholder`
    # (on-demand cold open, the path non-leadoff agents already took
    # since their slot showed a different leadoff). This collapses the
    # old M×N SessionWriter/session/SQLite fan-out that exhausted file
    # descriptors at high concurrency (the `:emfile` crash).
    new_state
  end

  defp kickoff_fan_out(state, slot_index) do
    # Each slot's rotational leadoff is a DIFFERENT active identifier
    # (slot 1 = active[0], slot 2 = active[1], ...). Fire it exactly
    # ONCE per slot lifetime — slots can broadcast :slot_ready more
    # than once (post-rebuild path), and re-firing the rotation here
    # would race do_seed's pairing and displace whichever assignment
    # the user just triggered (e.g. resume of a queued agent).
    #
    # Each slot paints ONLY its leadoff. The previous "fan out the
    # remaining active identifiers as background `Slot.attach` tasks"
    # cost 30 HTTP attaches at boot (6 slots × 5 rest agents) and
    # saturated Slot mailboxes for ~30 s — the observed 50 s boot.
    # Secondary attach (the 🔘 "switch-session within opencode" path)
    # is a deferred follow-up; deleting the rest loop here gets boot
    # back under 20 s for the common case.
    n = length(state.active_identifiers)

    cond do
      n == 0 ->
        state

      slot_already_fanned_out?(state, slot_index) ->
        state

      true ->
        start = rem(slot_index - 1, n)
        leadoff = Enum.at(state.active_identifiers, start)
        _ = start_leadoff_task(state, slot_index, leadoff)
        %{state | fanned_out_slots: Map.put(state.fanned_out_slots, slot_index, current_slot_pid(slot_index))}
    end
  end

  defp start_leadoff_task(state, slot_index, identifier) do
    case slot_pid_for(slot_index) do
      {:ok, slot_pid} ->
        pool = self()
        Task.start(fn -> run_leadoff_task(pool, slot_pid, slot_index, identifier) end)

        state

      :error ->
        state
    end
  end

  # Paint this slot's single leadoff identifier. Leadoff-only fan-out
  # (#409): no background attach of the other active identifiers — that
  # was the M×N SessionWriter/session/SQLite blow-up behind `:emfile`.
  # Non-leadoff agents open on demand via `AttachPool.consume` → `:miss`
  # → cold respawn (the path they already took, since their slot showed
  # a different leadoff).
  defp run_leadoff_task(pool, slot_pid, slot_index, identifier) do
    span = Aiur.Perf.span_begin(:attach_pool_leadoff, identifier: identifier, slot: slot_index)

    case Slot.set_visible(slot_pid, identifier) do
      {:ok, _pane_id} ->
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
  end

  defp slot_already_fanned_out?(state, slot_index) do
    case {Map.get(state.fanned_out_slots, slot_index), current_slot_pid(slot_index)} do
      {pid, pid} when is_pid(pid) -> true
      _ -> false
    end
  end

  defp current_slot_pid(slot_index) do
    case SlotRegistry.lookup(slot_index) do
      {:ok, pid} -> pid
      :not_found -> nil
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
    attached_in_slot = attached_set_for_slot(state, slot_index)

    # Under the leadoff-only model (no eager fan-out), a slot is
    # "fully warmed" the moment its leadoff identifier is attached.
    # No more "every active identifier on every slot" requirement —
    # that was the 36-attach boot that took 50 s. Bottom warmth row
    # ⬜ now means "this slot has paint."
    full? = MapSet.size(attached_in_slot) >= 1

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
      %{attached_slots: slots} = self_att ->
        prefer = Keyword.get(opts, :prefer)
        exclude_visible = Keyword.get(opts, :exclude_visible, false)
        # `exclude_slots` — explicit list of slot indexes whose panes
        # are currently visible in window 0 (PaneManager owns this fact).
        # We must not hijack a slot whose pane the user is actively
        # looking at by re-binding it to a different identifier.
        # Authoritative over `exclude_visible`, which excluded ALL
        # slots whose `visible_in` was set — including hidden-window
        # leadoffs, which made every post-boot non-leadoff open miss.
        exclude_slots = Keyword.get(opts, :exclude_slots, MapSet.new()) |> to_mapset()

        candidates =
          slots
          |> MapSet.to_list()
          |> Enum.reject(&MapSet.member?(exclude_slots, &1))
          |> filter_visible_to_others(state, identifier, exclude_visible, exclude_slots)

        own_visible = self_att.visible_in

        cond do
          candidates == [] ->
            :miss

          prefer != nil and prefer in candidates ->
            {:ok, prefer}

          # Preferred path: the slot where this identifier was rendered
          # as the leadoff (Slot broadcasts :slot_visible_changed during
          # `maybe_render_leadoff_pane`). Returning that slot lets
          # `Slot.set_visible/2` hit its fast path
          # (`visible_identifier == identifier`) and return the existing
          # pane id without a respawn — instant open, the whole point
          # of pre-warming. Picking any other slot forces a respawn
          # (5-7 s, the regression the user reported).
          is_integer(own_visible) and own_visible in candidates ->
            {:ok, own_visible}

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

  @doc """
  Given `{slot_index, visible_identifier | nil}` pairs and the current
  active identifier list, return the sorted slot indexes that are free
  for a new leadoff.

  Each active identifier keeps exactly ONE slot — its primary, the
  lowest-index slot currently showing it. Every other slot is free:
  idle (`nil`), showing a now-inactive identifier, or a surplus
  duplicate of an already-claimed active id. This is what lets a
  post-boot agent claim a slot when one boot agent has been painted as
  the leadoff across several pre-warmed slots (#372).
  """
  @spec free_slots_for([{pos_integer(), String.t() | nil}], [String.t()]) :: [pos_integer()]
  def free_slots_for(slot_vids, active_identifiers) do
    active = MapSet.new(active_identifiers)

    {_claimed_ids, free} =
      slot_vids
      |> Enum.sort_by(fn {idx, _vid} -> idx end)
      |> Enum.reduce({MapSet.new(), []}, fn {idx, vid}, {claimed_ids, free_acc} ->
        if is_binary(vid) and MapSet.member?(active, vid) and
             not MapSet.member?(claimed_ids, vid) do
          {MapSet.put(claimed_ids, vid), free_acc}
        else
          {claimed_ids, [idx | free_acc]}
        end
      end)

    Enum.sort(free)
  end

  # Test / no-live-slots fallback: derive `{slot_index, visible_identifier}`
  # pairs from the pool's own attachments (`visible_in`) so the same
  # reclamation logic runs without live Slot snapshots. Attached-but-not-
  # visible slots surface as `{idx, nil}`.
  defp slot_vids_from_attachments(attachments) do
    visible_by_slot =
      Enum.reduce(attachments, %{}, fn {id, %{visible_in: slot}}, acc ->
        if is_integer(slot), do: Map.put(acc, slot, id), else: acc
      end)

    attached_slots =
      Enum.flat_map(attachments, fn {_id, %{attached_slots: slots}} -> MapSet.to_list(slots) end)

    (attached_slots ++ Map.keys(visible_by_slot))
    |> Enum.uniq()
    |> Enum.map(fn slot -> {slot, Map.get(visible_by_slot, slot)} end)
  end

  defp detach_removed_identifier(id, acc) do
    slots = attached_slots_for(acc, id)
    Enum.each(slots, &detach_slot_from_identifier(&1, id))
    broadcast_event({:agent_inactive, id})
    Aiur.Perf.event(:agent_inactive, identifier: id)
    acc
  end

  defp attached_slots_for(state, id) do
    case Map.get(state.attachments, id) do
      %{attached_slots: slots} -> MapSet.to_list(slots)
      _ -> []
    end
  end

  defp detach_slot_from_identifier(slot_index, id) do
    case slot_pid_for(slot_index) do
      {:ok, pid} -> Slot.detach(pid, id)
      :error -> :ok
    end
  end

  defp visible_identifier_snapshot(slot_index) do
    case slot_pid_for(slot_index) do
      {:ok, pid} -> {slot_index, slot_visible_identifier(pid)}
      :error -> {slot_index, nil}
    end
  end

  defp slot_visible_identifier(pid) do
    case Slot.snapshot(pid) do
      %{visible_identifier: vid} -> vid
      _ -> nil
    end
  end

  defp filter_visible_to_others(candidates, state, identifier, true, exclude_slots) do
    if MapSet.size(exclude_slots) == 0 do
      visible_to_other = visible_slots_for_other_identifiers(state, identifier)
      Enum.reject(candidates, &MapSet.member?(visible_to_other, &1))
    else
      candidates
    end
  end

  defp filter_visible_to_others(candidates, _state, _identifier, _exclude_visible, _exclude_slots),
    do: candidates

  defp visible_slots_for_other_identifiers(state, identifier) do
    state.attachments
    |> Enum.filter(fn {id, att} -> id != identifier and not is_nil(att.visible_in) end)
    |> Enum.map(fn {_id, att} -> att.visible_in end)
    |> MapSet.new()
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

  defp to_mapset(%MapSet{} = ms), do: ms
  defp to_mapset(list) when is_list(list), do: MapSet.new(list)
  defp to_mapset(_), do: MapSet.new()

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

  @paint_poll_interval_ms 100

  @doc """
  Re-size the hidden window so each slot's attach pane matches the
  geometry it will have in window 0 once the user opens it. Avoids
  the SIGWINCH that triggers opencode-attach's ~7 s splash animation
  on every move-pane resize. Idempotent — safe to call on terminal
  resize signals.

  `HiddenWindow.handle_continue(:create_window)` runs the same logic
  inline at boot so the keep-alive pane is already at the right size
  before the first slot splits into it. This `ensure_hidden_geometry`
  entry point is kept for re-trigger paths (e.g. terminal resize).
  """
  @spec ensure_hidden_geometry() :: :ok
  def ensure_hidden_geometry do
    with {:ok, [dims_str | _]} <-
           Tmux.command(
             Tmux,
             "display-message -p -t aiur-orangekid-default:0 \"\#{window_width} \#{window_height}\""
           ),
         [w_str, h_str] <- String.split(String.trim(dims_str), " ", trim: true),
         {term_w, ""} <- Integer.parse(w_str),
         {term_h, ""} <- Integer.parse(h_str) do
      slot_count = max(SlotSupervisor.slot_count(), 1)
      chat_pane_width = max(div(term_w, 2), 40)
      hidden_window_w = chat_pane_width * slot_count

      _ =
        Tmux.command(
          Tmux,
          "resize-window -t aiur-orangekid-default:aiur-hidden -x #{hidden_window_w} -y #{term_h}"
        )

      _ =
        Tmux.command(
          Tmux,
          "select-layout -t aiur-orangekid-default:aiur-hidden even-horizontal"
        )

      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  @spec wait_for_paint(String.t(), non_neg_integer()) :: :ok | :timeout
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
