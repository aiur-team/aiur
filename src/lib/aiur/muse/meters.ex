defmodule Aiur.Muse.Meters do
  @moduledoc "Connects native Muse host observations to the display-only meter owner."

  alias Aiur.Muse.{MeterProbe, Transport}
  alias Aiur.ProviderMeters.HostObservations

  @spec attach(map()) :: map()
  def attach(session), do: attach(session, HostObservations)

  @spec attach(map(), module()) :: map()
  def attach(session, host_observations) do
    case host_observations.attach(:muse, :app_server, self()) do
      {:ok, scope} ->
        session
        |> Map.put(:meter_scope, scope)
        |> Map.put(:host_observations, host_observations)

      {:error, _reason} ->
        session
    end
  catch
    :exit, _reason -> session
  end

  @spec refresh(map(), keyword()) :: :ok
  def refresh(session, opts \\ [])

  def refresh(%{meter_scope: scope, port: port} = session, opts) do
    frame = %{"jsonrpc" => "2.0", "id" => System.unique_integer([:positive]), "method" => "usage/read", "params" => %{}}
    timeout = Keyword.get(opts, :timeout_ms, 1_000)

    request = fn "usage/read" ->
      Transport.request(port, frame, timeout, fn notification -> send(self(), {:muse_prestart, notification}) end)
    end

    case MeterProbe.read(request, scope) do
      {:ok, observation} -> host_observations(session).observe(scope, observation)
      {:error, reason} -> host_observations(session).fail(scope, reason)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  def refresh(_session, _opts), do: :ok

  @spec observe(map(), map()) :: :ok
  def observe(%{meter_scope: scope}, %{"method" => "usage/changed"} = frame) do
    case MeterProbe.normalize_changed(frame, scope) do
      {:ok, observation} -> HostObservations.observe(scope, observation)
      {:error, reason} -> HostObservations.fail(scope, reason)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  def observe(_session, _frame), do: :ok

  @spec retire(map()) :: :ok
  def retire(%{meter_scope: scope} = session) do
    host_observations(session).retire(scope)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def retire(_session), do: :ok

  defp host_observations(session), do: Map.get(session, :host_observations, HostObservations)
end
