defmodule Aiur.DecisionHistorySourcesTest do
  use ExUnit.Case, async: true
  alias Aiur.{DecisionEvent, DecisionHistory}

  test "routing and delivery facts preserve known actors and identify daemon-owned facts" do
    at = DateTime.utc_now()

    facts = [
      {:routed, %{policy: :human_only, state: :with_human, cause: nil, at: at, actor: %{kind: :system, id: "routing"}}, %{type: :system, id: "routing", label: "routing"}},
      {:human_needed, %{cause: :executor_offline, requester_kind: :worker, urgency: :normal, blocking: false, at: at}, %{type: :system, id: "aiur", label: "aiur"}},
      {:escalated, %{cause: :executor_escalated, at: at, actor: %{kind: :executor, id: "executor-1"}}, %{type: :executor, id: "executor-1", label: "Executor"}},
      {:executor_acknowledged, %{executor_id: "executor-1", via: :explicit, at: at}, %{type: :executor, id: "executor-1", label: "Executor"}},
      {:pending_for_session, %{action_id: "action-1"}, %{type: :system, id: "decision-store", label: "decision-store"}},
      {:answer_comment_published, %{action_id: "action-1"}, %{type: :system, id: "decision-store", label: "decision-store"}}
    ]

    for {{type, data, expected}, id} <- Enum.with_index(facts, 1) do
      assert {:ok, event} = DecisionEvent.new(type, "dec-sources", 1, data, event_id: id, run_id: "run-sources", now: at)
      assert DecisionHistory.project_record(event).actor == expected
    end
  end
end
