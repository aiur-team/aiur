defmodule Aiur.Opencode.Slot.Attach do
  @moduledoc """
  Attach and claim transitions for `Aiur.Opencode.Slot`. Functions take and
  return the slot state; the GenServer stays in `Slot`.
  """

  require Logger

  alias Aiur.Opencode.Slot.{Events, Sessions, State}

  @doc false
  @spec do_attach(String.t(), map()) :: {:ok, String.t() | :attached | nil, map()} | {:error, term()}
  def do_attach(identifier, state) do
    cond do
      MapSet.member?(state.attached_identifiers, identifier) ->
        sid = if state.visible_identifier == identifier, do: state.visible_session_id, else: :attached
        {:ok, sid, state}

      State.identifier_known?(state, identifier) ->
        do_attach_known(identifier, state)

      true ->
        {:error, :identifier_unknown}
    end
  end

  defp do_attach_known(identifier, state) do
    span = Aiur.Perf.span_begin(:slot_do_attach, slot: state.slot_index, identifier: identifier)

    case Sessions.ensure(identifier, state.base_url, state.token) do
      {:ok, session_id} ->
        Aiur.Perf.span_end(span, slot: state.slot_index, identifier: identifier, session_id: session_id)
        new_state = %{state | attached_identifiers: MapSet.put(state.attached_identifiers, identifier)}
        # Note: leadoff render (`respawn_attach_with_session` to bind
        # the slot's attach pane to a session) is NOT done here. It's
        # driven explicitly by `AttachPool.kickoff_fan_out` calling
        # `Slot.set_visible/2` on the slot's intended leadoff
        # identifier — deterministic per slot. Doing it as a side effect
        # of whichever attach finished first under parallel boot caused
        # multiple slots to leadoff the same agent (race), leaving
        # other agents 🔘 (no painted pane) instead of ⚪.
        Aiur.Perf.event(:slot_attach_added, slot: state.slot_index, identifier: identifier, session_id: session_id)
        Logger.info("opencode_slot phase=attach slot=#{state.slot_index} identifier=#{identifier} session_id=#{session_id}")
        {:ok, session_id, new_state}

      {:error, reason} = err ->
        Aiur.Perf.span_end(span, result: :failed, slot: state.slot_index, identifier: identifier, reason: reason)
        err
    end
  end

  @doc false
  @spec drain_pending_attaches(map()) :: map()
  def drain_pending_attaches(%{pending_attaches: ms} = state) do
    if MapSet.size(ms) == 0,
      do: state,
      else: Enum.reduce(ms, %{state | pending_attaches: MapSet.new()}, &retry_pending_attach/2)
  end

  defp retry_pending_attach(id, acc) do
    case do_attach(id, acc) do
      {:ok, _session_id, new_acc} ->
        Events.attach_added(new_acc.slot_index, id)
        Aiur.Perf.event(:slot_attach_retry_succeeded, slot: new_acc.slot_index, identifier: id)
        new_acc

      {:error, reason} ->
        Aiur.Perf.event(:slot_attach_retry_failed, slot: acc.slot_index, identifier: id, reason: reason)
        acc
    end
  end

  @doc false
  @spec clear_claim_for(GenServer.from(), map()) :: map()
  def clear_claim_for({owner, _tag}, %{claim_owner: owner, claim_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | claim_owner: nil, claim_ref: nil}
  end

  def clear_claim_for(_from, state), do: state

  @doc false
  @spec unclaim(map()) :: map()
  def unclaim(%{status: :claimed} = state), do: clear_claim(state)
  def unclaim(state), do: state

  defp clear_claim(%{claim_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | status: :ready, claim_owner: nil, claim_ref: nil}
  end

  defp clear_claim(state), do: %{state | status: :ready, claim_owner: nil, claim_ref: nil}
end
