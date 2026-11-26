defmodule Aiur.Orchestrator.IssueSync.DependencyCapacityTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.PushRouting
  alias Aiur.Orchestrator.State

  test "reports waiting for capacity, not a blocker pause, when a cleared dependency resume is deferred" do
    Publisher.set_tracked_fn(fn _ -> true end)

    blockee_identifier = "its-everdred/aiur#blockee"
    pause_topic = "ticket.#{blockee_identifier}.agent.attention.paused-blocker_dependency"
    deferred_topic = "ticket.#{blockee_identifier}.agent.auto_resume_deferred"
    :ok = Exchange.subscribe(pause_topic)
    :ok = Exchange.subscribe(deferred_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    receive_barrier({:agent_started, ^agent})

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker]}
    current = %{previous | blocked_by: [%{blocker | state: "done"}]}

    blockee = %{
      pid: agent,
      identifier: previous.identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    busy = %{issue: issue("busy", "in-progress"), control: %{status: :working}}

    deferred =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{previous.id => previous},
          running: %{previous.id => blockee, "busy" => busy},
          max_concurrent_agents: 1
        },
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    control_agent_barrier(agent)
    refute_received {:resume_agent, _}
    assert deferred.running[previous.id].pending_auto_resume.resume_kind == :cleared_dependency

    assert_received {:event, %{topic: ^deferred_topic} = alert}
    assert alert["reason"] =~ "waiting for a dispatch slot"
    assert alert["needs_attention"] in [false, nil]

    mailbox_barrier()
    refute_received {:event, %{topic: ^pause_topic}}
  end

  test "retries a cleared dependency resume when a later slot becomes available" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    receive_barrier({:agent_started, ^agent})

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker]}
    current = %{previous | blocked_by: [%{blocker | state: "done"}]}

    blockee = %{
      pid: agent,
      identifier: previous.identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    busy = %{issue: issue("busy", "in-progress"), control: %{status: :working}}

    deferred =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{previous.id => previous},
          running: %{previous.id => blockee, "busy" => busy},
          max_concurrent_agents: 1
        },
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    control_agent_barrier(agent)
    refute_received {:resume_agent, _}
    assert deferred.running[previous.id].pending_auto_resume.resume_kind == :cleared_dependency

    resumed =
      %{deferred | running: %{previous.id => deferred.running[previous.id]}}
      |> PushRouting.reconcile_pending_auto_resumes()

    control_agent_barrier(agent)
    assert_received {:resume_agent, _request_id}
    assert get_in(resumed.running, [previous.id, :control, :status]) == :working
    refute Map.has_key?(resumed.running[previous.id], :pending_auto_resume)
  end
end
