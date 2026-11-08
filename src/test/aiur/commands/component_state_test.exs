defmodule Aiur.Commands.ComponentStateTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.ComponentState

  @ticket %{"identifier" => "42", "title" => "Game", "url" => "https://example.test/42"}

  defp projection(overrides) do
    Map.merge(
      %{
        "decision_id" => "dec_1",
        "version" => 3,
        "question" => "Ship the build?",
        "ticket" => @ticket,
        "blocking" => true,
        "decision_status" => "open",
        "delivery_status" => "pending",
        "revision_sequence" => 0,
        "options" => [
          %{"id" => "approve", "label" => "Approve", "description" => "Ship it"},
          %{"id" => "hold", "label" => "Hold", "description" => nil}
        ],
        "recommendation" => %{"option_id" => "approve"},
        "artifacts" => [%{"kind" => "url", "value" => "https://example.test/evidence"}],
        "answer" => nil,
        "active_answer" => nil
      },
      overrides
    )
  end

  test "an unanswered open Command is pending and answerable" do
    component = ComponentState.from_projection(projection(%{}))

    assert component["state"] == "pending"
    assert component["reason"] == nil
    assert component["decision_id"] == "dec_1"
    assert component["ticket"] == @ticket
    assert component["blocking"] == true
    assert component["actions"]["answer"] == true
    assert component["actions"]["revise"] == false
  end

  test "options, recommendation signal, free response and typed media are preserved" do
    component = ComponentState.from_projection(projection(%{}))

    assert [approve, hold] = component["options"]
    assert approve["label"] == "Approve"
    assert hold["description"] == nil
    assert component["recommendation"] == %{"option_id" => "approve", "label" => "Approve"}
    assert component["free_response"] == %{"allowed" => true, "required" => false}
    assert component["media"] == [%{"kind" => "url", "value" => "https://example.test/evidence"}]
  end

  test "a free-response Command accepts a response and reports it as required" do
    component = ComponentState.from_projection(projection(%{"options" => [], "recommendation" => nil}))

    assert component["options"] == []
    assert component["recommendation"] == nil
    assert component["free_response"] == %{"allowed" => true, "required" => true}
  end

  test "a decided Command is answered and offers revision" do
    answer = %{"action_id" => "act_1", "decision_version" => 3, "selected_option_id" => "approve"}

    component =
      ComponentState.from_projection(projection(%{"decision_status" => "decided", "answer" => answer, "active_answer" => answer}))

    assert component["state"] == "answered"
    assert component["actions"]["answer"] == false
    assert component["actions"]["revise"] == true
    assert component["answer"]["selected_option_id"] == "approve"
  end

  test "an answer with a revision sequence is revised, not plain answered" do
    answer = %{"action_id" => "act_2", "decision_version" => 4}

    component =
      ComponentState.from_projection(
        projection(%{
          "decision_status" => "decided",
          "revision_sequence" => 2,
          "answer" => answer,
          "active_answer" => answer
        })
      )

    assert component["state"] == "revised"
  end

  test "expired, moot and dismissed Commands are expired and unanswerable" do
    for status <- ["expired", "moot", "dismissed"] do
      component = ComponentState.from_projection(projection(%{"decision_status" => status}))

      assert component["state"] == "expired"
      assert component["reason"] == status
      assert component["actions"]["answer"] == false
    end
  end

  test "a partially readable store is unavailable rather than empty" do
    component =
      ComponentState.from_projection(projection(%{"health" => %{"status" => "partial", "partial" => true, "reason" => "retained_store_partial"}}))

    assert component["state"] == "unavailable"
    assert component["reason"] == "store_unavailable"
    assert component["actions"]["answer"] == false
  end

  test "dashboard rows (atom keys) and API projections (string keys) agree" do
    atom_row = %{
      decision_id: "dec_1",
      version: 3,
      question: "Ship the build?",
      ticket: %{identifier: "42", title: "Game", url: "https://example.test/42"},
      blocking: true,
      decision_status: :open,
      revision_sequence: 0,
      options: [%{id: "approve", label: "Approve", description: "Ship it"}],
      recommendation: %{option_id: "approve"},
      artifacts: [%{kind: :url, value: "https://example.test/evidence"}],
      answer: nil
    }

    dashboard = ComponentState.from_projection(atom_row)
    api = ComponentState.from_projection(projection(%{}))

    assert dashboard["state"] == api["state"]
    assert dashboard["decision_id"] == api["decision_id"]
    assert dashboard["ticket"] == api["ticket"]
    assert dashboard["recommendation"]["option_id"] == api["recommendation"]["option_id"]
    assert dashboard["media"] == api["media"]
  end

  test "an accepted answer maps to answered and a duplicate submit stays answered" do
    decision = %{
      decision_id: "dec_1",
      version: 4,
      decision_status: :decided,
      question: "Ship the build?",
      answer: %{action_id: "act_1", decision_version: 3, selected_option_id: "approve"},
      revision_sequence: 0
    }

    assert ComponentState.from_outcome(%{status: :accepted, decision: decision, delivery: :pending})["state"] == "answered"
    assert ComponentState.from_outcome(%{status: :duplicate, decision: decision, delivery: :pending})["reason"] == "duplicate_submit"
  end

  test "stale, already-answered and too-late answers are conflicts" do
    stale = ComponentState.from_outcome(%{status: :stale, current_version: 7})
    already = ComponentState.from_outcome(%{status: :already_answered, winner: %{}})
    too_late = ComponentState.from_outcome(%{status: :too_late, reason: :answer_delivered, winner: %{}})

    assert stale["state"] == "conflict"
    assert stale["reason"] == "stale_version"
    assert stale["version"] == 7

    assert already["state"] == "conflict"
    assert already["reason"] == "already_answered"

    assert too_late["state"] == "conflict"
    assert too_late["reason"] == "answer_in_flight"
  end

  test "a withdrawn Command is expired and a permission refusal is an error" do
    assert ComponentState.from_outcome(%{status: :withdrawn, reason: :moot})["state"] == "expired"

    not_allowed = ComponentState.from_outcome(%{status: :not_allowed, reason: :human_answer})
    assert not_allowed["state"] == "error"
    assert not_allowed["reason"] == "not_allowed"
  end

  test "validation failures have a stable error state" do
    assert ComponentState.from_outcome({:error, {:answer_invalid, {:option_id, :unknown}}})["reason"] ==
             "validation_failed"

    assert ComponentState.from_outcome({:error, {:response, :missing}})["reason"] == "validation_failed"
    assert ComponentState.from_outcome({:error, :store_unavailable})["reason"] == "store_unavailable"
    assert ComponentState.from_outcome({:error, {:conflict, {:stale_version, 1, 2}}})["reason"] == "stale_version"
  end

  test "list states distinguish empty, ready, loading and unavailable" do
    component = ComponentState.from_projection(projection(%{}))

    assert ComponentState.list([])["status"] == "empty"
    assert ComponentState.list([component])["status"] == "ready"
    assert ComponentState.list([component])["count"] == 1
    assert ComponentState.loading()["status"] == "loading"
    assert ComponentState.list([], error: :store_unavailable)["status"] == "error"
    assert ComponentState.list([], error: :store_unavailable)["error"] == %{"reason" => "store_unavailable"}
  end
end
