defmodule Aiur.Commands.QuestionAnswersTest do
  use ExUnit.Case, async: true
  alias Aiur.Commands.Answering
  alias Aiur.Commands.Answering.QuestionAnswers
  alias Aiur.DecisionAnswer

  test "multi-question encoding includes marker, labels, custom text and readable fallback" do
    answers = %{"first" => ["Yes"], "second" => ["Custom", "Blue"]}
    assert {:ok, payload} = QuestionAnswers.encode(%{expected_version: 1, idempotency_key: "multi", option_id: "old"}, questions(), answers)

    assert Jason.decode!(payload["custom_response"]) == %{
             "kind" => "question_answers",
             "question_answers" => answers
           }

    refute Map.has_key?(payload, :option_id)
    assert Answering.render_question_answers(questions(), answers) == "Proceed?: Yes\nColors?: Custom, Blue"
    assert {:ok, normalized} = DecisionAnswer.normalize(payload, decision_id: "decision", decision_version: 1, actor: %{kind: :operator, id: "human"})
    assert Jason.decode!(normalized.custom_response)["question_answers"] == answers
    assert Answering.decode_question_answers(questions(), normalized) == {:ok, answers}
  end

  test "partial and extra question keys are rejected" do
    for answers <- [%{"first" => ["Yes"]}, %{"first" => ["Yes"], "second" => ["Blue"], "extra" => ["No"]}] do
      assert QuestionAnswers.encode(%{}, questions(), answers) == {:error, {:question_answers, :incomplete}}
    end
  end

  test "invalid selections, unknown labels and empty answers are rejected" do
    for value <- [["Unknown"], [], [nil], [""], [" "], ["Yes", "No"], "Yes", ["Yes", "Yes"]] do
      assert QuestionAnswers.encode(%{}, questions(), %{"first" => value, "second" => ["Blue"]}) == {:error, {:question_answers, :invalid}}
    end

    assert QuestionAnswers.encode(%{}, [], %{}) == {:error, {:question_answers, :invalid}}
    assert QuestionAnswers.encode(%{}, questions(), []) == {:error, {:question_answers, :invalid}}
  end

  test "encoded custom response retains the existing answer size bound" do
    assert {:ok, payload} = QuestionAnswers.encode(%{expected_version: 1, idempotency_key: "long"}, questions(), %{"first" => ["Yes"], "second" => [String.duplicate("x", 4_001)]})
    assert {:error, {:answer_invalid, {:custom_response, :too_long}}} = DecisionAnswer.normalize(payload, decision_id: "decision", decision_version: 1, actor: %{kind: :operator, id: "human"})
  end

  test "legacy option and custom answers project to the first question" do
    assert Answering.decode_question_answers(questions(), %{custom_response: nil, selected_option_id: "yes"}) == {:ok, %{"first" => ["Yes"]}}
    assert Answering.decode_question_answers(questions(), %{custom_response: "Other", selected_option_id: nil}) == {:ok, %{"first" => ["Other"]}}
    assert Answering.decode_question_answers([], %{custom_response: "Other"}) == {:error, {:question_answers, :invalid}}
  end

  test "maximum labelled multi-select answers fit the existing response bound" do
    questions =
      for q <- 1..4 do
        %{question_id: "q#{q}", question: "Question #{q}", multi_select: true, allow_other: false, options: for(o <- 1..4, do: %{label: String.duplicate("a", 199) <> Integer.to_string(o)})}
      end

    answers = Map.new(questions, &{&1.question_id, Enum.map(&1.options, fn option -> option.label end)})
    assert {:ok, payload} = QuestionAnswers.encode(%{expected_version: 1, idempotency_key: "bounded"}, questions, answers)
    assert {:ok, normalized} = DecisionAnswer.normalize(payload, decision_id: "decision", decision_version: 1, actor: %{kind: :operator, id: "human"})
    assert Jason.decode!(normalized.custom_response)["question_answers"] == answers
  end

  defp questions do
    [
      %{question_id: "first", question: "Proceed?", options: [%{id: "yes", label: "Yes"}, %{label: "No"}], allow_other: false, multi_select: false},
      %{question_id: "second", question: "Colors?", options: [%{label: "Blue"}], allow_other: true, multi_select: true}
    ]
  end
end
