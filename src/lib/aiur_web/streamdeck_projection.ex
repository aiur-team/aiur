defmodule AiurWeb.StreamdeckProjection do
  @moduledoc false
  alias Aiur.{CodingAgent, Commands, Config, Orchestrator, PollCadence, ProviderMeterProjection, ProviderMeterSnapshot}
  import AiurWeb.StreamdeckProjection.Meters, only: [age_seconds: 1, field: 2, normalize_provider_meter: 3]

  alias AiurWeb.{Endpoint, StreamdeckFleet}

  @version 1
  @voice_unconfigured_reason "Aiur has no ElevenLabs API key - transcription is off"

  @spec snapshot() :: map()
  def snapshot do
    snapshot = safe_call(snapshot_fun(), %{})

    %{
      version: @version,
      fleet: fleet(snapshot),
      grid: grid(snapshot),
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
  @spec fleet(term()) :: map()
  def fleet(snapshot \\ safe_call(snapshot_fun(), %{})), do: StreamdeckFleet.fleet(snapshot)

  @spec grid() :: map()
  @spec grid(term()) :: map()
  def grid(snapshot \\ safe_call(snapshot_fun(), %{})), do: StreamdeckFleet.grid(snapshot)

  @spec fleet_with_grid([map()] | nil) :: map()
  def fleet_with_grid(summaries) do
    snapshot_fun() |> safe_call(:unavailable) |> StreamdeckFleet.with_grid(summaries)
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
      model: field(summary, :model) || field(summary, :requested_model)
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
    if provider in CodingAgent.provider_families() and AiurWeb.StreamdeckMeterRetention.newer?(snapshot, Map.get(meters, Atom.to_string(provider))) do
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
    endpoint_config(:streamdeck_decisions_fun) || fn -> %{count: Commands.metrics_snapshots() |> map_size()} end
  end

  defp provider_meter(snapshot) do
    %{
      summary_label: snapshot.summary_label,
      ingested_at: snapshot.ingested_at,
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

  defp orchestrator, do: endpoint_config(:orchestrator) || Orchestrator
  # The configured value is the floor, not the tolerance: a fixed 15s window
  # against a 120s poll marks a healthy fleet stale for most of every cycle.
  # See `Aiur.PollCadence.snapshot_tolerance_ms/1`.
  defp snapshot_timeout_ms, do: PollCadence.snapshot_tolerance_ms(endpoint_config(:snapshot_timeout_ms) || 15_000, class: :dispatch)

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

  defp endpoint_config(key) do
    Endpoint.config(key) || Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  rescue
    _error -> Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  end
end
