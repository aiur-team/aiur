defmodule Aiur.Diagnostics.IdleBurstSampler do
  @moduledoc """
  Opt-in, finite reduction-triggered stack capture for an already-running daemon.
  Call `run/1` through the release's `rpc`. Nothing runs automatically.
  It neither pauses dispatch nor changes VM flags, tracing, or application state.
  """

  @interval_ms 200
  @threshold 300_000
  @stack_interval_ms 25
  @stack_count 8
  @top_count 5

  @doc """
  Observe for `:duration_ms` (default ten minutes), stopping after `:max_bursts`
  (default twenty). Each burst captures the top five qualifying processes together.
  `:processes`, `:info`, `:sleep`, and `:clock` callbacks are deterministic test seams.
  Output contains stack locations, never process dictionaries or message contents.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    duration = positive!(opts, :duration_ms, 600_000)
    max_bursts = positive!(opts, :max_bursts, 20)

    source = %{
      processes: Keyword.get(opts, :processes, &Process.list/0),
      info: Keyword.get(opts, :info, &Process.info/2),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    }

    started = source.clock.()
    initial = snapshot(source)
    state = %{deadline: started + duration, max_bursts: max_bursts, bursts: [], windows: 0}
    result = poll(source, initial, state)
    Map.merge(result, %{elapsed_ms: source.clock.() - started, interval_ms: @interval_ms, threshold: @threshold})
  end

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp snapshot(source) do
    readings =
      source.processes.()
      |> Enum.reject(&(&1 == self()))
      |> Enum.reduce(%{}, fn pid, acc ->
        case source.info.(pid, :reductions) do
          {:reductions, count} -> Map.put(acc, pid, count)
          nil -> acc
        end
      end)

    %{at_ms: source.clock.(), readings: readings}
  end

  defp poll(source, previous, state) do
    cond do
      length(state.bursts) >= state.max_bursts ->
        finish(state, :max_bursts)

      source.clock.() + @interval_ms > state.deadline ->
        finish(state, :duration)

      true ->
        source.sleep.(@interval_ms)
        current = snapshot(source)
        elapsed = current.at_ms - previous.at_ms
        hot = candidates(previous.readings, current.readings, elapsed)
        next = %{state | windows: state.windows + 1}
        capture_or_poll(source, current, hot, elapsed, next)
    end
  end

  defp candidates(previous, current, elapsed) do
    current
    |> Enum.flat_map(fn {pid, count} ->
      case Map.fetch(previous, pid) do
        {:ok, before} when elapsed > 0 and (count - before) * @interval_ms > @threshold * elapsed -> [{pid, count - before}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_pid, delta} -> -delta end)
    |> Enum.take(@top_count)
  end

  defp capture_or_poll(source, current, [], _elapsed, state), do: poll(source, current, state)

  defp capture_or_poll(source, current, hot, elapsed, state) do
    processes =
      Enum.map(hot, fn {pid, delta} ->
        %{pid: pid, reductions: delta, registered_name: source.info.(pid, :registered_name), initial_call: source.info.(pid, :initial_call)}
      end)

    samples = stacks(source, hot, state.deadline, @stack_count, [])
    burst = %{at_ms: current.at_ms, window_ms: elapsed, processes: processes, samples: samples}
    # Rebaseline after capture: stack sampling time must not inflate the next 200 ms delta.
    poll(source, snapshot(source), %{state | bursts: [burst | state.bursts]})
  end

  defp stacks(_source, _hot, _deadline, 0, samples), do: Enum.reverse(samples)

  defp stacks(source, hot, deadline, left, samples) do
    if source.clock.() + @stack_interval_ms <= deadline do
      source.sleep.(@stack_interval_ms)
      traces = Enum.map(hot, fn {pid, _delta} -> {pid, source.info.(pid, :current_stacktrace)} end)
      sample = %{at_ms: source.clock.(), stacks: traces}
      stacks(source, hot, deadline, left - 1, [sample | samples])
    else
      Enum.reverse(samples)
    end
  end

  defp finish(state, reason), do: %{bursts: Enum.reverse(state.bursts), windows: state.windows, stopped: reason}
end
