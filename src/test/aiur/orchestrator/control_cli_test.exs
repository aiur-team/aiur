Code.require_file("control_cli/fixture.exs", __DIR__)

defmodule Aiur.Orchestrator.ControlCLITest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{DispatchBudgetStore, Issue}
  alias Aiur.Orchestrator.{ControlLifecycle, Dispatcher, SnapshotStore, StatusReport}

  alias Aiur.Orchestrator.ControlCLI, as: AgentControlCLI
  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  test "pause reports already paused agents as a successful no-op", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

    assert output =~ "aiur: already paused #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    refute_receive {:pause_agent, _request_id}, 100
  end

  test "all-target mutations report that no action was taken" do
    pause_output = capture_io(fn -> AgentControlCLI.pause(:all) end)
    resume_output = capture_io(fn -> AgentControlCLI.resume(:all) end)

    assert pause_output =~ "__AIUR_CONTROL_ERROR__:aiur: pause took no action because there are no running agents"
    assert pause_output =~ "__AIUR_CONTROL_EXIT__:1"
    assert resume_output =~ "__AIUR_CONTROL_ERROR__:aiur: resume took no action because there are no paused agents"
    assert resume_output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  describe "reset-budget" do
    test "clears the latch synchronously and reports the applied reset", %{orchestrator: pid} do
      issue = %Issue{id: "issue-49", identifier: "repo#49", state: "error", title: "Latched"}
      :ok = DispatchBudgetStore.put_lifetime(issue.id, 40)

      :sys.replace_state(pid, fn state ->
        state = put_in(state.dispatch_recovery.codex_thrash_budget[issue.id], %{lifetime: 40, count: 0})
        %{state | running: %{}, last_polled_issues: %{issue.id => issue}}
      end)

      output = capture_io(fn -> AgentControlCLI.reset_budget(["49"]) end)

      # The command reports the APPLIED outcome, not an unverifiable "queued":
      # by the time it prints, both the in-memory and durable latches are zero.
      assert output =~ "aiur: lifetime dispatch budget reset for #49"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"

      state = :sys.get_state(pid)
      assert get_in(state.dispatch_recovery.codex_thrash_budget, [issue.id]) == nil
      assert {:ok, 0} = DispatchBudgetStore.lifetime(issue.id)
      assert :none = Dispatcher.dispatch_latch_status(state, issue.id)
    end

    test "fails loudly instead of claiming a reset when the target cannot be resolved", %{orchestrator: pid} do
      # #2435: an unresolvable target used to print "queued" and exit 0 while
      # nothing happened. The command must fail loudly with a reason so an
      # operator is never left believing the latch cleared. The exact reason
      # depends on the tracker backend (an unknown ticket, or a tracker read
      # failure) — the contract is that it never reports success.
      output = capture_io(fn -> AgentControlCLI.reset_budget(["9999"]) end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: failed to reset lifetime dispatch budget for #9999"
      assert output =~ "__AIUR_CONTROL_EXIT__:1"
      refute output =~ "lifetime dispatch budget reset for #9999"
      _state = :sys.get_state(pid)
    end

    test "fails instead of claiming a reset was applied when the orchestrator is unavailable", %{orchestrator: pid} do
      Process.unregister(Orchestrator)

      try do
        output = capture_io(fn -> AgentControlCLI.reset_budget(["49"]) end)

        assert output =~ "__AIUR_CONTROL_ERROR__:aiur: failed to reset lifetime dispatch budget for #49 (orchestrator unavailable)"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
        refute output =~ "lifetime dispatch budget reset for #49"
      after
        Process.register(pid, Orchestrator)
      end
    end
  end

  test "busy handle_info leaves reset-budget and resume outcomes unknown", %{orchestrator: original} do
    issue = %Issue{id: "issue-49", identifier: "repo#49", state: "in-progress", title: "Budget reset"}
    :ok = DispatchBudgetStore.put_lifetime(issue.id, 40)
    state = :sys.get_state(original)
    state = %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}, last_polled_issues: %{issue.id => issue}}
    state = put_in(state.dispatch_recovery.codex_thrash_budget[issue.id], %{lifetime: 40, count: 0})
    previous_timeout = Application.get_env(:aiur, :control_api_call_timeout_ms)
    Application.put_env(:aiur, :control_api_call_timeout_ms, 20)
    Process.unregister(Orchestrator)
    busy = start_supervised!({__MODULE__.BusyOrchestrator, state})

    try do
      :ok = SnapshotStore.publish(Orchestrator, StatusReport.snapshot_payload(state), state)
      send(busy, {:block, self()})
      receive_barrier(:blocked)

      for {command, description} <- [
            {fn -> AgentControlCLI.reset_budget(["49", "49"]) end, "reset lifetime dispatch budget for #49"},
            {fn -> AgentControlCLI.resume(["44"]) end, "resume #44"}
          ] do
        output = capture_io(command)
        assert output =~ "outcome unknown for #{description}"
        assert output =~ "may still apply"
        assert output =~ "__AIUR_CONTROL_EXIT__:124"
        refute output =~ "failed to"
      end

      assert {:ok, 40} = DispatchBudgetStore.lifetime(issue.id)
      send(busy, :release)
      :sys.get_state(busy)
      assert {:ok, 0} = DispatchBudgetStore.lifetime(issue.id)
    after
      send(busy, :release)
      stop_supervised!(__MODULE__.BusyOrchestrator)
      Process.register(original, Orchestrator)
      SnapshotStore.forget(Orchestrator)
      if previous_timeout, do: Application.put_env(:aiur, :control_api_call_timeout_ms, previous_timeout), else: Application.delete_env(:aiur, :control_api_call_timeout_ms)
    end
  end

  describe "global pause switch" do
    test "pause_global halts the daemon and resume_global lifts it", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state -> %{state | globally_paused: false} end)

      pause_output = capture_io(fn -> AgentControlCLI.pause_global() end)
      assert pause_output =~ "aiur: global pause ON"
      assert pause_output =~ "__AIUR_CONTROL_EXIT__:0"
      assert :sys.get_state(pid).globally_paused

      resume_output = capture_io(fn -> AgentControlCLI.resume_global() end)
      assert resume_output =~ "aiur: global pause OFF"
      assert resume_output =~ "__AIUR_CONTROL_EXIT__:0"
      refute :sys.get_state(pid).globally_paused
    end

    test "status surfaces the global pause banner only while paused", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state -> %{state | globally_paused: true} end)
      assert capture_io(fn -> Aiur.AgentControlCLI.status() end) =~ "GLOBALLY PAUSED"

      :sys.replace_state(pid, fn state -> %{state | globally_paused: false} end)
      refute capture_io(fn -> Aiur.AgentControlCLI.status() end) =~ "GLOBALLY PAUSED"
    end

    test "targeted controls fail truthfully while globally paused", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state -> %{state | globally_paused: true} end)

      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "error: aiur is globally paused; per-ticket resume has no effect."
      assert stderr =~ "Run `aiurdev resume` (no arguments) to lift the global pause."
    end

    test "targeted control preserves a global-pause status timeout as exit 124" do
      Application.put_env(:aiur, :agent_control_cli_global_pause_status_fun, fn -> {:error, :timeout} end)
      on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_global_pause_status_fun) end)

      output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: timed out while reading agent status"
      assert output =~ "__AIUR_CONTROL_EXIT__:124"
    end

    test "global mutation preserves an orchestrator timeout as exit 124" do
      Application.put_env(:aiur, :agent_control_cli_set_global_pause_fun, fn _on?, _source -> {:error, :timeout} end)
      on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_set_global_pause_fun) end)

      output = capture_io(fn -> AgentControlCLI.pause_global() end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: failed to pause the daemon (orchestrator timed out)"
      assert output =~ "__AIUR_CONTROL_EXIT__:124"
    end
  end

  test "pause and resume emit control messages and successful summaries", %{orchestrator: pid} do
    parent = self()

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working, parent)}}
    end)

    pause_output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

    assert pause_output =~ "aiur: paused #44 (was: running)"
    assert pause_output =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:pause_agent, pause_request_id} when is_integer(pause_request_id), 500

    send(pid, {:worker_control_state, "issue-44", :paused})

    assert [%{identifier: "repo#44", state: :paused}] = Orchestrator.status(Orchestrator, 1_000)

    resume_output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert resume_output =~ "aiur: resumed #44 (was: paused)"
    assert resume_output =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:resume_agent, resume_request_id} when is_integer(resume_request_id), 500
  end

  test "resume guards an unexpected action crash with a diagnostic and non-zero marker", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" ->
      raise "resume worker disappeared"
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: resume query failed"
    assert output =~ "resume worker disappeared"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "resume renders structured dispatch and redispatch causes on the marker channel", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-44" => running_entry("issue-44", "repo#44", :paused),
            "issue-45" => running_entry("issue-45", "repo#45", :paused)
          }
      }
    end)

    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn
      "repo#44" -> {:error, {:dispatch_failed, :no_worker_capacity}}
      "repo#45" -> {:error, {:redispatch_deferred, :thrash_circuit_open}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    output = capture_io(fn -> AgentControlCLI.resume(["44", "45"]) end)

    assert output =~ "dispatch failed because no worker capacity is available; retry after a worker slot is free"
    assert output =~ "redispatch deferred by the restart circuit; it clears when the restart window resets or `reset-budget` clears the latch"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
    refute output =~ "(dispatch failed)"
    refute output =~ "(:redispatch_deferred)"
  end

  test "resume preserves the timeout versus unavailable exit-code split", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" -> {:error, :timeout} end)
    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert output =~ "outcome unknown for resume #44"
    refute output =~ "failed to resume"
    assert output =~ "__AIUR_CONTROL_EXIT__:124"
  end

  test "resume confirmation preserves a status timeout as exit 124", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => modern_running_entry("issue-44", "repo#44", :paused)}}
    end)

    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" -> {:ok, {:resumed, 999}} end)
    Application.put_env(:aiur, :agent_control_cli_confirmation_status_fun, fn _server, _timeout -> :timeout end)

    on_exit(fn ->
      Application.delete_env(:aiur, :agent_control_cli_resume_fun)
      Application.delete_env(:aiur, :agent_control_cli_confirmation_status_fun)
    end)

    output = with_resume_confirm_timeout(100, fn -> capture_io(fn -> AgentControlCLI.resume(["44"]) end) end)

    assert output =~ "status unreadable: orchestrator timed out"
    assert output =~ "__AIUR_CONTROL_EXIT__:124"
  end

  # Each confirmation read is capped by the time left, so the last poll before
  # the deadline gets only a sliver of the budget. On a loaded coverage shard
  # that sliver is routinely too short, and a status the CLI had already read
  # was then reported as unreadable with exit 124 (#2632, #2690). A read that
  # misses the final sliver must not erase what an earlier read observed.
  test "resume confirmation keeps the last observed status when only a late read times out", %{orchestrator: pid} do
    entry = modern_running_entry("issue-44", "repo#44", :paused) |> Map.put(:paused_reason, :operator_pause)

    attrs = %{
      request_id: 999,
      issue_id: "issue-44",
      tracker_identity: entry.issue.tracker_identity,
      action: :resume,
      generation: 1,
      expected_status: :paused,
      expected_version: 0,
      requester: :operator
    }

    lifecycle = ControlLifecycle.new(now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.accept(lifecycle, 999, 1, now: ~U[2026-08-11 12:00:01Z])

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => entry}, control_lifecycle: lifecycle}
    end)

    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" -> {:ok, {:resumed, 999}} end)

    readable_statuses =
      pid
      |> :sys.get_state()
      |> StatusReport.agent_statuses(fn _timeout -> {:unavailable, nil} end)

    reads = :counters.new(1, [])

    Application.put_env(:aiur, :agent_control_cli_confirmation_status_fun, fn _server, _timeout ->
      :counters.add(reads, 1, 1)
      if :counters.get(reads, 1) == 1, do: readable_statuses, else: :timeout
    end)

    on_exit(fn ->
      Application.delete_env(:aiur, :agent_control_cli_resume_fun)
      Application.delete_env(:aiur, :agent_control_cli_confirmation_status_fun)
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = with_resume_confirm_timeout(400, fn -> capture_io(fn -> AgentControlCLI.resume(["44"]) end) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1\n"
      end)

    assert :counters.get(reads, 1) > 1
    assert stderr =~ "aiur: resume request accepted for #44"
    assert stderr =~ "confirmation window elapsed"
    assert stderr =~ "control status remains paused"
    refute stderr =~ "status unreadable"
  end

  test "mixed target results exit non-zero when any target fails", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.pause(["44", "45"]) end)

        assert output =~ "aiur: already paused #44"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to pause #45 (no running agent)"
  end

  test "all failed targets exit non-zero" do
    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["45"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume #45 (no running agent)"
  end

  test "resume explains that a tracker label failure will not hold", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" ->
      {:error, {:pause_override_clear_failed, :missing_permission}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
        refute output =~ "aiur: resumed"
      end)

    assert stderr =~ "aiur: failed to resume #44"
    assert stderr =~ "resume will not hold"
    assert stderr =~ "agent:paused"
    assert stderr =~ "missing_permission"
  end

  test "running resume is a successful no-op", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert output =~ "aiur: already running #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end
end

defmodule Aiur.Orchestrator.ControlCLITest.BusyOrchestrator do
  use GenServer

  def start_link(state), do: GenServer.start_link(__MODULE__, state, name: Aiur.Orchestrator)
  @impl true
  def init(state), do: {:ok, state}
  @impl true
  def handle_info({:block, parent}, state) do
    send(parent, :blocked)
    receive do: (:release -> {:noreply, state})
  end

  def handle_info(message, state), do: Aiur.Orchestrator.handle_info(message, state)
  @impl true
  def handle_call(request, from, state), do: Aiur.Orchestrator.handle_call(request, from, state)
end
