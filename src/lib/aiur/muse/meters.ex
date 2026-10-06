defmodule Aiur.Muse.Meters do
  @moduledoc "Connects native Muse host observations to the display-only meter owner."

  alias Aiur.Muse.{MeterProbe, Transport}
  alias Aiur.ProviderMeters.HostObservations

  @spec attach(map()) :: map()
  def attach(session) do
    case HostObservations.attach(:muse, :app_server, self()) do
      {:ok, scope} -> Map.put(session, :meter_scope, scope)
      {:error, _reason} -> session
    end
  catch
    :exit, _reason -> session
  end

  @spec refresh(map(), keyword()) :: :ok
  def refresh(session, opts \\ [])

  def refresh(%{meter_scope: scope, port: port}, opts) do
    frame = %{"jsonrpc" => "2.0", "id" => System.unique_integer([:positive]), "method" => "usage/read", "params" => %{}}
    timeout = Keyword.get(opts, :timeout_ms, 1_000)

    request = fn "usage/read" ->
      Transport.request(port, frame, timeout, fn notification -> send(self(), {:muse_prestart, notification}) end)
    end

    case MeterProbe.read(request, scope) do
      {:ok, observation} -> HostObservations.observe(scope, observation)
      {:error, reason} -> HostObservations.fail(scope, reason)
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
  def retire(%{meter_scope: scope}) do
    HostObservations.retire(scope)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def retire(_session), do: :ok
end
