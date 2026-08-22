defmodule Aiur.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  require Logger

  alias Aiur.{Config, DecisionApi, DecisionStore, Orchestrator}
  alias AiurWeb.Endpoint

  @secret_key_bytes 48
  @loopback_v4 {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    Application.put_env(:aiur, :dashboard_url_fun, &__MODULE__.base_url/0)

    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        start_on_port(opts, port)

      _ ->
        :ignore
    end
  end

  defp start_on_port(opts, port) do
    host = Keyword.get(opts, :host, Config.server_host())
    dashboard_writable = Keyword.get(opts, :dashboard_writable, dashboard_writable?())

    with {:ok, ip} <- parse_host(host),
         :ok <- guard_dashboard_credentials(ip, host, dashboard_writable) do
      configure_endpoint(opts, host, ip, port, dashboard_writable)

      opts
      |> Keyword.get(:endpoint_start_fun, &Endpoint.start_link/0)
      |> start_endpoint()
      |> handle_endpoint_start(host, ip, port)
    else
      :dashboard_credentials_missing -> :ignore
      other -> other
    end
  end

  defp configure_endpoint(opts, host, ip, port, dashboard_writable) do
    endpoint_opts = [
      server: true,
      http: [ip: ip, port: port],
      url: [host: normalize_host(host)],
      orchestrator: Keyword.get(opts, :orchestrator, Orchestrator),
      snapshot_timeout_ms: Keyword.get(opts, :snapshot_timeout_ms, 15_000),
      dashboard_writable: dashboard_writable,
      dashboard_auth_required: dashboard_writable or not loopback?(ip),
      decision_api: Keyword.get(opts, :decision_api, DecisionApi),
      decision_store: Keyword.get(opts, :decision_store, DecisionStore),
      decision_policy: Keyword.get(opts, :decision_policy),
      secret_key_base: secret_key_base()
    ]

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(endpoint_opts)

    Application.put_env(:aiur, Endpoint, endpoint_config)
  end

  defp handle_endpoint_start({:endpoint_exit, reason}, host, ip, port) do
    if address_in_use?(reason), do: ignore_port_conflict(host, ip, port), else: exit(reason)
  end

  defp handle_endpoint_start({:error, reason} = error, host, ip, port) do
    if address_in_use?(reason), do: ignore_port_conflict(host, ip, port), else: error
  end

  defp handle_endpoint_start(other, _host, _ip, _port), do: other

  defp ignore_port_conflict(host, ip, port) do
    port_in_use(host, ip, port)
    :ignore
  end

  defp start_endpoint(endpoint_start_fun) do
    trapping_exits? = Process.flag(:trap_exit, true)

    try do
      result = endpoint_start_fun.()
      drain_failed_start_exit(result)
      result
    catch
      :exit, reason ->
        drain_failed_start_exit({:error, reason})
        {:endpoint_exit, reason}
    after
      Process.flag(:trap_exit, trapping_exits?)
    end
  end

  defp drain_failed_start_exit({:error, reason}) do
    receive do
      {:EXIT, _pid, ^reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp drain_failed_start_exit(_result), do: :ok

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  @doc "Return the dashboard URL only when the HTTP listener is actually bound."
  @spec base_url() :: String.t() | nil
  def base_url do
    case bound_port() do
      port when is_integer(port) and port > 0 ->
        host = Config.server_host()
        "http://#{display_host(host)}:#{port}"

      _ ->
        nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # Require basic-auth credentials for writable dashboards on every host, and
  # for read-only dashboards exposed beyond loopback. Even when the bind guard
  # permits a loopback bind without credentials, the dashboard plug fails
  # closed: every request is refused (503) until credentials are set, so an
  # unconfigured loopback dashboard is bound but inert, never open. Returns
  # `:ok` to proceed, or a sentinel that disables the dashboard after logging
  # remediation.
  defp guard_dashboard_credentials(ip, host_input, dashboard_writable) do
    cond do
      basic_auth_configured?() ->
        :ok

      dashboard_writable ->
        Logger.error(
          "Aiur dashboard refusing to start with observability.dashboard_writable enabled " <>
            "without basic-auth credentials.\n" <>
            "Set both AIUR_DASHBOARD_USERNAME and AIUR_DASHBOARD_PASSWORD env vars, " <>
            "or disable observability.dashboard_writable."
        )

        :dashboard_credentials_missing

      loopback?(ip) ->
        Logger.warning(
          "Aiur dashboard binding on loopback without basic-auth credentials. " <>
            "The dashboard plug fails closed, so every request is refused (503) " <>
            "until AIUR_DASHBOARD_USERNAME and AIUR_DASHBOARD_PASSWORD are set."
        )

        :ok

      true ->
        Logger.error(
          "Aiur dashboard refusing to bind on non-loopback host " <>
            "(#{inspect(host_input)} resolved to #{format_ip(ip)}) without basic-auth credentials.\n" <>
            "Set AIUR_DASHBOARD_USERNAME and AIUR_DASHBOARD_PASSWORD env vars, " <>
            "or re-run with --host 127.0.0.1. Without credentials the dashboard " <>
            "binds on loopback but refuses every request (503) until they are set."
        )

        :dashboard_credentials_missing
    end
  end

  defp port_in_use(host_input, ip, port) do
    Logger.warning(
      "Aiur dashboard port #{port} is already in use on " <>
        "#{inspect(host_input)} (#{format_ip(ip)}) — another aiur instance? " <>
        "Dashboard disabled for this instance (agents still run). " <>
        "Set a different `server.port` (or pass `--port`) to run a second dashboard."
    )
  end

  defp address_in_use?(:eaddrinuse), do: true
  defp address_in_use?(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.any?(&address_in_use?/1)
  defp address_in_use?(term) when is_list(term), do: Enum.any?(term, &address_in_use?/1)
  defp address_in_use?(_term), do: false

  defp loopback?(@loopback_v4), do: true
  defp loopback?(@loopback_v6), do: true
  defp loopback?(_), do: false

  # Read-only unless the Executor opted into dashboard writes. Fail closed if
  # config can't be resolved — an observe-only dashboard is the safe default.
  defp dashboard_writable? do
    Config.dashboard_writable?()
  rescue
    _ -> false
  end

  defp basic_auth_configured? do
    nonblank?(System.get_env("AIUR_DASHBOARD_USERNAME")) and
      nonblank?(System.get_env("AIUR_DASHBOARD_PASSWORD"))
  end

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_), do: false

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_tuple(ip), do: inspect(ip)
  defp format_ip(ip), do: inspect(ip)

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp normalize_host(host) when host in ["", nil], do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host), do: to_string(host)

  defp display_host(host) when host in ["0.0.0.0", "::", "", nil], do: "127.0.0.1"
  defp display_host(host) when is_binary(host), do: host
  defp display_host(host), do: to_string(host)

  defp secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end
end
