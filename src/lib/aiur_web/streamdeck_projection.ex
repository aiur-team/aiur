defmodule AiurWeb.StreamdeckProjection do
  @moduledoc false

  alias Aiur.{CodingAgent, DecisionMetrics, Orchestrator, ProviderMeterProjection, ProviderMeterSnapshot}
  alias AiurWeb.Endpoint

  @version 1

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
  def provider_meters, do: provider_meters_fun() |> safe_call(%{}) |> external_value()

  @spec provider_meters(ProviderMeterSnapshot.t()) :: map()
  def provider_meters(%ProviderMeterSnapshot{} = snapshot), do: merge_provider_meter(provider_meters(), snapshot)

  @doc false
  @spec merge_provider_meter(map(), ProviderMeterSnapshot.t()) :: map()
  def merge_provider_meter(meters, %ProviderMeterSnapshot{provider: provider} = snapshot) do
    if provider in CodingAgent.provider_families() and newer_provider_observation?(snapshot, Map.get(meters, Atom.to_string(provider))) do
      Map.put(meters, Atom.to_string(provider), provider_meter(snapshot))
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
  defp age_seconds(observed_at), do: DateTime.diff(DateTime.utc_now(), observed_at) |> max(0)

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
