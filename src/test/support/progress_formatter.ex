defmodule Aiur.TestSupport.ProgressFormatter do
  @moduledoc false
  use GenServer

  @report_interval_ms 30_000

  @impl true
  def init(_opts) do
    schedule_report(@report_interval_ms)
    {:ok, %{running: %{}, report_interval_ms: @report_interval_ms}}
  end

  @impl true
  def handle_cast({:test_started, %ExUnit.Test{} = test}, state) do
    running = Map.put(state.running, test_key(test), test_name(test))
    {:noreply, %{state | running: running}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    {:noreply, %{state | running: Map.delete(state.running, test_key(test))}}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @impl true
  def handle_info(:report_running, state) do
    if map_size(state.running) > 0 do
      IO.puts(:stdio, "still-running tests:")
      state.running |> Map.values() |> Enum.sort() |> Enum.each(&IO.puts(:stdio, "  #{&1}"))
    end

    schedule_report(state.report_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp schedule_report(nil), do: :ok
  defp schedule_report(interval), do: Process.send_after(self(), :report_running, interval)
  defp test_key(test), do: {test.module, test.name}
  defp test_name(test), do: "#{inspect(test.module)} #{test.name}"
end
