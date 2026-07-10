defmodule Aiur.Codex.UserInputAnswersTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.UserInputAnswers

  describe "approval_answers/1" do
    test "selects Approve this Session when offered" do
      params = %{
        "questions" => [
          %{
            "id" => "q1",
            "options" => [
              %{"label" => "Approve Once"},
              %{"label" => "Approve this Session"},
              %{"label" => "Reject"}
            ]
          }
        ]
      }

      assert {:ok, answers, "Approve this Session"} = UserInputAnswers.approval_answers(params)
      assert answers["q1"]["answers"] == ["Approve this Session"]
    end

    test "falls back to Approve Once when Approve this Session absent" do
      params = %{
        "questions" => [
          %{
            "id" => "q1",
            "options" => [
              %{"label" => "Approve Once"},
              %{"label" => "Reject"}
            ]
          }
        ]
      }

      assert {:ok, answers, "Approve this Session"} = UserInputAnswers.approval_answers(params)
      assert answers["q1"]["answers"] == ["Approve Once"]
    end

    test "falls back to any approve-prefixed label when exact matches absent" do
      params = %{
        "questions" => [
          %{
            "id" => "q1",
            "options" => [
              %{"label" => "Allow always"},
              %{"label" => "Reject"}
            ]
          }
        ]
      }

      assert {:ok, answers, "Approve this Session"} = UserInputAnswers.approval_answers(params)
      assert answers["q1"]["answers"] == ["Allow always"]
    end

    test "returns error when no approval option found" do
      params = %{
        "questions" => [
          %{
            "id" => "q1",
            "options" => [%{"label" => "Reject"}, %{"label" => "Cancel"}]
          }
        ]
      }

      assert :error = UserInputAnswers.approval_answers(params)
    end

    test "returns error for non-list questions" do
      assert :error = UserInputAnswers.approval_answers(%{"questions" => "not a list"})
    end

    test "returns error for params without questions key" do
      assert :error = UserInputAnswers.approval_answers(%{})
    end

    test "handles multiple questions" do
      params = %{
        "questions" => [
          %{"id" => "q1", "options" => [%{"label" => "Approve this Session"}]},
          %{"id" => "q2", "options" => [%{"label" => "Approve Once"}]}
        ]
      }

      assert {:ok, answers, "Approve this Session"} = UserInputAnswers.approval_answers(params)
      assert answers["q1"]["answers"] == ["Approve this Session"]
      assert answers["q2"]["answers"] == ["Approve Once"]
    end
  end

  describe "unavailable_answers/1" do
    test "returns non-interactive answer for each question" do
      params = %{
        "questions" => [
          %{"id" => "q1"},
          %{"id" => "q2"}
        ]
      }

      assert {:ok, answers} = UserInputAnswers.unavailable_answers(params)
      assert answers["q1"]["answers"] == [UserInputAnswers.non_interactive_answer()]
      assert answers["q2"]["answers"] == [UserInputAnswers.non_interactive_answer()]
    end

    test "returns error when question has no id" do
      params = %{"questions" => [%{"text" => "What?"}]}
      assert :error = UserInputAnswers.unavailable_answers(params)
    end

    test "returns error for empty questions list" do
      assert :error = UserInputAnswers.unavailable_answers(%{"questions" => []})
    end

    test "returns error for params without questions key" do
      assert :error = UserInputAnswers.unavailable_answers(%{})
    end
  end

  describe "non_interactive_answer/0" do
    test "returns the non-interactive session message" do
      answer = UserInputAnswers.non_interactive_answer()
      assert is_binary(answer)
      assert String.contains?(answer, "non-interactive")
    end
  end
end
