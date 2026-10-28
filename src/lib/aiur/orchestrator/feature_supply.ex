defmodule Aiur.Orchestrator.FeatureSupply do
  @moduledoc "Observes feature supply without changing admission or dispatch order."

  alias Aiur.{RunTelemetry, Signal}
  alias Aiur.Orchestrator.{FeatureSupplySnapshot, State}
  alias Aiur.Orchestrator.IssueSync.AttentionSnapshot

  @topic "system.feature_supply_low"
  @hold_ms 30 * 60_000
  @clear_ms 10 * 60_000

  @spec observe(State.t(), [Aiur.Issue.t()], keyword()) :: State.t()
  def observe(state, issues, opts \\ []) do
    if state.globally_paused do
      unavailable(state)
    else
      sample = FeatureSupplySnapshot.build(state, issues)
      now = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
      timestamp = Keyword.get(opts, :timestamp_ms, System.system_time(:millisecond))
      record = Keyword.get(opts, :record, &RunTelemetry.record/2)
      emit = Keyword.get(opts, :emit, &Signal.alert/2)
      previous = state.feature_supply
      active = Map.get_lazy(previous, :active, fn -> AttentionSnapshot.active_system_attention?(@topic) end)
      deficit = max(0, sample.free - sample.feature_ready)
      record_interval(previous, now, timestamp, record)
      episode = transition(previous, active, deficit > 0, now, sample, emit, record)
      %{state | feature_supply: Map.merge(episode, %{at: now, timestamp: timestamp, deficit: deficit, non_feature: sample.non_feature_running, sample: sample})}
    end
  end

  @doc "Unknown or paused passes break both continuous timers and interval coverage."
  @spec unavailable(State.t()) :: State.t()
  def unavailable(state), do: %{state | feature_supply: Map.take(state.feature_supply, [:active, :opened_at])}

  defp transition(previous, active, true, now, sample, emit, record) do
    since = previous[:since] || now

    if not active and now - since >= @hold_ms do
      reason = reason(sample)

      case emit.(@topic, message: reason, reason: reason, needs_attention: true, severity: "warning", durable: true, exchange_payload: sample) do
        :ok ->
          record.(:feature_supply, %{event: "opened", free: sample.free, feature_ready: sample.feature_ready})
          %{active: true, since: since, opened_at: now}

        _ ->
          %{active: false, since: since}
      end
    else
      %{active: active, since: since, opened_at: previous[:opened_at]}
    end
  end

  defp transition(previous, true, false, now, _sample, emit, record) do
    clear_since = previous[:clear_since] || now

    if now - clear_since >= @clear_ms do
      case emit.(@topic <> ".resolved", message: "Feature supply has been sufficient for 10 minutes.", needs_attention: false, severity: "info", durable: true) do
        :ok ->
          record.(:feature_supply, %{event: "resolved", open_duration_ms: if(previous[:opened_at], do: now - previous.opened_at)})
          %{active: false}

        _ ->
          Map.merge(previous, %{active: true, since: nil, clear_since: clear_since})
      end
    else
      %{active: true, clear_since: clear_since, opened_at: previous[:opened_at]}
    end
  end

  defp transition(_previous, false, false, _now, _sample, _emit, _record), do: %{active: false}

  defp record_interval(%{at: at, deficit: deficit, non_feature: non_feature}, now, timestamp, record) when now > at do
    elapsed = now - at

    record.(:feature_supply, %{
      event: "interval",
      interval_start_ms: timestamp - elapsed,
      interval_end_ms: timestamp,
      feature_starved_slot_minutes: deficit * elapsed / 60_000,
      non_feature_during_starvation_minutes: if(deficit > 0 and non_feature, do: elapsed / 60_000, else: 0),
      observed_minutes: elapsed / 60_000
    })
  end

  defp record_interval(_, _, _, _), do: :ok

  defp reason(sample) do
    blockers =
      Enum.map_join(sample.blockers, "; ", fn row ->
        "#{row.identifier} (#{row.state}) holds #{row.feature_tickets}, PR #{row.pr_number || "unknown"} #{row.pr_state}"
      end)

    "Feature supply low for 30 minutes: free=#{sample.free}, feature_ready=#{sample.feature_ready}; " <>
      "feature todo declines=#{inspect(sample.declines)}; top blockers (cached PR evidence): #{blockers}. " <>
      "Land blocker PRs first, then promote or publish feature work in goal order."
  end
end
