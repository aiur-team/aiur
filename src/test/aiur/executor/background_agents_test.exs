Code.require_file("../conversation/journal_support.exs", __DIR__)

defmodule Aiur.Executor.BackgroundAgentsTest do
  use ExUnit.Case, async: false

  alias Aiur.Conversation.TestSupport
  alias Aiur.Executor.{BackgroundAgents, CapabilityProvider, Session, SessionIngest}

  setup context do
    context = TestSupport.setup(context)
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(context.root, "executor"))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :executor_state_dir, value)
        :error -> Application.delete_env(:aiur, :executor_state_dir)
      end
    end)

    start_supervised!({Session, instance_key: "background-agents"})
    timer = start_supervised!({Agent, fn -> ~U[2026-11-20 00:00:00Z] end})
    start_supervised!({SessionIngest, pubsub: context.pubsub})
    start_supervised!({BackgroundAgents, pubsub: context.pubsub, clock: fn -> Agent.get(timer, & &1) end})
    :ok = Phoenix.PubSub.subscribe(context.pubsub, "executor_hook")
    Map.put(context, :timer, timer)
  end

  test "unsupported is distinct from an empty supported list" do
    assert {:unsupported, :no_attached_harness} = BackgroundAgents.snapshot()

    assert {:ok, _binding} = Session.attach(%{harness: "claude"})
    assert {:ok, [], _observed_since} = BackgroundAgents.snapshot()
  end

  test "Claude start and stop yields a bounded finished row with last message", %{timer: timer} do
    assert {:ok, _} = Session.attach(%{harness: "claude"})
    dispatch("SessionStart", %{"source" => "startup"})
    assert {:ok, binding} = Session.current()

    dispatch("SubagentStart", %{"agent_id" => "child", "agent_type" => "worker"})
    assert_receive {:executor_hook, %{event: "SubagentStart"}}, 1000
    Agent.update(timer, &DateTime.add(&1, 1, :second))
    dispatch("SubagentStop", %{"agent_id" => "child", "agent_type" => "worker", "last_assistant_message" => String.duplicate("x", 510)})
    assert_receive {:executor_hook, %{event: "SubagentStop"}}, 1000

    assert {:ok, [row], observed_since} = BackgroundAgents.snapshot()
    assert row.agent_id == "child"
    assert row.agent_type == "worker"
    assert row.state == :finished
    assert %DateTime{} = row.started_at
    assert DateTime.compare(row.started_at, DateTime.from_iso8601(binding.attached_at) |> elem(1)) == :gt
    assert %DateTime{} = row.stopped_at
    assert DateTime.compare(row.stopped_at, row.started_at) == :gt
    assert byte_size(row.last_message) == 500
    assert observed_since == ~U[2026-11-20 00:00:00Z]
  end

  test "stop without start creates a finished row with no start" do
    assert {:ok, _} = Session.attach(%{harness: "claude"})
    dispatch("SessionStart", %{"source" => "startup"})
    assert {:ok, _} = Session.current()
    dispatch("SubagentStop", %{"agent_id" => "missed", "last_assistant_message" => "done"})
    assert_receive {:executor_hook, %{event: "SubagentStop"}}, 1000

    assert {:ok, [row], _} = BackgroundAgents.snapshot()
    assert row.state == :finished
    assert row.started_at == nil
    assert row.last_message == "done"
  end

  test "Claude task hooks use task_id and retain completed tasks" do
    assert {:ok, _} = Session.attach(%{harness: "claude"})
    dispatch("SessionStart", %{"source" => "startup"})
    assert {:ok, _} = Session.current()

    dispatch("TaskCreated", %{"task_id" => "task-42"})
    assert_receive {:executor_hook, %{event: "TaskCreated", task_id: "task-42"}}, 1000
    assert {:ok, [running], _} = BackgroundAgents.snapshot()
    assert running.agent_id == "task-42"
    assert running.state == :running

    dispatch("TaskCompleted", %{"task_id" => "task-42"})
    assert_receive {:executor_hook, %{event: "TaskCompleted", task_id: "task-42"}}, 1000
    assert {:ok, [finished], _} = BackgroundAgents.snapshot()
    assert finished.agent_id == "task-42"
    assert finished.state == :finished
  end

  test "Codex reports fields as unverified and provider maps unavailable reason through closed enum" do
    assert {:ok, _} = Session.attach(%{harness: "codex"})

    assert %{state: :degraded, reason: :unknown, detail: "fields_unverified"} =
             CapabilityProvider.evaluate(%{}, background_agents_fun: &BackgroundAgents.snapshot/0)["executor.background_agents"]
  end

  defp dispatch(event, extra) do
    raw = Map.merge(%{"hook_event_name" => event, "session_id" => "session", "pid" => "123"}, extra)
    SessionIngest.dispatch(raw, "claude")
  end
end
