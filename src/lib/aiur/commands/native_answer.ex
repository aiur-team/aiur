defmodule Aiur.Commands.NativeAnswer do
  @moduledoc false

  alias Aiur.Commands.Answering

  @spec correlate(Aiur.Decision.t(), Aiur.DecisionAnswer.t(), map()) :: map()
  def correlate(%{native: %{hold: :in_band, native_ref: ref}, questions: questions}, answer, correlation) do
    case Answering.decode_question_answers(questions, answer) do
      {:ok, answers} -> Map.merge(correlation, %{native_ref: ref, question_answers: answers})
      {:error, _reason} -> correlation
    end
  end

  def correlate(_decision, _answer, correlation), do: correlation

  @spec render(Aiur.Decision.t(), Aiur.DecisionAnswer.t()) :: String.t() | nil
  def render(%{questions: [_ | _] = questions}, answer) do
    case Answering.decode_question_answers(questions, answer) do
      {:ok, answers} -> Answering.render_question_answers(questions, answers)
      {:error, _reason} -> nil
    end
  end

  def render(_decision, _answer), do: nil
end
