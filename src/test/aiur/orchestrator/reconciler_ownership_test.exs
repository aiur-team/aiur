defmodule Aiur.Orchestrator.ReconcilerOwnershipTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.{Reconciler, State}

  setup do
    parent = self()
    Application.put_env(:aiur, :ownership_poll_fun, fn issue -> send(parent, {:polled, issue.id}) end)
    on_exit(fn -> Application.delete_env(:aiur, :ownership_poll_fun) end)
  end

  test "the poll pass runs ownership for a running ticket and skips others" do
    running = %Issue{id: "run", identifier: "1", state: "in-progress", title: "R", labels: []}
    idle = %Issue{id: "idle", identifier: "2", state: "todo", title: "I", labels: []}
    state = %State{running: %{"run" => %{identifier: "1", issue: running, control: %{status: :working}}}}

    Reconciler.reconcile_running_issue_states([running, idle], state, MapSet.new(["todo", "in-progress"]), MapSet.new(["done"]))

    assert_receive {:polled, "run"}, 1000
    refute_receive {:polled, "idle"}, 100
  end
end
