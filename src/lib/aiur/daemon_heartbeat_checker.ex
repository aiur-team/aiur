defmodule Aiur.DaemonHeartbeatChecker do
  @moduledoc """
  Checks daemon heartbeat staleness and emits durable alerts when the daemon appears down.

  This module runs during Executor boot to detect if the daemon has stopped responding.
  It reads the heartbeat file written by the daemon, calculates its age, and compares
  against a configured staleness threshold. If the heartbeat is stale or missing, it
  emits a system alert to notify the Executor operator.

  The alert uses a topic (`system.daemon.stopped`) that the alert ledger tracks,
  allowing the Executor to detect that daemon downtime has been recorded. When the
  heartbeat becomes recent again (i.e., the daemon restarts), a resolved alert is
  emitted to clear the condition.

  All operations are best-effort: file reads, parse errors, config errors, and
  alert emission failures are logged and do not block Executor boot. The function
  never raises; it always returns `:ok`.
  """

  require Logger

  alias Aiur.{Alerts, Config}
  alias Aiur.Config.Paths

  @alert_topic "system.daemon.stopped"

  @doc """
  Check daemon heartbeat staleness and emit alert if necessary.

  This function:
  1. Reads the heartbeat file (if it exists)
  2. Parses the ISO 8601 timestamp
  3. Calculates age and compares to the configured threshold
  4. Emits an alert if the heartbeat is stale or missing
  5. Emits a resolved alert if the heartbeat is recent (clearing a prior stale condition)

  Returns `:ok` in all cases. All errors are logged as warnings and do not raise.

  The alert message includes the timestamp and age for debugging. The alert topic
  (`system.daemon.stopped`) allows the alert ledger to deduplicate repeated firings
  and track the stale → resolved transition.
  """
  @spec check_and_alert!() :: :ok
  def check_and_alert! do
    check_and_alert!(
      &Paths.daemon_heartbeat_path/0,
      &Config.daemon_heartbeat_stale_ms/0,
      &Alerts.emit_system/2
    )
  end

  @doc false
  @spec check_and_alert!(
          (-> {:ok, String.t()} | {:error, term()}),
          (-> non_neg_integer()),
          (String.t(), keyword() -> :ok | {:error, term()})
        ) :: :ok
  def check_and_alert!(path_fun, threshold_fun, emit_fun) do
    case read_heartbeat_age(path_fun) do
      {:ok, age_ms} ->
        case safe_call_threshold(threshold_fun) do
          threshold_ms when is_integer(threshold_ms) and threshold_ms > 0 ->
            if age_ms > threshold_ms do
              emit_stale_alert(emit_fun, age_ms, threshold_ms)
            else
              emit_resolved_alert(emit_fun)
            end

          invalid_threshold ->
            Logger.warning("daemon_heartbeat_checker config_error reason=invalid_threshold threshold=#{inspect(invalid_threshold)}")
            :ok
        end

      {:error, reason} ->
        Logger.debug("daemon_heartbeat_checker heartbeat_read_failed reason=#{inspect(reason)}")
        emit_stale_alert(emit_fun, nil, nil)
    end
  rescue
    error ->
      Logger.warning("daemon_heartbeat_checker check_and_alert_crashed error=#{inspect(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("daemon_heartbeat_checker check_and_alert_crashed kind=#{kind} reason=#{inspect(reason)}")
      :ok
  end

  # Read the heartbeat file and calculate its age in milliseconds.
  # Returns {:ok, age_ms} on success, or {:error, reason} if the file does not exist,
  # cannot be read, or the timestamp cannot be parsed.
  @spec read_heartbeat_age((-> {:ok, String.t()} | {:error, term()})) :: {:ok, non_neg_integer()} | {:error, term()}
  defp read_heartbeat_age(path_fun) do
    with {:ok, path} <- path_fun.(),
         {:ok, content} <- File.read(path),
         timestamp_str <- String.trim(content),
         {:ok, parsed_dt, _offset} <- DateTime.from_iso8601(timestamp_str),
         now <- DateTime.utc_now(),
         age_duration <- DateTime.diff(now, parsed_dt, :millisecond) do
      {:ok, age_duration}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unparseable}
    end
  end

  # Safely call the threshold function, catching any errors.
  @spec safe_call_threshold((-> non_neg_integer())) :: non_neg_integer() | :invalid
  defp safe_call_threshold(threshold_fun) do
    threshold_fun.()
  rescue
    _error -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  # Emit an alert indicating the daemon heartbeat is stale.
  # age_ms and threshold_ms are used to construct a descriptive message.
  @spec emit_stale_alert(
          (String.t(), keyword() -> :ok | {:error, term()}),
          non_neg_integer() | nil,
          non_neg_integer() | nil
        ) :: :ok
  defp emit_stale_alert(emit_fun, age_ms, threshold_ms) do
    message = format_stale_message(age_ms, threshold_ms)
    reason = "Daemon heartbeat is stale; daemon may have stopped"

    case emit_fun.(@alert_topic,
           message: message,
           reason: reason,
           needs_attention: true,
           severity: "critical"
         ) do
      :ok ->
        Logger.info("daemon_heartbeat_checker stale_alert_emitted age_ms=#{inspect(age_ms)}")
        :ok

      {:error, alert_error} ->
        Logger.warning("daemon_heartbeat_checker stale_alert_emit_failed error=#{inspect(alert_error)}")
        :ok
    end
  end

  # Emit a resolved alert to clear a prior stale condition.
  @spec emit_resolved_alert((String.t(), keyword() -> :ok | {:error, term()})) :: :ok
  defp emit_resolved_alert(emit_fun) do
    message = "Daemon heartbeat is healthy again"
    reason = "Daemon heartbeat is now within acceptable staleness threshold"

    case emit_fun.("#{@alert_topic}.resolved",
           message: message,
           reason: reason,
           needs_attention: false,
           severity: "info"
         ) do
      :ok ->
        Logger.info("daemon_heartbeat_checker resolved_alert_emitted")
        :ok

      {:error, alert_error} ->
        Logger.warning("daemon_heartbeat_checker resolved_alert_emit_failed error=#{inspect(alert_error)}")
        :ok
    end
  end

  @doc """
  Format a descriptive message for the stale heartbeat alert.

  If age_ms or threshold_ms is nil, a simple message is returned. Otherwise,
  the message includes the age and threshold in human-readable format.
  """
  @spec format_stale_message(non_neg_integer() | nil, non_neg_integer() | nil) :: String.t()
  def format_stale_message(nil, _threshold_ms) do
    "Daemon heartbeat file not found or unreadable; daemon may have never started or files were deleted"
  end

  def format_stale_message(age_ms, nil) when is_integer(age_ms) do
    "Daemon heartbeat is #{format_duration_ms(age_ms)} old; daemon may have stopped"
  end

  def format_stale_message(age_ms, threshold_ms)
      when is_integer(age_ms) and is_integer(threshold_ms) do
    age_str = format_duration_ms(age_ms)
    threshold_str = format_duration_ms(threshold_ms)
    "Daemon heartbeat is #{age_str} old (threshold: #{threshold_str}); daemon may have stopped"
  end

  @doc """
  Format a duration in milliseconds as a human-readable string.

  Examples:
    iex> format_duration_ms(5_400_000)
    "1h30m"
    iex> format_duration_ms(125_000)
    "2m5s"
    iex> format_duration_ms(45_000)
    "45s"
  """
  @spec format_duration_ms(non_neg_integer()) :: String.t()
  def format_duration_ms(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms >= 3_600_000 ->
        hours = div(ms, 3_600_000)
        remainder_ms = rem(ms, 3_600_000)
        minutes = div(remainder_ms, 60_000)
        "#{hours}h#{minutes}m"

      ms >= 60_000 ->
        minutes = div(ms, 60_000)
        seconds = div(rem(ms, 60_000), 1_000)
        "#{minutes}m#{seconds}s"

      ms >= 1_000 ->
        seconds = div(ms, 1_000)
        "#{seconds}s"

      true ->
        "#{ms}ms"
    end
  end

  def format_duration_ms(_ms), do: "unknown"
end
