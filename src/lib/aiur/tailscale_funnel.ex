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

  @spec child_spec(keyword()) :: Supervisor.child_spec()
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

    with {:ok, status} <- command(["funnel", "status", "--json"], opts),
         {:ok, current_target} <- funnel_target(status),
         :ok <- maybe_update(current_target, target, opts),
         {:ok, verified_status} <- command(["funnel", "status", "--json"], opts),
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

  def funnel_target(%{"AllowFunnel" => allow_funnel} = status) when is_map(allow_funnel) do
    listeners =
      for {listener, true} <- allow_funnel,
          is_binary(listener),
          String.ends_with?(listener, ":#{@https_port}"),
          do: listener

    case listeners do
      [] ->
        {:error, :funnel_443_not_enabled}

      [listener] ->
        web = Map.get(status, "Web", %{})
        proxy = if is_map(web), do: get_in(web, [listener, "Handlers", "/", "Proxy"])

        case proxy do
          target when is_binary(target) -> {:ok, target}
          _other -> {:error, :funnel_443_root_proxy_missing}
        end

      _multiple ->
        {:error, :multiple_funnel_443_routes}
    end
  end

  def funnel_target(_status), do: {:error, :invalid_status_shape}

  @doc false
  @spec command([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(args, opts \\ []) do
    executable = Keyword.get_lazy(opts, :tailscale_executable, fn -> System.find_executable("tailscale") end)
    runner = Keyword.get(opts, :tailscale_runner, &run_tailscale/3)
    timeout_ms = Keyword.get(opts, :timeout_ms, @command_timeout_ms)

    case executable do
      nil ->
        {:error, :tailscale_executable_not_found}

      executable ->
        case safe_tailscale_run(runner, executable, args, timeout_ms) do
          {output, 0} when is_binary(output) -> {:ok, output}
          {_output, status} when is_integer(status) -> {:error, {:tailscale_exit, status}}
          {:error, :timeout} -> {:error, :tailscale_timeout}
          {:error, reason} -> {:error, reason}
          _other -> {:error, :invalid_tailscale_result}
        end
    end
  end

  defp maybe_update(target, target, _opts), do: :ok

  defp maybe_update(_current_target, target, opts) do
    case command(["funnel", "--bg", "--https=#{@https_port}", "--yes", target], opts) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp safe_tailscale_run(runner, executable, args, timeout_ms) do
    runner.(executable, args, timeout_ms)
  rescue
    error -> {:error, {:tailscale_runner_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:tailscale_runner_exit, reason}}
  end

  defp run_tailscale(executable, args, timeout_ms) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        {:args, Enum.map(args, &String.to_charlist/1)}
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_tailscale_output(port, deadline, [])
  end

  defp collect_tailscale_output(port, deadline, output) do
    receive do
      {^port, {:data, chunk}} ->
        collect_tailscale_output(port, deadline, [chunk | output])

      {^port, {:exit_status, status}} ->
        {output |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        terminate_tailscale_process(port)
        flush_tailscale_messages(port)
        {:error, :timeout}
    end
  end

  defp terminate_tailscale_process(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        case System.find_executable("kill") do
          nil -> :ok
          kill -> System.cmd(kill, ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        end

      nil ->
        :ok
    end

    close_tailscale_port(port)
  end

  defp close_tailscale_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp flush_tailscale_messages(port) do
    receive do
      {^port, _message} -> flush_tailscale_messages(port)
    after
      0 -> :ok
    end
  end

  defp url_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[#{host}]"
    else
      host
    end
  end

  defp format_reason({:tailscale_exit, status}), do: "tailscale exited with status #{status}; will retry"
  defp format_reason(:tailscale_timeout), do: "tailscale command timed out; will retry"
  defp format_reason(:tailscale_executable_not_found), do: "tailscale executable not found; install Tailscale CLI"
  defp format_reason(:funnel_443_not_enabled), do: "no operator-enabled HTTPS 443 Funnel route exists"
  defp format_reason(:dashboard_listener_not_bound), do: "dashboard listener is not bound; will retry"
  defp format_reason(reason), do: inspect(reason)
end
