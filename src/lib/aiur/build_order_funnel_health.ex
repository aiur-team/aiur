defmodule Aiur.BuildOrderFunnelHealth do
  @moduledoc """
  Health check for Build Order endpoint reachability across restarts.

  Detects when the Tailscale Funnel target (configured externally) becomes stale
  after a dashboard port change or restart. When the endpoint is unreachable,
  emits an alert with the current bound port so operators can repair the Funnel target.

  This is an idempotent health check suitable for running at startup.
  """

  require Logger

  alias Aiur.{Alerts, HttpServer}

  @type check_result :: {:ok, port} | {:error, reason}
  @type reason :: :unreachable | :timeout | :parse_error

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
        {:ok, port}

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
end
