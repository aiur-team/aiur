defmodule Aiur.Orchestrator.CancellationObservationTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.Cancellation.Observation

  @now ~U[2026-10-24 18:30:00Z]

  test "reports the selected process exit with its opaque handle and exit status" do
    pid = start_test_process(fn -> exit_on_stop() end)

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
    pid = start_test_process(fn -> ignore_stop() end)

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

  test "a runner exit with a lingering OS process reports still_running" do
    pid = start_test_process(fn -> exit_on_stop() end)

    result =
      observe_after_stop(
        pid,
        "NUC-42:attempt-os-lingers",
        fn target ->
          send(target, :stop)
          :ok
        end,
        100,
        shell_alive?: true
      )

    assert %{process: %{status: "still_running", exit_status: nil, exited_at: nil}} = result
    refute Process.alive?(pid)
  end

  test "a runner exit without an OS identity cannot claim confirmed exit" do
    pid = start_test_process(fn -> exit_on_stop() end)
    monitor = Process.monitor(pid)
    send(pid, :stop)

    result =
      Observation.observe_exit(
        monitor,
        pid,
        %{handle: "NUC-42:identity-missing"},
        "NUC-42",
        :ok,
        timeout_ms: 100,
        now_fun: fn -> @now end
      )

    assert %{process: %{status: "kill_failed", exit_status: nil, exited_at: nil}} = result
  end

  test "exit reasons are reduced to the closed wire enum" do
    assert %{process: %{exit_status: "shutdown"}} =
             Observation.result("NUC-42", "handle", :exited, {:shutdown, :cancelled}, @now)

    assert %{process: %{exit_status: "unknown"}} =
             Observation.result("NUC-42", "handle", :exited, {:unexpected, :detail}, @now)
  end

  test "a rejected stop request reports kill_failed while the process remains alive" do
    pid = start_test_process(fn -> ignore_stop() end)

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

  defp observe_after_stop(pid, handle, stop_fun, timeout_ms, opts \\ []) do
    monitor = Process.monitor(pid)
    stop_result = Observation.request_stop(stop_fun, pid)

    observation_opts =
      [
        timeout_ms: timeout_ms,
        os_exit_timeout_ms: 0,
        now_fun: fn -> @now end,
        reap_fun: fn _stage -> :reaped end,
        shell_alive_fun: fn _stage -> Keyword.get(opts, :shell_alive?, false) end
      ]

    Observation.observe_exit(
      monitor,
      pid,
      %{handle: handle, headless_os_pid: 42_424},
      "NUC-42",
      stop_result,
      observation_opts
    )
  end

  defp ignore_stop do
    receive do
      :stop -> ignore_stop()
    end
  end

  defp start_test_process(fun), do: start_supervised!({Task, fun}, id: make_ref())
end
