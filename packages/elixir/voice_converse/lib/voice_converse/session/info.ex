defmodule VoiceConverse.Session.Info do
  @moduledoc false

  alias VoiceConverse.{Events, LiveContext, TranscriptIndex}
  alias VoiceConverse.Session.Runtime

  def broadcast(state) do
    state.event_broadcast.(state.subscribers, state.id, {:session_info, frame(state)})
    state
  end

  def provider_ready(state, transition) do
    state
    |> Runtime.flush_consult_context()
    |> transition.(:listening)
    |> LiveContext.ready()
    |> broadcast()
  end

  def after_turn(state, event, check_daily_cap) do
    if match?(%Events.AgentText{final?: true}, event),
      do: state |> broadcast() |> check_daily_cap.(),
      else: {:noreply, state}
  end

  def frame(state) do
    descriptor = state.provider.descriptor()
    id = to_string(descriptor.id)
    label = Map.get(descriptor, :label) || id
    elapsed = max(DateTime.diff(state.clock.(), state.started_at), 0)

    %{option_id: id, label: label, interruption_supported: Events.Interruption in state.provider.capabilities().events}
    |> put_price_hint(Map.get(descriptor, :price_hint))
    |> Map.put(:session_seconds_left, max(state.config.limits.max_session_seconds - elapsed, 0))
    |> put_minutes_left(state)
    |> put_fork_mode(state)
  end

  defp put_price_hint(frame, hint) when is_number(hint) and hint >= 0,
    do: Map.put(frame, :cost_estimate_usd, hint)

  defp put_price_hint(frame, _hint), do: frame

  defp put_minutes_left(frame, %{config: %{limits: %{daily_minutes_cap: cap}}} = state) when is_integer(cap) do
    minutes =
      TranscriptIndex.minutes_today(state.config.transcript_root,
        now: state.clock.(),
        open_sessions: fn -> [%{started_at: state.started_at}] end
      )

    if is_integer(minutes), do: Map.put(frame, :minutes_left_today, max(cap - minutes, 0)), else: frame
  rescue
    _error -> frame
  end

  defp put_minutes_left(frame, _state), do: frame

  defp put_fork_mode(frame, %{fork_mode: :replay}), do: Map.put(frame, :fork_mode, :replay)
  defp put_fork_mode(frame, %{fork_mode: :native}), do: Map.put(frame, :fork_mode, :native)
  defp put_fork_mode(frame, _state), do: frame
end
