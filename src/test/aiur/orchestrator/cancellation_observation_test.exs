defmodule Aiur.Orchestrator.CancellationObservationTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.Cancellation.Observation

  @now ~U[2026-10-24 18:30:00Z]

  test "reports the selected process exit with its opaque handle and exit status" do
    pid = spawn(fn -> exit_on_stop() end)
    on_exit(fn -> stop_if_alive(pid) end)

    assert %{
             contract: "aiur.ticket_cancel",
             contract_version: 1,
             issue_identifier: "NUC-42",
             tracker_state: "cancelled",
             process: %{
               handle: "NUC-42:attempt-1",
               status: "exited",
               exit_status: "shutdown",
               exited_at: "2026-10-24T18:30:00Z",
               observed_at: "2026-10-24T18:30:00Z"
             }
           } =
             observe_after_stop(
               pid,
               "NUC-42:attempt-1",
               fn target ->
                 send(target, :stop)
                 :ok
               end,
               100
             )

    refute Process.alive?(pid)
  end

  test "a process that ignores the stop request reports still_running after the bound" do
    pid = spawn(fn -> ignore_stop() end)
    on_exit(fn -> stop_if_alive(pid) end)

    result =
      observe_after_stop(
        pid,
        "NUC-42:attempt-2",
        fn target ->
          send(target, :stop)
          :ok
        end,
        10
      )

    assert %{
             process: %{
               status: "still_running",
               exit_status: nil,
               exited_at: nil,
               observed_at: "2026-10-24T18:30:00Z"
             }
           } = result

    assert Process.alive?(pid)
  end

  test "a rejected stop request reports kill_failed while the process remains alive" do
    pid = spawn(fn -> ignore_stop() end)
    on_exit(fn -> stop_if_alive(pid) end)

    result =
      observe_after_stop(pid, "NUC-42:attempt-3", fn _target -> {:error, :refused} end, 10)

    assert %{process: %{status: "kill_failed", exit_status: nil, exited_at: nil}} = result
    assert Process.alive?(pid)
  end

  defp exit_on_stop do
    receive do
      :stop -> exit(:shutdown)
    end
  end

  defp observe_after_stop(pid, handle, stop_fun, timeout_ms) do
    monitor = Process.monitor(pid)
    stop_result = Observation.request_stop(stop_fun, pid)

    Observation.observe_exit(monitor, pid, handle, "NUC-42", stop_result,
      timeout_ms: timeout_ms,
      now_fun: fn -> @now end
    )
  end

  defp ignore_stop do
    receive do
      :stop -> ignore_stop()
    end
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end
end
