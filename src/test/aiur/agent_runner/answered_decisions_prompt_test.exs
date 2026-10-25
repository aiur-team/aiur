defmodule Aiur.AgentRunner.AnsweredDecisionsPromptTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.Issue

  test "the first prompt includes durable answered decisions with attribution and time" do
    accepted_at = DateTime.from_naive!(~N[2026-10-20 18:02:03], "Etc/UTC")

    decision = %{
      question: "Ship this release?",
      answer: "Proceed exactly",
      actor: "operator: kevin",
      accepted_at: accepted_at
    }

    prompt =
      TurnPrompt.build_turn_prompt(
        %Issue{identifier: "5491", title: "Resume", state: "in-progress"},
        [answered_decisions: [decision]],
        1,
        nil
      )

    assert prompt =~ "## Answered decisions"
    assert prompt =~ "Ship this release?"
    assert prompt =~ "Proceed exactly"
    assert prompt =~ "operator: kevin"
    assert prompt =~ "2026-10-20T18:02:03Z"
  end
end
