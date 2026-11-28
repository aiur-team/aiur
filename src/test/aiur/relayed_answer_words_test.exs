defmodule Aiur.RelayedAnswerWordsTest do
  use ExUnit.Case, async: true

  alias Aiur.{Decision, DecisionAnswer, DecisionAnswerComment, DecisionDispatch, DecisionStore, PromptBuilder}
  alias Aiur.Orchestrator.Dispatcher.AnsweredDecisions

  # open-games #644: the Executor relayed Kevin's notes with option B, but the
  # ticket comment, the worker's message and the redispatch prompt carried only
  # "B: Needs changes", so the worker had to ask for the notes again.
  @words "trailers should always be the same horizontal aspect ratio.\ntrailers should never show menus, gameplay only."

  test "the answer comment quotes the relayed operator words" do
    body = DecisionAnswerComment.render(decision(relayed_answer()))

    assert body =~ "**Answer:** B: Needs changes"
    assert body =~ "**Operator's words:**\n\n> trailers should always be the same horizontal aspect ratio.\n> trailers should never show menus, gameplay only."
  end

  test "an answer without relayed words keeps the comment unchanged" do
    body = DecisionAnswerComment.render(decision(%{relayed_answer() | operator_quote: nil, relayed_by: nil, actor: %{kind: :operator, id: "kevin"}}))

    refute body =~ "Operator's words"
    assert body =~ "**Answer:** B: Needs changes\n\n**Answered by:**"
  end

  test "the worker's answer message carries the relayed words verbatim" do
    message = DecisionDispatch.render(decision(relayed_answer()))

    assert message =~ "Selected option `B`: Needs changes\n\nOperator's words (verbatim):\n" <> @words
  end

  test "a redispatched worker's prompt carries the relayed words" do
    dir = Aiur.TestSupport.tmp_root!("relayed-answer-words")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    store =
      start_supervised!(
        {DecisionStore,
         name: nil,
         state_dir: dir,
         filesystem_sync_fun: fn -> :ok end,
         dispatch_delay_ms: 60_000,
         retry_delays_ms: [],
         dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end,
         answer_comment_publisher: fn _decision -> :ok end}
      )

    {:ok, %{decision: requested}} =
      DecisionStore.request(
        %{"question" => "Trailer verdict?", "blocking" => false, "source_id" => "relay-words", "options" => [%{"id" => "A", "label" => "Approve"}, %{"id" => "B", "label" => "Needs changes"}]},
        [ticket: %{identifier: "644", title: "Trailer", url: nil}, source: %{agent_id: "agent-644", session_id: "s-644", event_id: nil}],
        store
      )

    {:ok, _answer} =
      DecisionStore.answer(
        requested.decision_id,
        %{"idempotency_key" => "relay-words", "expected_version" => 1, "option_id" => "B", "operator_quote" => @words, "relayed_by" => "nuc-ogm-executor"},
        [actor: %{kind: :operator_relayed, id: "nuc-ogm-executor"}],
        store
      )

    assert [entry] = AnsweredDecisions.for_ticket("644", store, 5_000)
    prompt = PromptBuilder.answered_decisions_prompt([entry])

    assert prompt =~ "Answer: B: Needs changes\nOperator's words (verbatim):\n" <> @words <> "\nAnswered by:"
  end

  defp relayed_answer do
    %DecisionAnswer{
      action_id: "act-644",
      decision_id: "dec-644",
      decision_version: 1,
      idempotency_key: "key-644",
      selected_option_id: "B",
      operator_quote: @words,
      relayed_by: "nuc-ogm-executor",
      rationale: "Operator answer relayed by nuc-ogm-executor",
      actor: %{kind: :operator_relayed, id: "nuc-ogm-executor"},
      accepted_at: DateTime.from_naive!(~N[2026-11-17 21:12:57], "Etc/UTC"),
      content_hash: "hash"
    }
  end

  defp decision(answer) do
    %Decision{
      decision_id: "dec-644",
      version: 2,
      ticket: %{identifier: "644", title: "Trailer", url: nil},
      source: %{agent_id: "agent-644", session_id: "s-644", event_id: nil},
      authority: :human_required,
      urgency: :normal,
      blocking: false,
      reversibility: :reversible,
      question: "Trailer verdict?",
      context: %{},
      options: [
        %{id: "A", label: "Approve", description: nil, benefits: nil, drawbacks: nil, risk: nil},
        %{id: "B", label: "Needs changes", description: nil, benefits: nil, drawbacks: nil, risk: nil}
      ],
      artifacts: [],
      created_at: DateTime.from_naive!(~N[2026-11-17 18:00:00], "Etc/UTC"),
      content_hash: "request-hash",
      answer: answer
    }
  end
end
