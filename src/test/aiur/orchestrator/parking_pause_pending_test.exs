defmodule Aiur.Orchestrator.ParkingPausePendingTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.ControlCLI.Park
  alias Aiur.Orchestrator.{ControlLifecycle, Parking, State}

  # open-games, 2026-11-24: a park sent right after a successful pause was refused as
  # "not paused": the pause is admitted before the worker acknowledges it.

  @now ~U[2026-11-24T11:00:00Z]

  test "a park while the pause is still reaching the worker says so" do
    {:reply, reply, _state} = Parking.park_agent_call(state(pending_pause: true), "4")
    assert reply == {:error, :pause_pending}
  end

  test "a park with no pause on the way is still refused as not paused" do
    {:reply, reply, _state} = Parking.park_agent_call(state(pending_pause: false), "4")
    assert reply == {:error, :agent_not_paused}
  end

  test "the CLI waits for the pause and then parks" do
    replies = :counters.new(1, [])

    call = fn "4" ->
      :counters.add(replies, 1, 1)
      if :counters.get(replies, 1) < 3, do: {:error, :pause_pending}, else: {:ok, :pending}
    end

    assert Park.park("4", 30, call) == {:ok, :pending}
    assert :counters.get(replies, 1) == 3
  end

  test "the CLI gives up after its attempts with the pending reason" do
    assert Park.park("4", 1, fn "4" -> {:error, :pause_pending} end) == {:error, :pause_pending}
  end

  defp state(pending_pause: pending?) do
    issue = %Issue{id: "4", identifier: "4", state: "in-progress"}
    entry = %{issue: issue, identifier: "4", pid: nil, ref: nil, control: %{status: :working}}
    lifecycle = ControlLifecycle.new(now: @now)

    lifecycle =
      if pending? do
        {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, pause_attrs(), now: @now)
        lifecycle
      else
        lifecycle
      end

    %State{running: %{"4" => entry}, control_lifecycle: lifecycle, tracker_tasks: %{}}
  end

  defp pause_attrs do
    %{
      request_id: "pause-1",
      issue_id: "4",
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "open-games",
        provider_id: "I_kwDOissue4",
        identifier: "4",
        reason: nil
      },
      action: :pause,
      generation: "worker-1",
      expected_status: :working,
      expected_version: 3,
      requester: :operator
    }
  end
end
