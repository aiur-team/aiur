defmodule Aiur.BuildOrderFunnelHealth do
  @moduledoc """
  Health check for Build Order endpoint reachability across restarts.

  Detects when the externally configured Tailscale Funnel target becomes stale
  after a dashboard port change or restart. When the local endpoint is unreachable
  or Funnel points at a different port, emits an alert with actionable port details.

  The application runs this check after startup; calling it repeatedly is safe.
  """

  require Logger

  alias Aiur.{Alerts, HttpServer}

  @type check_result :: {:ok, port} | {:error, reason}
  @type reason ::
          :unreachable
          | :timeout
          | :parse_error
          | {:funnel_target_mismatch, non_neg_integer() | :unknown}

  @doc """
  Check if Build Order endpoint is reachable and return the bound port.

  Returns `{:ok, port}` if the endpoint responds with a 2xx/3xx status or 401 (auth required).
  Returns `{:error, reason}` for connection failures, timeouts, or 502/503 errors.
  """
  @spec check(keyword()) :: check_result()
  def check(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    case build_order_endpoint_reachable?(timeout_ms) do
      {:ok, port} ->
        case funnel_target_status(Keyword.get(opts, :funnel_status), port) do
          :ok ->
            {:ok, port}

          :not_configured ->
            {:ok, port}

          {:error, {:funnel_target_mismatch, _target_port} = reason} = error ->
            emit_unreachable_alert({:error, reason})
            error
        end

      error ->
        emit_unreachable_alert(error)
        error
    end
  end

  @doc """
  Get the current bound dashboard port, or nil if not bound.
  """
  @spec bound_port() :: non_neg_integer() | nil
  def bound_port, do: HttpServer.bound_port()

  @doc """
  Get the dashboard base URL for diagnostic purposes.
  """
  @spec base_url() :: String.t() | nil
  def base_url, do: HttpServer.base_url()

  @doc false
  @spec funnel_target_status(map() | nil, non_neg_integer()) ::
          :ok | :not_configured | {:error, {:funnel_target_mismatch, non_neg_integer() | :unknown}}
  def funnel_target_status(status, bound_port) when is_map(status) do
    case configured_funnel_proxy(status) do
      :not_configured ->
        :not_configured

      {:ok, proxy} ->
        funnel_proxy_status(proxy, bound_port)

      :error ->
        funnel_target_mismatch(:unknown)
    end
  end

  def funnel_target_status(nil, bound_port) do
    case System.find_executable("tailscale") do
      nil ->
        :not_configured

      executable ->
        read_funnel_status(executable, bound_port)
    end
  end

  defp read_funnel_status(executable, bound_port) do
    case System.cmd(executable, ["funnel", "status", "--json"], stderr_to_stdout: true) do
      {output, 0} -> decode_funnel_status(output, bound_port)
      _ -> :not_configured
    end
  end

  defp decode_funnel_status(output, bound_port) do
    case Jason.decode(output) do
      {:ok, status} when is_map(status) -> funnel_target_status(status, bound_port)
      _ -> funnel_target_mismatch(:unknown)
    end
  end

  defp configured_funnel_proxy(status) do
    with true <- funnel_enabled?(status),
         {:ok, proxy} <- funnel_https_proxy(status) do
      {:ok, proxy}
    else
      false -> :not_configured
      :error -> :error
    end
  end

  defp funnel_proxy_status(proxy, bound_port) do
    case URI.parse(proxy).port do
      ^bound_port -> :ok
      target_port when is_integer(target_port) -> funnel_target_mismatch(target_port)
      _ -> funnel_target_mismatch(:unknown)
    end
  end

  defp funnel_target_mismatch(target_port), do: {:error, {:funnel_target_mismatch, target_port}}

  defp funnel_enabled?(%{"AllowFunnel" => allow_funnel}) when is_map(allow_funnel),
    do: Enum.any?(allow_funnel, fn {_target, enabled?} -> enabled? == true end)

  defp funnel_enabled?(_status), do: false

  defp funnel_https_proxy(%{"Web" => web}) when is_map(web) do
    web
    |> Enum.filter(fn {target, _config} -> is_binary(target) and String.ends_with?(target, ":443") end)
    |> Enum.find_value(:error, fn {_target, config} -> root_proxy(config) end)
  end

  defp funnel_https_proxy(_status), do: :error

  defp root_proxy(config) do
    case get_in(config, ["Handlers", "/", "Proxy"]) do
      proxy when is_binary(proxy) -> {:ok, proxy}
      _ -> nil
    end
  end

  # Check if the Build Order endpoint is reachable at the current bound port.
  # Returns {:ok, port} for successful responses (including 401 auth required).
  # Returns {:error, reason} for connection failures or service errors (502/503).
  defp build_order_endpoint_reachable?(timeout_ms) do
    with port when is_integer(port) and port > 0 <- HttpServer.bound_port(),
         url <- endpoint_url(port),
         {:ok, response} <- fetch_endpoint(url, timeout_ms),
         :ok <- check_response_status(response) do
      {:ok, port}
    else
      nil ->
        {:error, :unreachable}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :parse_error} ->
        {:error, :parse_error}

      {:error, status_code} when is_integer(status_code) ->
        {:error, :unreachable}
    end
  end

  defp endpoint_url(port) do
    "http://127.0.0.1:#{port}/build-orders/1"
  end

  defp fetch_endpoint(url, timeout_ms) do
    case Req.get(url, receive_timeout: timeout_ms, retry: false) do
      {:ok, response} ->
        {:ok, response}

      {:error, _reason} ->
        {:error, :timeout}
    end
  rescue
    _exception ->
      {:error, :parse_error}
  end

  defp check_response_status(%Req.Response{status: status}) when status in [200, 301, 302, 304, 307, 308, 401], do: :ok
  defp check_response_status(%Req.Response{status: status}), do: {:error, status}

  defp emit_unreachable_alert({:error, :timeout}) do
    Alerts.emit_system(
      "system.build_order_funnel.target_timeout",
      message: "Build Order endpoint timeout at #{base_url() || "unknown"}",
      reason: "Connection timeout checking Build Order endpoint",
      needs_attention: true
    )
  end

  defp emit_unreachable_alert({:error, :unreachable}) do
    port_info =
      case bound_port() do
        port when is_integer(port) -> " (port #{port})"
        _ -> ""
      end

    Alerts.emit_system(
      "system.build_order_funnel.target_unreachable",
      message: "Build Order endpoint unreachable#{port_info}. Verify Funnel target.",
      reason: "Build Order endpoint returned error status or connection refused",
      needs_attention: true
    )
  end

  defp emit_unreachable_alert({:error, :parse_error}) do
    Alerts.emit_system(
      "system.build_order_funnel.health_check_error",
      message: "Build Order health check encountered an error",
      reason: "Error during endpoint health check",
      needs_attention: true
    )
  end

  defp emit_unreachable_alert({:error, {:funnel_target_mismatch, target_port}}) do
    current_port = bound_port()

    Alerts.emit_system(
      "system.build_order_funnel.target_mismatch",
      message:
        "Tailscale Funnel HTTPS 443 targets port #{target_port}; dashboard is bound to port #{current_port}. " <>
          "Update the Funnel target to #{base_url() || "the current dashboard port"}.",
      reason: "Build Order dashboard port changed but the persisted Funnel target did not",
      needs_attention: true
    )
  end
end
