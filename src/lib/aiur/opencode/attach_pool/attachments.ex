defmodule Aiur.Opencode.AttachPool.Attachments do
  @moduledoc """
  Per-identifier attachment bookkeeping for `Aiur.Opencode.AttachPool`:
  which slots have an identifier attached, which slot shows it, and the
  PubSub events those changes emit.
  """

  @topic "attach_pool"

  @doc "PubSub topic for attach-state changes."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc false
  @spec purge_slot_attachments(map(), pos_integer()) :: map()
  def purge_slot_attachments(state, slot_index) do
    Enum.reduce(state.attachments, state, fn {identifier, attachment}, acc ->
      if MapSet.member?(attachment.attached_slots, slot_index) do
        do_attach_removed(acc, slot_index, identifier)
      else
        acc
      end
    end)
  end

  @doc false
  @spec do_attach_added(map(), pos_integer(), String.t()) :: map()
  def do_attach_added(state, slot_index, identifier) do
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

  @doc false
  @spec do_attach_removed(map(), pos_integer(), String.t()) :: map()
  def do_attach_removed(state, slot_index, identifier) do
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

  @doc false
  @spec do_mark_visible(map(), String.t(), pos_integer()) :: map()
  def do_mark_visible(state, identifier, slot_index) do
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

  @doc false
  @spec do_clear_visible(map(), String.t()) :: map()
  def do_clear_visible(state, identifier) do
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

  defp broadcast_state_changed(identifier, %{attached_slots: slots, visible_in: visible_in}) do
    broadcast_event({:attach_state_changed, identifier, MapSet.size(slots), visible_in})
  end

  @doc false
  @spec broadcast_event(term()) :: :ok | {:error, term()}
  def broadcast_event(payload) do
    Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, payload)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
