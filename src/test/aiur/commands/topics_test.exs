Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.TopicsTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Commands.Topics
  alias Aiur.ExecutorEvents

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :executor_state_dir, previous),
        else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    :ok = ExecutorEvents.subscribe("executor.#")
    :ok
  end

  test "worker topic remains byte-identical, including missing attribution" do
    {:ok, decision} = DecisionValidation.normalize(%{question: "Choose?", blocking: false}, ticket: %{identifier: "123"})
    assert Topics.lifecycle(decision, "answered") == "ticket.123.agent.decision.answered"
    assert Topics.lifecycle(%{decision | requester: %{kind: :worker}}, "answered") == "ticket.123.agent.decision.answered"
  end

  test "executor requester uses the Executor namespace" do
    {:ok, decision} = DecisionValidation.normalize(%{question: "Choose?", blocking: false}, ticket: %{identifier: "123"})
    assert Topics.lifecycle(%{decision | requester: %{kind: :executor}}, "answered") == "executor.decision.answered"
  end

  test "executor request is journaled once and lifecycle never uses a fake ticket", %{dir: dir} do
    pid = start_store!(dir)
    :ok = Exchange.subscribe("ticket.executor.#")

    assert {:ok, %{decision: decision}} =
             request(pid, %{question: "Choose<!-- hidden --> scope?", blocking: true}, ticket: %{identifier: "executor"}, requester: %{kind: :executor}, origin: :executor_cli)

    assert {:ok, [event]} = ExecutorEvents.replay(["executor.decision.requested"], 0)
    assert event["decision_id"] == decision.decision_id
    assert event["decision_version"] == decision.version
    assert event["title"] == "Choose scope?"
    assert "title" in event["untrusted_fields"]
    assert event["source"] == "internal"

    assert {:ok, %{status: :accepted}} = DecisionStore.expire(decision.decision_id, "agent_not_running", [], pid)
    assert {:ok, [expired]} = ExecutorEvents.replay(["executor.decision.expired"], 0)
    assert expired["decision_id"] == decision.decision_id
    assert expired["event_type"] == "decision_expired"
    refute_received {:event, %{topic: "ticket.executor.agent.decision.requested"}}
    refute_received {:event, %{topic: "ticket.executor.agent.decision.expired"}}
    GenServer.stop(pid)
  end

  test "executor defer retains the existing rich notification exactly once", %{dir: dir} do
    pid = start_store!(dir)

    assert {:ok, %{decision: decision}} =
             request(pid, %{question: "Choose deferred scope?", blocking: false}, ticket: %{identifier: "executor"}, requester: %{kind: :executor})

    assert {:ok, %{status: :accepted}} =
             DecisionStore.defer(decision.decision_id, [expected_version: decision.version, actor: %{kind: :operator, id: "operator"}], pid)

    assert {:ok, [event]} = ExecutorEvents.replay(["executor.decision.deferred"], 0)
    assert event["decision_id"] == decision.decision_id
    assert event["title"] == decision.question
    assert event["options"] == []
    assert event["issue_identifier"] == "executor"
    assert event["provenance"] == "operator_dashboard"
    assert event["renotify"] == false
    GenServer.stop(pid)
  end

  # Characterizes existing worker fan-out; guards the new Executor-only branch.
  test "worker request still publishes ticket and Executor request events", %{dir: dir} do
    pid = start_store!(dir)
    :ok = Exchange.subscribe("ticket.979.agent.decision.requested")
    assert {:ok, %{decision: decision}} = request(pid, %{question: "Worker scope?", blocking: false})
    id = decision.decision_id
    assert_receive {:event, %{"decision_id" => ^id, topic: "ticket.979.agent.decision.requested", digest_source: :orchestrator}}, 1000
    assert {:ok, [event]} = ExecutorEvents.replay(["executor.decision.requested"], 0)
    assert event["decision_id"] == id
    assert event["issue_identifier"] == "979"
    GenServer.stop(pid)
  end

  test "Executor journal failure leaves request writable and schedules retry", %{dir: dir} do
    journal_dir = Path.join(dir, "unavailable")
    File.write!(journal_dir, "not a directory")
    Application.put_env(:aiur, :executor_state_dir, journal_dir)
    parent = self()

    scheduler = fn _server, message, _delay ->
      send(parent, {:scheduled, message})
      make_ref()
    end

    pid = start_store!(dir, dispatch_scheduler: scheduler)

    capture_log(fn ->
      assert {:ok, %{decision: decision}} =
               request(pid, %{question: "Recover?", blocking: false}, ticket: %{identifier: "executor"}, requester: %{kind: :executor})

      id = decision.decision_id
      assert_receive {:scheduled, {:retry_executor_request_notification, ^id, 1, 1}}, 1000
      assert {:ok, ^decision} = DecisionStore.get(id, pid)
      assert DecisionStore.health(pid) == :writable
    end)

    GenServer.stop(pid)
  end
end
