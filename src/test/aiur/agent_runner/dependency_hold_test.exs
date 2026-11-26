defmodule Aiur.AgentRunner.DependencyHoldTest do
  # open-games #632 (blocked_by #635, open) kept a live worker after a rework,
  # and the rework reason and a later message each started turns there. A fresh
  # dispatch would have waited for #635; a worker that never exits must wait too.
  use Aiur.TestSupport

  alias Aiur.AgentRunner.{DependencyHold, QueueDrain, TurnLoop}
  alias Aiur.Issue

  defmodule ClaimRecorder do
    use GenServer

    def start_link(report), do: GenServer.start_link(__MODULE__, report)

    @impl true
    def init(report), do: {:ok, report}

    @impl true
    def handle_call(request, _from, report) do
      send(report, {:claimed, request})
      {:reply, :empty, report}
    end
  end

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_active_states: ["todo", "in-progress", "rework"])
    :ok
  end

  @open_blocker %{id: "635", identifier: "635", state: "todo"}
  @closed_blocker %{id: "635", identifier: "635", state: "closed"}

  defp issue(state), do: %Issue{id: "632", identifier: "632", title: "t", state: state, state_labels: [state], labels: ["agent:#{state}"], blocked_by: []}

  defp opts(blocker, current_state) do
    [
      blocked_by_hydrator: fn issue -> {:ok, %{issue | blocked_by: [blocker]}} end,
      issue_state_fetcher: fn ["632"] -> {:ok, [issue(current_state)]} end
    ]
  end

  test "a rework or todo ticket with an open blocker is held, read from its current state" do
    # The runner still holds human-review; the CI lifecycle has since written rework.
    assert DependencyHold.held?(issue("human-review"), opts(@open_blocker, "rework"))
    assert DependencyHold.held?(issue("todo"), opts(@open_blocker, "todo"))
  end

  test "a closed blocker, a state dispatch never holds, or an unreadable list does not hold" do
    refute DependencyHold.held?(issue("rework"), opts(@closed_blocker, "rework"))
    refute DependencyHold.held?(issue("human-review"), opts(@open_blocker, "human-review"))
    refute DependencyHold.held?(issue("rework"), blocked_by_hydrator: fn _ -> {:error, :github_budget_hold} end)
  end

  test "the turn loop ends the run instead of continuing a held rework" do
    fetcher = fn ["632"] -> {:ok, [issue("rework")]} end

    assert {:done, %Issue{state: "rework"}} = TurnLoop.continue_with_issue?(issue("rework"), fetcher, opts(@open_blocker, "rework"))
    assert {:continue, %Issue{}} = TurnLoop.continue_with_issue?(issue("rework"), fetcher, opts(@closed_blocker, "rework"))
  end

  test "a parked worker woken by queued input leaves it queued while held" do
    {:ok, orchestrator} = ClaimRecorder.start_link(self())
    send(self(), {:agent_queue_updated, "632", 447})

    assert :ok = QueueDrain.wait_for_operator_message(%{}, issue("human-review"), nil, orchestrator, nil, opts(@open_blocker, "rework"))
    refute_received {:claimed, _}
  end

  test "an unblocked parked worker still claims the queued input" do
    {:ok, orchestrator} = ClaimRecorder.start_link(self())
    send(self(), {:agent_queue_updated, "632", 447, true})
    send(self(), :noop_park_timeout)

    assert :ok = QueueDrain.wait_for_operator_message(%{}, issue("rework"), nil, orchestrator, nil, opts(@closed_blocker, "rework"))
    assert_received {:claimed, _}
  end
end
