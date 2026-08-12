defmodule Aiur.Orchestrator.PauseResumeTest.CrashingOrchestrator do
  @moduledoc false
  use GenServer

  def init(:ok), do: {:ok, :ok}
  def handle_call(_request, _from, _state), do: raise("control handler blew up")
end

defmodule Aiur.Orchestrator.PauseResumeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.Orchestrator.{PauseResume, State}
  alias Aiur.Orchestrator.PauseResumeTest.CrashingOrchestrator

  # #1634: `:unavailable` reaches the operator as "orchestrator unavailable" —
  # the daemon is not there to answer. A crash raised inside a live, answering
  # orchestrator must not borrow that diagnosis; it has to carry its own reason.
  test "a crash inside a live orchestrator keeps its reason instead of claiming unavailable" do
    {:ok, pid} = GenServer.start(CrashingOrchestrator, :ok)

    capture_log(fn ->
      assert {:error, {:orchestrator_call_failed, reason}} = PauseResume.resume_agent(pid, "repo#44")
      assert inspect(reason) =~ "control handler blew up"
    end)

    # The pause path shares the same wrapper, so it must classify identically.
    {:ok, pause_pid} = GenServer.start(CrashingOrchestrator, :ok)

    capture_log(fn ->
      assert {:error, {:orchestrator_call_failed, _}} = PauseResume.pause_agent(pause_pid, "repo#44")
    end)
  end

  test "a genuinely absent orchestrator still reports unavailable" do
    {:ok, pid} = GenServer.start(CrashingOrchestrator, :ok)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert PauseResume.resume_agent(pid, "repo#44") == {:error, :unavailable}
    assert PauseResume.resume_agent(:no_such_orchestrator_process, "repo#44") == {:error, :unavailable}
  end

  test "sets control status only for a known running entry" do
    state = %State{running: %{"known" => %{control: %{status: :working}}}}

    updated_state = PauseResume.put_running_control_status(state, "known", :paused)

    assert get_in(updated_state.running, ["known", :control, :status]) == :paused
    assert PauseResume.put_running_control_status(state, "missing", :paused) == state
  end

  test "resets the Codex timestamp for a known entry" do
    now = DateTime.utc_now()
    running = %{"known" => %{last_codex_timestamp: nil}}

    assert get_in(PauseResume.reset_last_codex_timestamp(running, "known", now), ["known", :last_codex_timestamp]) == now
    assert PauseResume.reset_last_codex_timestamp(running, "missing", now) == running
  end

  test "only an operator resume resets a max-duration clock" do
    started_at = DateTime.add(DateTime.utc_now(), -60, :second)
    now = DateTime.utc_now()
    running = %{"capped" => %{started_at: started_at, paused_reason: :max_agent_duration}}

    assert %{started_at: ^now} = PauseResume.reset_duration_clock_if_capped(running, "capped", now, true)["capped"]
    refute Map.has_key?(PauseResume.reset_duration_clock_if_capped(running, "capped", now, true)["capped"], :paused_reason)

    assert %{started_at: ^started_at} = PauseResume.reset_duration_clock_if_capped(running, "capped", now, false)["capped"]
    refute Map.has_key?(PauseResume.reset_duration_clock_if_capped(running, "capped", now, false)["capped"], :paused_reason)
  end

  test "preserves unrelated pause markers on resume" do
    running = %{"paused" => %{paused_reason: :operator}}

    assert PauseResume.reset_duration_clock_if_capped(running, "paused", DateTime.utc_now(), true) == running
  end

  test "completed replacement preserves state committed by a rejected admission" do
    issue = %Aiur.Issue{id: "known", identifier: "repo#known", state: "in-progress"}

    running_entry = %{
      issue: issue,
      identifier: issue.identifier,
      completed_provenance: true,
      control: %{status: :completed}
    }

    state = %State{
      running: %{issue.id => running_entry},
      max_concurrent_agents: 1,
      effective_concurrent_agents: 1
    }

    rejected = %{state | claimed: MapSet.new(["durably-tripped"])}

    assert ^rejected =
             PauseResume.dispatch_completed_replacement(state, running_entry, issue,
               admit_fun: fn _state, ^issue, nil ->
                 {:error, :thrash_circuit_open, rejected}
               end,
               replace_fun: fn _, _, _, _ -> flunk("rejected admission must not replace") end
             )
  end
end
