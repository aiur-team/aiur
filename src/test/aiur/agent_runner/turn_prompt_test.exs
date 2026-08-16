defmodule Aiur.AgentRunner.TurnPromptTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.{Config, Issue, PromptBuilder}

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

    # Regression for #1973: the cold-start prompt states the authoritative
    # `tracker.base_branch`, but `build_turn_prompt/4` only delegates to
    # `PromptBuilder.build_prompt/2` on turn one. A mid-run base change must
    # still be re-stated so a long-lived session cannot silently keep opening
    # PRs against a retired base.
    test "in-process continuation restates the authoritative integration branch" do
      prompt = TurnPrompt.build_turn_prompt(%Issue{}, [], 2, nil)

      assert prompt =~ "## Authoritative integration branch (restated)"
      assert prompt =~ "tracker.base_branch"
      assert prompt =~ ~r/--base "#{Config.base_branch()}"/i
    end

    test "resumed-session prompt restates the authoritative integration branch" do
      prompt = TurnPrompt.build_turn_prompt(%Issue{}, [resumed: true], 1, nil)

      assert prompt =~ "## Authoritative integration branch (restated)"
      assert prompt =~ "tracker.base_branch"
      assert prompt =~ ~r/--base "#{Config.base_branch()}"/i
    end

    # Regression: agents must not stall at the ce-plan → ce-work boundary waiting
    # for an operator message. Every prompt surface must carry the authorization
    # AND the interactive-menu suppression rule with the correct semantic
    # direction (authorized, never negated).

    # #1024 / #1041: a scripted stand-in for the model at the ce-plan → ce-work
    # boundary. It ends turn 1 at a plan handoff and, on the next autonomous
    # turn, must decide from the delivered prompt alone whether to begin
    # `ce-work` — there is no operator-message channel to consult. `begin_work?/1`
    # mirrors the diagnosed contract: proceed only when the prompt positively
    # authorizes the transition on an active ticket; otherwise park at the
    # handoff (the stall).
    defmodule FakePlanningHandoffAgent do
      @moduledoc false

      @spec begin_work?(String.t()) :: boolean()
      def begin_work?(prompt) when is_binary(prompt) do
        positively_authorizes?(prompt) and not negated?(prompt)
      end

      defp positively_authorizes?(prompt) do
        prompt =~ "planning-to-work transition is authorized" and
          prompt =~ "proceed directly to `ce-work`" and
          prompt =~ "without an operator message"
      end

      defp negated?(prompt), do: prompt =~ ~r/is\s+not\s+authorized|not\s+authorized/i
    end

    defp assert_prompt_authorizes_transition(prompt) do
      # Positive, unconditional direction: proceed straight to ce-work.
      assert prompt =~ "planning-to-work transition is authorized"
      assert prompt =~ "proceed directly to `ce-work`"
      assert prompt =~ "without an operator message"

      # The pause carve-out stays narrow: only genuine operator decisions,
      # dependency blockers, or scope questions.
      assert prompt =~ "unresolved operator decision"
      assert prompt =~ "dependency blocker"
      assert prompt =~ "scope question"

      # Interactive phase-skill menus must not end an autonomous ticket turn.
      assert prompt =~ "Interactive CE phase menus do not end an autonomous ticket turn"

      # Guard the semantic direction: the authorization must never be negated.
      refute prompt =~ ~r/is\s+not\s+authorized|not\s+authorized/i
    end

    setup do
      issue = %Issue{id: "1041", identifier: "1041", title: "Auto-transition", state: "in-progress"}
      %{issue: issue}
    end

    test "cold-start prompt authorizes the planning-to-work transition (shared instructions)", %{issue: issue} do
      prompt = TurnPrompt.build_turn_prompt(issue, [], 1, nil)

      # Confirm this is the cold-start path (shared instructions present) not a continuation
      assert prompt =~ "## Shared Agent Instructions"
      assert_prompt_authorizes_transition(prompt)
    end

    test "in-process continuation turn authorizes the planning-to-work transition", %{issue: issue} do
      prompt = TurnPrompt.build_turn_prompt(issue, [], 2, nil)

      assert prompt =~ "continuation turn #2"
      assert_prompt_authorizes_transition(prompt)
    end

    test "resumed-session prompt authorizes the planning-to-work transition", %{issue: issue} do
      prompt = TurnPrompt.build_turn_prompt(issue, [resumed: true], 1, nil)

      assert prompt =~ "session resumed after an aiur restart"
      assert_prompt_authorizes_transition(prompt)
    end

    test "first-turn continuation (prior work / rework) explicitly authorizes the transition", %{issue: issue} do
      prior_prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true], 1, nil)
      rework_prompt = TurnPrompt.build_turn_prompt(%{issue | state: "rework"}, [], 1, nil)

      # The continuation guidance "supersedes the generic cold-start phase order",
      # which would otherwise make the inherited shared rule ambiguous; the
      # authorization and menu-suppression rule must be explicit here.
      assert prior_prompt =~ "planning-to-work transition is authorized"
      assert prior_prompt =~ "proceed directly to `ce-work`"
      assert prior_prompt =~ "Interactive CE phase menus do not end an autonomous ticket turn"
      assert rework_prompt =~ "planning-to-work transition is authorized"
      assert rework_prompt =~ "Interactive CE phase menus do not end an autonomous ticket turn"
    end

    # Plain control-only resume (aiur restart) vs. a resume-with-continue
    # directive: the `:resumed` path is a pure "you were reattached" nudge and
    # does NOT replay the cold-start ticket contract (the thread already carries
    # it). There is no separate "resume-with-continue" option — the nudge itself
    # must re-authorize the transition so a control-only resume is sufficient to
    # unstick a thread parked at a plan handoff.
    test "plain control-only resume still authorizes the transition (no operator directive needed)", %{issue: issue} do
      prompt = TurnPrompt.build_turn_prompt(issue, [resumed: true], 1, nil)

      assert prompt =~ "session resumed after an aiur restart"

      refute prompt =~ "## Shared Agent Instructions",
             "resumed prompt must not replay the cold-start contract (thread already has it)"

      assert_prompt_authorizes_transition(prompt)
    end

    # The diagnostic's regression ask: turn 1 ends at a plan handoff, and the
    # next autonomous turn must begin work without an operator message. The
    # daemon dispatches turn 2 as an N>1 continuation with no operator input;
    # the fake agent must be able to begin work from that prompt alone.
    test "fake planning-handoff agent begins work on the next autonomous turn without an operator message", %{issue: issue} do
      turn2 = TurnPrompt.build_turn_prompt(issue, [], 2, 12)

      assert FakePlanningHandoffAgent.begin_work?(turn2)
    end

    # Negative coverage — the risk that matters. A regression that removes or
    # inverts the authorization must park the agent at the handoff, not start
    # work on an unfinished plan. This is the "trivially wrong implementation"
    # guard: both prompts below must fail the begin-work decision.
    test "fake planning-handoff agent does not begin work when the contract is absent or negated" do
      stale_prompt = """
      Continuation guidance:

      - Resume from the current workspace state.
      - Focus on the remaining ticket work.
      """

      refute FakePlanningHandoffAgent.begin_work?(stale_prompt)

      negated_prompt = """
      Continuation guidance:

      - If you just completed `ce-plan`, proceed directly to `ce-work` — the planning-to-work transition is NOT authorized on active tickets without an operator message. Await operator direction.
      """

      refute FakePlanningHandoffAgent.begin_work?(negated_prompt)
    end
  end
end
