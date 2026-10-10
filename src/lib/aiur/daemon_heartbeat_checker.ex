defmodule Aiur.DaemonHeartbeatChecker do
  @moduledoc """
  Reports a past daemon heartbeat gap when an Executor starts.

  This is a retrospective notice, not a live monitor: while the daemon is down,
  nothing in this application is running to inspect its heartbeat. At the next
  Executor startup, the checker compares the last heartbeat with the durable
  daemon lifecycle journal. Missing heartbeat files are ignored because they
  may mean first boot, an upgrade, or a changed state directory.

  A journaled clean stop is reported as `clean_shutdown`; an unmatched start
  with a stale heartbeat has cause `unknown`. Both notices describe a completed
  gap and are informational, never open critical attentions.
  """

  require Logger

  alias Aiur.{Signal, Config, DaemonLifecycle}
  alias Aiur.Config.Paths

  @alert_topic "system.daemon.gap"

  @doc "Checks for and records a retrospective gap on Executor startup."
  @spec check_and_alert!() :: :ok
  def check_and_alert! do
    check_and_alert!(
      &Paths.daemon_heartbeat_path/0,
      &Config.daemon_heartbeat_stale_ms/0,
      &DaemonLifecycle.daemon_events/0,
      &Signal.alert/2
    )
  end

  @doc false
  @spec check_and_alert!(
          (-> {:ok, String.t()} | {:error, term()}),
          (-> pos_integer()),
          (-> [map()]),
          (String.t(), keyword() -> :ok | {:error, term()})
        ) :: :ok
  def check_and_alert!(path_fun, threshold_fun, events_fun, emit_fun) do
    with {:ok, heartbeat_at} <- read_heartbeat(path_fun),
         threshold when is_integer(threshold) and threshold > 0 <- safe_call(threshold_fun),
         {:ok, cause, gap_start} <- gap_start(heartbeat_at, safe_call(events_fun)),
         now <- DateTime.utc_now(),
         age_ms when age_ms > threshold <- DateTime.diff(now, gap_start, :millisecond) do
      emit_gap(emit_fun, cause, gap_start, now, age_ms)
    else
      {:error, reason} ->
        Logger.debug("daemon_heartbeat_checker skipped reason=#{inspect(reason)}")
        :ok

      :invalid ->
        Logger.warning("daemon_heartbeat_checker config_error reason=invalid_threshold threshold=:invalid")
        :ok

      threshold when not is_integer(threshold) or threshold <= 0 ->
        Logger.warning("daemon_heartbeat_checker config_error reason=invalid_threshold threshold=#{inspect(threshold)}")
        :ok

      age_ms when is_integer(age_ms) ->
        :ok
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

  @doc false
  @spec gap_start(DateTime.t(), [map()]) :: {:ok, :unknown | :clean_shutdown, DateTime.t()} | {:error, atom()}
  def gap_start(heartbeat_at, events) do
    case latest_event(events) do
      %{kind: :start} ->
        {:ok, :unknown, heartbeat_at}

      %{kind: :stop, at: stopped_at} ->
        if DateTime.compare(stopped_at, heartbeat_at) == :gt do
          {:ok, :clean_shutdown, stopped_at}
        else
          {:error, :no_gap_evidence}
        end

      _ ->
        {:error, :no_gap_evidence}
    end
  end

  defp read_heartbeat(path_fun) do
    with {:ok, path} <- path_fun.(),
         {:ok, content} <- File.read(path),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(String.trim(content)) do
      {:ok, datetime}
    else
      {:error, :enoent} -> {:error, :heartbeat_missing}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :heartbeat_unparseable}
    end
  end

  defp latest_event(events) do
    Enum.max_by(events, &DateTime.to_unix(&1.at, :microsecond), fn -> nil end)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> :invalid
  catch
    _, _ -> :invalid
  end

  defp emit_gap(emit_fun, cause, gap_start, gap_end, age_ms) do
    message =
      "Retrospective daemon availability gap from #{DateTime.to_iso8601(gap_start)} " <>
        "to #{DateTime.to_iso8601(gap_end)} (cause: #{cause}). Detected at the next Executor startup; " <>
        "this notice does not monitor a stopped daemon live."

    case emit_fun.(@alert_topic,
           message: message,
           reason: Atom.to_string(cause),
           needs_attention: false,
           severity: "info"
         ) do
      :ok ->
        Logger.info("daemon_heartbeat_checker retrospective_gap_emitted cause=#{cause} age_ms=#{age_ms}")
        :ok

      {:error, error} ->
        Logger.warning("daemon_heartbeat_checker retrospective_gap_emit_failed error=#{inspect(error)}")
        :ok
    end
  end
end
