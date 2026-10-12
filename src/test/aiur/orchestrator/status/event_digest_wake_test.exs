defmodule Aiur.Orchestrator.Status.EventDigestWakeTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.OperatorMessages

  test "event digest wakes a sleeping agent task" do
    orchestrator_name = Module.concat(__MODULE__, :SleepingEventDigestOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-sleeping" => running_entry("issue-sleeping", "MT-SLEEP", :sleeping, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-SLEEP",
               %{
                 topic: "ticket.MT-SLEEP.pr.review_comment",
                 source: :github,
                 author_trusted?: true,
                 message: "please fix",
                 comment: %{"body" => "please fix"}
               }
             })

    assert_receive {:agent_queue_updated, "MT-SLEEP", item_id, true}, 1000

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              body: %{events: [%{message: "please fix", comment: %{"body" => "please fix"}}]},
              delivery: %{interrupt_requested: true, priority: :now}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-SLEEP")
  end

  test "event digest does not auto-wake a manually paused agent task" do
    orchestrator_name = Module.concat(__MODULE__, :PausedEventDigestOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-PAUSED",
               %{
                 topic: "ticket.MT-PAUSED.pr.review_comment",
                 source: :github,
                 author_trusted?: true,
                 message: "please fix",
                 comment: %{"body" => "please fix"}
               }
             })

    assert_receive {:agent_queue_updated, "MT-PAUSED", item_id, false}, 1000

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: false, priority: :later}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-PAUSED")
  end

  test "system default-branch push wakes a sleeping (standby) agent task" do
    orchestrator_name = Module.concat(__MODULE__, :SleepingMainPushOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-main-sleep" => running_entry("issue-main-sleep", "MT-MAIN-SLEEP", :sleeping, worker_pid)
          }
      }
    end)

    # Same path a real push takes: each agent's SubscriptionStore enqueues the
    # `system.<base>.branch.push` it is universally subscribed to.
    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-MAIN-SLEEP",
               %{topic: "system.main.branch.push", sha: "abc123", message: "main advanced"}
             })

    # Standby agent is woken so it can pull main and resume in its held slot.
    assert_receive {:agent_queue_updated, "MT-MAIN-SLEEP", item_id, true}, 1000

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: true, priority: :now}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-MAIN-SLEEP")
  end

  test "system default-branch push does not wake a manually paused agent task" do
    orchestrator_name = Module.concat(__MODULE__, :PausedMainPushOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-main-paused" => running_entry("issue-main-paused", "MT-MAIN-PAUSED", :paused, worker_pid)
          }
      }
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-MAIN-PAUSED",
               %{topic: "system.main.branch.push", sha: "abc123", message: "main advanced"}
             })

    # A manual pause is never woken by a main update; the notice waits in queue
    # until the operator resumes.
    assert_receive {:agent_queue_updated, "MT-MAIN-PAUSED", item_id, false}, 1000

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: false, priority: :later}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-MAIN-PAUSED")
  end

  test "system default-branch push does not interrupt a working agent mid-turn" do
    orchestrator_name = Module.concat(__MODULE__, :WorkingMainPushOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      ActiveTurns.mark_closed("MT-MAIN-WORK", "turn-active", :test_cleanup)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)
    :ok = ActiveTurns.put("MT-MAIN-WORK", "turn-active")

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-main-work" => running_entry("issue-main-work", "MT-MAIN-WORK", :working, worker_pid)
          }
      }
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-MAIN-WORK",
               %{topic: "system.main.branch.push", sha: "abc123", message: "main advanced"}
             })

    # The headline acceptance criterion: a main update never interrupts an
    # in-flight turn. The notice is queued NON-interrupting and seen at the next
    # turn boundary, leaving whether/when to pull main to the agent.
    assert_receive {:agent_queue_updated, "MT-MAIN-WORK", item_id, false}, 1000

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: false, priority: :later}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-MAIN-WORK")
  end

  test "event digest wakes a running agent with no active turn" do
    orchestrator_name = Module.concat(__MODULE__, :IdleEventDigestOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-idle-turn" => running_entry("issue-idle-turn", "MT-IDLE-TURN", :working, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-IDLE-TURN",
               %{topic: "ticket.MT-IDLE-TURN.pr.review_comment", comment: %{body: "please fix"}}
             })

    assert_receive {:agent_queue_updated, "MT-IDLE-TURN", item_id, true}, 1000

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: true, priority: :now}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-IDLE-TURN")
  end

  test "untrusted event digest keeps checkpoint delivery while a turn is active" do
    orchestrator_name = Module.concat(__MODULE__, :UntrustedActiveEventDigestOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      ActiveTurns.mark_closed("MT-WORK", "turn-active", :test_cleanup)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)
    :ok = ActiveTurns.put("MT-WORK", "turn-active")

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-working" => running_entry("issue-working", "MT-WORK", :working, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-WORK",
               %{topic: "ticket.MT-WORK.pr.review_comment", comment: %{body: "please fix"}}
             })

    assert_receive {:agent_queue_updated, "MT-WORK", item_id, false}, 1000

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: false, priority: :later}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-WORK")
  end

  test "trusted PR review comment wakes a running agent with an active turn" do
    orchestrator_name = Module.concat(__MODULE__, :TrustedActiveReviewCommentOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      ActiveTurns.mark_closed("MT-WORK-REVIEW", "turn-active-review", :test_cleanup)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)
    :ok = ActiveTurns.put("MT-WORK-REVIEW", "turn-active-review")

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-working-review" => running_entry("issue-working-review", "MT-WORK-REVIEW", :working, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-WORK-REVIEW",
               %{
                 topic: "ticket.MT-WORK-REVIEW.pr.review_comment",
                 source: :github,
                 author_trusted?: true,
                 comment: %{body: "please fix"}
               }
             })

    assert_receive {:agent_queue_updated, "MT-WORK-REVIEW", item_id, true}, 1000

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: true, priority: :now}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-WORK-REVIEW")
  end

  test "operator message wakes a running agent with no active turn" do
    orchestrator_name = Module.concat(__MODULE__, :SleepingOperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-sleeping-chat" => running_entry("issue-sleeping-chat", "MT-SLEEP-CHAT", :sleeping, worker_pid)}}
    end)

    assert {:ok, request_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-SLEEP-CHAT", %{
               kind: :text,
               body: "please address the review"
             })

    assert_receive {:agent_queue_updated, "MT-SLEEP-CHAT", ^request_id, true}, 1000

    assert {:ok,
            %{
              id: ^request_id,
              category: :operator_message,
              delivery: %{interrupt_requested: false, priority: :next}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-SLEEP-CHAT")
  end
end
