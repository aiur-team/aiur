Code.require_file("../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionAnswerFeedbackTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.{DecisionAnswer, DecisionDispatch}

  @options [%{id: "a", label: "A"}, %{id: "b", label: "B"}]
  @feedback [
    %{"option_id" => "a", "verdict" => "dislike", "reason" => "too slow"},
    %{"option_id" => "b", "verdict" => "like"}
  ]

  defp normalize(extra, opts \\ []) do
    payload = Map.merge(%{"idempotency_key" => "k1", "expected_version" => 1, "option_id" => "b"}, extra)
    DecisionAnswer.normalize(payload, [decision_id: "dec_1", decision_version: 1, options: @options, actor: %{kind: :operator, id: "o"}] ++ opts)
  end

  test "accepts feedback and keeps it through the persisted round trip" do
    assert {:ok, answer} = normalize(%{"feedback" => @feedback})
    assert answer.feedback == @feedback
    raw = answer |> DecisionAnswer.to_json_safe() |> Jason.encode!() |> Jason.decode!()
    assert raw["feedback"] == @feedback
    assert DecisionAnswer.to_event_json_safe(answer)["feedback"] == @feedback
    assert {:ok, ^answer} = DecisionAnswer.from_json_safe(raw)
  end

  test "text-only answers keep the old wire shape" do
    assert {:ok, answer} = normalize(%{})
    refute Map.has_key?(DecisionAnswer.to_json_safe(answer), "feedback")
    refute Map.has_key?(DecisionAnswer.to_event_json_safe(answer), "feedback")
  end

  test "refuses unknown option, unknown verdict, oversized payload and oversized reason" do
    assert {:error, {:answer_invalid, {:feedback, :unknown_option}}} =
             normalize(%{"feedback" => [%{"option_id" => "zzz", "verdict" => "like"}]})

    assert {:error, {:answer_invalid, {:feedback, :unknown_verdict}}} =
             normalize(%{"feedback" => [%{"option_id" => "a", "verdict" => "meh"}]})

    many = for i <- 1..21, do: %{"option_id" => "a#{i}", "verdict" => "like"}
    assert {:error, {:answer_invalid, {:feedback, :too_large}}} = normalize(%{"feedback" => many}, allow_unchecked_option: true)

    assert {:error, {:answer_invalid, {:feedback, :reason_too_long}}} =
             normalize(%{"feedback" => [%{"option_id" => "a", "verdict" => "like", "reason" => String.duplicate("x", 501)}]})
  end

  test "dispatch renders the feedback for the agent" do
    {:ok, decision} =
      Aiur.DecisionValidation.normalize(
        %{"question" => "Which?", "blocking" => true, "source_id" => "fb", "options" => [%{"id" => "a", "label" => "A"}, %{"id" => "b", "label" => "B"}]},
        ticket: %{identifier: "981", title: "T", url: nil},
        source: %{agent_id: "agent-1", session_id: "s"},
        now: ~U[2026-07-12 10:00:00Z]
      )

    {:ok, answer} = normalize(%{"feedback" => @feedback}, decision_id: decision.decision_id, decision_version: decision.version, now: ~U[2026-07-12 10:01:00Z])
    text = DecisionDispatch.render(%{decision | answer: answer, decision_status: :decided})
    assert text =~ "Option feedback:\n- `a`: dislike - too slow\n- `b`: like"
  end

  test "feedback survives a DecisionStore restart", %{dir: dir} do
    pid1 = start_store!(dir)

    payload = %{
      "question" => "Which?",
      "blocking" => true,
      "source_id" => "fb-restart",
      "options" => [%{"id" => "a", "label" => "A"}, %{"id" => "b", "label" => "B"}]
    }

    assert {:ok, %{decision: decision}} = request(pid1, payload)
    answer = %{"idempotency_key" => "k1", "expected_version" => decision.version, "option_id" => "b", "feedback" => @feedback}
    assert {:ok, %{status: :accepted}} = DecisionStore.answer(decision.decision_id, answer, [actor: %{kind: :operator, id: "o"}], pid1)
    GenServer.stop(pid1)

    pid2 = start_store!(dir)
    assert {:ok, replayed} = DecisionStore.get(decision.decision_id, pid2)
    assert replayed.answer.feedback == @feedback
  end
end
