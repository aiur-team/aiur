defmodule Aiur.CodexProber do
  @moduledoc """
  Probe Codex usage limits asynchronously and update the ledger.

  When a cached usage limit is stale, a probe runs in the background to fetch
  the current limit from the Codex provider. On success, the ledger is refreshed
  immediately. On failure, a retry is scheduled for 2 minutes later.
  """

  require Logger

  alias Aiur.Codex.{Frames, Rpc}
  alias Aiur.ModelAvailability

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

  defp probe_codex_limits(_opts) do
    # Create a temporary workspace for the probe session
    workspace = System.tmp_dir() <> "/codex-probe-#{:erlang.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(workspace),
         {:ok, session} <- start_probe_session(workspace) do
      try do
        # Read limits through the established session
        case read_limits_from_session(session) do
          {:ok, limits} -> normalize_codex_limits(limits)
          error -> error
        end
      after
        # Always clean up the session
        stop_probe_session(session)
        # Clean up the temporary workspace directory
        File.rm_rf(workspace)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Start a temporary probe session using the Codex backend
  @spec start_probe_session(String.t()) :: {:ok, map()} | {:error, term()}
  defp start_probe_session(workspace) do
    agent_module = Aiur.Codex.CodingAgent

    case agent_module.start_session(workspace, identifier: "model-usage-probe") do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :failed_to_start_session}
  catch
    _kind, _reason -> {:error, :failed_to_start_session}
  end

  # Stop the probe session
  defp stop_probe_session(session) when is_map(session) do
    agent_module = Aiur.Codex.CodingAgent
    agent_module.stop_session(session)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Read limits from an established Codex session via account/rateLimits/read
  defp read_limits_from_session(session) when is_map(session) do
    port = Map.get(session, :port)

    case port do
      port when is_port(port) ->
        try do
          # Send the rate limits read frame
          Rpc.send_message(port, Frames.rate_limits_read_frame())

          # Wait for the response
          case Rpc.await_response(port, Frames.rate_limits_read_id(), @timeout_ms) do
            {:ok, response} -> {:ok, response}
            {:error, reason} -> {:error, reason}
          end
        rescue
          ArgumentError -> {:error, :port_closed}
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, reason -> {:error, reason}
          kind, error -> {:error, {kind, error}}
        end

      _ ->
        {:error, :invalid_session}
    end
  end

  @spec normalize_codex_limits(map()) :: {:ok, map()} | {:error, term()}
  defp normalize_codex_limits(result) do
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
end
