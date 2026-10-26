defmodule Aiur.Commands.RequestContentTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.RequestContent

  defp question(id \\ "scope") do
    %{question_id: id, question: "Choose the scope", options: [%{label: "Small"}, %{label: "Large"}]}
  end

  test "questions normalize bounded content, derive option ids and drop unknown keys" do
    raw = Map.put(question(), :unknown, "discard")
    assert {:ok, [q]} = RequestContent.normalize_questions([raw])

    assert q == %{
             question_id: "scope",
             question: "Choose the scope",
             header: nil,
             options: [%{id: "q1-o1", label: "Small", description: nil}, %{id: "q1-o2", label: "Large", description: nil}],
             multi_select: false,
             allow_other: true,
             secret: false
           }

    assert RequestContent.v1_projection([q]) == %{question: q.question, options: q.options}
    assert RequestContent.v1_projection([]) == %{}
    assert {:ok, questions} = RequestContent.normalize_questions(Enum.map(1..4, &question("q#{&1}")))
    assert List.last(questions).options |> hd() |> Map.fetch!(:id) == "q4-o1"
    assert {:ok, [%{multi_select: true, allow_other: false}]} = RequestContent.normalize_questions([Map.merge(question(), %{multi_select: true, allow_other: false})])
    assert {:ok, [%{question_id: "scope"}]} = RequestContent.normalize_questions([%{"question_id" => "scope", "question" => "Choose", "options" => [%{"label" => "A"}, %{"label" => "B"}]}])
  end

  test "question count and type boundaries return structured errors" do
    for raw <- [[], List.duplicate(question(), 5)] do
      assert {:error, {:questions, :invalid_count}} = RequestContent.normalize_questions(raw)
    end

    for raw <- [nil, %{}, "questions", 1] do
      assert {:error, {:questions, :invalid_type}} = RequestContent.normalize_questions(raw)
    end

    assert {:error, {:questions, :invalid_type}} = RequestContent.normalize_questions([false])
    assert {:error, {:questions, {:question_id, :duplicate_id}}} = RequestContent.normalize_questions([question(), question()])
  end

  test "questions reject oversized text, invalid flags, duplicate options and secrets" do
    cases = [
      {:question_id, "", {:question_id, :missing}},
      {:question_id, String.duplicate("x", 65), {:question_id, :too_long}},
      {:header, String.duplicate("x", 13), {:header, :too_long}},
      {:question, "", {:question, :missing}},
      {:question, String.duplicate("x", 2001), {:question, :too_long}},
      {:multi_select, "true", {:multi_select, :invalid_type}},
      {:allow_other, nil, {:allow_other, :invalid_type}},
      {:secret, true, :secret_not_storable},
      {:secret, "true", {:secret, :invalid_type}},
      {:options, nil, {:options, :invalid_type}},
      {:options, [%{label: "A"}], {:options, :invalid_count}},
      {:options, List.duplicate(%{label: "A"}, 5), {:options, :invalid_count}},
      {:options, [false, false], {:options, :invalid_type}},
      {:options, [%{id: "a", label: "A"}, %{id: "a", label: "B"}], {:id, :duplicate_id}},
      {:options, [%{label: String.duplicate("x", 201)}, %{label: "B"}], {:label, :too_long}},
      {:options, [%{label: "A", description: String.duplicate("x", 2001)}, %{label: "B"}], {:description, :too_long}}
    ]

    for {key, value, error} <- cases do
      assert {:error, {:questions, ^error}} = RequestContent.normalize_questions([Map.put(question(), key, value)])
    end

    for count <- [2, 4] do
      assert {:ok, [_q]} = RequestContent.normalize_questions([Map.put(question(), :options, List.duplicate(%{label: "A"}, count))])
    end
  end

  test "short labels follow summary, header, question, kind and Command fallbacks" do
    summary = "one two three four five six seven eight nine ten eleven twelve"
    assert RequestContent.short_label(%{context: %{short_summary: "  #{summary}  "}}, []) == "one two three four five six seven eight"
    assert RequestContent.short_label(%{context: %{short_summary: " "}}, [%{header: "Scope"}]) == "Scope"
    assert RequestContent.short_label(%{question: "Question fallback", kind: "kind"}, []) == "Question fallback"
    assert RequestContent.short_label(%{question: "Top level"}, [%{question: "Native question"}]) == "Native question"
    assert RequestContent.short_label(%{kind: "scope"}, []) == "scope"
    assert RequestContent.short_label(%{}, []) == "Command"
    assert RequestContent.short_label(%{question: String.duplicate("x", 60)}, []) == String.duplicate("x", 40)
    assert RequestContent.short_label(%{question: String.duplicate("x", 40) <> " next"}, []) == String.duplicate("x", 40)
  end

  test "only emit_event requires two or three options and the recommended option first" do
    options = [%{id: "a"}, %{id: "b"}]
    assert RequestContent.suggested_response_check(%{options: options}, :emit_event) == :ok
    assert RequestContent.suggested_response_check(%{options: options, recommendation: %{option_id: "a"}}, :emit_event) == :ok
    assert RequestContent.suggested_response_check(%{options: options, recommendation: %{option_id: "b"}}, :emit_event) == {:warn, :recommended_not_first}

    for count <- [0, 1] do
      assert RequestContent.suggested_response_check(%{options: List.duplicate(%{id: "a"}, count)}, :emit_event) == {:warn, :too_few_options}
    end

    assert RequestContent.suggested_response_check(%{options: List.duplicate(%{id: "a"}, 3)}, :emit_event) == :ok
    assert RequestContent.suggested_response_check(%{options: List.duplicate(%{id: "a"}, 4)}, :emit_event) == {:warn, :too_many_options}

    for origin <- [:native_question, :attention, :executor_cli, :supervisor_api] do
      assert RequestContent.suggested_response_check(%{options: []}, origin) == :ok
    end
  end
end
