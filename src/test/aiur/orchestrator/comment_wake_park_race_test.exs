defmodule Aiur.Orchestrator.CommentWakeParkRaceTest.Tracker do
  def start(id, labels, park? \\ false) do
    {:ok, pid} = Agent.start_link(fn -> %{labels: labels, park?: park?, result: nil} end)
    :persistent_term.put({__MODULE__, id}, pid)
    pid
  end

  def stop(id, pid) do
    :persistent_term.erase({__MODULE__, id})
    if Process.alive?(pid), do: Agent.stop(pid)
  end

  def labels(id), do: Agent.get(fetch(id), & &1.labels)
  def result(id), do: Agent.get(fetch(id), & &1.result)

  def update_issue_state(id, target, opts) do
    Agent.get_and_update(fetch(id), fn state ->
      labels = if state.park?, do: ["needs-triage"], else: state.labels
      refused = Enum.map(Keyword.get(opts, :refuse_labels, []), &String.downcase/1)

      if Enum.any?(labels, &(String.downcase(&1) in refused)) do
        result = {:error, {:operator_hold, "needs-triage"}}
        {result, %{state | labels: labels, result: result}}
      else
        next_labels = ["agent:#{target}" | Enum.reject(labels, &String.starts_with?(&1, "agent:"))]
        {:ok, %{state | labels: next_labels, park?: false, result: :ok}}
      end
    end)
  end

  def update_issue_state(_id, _target), do: {:error, :expected_state_unsupported}

  defp fetch(id), do: :persistent_term.get({__MODULE__, id})
end

defmodule Aiur.Orchestrator.CommentWakeParkRaceTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CommentWake, State}
  alias Aiur.Orchestrator.CommentWakeParkRaceTest.Tracker

  test "the Part-of handoff leaves a park added before its write intact" do
    tracker = Tracker.start("park-race-42", ["agent:in-progress"], true)
    on_exit(fn -> Tracker.stop("park-race-42", tracker) end)

    CommentWake.mark_pr_merged_issue_done(%State{}, "park-race-42",
      target_state: "human-review",
      tracker: Tracker,
      fetch_issue_states_fun: fn [_id] -> {:ok, [%Issue{state: "in-progress"}]} end
    )

    assert Tracker.result("park-race-42") == {:error, {:operator_hold, "needs-triage"}}
    assert Tracker.labels("park-race-42") == ["needs-triage"]
  end

  test "the Part-of handoff still writes human-review when no hold appears" do
    tracker = Tracker.start("no-park-42", ["agent:in-progress"])
    on_exit(fn -> Tracker.stop("no-park-42", tracker) end)

    CommentWake.mark_pr_merged_issue_done(%State{}, "no-park-42",
      target_state: "human-review",
      tracker: Tracker,
      fetch_issue_states_fun: fn [_id] -> {:ok, [%Issue{state: "in-progress"}]} end
    )

    assert Tracker.result("no-park-42") == :ok
    assert Tracker.labels("no-park-42") == ["agent:human-review"]
  end
end
