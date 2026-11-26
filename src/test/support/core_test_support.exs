defmodule Aiur.CoreTestSupport do
  import ExUnit.Assertions

  def stop_test_orchestrator(pid) when is_pid(pid) do
    if Process.alive?(pid), do: stop_live_test_orchestrator(pid)

    :ok
  end

  defp stop_live_test_orchestrator(pid) do
    stop_result =
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, reason -> {:exit, reason}
      end

    case {stop_result, Process.alive?(pid)} do
      {:ok, _} -> :ok
      {{:exit, _reason}, false} -> :ok
      {{:exit, _reason}, true} -> kill_live_test_orchestrator(pid)
    end
  end

  defp kill_live_test_orchestrator(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> flunk("test orchestrator did not stop")
    end
  end

  def wait_for_path(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_path(path, deadline)
  end

  defp do_wait_for_path(path, deadline) do
    cond do
      File.exists?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        do_wait_for_path(path, deadline)
    end
  end
end
