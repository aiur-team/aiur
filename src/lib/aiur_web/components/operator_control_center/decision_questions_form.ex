defmodule AiurWeb.OperatorControlCenter.DecisionQuestionsForm do
  @moduledoc false
  use Phoenix.Component
  alias Aiur.Commands.RequestContent

  @spec questions(map()) :: list()
  def questions(decision) do
    case RequestContent.normalize_questions(Map.get(decision, :questions, [])) do
      {:ok, questions} -> questions
      # Older attribution facts retain arbitrary question metadata, not the native form contract.
      {:error, _reason} -> []
    end
  end

  attr(:questions, :list, required: true)
  attr(:form, :map, default: %{})
  attr(:disabled, :boolean, default: false)

  @spec decision_questions_form(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_questions_form(assigns) do
    ~H"""
    <div class="decision-questions">
      <fieldset :for={question <- @questions} class="decision-choice-list" data-question-group disabled={@disabled}>
        <legend>{get(question, :question)}</legend>
        <p :if={get(question, :multi_select)}>Choose one or more answers.</p>
        <label :for={option <- get(question, :options)} class="decision-choice">
          <input
            type={if get(question, :multi_select), do: "checkbox", else: "radio"}
            name={"answer[question_choices][#{get(question, :question_id)}][]"}
            value={"option:#{get(option, :id)}"}
            checked={"option:#{get(option, :id)}" in choices(@form, question)}
            required={not get(question, :multi_select)}
          />
          <span class="decision-choice-copy">
            <strong>{get(option, :label)}</strong>
            <small :if={get(option, :description)}>{get(option, :description)}</small>
          </span>
        </label>
        <label :if={get(question, :allow_other)} class="decision-choice">
          <input
            type={if get(question, :multi_select), do: "checkbox", else: "radio"}
            name={"answer[question_choices][#{get(question, :question_id)}][]"}
            value="other"
            checked={"other" in choices(@form, question)}
            required={not get(question, :multi_select)}
          />
          <span>Other</span>
        </label>
        <label :if={get(question, :allow_other) and "other" in choices(@form, question)} class="decision-action-field" data-custom-response>
          <span>Other response</span>
          <input type="text" name={"answer[question_other][#{get(question, :question_id)}]"} value={other(@form, question)} maxlength="4000" required />
        </label>
      </fieldset>
    </div>
    """
  end

  @spec answer_content(list(), map()) :: {:ok, map()} | {:error, String.t()}
  def answer_content(questions, form) do
    answers = Map.new(questions, fn question -> {get(question, :question_id), values(question, form)} end)

    if Enum.all?(questions, &valid?(&1, answers[get(&1, :question_id)])) do
      {:ok, %{"question_answers" => answers}}
    else
      {:error, "Answer every question. Select an option or enter an Other response."}
    end
  end

  defp values(question, form) do
    Enum.map(choices(form, question), fn
      "other" -> if get(question, :allow_other), do: String.trim(other(form, question)), else: nil
      "option:" <> id -> option_label(question, id)
      _invalid -> nil
    end)
  end

  defp option_label(question, id) do
    case Enum.find(get(question, :options), &(get(&1, :id) == id)) do
      nil -> nil
      option -> get(option, :label)
    end
  end

  defp valid?(question, values) do
    values != [] and (get(question, :multi_select) or length(values) == 1) and
      Enum.uniq(values) == values and Enum.all?(values, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp choices(form, question), do: List.wrap(question_value(form, "question_choices", question))

  defp other(form, question) do
    case question_value(form, "question_other", question) do
      value when is_binary(value) -> value
      _invalid -> ""
    end
  end

  defp question_value(form, key, question) do
    case Map.get(form, key) do
      values when is_map(values) -> Map.get(values, get(question, :question_id))
      _invalid -> nil
    end
  end

  defp get(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
