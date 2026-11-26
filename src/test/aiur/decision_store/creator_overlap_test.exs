Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.CreatorOverlapTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.AgentRunner.DecisionAttention

  @question "Riffrec export summaries should use UTC?"
  @context %{"long_context_markdown" => "Shared export schema for the reporting pipeline"}
  @other_ticket %{@ticket | identifier: "5150", url: "https://github.com/its-everdred/aiur/issues/5150"}
  @other_repository %{@ticket | url: "https://github.com/its-everdred/riffrec/issues/979"}

  test "a near-duplicate creator question links the recent answer in the agent tool result", %{dir: dir} do
    store = start_store!(dir)
    assert {:ok, %{status: :accepted, decision: prior}} = request(store, request_payload("viewer-timezone"))

    assert {:ok, %{status: :accepted, action: answer}} =
             answer(store, prior.decision_id, %{
               "idempotency_key" => "prefer-utc",
               "expected_version" => 1,
               "custom_response" => "Always use UTC"
             })

    question = "Could you confirm whether Riffrec export summaries should use UTC?"

    handlers = %{
      decision_requester: fn payload, opts ->
        DecisionStore.request(payload, Keyword.put(opts, :now, DateTime.add(answer.accepted_at, 3600)), store)
      end
    }

    assert {:ok, %{"status" => "duplicate", "decision_id" => prior_id, "creator_overlap" => %{"status" => "answered", "command_path" => path}}} =
             DecisionAttention.request_decision(@other_ticket, %{thread_id: "another-session"}, handlers, question, Map.put(request_payload("reworded"), "question", question))

    assert prior_id == prior.decision_id
    assert path == "/commands/" <> URI.encode_www_form(prior.decision_id)
    assert [%{decision_id: ^prior_id, answer: %{custom_response: "Always use UTC"}}] = DecisionStore.list(store)
  end

  test "an open creator question suppresses a second inbox item with the same shared context", %{dir: dir} do
    store = start_store!(dir)
    assert {:ok, %{status: :accepted, decision: prior}} = request(store, request_payload("first"))
    prior_id = prior.decision_id

    assert {:ok, %{status: :duplicate, decision: %{decision_id: ^prior_id}, creator_overlap: %{status: :open}}} =
             request(store, request_payload("open-twin"))

    assert {:ok, %{status: :accepted, decision: other_ticket}} =
             request(store, request_payload("open-other-ticket"), ticket: @other_ticket)

    different_context = %{"long_context_markdown" => "Legacy export schema for user downloads"}

    assert {:ok, %{status: :accepted, decision: unrelated}} =
             request(store, Map.put(request_payload("different-context"), "context", different_context))

    assert unrelated.decision_id != prior_id

    assert {:ok, %{status: :accepted, decision: foreign}} =
             request(store, request_payload("foreign"), ticket: @other_repository)

    assert Enum.sort(Enum.map(DecisionStore.list(store), & &1.decision_id)) == Enum.sort([prior_id, other_ticket.decision_id, unrelated.decision_id, foreign.decision_id])
  end

  # Future regression guard for the age boundary, which had no effect before answer linking.
  test "an older answer leaves an identical creator question open for a fresh decision", %{dir: dir} do
    store = start_store!(dir)
    before = DateTime.add(DateTime.utc_now(), -8, :day)
    assert {:ok, %{decision: prior}} = request(store, request_payload("older"), now: before)

    assert {:ok, %{status: :accepted, action: %{accepted_at: ^before}}} =
             answer(store, prior.decision_id, %{"idempotency_key" => "old-answer", "expected_version" => 1, "custom_response" => "UTC"}, now: before)

    assert {:ok, %{status: :accepted, decision: new}} = request(store, request_payload("new"))
    assert new.decision_id != prior.decision_id
    assert new.decision_status == :open
  end

  defp request_payload(source_id) do
    %{"audience" => "creator", "source_id" => source_id, "question" => @question, "blocking" => false, "context" => @context}
  end
end
