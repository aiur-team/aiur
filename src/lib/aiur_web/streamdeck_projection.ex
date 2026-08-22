defmodule AiurWeb.StreamdeckProjection do
  @moduledoc false

  alias Aiur.{CodingAgent, Config, DecisionMetrics, ModelAvailability, Orchestrator, PollCadence, ProviderMeterProjection, ProviderMeterSnapshot}
  alias AiurWeb.{Endpoint, StreamDeckGrid}

  @version 1
  @voice_unconfigured_reason "Aiur has no ElevenLabs API key - transcription is off"
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
      decisions: decisions(),
      voice: voice()
    }
    |> external_value()
  end

  @doc """
  Whether voice input can transcribe, and why not when it cannot.

  The device carries this in the join snapshot so the microphone key can say why
  it is off without a round trip. Only the *presence* of a credential is ever
  reported — never the credential, nor any part of it.
  """
  @spec voice() :: map()
  def voice do
    if configured_elevenlabs_key?() do
      %{available: true, reason: nil}
    else
      %{available: false, reason: @voice_unconfigured_reason}
    end
  end

  # The seam injects the *answer*, never the credential: it is a boolean reader,
  # so no configuration key anywhere can be made to carry an API key into this
  # projection. An unreadable configuration reads as "not configured", which is
  # the honest answer — a key that cannot be read cannot be used.
  defp configured_elevenlabs_key? do
    case endpoint_config(:streamdeck_voice_available_fun) do
      fun when is_function(fun, 0) -> fun.() == true
      _absent -> present?(Config.elevenlabs_api_key())
    end
  rescue
    _unavailable -> false
  catch
    _kind, _reason -> false
  end

  defp present?(key) when is_binary(key), do: String.trim(key) != ""
  defp present?(_key), do: false

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
    state = meter_state(meter, observed_at)

    normalized =
      %{
        provider: provider,
        state: state,
        observed_at: observed_at,
        age_seconds: age_seconds(observed_at, now),
        auth_mode: field(meter, :auth_mode),
        plan: field(meter, :plan),
        freshness: freshness,
        health: field(meter, :health),
        windows: normalized_windows(provider, meter, observed_at, now, freshness)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if state == :unknown, do: maybe_attach_durable(normalized, provider, now), else: normalized
  end

  defp normalize_provider_meter(provider, _meter, now) do
    %{provider: provider, state: :unknown, freshness: :unknown, windows: %{}}
    |> maybe_attach_durable(provider, now)
  end

  # A provider that has never been observed this boot reads `:unknown` on the
  # deck, exactly like the dashboard's cards do before `put_durable_observation`
  # attaches the last-known standing from the durable dispatch-limits ledger
  # (`Aiur.ModelAvailability`, `model-usage.json`). The deck had no equivalent,
  # so a provider the dashboard read as, say, 99% used rendered as a permanent
  # "Awaiting data" on the strip — the two surfaces disagreeing about the same
  # account (#2185). Attach the same durable record here: the value is a real
  # last-known used% (marked stale, never live), and a later real observation
  # replaces it because this branch only runs for an unobserved meter.
  defp maybe_attach_durable(meter, provider, now) do
    case durable_window(provider, now) do
      %{} = window ->
        meter
        |> Map.merge(%{
          state: :observed,
          observed_at: window.observed_at,
          age_seconds: window.age_seconds,
          freshness: :stale,
          health: %{state: :stale, failure: nil},
          windows: %{"session" => window}
        })

      nil ->
        meter
    end
  end

  # The ledger's governing bucket becomes the deck's session slot (the primary
  # one both the emulator and the sidecar render). It carries no reliable reset
  # instant and is stale by construction, mirroring the dashboard's durable meta
  # line ("99% used · as of HH:MM UTC (stale)").
  defp durable_window(provider, now) do
    case durable_observation(provider) do
      %{percent: percent, observed_at: %DateTime{} = observed_at} when is_number(percent) ->
        %{
          used_percent: percent,
          observed_at: observed_at,
          age_seconds: age_seconds(observed_at, now),
          freshness: :stale
        }

      _ ->
        nil
    end
  end

  defp durable_observation(provider) do
    with %{"backends" => backends} <- ModelAvailability.load(),
         %{} = entry when map_size(entry) > 0 <- Map.get(backends, Atom.to_string(provider)),
         %{percent: percent} <- durable_percent_entry(entry) do
      %{percent: percent, observed_at: durable_observed_at(Map.get(entry, "observed_at"))}
    else
      _ -> nil
    end
  end

  defp durable_percent_entry(entry) do
    entry
    |> Map.take(~w(hourly weekly monthly))
    |> Enum.map(fn {_window, %{"used" => used, "limit" => limit}} when is_number(used) and is_number(limit) and limit > 0 ->
      %{percent: min(round(used / limit * 100), 100)}
    end)
    |> Enum.max_by(& &1.percent, fn -> nil end)
  end

  defp durable_observed_at(%DateTime{} = value), do: value

  defp durable_observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp durable_observed_at(_value), do: nil

  defp meter_state(meter, _observed_at) do
    case field(meter, :state) do
      state when state in [:observed, "observed"] -> :observed
      _ -> :unknown
    end
  end

  defp normalized_windows(provider, meter, provider_observed_at, now, provider_freshness) do
    meter
    |> field(:windows)
    |> meter_windows(provider)
    |> semantic_windows()
    |> Map.new(fn {slot, {_limit_id, window}} ->
      {slot, normalize_window(window, provider_observed_at, now, provider_freshness)}
    end)
  end

  # The dashboard shows prepaid credit windows for every provider except Codex,
  # whose credit facts are account capabilities rather than a dollar balance.
  # Keep the same distinction here so both surfaces describe the same account
  # standing. A credit window is governing, so `semantic_windows/1` gives it
  # the primary Session position on the two-slot deck.
  defp meter_windows(windows, provider) when is_map(windows) do
    windows
    |> Enum.filter(&eligible_window?(&1, provider))
    |> Enum.sort_by(fn {limit_id, window} -> {window_duration(window), to_string(limit_id)} end)
  end

  defp meter_windows(_windows, _provider), do: []

  defp eligible_window?({limit_id, window}, provider) when is_map(window) do
    if to_string(field(window, :limit_id) || limit_id) == "local-concurrency" do
      false
    else
      case field(window, :kind) do
        kind when kind in [:rate_limit, "rate_limit"] -> true
        kind when kind in [:credit, "credit"] -> provider != :codex
        _kind -> false
      end
    end
  end

  defp eligible_window?(_entry, _provider), do: false

  defp semantic_windows([]), do: []

  defp semantic_windows(windows) do
    session = Enum.find(windows, &credit_window?/1) || Enum.find(windows, &window_matches?(&1, @session_window_tokens))
    weekly = windows |> List.delete(session) |> Enum.find(&window_matches?(&1, @weekly_window_tokens))
    remaining = windows |> unclassified_windows() |> List.delete(session) |> List.delete(weekly)

    session = session || fallback_window(remaining, :shortest)
    weekly = weekly || remaining |> List.delete(session) |> fallback_window(:longest)

    [{"session", session}, {"weekly", weekly}]
    |> Enum.reject(fn {_slot, window} -> is_nil(window) end)
  end

  defp credit_window?({_limit_id, window}), do: field(window, :kind) in [:credit, "credit"]

  defp unclassified_windows(windows) do
    Enum.reject(windows, fn window ->
      credit_window?(window) or window_matches?(window, @session_window_tokens) or window_matches?(window, @weekly_window_tokens)
    end)
  end

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
  # The configured value is the floor, not the tolerance: a fixed 15s window
  # against a 120s poll marks a healthy fleet stale for most of every cycle.
  # See `Aiur.PollCadence.snapshot_tolerance_ms/1`.
  defp snapshot_timeout_ms, do: PollCadence.snapshot_tolerance_ms(endpoint_config(:snapshot_timeout_ms) || 15_000)

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
