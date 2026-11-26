defmodule Aiur.DaemonHeartbeat do
  @moduledoc """
  Writes the daemon heartbeat file to signal daemon liveness.

  The heartbeat file contains a single timestamp written on daemon startup and
  periodically refreshed to allow the Executor to detect daemon downtime. The
  file lives at `<decision-state-dir>/executor/<repo>.daemon-heartbeat`.

  All operations are best-effort: a write failure must never crash boot or
  block the daemon. Errors are logged and execution continues.
  """

  require Logger

  alias Aiur.Config.Paths

  @doc """
  Write the current UTC timestamp to the daemon heartbeat file.

  The timestamp is formatted as ISO 8601 with UTC zone (e.g., `2026-10-01T12:34:56.789Z`),
  followed by a newline. Multiple writes overwrite the previous timestamp with no appending.

  Best-effort: write failures are logged as warnings and do not raise or crash boot.
  Parent directories are created automatically if they do not exist.
  """
  @spec write!() :: :ok
  def write! do
    case Paths.daemon_heartbeat_path() do
      {:ok, path} ->
        Logger.debug("daemon_heartbeat write path=#{inspect(path)}")
        write_heartbeat(path)

      {:error, reason} ->
        Logger.warning("daemon_heartbeat path_resolution_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp write_heartbeat(path) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    content = timestamp <> "\n"
    parent_dir = Path.dirname(path)

    case File.mkdir_p(parent_dir) do
      :ok ->
        case File.write(path, content) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("daemon_heartbeat write_failed path=#{inspect(path)} reason=#{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.warning("daemon_heartbeat mkdir_failed path=#{inspect(parent_dir)} reason=#{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("daemon_heartbeat write_crashed path=#{inspect(path)} error=#{inspect(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("daemon_heartbeat write_crashed path=#{inspect(path)} kind=#{kind} reason=#{inspect(reason)}")
      :ok
  end
end
