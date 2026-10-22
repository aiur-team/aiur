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
    test "review and CI handoffs do not receive routine base-merge instructions" do
      for state <- ["human-review", "ci-wait"] do
        prompt = TurnPrompt.build_turn_prompt(%Issue{id: "5237", identifier: "5237", title: "Review handoff", state: state}, [], 1, nil)

        normalized = String.replace(prompt, ~r/\s+/, " ")
        assert normalized =~ "do not merge or rebase `$AIUR_BASE_BRANCH`"
        assert normalized =~ "only when GitHub reports the PR `CONFLICTING`"
        assert normalized =~ "In `rework`, follow the reviewer’s request"
      end
    end

    test "turn one prior_work recycle gets continuation guidance plus the ticket contract" do
      issue = %Issue{id: "1091", identifier: "1091", title: "Fetch graph", state: "in-progress"}

      prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true], 1, nil)

      assert prompt =~ "Agent Workpad"
      assert prompt =~ "do not restart the ticket from scratch"
      # keeps the full operating contract so a cold thread still knows the ticket
      assert prompt =~ issue.title
      refute prompt == PromptBuilder.build_prompt(issue, prior_work: true)
      refute prompt =~ "previous agent thread was abandoned"
    end

    test "a fresh session that replaced an abandoned thread says so" do
      issue = %Issue{id: "4561", identifier: "4561", title: "Big thread", state: "in-progress"}

      prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, abandoned_thread: true], 1, nil)

      assert prompt =~ "do not restart the ticket from scratch"
      assert prompt =~ "previous agent thread was abandoned after it repeatedly lost its transport"
    end

    test "dirty prior-work workspace includes status and last agent message" do
      workspace = temp_git_workspace!("stopped-dirty")
      File.write!(Path.join(workspace, "unfinished.ex"), "unfinished work\n")
      File.mkdir_p!(Path.join(workspace, "logs"))

      write_agent_events!(workspace, [
        %{event: "agent_message", last_message: "Older legacy message."},
        codex_completed_message("I found the broker race; fixing the retry path.")
      ])

      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

      issue = %Issue{id: "5561", identifier: "5561", title: "Resume work", state: "in-progress"}
      prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, workspace: workspace], 1, nil)

      assert prompt =~ "## Resuming from a stopped session"
      assert prompt =~ "continue from this work rather than restarting the ticket"
      assert prompt =~ "?? unfinished.ex"
      assert prompt =~ "I found the broker race; fixing the retry path."

      rework_issue = %{issue | state: "rework"}
      assert TurnPrompt.build_turn_prompt(rework_issue, [workspace: workspace], 1, nil) =~ "## Resuming from a stopped session"
    end

    test "dirty workspace includes an incomplete Codex message accumulated from deltas" do
      workspace = temp_git_workspace!("stopped-delta")
      File.write!(Path.join(workspace, "unfinished.ex"), "unfinished work\n")
      File.mkdir_p!(Path.join(workspace, "logs"))
      write_agent_events!(workspace, [codex_delta("partial "), codex_delta("assistant answer")])
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

      issue = %Issue{id: "5561", identifier: "5561", title: "Resume work", state: "in-progress"}
      prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, workspace: workspace], 1, nil)

      assert prompt =~ "partial assistant answer"
    end

    test "dirty workspace includes a legacy agent message and skips already resumed threads" do
      workspace = temp_git_workspace!("stopped-legacy")
      File.write!(Path.join(workspace, "unfinished.ex"), "unfinished work\n")
      File.mkdir_p!(Path.join(workspace, "logs"))
      write_agent_events!(workspace, [%{event: "agent_message", last_message: "Legacy session was checking the retry path."}])
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

      issue = %Issue{id: "5561", identifier: "5561", title: "Resume work", state: "in-progress"}
      prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, workspace: workspace], 1, nil)
      resumed_prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, resumed: true, workspace: workspace], 1, nil)

      assert prompt =~ "Legacy session was checking the retry path."
      refute resumed_prompt =~ "## Resuming from a stopped session"
    end

    test "dirty workspace includes the last Claude transcript message" do
      workspace = temp_git_workspace!("stopped-claude")
      File.write!(Path.join(workspace, "unfinished.ex"), "unfinished work\n")
      File.mkdir_p!(Path.join(workspace, "logs"))

      write_agent_events!(workspace, [
        %{event: :transcript, transcript_event: %{role: :assistant, body: "Claude was tracing the broker retry."}}
      ])

      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

      issue = %Issue{id: "5561", identifier: "5561", title: "Resume work", state: "in-progress"}
      prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, workspace: workspace], 1, nil)

      assert prompt =~ "Claude was tracing the broker retry."
    end

    test "dirty workspace keeps only the tail of a long last agent message" do
      workspace = temp_git_workspace!("stopped-long")
      File.write!(Path.join(workspace, "unfinished.ex"), "unfinished work\n")
      File.mkdir_p!(Path.join(workspace, "logs"))
      write_agent_events!(workspace, [%{event: "agent_message", last_message: String.duplicate("a", 3_000) <> "END"}])
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

      issue = %Issue{id: "5561", identifier: "5561", title: "Resume work", state: "in-progress"}
      prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, workspace: workspace], 1, nil)

      assert prompt =~ "Ticket 5561: " <> String.duplicate("a", 1_997) <> "END"
      refute prompt =~ String.duplicate("a", 1_998)
    end

    test "clean prior-work workspace does not include stopped-session guidance" do
      workspace = temp_git_workspace!("stopped-clean")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

      issue = %Issue{id: "5561", identifier: "5561", title: "Resume work", state: "in-progress"}
      prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, workspace: workspace], 1, nil)

      refute prompt =~ "## Resuming from a stopped session"
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

    test "turn prompts name files left by an aborted before_run base merge" do
      workspace = Path.join(System.tmp_dir!(), "turn-prompt-conflict-#{System.unique_integer([:positive])}")
      conflict_note = Path.join([workspace, "logs", "before-run-merge-conflict.md"])
      File.mkdir_p!(Path.dirname(conflict_note))

      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

      File.write!(conflict_note, """
      # Base branch merge conflict

      The preflight merge was aborted.

      ## Conflicting files
      - src/example.ex
      - test/example_test.exs
      """)

      issue = %Issue{id: "3011", identifier: "3011", title: "Resolve base conflict"}
      resumed_prompt = TurnPrompt.build_turn_prompt(issue, [resumed: true, workspace: workspace], 1, nil)
      cold_prompt = TurnPrompt.build_turn_prompt(issue, [workspace: workspace], 1, nil)
      prior_work_prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, workspace: workspace], 1, nil)
      next_turn_prompt = TurnPrompt.build_turn_prompt(issue, [workspace: workspace], 2, nil)

      for prompt <- [resumed_prompt, cold_prompt, prior_work_prompt] do
        assert prompt =~ "Merge `origin/$AIUR_BASE_BRANCH` and resolve these files"
        assert prompt =~ "- `src/example.ex`"
        assert prompt =~ "- `test/example_test.exs`"
      end

      refute next_turn_prompt =~ "Merge `origin/$AIUR_BASE_BRANCH` and resolve these files"
      refute next_turn_prompt =~ "src/example.ex"

      refute resumed_prompt =~ workspace
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
      assert prompt =~ "latest Executor rework comment on the ticket"
      assert prompt =~ "failing required checks"
      assert prompt =~ "even when the PR is approved"
      assert prompt =~ "## Shared Agent Instructions"
      assert prompt =~ issue.title
      assert prompt =~ issue.description
      assert prompt =~ "generic cold-start phase order"
      refute prompt == PromptBuilder.build_prompt(issue, [])
    end

    test "turn one cold rework lists the latest review's findings as the handback checklist" do
      issue = %Issue{id: "4654", identifier: "4654", title: "Checklist", state: "rework"}
      body = "Request changes.\n\n1. lib/a.ex:44 drop the nil key\n2. No location here.\n"

      opts = [
        open_pr_fetcher: fn "4654" -> {:ok, %{"number" => 7}} end,
        reviews_fetcher: fn 7 -> {:ok, [%{"state" => "CHANGES_REQUESTED", "body" => body, "submitted_at" => "t", "id" => 1, "user" => %{"login" => "r"}, authoritative: true}]} end
      ]

      prompt = TurnPrompt.build_turn_prompt(issue, opts, 1, nil)

      assert prompt =~ "Review findings checklist"
      assert prompt =~ "- 1. `lib/a.ex:44` — lib/a.ex:44 drop the nil key"
      refute prompt =~ "- 2."
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

    test "in-process continuation restates the rename test-tree audit" do
      prompt = TurnPrompt.build_turn_prompt(%Issue{}, [], 2, nil)

      assert prompt =~ "## Rename and signature-change test audit (restated)"
      assert prompt =~ "rg -n --fixed-strings -- '<old-name>' src/test/"
      assert prompt =~ "test/aiur/github/` does not collect `test/aiur/github_client_test.exs"
    end

    test "resumed-session prompt restates the rename test-tree audit" do
      prompt = TurnPrompt.build_turn_prompt(%Issue{}, [resumed: true], 1, nil)

      assert prompt =~ "## Rename and signature-change test audit (restated)"
      assert prompt =~ "rg -n --fixed-strings -- '<old-name>' src/test/"
      assert prompt =~ "test/aiur/github/` does not collect `test/aiur/github_client_test.exs"
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

  defp temp_git_workspace!(prefix) do
    workspace = Path.join(System.tmp_dir!(), "turn-prompt-#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
    {_, 0} = System.cmd("git", ["-C", workspace, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial", "--quiet"])

    workspace
  end

  defp write_agent_events!(workspace, events) do
    content = Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    File.write!(Path.join(workspace, "logs/agent.ndjson"), content)
  end

  defp codex_completed_message(text) do
    %{
      event: "notification",
      payload: %{method: "item/completed", params: %{item: %{type: "agentMessage", text: text}}}
    }
  end

  defp codex_delta(delta) do
    %{
      event: "notification",
      payload: %{method: "item/agentMessage/delta", params: %{itemId: "message-1", delta: delta}}
    }
  end
end
