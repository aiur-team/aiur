defmodule Aiur.Commands.Answering.QuestionAnswers do
  @moduledoc false

  @spec encode(map(), list(), term()) :: {:ok, map()} | {:error, term()}
  def encode(payload, questions, answers) do
    with :ok <- validate(questions, answers) do
      encoded = Jason.encode!(%{kind: "question_answers", question_answers: answers, text: render(questions, answers)})

      {:ok,
       payload
       |> Map.drop([:question_answers, "question_answers", :option_id, "option_id", :custom_response, "custom_response"])
       |> Map.put("custom_response", encoded)}
    end
  end

  @spec decode(list(), map()) :: {:ok, map()} | {:error, term()}
  def decode(questions, %{custom_response: response} = answer) do
    case is_binary(response) && Jason.decode(response) do
      {:ok, %{"kind" => "question_answers", "question_answers" => answers}} ->
        with :ok <- validate(questions, answers), do: {:ok, answers}

      _legacy ->
        decode_legacy(questions, answer)
    end
  end

  defp decode_legacy([question | _rest], answer) do
    option_id = Map.get(answer, :selected_option_id)
    option = option_id && Enum.find(get(question, :options) || [], &(get(&1, :id) == option_id))
    value = if option, do: get(option, :label), else: Map.get(answer, :custom_response)

    if is_binary(value) and value != "",
      do: {:ok, %{get(question, :question_id) => [value]}},
      else: {:error, {:question_answers, :invalid}}
  end

  defp decode_legacy([], _answer), do: {:error, {:question_answers, :invalid}}

  @spec render(list(), map()) :: String.t()
  def render(questions, answers) do
    Enum.map_join(questions, "\n", fn question ->
      "#{get(question, :question)}: #{Enum.join(Map.fetch!(answers, get(question, :question_id)), ", ")}"
    end)
  end

  defp validate(questions, answers) when is_map(answers) and questions != [] do
    ids = Enum.map(questions, &get(&1, :question_id))

    cond do
      Enum.sort(Map.keys(answers)) != Enum.sort(ids) -> {:error, {:question_answers, :incomplete}}
      Enum.all?(questions, &valid_answer?(&1, Map.fetch!(answers, get(&1, :question_id)))) -> :ok
      true -> {:error, {:question_answers, :invalid}}
    end
  end

  defp validate(_questions, _answers), do: {:error, {:question_answers, :invalid}}

  defp valid_answer?(question, values) when is_list(values) and values != [] do
    labels = Enum.map(get(question, :options) || [], &get(&1, :label))

    (get(question, :multi_select) == true or length(values) == 1) and
      length(Enum.uniq(values)) == length(values) and
      Enum.all?(values, fn value ->
        is_binary(value) and String.trim(value) != "" and
          (value in labels or get(question, :allow_other) != false)
      end)
  end

  defp valid_answer?(_question, _values), do: false
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
