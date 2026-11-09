defmodule Aiur.Commands.CLIAnswers do
  @moduledoc """
  Resolves the CLI's per-question answer flags against a Command's questions.

  `--answer QUESTION=OPTION[,OPTION]` (repeatable) picks options by id or
  label, `--answer-text QUESTION=TEXT` (repeatable) supplies free text for an
  `allow_other` question, and `--answers-file` carries JSON in the
  `question_answers` shape. QUESTION is a question id or its header. All three
  produce the same encoded payload, so a retry through another form replays.
  """

  alias Aiur.Commands.Answering.QuestionAnswers

  @flag_keys [:answers, :answer_texts, :answers_json]

  @doc "Whether the caller passed any per-question answer flag."
  @spec requested?(keyword()) :: boolean()
  def requested?(params), do: Enum.any?(@flag_keys, &(Keyword.get(params, &1) not in [nil, []]))

  @doc "Resolve the flags to an encoded answer map (`custom_response` carries the question answers)."
  @spec encode(keyword(), [map()]) :: {:ok, map()} | {:usage, String.t()}
  def encode(params, questions) do
    with {:ok, answers} <- resolve(params, questions) do
      case QuestionAnswers.encode(%{}, questions, answers) do
        {:ok, payload} -> {:ok, payload}
        {:error, {:question_answers, reason}} -> {:usage, "question answers are #{reason}; run aiur command DECISION-ID for the template"}
      end
    end
  end

  @doc "Resolve the flags to `%{question_id => [label or text]}`, in each question's option order."
  @spec resolve(keyword(), [map()]) :: {:ok, map()} | {:usage, String.t()}
  def resolve(_params, []), do: {:usage, "this Command has no questions; answer with --option or --custom-response"}

  def resolve(params, questions) do
    pairs = Keyword.get(params, :answers, []) |> List.wrap()
    texts = Keyword.get(params, :answer_texts, []) |> List.wrap()

    collected =
      case Keyword.get(params, :answers_json) do
        nil -> flag_entries(pairs, texts, questions)
        json when pairs == [] and texts == [] -> file_entries(json, questions)
        _json -> {:usage, "--answers-file cannot be combined with --answer or --answer-text"}
      end

    with {:ok, entries} <- collected,
         answers <- group(entries, questions),
         :ok <- complete(answers, questions),
         :ok <- cardinality(answers, questions) do
      {:ok, answers}
    end
  end

  @doc "A ready-to-fill flag and JSON template for every question."
  @spec template([map()]) :: %{flags: String.t(), json: String.t()}
  def template(questions) do
    flags =
      Enum.map_join(questions, " ", fn question ->
        value = if get(question, :multi_select), do: "<option-id>[,<option-id>]", else: "<option-id>"
        "--answer #{get(question, :question_id)}=#{value}"
      end)

    json = Map.new(questions, &{get(&1, :question_id), ["<option-id or label>"]}) |> Jason.encode!()
    %{flags: flags, json: json}
  end

  @doc "Unanswered question ids with their headers, for an incomplete answer."
  @spec describe_missing([map()], [String.t()]) :: String.t()
  def describe_missing(questions, answered_ids) do
    questions
    |> Enum.reject(&(get(&1, :question_id) in answered_ids))
    |> Enum.map_join(", ", &label/1)
  end

  defp flag_entries(pairs, texts, questions) do
    with {:ok, options} <- each(pairs, "--answer", &option_entries(&1, &2, questions)),
         {:ok, free} <- each(texts, "--answer-text", &text_entries(&1, &2, questions)) do
      {:ok, options ++ free}
    end
  end

  defp each(items, flag, fun) do
    collect(items, fn item ->
      with {:ok, key, value} <- split(item, flag), do: fun.(key, value)
    end)
  end

  # Concatenate each item's entries, stopping at the first usage error.
  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
        usage -> {:halt, usage}
      end
    end)
  end

  defp split(item, flag) do
    case String.split(item, "=", parts: 2) do
      [key, value] when key != "" and value != "" -> {:ok, String.trim(key), value}
      _invalid -> {:usage, "#{flag} expects QUESTION=VALUE, got #{inspect(item)}"}
    end
  end

  defp option_entries(key, value, questions) do
    with {:ok, question} <- find_question(key, questions) do
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> collect(&option_entry(key, question, &1))
    end
  end

  defp option_entry(key, question, choice) do
    case option_label(question, choice) do
      nil -> {:usage, "--answer #{key}: unknown option #{inspect(choice)}; choose one of #{option_ids(question)}"}
      label -> {:ok, [{get(question, :question_id), label}]}
    end
  end

  defp text_entries(key, text, questions) do
    with {:ok, question} <- find_question(key, questions),
         :ok <- allows_text(question) do
      {:ok, [{get(question, :question_id), String.trim(text)}]}
    end
  end

  defp file_entries(json, questions) do
    case Jason.decode(json) do
      {:ok, %{"question_answers" => answers}} when is_map(answers) -> collect(answers, &file_values(&1, questions))
      {:ok, answers} when is_map(answers) -> collect(answers, &file_values(&1, questions))
      _invalid -> {:usage, "--answers-file must hold a JSON object of question ids to answer lists"}
    end
  end

  defp file_values({key, values}, questions) do
    with {:ok, question} <- find_question(key, questions) do
      collect(List.wrap(values), &file_value(question, &1))
    end
  end

  defp file_value(question, value) when is_binary(value) do
    case option_label(question, String.trim(value)) do
      nil -> with :ok <- allows_text(question), do: {:ok, [{get(question, :question_id), String.trim(value)}]}
      label -> {:ok, [{get(question, :question_id), label}]}
    end
  end

  defp file_value(question, value), do: {:usage, "--answers-file: #{get(question, :question_id)} has a non-text answer #{inspect(value)}"}

  defp find_question(key, questions) do
    by_id = Enum.find(questions, &(get(&1, :question_id) == key))
    by_header = Enum.filter(questions, &(is_binary(get(&1, :header)) and String.downcase(get(&1, :header)) == String.downcase(key)))

    case {by_id, by_header} do
      {nil, [question]} -> {:ok, question}
      {nil, _none_or_many} -> {:usage, "unknown question #{inspect(key)}; use one of #{Enum.map_join(questions, ", ", &label/1)}"}
      {question, _headers} -> {:ok, question}
    end
  end

  defp option_label(question, choice) do
    options = get(question, :options) || []
    option = Enum.find(options, &(get(&1, :id) == choice)) || Enum.find(options, &(get(&1, :label) == choice))
    option && get(option, :label)
  end

  defp allows_text(question) do
    if get(question, :allow_other) == false,
      do: {:usage, "question #{label(question)} does not accept free text; choose one of #{option_ids(question)}"},
      else: :ok
  end

  # Group per question; options follow the question's option order so every input form encodes identically.
  defp group(entries, questions) do
    entries
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, values} ->
      labels = questions |> Enum.find(&(get(&1, :question_id) == id)) |> get(:options) |> Kernel.||([]) |> Enum.map(&get(&1, :label))
      {id, values |> Enum.uniq() |> Enum.sort_by(&(Enum.find_index(labels, fn label -> label == &1 end) || length(labels)))}
    end)
  end

  defp complete(answers, questions) do
    case describe_missing(questions, Map.keys(answers)) do
      "" -> :ok
      missing -> {:usage, "every question needs an answer; unanswered: #{missing}"}
    end
  end

  defp cardinality(answers, questions) do
    case Enum.find(questions, &(get(&1, :multi_select) != true and length(Map.fetch!(answers, get(&1, :question_id))) > 1)) do
      nil -> :ok
      question -> {:usage, "question #{label(question)} accepts one answer"}
    end
  end

  defp option_ids(question), do: Enum.map_join(get(question, :options) || [], ", ", &(get(&1, :id) || get(&1, :label)))

  defp label(question) do
    case get(question, :header) do
      header when is_binary(header) and header != "" -> "#{get(question, :question_id)} (#{header})"
      _none -> get(question, :question_id)
    end
  end

  defp get(nil, _key), do: nil
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
