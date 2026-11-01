defmodule AiurWeb.OperatorControlCenter.Analytics.Prewarmer do
  @moduledoc "Warms the retained latest-run projection at boot and after summary changes."
  use GenServer

  alias Aiur.RunTelemetry.RetainedCache
  alias AiurWeb.OperatorControlCenter.Analytics.Runtime

  @check_interval_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    if Keyword.get(opts, :prewarm_on_start, true), do: send(self(), :check_identity)

    {:ok,
     %{
       identity: nil,
       refresh: nil,
       refresh_identity: nil,
       prewarm_fun: Keyword.get(opts, :prewarm_fun, &Runtime.prewarm/0),
       bound_port_fun: Keyword.get(opts, :bound_port_fun, &Aiur.HttpServer.bound_port/0),
       http_unavailable_logged?: false
     }}
  end

  @impl true
  def handle_info(:check_identity, state) do
    state = if http_server_running?(state), do: prewarm_identity(state), else: warn_http_unavailable(state)

    Process.send_after(self(), :check_identity, @check_interval_ms)
    {:noreply, state}
  end

  def handle_info({ref, _result}, %{refresh: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, refresh_finished(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refresh: ref} = state) do
    {:noreply, %{refresh_finished(state) | identity: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_refresh(%{refresh: refresh} = state) when not is_nil(refresh), do: state

  defp start_refresh(state) do
    task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, state.prewarm_fun)
    %{state | refresh: task.ref, refresh_identity: state.identity}
  end

  defp refresh_finished(state) do
    identity = if state.identity == state.refresh_identity, do: state.identity, else: nil
    %{state | identity: identity, refresh: nil, refresh_identity: nil}
  end

  defp prewarm_identity(state) do
    identity = RetainedCache.identity(Aiur.RunTelemetry.boot_id())
    if identity != state.identity, do: start_refresh(%{state | identity: identity}), else: state
  end

  defp http_server_running?(state), do: is_integer(state.bound_port_fun.())

  defp warn_http_unavailable(state) do
    if not Map.get(state, :http_unavailable_logged?, false) do
      require Logger
      Logger.warning("Analytics prewarm skipped because the dashboard HTTP server is unavailable")
    end

    Map.put(state, :http_unavailable_logged?, true)
  end
end
