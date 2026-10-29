defmodule Aiur.Orchestrator.TodoDispatchClaimTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, Tracker, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, State}

  defmodule SlowTracker do
    def update_issue_state(identifier, target, opts) do
      send(
        Application.fetch_env!(:aiur, :todo_dispatch_tracker_owner),
        {:state_write_started, self(), identifier, target, opts}
      )

      receive do
        :finish_state_write -> :ok
      end
    end
  end

  defmodule ReplyTracker do
    def update_issue_state(identifier, target, opts) do
      owner = Application.fetch_env!(:aiur, :todo_dispatch_tracker_owner)
      send(owner, {:todo_state_write_attempt, self(), identifier, target, opts})

      receive do
        {:todo_state_write_result, result} -> result
      end
    end
  end

  defmodule RecordingTracker do
    def update_issue_state(identifier, target, opts) do
      owner = Application.fetch_env!(:aiur, :todo_dispatch_tracker_owner)
      send(owner, {:todo_state_write_attempt, self(), identifier, target, opts})
      :ok
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())
    handler = "todo-dispatch-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:aiur, :ticket_transition],
        &__MODULE__.handle_transition/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def handle_transition(event, measurements, meta, pid),
    do: send(pid, {:ticket_transition, event, measurements, meta})

  test "dispatch claims todo in-progress before a runner that never transitions state" do
    candidate = issue("todo-dispatch-claim")
    Application.put_env(:aiur, :memory_tracker_issues, [candidate])
    parent = self()

    state =
      Dispatcher.dispatch_issue(dispatch_state(), candidate, nil, nil,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn dispatched, _recipient, _opts ->
          send(parent, {:todo_runner_issue, dispatched})
          :ok
        end
      )

    assert_receive {:memory_tracker_state_update, "todo-dispatch-claim", "in-progress"}, 1_000

    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{},
                    %{
                      issue_id: "todo-dispatch-claim",
                      expected: "todo",
                      to: "in-progress",
                      writer: :dispatcher,
                      outcome: :ok
                    }},
                   1_000

    assert_receive {:todo_runner_issue, %Issue{state: "todo"}}, 1_000
    assert Map.has_key?(state.running, candidate.id)

    assert {:ok, [%Issue{state: "in-progress"}]} =
             Tracker.fetch_issue_states_by_ids([candidate.id])
  end

  test "a stale todo claim cannot overwrite the newer state and dispatch continues" do
    candidate = issue("todo-write-failure")
    Application.put_env(:aiur, :memory_tracker_issues, [%{candidate | state: "human-review"}])
    parent = self()

    state =
      Dispatcher.dispatch_issue(dispatch_state(), candidate, nil, nil,
        issue_fetcher: fn _ids -> {:ok, [candidate]} end,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn dispatched, _recipient, _opts ->
          send(parent, {:todo_runner_started, dispatched})
        end
      )

    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{},
                    %{
                      issue_id: "todo-write-failure",
                      expected: "todo",
                      to: "in-progress",
                      writer: :dispatcher,
                      outcome: {:error, {:stale_issue_state, "todo", "human-review"}}
                    }},
                   1_000

    assert_receive {:todo_runner_started, ^candidate}, 1_000
    assert Map.has_key?(state.running, candidate.id)

    assert {:ok, [%Issue{state: "human-review"}]} =
             Tracker.fetch_issue_states_by_ids([candidate.id])
  end

  test "slow tracker state write does not delay dispatch or worker start" do
    candidate = issue("todo-slow-write")
    parent = self()
    Application.put_env(:aiur, :todo_dispatch_tracker_owner, self())
    on_exit(fn -> Application.delete_env(:aiur, :todo_dispatch_tracker_owner) end)

    state =
      Dispatcher.do_dispatch_issue(dispatch_state(snapshot_key: self()), candidate, nil, nil,
        todo_dispatch_tracker: SlowTracker,
        runner: fn dispatched, _recipient, _opts ->
          send(parent, {:slow_todo_runner_started, dispatched})
        end
      )

    assert_receive {:state_write_started, tracker_pid, "todo-slow-write", "in-progress", opts},
                   1_000

    assert Keyword.fetch!(opts, :expected_state) == "todo"
    assert_receive {:slow_todo_runner_started, ^candidate}, 1_000
    assert Map.has_key?(state.running, candidate.id)
    assert state.tracker_tasks == %{}

    send(tracker_pid, :finish_state_write)

    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{},
                    %{
                      issue_id: "todo-slow-write",
                      to: "in-progress",
                      writer: :dispatcher,
                      outcome: :ok
                    }},
                   1_000
  end

  test "a transient tracker failure retries the todo claim without blocking the worker" do
    candidate = issue("todo-retry-write")
    parent = self()
    Application.put_env(:aiur, :todo_dispatch_tracker_owner, self())
    on_exit(fn -> Application.delete_env(:aiur, :todo_dispatch_tracker_owner) end)

    state =
      Dispatcher.do_dispatch_issue(dispatch_state(snapshot_key: self()), candidate, nil, nil,
        todo_dispatch_tracker: ReplyTracker,
        runner: fn dispatched, _recipient, _opts ->
          send(parent, {:retry_todo_runner_started, dispatched})
        end
      )

    assert_receive {:todo_state_write_attempt, first_pid, "todo-retry-write", "in-progress", opts},
                   1_000

    assert Keyword.fetch!(opts, :expected_state) == "todo"
    send(first_pid, {:todo_state_write_result, {:error, {:github, :http, %{status: 500}}}})

    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{}, %{issue_id: "todo-retry-write", outcome: {:error, {:github, :http, %{status: 500}}}}},
                   1_000

    assert_receive {:todo_state_write_attempt, second_pid, "todo-retry-write", "in-progress", retry_opts},
                   1_000

    assert Keyword.fetch!(retry_opts, :expected_state) == "todo"
    send(second_pid, {:todo_state_write_result, :ok})

    assert_receive {:ticket_transition, [:aiur, :ticket_transition], %{}, %{issue_id: "todo-retry-write", outcome: :ok}},
                   1_000

    assert_receive {:retry_todo_runner_started, ^candidate}, 1_000
    assert Map.has_key?(state.running, candidate.id)
  end

  test "a failed worker launch does not claim the todo ticket" do
    candidate = issue("todo-failed-launch")
    Application.put_env(:aiur, :todo_dispatch_tracker_owner, self())
    on_exit(fn -> Application.delete_env(:aiur, :todo_dispatch_tracker_owner) end)

    state =
      Dispatcher.do_dispatch_issue(dispatch_state(), candidate, nil, nil,
        todo_dispatch_tracker: RecordingTracker,
        start_runner_task_fun: fn _issue, _runner, _recipient, _context, _opts ->
          {:error, :start_rejected}
        end
      )

    assert Map.get(state.retry_attempts, candidate.id).attempt == 1
    refute Map.has_key?(state.running, candidate.id)
    refute_received {:todo_state_write_attempt, _, "todo-failed-launch", _, _}
  end

  defp dispatch_state(opts \\ []) do
    struct!(State, [max_concurrent_agents: 4, effective_concurrent_agents: 4] ++ opts)
  end

  defp issue(id) do
    %Issue{
      id: id,
      identifier: id,
      title: id,
      state: "todo",
      state_labels: ["todo"],
      selected_backend: "codex",
      labels: ["agent:todo"]
    }
  end
end
