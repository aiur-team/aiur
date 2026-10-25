defmodule Aiur.DecisionAnswerCommentTest do
  use ExUnit.Case, async: true

  alias Aiur.{Decision, DecisionAnswer, DecisionAnswerComment}

  test "the stable action marker makes a repeated ticket write idempotent" do
    decision = decision()
    {:ok, comments} = Agent.start_link(fn -> [] end)
    {:ok, writes} = Agent.start_link(fn -> 0 end)

    fetch = fn _ticket -> {:ok, Agent.get(comments, & &1)} end

    create = fn _ticket, body ->
      Agent.update(comments, &[%{body: body} | &1])
      Agent.update(writes, &(&1 + 1))
      :ok
    end

    assert :ok = DecisionAnswerComment.ensure(decision, fetch: fetch, create: create)
    assert :ok = DecisionAnswerComment.ensure(decision, fetch: fetch, create: create)
    assert Agent.get(writes, & &1) == 1

    [%{body: body}] = Agent.get(comments, & &1)
    assert body =~ DecisionAnswerComment.marker("action-1")
    assert body =~ "Which option?"
    assert body =~ "ship: Ship it"
    assert body =~ "operator-1"
    assert body =~ "2026-10-20T18:02:03Z"
  end

  defp decision do
    at = DateTime.from_naive!(~N[2026-10-20 18:02:03], "Etc/UTC")

    answer = %DecisionAnswer{
      action_id: "action-1",
      decision_id: "decision-1",
      decision_version: 1,
      idempotency_key: "key-1",
      selected_option_id: "ship",
      actor: %{kind: :operator, id: "operator-1"},
      accepted_at: at,
      content_hash: "hash"
    }

    %Decision{
      decision_id: "decision-1",
      version: 1,
      ticket: %{identifier: "5491", title: "test", url: nil},
      source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil},
      authority: :human_required,
      urgency: :normal,
      blocking: true,
      reversibility: :reversible,
      question: "Which option?",
      context: %{},
      options: [%{id: "ship", label: "Ship it", description: nil, benefits: nil, drawbacks: nil, risk: nil}],
      artifacts: [],
      created_at: at,
      content_hash: "request-hash",
      answer: answer
    }
  end
end
