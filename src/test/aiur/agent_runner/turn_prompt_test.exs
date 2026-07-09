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

    test "continuation prompts render finite and uncapped turn counts" do
      finite = TurnPrompt.build_turn_prompt(%Issue{}, [], 3, 10)
      uncapped = TurnPrompt.build_turn_prompt(%Issue{}, [], 4, nil)

      assert finite =~ "continuation turn #3 of 10"
      assert uncapped =~ "continuation turn #4"
      refute uncapped =~ "continuation turn #4 of"
    end
  end
end
