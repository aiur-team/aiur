defmodule Aiur.TailscaleFunnel do
  @moduledoc """
  Keeps an explicitly enabled Tailscale Funnel pointed at the live dashboard port.

  The operator owns enabling Funnel and setting `server.tailscale_funnel`. Once
  enabled, this worker reconciles the existing HTTPS 443 route after startup and
  periodically, because `server.port: 0` may select a new port on every boot.
  """

  use GenServer
  require Logger

  alias Aiur.{Config, HttpServer}

  @interval_ms 30_000
  @command_timeout_ms 5_000
  @https_port 443

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    send(self(), :reconcile)
    {:ok, %{opts: opts, last_failure: nil}}
  end

  @impl true
  def handle_info(:reconcile, %{opts: opts} = state) do
    port_fun = Keyword.get(opts, :port_fun, &HttpServer.bound_port/0)
    host_fun = Keyword.get(opts, :host_fun, &Config.server_host/0)

    result =
      case {host_fun.(), port_fun.()} do
        {host, port} when is_binary(host) and is_integer(port) and port > 0 ->
          reconcile(host, port, opts)

        _ ->
          {:error, :dashboard_listener_not_bound}
      end

    new_state = report_result(result, state)
    Process.send_after(self(), :reconcile, Keyword.get(opts, :interval_ms, @interval_ms))
    {:noreply, new_state}
  rescue
    error ->
      new_state = report_result({:error, {:reconciliation_exception, Exception.message(error)}}, state)
      Process.send_after(self(), :reconcile, Keyword.get(opts, :interval_ms, @interval_ms))
      {:noreply, new_state}
  end

  defp report_result(:ok, %{last_failure: nil} = state), do: state

  defp report_result(:ok, %{last_failure: reason} = state) do
    Logger.info("Tailscale Funnel dashboard reconciliation recovered after: #{format_reason(reason)}")
    %{state | last_failure: nil}
  end

  defp report_result({:error, reason}, %{last_failure: reason} = state), do: state

  defp report_result({:error, reason}, state) do
    Logger.warning("Tailscale Funnel dashboard reconciliation failed: #{format_reason(reason)}")
    %{state | last_failure: reason}
  end

  defp report_result(_other, state), do: state

  @doc false
  @spec reconcile(String.t(), pos_integer(), keyword()) :: :ok | {:error, term()}
  def reconcile(host, port, opts \\ []) when is_binary(host) and is_integer(port) and port > 0 do
    target = "http://#{url_host(host)}:#{port}"
    command_fun = Keyword.get(opts, :command_fun, &run_tailscale/1)

    with {:ok, status} <- command(command_fun, ["funnel", "status", "--json"]),
         {:ok, current_target} <- funnel_target(status),
         :ok <- maybe_update(current_target, target, command_fun),
         {:ok, verified_status} <- command(command_fun, ["funnel", "status", "--json"]),
         {:ok, ^target} <- funnel_target(verified_status) do
      :ok
    else
      {:ok, other} -> {:error, {:target_verification_failed, other}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec funnel_target(map() | String.t()) :: {:ok, String.t()} | {:error, term()}
  def funnel_target(status) when is_binary(status) do
    case Jason.decode(status) do
      {:ok, decoded} -> funnel_target(decoded)
      {:error, _reason} -> {:error, :invalid_status_json}
    end
  end

  def funnel_target(status) when is_map(status) do
    allow_funnel = Map.get(status, "AllowFunnel", %{})
    web = Map.get(status, "Web", %{})

    routes =
      for {listener, true} <- allow_funnel,
          String.ends_with?(listener, ":#{@https_port}"),
          route = Map.get(web, listener),
          is_map(route),
          do: route

    case routes do
      [%{"Handlers" => %{"/" => %{"Proxy" => target}}}] when is_binary(target) -> {:ok, target}
      [] -> {:error, :funnel_443_not_enabled}
      [_] -> {:error, :funnel_443_root_proxy_missing}
      _ -> {:error, :multiple_funnel_443_routes}
    end
  end

  def funnel_target(_status), do: {:error, :invalid_status_shape}

  defp maybe_update(target, target, _command_fun), do: :ok

  defp maybe_update(_current_target, target, command_fun) do
    case command(command_fun, ["funnel", "--bg", "--https=#{@https_port}", "--yes", target]) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp command(command_fun, args) do
    case command_fun.(args) do
      {output, 0} when is_binary(output) -> {:ok, output}
      {output, status} when is_binary(output) -> {:error, {:command_failed, status, output}}
      other -> {:error, {:invalid_command_result, other}}
    end
  rescue
    error -> {:error, {:command_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:command_exit, reason}}
  end

  defp run_tailscale(args) do
    executable = System.find_executable("tailscale")

    if executable do
      task = Task.async(fn -> System.cmd(executable, args, stderr_to_stdout: true) end)

      case Task.yield(task, @command_timeout_ms) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {inspect(reason), 1}

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          {"tailscale command timed out", 124}
      end
    else
      {"tailscale executable not found", 127}
    end
  end

  defp url_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[#{host}]"
    else
      host
    end
  end

  defp format_reason({:command_failed, 127, _output}), do: "tailscale executable not found; install Tailscale CLI"
  defp format_reason({:command_failed, 124, _output}), do: "tailscale command timed out; will retry"
  defp format_reason({:command_failed, status, _output}), do: "tailscale exited with status #{status}; will retry"
  defp format_reason(:funnel_443_not_enabled), do: "no operator-enabled HTTPS 443 Funnel route exists"
  defp format_reason(:dashboard_listener_not_bound), do: "dashboard listener is not bound; will retry"
  defp format_reason(reason), do: inspect(reason)
end
