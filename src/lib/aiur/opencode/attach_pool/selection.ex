defmodule Aiur.Opencode.AttachPool.Selection do
  @moduledoc """
  Slot selection for `Aiur.Opencode.AttachPool`: pure queries over the
  pool's attachment map.
  """

  @doc false
  @spec find_slot_for_impl(map(), String.t(), keyword()) :: {:ok, pos_integer()} | :miss
  def find_slot_for_impl(state, identifier, opts) do
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

  @doc false
  @spec count_visible(map()) :: non_neg_integer()
  def count_visible(state) do
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
  @doc false
  @spec slot_vids_from_attachments(map()) :: [{pos_integer(), String.t() | nil}]
  def slot_vids_from_attachments(attachments) do
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

  @doc false
  @spec attached_slots_for(map(), String.t()) :: [pos_integer()]
  def attached_slots_for(state, id) do
    case Map.get(state.attachments, id) do
      %{attached_slots: slots} -> MapSet.to_list(slots)
      _ -> []
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

  defp to_mapset(%MapSet{} = ms), do: ms
  defp to_mapset(list) when is_list(list), do: MapSet.new(list)
  defp to_mapset(_), do: MapSet.new()
end
