defmodule Aiur.TestSupport.ProgressFormatter do
  @moduledoc false
  use GenServer

  @report_interval_ms 30_000

  @impl true
  def init(_opts) do
    schedule_report(@report_interval_ms)

    {:ok,
     %{
       running: %{},
       file_timings: %{},
       timings_path: System.get_env("AIUR_TEST_TIMINGS_PATH"),
       report_interval_ms: @report_interval_ms
     }}
  end

  @impl true
  def handle_cast({:test_started, %ExUnit.Test{} = test}, state) do
    running = Map.put(state.running, test_key(test), test_name(test))
    {:noreply, %{state | running: running}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    state = %{state | running: Map.delete(state.running, test_key(test))}
    {:noreply, record_file_timing(state, test)}
  end

  def handle_cast({:suite_finished, _times_us}, state) do
    write_file_timings(state)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @impl true
  def handle_info(:report_running, state) do
    if map_size(state.running) > 0 do
      IO.puts(:stdio, "still-running tests:")
      state.running |> Map.values() |> Enum.sort() |> Enum.each(&IO.puts(:stdio, "  #{&1}"))
    end

    write_file_timings(state)
    schedule_report(state.report_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    write_file_timings(state)
    :ok
  end

  defp schedule_report(nil), do: :ok
  defp schedule_report(interval), do: Process.send_after(self(), :report_running, interval)
  defp test_key(test), do: {test.module, test.name}
  defp test_name(test), do: "#{inspect(test.module)} #{test.name}"

  defp record_file_timing(state, test) do
    case test_file(test) do
      nil ->
        state

      file ->
        timing = Map.get(state.file_timings, file, %{tests: 0, total_us: 0, max_us: 0})
        time_us = test.time || 0

        updated = %{
          tests: timing.tests + 1,
          total_us: timing.total_us + time_us,
          max_us: max(timing.max_us, time_us)
        }

        %{state | file_timings: Map.put(state.file_timings, file, updated)}
    end
  end

  defp test_file(%ExUnit.Test{tags: %{file: file}}) when is_binary(file) do
    relative = file |> Path.expand() |> Path.relative_to(File.cwd!())
    if String.starts_with?(relative, "test/"), do: relative
  end

  defp test_file(_test), do: nil

  defp write_file_timings(%{timings_path: path} = state) when is_binary(path) and path != "" do
    rows =
      state.file_timings
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {file, timing} ->
        [file, timing.tests, timing.total_us, timing.max_us]
        |> Enum.map_join("\t", &to_string/1)
      end)

    contents = Enum.join(["path\ttests\ttotal_us\tmax_us" | rows], "\n") <> "\n"
    temp_path = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(temp_path, contents)
    File.rename!(temp_path, path)
    state
  end

  defp write_file_timings(state), do: state
end
