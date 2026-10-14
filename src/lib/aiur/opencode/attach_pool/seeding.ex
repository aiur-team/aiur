defmodule Aiur.Opencode.AttachPool.Seeding do
  @moduledoc """
  Active-set seeding and per-slot leadoff fan-out for `Aiur.Opencode.AttachPool`.

  Functions take and return the pool state; the GenServer stays in
  `AttachPool`. Leadoff tasks report back to the calling process.
  """

  alias Aiur.Opencode.AttachPool.{Attachments, Selection}
  alias Aiur.Opencode.{Slot, SlotRegistry}

  @doc false
  @spec do_seed(map(), [String.t()], [String.t()]) :: map()
  def do_seed(state, identifiers, retain_ids) do
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
        Selection.slot_vids_from_attachments(new_state.attachments)
      else
        Enum.map(slot_indexes, &visible_identifier_snapshot/1)
      end

    free_slots = Selection.free_slots_for(slot_vids, new_active)

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

  @doc false
  @spec kickoff_fan_out(map(), pos_integer()) :: map()
  def kickoff_fan_out(state, slot_index) do
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

  @doc false
  @spec current_slot_pid(pos_integer()) :: pid() | nil
  def current_slot_pid(slot_index) do
    case SlotRegistry.lookup(slot_index) do
      {:ok, pid} -> pid
      :not_found -> nil
    end
  end

  @doc false
  @spec reset_replaced_slot(map(), pos_integer(), pid()) :: map()
  def reset_replaced_slot(state, slot_index, current_pid) do
    case Map.get(state.slot_pids, slot_index) do
      nil ->
        %{state | slot_pids: Map.put(state.slot_pids, slot_index, current_pid)}

      ^current_pid ->
        state

      old_pid ->
        state
        |> purge_slot_lifetime(slot_index, old_pid)
        |> Map.update!(:slot_pids, &Map.put(&1, slot_index, current_pid))
    end
  end

  @doc false
  @spec purge_slot_lifetime(map(), pos_integer(), pid()) :: map()
  def purge_slot_lifetime(state, slot_index, pid) do
    if Map.get(state.slot_pids, slot_index) == pid do
      state
      |> Attachments.purge_slot_attachments(slot_index)
      |> Map.update!(:fully_warmed_slots, &MapSet.delete(&1, slot_index))
      |> Map.update!(:in_flight, &MapSet.filter(&1, fn {index, _} -> index != slot_index end))
      |> Map.update!(:fanned_out_slots, &Map.delete(&1, slot_index))
      |> Map.update!(:slot_pids, &Map.delete(&1, slot_index))
    else
      state
    end
  end

  defp detach_removed_identifier(id, acc) do
    slots = Selection.attached_slots_for(acc, id)
    Enum.each(slots, &detach_slot_from_identifier(&1, id))
    Attachments.broadcast_event({:agent_inactive, id})
    Aiur.Perf.event(:agent_inactive, identifier: id)
    acc
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

  defp running_slot_indexes do
    SlotRegistry.all() |> Enum.map(fn {idx, _pid} -> idx end)
  end

  @doc false
  @spec slot_pid_for(pos_integer()) :: {:ok, pid()} | :error
  def slot_pid_for(slot_index) do
    case Enum.find(SlotRegistry.all(), fn {idx, _pid} -> idx == slot_index end) do
      {_idx, pid} when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end
end
