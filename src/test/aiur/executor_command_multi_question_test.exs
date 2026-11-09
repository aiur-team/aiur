defmodule Aiur.ExecutorCommandMultiQuestionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.Commands.Answering
  alias Aiur.{CommandsCLI, DecisionEvent, DecisionStore, ExecutorCommandCLI}

  @questions [
    %{
      question_id: "scope",
      header: "Scope",
      question: "Which packages?",
      options: [%{id: "core", label: "Core"}, %{id: "web", label: "Web"}, %{id: "cli", label: "CLI"}],
      multi_select: true,
      allow_other: false
    },
    %{question_id: "order", header: "Order", question: "Which order?", options: [%{id: "first", label: "First"}, %{id: "last", label: "Last"}], allow_other: false},
    %{question_id: "note", header: "Note", question: "Anything else?", options: [%{id: "none", label: "Nothing"}, %{id: "later", label: "Later"}], allow_other: true}
  ]

  @answers %{"scope" => ["Core", "CLI"], "order" => ["Last"], "note" => ["Ship behind a flag"]}

  setup do
    dir = Aiur.TestSupport.tmp_root!("multi-question-7871")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end})

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{question: "Plan the release", blocking: true, source_id: "multi-7871", authority: "supervisor_allowed", reversibility: "reversible"},
        [ticket: %{identifier: "7871", title: "Multi", url: nil}, source: %{agent_id: "agent", session_id: "session"}, questions: @questions],
        store
      )

    %{store: store, decision: decision}
  end

  defp answer(ctx, flags, key \\ "multi-1") do
    params = [decision_id: ctx.decision.decision_id, expected_version: ctx.decision.version, rationale: "Delegated release call", idempotency_key: key] ++ flags
    stderr = capture_io(:stderr, fn -> capture_io(fn -> send(self(), {:code, ExecutorCommandCLI.answer(params, decision_store: ctx.store)}) end) end)
    assert_received {:code, code}
    {code, stderr}
  end

  defp recorded(ctx) do
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    decision
  end

  test "one executor-answer call records every question's answer from --answer and --answer-text", ctx do
    assert {0, ""} = answer(ctx, answers: ["scope=cli,core", "Order=last"], answer_texts: ["note=Ship behind a flag"])
    decision = recorded(ctx)
    assert decision.decision_status == :decided
    assert Answering.decode_question_answers(decision.questions, decision.answer) == {:ok, @answers}
  end

  test "--answers-file records the identical payload hash as the flags", ctx do
    assert {0, ""} = answer(ctx, answers: ["scope=core", "scope=cli", "order=last"], answer_texts: ["note=Ship behind a flag"])
    flags_hash = recorded(ctx).answer.content_hash

    file_json = Jason.encode!(%{"question_answers" => %{"scope" => ["cli", "core"], "order" => ["last"], "note" => ["Ship behind a flag"]}})

    stdout =
      capture_io(fn ->
        assert ExecutorCommandCLI.answer(
                 [decision_id: ctx.decision.decision_id, expected_version: ctx.decision.version, rationale: "Delegated release call", idempotency_key: "multi-1", answers_json: file_json],
                 decision_store: ctx.store
               ) == 0
      end)

    # Same key, same content: the store replays instead of conflicting.
    assert stdout =~ "duplicate"
    assert recorded(ctx).answer.content_hash == flags_hash
  end

  test "omitting a question names it and records nothing", ctx do
    assert {64, stderr} = answer(ctx, answers: ["scope=core", "order=first"])
    assert stderr =~ "unanswered: note (Note)"
    refute stderr =~ "scope"
    assert recorded(ctx).answer == nil
  end

  test "a legacy single --custom-response on a multi-question Command names the unanswered questions", ctx do
    assert {64, stderr} = answer(ctx, custom_response: "Core")
    assert stderr =~ "unanswered: order (Order), note (Note)"
    assert recorded(ctx).answer == nil
  end

  test "aiur command prints every question and a template that is accepted once filled", ctx do
    output = capture_io(fn -> assert CommandsCLI.run(decision_id: ctx.decision.decision_id, decision_store: ctx.store, decision_metrics: make_ref(), history_fun: fn -> [] end) == 0 end)

    for id <- ["scope", "order", "note"], do: assert(output =~ "Question #{id} [")
    assert output =~ "multi_select: true; allow_other: false"
    assert output =~ "Option cli: CLI"
    [_, flags] = Regex.run(~r/Answer template: aiur executor-answer \S+ --expected-version \d+ (.+)$/m, output)
    assert flags == "--answer scope=<option-id>[,<option-id>] --answer order=<option-id> --answer note=<option-id>"

    filled = flags |> String.replace("<option-id>[,<option-id>]", "core,web") |> String.replace("order=<option-id>", "order=first") |> String.replace("note=<option-id>", "note=none")
    answers = filled |> String.split("--answer ", trim: true) |> Enum.map(&String.trim/1)
    assert {0, ""} = answer(ctx, answers: answers)
    assert Answering.decode_question_answers(@questions, recorded(ctx).answer) == {:ok, %{"scope" => ["Core", "Web"], "order" => ["First"], "note" => ["Nothing"]}}
  end

  test "executor-moot replayed with one idempotency key records one moot", ctx do
    params = [decision_id: ctx.decision.decision_id, expected_version: ctx.decision.version, reason_class: "ticket_closed", idempotency_key: "moot-1", rationale: "Ticket shipped"]
    capture_io(fn -> assert ExecutorCommandCLI.moot(params, decision_store: ctx.store) == 0 end)
    replay = capture_io(fn -> assert ExecutorCommandCLI.moot(params, decision_store: ctx.store) == 0 end)
    assert replay =~ "duplicate"

    {:ok, events} = DecisionStore.audit_history(ctx.decision.decision_id, ctx.store)
    assert [mooted] = Enum.filter(events, &match?(%DecisionEvent{type: :decision_mooted}, &1))
    assert mooted.data.rationale == "Ticket shipped"

    conflict = capture_io(:stderr, fn -> assert ExecutorCommandCLI.moot(Keyword.put(params, :reason_class, "origin_agent_gone"), decision_store: ctx.store) == 1 end)
    assert conflict =~ "--idempotency-key was already used"
  end
end
