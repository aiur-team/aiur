defmodule Aiur.AgentRunner.TurnPromptTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.{Issue, PromptBuilder}

  describe "build_turn_prompt/4" do
    test "turn one cold start delegates to PromptBuilder" do
      issue = %Issue{id: "1", identifier: "1", title: "Cold start"}

      assert TurnPrompt.build_turn_prompt(issue, [], 1, nil) == PromptBuilder.build_prompt(issue, [])
    end

    test "turn one resumed session uses restart continuation guidance" do
      issue = %Issue{id: "378", identifier: "378", title: "Resume sessions"}

      prompt = TurnPrompt.build_turn_prompt(issue, [resumed: true], 1, nil)

      assert prompt =~ "session resumed after an aiur restart"
      assert prompt =~ "Do not restart from scratch"
      refute prompt =~ issue.title
    end

    test "turn one cold rework uses rework continuation guidance, not a cold restart" do
      issue = %Issue{id: "1091", identifier: "1091", title: "Fetch planning graph", state: "rework"}

      prompt = TurnPrompt.build_turn_prompt(issue, [], 1, nil)

      assert prompt =~ "rework"
      assert prompt =~ "Agent Workpad"
      assert prompt =~ "review feedback"
      # rework continuation must not re-run planning or restate the full cold task
      refute prompt == PromptBuilder.build_prompt(issue, [])
      refute prompt =~ issue.title
    end

    test "turn one resumed rework still uses restart continuation guidance" do
      issue = %Issue{id: "1091", identifier: "1091", title: "Fetch planning graph", state: "rework"}

      prompt = TurnPrompt.build_turn_prompt(issue, [resumed: true], 1, nil)

      assert prompt =~ "session resumed after an aiur restart"
    end

    test "turn one cold non-rework state still delegates to PromptBuilder" do
      issue = %Issue{id: "5", identifier: "5", title: "Todo work", state: "todo"}

      assert TurnPrompt.build_turn_prompt(issue, [], 1, nil) == PromptBuilder.build_prompt(issue, [])
    end

    test "rework state matching is case-insensitive and prefix-tolerant" do
      for state <- ["REWORK", "agent:rework", "Rework"] do
        issue = %Issue{id: "1", identifier: "1", title: "T", state: state}
        prompt = TurnPrompt.build_turn_prompt(issue, [], 1, nil)
        assert prompt =~ "Agent Workpad", "expected rework branch for state=#{state}"
      end
    end

    test "continuation prompts render finite and uncapped turn counts" do
      finite = TurnPrompt.build_turn_prompt(%Issue{}, [], 3, 10)
      uncapped = TurnPrompt.build_turn_prompt(%Issue{}, [], 4, nil)

      assert finite =~ "continuation turn #3 of 10"
      assert uncapped =~ "continuation turn #4"
      refute uncapped =~ "continuation turn #4 of"
    end
  end
end
