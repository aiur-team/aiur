defmodule Aiur.BuildOrderFunnelHealth do
  @moduledoc """
  Opt-in health check for Build Order endpoint reachability and its persisted
  Tailscale Funnel target.

  The caller runs this after dashboard startup only when
  `observability.build_order_funnel_health_check` is enabled. The local HTTP
  probe and Tailscale status command are both bounded by the configured
  timeout. Missing Tailscale/Funnel configuration is treated as not configured;
  malformed or failed status reads retain a neutral cause and a separate reason.
  """

  alias Aiur.{Alerts, HttpServer}

  @default_timeout_ms 5_000
  @healthy_statuses [200, 301, 302, 304, 307, 308, 401]

  @type port_number :: non_neg_integer()
  @type failure :: %{cause: atom(), reasons: [term()]}
  @type check_result :: {:ok, port_number()} | {:error, failure()}

  @doc """
  Check the bound Build Order endpoint and compare the configured Funnel HTTPS
  443 proxy target with its current port. HTTP 200, redirects 301/302/304/307/308,
  and 401 (authentication required) are considered reachable.

  `:http_client`, `:tailscale_runner`, and `:alert` are injectable adapters for
  deterministic tests. The Tailscale command is bounded by `:timeout_ms`.
  """
  @spec check(keyword()) :: check_result()
  def check(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    port = Keyword.get_lazy(opts, :bound_port, &HttpServer.bound_port/0)
    http_client = Keyword.get(opts, :http_client, &fetch_endpoint/2)

    case build_order_endpoint_reachable?(port, timeout_ms, http_client) do
      {:ok, port} ->
        case funnel_status(opts, port, timeout_ms) do
          :ok ->
            {:ok, port}

          :not_configured ->
            {:ok, port}

          {:error, failure} = error ->
            report_failure(failure, port, opts)
            error
        end

      {:error, failure} = error ->
        report_failure(failure, port, opts)
        error
    end
  end

  @doc false
  @spec funnel_target_status(map(), port_number()) :: :ok | :not_configured | {:error, failure()}
  def funnel_target_status(status, bound_port) when is_map(status) do
    case configured_funnel_proxy(status) do
      :not_configured ->
        :not_configured

      {:ok, proxy} ->
        funnel_proxy_status(proxy, bound_port)

      {:error, reason} ->
        unknown_failure(reason)
    end
  end

  def funnel_target_status(_status, _bound_port), do: unknown_failure(:invalid_funnel_status)

  defp funnel_status(opts, bound_port, timeout_ms) do
    case Keyword.fetch(opts, :funnel_status) do
      {:ok, status} ->
        funnel_target_status(status, bound_port)

      :error ->
        read_funnel_status(bound_port, timeout_ms, opts)
    end
  end

  defp read_funnel_status(bound_port, timeout_ms, opts) do
    case Keyword.get_lazy(opts, :tailscale_executable, fn -> System.find_executable("tailscale") end) do
      nil ->
        :not_configured

      executable ->
        runner = Keyword.get(opts, :tailscale_runner, &run_tailscale/3)

        case safe_tailscale_run(runner, executable, timeout_ms) do
          {output, 0} when is_binary(output) ->
            decode_funnel_status(output, bound_port)

          {_output, exit_status} when is_integer(exit_status) ->
            unknown_failure({:tailscale_exit, exit_status})

          {:error, :timeout} ->
            unknown_failure(:tailscale_status_timeout)

          {:error, reason} ->
            unknown_failure(reason)

          _other ->
            unknown_failure(:invalid_tailscale_result)
        end
    end
  end

  defp safe_tailscale_run(runner, executable, timeout_ms) do
    runner.(executable, ["funnel", "status", "--json"], timeout_ms)
  rescue
    exception ->
      {:error, {:tailscale_runner_exception, exception.__struct__}}
  catch
    kind, reason ->
      {:error, {:tailscale_runner_exit, kind, reason}}
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
        safe_close_tailscale_port(port)
        flush_tailscale_messages(port)
        {:error, :timeout}
    end
  end

  defp safe_close_tailscale_port(port) do
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

  defp decode_funnel_status(output, bound_port) do
    case Jason.decode(output) do
      {:ok, status} when is_map(status) -> funnel_target_status(status, bound_port)
      {:ok, _other} -> unknown_failure(:invalid_funnel_status_shape)
      {:error, _reason} -> unknown_failure(:invalid_funnel_status_json)
    end
  end

  defp configured_funnel_proxy(%{"AllowFunnel" => allow_funnel} = status) when is_map(allow_funnel) do
    if Enum.any?(allow_funnel, fn {_target, enabled?} -> enabled? == true end) do
      funnel_https_proxy(status)
    else
      :not_configured
    end
  end

  defp configured_funnel_proxy(_status), do: {:error, :missing_allow_funnel_status}

  defp funnel_https_proxy(%{"Web" => web}) when is_map(web) do
    target = Enum.find(Map.keys(web), &(is_binary(&1) and String.ends_with?(&1, ":443")))

    case target do
      nil ->
        {:error, :https_443_target_missing}

      _target ->
        case get_in(web, [target, "Handlers", "/", "Proxy"]) do
          proxy when is_binary(proxy) -> {:ok, proxy}
          _other -> {:error, :root_proxy_handler_missing}
        end
    end
  end

  defp funnel_https_proxy(_status), do: {:error, :web_status_missing}

  defp funnel_proxy_status(proxy, bound_port) do
    case URI.parse(proxy) do
      %URI{scheme: scheme, port: target_port} when scheme in ["http", "https"] and is_integer(target_port) ->
        if target_port == bound_port do
          :ok
        else
          {:error, %{cause: :funnel_target_mismatch, reasons: [{:target_port, target_port}]}}
        end

      _other ->
        unknown_failure(:invalid_funnel_proxy_url)
    end
  end

  defp build_order_endpoint_reachable?(port, timeout_ms, http_client)
       when is_integer(port) and port > 0 do
    url = "http://127.0.0.1:#{port}/build-orders/1"

    case safe_http_request(http_client, url, timeout_ms) do
      {:ok, %Req.Response{status: status}} when status in @healthy_statuses ->
        {:ok, port}

      {:ok, %Req.Response{status: status}} ->
        {:error, %{cause: :unreachable, reasons: [{:http_status, status}]}}

      {:error, :timeout} ->
        {:error, %{cause: :timeout, reasons: [{:transport, :timeout}]}}

      {:error, %{reason: :timeout}} ->
        {:error, %{cause: :timeout, reasons: [{:transport, :timeout}]}}

      {:error, %{cause: _cause} = failure} ->
        {:error, failure}

      {:error, reason} ->
        unknown_failure(transport_failure_reason(reason))

      _other ->
        unknown_failure(:invalid_http_client_result)
    end
  end

  defp build_order_endpoint_reachable?(_port, _timeout_ms, _http_client),
    do: unknown_failure(:dashboard_not_bound)

  defp fetch_endpoint(url, timeout_ms) do
    Req.get(url, receive_timeout: timeout_ms, retry: false)
  end

  defp safe_http_request(http_client, url, timeout_ms) do
    http_client.(url, timeout_ms)
  rescue
    exception ->
      unknown_failure({:http_client_exception, exception.__struct__})
  catch
    kind, reason ->
      unknown_failure({:http_client_exit, kind, reason})
  end

  defp transport_failure_reason(%{__struct__: module, reason: reason}) do
    {:transport, module, reason}
  end

  defp transport_failure_reason(reason), do: {:transport, reason}

  defp unknown_failure(reason), do: {:error, %{cause: :unknown, reasons: List.wrap(reason)}}

  defp report_failure(failure, port, opts) do
    alert = Keyword.get(opts, :alert, &emit_unreachable_alert(&1, port))
    alert.(failure)
  end

  defp emit_unreachable_alert(%{cause: :timeout, reasons: reasons}, _port) do
    Alerts.emit_system(
      "system.build_order_funnel.target_timeout",
      message: "Build Order endpoint check timed out",
      reason: "Build Order endpoint transport timed out: #{inspect(reasons)}",
      needs_attention: true
    )
  end

  defp emit_unreachable_alert(%{cause: :unreachable, reasons: reasons}, port) do
    Alerts.emit_system(
      "system.build_order_funnel.target_unreachable",
      message: "Build Order endpoint returned an unexpected HTTP status at #{dashboard_url(port)}",
      reason: "Build Order endpoint HTTP result: #{inspect(reasons)}",
      needs_attention: true
    )
  end

  defp emit_unreachable_alert(%{cause: :funnel_target_mismatch, reasons: [{:target_port, target_port}]}, port) do
    Alerts.emit_system(
      "system.build_order_funnel.target_mismatch",
      message:
        "Tailscale Funnel HTTPS 443 targets port #{target_port}; dashboard is bound to port #{port}. " <>
          "Update the Funnel target to #{dashboard_url(port)}.",
      reason: "Build Order dashboard port changed but the persisted Funnel target did not",
      needs_attention: true
    )
  end

  defp emit_unreachable_alert(%{cause: :unknown, reasons: reasons}, _port) do
    Alerts.emit_system(
      "system.build_order_funnel.health_check_error",
      message: "Build Order Funnel health check could not classify its result",
      reason: "Build Order Funnel health check reason: #{inspect(reasons)}",
      needs_attention: true
    )
  end

  defp dashboard_url(port) do
    HttpServer.base_url() || "http://127.0.0.1:#{port}"
  end
end
