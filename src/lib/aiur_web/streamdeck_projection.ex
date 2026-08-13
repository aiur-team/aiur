defmodule AiurWeb.StreamdeckProjection do
  @moduledoc false

  alias Aiur.{CodingAgent, DecisionMetrics, Orchestrator, ProviderMeterProjection, ProviderMeterSnapshot}
  alias AiurWeb.{Endpoint, StreamDeckGrid}

  @version 1
  @default_usage_interval_seconds 300
  @stale_after_intervals 2
  @session_window_tokens ~w(session primary five_hour hourly)
  @weekly_window_tokens ~w(weekly secondary seven_day)

  @spec snapshot() :: map()
  def snapshot do
    %{
      version: @version,
      fleet: fleet(),
      usage: provider_meters(),
      decisions: decisions()
    }
    |> external_value()
  end

  @spec fleet_agents([map()]) :: [map()]
  def fleet_agents(summaries) when is_list(summaries), do: Enum.map(summaries, &agent/1)

  @spec fleet() :: map()
  def fleet, do: %{agents: fleet_agents()} |> external_value()

  @doc "The render-ready grid projection carried alongside the channel fleet event."
  @spec grid() :: map()
  def grid do
    case safe_call(snapshot_fun(), %{}) do
      {status, snapshot, freshness} when status in [:current, :stale] and is_map(snapshot) ->
        snapshot |> StreamDeckGrid.project() |> Map.put(:snapshot_freshness, freshness)

      snapshot when is_map(snapshot) ->
        StreamDeckGrid.project(snapshot)

      _ ->
        StreamDeckGrid.project(%{})
    end
  end

  defp fleet_agents do
    case safe_call(snapshot_fun(), %{agents: []}) do
      %{agents: agents} when is_list(agents) -> fleet_agents(agents)
      {_status, %{running: running, retrying: retrying, idle: idle}, _freshness} -> snapshot_agents(running, retrying, idle)
      %{running: running, retrying: retrying, idle: idle} -> snapshot_agents(running, retrying, idle)
      _ -> []
    end
  end

  defp snapshot_agents(running, retrying, idle) do
    Enum.map(running, &agent(Map.put(&1, :status, :running))) ++
      Enum.map(retrying, &agent(Map.put(&1, :status, :retrying))) ++
      Enum.map(idle, &agent(Map.put(&1, :status, :queued)))
  end

  @spec agent(map()) :: map()
  def agent(summary) when is_map(summary) do
    %{
      identifier: field(summary, :identifier),
      status: field(summary, :status) || :unknown,
      alert_count: field(summary, :alert_count) || 0,
      title: field(summary, :title),
      runtime_seconds: field(summary, :runtime_seconds),
      turn_count: field(summary, :turn_count),
      work_state: field(summary, :work_state),
      pause_reason: field(summary, :pause_reason),
      tracker_paused: field(summary, :tracker_paused),
      backend: field(summary, :backend),
      model: field(summary, :model)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> external_value()
  end

  @spec provider_meters() :: map()
  def provider_meters do
    provider_meters_fun()
    |> safe_call(%{})
    |> provider_meters(DateTime.utc_now())
  end

  @doc false
  @spec provider_meters(map(), DateTime.t()) :: map()
  def provider_meters(meters, %DateTime{} = now) when is_map(meters) do
    CodingAgent.provider_families()
    |> Map.new(fn provider ->
      meter = field(meters, provider)
      {Atom.to_string(provider), normalize_provider_meter(provider, meter, now)}
    end)
    |> external_value()
  end

  @spec provider_meters(ProviderMeterSnapshot.t()) :: map()
  def provider_meters(%ProviderMeterSnapshot{} = snapshot), do: merge_provider_meter(provider_meters(), snapshot)

  @doc false
  @spec merge_provider_meter(map(), ProviderMeterSnapshot.t()) :: map()
  def merge_provider_meter(meters, %ProviderMeterSnapshot{provider: provider} = snapshot) do
    if provider in CodingAgent.provider_families() and newer_provider_observation?(snapshot, Map.get(meters, Atom.to_string(provider))) do
      meter = normalize_provider_meter(provider, provider_meter(snapshot), DateTime.utc_now()) |> external_value()
      Map.put(meters, Atom.to_string(provider), meter)
    else
      meters
    end
  end

  @spec decisions() :: map()
  def decisions, do: decisions_fun() |> safe_call(%{count: 0}) |> external_value()

  @spec transcript(String.t(), map()) :: map()
  def transcript(identifier, event) when is_binary(identifier) and is_map(event) do
    %{
      identifier: identifier,
      role: Map.get(event, :role),
      body: Map.get(event, :body),
      sequence: Map.get(event, :sequence),
      timestamp: Map.get(event, :timestamp)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> external_value()
  end

  @spec alert(String.t(), map()) :: map()
  def alert(identifier, event) when is_binary(identifier) and is_map(event) do
    %{
      identifier: identifier,
      name: field(event, :name),
      message: field(event, :message),
      severity: field(event, :severity),
      needs_attention: field(event, :needs_attention),
      timestamp: field(event, :timestamp)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> external_value()
  end

  @spec control(String.t(), map()) :: map()
  def control(identifier, payload) when is_binary(identifier) and is_map(payload) do
    %{
      identifier: identifier,
      state:
        %{
          action: field(payload, :action),
          status: field(payload, :status),
          requested_at: field(payload, :requested_at),
          accepted_at: field(payload, :accepted_at),
          applied_at: field(payload, :applied_at),
          rejected_at: field(payload, :rejected_at),
          expiry: field(payload, :expiry)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
    |> external_value()
  end

  defp snapshot_fun do
    endpoint_config(:streamdeck_snapshot_fun) || fn -> Orchestrator.dashboard_snapshot(orchestrator(), snapshot_timeout_ms()) end
  end

  defp provider_meters_fun do
    endpoint_config(:streamdeck_provider_meters_fun) || fn -> ProviderMeterProjection.snapshot() end
  end

  defp decisions_fun do
    endpoint_config(:streamdeck_decisions_fun) || fn -> %{count: DecisionMetrics.snapshots() |> map_size()} end
  end

  defp provider_meter(snapshot) do
    %{
      provider: snapshot.provider,
      state: if(is_nil(snapshot.observed_at), do: :unknown, else: :observed),
      observed_at: snapshot.observed_at,
      age_seconds: age_seconds(snapshot.observed_at),
      auth_mode: snapshot.auth_mode,
      plan: snapshot.plan,
      freshness: snapshot.freshness,
      health: snapshot.health,
      windows: snapshot.windows
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> external_value()
  end

  # The provider projection intentionally preserves backend-native limit IDs
  # (for example, `five_hour`/`seven_day` and `primary`/`secondary`). The
  # Stream Deck has two fixed physical meter positions, so it maps two distinct
  # rate-limit observations into its semantic Session/Weekly slots here. It
  # never invents a second value: a provider with one usable reading has one
  # populated slot and an explicitly unobserved other slot.
  defp normalize_provider_meter(provider, meter, now) when is_map(meter) do
    observed_at = meter |> field(:observed_at) |> datetime()
    freshness = meter_freshness(meter, observed_at, now)

    %{
      provider: provider,
      state: meter_state(meter, observed_at),
      observed_at: observed_at,
      age_seconds: age_seconds(observed_at, now),
      auth_mode: field(meter, :auth_mode),
      plan: field(meter, :plan),
      freshness: freshness,
      health: field(meter, :health),
      windows: normalized_windows(meter, observed_at, now, freshness)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_provider_meter(provider, _meter, _now) do
    %{provider: provider, state: :unknown, freshness: :unknown, windows: %{}}
  end

  defp meter_state(meter, _observed_at) do
    case field(meter, :state) do
      state when state in [:observed, "observed"] -> :observed
      _ -> :unknown
    end
  end

  defp normalized_windows(meter, provider_observed_at, now, provider_freshness) do
    meter
    |> field(:windows)
    |> rate_limit_windows()
    |> semantic_windows()
    |> Map.new(fn {slot, {_limit_id, window}} ->
      {slot, normalize_window(window, provider_observed_at, now, provider_freshness)}
    end)
  end

  defp rate_limit_windows(windows) when is_map(windows) do
    windows
    |> Enum.filter(fn {_limit_id, window} -> is_map(window) and field(window, :kind) in [:rate_limit, "rate_limit"] end)
    |> Enum.sort_by(fn {limit_id, window} -> {window_duration(window), to_string(limit_id)} end)
  end

  defp rate_limit_windows(_windows), do: []

  defp semantic_windows([]), do: []

  defp semantic_windows(windows) do
    session = Enum.find(windows, &window_matches?(&1, @session_window_tokens))
    weekly = windows |> List.delete(session) |> Enum.find(&window_matches?(&1, @weekly_window_tokens))
    remaining = unclassified_windows(windows) |> List.delete(session) |> List.delete(weekly)

    session = session || fallback_window(remaining, :shortest)
    weekly = weekly || remaining |> List.delete(session) |> fallback_window(:longest)

    [{"session", session}, {"weekly", weekly}]
    |> Enum.reject(fn {_slot, window} -> is_nil(window) end)
  end

  defp unclassified_windows(windows),
    do: Enum.reject(windows, &(window_matches?(&1, @session_window_tokens) or window_matches?(&1, @weekly_window_tokens)))

  defp window_matches?({limit_id, _window}, tokens) do
    limit_id
    |> to_string()
    |> String.downcase()
    |> then(&Enum.any?(tokens, fn token -> String.contains?(&1, token) end))
  end

  defp fallback_window([], _fallback), do: nil
  defp fallback_window(windows, :shortest), do: Enum.min_by(windows, fn {_limit_id, window} -> window_duration(window) end)
  defp fallback_window(windows, :longest), do: Enum.max_by(windows, fn {_limit_id, window} -> window_duration(window) end)

  defp window_duration(window) do
    case field(window, :duration_minutes) do
      minutes when is_integer(minutes) and minutes >= 0 -> minutes
      _ -> 0
    end
  end

  defp normalize_window(window, provider_observed_at, now, provider_freshness) do
    observed_at = window |> field(:observed_at) |> datetime() || provider_observed_at

    %{
      used_percent: field(window, :used_percent),
      remaining: field(window, :remaining),
      resets_at: window |> field(:resets_at) |> datetime(),
      observed_at: observed_at,
      age_seconds: age_seconds(observed_at, now),
      freshness: window_freshness(window, observed_at, now, provider_freshness)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp meter_freshness(meter, observed_at, now) do
    if stale?(observed_at, now) or field(meter, :freshness) in [:stale, "stale"] or field(field(meter, :health) || %{}, :state) in [:stale, "stale"] do
      :stale
    else
      case field(meter, :freshness) do
        freshness when freshness in [:fresh, "fresh"] -> :fresh
        freshness when freshness in [:partial, "partial"] -> :partial
        _ -> :unknown
      end
    end
  end

  defp window_freshness(window, observed_at, now, provider_freshness) do
    if provider_freshness == :stale or stale?(observed_at, now) or field(window, :freshness) in [:stale, "stale"] do
      :stale
    else
      case field(window, :freshness) do
        freshness when freshness in [:fresh, "fresh"] -> :fresh
        freshness when freshness in [:partial, "partial"] -> :partial
        _ -> :unknown
      end
    end
  end

  defp stale?(nil, _now), do: false
  defp stale?(observed_at, now), do: age_seconds(observed_at, now) > usage_interval_seconds() * @stale_after_intervals

  defp usage_interval_seconds do
    case Aiur.Config.settings() do
      {:ok, %{polling: %{usage_interval_seconds: seconds}}} when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_usage_interval_seconds
    end
  end

  defp newer_provider_observation?(%ProviderMeterSnapshot{observed_at: nil}, _current), do: false
  defp newer_provider_observation?(%ProviderMeterSnapshot{}, nil), do: true
  defp newer_provider_observation?(%ProviderMeterSnapshot{}, %{"observed_at" => nil}), do: true

  defp newer_provider_observation?(%ProviderMeterSnapshot{observed_at: observed_at}, %{"observed_at" => current_observed_at}) do
    case DateTime.from_iso8601(current_observed_at) do
      {:ok, current_observed_at, _offset} -> DateTime.compare(observed_at, current_observed_at) != :lt
      _ -> true
    end
  end

  defp newer_provider_observation?(%ProviderMeterSnapshot{}, _current), do: true

  defp age_seconds(nil), do: nil
  defp age_seconds(observed_at), do: age_seconds(observed_at, DateTime.utc_now())
  defp age_seconds(nil, _now), do: nil
  defp age_seconds(observed_at, now), do: DateTime.diff(now, observed_at) |> max(0)

  defp datetime(%DateTime{} = value), do: value

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime(_value), do: nil

  defp orchestrator, do: endpoint_config(:orchestrator) || Orchestrator
  defp snapshot_timeout_ms, do: endpoint_config(:snapshot_timeout_ms) || 15_000

  defp safe_call(fun, fallback) when is_function(fun, 0) do
    fun.()
  rescue
    _error -> fallback
  catch
    :exit, _reason -> fallback
  end

  defp external_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp external_value(nil), do: nil
  defp external_value(value) when is_boolean(value), do: value
  defp external_value(value) when is_atom(value), do: Atom.to_string(value)
  defp external_value(value) when is_list(value), do: Enum.map(value, &external_value/1)

  defp external_value(value) when is_map(value) do
    value
    |> maybe_from_struct()
    |> Map.new(fn {key, nested} -> {to_string(key), external_value(nested)} end)
  end

  defp external_value(value), do: value

  defp maybe_from_struct(value) do
    if is_struct(value), do: Map.from_struct(value), else: value
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp endpoint_config(key) do
    Endpoint.config(key) || Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  rescue
    _error -> Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  end
end
