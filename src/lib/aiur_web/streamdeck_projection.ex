defmodule AiurWeb.StreamdeckProjection do
  @moduledoc false
  alias Aiur.Commands
  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2]

  alias AiurWeb.{Endpoint, EndpointConfig, StreamdeckFleet}
  alias AiurWeb.Streamdeck.Deck.Meters

  @voice_not_installed_reason "Voice isn't installed in this Aiur"
  @version 1
  @voice_unconfigured_reason "Aiur has no ElevenLabs API key - transcription is off"

  @spec snapshot() :: map()
  def snapshot do
    grid = grid()
    snapshot = safe_call(snapshot_fun(grid), %{})

    %{
      version: @version,
      fleet: StreamdeckFleet.fleet(snapshot),
      grid: grid,
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
    case Aiur.Voice.availability() do
      %{available: true} -> %{available: true, reason: nil}
      %{reason: :unconfigured} -> %{available: false, reason: @voice_unconfigured_reason}
      %{reason: :not_installed} -> %{available: false, reason: @voice_not_installed_reason}
    end
  end

  @spec fleet_agents([map()]) :: [map()]
  def fleet_agents(summaries) when is_list(summaries), do: Enum.map(summaries, &agent/1)

  @spec grid() :: map()
  @spec grid(term()) :: map()
  def grid(snapshot \\ nil), do: StreamdeckFleet.grid(snapshot)

  @spec fleet_with_grid([map()] | nil) :: map()
  def fleet_with_grid(summaries) do
    grid = grid()
    snapshot = safe_call(snapshot_fun(grid), :unavailable)
    StreamdeckFleet.with_grid(snapshot, summaries, grid)
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
    Meters.read()
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

  defp snapshot_fun(grid) do
    endpoint_config(:streamdeck_snapshot_fun) || fn -> %{agents: grid.agents} end
  end

  defp decisions_fun do
    endpoint_config(:streamdeck_decisions_fun) || fn -> %{count: Commands.metrics_snapshots() |> map_size()} end
  end

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
    EndpointConfig.get(key) || Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  rescue
    _error -> Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  end
end
