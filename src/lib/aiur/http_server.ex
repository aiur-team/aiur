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
    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        host = Keyword.get(opts, :host, Config.server_host())
        orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)
        dashboard_writable = Keyword.get(opts, :dashboard_writable, dashboard_writable?())
        decision_api = Keyword.get(opts, :decision_api, DecisionApi)
        decision_store = Keyword.get(opts, :decision_store, DecisionStore)
        decision_policy = Keyword.get(opts, :decision_policy)
        decision_revision_service = Keyword.get(opts, :decision_revision_service)

        with {:ok, ip} <- parse_host(host),
             :ok <- guard_credentials_for_non_loopback(ip, host),
             :ok <- guard_port_available(ip, port, host) do
          endpoint_opts = [
            server: true,
            http: [ip: ip, port: port],
            url: [host: normalize_host(host)],
            orchestrator: orchestrator,
            snapshot_timeout_ms: snapshot_timeout_ms,
            dashboard_writable: dashboard_writable,
            decision_api: decision_api,
            decision_store: decision_store,
            decision_policy: decision_policy,
            decision_revision_service: decision_revision_service,
            secret_key_base: secret_key_base()
          ]

          endpoint_config =
            :aiur
            |> Application.get_env(Endpoint, [])
            |> Keyword.merge(endpoint_opts)

          Application.put_env(:aiur, Endpoint, endpoint_config)
          Endpoint.start_link()
        else
          :credentials_missing_for_non_loopback -> :ignore
          :port_in_use -> :ignore
          other -> other
        end

      _ ->
        :ignore
    end
  end

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

  # Refuse to bind on non-loopback when basic-auth credentials are
  # missing. The dashboard exposes write endpoints (chat, pause,
  # refresh); without auth, every device on the LAN/tailnet can POST.
  # Returns `:ok` to proceed, or the sentinel
  # `:credentials_missing_for_non_loopback` to short-circuit to
  # `:ignore`. The Logger.error log line is the operator's only signal,
  # so it must include the resolved host + env-var names + remediation.
  defp guard_credentials_for_non_loopback(ip, host_input) do
    cond do
      loopback?(ip) ->
        :ok

      basic_auth_configured?() ->
        :ok

      true ->
        Logger.error(
          "Aiur dashboard refusing to bind on non-loopback host " <>
            "(#{inspect(host_input)} resolved to #{format_ip(ip)}) without basic-auth credentials.\n" <>
            "Set AIUR_DASHBOARD_USERNAME and AIUR_DASHBOARD_PASSWORD env vars, " <>
            "or re-run with --host 127.0.0.1 (loopback bind is unauthenticated by design)."
        )

        :credentials_missing_for_non_loopback
    end
  end

  # A fixed dashboard port that is already bound — e.g. a *second* aiur instance
  # sharing the same `server.port` (this repo's config pins 4000) — makes
  # Bandit's listener fail with `:eaddrinuse`. That failure surfaces as a
  # crashed child, which `:one_for_one` retries until `max_restarts` is exhausted
  # and the whole BEAM goes down on startup (#442). Probe the bind first and
  # degrade to no-dashboard (`:ignore`) instead: the node keeps running agents,
  # only this instance's dashboard is unavailable. The `Logger.warning` line is
  # the operator's only signal, so it names the port + remediation.
  #
  # Port 0 is ephemeral (the OS assigns a free port), so it never collides —
  # skip the probe. The probe mirrors Bandit's bind (`reuseaddr: true`) so a
  # port merely lingering in TIME_WAIT is not misread as in-use. A tiny
  # time-of-check/time-of-use window remains between the probe and the real
  # bind; losing that race only reproduces the pre-#442 crash, which is no
  # worse than today and astronomically unlikely in practice.
  defp guard_port_available(_ip, 0, _host_input), do: :ok

  defp guard_port_available(ip, port, host_input) do
    case :gen_tcp.listen(port, ip: ip, reuseaddr: true) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, :eaddrinuse} ->
        Logger.warning(
          "Aiur dashboard port #{port} is already in use on " <>
            "#{inspect(host_input)} (#{format_ip(ip)}) — another aiur instance? " <>
            "Dashboard disabled for this instance (agents still run). " <>
            "Set a different `server.port` (or pass `--port`) to run a second dashboard."
        )

        :port_in_use

      {:error, _other} ->
        # Any other bind error (e.g. `:eaddrnotavail` for an unroutable host) is
        # left to `Endpoint.start_link/0` to surface, preserving prior behavior.
        :ok
    end
  end

  defp loopback?(@loopback_v4), do: true
  defp loopback?(@loopback_v6), do: true
  defp loopback?(_), do: false

  # Read-only unless the operator opted into dashboard writes. Fail closed if
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

  defp secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end
end
