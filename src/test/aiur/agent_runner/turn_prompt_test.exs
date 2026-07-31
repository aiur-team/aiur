defmodule Aiur.AgentRunner.TurnPromptTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.{Issue, PromptBuilder}

  describe "first_turn_mode/2" do
    test "prior_work on an in-progress recycle is a continuation, not a cold start" do
      issue = %Issue{id: "1", identifier: "1", title: "t", state: "in-progress"}

      assert TurnPrompt.first_turn_mode(issue, prior_work: true) == :continuation
    end

    test "resumed wins over prior_work (the thread already carries history)" do
      issue = %Issue{id: "1", identifier: "1", title: "t", state: "in-progress"}

      assert TurnPrompt.first_turn_mode(issue, resumed: true, prior_work: true) == :resumed
    end

    test "without prior_work an in-progress dispatch stays cold (flag off = today's behavior)" do
      issue = %Issue{id: "1", identifier: "1", title: "t", state: "in-progress"}

      assert TurnPrompt.first_turn_mode(issue, []) == :cold
      assert TurnPrompt.first_turn_mode(issue, prior_work: false) == :cold
    end

    test "rework state is a continuation regardless of prior_work" do
      for state <- ["rework", "agent:rework", "REWORK"] do
        issue = %Issue{id: "1", identifier: "1", title: "t", state: state}
        assert TurnPrompt.first_turn_mode(issue, []) == :continuation
      end
    end

    test "a fresh todo dispatch is cold" do
      issue = %Issue{id: "1", identifier: "1", title: "t", state: "todo"}

      assert TurnPrompt.first_turn_mode(issue, []) == :cold
    end
  end

  describe "build_turn_prompt/4" do
    test "turn one prior_work recycle gets continuation guidance plus the ticket contract" do
      issue = %Issue{id: "1091", identifier: "1091", title: "Fetch graph", state: "in-progress"}

      prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true], 1, nil)

      assert prompt =~ "Agent Workpad"
      assert prompt =~ "do not restart the ticket from scratch"
      # keeps the full operating contract so a cold thread still knows the ticket
      assert prompt =~ issue.title
      refute prompt == PromptBuilder.build_prompt(issue, prior_work: true)
    end

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

    test "turn one cold rework keeps the ticket contract without restarting discovery" do
      issue = %Issue{
        id: "1091",
        identifier: "1091",
        title: "Fetch planning graph",
        description: "Render the dependency graph",
        state: "rework"
      }

      prompt = TurnPrompt.build_turn_prompt(issue, [], 1, nil)

      assert prompt =~ "rework"
      assert prompt =~ "Agent Workpad"
      assert prompt =~ "review feedback"
      assert prompt =~ "## Shared Agent Instructions"
      assert prompt =~ issue.title
      assert prompt =~ issue.description
      assert prompt =~ "generic cold-start phase order"
      refute prompt == PromptBuilder.build_prompt(issue, [])
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

    # Regression: agents must not stall at the ce-plan → ce-work boundary waiting
    # for an operator message. All three prompt paths must carry the authorization.

    test "cold-start prompt authorizes the planning-to-work transition (shared instructions)" do
      issue = %Issue{id: "1041", identifier: "1041", title: "Auto-transition", state: "in-progress"}
      prompt = TurnPrompt.build_turn_prompt(issue, [], 1, nil)

      assert prompt =~ "ce-plan"
      assert prompt =~ "ce-work"
      assert prompt =~ "planning-to-work transition is authorized"
    end

    test "in-process continuation turn authorizes the planning-to-work transition" do
      issue = %Issue{id: "1041", identifier: "1041", title: "Auto-transition", state: "in-progress"}
      prompt = TurnPrompt.build_turn_prompt(issue, [], 2, nil)

      assert prompt =~ "planning-to-work transition is authorized"
    end

    test "resumed-session prompt authorizes the planning-to-work transition" do
      issue = %Issue{id: "1041", identifier: "1041", title: "Auto-transition", state: "in-progress"}
      prompt = TurnPrompt.build_turn_prompt(issue, [resumed: true], 1, nil)

      assert prompt =~ "planning-to-work transition is authorized"
    end

    # Plain control-only resume (aiur restart) vs. resume-with-continue:
    # The :resumed path is a pure "you were reattached" nudge — it does NOT replay
    # the cold-start ticket contract, because the thread already carries it. The
    # in-process continuation (turn N>1) behaves identically for the transition
    # rule. There is no separate "resume-with-continue" option; the authorization
    # is always present in both paths.
    test "plain resumed prompt does not replay the cold-start ticket contract" do
      issue = %Issue{id: "1041", identifier: "1041", title: "Resume semantics", state: "in-progress"}
      resumed_prompt = TurnPrompt.build_turn_prompt(issue, [resumed: true], 1, nil)
      cold_prompt = TurnPrompt.build_turn_prompt(issue, [], 1, nil)

      refute resumed_prompt =~ issue.title,
             "resumed prompt must not replay the ticket contract (thread already has it)"

      assert cold_prompt =~ issue.title
    end
  end
end
