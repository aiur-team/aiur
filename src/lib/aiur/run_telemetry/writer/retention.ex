defmodule Aiur.RunTelemetry.Writer.Retention do
  @moduledoc "Rolls the live telemetry segment and prunes retained boots for `Aiur.RunTelemetry.Writer`."

  require Logger

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.{Retention, Summaries}
  alias Aiur.RunTelemetry.Writer.Encoding

  @doc false
  @spec maybe_prune(map()) :: map()
  def maybe_prune(%{prune_interval_bytes: nil} = state), do: state
  def maybe_prune(%{bytes_since_prune: n, prune_interval_bytes: threshold} = state) when n < threshold, do: state

  def maybe_prune(state) do
    if segment_roll_required?(state) do
      roll_and_prune(state)
    else
      prune_historical_boots(state)
    end
  rescue
    error ->
      Logger.warning("run_telemetry retention_raised path=#{state.path} reason=#{inspect(error)}")
      %{state | bytes_since_prune: 0}
  end

  defp roll_and_prune(state) do
    # Roll the current segment: append a restart marker to close the current
    # segment so any data before this point is pruneable as a completed group.
    # The fresh restart marker re-anchors the current boot in the file, so the
    # subsequent prune (which does not protect any boot) leaves it parseable.
    # If the boundary write fails (sequence unchanged), skip pruning to avoid
    # cutting mid-segment without a clean group boundary.
    rolled = write_segment_boundary(state)

    if rolled.sequence != state.sequence do
      opts = rolled.retention |> Keyword.put(:now, rolled.clock.())

      case Retention.prune(rolled.path, opts) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("run_telemetry retention_failed path=#{rolled.path} reason=#{inspect(reason)}")
      end

      # The segment boundary is the hook to materialize run summaries: the boot
      # just rolled is complete up to this point, so its summary is a stable
      # cache entry the dashboard can serve for prior-boot reads. Fire-and-forget;
      # a regenerable cache must never block the writer's append path.
      Summaries.materialize_async()
    end

    %{rolled | bytes_since_prune: 0}
  end

  defp prune_historical_boots(state) do
    opts = state.retention |> Keyword.put(:now, state.clock.()) |> Keyword.put(:protected_boot_id, state.boot_id)

    case Retention.prune(state.path, opts) do
      :ok ->
        %{state | bytes_since_prune: 0}

      {:error, reason} ->
        Logger.warning("run_telemetry retention_failed path=#{state.path} reason=#{inspect(reason)}")
        %{state | bytes_since_prune: 0}
    end
  end

  defp segment_roll_required?(state) do
    with max_bytes when is_integer(max_bytes) and max_bytes > 0 <- Keyword.get(state.retention, :max_bytes),
         {:ok, %{size: size}} <- File.stat(state.path) do
      size > max_bytes
    else
      _other -> false
    end
  end

  defp write_segment_boundary(state) do
    # Structural markers use the writer clock so retention can always parse and
    # age segment boundaries independently of caller-supplied timestamps.
    timestamp = Encoding.clock_timestamp(state.clock)
    {closing, reopening, open_lifecycles} = Encoding.segment_lifecycle_records(state.open_lifecycles, timestamp)

    records =
      closing ++
        [
          {:restart,
           %{
             event: "segment_boundary",
             daemon_pid: System.pid(),
             daemon_started_at: RunTelemetry.boot_started_at(),
             existing_records: true
           }, timestamp}
        ] ++ reopening ++ Encoding.carried_point_records(state.carried_points)

    {rolled, contents, _encoded_records} = Encoding.encode_records(state, records)

    case state.write_fun.(state.path, contents) do
      :ok ->
        %{
          rolled
          | bytes_since_prune: state.bytes_since_prune + byte_size(contents),
            open_lifecycles: open_lifecycles
        }

      {:error, reason} ->
        Logger.warning("run_telemetry segment_roll_failed path=#{state.path} reason=#{inspect(reason)}")
        state
    end
  end

  # Default interval: max_bytes / 8, minimum 1 MiB. It can be overridden with
  # observability.telemetry_retention_prune_interval_bytes (or directly in
  # the retention keyword list for focused tests).
  @doc false
  @spec prune_interval(keyword()) :: pos_integer() | nil
  def prune_interval(retention) do
    case Keyword.get(retention, :prune_interval_bytes) do
      n when is_integer(n) and n > 0 ->
        n

      _other ->
        case Keyword.get(retention, :max_bytes) do
          bytes when is_integer(bytes) and bytes > 0 -> max(div(bytes, 8), 1024 * 1024)
          _other -> nil
        end
    end
  end
end
