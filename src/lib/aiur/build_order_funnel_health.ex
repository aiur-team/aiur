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

  alias Aiur.{Alerts, Config, HttpServer, TailscaleFunnel}

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
    host = Keyword.get_lazy(opts, :bound_host, &Config.server_host/0) |> normalize_probe_host()
    http_client = Keyword.get(opts, :http_client, &fetch_endpoint/2)

    case build_order_endpoint_reachable?(host, port, timeout_ms, http_client) do
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
    case TailscaleFunnel.funnel_target(status) do
      {:error, :funnel_443_not_enabled} ->
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
    case TailscaleFunnel.command(["funnel", "status", "--json"], Keyword.put(opts, :timeout_ms, timeout_ms)) do
      {:error, :tailscale_executable_not_found} ->
        :not_configured

      {:ok, output} ->
        case TailscaleFunnel.funnel_target(output) do
          {:ok, proxy} -> funnel_proxy_status(proxy, bound_port)
          {:error, :funnel_443_not_enabled} -> :not_configured
          {:error, reason} -> unknown_failure(reason)
        end

      {:error, {:tailscale_exit, exit_status}} ->
        unknown_failure({:tailscale_exit, exit_status})

      {:error, :tailscale_timeout} ->
        unknown_failure(:tailscale_status_timeout)

      {:error, reason} ->
        unknown_failure(reason)
    end
  end

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

  defp build_order_endpoint_reachable?(host, port, timeout_ms, http_client)
       when is_integer(port) and port > 0 do
    url = "http://#{url_host(host)}:#{port}/build-orders/1"

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

  defp build_order_endpoint_reachable?(_host, _port, _timeout_ms, _http_client),
    do: unknown_failure(:dashboard_not_bound)

  defp normalize_probe_host(host) when host in ["0.0.0.0", "::"], do: "127.0.0.1"
  defp normalize_probe_host(host) when is_binary(host) and host != "", do: host
  defp normalize_probe_host(_host), do: "127.0.0.1"

  defp url_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[#{host}]"
    else
      host
    end
  end

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
