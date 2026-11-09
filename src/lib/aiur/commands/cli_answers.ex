defmodule Aiur.Commands.CLIAnswers do
  @moduledoc """
  Resolves the CLI's per-question answer flags against a Command's questions.

  `--answer QUESTION=OPTION[,OPTION]` (repeatable) picks options by id or
  label, `--answer-text QUESTION=TEXT` (repeatable) supplies free text for an
  `allow_other` question, and `--answers-file` carries JSON of
  `{QUESTION: {"options": [...], "text": "..."}}`. QUESTION is a question id or its header. All three
  produce the same encoded payload, so a retry through another form replays.
  """

  alias Aiur.Commands
  alias Aiur.Commands.Answering.QuestionAnswers

  @flag_keys [:answers, :answer_texts, :answers_json]
  # Matches the launcher's limit; the file travels inside one control RPC.
  @max_file_bytes 65_536

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

    json = Map.new(questions, &{get(&1, :question_id), file_template(&1)}) |> Jason.encode!()
    %{flags: flags, json: json}
  end

  defp file_template(question) do
    if get(question, :allow_other) == false,
      do: %{"options" => ["<option-id>"]},
      else: %{"options" => ["<option-id>"], "text" => "<free text, or delete this key>"}
  end

  @doc "Unanswered question ids with their headers, for an incomplete answer."
  @spec describe_missing([map()], [String.t()]) :: String.t()
  def describe_missing(questions, answered_ids) do
    questions
    |> Enum.reject(&(get(&1, :question_id) in answered_ids))
    |> Enum.map_join(", ", &label/1)
  end

  @doc "Read a Command's decision (questions included) from the store."
  @spec fetch_decision(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_decision(decision_id, deps) do
    get_fun = Keyword.get(deps, :get_fun, fn id, store -> Commands.get(id, store: store) end)

    case get_fun.(decision_id, Keyword.get(deps, :decision_store, Commands.default_store())) do
      {:ok, %{decision: decision}} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  @doc "Name the unanswered questions when a single legacy answer meets a multi-question Command."
  @spec name_unanswered(term(), String.t(), keyword()) :: term()
  def name_unanswered({:error, {:answer_invalid, {:question_answers, :incomplete}}} = error, decision_id, deps) do
    case fetch_decision(decision_id, deps) do
      {:ok, %{questions: [first | _rest] = questions}} ->
        missing = describe_missing(questions, [Map.get(first, :question_id)])
        {:usage, "every question needs an answer; unanswered: #{missing}. Use --answer/--answer-text or --answers-file; aiur command #{decision_id} prints the template"}

      _unavailable ->
        error
    end
  end

  def name_unanswered(result, _decision_id, _deps), do: result

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
      |> collect(&option_entry("--answer #{key}", question, &1))
    end
  end

  defp option_entry(where, question, choice) do
    case option_label(question, choice) do
      nil -> {:usage, "#{where}: unknown option #{inspect(choice)}; choose one of #{option_ids(question)}"}
      label -> {:ok, [{get(question, :question_id), label}]}
    end
  end

  defp text_entries(key, text, questions) do
    with {:ok, question} <- find_question(key, questions),
         :ok <- allows_text(question) do
      {:ok, [{get(question, :question_id), String.trim(text)}]}
    end
  end

  defp file_entries(json, _questions) when byte_size(json) > @max_file_bytes,
    do: {:usage, "--answers-file is larger than #{@max_file_bytes} bytes"}

  defp file_entries(json, questions) do
    case Jason.decode(json) do
      {:ok, %{"question_answers" => answers}} when is_map(answers) -> collect(answers, &file_values(&1, questions))
      {:ok, answers} when is_map(answers) -> collect(answers, &file_values(&1, questions))
      _invalid -> {:usage, ~s(--answers-file must hold a JSON object of question ids to {"options": [...], "text": "..."})}
    end
  end

  # Each answer says what it is: "options" are option ids or labels, refused when
  # unknown (like --answer); "text" is free text (like --answer-text). No guessing.
  defp file_values({key, %{} = answer}, questions) do
    where = "--answers-file #{key}"

    with {:ok, question} <- find_question(key, questions),
         [] <- Map.keys(answer) -- ["options", "text"],
         {:ok, options} <- file_options(where, question, Map.get(answer, "options", [])),
         {:ok, text} <- file_text(where, question, Map.get(answer, "text")) do
      {:ok, options ++ text}
    else
      [_ | _] = unknown -> {:usage, ~s(#{where}: unknown keys #{Enum.join(unknown, ", ")}; use "options" and "text")}
      usage -> usage
    end
  end

  defp file_values({key, _answer}, _questions), do: {:usage, ~s(--answers-file #{key}: expected {"options": [...], "text": "..."})}

  defp file_options(where, question, options) when is_list(options) do
    if Enum.all?(options, &is_binary/1),
      do: collect(options, &option_entry(where, question, String.trim(&1))),
      else: {:usage, "#{where}: options must be option ids or labels"}
  end

  defp file_options(where, _question, _options), do: {:usage, "#{where}: options must be a list"}

  defp file_text(_where, _question, nil), do: {:ok, []}

  defp file_text(where, question, text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:usage, "#{where}: text is empty"}
      trimmed -> with :ok <- allows_text(question), do: {:ok, [{get(question, :question_id), trimmed}]}
    end
  end

  defp file_text(where, _question, _text), do: {:usage, "#{where}: text must be a string"}

  defp find_question(key, questions) do
    by_id = Enum.find(questions, &(get(&1, :question_id) == key))
    by_header = Enum.filter(questions, &(is_binary(get(&1, :header)) and String.downcase(get(&1, :header)) == String.downcase(key)))

    case {by_id, by_header} do
      {nil, [question]} -> {:ok, question}
      {nil, [_, _ | _] = many} -> {:usage, "ambiguous header #{inspect(key)}: it matches questions #{Enum.map_join(many, ", ", &get(&1, :question_id))}; use the question id"}
      {nil, []} -> {:usage, "unknown question #{inspect(key)}; use one of #{Enum.map_join(questions, ", ", &label/1)}"}
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
