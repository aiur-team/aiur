defmodule Aiur.Orchestrator.BuildQueueClaimProbeTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{BuildQueueClaimProbe, State}

  test "a running entry still carrying todo is claimed ahead of a decline" do
    state = %State{running: %{"7" => %{issue: %Issue{state: "todo"}}}, dispatch_declines: %{"7" => :unauthorized}}
    assert BuildQueueClaimProbe.classify(state, "7") == :claimed
  end

  test "claims, pending retries and scheduled resumes all retain ownership" do
    for state <- [
          %State{claimed: MapSet.new(["7"])},
          %State{retry_attempts: %{"7" => %{attempt: 1}}},
          %State{auto_resume: %{"7" => %{}}}
        ] do
      assert BuildQueueClaimProbe.classify(state, "7") == :claimed
    end
  end

  test "a declined issue retains its reason and an unknown issue is unclaimed" do
    state = %State{dispatch_declines: %{"8" => :unauthorized}}
    assert BuildQueueClaimProbe.classify(state, "8") == {:declined, :unauthorized}
    assert BuildQueueClaimProbe.classify(state, "unknown") == :unclaimed
  end

  test "the batched call classifies every requested id without changing state" do
    state = %State{claimed: MapSet.new(["7"]), dispatch_declines: %{"8" => :unauthorized}}
    expected = %{"7" => :claimed, "8" => {:declined, :unauthorized}, "9" => :unclaimed}
    assert Orchestrator.handle_call({:build_queue_claim_status, ["7", "8", "9"]}, {self(), make_ref()}, state) == {:reply, expected, state}
    assert Orchestrator.handle_call({:build_queue_claim_status, []}, {self(), make_ref()}, state) == {:reply, %{}, state}
  end

  test "status and demand reach a real orchestrator process" do
    server = start_supervised!({Orchestrator, name: nil, initial_poll?: false})
    assert BuildQueueClaimProbe.status(server, ["unknown"]) == %{"unknown" => :unclaimed}
    assert BuildQueueClaimProbe.notify_demand(server, ["7"]) == :ok
    assert Map.has_key?(:sys.get_state(server).queued_demand_hints, "7")
  end

  test "a dead orchestrator answers unavailable for status and demand" do
    server = spawn(fn -> :ok end)
    ref = Process.monitor(server)
    receive_barrier({:DOWN, ^ref, :process, ^server, _})
    assert BuildQueueClaimProbe.status(server, ["7"]) == :unavailable
    assert BuildQueueClaimProbe.notify_demand(server, ["7"]) == :unavailable
  end

  test "a slow orchestrator status times out as unavailable" do
    server = start_supervised!({Orchestrator, name: nil, initial_poll?: false})
    :sys.suspend(server)

    try do
      assert BuildQueueClaimProbe.status(server, ["7"]) == :unavailable
    after
      :sys.resume(server)
    end
  end
end
