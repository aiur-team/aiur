defmodule Aiur.AiurExecutorSkillTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  # Every skill that can reach a ticket-creation command. Each states the rule
  # once, in a block located by this marker.
  @creation_rule_marker "same creation request"
  @creation_rule_docs ~w(
    .claude/skills/aiur-agent/conventions.md
    .claude/skills/aiur-run/references/run-contract.md
    .claude/skills/aiur-run/references/executor.md
    .claude/skills/aiur-meta/SKILL.md
    .claude/skills/aiur-build/SKILL.md
  )
  @label_token ~r/^[a-z][a-z0-9-]*(?::[a-z0-9-]+)?$/

  test "Executor guidance gives review subagents per-agent scratchpads and worktree isolation (#2362)" do
    content = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/references/review-and-merge.md"))

    # the class-closing fix: each subagent gets its own scratchpad, mirroring
    # the already-per-agent tasks/<agentId>.output, and sharing is explicit
    assert content =~ "Give every review subagent its own scratchpad"
    assert content =~ "per-agent scratchpad"
    assert content =~ "`tasks/<agentId>.output`"
    assert content =~ "`shared/`"

    # the prompt-level mitigations that are necessary but not sufficient
    assert content =~ "Never persist the worktree path in a file"
    assert content =~ "recompute the path inline per command"
    assert content =~ "Assert the worktree HEAD before every mutation batch"
    assert content =~ "`git -C <wt>\n  rev-parse HEAD`"
    assert content =~ "head-check <wt> <sha>"
    assert content =~ "Forbid mutation testing in the live checkout"
  end

  test "dictation guidance has one source shared by issue workers and Executors" do
    worker_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/SKILL.md"))
    executor_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/SKILL.md"))
    guidance_path = Path.join(@repo_root, ".claude/skills/aiur-agent/dictated-input.md")
    guidance = File.read!(guidance_path)

    assert worker_skill =~ "dictated-input.md"
    assert executor_skill =~ "../aiur-agent/dictated-input.md"
    assert guidance =~ "Voice-originated text may render **Aiur**"
    assert guidance =~ "`A, your`"
    assert guidance =~ "never silently rewriting a real word or acronym"
  end

  # #1793: 29 tickets were filed with no `agent:*` label. Each was
  # undispatchable and invisible in every state-scoped view, so the fleet read
  # as having no work left. Every path that can file a ticket must state a
  # disposition, and the vocabulary it teaches has to be the vocabulary the
  # `gh` guard actually honours — a doc naming a label the guard refuses would
  # send agents into a wall, and a guard that stopped enforcing would leave the
  # docs describing a rule nothing applies.
  test "every filing path teaches a disposition the gh guard actually accepts" do
    documented =
      for path <- @creation_rule_docs, reduce: MapSet.new() do
        found ->
          per_doc =
            for block <- creation_rule_blocks(path), reduce: MapSet.new() do
              seen ->
                labels = documented_labels(block)

                # A creation rule that names no label is prose with no
                # vocabulary — the agent is told when, never what.
                assert MapSet.size(labels) > 0,
                       "#{path} states the creation rule without naming any label: #{block}"

                MapSet.union(seen, labels)
            end

          assert MapSet.member?(per_doc, "agent:todo"),
                 "#{path} never names `agent:todo` where it states the creation rule"

          MapSet.union(found, per_doc)
      end

    # Every label the skills teach must survive the guard, or following the
    # documented instruction fails.
    for label <- documented do
      assert run_creation_guard(["--title", "t", "--label", label]) == 0,
             "the gh guard refuses documented disposition #{label}"
    end

    # And the guard must actually be enforcing, not passing everything through.
    assert run_creation_guard(["--title", "t"]) != 0,
           "the gh guard admits an issue create with no disposition at all"

    assert run_creation_guard(["--title", "t", "--label", "wontfix"]) != 0,
           "the gh guard admits an issue create whose labels carry no disposition"

    assert MapSet.subset?(MapSet.new(~w(agent:todo needs-triage human:todo build-order)), documented),
           "the documented disposition vocabulary lost a case: #{inspect(MapSet.to_list(documented))}"
  end

  test "aiur run and status skill descriptions cover iarc and aiur triggers" do
    run_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/SKILL.md"))
    status_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md"))

    assert String.contains?(run_skill, "run IAR")
    assert String.contains?(run_skill, "run aiur")
    assert String.contains?(run_skill, "iarc run")
    assert String.contains?(status_skill, "iarc status")
    assert String.contains?(status_skill, "aiur status")
    assert String.contains?(status_skill, "aiurdev watch")

    for skill <- [run_skill, status_skill] do
      assert String.contains?(skill, "iarc")
      assert String.contains?(skill, "alias for `aiur`")
    end
  end

  test "Executor wake guidance separates notification, consumption, and recovery" do
    run_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/SKILL.md"))

    assert run_skill =~ "executor/<repo>.executor.wakes.ndjson"
    assert run_skill =~ "sanitized final\nsegment of the tracker project identity"
    assert run_skill =~ "`Paths.repo_name/0`"
    assert run_skill =~ "khala.executor.wakes.ndjson"
    assert run_skill =~ "wake monitor not armed: expected wake stream is absent"
    refute run_skill =~ "executor/aiur.executor.wakes.ndjson"
    assert run_skill =~ "The tail is notification-only"
    assert run_skill =~ "does **not** advance the durable cursor"
    assert run_skill =~ "cannot substitute for `executor-wait`"
    assert run_skill =~ "WAKES CURSOR <id>\nPENDING <count>"
    monitoring = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/references/monitoring.md"))

    assert monitoring =~ "executor-fast-forward <wake-id>"
    assert monitoring =~ "Never use it merely because the backlog is large"
  end

  test "Executor decision relay covers backend push, RC, and the Decisions log" do
    monitor_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md"))
    relay = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/references/alerts-and-decisions.md"))

    monitor_skill = one_line(monitor_skill)
    relay = one_line(relay)

    assert monitor_skill =~ "alerts-and-decisions.md"
    assert relay =~ "operator_decision:true"
    assert relay =~ "Decisions entry"
    assert relay =~ "Claude native push"
    assert relay =~ "Codex device notification"
    assert relay =~ "Remote Control"
    assert relay =~ "retry them on a later re-ask"
    assert relay =~ "matching resolution"
  end

  test "Executor protects a finite feature boundary" do
    monitor_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md"))
    executor = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/references/executor.md"))

    monitor_skill = one_line(monitor_skill)
    executor = one_line(executor)

    assert executor =~ "Protect convergence"
    assert executor =~ "Contained rework"
    assert executor =~ "P2/P3 non-blocker"
    assert executor =~ "creation exceeds completion"
    assert executor =~ "freeze new ticket creation"
    assert executor =~ "deferred findings ledger"
    driving = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/references/driving.md")) |> one_line()
    assert driving =~ "prefer contained rework"
    assert monitor_skill =~ "completed versus created/promoted tickets"
  end

  test "needs-attention relay is an independent wake path for the Executor cadence" do
    monitor_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md"))
    run_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/references/command-decisions.md"))
    relay = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/references/alerts-and-decisions.md"))

    monitor_skill = one_line(monitor_skill)
    run_skill = one_line(run_skill)
    relay = one_line(relay)

    assert monitor_skill =~ "streams new local-workspace alert records"
    assert monitor_skill =~ "workspace-less alerts remain visible"
    assert run_skill =~ "timer and alert path are additive"
    assert relay =~ "real-time wake path"
    assert relay =~ "does not replace the recurring status cadence"
  end

  # The rule block, not the whole file: a doc that merely mentions `agent:todo`
  # somewhere else must not satisfy the assertion. A paragraph that ends in a
  # colon carries its list with it.
  defp creation_rule_blocks(relative_path) do
    paragraphs =
      @repo_root
      |> Path.join(relative_path)
      |> File.read!()
      |> String.split(~r/\n[ \t]*\n/)
      |> Enum.map(&(&1 |> one_line() |> String.trim()))

    blocks =
      paragraphs
      |> Enum.with_index()
      |> Enum.filter(fn {text, _index} -> String.contains?(text, @creation_rule_marker) end)
      |> Enum.map(fn {text, index} ->
        # A paragraph that ends in a colon carries its list with it.
        if String.ends_with?(text, ":") do
          text <> " " <> Enum.at(paragraphs, index + 1, "")
        else
          text
        end
      end)

    assert blocks != [], "#{relative_path} no longer states the ticket-creation rule"

    blocks
  end

  defp documented_labels(block) do
    ~r/`([^`]+)`/
    |> Regex.scan(block)
    |> Enum.map(fn [_, token] -> token end)
    |> Enum.filter(&Regex.match?(@label_token, &1))
    |> MapSet.new()
  end

  # Runs the real wrapper the daemon installs on agent PATH, against a stub
  # `gh`, so this asserts the shipped guard rather than a copy of its rules.
  defp run_creation_guard(arguments) do
    root = Aiur.TestSupport.tmp_root!("aiur-skill-guard")
    File.mkdir_p!(root)
    stub = Path.join(root, "gh")
    File.write!(stub, "#!/bin/sh\nexit 0\n")
    File.chmod!(stub, 0o755)

    try do
      {_output, status} =
        System.cmd(
          "/bin/sh",
          [Aiur.AgentGitHubGuardTestSupport.write_gh_guard(root), "issue", "create" | arguments],
          # This test asserts the dispatch disposition enforcement in
          # isolation. The shared GitHub budget broker lives beside the
          # installed wrapper, not beside the copy this test writes, so
          # disable it explicitly or the admission check exits 75 whenever the
          # broker is absent (CI has no broker in `src/priv`).
          env: [
            {"AIUR_REAL_GH", stub},
            {"AIUR_REPO_STATE_PATH", Path.join(root, "state")},
            {"AIUR_GITHUB_BUDGET_ENABLED", "0"}
          ],
          stderr_to_stdout: true
        )

      status
    after
      File.rm_rf!(root)
    end
  end

  defp one_line(text), do: String.replace(text, ~r/\s+/, " ")
end
