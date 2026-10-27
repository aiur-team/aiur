defmodule Aiur.Commands.RequestContent do
  @moduledoc "Bounded native questions and display content for Commands."

  alias Aiur.DecisionEvent.Validation

  @spec normalize_questions(term()) :: {:ok, [map()]} | {:error, {:questions, term()}}
  def normalize_questions(raw) when is_list(raw) and length(raw) in 1..4 do
    with {:ok, questions} <- normalize_list(raw, &normalize_question/2),
         :ok <- unique_ids(questions, :question_id) do
      {:ok, questions}
    else
      {:error, reason} -> {:error, {:questions, reason}}
    end
  end

  def normalize_questions(raw) when is_list(raw), do: {:error, {:questions, :invalid_count}}
  def normalize_questions(_raw), do: {:error, {:questions, :invalid_type}}

  defp normalize_question(raw, index) when is_map(raw) do
    with {:ok, id} <- Validation.map_required_string(raw, :question_id, 64),
         {:ok, header} <- Validation.bounded_optional(get(raw, :header), 12, :header),
         {:ok, question} <- Validation.map_required_string(raw, :question, 2000),
         {:ok, flags} <- flags(raw),
         {:ok, options} <- options(get(raw, :options), index) do
      {:ok, Map.merge(flags, %{question_id: id, header: header, question: question, options: options})}
    end
  end

  defp normalize_question(_raw, _index), do: {:error, :invalid_type}

  defp flags(raw) do
    with {:ok, multi_select} <- boolean(raw, :multi_select, false),
         {:ok, allow_other} <- boolean(raw, :allow_other, true),
         {:ok, secret} <- boolean(raw, :secret, false),
         false <- secret do
      {:ok, %{multi_select: multi_select, allow_other: allow_other, secret: false}}
    else
      true -> {:error, :secret_not_storable}
      error -> error
    end
  end

  defp boolean(raw, key, default) do
    case Map.get(raw, key, Map.get(raw, Atom.to_string(key), default)) do
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, {key, :invalid_type}}
    end
  end

  defp options(raw, index) when is_list(raw) and length(raw) in 1..4 do
    with {:ok, options} <- normalize_list(raw, &normalize_option(&1, index, &2)),
         :ok <- unique_ids(options, :id) do
      {:ok, options}
    end
  end

  defp options(raw, _index) when is_list(raw), do: {:error, {:options, :invalid_count}}
  defp options(_raw, _index), do: {:error, {:options, :invalid_type}}

  defp normalize_option(raw, question_index, option_index) when is_map(raw) do
    id = get(raw, :id) || "q#{question_index}-o#{option_index}"

    with {:ok, id} <- Validation.bounded_required(id, 200, :option_id),
         {:ok, label} <- Validation.map_required_string(raw, :label, 200),
         {:ok, description} <- Validation.bounded_optional(get(raw, :description), 2000, :description) do
      {:ok, %{id: id, label: label, description: description}}
    end
  end

  defp normalize_option(_raw, _question_index, _option_index), do: {:error, {:options, :invalid_type}}

  defp normalize_list(raw, fun) do
    raw
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case fun.(item, index) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        error -> {:halt, error}
      end
    end)
  end

  defp unique_ids(items, key) do
    ids = Enum.map(items, &Map.fetch!(&1, key))
    if Enum.uniq(ids) == ids, do: :ok, else: {:error, {key, :duplicate_id}}
  end

  @spec v1_projection([map()]) :: map()
  def v1_projection([first | _rest]), do: %{question: get(first, :question), options: get(first, :options)}
  def v1_projection([]), do: %{}

  @spec short_label(map(), [map()]) :: String.t()
  def short_label(decision, questions) do
    first = List.first(questions) || %{}
    context = get(decision, :context) || %{}

    [get(context, :short_summary), get(first, :header), get(first, :question), get(decision, :question), get(decision, :kind), "Command"]
    |> Enum.find_value(&present/1)
    |> truncate()
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_value), do: nil

  defp truncate(text) do
    if String.length(text) <= 40 do
      text
    else
      prefix = String.slice(text, 0, 40)
      if Regex.match?(~r/\s/u, String.slice(text, 40, 1)), do: String.trim_trailing(prefix), else: word_prefix(prefix)
    end
  end

  defp word_prefix(prefix) do
    words = Regex.replace(~r/\s+\S*$/u, prefix, "")
    String.trim_trailing(words)
  end

  @spec suggested_response_check(map(), atom()) :: :ok | {:warn, atom()}
  def suggested_response_check(decision, :emit_event) do
    options = get(decision, :options) || []
    recommendation = get(decision, :recommendation)

    cond do
      length(options) < 2 -> {:warn, :too_few_options}
      length(options) > 3 -> {:warn, :too_many_options}
      recommendation && get(recommendation, :option_id) != get(hd(options), :id) -> {:warn, :recommended_not_first}
      true -> :ok
    end
  end

  def suggested_response_check(_decision, _origin), do: :ok

  defp get(raw, key), do: Validation.get(raw, key)
end
