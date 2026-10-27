Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.NativeCaptureTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Codex.UserInputAnswers
  alias Aiur.Commands.Answering
  alias Aiur.Commands.NativeCapture
  alias Aiur.Events.Publisher

  @fixtures Path.expand("../../fixtures/codex/request_user_input", __DIR__)

  setup %{dir: dir} do
    tracked_key = {Publisher, :tracked_fn}
    tracked = :persistent_term.get(tracked_key, nil)
    Publisher.set_tracked_fn(fn _ -> true end)
    on_exit(fn -> :persistent_term.put(tracked_key, tracked) end)
    store = start_store!(dir, dispatch_delay_ms: 60_000)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    %{ctx: %{ticket: @ticket, source: @source, session_ref: "session-1", store: store, workspace: dir}}
  end

  defp normalized(file \\ "request_user_input.json") do
    frame = @fixtures |> Path.join(file) |> File.read!() |> Jason.decode!()
    params = frame["params"]

    %{
      harness: :codex,
      native_ref: "#{params["threadId"]}:#{frame["id"]}",
      call_id: params["itemId"],
      turn_id: params["turnId"],
      blocking: params["isBlocking"],
      questions:
        Enum.map(params["questions"], fn q ->
          %{
            question_id: q["id"],
            header: q["header"],
            question: q["question"],
            options: Enum.map(q["options"], &%{label: &1["label"], description: &1["description"]}),
            multi_select: false,
            allow_other: q["isOther"],
            secret: q["isSecret"]
          }
        end)
    }
  end

  defp records(dir), do: dir |> Path.join("decisions.ndjson") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "captured question creates and persists one attributed Command using trusted identity", %{ctx: ctx, dir: dir} do
    input = normalized() |> Map.put(:ticket, %{identifier: "forged"}) |> Map.put(:source, %{session_id: "forged"})
    assert NativeCapture.classify(input) == :question
    assert {:command, d} = NativeCapture.capture(input, ctx)
    assert d.kind == "native_question"
    assert d.question == "Which colour should README.md mention: red or blue?"
    assert d.context.short_summary == "Colour"
    assert Enum.map(d.options, & &1.id) == ["o1", "o2"]
    assert Enum.map(d.options, & &1.label) == ["Red (Recommended)", "Blue"]
    assert d.authority == :supervisor_allowed
    assert d.reversibility == :reversible
    assert d.blocking == false
    assert d.ticket.identifier == "979"
    assert d.source.session_id == "session-1"
    assert d.requester == %{kind: :worker, ticket: "979", session_ref: "session-1", harness: "codex", executor_id: nil}
    assert d.origin == :native_question
    assert d.native == %{harness: :codex, native_ref: "<uuid>:0", call_id: "call_<id>", turn_id: "<uuid>", question_ids: ["colour"], hold: :in_band}
    assert [%{question_id: "colour", allow_other: true, multi_select: false}] = d.questions
    assert Answering.decode_question_answers(d.questions, %{selected_option_id: "o1", custom_response: nil}) == {:ok, %{"colour" => ["Red (Recommended)"]}}
    assert {:ok, ^d} = DecisionStore.get(d.decision_id, ctx.store)
    assert Enum.map(records(dir), & &1["event_type"]) == ["requested", "request_attributed"]

    assert NativeCapture.release_text(d.decision_id) ==
             "Your question is recorded as Command #{d.decision_id}. Stop and end your turn; the answer will arrive as a message."
  end

  test "same native ref is idempotent but different native refs have distinct source ids", %{ctx: ctx, dir: dir} do
    input = normalized()
    assert {:command, first} = NativeCapture.capture(input, ctx)
    assert {:command, ^first} = NativeCapture.capture(input, ctx)
    assert length(records(dir)) == 2
    assert {:ok, %{source_id: "native:<uuid>:0"}, _} = NativeCapture.to_request(input, ctx)
    assert {:ok, %{source_id: "native:other"}, _} = NativeCapture.to_request(%{input | native_ref: "other"}, ctx)
  end

  test "captured multiple questions retain the single-option question and project first options", %{ctx: ctx} do
    input = normalized("request_user_input_two_questions.json")
    assert {:command, d} = NativeCapture.capture(input, ctx)
    assert d.question == "2 questions: Colour, Dummy token"
    assert Enum.map(d.options, & &1.label) == ["Red", "Blue"]
    assert d.native.question_ids == ["colour", "dummy_token"]
    assert [%{question_id: "colour"}, %{question_id: "dummy_token", options: [%{label: "Enter token"}]}] = d.questions
  end

  test "distinct native requests survive creation dedup and answering a sibling", %{ctx: ctx} do
    input = normalized()
    assert {:command, first} = NativeCapture.capture(input, ctx)
    assert {:command, second} = NativeCapture.capture(%{input | native_ref: "second"}, ctx)
    refute first.decision_id == second.decision_id
    assert second.native.native_ref == "second"
    assert {:ok, %{decision: _answered}} = answer(ctx.store, first.decision_id, %{expected_version: 1, idempotency_key: "answer-first", option_id: "o1"})
    assert {:ok, %{decision_status: :open, native: %{native_ref: "second"}}} = DecisionStore.get(second.decision_id, ctx.store)

    multi = normalized("request_user_input_two_questions.json") |> Map.put(:native_ref, "multi")
    assert {:command, multi_first} = NativeCapture.capture(multi, ctx)
    changed = update_in(multi.questions, fn [first, second] -> [%{first | question: "Which host should run the build?"}, second] end)
    assert {:command, multi_second} = NativeCapture.capture(%{changed | native_ref: "multi-second"}, ctx)
    refute multi_first.decision_id == multi_second.decision_id
    assert hd(multi_second.questions).question == "Which host should run the build?"
  end

  test "derived approval labels use the existing policy for every question", %{ctx: ctx, dir: dir} do
    # The recorded approval.json is commandExecution/requestApproval, not a user-input question.
    # These are explicit variants of the captured question, not recorded approval questions.
    for label <- ["Approve this Session", "Approve Once", "  allow this action", "approve change"] do
      input = put_in(normalized(), [:questions, Access.at(0), :options], [%{label: label}, %{label: "Deny"}])
      assert NativeCapture.classify(input) == :approval
      assert NativeCapture.capture(input, ctx) == {:policy, :approval}
      mixed = Map.update!(input, :questions, &(&1 ++ [%{hd(normalized().questions) | question_id: "other"}]))
      assert NativeCapture.classify(mixed) == :question
    end

    assert records(dir) == []
  end

  test "native and ordinary questions stay independent in either order", %{ctx: ctx} do
    for first_kind <- [:ordinary, :native] do
      input = put_in(normalized(), [:questions, Access.at(0), :question], "Boundary choice #{first_kind}?")
      input = %{input | native_ref: "boundary-#{first_kind}"}
      {:ok, payload, _opts} = NativeCapture.to_request(input, ctx)
      ordinary = %{payload | kind: "ordinary", source_id: "ordinary-#{first_kind}"}

      results =
        for kind <- [first_kind, if(first_kind == :ordinary, do: :native, else: :ordinary)] do
          case kind do
            :native ->
              assert {:command, decision} = NativeCapture.capture(input, ctx)
              decision

            :ordinary ->
              assert {:ok, %{decision: decision}} = request(ctx.store, ordinary)
              decision
          end
        end

      [first, second] = results
      refute first.decision_id == second.decision_id
      assert {:ok, %{decision: _answered}} = answer(ctx.store, first.decision_id, %{expected_version: 1, idempotency_key: "answer-boundary", option_id: "o1"})
      assert {:ok, %{decision_status: :open}} = DecisionStore.get(second.decision_id, ctx.store)
    end
  end

  test "derived secret flag releases without storing or publishing the question text", %{ctx: ctx, dir: dir} do
    topic = "ticket.979.agent.native-secret-question"
    :ok = Exchange.subscribe(topic)
    # The real capture's isSecret is false, including its dummy-token prompt.
    input = put_in(normalized(), [:questions, Access.at(0), :secret], true)
    log = capture_log(fn -> assert NativeCapture.capture(input, ctx) == {:release, "aiur cannot collect secrets through Commands."} end)
    assert NativeCapture.classify(input) == :secret
    assert_received {:event, %{topic: ^topic} = payload}
    assert payload["needs_attention"] == true
    assert payload["source_ticket_id"] == "979"
    assert payload["message"] == NativeCapture.secret_release_text()
    refute Jason.encode!(payload) =~ hd(input.questions).question
    refute log =~ hd(input.questions).question
    assert records(dir) == []
    for path <- Path.wildcard(Path.join(dir, "**/*")), File.regular?(path), do: refute(File.read!(path) =~ hd(input.questions).question)
    approval_secret = put_in(input, [:questions, Access.at(0), :options], [%{label: "Approve Once"}])
    assert NativeCapture.classify(approval_secret) == :secret
  end

  test "malformed question and missing native ref release without writing", %{ctx: ctx, dir: dir} do
    input = normalized()
    invalid = update_in(input.questions, fn [q] -> [Map.delete(q, :question_id)] end)

    for request <- [invalid, %{input | native_ref: nil}, %{input | questions: []}] do
      capture_log(fn -> assert NativeCapture.capture(request, ctx) == {:release, UserInputAnswers.non_interactive_answer()} end)
    end

    assert records(dir) == []
    assert {:ok, %{blocking: true}, _} = NativeCapture.to_request(Map.delete(input, :blocking), ctx)
  end

  test "unavailable store and rejected request release with the existing noninteractive text", %{ctx: ctx, dir: dir} do
    GenServer.stop(ctx.store)
    log = capture_log(fn -> assert NativeCapture.capture(normalized(), ctx) == {:release, UserInputAnswers.non_interactive_answer()} end)
    assert log =~ "native_capture phase=request_failed issue_id= issue_identifier=979 session_id=session-1 reason=store_unavailable"

    store = start_store!(dir, dispatch_delay_ms: 60_000)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    invalid = %{normalized() | blocking: "invalid"}
    capture_log(fn -> assert NativeCapture.capture(invalid, %{ctx | store: store}) == {:release, UserInputAnswers.non_interactive_answer()} end)
  end
end
