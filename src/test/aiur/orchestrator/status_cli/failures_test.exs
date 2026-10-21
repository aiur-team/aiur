Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliFailuresTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.Orchestrator.StatusCLI, as: AgentControlCLI

  test "status distinguishes a bounded query timeout", %{orchestrator: pid} do
    schedulers = System.schedulers_online()
    load = schedulers * 2.0
    previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{load} 1.0 1.0 1/1 1"} end)

    on_exit(fn ->
      if previous_loadavg,
        do: Application.put_env(:aiur, :loadavg_source_override, previous_loadavg),
        else: Application.delete_env(:aiur, :loadavg_source_override)
    end)

    :sys.suspend(pid)

    try do
      output = capture_io(fn -> AgentControlCLI.status(status_timeout_ms: 1) end)

      assert output =~
               "LOAD (local fallback diagnostic) #{load} threshold=#{schedulers * 1.5} schedulers=#{schedulers} " <>
                 "(local host sample; over fallback load threshold, PSI governs dispatch when available)"

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query timed out after 1ms; outcome is unknown"
      assert output =~ "__AIUR_CONTROL_EXIT__:124"

      # #1731: the old wording asserted a cause ("daemon may be
      # scheduler-saturated") that was measurably wrong — the run queue was 1
      # and one process was head-of-line blocked. The replacement must not just
      # drop the false claim, it must print the evidence an operator would
      # otherwise gather by hand. `Process.info/2` reads a suspended process
      # fine, which is exactly why it works when the daemon will not answer.
      assert output =~ "Orchestrator mailbox="

      # The current function is the load-bearing half: it names *where* the
      # process is parked in `:sys.suspend_loop/6`, as #1731 pinpointed
      # `:gen.do_call/4`. Status is unasserted: the query's own message can wake
      # the process to scan its mailbox, so it may read `running` (#3891).
      assert output =~ ~r/status=\w+ in :sys\.suspend_loop\/6/
      assert output =~ "means one process is stuck, not that the host is busy"
    after
      :sys.resume(pid)
    end
  end

  test "status preserves a bounded global-pause query timeout" do
    output =
      capture_io(fn ->
        AgentControlCLI.status(
          status_timeout_ms: 1_000,
          global_pause_status: {:error, :timeout}
        )
      end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query timed out after 1s; outcome is unknown"
    assert output =~ "__AIUR_CONTROL_EXIT__:124"
  end

  # #1684: `aiur status` exited non-zero printing nothing at all, which reads
  # exactly like a healthy idle fleet. Two independent guarantees below: the
  # render path survives a stalled config store, and anything that still goes
  # wrong says so in one line and carries an exit marker.
  describe "status never exits silently (#1684)" do
    test "renders the table when the config store is stalled", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
      end)

      store = Process.whereis(WorkflowStore)
      Application.put_env(:aiur, :workflow_store_call_timeout_ms, 25)
      :sys.suspend(store)

      on_exit(fn ->
        if Process.alive?(store), do: :sys.resume(store)
        Application.delete_env(:aiur, :workflow_store_call_timeout_ms)
      end)

      output = capture_io(fn -> AgentControlCLI.status() end)

      assert output =~ "repo#44"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      refute output =~ "__AIUR_CONTROL_ERROR__"
    end

    test "an unexpected crash is reported in one line with a non-zero exit" do
      Application.put_env(:aiur, :supervision_health_status_fun, fn ->
        raise ArgumentError, "config is unreadable\nsecond line"
      end)

      output = capture_io(fn -> AgentControlCLI.status() end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query failed (config is unreadable second line)"
      assert output =~ "__AIUR_CONTROL_EXIT__:1"
    end

    test "an unexpected process exit is reported instead of killing the caller" do
      Application.put_env(:aiur, :supervision_health_status_fun, fn -> exit(:boom) end)

      output = capture_io(fn -> AgentControlCLI.status() end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query failed (process exited: :boom)"
      assert output =~ "__AIUR_CONTROL_EXIT__:1"
    end

    test "an unexpected GenServer timeout keeps the timeout wording and budget" do
      Application.put_env(:aiur, :supervision_health_status_fun, fn ->
        exit({:timeout, {GenServer, :call, [:some_server, :some_request, 8_000]}})
      end)

      output = capture_io(fn -> AgentControlCLI.status() end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: status query timed out after 8s; outcome is unknown"
      assert output =~ "__AIUR_CONTROL_EXIT__:124"
    end
  end
end
