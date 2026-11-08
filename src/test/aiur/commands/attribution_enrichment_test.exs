Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.AttributionEnrichmentTest do
  use Aiur.DecisionStoreCase, async: false

  defp attribution do
    [
      requester: %{kind: :executor, executor_id: "operator"},
      origin: :executor_cli,
      native: %{harness: :codex, native_ref: "request-1", hold: :deferred},
      questions: [%{question_id: "scope", question: "Choose scope?", options: [%{label: "Small"}, %{label: "Large"}]}]
    ]
  end

  test "enrichment accepts the reserved Executor identity using persisted trusted requester", %{dir: dir} do
    pid = start_store!(dir)
    opts = Keyword.put(attribution(), :ticket, %{identifier: "executor"})
    assert {:ok, %{decision: original}} = request(pid, %{question: "Choose scope?", blocking: false}, opts)
    assert {:ok, %{status: :accepted, decision: enriched}} = enrich(pid, original.decision_id, %{"context" => %{"short_summary" => "New evidence"}}, 1)
    assert enriched.version == 2
    assert enriched.requester == original.requester
    assert enriched.context.short_summary == "New evidence"
    GenServer.stop(pid)
  end

  test "enriched snapshot replay preserves the separately persisted attribution", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, %{decision: original}} = request(pid, %{question: "Choose scope?", blocking: false}, attribution())
    assert {:ok, %{status: :accepted, decision: enriched}} = enrich(pid, original.decision_id, %{"context" => %{"short_summary" => "New evidence"}}, 1)
    assert enriched.requester == original.requester
    GenServer.stop(pid)
    replayed = start_store!(dir)
    assert {:ok, restored} = DecisionStore.get(original.decision_id, replayed)
    assert restored.version == 2
    assert Map.take(restored, [:requester, :origin, :native, :questions, :short_label]) == Map.take(original, [:requester, :origin, :native, :questions, :short_label])
    assert restored.context.short_summary == "New evidence"
    GenServer.stop(replayed)
  end
end
