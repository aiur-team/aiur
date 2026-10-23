defmodule Aiur.Orchestrator.TodoDispatchClaimTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, Tracker, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, State}

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

  defp dispatch_state, do: %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}

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
