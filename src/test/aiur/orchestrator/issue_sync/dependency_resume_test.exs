defmodule Aiur.Orchestrator.IssueSync.DependencyResumeTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.AgentQueueStore
  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  test "ignores a non-list poll result" do
    state = %State{last_polled_issues: %{"42" => %{id: "42"}}}

    assert IssueSync.sync_polled_issue_state(state, :invalid) == state
  end

  test "resumes a dependency-paused agent when its recorded blocker becomes terminal" do
    Publisher.set_tracked_fn(fn _ -> true end)

    blockee_identifier = "its-everdred/aiur#blockee"
    pause_topic = "ticket.#{blockee_identifier}.agent.attention.paused-blocker_dependency"
    resolved_pause_topic = "#{pause_topic}.resolved"
    cleared_topic = "ticket.#{blockee_identifier}.agent.dependency_cleared"
    :ok = Exchange.subscribe(pause_topic)
    :ok = Exchange.subscribe(resolved_pause_topic)
    :ok = Exchange.subscribe(cleared_topic)

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

    entry = %{
      pid: agent,
      identifier: blockee_identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    resumed =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, running: %{previous.id => entry}, max_concurrent_agents: 2},
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    control_agent_barrier(agent)
    assert_received {:resume_agent, _request_id}
    assert_received {:event, %{topic: ^cleared_topic} = alert}
    assert alert["reason"] =~ "Blocker its-everdred/aiur#blocker reached terminal state done"
    assert alert["needs_attention"] in [false, nil]
    assert get_in(resumed.running, [previous.id, :control, :status]) == :working
    refute Map.has_key?(resumed.running[previous.id], :paused_reason)
    assert_received {:event, %{topic: ^resolved_pause_topic}}
    mailbox_barrier()
    refute_received {:event, %{topic: ^pause_topic}}
  end

  test "keeps a dependency-paused agent parked while its recorded blocker remains active" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    receive_barrier({:agent_started, ^agent})

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker]}
    current = %{previous | blocked_by: [%{blocker | state: "rework"}]}

    entry = %{
      pid: agent,
      identifier: previous.identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    unchanged =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, running: %{previous.id => entry}, max_concurrent_agents: 2},
        [current],
        fn identifiers ->
          assert identifiers == [blocker.id]
          {:ok, [%{blocker | identifier: blocker.id, state: "rework"}]}
        end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    control_agent_barrier(agent)
    refute_received {:resume_agent, _}
    assert get_in(unchanged.running, [previous.id, :control, :status]) == :paused
    assert unchanged.running[previous.id].paused_reason == :blocker_dependency
  end

  test "resumes a dependency-paused agent when its recorded blocker is removed" do
    Publisher.set_tracked_fn(fn _ -> true end)

    blockee_identifier = "its-everdred/aiur#blockee"
    pause_topic = "ticket.#{blockee_identifier}.agent.attention.paused-blocker_dependency"
    cleared_topic = "ticket.#{blockee_identifier}.agent.dependency_cleared"
    :ok = Exchange.subscribe(pause_topic)
    :ok = Exchange.subscribe(cleared_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    receive_barrier({:agent_started, ^agent})

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker]}
    current = %{previous | blocked_by: []}
    :ok = SubscriptionStore.attach(blockee_identifier)
    :ok = SubscriptionStore.attach(blocker.identifier)

    on_exit(fn ->
      SubscriptionStore.stop(blockee_identifier)
      SubscriptionStore.stop(blocker.identifier)
    end)

    entry = %{
      pid: agent,
      identifier: blockee_identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    resumed =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, running: %{previous.id => entry}, max_concurrent_agents: 2},
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    control_agent_barrier(agent)
    assert_received {:resume_agent, _request_id}
    assert_received {:event, %{"reason" => reason, topic: ^cleared_topic}}
    assert reason =~ "Dependency on blocker its-everdred/aiur#blocker was removed"
    assert get_in(resumed.running, [previous.id, :control, :status]) == :working
    mailbox_barrier()
    refute_received {:event, %{topic: ^pause_topic}}
  end

  test "keeps a dependency-paused agent parked while another blocker remains active" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    receive_barrier({:agent_started, ^agent})

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    other_blocker = %{id: "other-blocker", identifier: "its-everdred/aiur#other-blocker", state: "rework"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker, other_blocker]}
    current = %{previous | blocked_by: [%{blocker | state: "done"}, other_blocker]}

    entry = %{
      pid: agent,
      identifier: previous.identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    unchanged =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, running: %{previous.id => entry}, max_concurrent_agents: 2},
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    control_agent_barrier(agent)
    refute_received {:resume_agent, _}
    assert get_in(unchanged.running, [previous.id, :control, :status]) == :paused
  end

  test "rechecks a dependency pause when its blocker is absent from the active poll" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    receive_barrier({:agent_started, ^agent})

    blockee = issue("blockee", "in-progress")
    blocker = issue("blocker", "done")

    entry = %{
      pid: agent,
      identifier: blockee.identifier,
      issue: blockee,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    resumed =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{blockee.id => blockee}, running: %{blockee.id => entry}, max_concurrent_agents: 2},
        [blockee],
        fn identifiers ->
          assert identifiers == [blocker.id]
          {:ok, [%{blocker | identifier: blocker.id}]}
        end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    control_agent_barrier(agent)
    assert_received {:resume_agent, _request_id}
    assert get_in(resumed.running, [blockee.id, :control, :status]) == :working

    {_queue_store, event} = AgentQueueStore.claim_next_deliverable(resumed.queue_store, blockee.identifier)
    assert event.event_type == :blocker_became_terminal
    assert event.body.blocker_issue_identifier == blocker.id
  end

  test "keeps a cleared blocker event off every agent that was not parked on that blocker" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    receive_barrier({:agent_started, ^agent})

    blockee = issue("blockee", "in-progress")
    blocker = issue("blocker", "done")
    unrelated = issue("unrelated", "in-progress")

    entry = %{
      pid: agent,
      identifier: blockee.identifier,
      issue: blockee,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    # Never blocked by anything, and working right now.
    unrelated_entry = %{
      identifier: unrelated.identifier,
      issue: unrelated,
      control: %{status: :working}
    }

    resumed =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{blockee.id => blockee, unrelated.id => unrelated},
          running: %{blockee.id => entry, unrelated.id => unrelated_entry},
          max_concurrent_agents: 4
        },
        [blockee, unrelated],
        fn identifiers ->
          assert identifiers == [blocker.id]
          {:ok, [%{blocker | identifier: blocker.id}]}
        end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    {queue_store, event} = AgentQueueStore.claim_next_deliverable(resumed.queue_store, blockee.identifier)
    assert event.event_type == :blocker_became_terminal

    assert {_queue_store, nil} = AgentQueueStore.claim_next_deliverable(queue_store, unrelated.identifier)
  end

  test "does not resume on a stale blocker set when the blockee is absent from the active poll" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    receive_barrier({:agent_started, ^agent})

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "done"}
    other_blocker = %{id: "other-blocker", identifier: "its-everdred/aiur#other-blocker", state: "in-progress"}

    # The snapshot the agent started with knows only the blocker that cleared.
    stored_blockee = %{issue("blockee", "in-progress") | blocked_by: [%{blocker | state: "in-progress"}]}
    # The tracker has since gained a second, still-open blocker.
    fresh_blockee = %{stored_blockee | blocked_by: [blocker, other_blocker]}

    entry = %{
      pid: agent,
      identifier: stored_blockee.identifier,
      issue: stored_blockee,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    unchanged =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{stored_blockee.id => stored_blockee},
          running: %{stored_blockee.id => entry},
          max_concurrent_agents: 2
        },
        [],
        fn
          ["blocker"] -> {:ok, [%{blocker | identifier: blocker.id}]}
          ["blockee"] -> {:ok, [fresh_blockee]}
        end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    control_agent_barrier(agent)
    refute_received {:resume_agent, _}
    assert get_in(unchanged.running, [stored_blockee.id, :control, :status]) == :paused
    assert unchanged.running[stored_blockee.id].paused_reason == :blocker_dependency

    assert {_queue_store, nil} =
             AgentQueueStore.claim_next_deliverable(unchanged.queue_store, stored_blockee.identifier)
  end
end
