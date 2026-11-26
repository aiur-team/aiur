defmodule AiurWeb.StreamdeckV2CommandsTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.{Commands, DecisionStore}
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.StreamdeckCommands

  setup do
    dir = Path.join(System.tmp_dir!(), "streamdeck-v2-#{System.unique_integer([:positive])}")
    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)
    EndpointStubs.put(decision_store: store)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{store: store}
  end

  defp question(id, multi_select \\ false) do
    %{question_id: id, header: "Scope", question: "Choose scope?", multi_select: multi_select, options: [%{label: "Small"}, %{label: "Large"}]}
  end

  defp request!(store, questions) do
    payload = %{
      "source_id" => "deck-#{System.unique_integer([:positive])}",
      "question" => "Choose?",
      "blocking" => false,
      "authority" => "human_required",
      "context" => %{"authority_basis" => "product"},
      "reversibility" => "reversible"
    }

    # NativeCapture's contract fills the v1 fields from the normalized first question.
    {:ok, normalized} = Commands.RequestContent.normalize_questions(questions)
    payload = Map.merge(payload, Map.new(Commands.RequestContent.v1_projection(normalized), fn {key, value} -> {Atom.to_string(key), value} end))

    opts = [
      ticket: %{identifier: "AIUR-1"},
      source: %{agent_id: "agent-1", session_id: "session-1"},
      native: %{harness: :codex, native_ref: "native-request", hold: :in_band},
      origin: :native_question,
      questions: questions
    ]

    assert {:ok, %{decision: decision}} = DecisionStore.request(payload, opts, store)
    decision
  end

  test "multi-question Commands project dashboard-only and reject both answer paths", %{store: store} do
    assert_dashboard_only(store, [question("scope"), question("timing")])
  end

  test "multi-select Commands project dashboard-only and reject both answer paths", %{store: store} do
    assert_dashboard_only(store, [question("scope", true)])
  end

  defp assert_dashboard_only(store, questions) do
    decision = request!(store, questions)
    item = StreamdeckCommands.item(decision)
    assert item["answerable_on_deck"] == false
    assert item["short_label"] == "Scope"
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
    receive_barrier(%Message{event: "commands"})

    for answer <- [%{"option_id" => "q1-o1"}, %{"custom_response" => "Small"}] do
      payload = Map.merge(answer, %{"decision_id" => decision.decision_id, "version" => decision.version, "idempotency_key" => "deck-answer"})
      ref = push(socket, "answer_command", payload)
      reply = receive_barrier(%Phoenix.Socket.Reply{ref: ^ref})
      assert reply.status == :error
      assert reply.payload == %{reason: "dashboard_only"}
    end

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer == nil
  end

  test "single native question retains option keys and native answer decoding (future regression guard)", %{store: store} do
    decision = request!(store, [question("scope")])
    item = StreamdeckCommands.item(decision)
    assert item["answerable_on_deck"] == true
    assert Enum.map(item["options"], & &1["id"]) == ["q1-o1", "q1-o2"]
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
    receive_barrier(%Message{event: "commands"})
    ref = push(socket, "answer_command", %{"decision_id" => decision.decision_id, "version" => decision.version, "idempotency_key" => "native-answer", "option_id" => "q1-o2"})
    reply = receive_barrier(%Phoenix.Socket.Reply{ref: ^ref})
    assert reply.status == :ok
    assert reply.payload["status"] == "accepted"
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer.selected_option_id == "q1-o2"
    assert Commands.Answering.decode_question_answers(current.questions, current.answer) == {:ok, %{"scope" => ["Large"]}}
  end

  test "legacy Commands remain deck-answerable" do
    assert StreamdeckCommands.item(command_decision("AIUR-1"))["answerable_on_deck"] == true
  end
end
