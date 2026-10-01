defmodule Aiur.CodexProber do
  @moduledoc """
  Probe Codex usage limits asynchronously and update the ledger.

  When a cached usage limit is stale, a probe runs in the background to fetch
  the current limit from the Codex provider. On success, the ledger is refreshed
  immediately. On failure, a retry is scheduled for 2 minutes later.
  """

  require Logger

  alias Aiur.{CodingAgent, ModelAvailability}

  @timeout_ms 5_000

  @doc """
  Probe Codex for current usage limits and update the ledger.

  This runs asynchronously in a spawned process. On success, the ledger is
  refreshed with the new reading and the retry schedule is cleared. On failure,
  the cached reading is retained and a retry is scheduled.

  Returns `:ok` immediately (probe runs in the background).
  """
  @spec probe_async(String.t(), keyword()) :: :ok
  def probe_async(backend, opts \\ []) when is_binary(backend) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    path = Keyword.get(opts, :path, ModelAvailability.path())

    spawn(fn -> probe_sync(backend, now, path: path) end)
    :ok
  end

  @doc false
  @spec probe_sync(String.t(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def probe_sync(backend, now, opts \\ []) when is_binary(backend) do
    path = Keyword.get(opts, :path, ModelAvailability.path())

    case fetch_limits(backend, opts) do
      {:ok, limits} ->
        # Refresh ledger with new observation
        ModelAvailability.observe(backend, limits, path: path, now: now)
        # Clear retry schedule
        ModelAvailability.clear_retry_schedule(backend, path: path)
        :ok

      {:error, reason} ->
        Logger.warning("Codex probe failed for #{backend}: #{inspect(reason)}")
        # Retain cached reading and schedule retry
        ModelAvailability.schedule_retry(backend, now, path: path)
        {:error, reason}
    end
  end

  @doc false
  # Fetch current usage limits from Codex provider via app-server.
  # Returns {:ok, limits_map} or {:error, reason}.
  @spec fetch_limits(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_limits(backend, opts) do
    backend_key = ModelAvailability.backend_key(backend)

    # Only probe Codex for now
    if backend_key != "codex" do
      {:error, :unsupported_backend}
    else
      probe_codex_limits(opts)
    end
  end

  defp probe_codex_limits(opts) do
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    with {:ok, app_server_pid} <- start_app_server(),
         {:ok, result} <- read_limits(app_server_pid, timeout),
         :ok <- stop_app_server(app_server_pid) do
      normalize_codex_limits(result)
    else
      error ->
        {:error, error}
    end
  end

  defp start_app_server do
    case CodingAgent.app_server(nil, %{}, %{"_backend" => "codex"}) do
      {:ok, pid} -> {:ok, pid}
      error -> error
    end
  catch
    _kind, error -> {:error, error}
  end

  defp stop_app_server(pid) when is_pid(pid) do
    try do
      GenServer.stop(pid, :normal)
      :ok
    catch
      _kind, _error -> :ok
    end
  end

  defp stop_app_server(_pid), do: :ok

  defp read_limits(pid, timeout) when is_pid(pid) and is_integer(timeout) and timeout > 0 do
    try do
      response =
        GenServer.call(
          pid,
          {:call_method, "account/rateLimits/read", %{}},
          timeout
        )

      {:ok, response}
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, reason}
      kind, error -> {:error, {kind, error}}
    end
  end

  defp normalize_codex_limits(%{} = result) do
    # Codex returns a structure like:
    # {
    #   "primary": {"usedPercent": N, "windowDurationMins": M, "resetsAt": "..."},
    #   "secondary": {"usedPercent": N, "windowDurationMins": M, "resetsAt": "..."},
    #   "rateLimitReachedType": null or "..."
    # }
    limits =
      result
      |> Map.take(["primary", "secondary"])
      |> Enum.into(%{})

    # Return in a format ModelAvailability.observe expects
    if map_size(limits) > 0 do
      {:ok, limits}
    else
      {:error, :no_usage_data}
    end
  end

  defp normalize_codex_limits(_), do: {:error, :invalid_response}
end
