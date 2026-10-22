defmodule Aiur.AgentRunner.ReworkHandoffGuardTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.ReworkHandoffGuard
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Issue

  test "same-head rework hand-back with failed required checks returns an error and does not write" do
    issue = %Issue{id: "gid-rework", identifier: "4180", state: "rework"}
    test_pid = self()

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        rework_head_sha: "same-head",
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ticket_state_writer: fn _issue_id, _state ->
          send(test_pid, :unexpected_write)
          :ok
        end,
        open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "same-head"}}} end,
        reviews_fetcher: fn _ -> {:ok, []} end,
        pr_issue_comments_fetcher: fn _ -> {:ok, []} end,
        required_checks_fetcher: fn _ ->
          send(test_pid, :required_checks_read)
          {:ok, [%{name: "lint", app_id: nil}]}
        end,
        commit_ci_status_fetcher: fn _ ->
          {:ok, %{check_runs: [%{"id" => 1, "name" => "lint", "status" => "completed", "conclusion" => "failure"}], commit_status: %{}}}
        end,
        no_op_rework_alert: fn issue_arg, checks, message -> send(test_pid, {:attention, issue_arg.identifier, checks, message}) end
      )

    response = executor.("aiur_set_ticket_state", %{"state" => "human-review"})

    assert_receive :required_checks_read, 100
    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "lint"
    assert_receive {:attention, "4180", ["lint"], message}, 100
    assert message =~ "latest rework comment"
    refute_received :unexpected_write
  end

  test "same-head rework hand-back with green required checks writes human-review despite a non-blocking failure" do
    issue = %Issue{id: "gid-rework-green", identifier: "4180", state: "rework"}
    test_pid = self()

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        rework_head_sha: "same-head",
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ticket_state_writer: fn issue_id, state ->
          send(test_pid, {:state_write, issue_id, state})
          :ok
        end,
        open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "same-head"}}} end,
        reviews_fetcher: fn _ -> {:ok, []} end,
        pr_issue_comments_fetcher: fn _ -> {:ok, []} end,
        required_checks_fetcher: fn _ ->
          send(test_pid, :required_checks_read)
          {:ok, [%{name: "lint", app_id: nil}]}
        end,
        commit_ci_status_fetcher: fn _ ->
          {:ok,
           %{
             check_runs: [
               %{"id" => 1, "name" => "lint", "status" => "completed", "conclusion" => "success"},
               %{"id" => 2, "name" => "quarantined tests (non-blocking)", "status" => "completed", "conclusion" => "failure"}
             ],
             commit_status: %{}
           }}
        end,
        no_op_rework_alert: fn _issue, _checks, _message -> send(test_pid, :unexpected_alert) end
      )

    response = executor.("aiur_set_ticket_state", %{"state" => "human-review"})

    assert_receive :required_checks_read, 100
    assert response["success"]
    assert_receive {:state_write, "gid-rework-green", "human-review"}, 100
    refute_received :unexpected_alert
  end

  test "rework hand-back writes human-review when required checks failed on the old dispatch head" do
    issue = %Issue{id: "gid-rework-moved", identifier: "4180", state: "rework"}
    test_pid = self()

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        rework_head_sha: "old",
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ticket_state_writer: fn issue_id, state ->
          send(test_pid, {:state_write, issue_id, state})
          :ok
        end,
        open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "new"}}} end,
        reviews_fetcher: fn _ -> {:ok, []} end,
        pr_issue_comments_fetcher: fn _ -> {:ok, []} end,
        required_checks_fetcher: fn _ -> {:ok, [%{name: "lint", app_id: nil}]} end,
        commit_ci_status_fetcher: fn "old" ->
          {:ok,
           %{
             check_runs: [%{"id" => 1, "name" => "lint", "status" => "completed", "conclusion" => "failure"}],
             commit_status: %{}
           }}
        end,
        no_op_rework_alert: fn _issue, _checks, _message -> send(test_pid, :unexpected_alert) end
      )

    response = executor.("aiur_set_ticket_state", %{"state" => "human-review"})

    assert response["success"]
    assert_receive {:state_write, "gid-rework-moved", "human-review"}, 100
    refute_received :unexpected_alert
  end

  test "ci-wait and human-review handoffs fail until the PR body names the live head" do
    head = String.duplicate("c", 40)
    base = String.duplicate("d", 40)
    issue = %Issue{id: "gid-evidence", identifier: "4611", state: "in-progress"}
    test_pid = self()

    # The body still holds a placeholder head; the handback must not rewrite that test claim.
    stale = "## Local tests\n\nPolicy: partial\nTested head: #{String.duplicate("a", 40)}\nBase: main @ #{base}\nSelection: focused\n- `mix test` -> pass\n"
    fresh = String.replace(stale, "Tested head: " <> String.duplicate("a", 40), "Tested head: " <> head)

    executor = fn body ->
      ToolExecutor.build(issue, nil, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ticket_state_writer: fn issue_id, state ->
          send(test_pid, {:state_write, issue_id, state})
          :ok
        end,
        open_pr_fetcher: fn "4611" -> {:ok, %{"number" => 4622, "body" => body, "head" => %{"sha" => head}}} end
      )
    end

    for state <- ["ci-wait", "human-review"] do
      response = executor.(stale).("aiur_set_ticket_state", %{"state" => state})
      refute response["success"]
      error = Jason.decode!(response["output"])["error"]
      assert error["reason"] == "stale_pr_body_evidence"
      assert error["message"] =~ "Tested head #{String.duplicate("a", 40)}"
      assert error["message"] =~ "PR head #{head}"
      assert error["message"] =~ "Rerun the touched tests"
      refute error["message"] =~ "aiur pre-pr"
      refute_received {:state_write, _, _}
    end

    backticked = String.replace(fresh, "Tested head: " <> head, "Tested head: `#{head}`")
    refute executor.(backticked).("aiur_set_ticket_state", %{"state" => "ci-wait"})["success"]

    assert executor.(fresh).("aiur_set_ticket_state", %{"state" => "ci-wait"})["success"]
    assert_receive {:state_write, "gid-evidence", "ci-wait"}, 100
  end

  @tag :tmp_dir
  test "stale body evidence is accepted only when intervening commits merge the base", %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    git_bin = Path.join(tmp_dir, "git")
    File.write!(git_bin, "#!/bin/sh\nexec /usr/bin/git \"$@\"\n")
    File.chmod!(git_bin, 0o755)
    File.mkdir_p!(repo)
    git!(git_bin, repo, ["init", "--quiet", "-b", "main"])
    git!(git_bin, repo, ["config", "user.name", "Test"])
    git!(git_bin, repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "base.txt"), "base 1\n")
    git!(git_bin, repo, ["add", "."])
    git!(git_bin, repo, ["commit", "--quiet", "-m", "base one"])

    git!(git_bin, repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "feature.txt"), "feature\n")
    git!(git_bin, repo, ["add", "."])
    git!(git_bin, repo, ["commit", "--quiet", "-m", "feature"])
    tested_head = git!(git_bin, repo, ["rev-parse", "HEAD"])

    git!(git_bin, repo, ["checkout", "main"])
    File.write!(Path.join(repo, "base.txt"), "base 2\n")
    git!(git_bin, repo, ["commit", "--quiet", "-am", "base two"])
    base_head = git!(git_bin, repo, ["rev-parse", "HEAD"])

    git!(git_bin, repo, ["checkout", "feature"])
    git!(git_bin, repo, ["merge", "--quiet", "--no-ff", "main", "-m", "merge base"])
    merged_head = git!(git_bin, repo, ["rev-parse", "HEAD"])
    body = "## Local tests\n\nPolicy: partial\nTested head: #{tested_head}\nBase: main @ #{base_head}\nSelection: focused\n- `mix test` -> pass\n"
    issue = %Issue{id: "gid-merge-evidence", identifier: "5408", state: "in-progress"}

    opts = [
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 5408, "body" => body, "head" => %{"sha" => merged_head}, "base" => %{"sha" => base_head}}} end,
      approval_carry_classifier: fn ^tested_head, ^merged_head, 5408, _opts -> :identical end
    ]

    assert :allow = ReworkHandoffGuard.evidence_blockers(issue, "ci-wait", repo, opts)

    File.write!(Path.join(repo, "feature.txt"), "feature changed\n")
    git!(git_bin, repo, ["commit", "--quiet", "-am", "feature follow-up"])
    changed_head = git!(git_bin, repo, ["rev-parse", "HEAD"])

    opts = [
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 5408, "body" => body, "head" => %{"sha" => changed_head}, "base" => %{"sha" => base_head}}} end,
      approval_carry_classifier: fn ^tested_head, ^changed_head, 5408, _opts -> {:changed, %{reason: :contribution_changed, hunks: []}} end
    ]

    assert {:refused, :stale_pr_body_evidence, message} =
             ReworkHandoffGuard.evidence_blockers(issue, "ci-wait", repo, opts)

    assert message =~ "does not match PR head #{changed_head}"

    git!(git_bin, repo, ["checkout", "main"])
    File.write!(Path.join(repo, "feature.txt"), "base edit\n")
    git!(git_bin, repo, ["add", "feature.txt"])
    git!(git_bin, repo, ["commit", "--quiet", "-m", "base conflicts with contribution"])
    new_base_head = git!(git_bin, repo, ["rev-parse", "HEAD"])
    git!(git_bin, repo, ["checkout", "feature"])
    {_, 1} = System.cmd(git_bin, ["-C", repo, "merge", "--no-ff", "main", "-m", "merge with conflict"], stderr_to_stdout: true)
    File.write!(Path.join(repo, "feature.txt"), "resolved contribution\n")
    git!(git_bin, repo, ["add", "feature.txt"])
    git!(git_bin, repo, ["commit", "--quiet", "-m", "resolve contribution conflict"])
    conflict_merge_head = git!(git_bin, repo, ["rev-parse", "HEAD"])

    conflict_opts = [
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 5408, "body" => body, "head" => %{"sha" => conflict_merge_head}, "base" => %{"sha" => new_base_head}}} end,
      approval_carry_classifier: fn ^tested_head, ^conflict_merge_head, 5408, _opts -> {:changed, %{reason: :contribution_changed, hunks: []}} end
    ]

    assert {:refused, :stale_pr_body_evidence, conflict_message} =
             ReworkHandoffGuard.evidence_blockers(issue, "ci-wait", repo, conflict_opts)

    assert conflict_message =~ "does not match PR head #{conflict_merge_head}"
  end

  @tag :tmp_dir
  test "a code commit after Tested head cannot use the base-advance exception", %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    git_bin = Path.join(tmp_dir, "git")
    File.write!(git_bin, "#!/bin/sh\nexec /usr/bin/git \"$@\"\n")
    File.chmod!(git_bin, 0o755)
    File.mkdir_p!(repo)
    git!(git_bin, repo, ["init", "--quiet", "-b", "main"])
    git!(git_bin, repo, ["config", "user.name", "Test"])
    git!(git_bin, repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "base.txt"), "base\n")
    git!(git_bin, repo, ["add", "."])
    git!(git_bin, repo, ["commit", "--quiet", "-m", "base"])
    git!(git_bin, repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "feature.txt"), "contribution\n")
    git!(git_bin, repo, ["add", "."])
    git!(git_bin, repo, ["commit", "--quiet", "-m", "contribution"])
    tested_head = git!(git_bin, repo, ["rev-parse", "HEAD"])

    git!(git_bin, repo, ["checkout", "main"])
    File.write!(Path.join(repo, "base.txt"), "base advanced\n")
    git!(git_bin, repo, ["commit", "--quiet", "-am", "advance base"])
    base_head = git!(git_bin, repo, ["rev-parse", "HEAD"])
    git!(git_bin, repo, ["checkout", "feature"])
    git!(git_bin, repo, ["merge", "--quiet", "--no-ff", "main", "-m", "merge base"])
    File.write!(Path.join(repo, "coverage.txt"), "preserve coverage\n")
    git!(git_bin, repo, ["add", "."])
    git!(git_bin, repo, ["commit", "--quiet", "-m", "preserve coverage"])
    head = git!(git_bin, repo, ["rev-parse", "HEAD"])
    body = "## Local tests\n\nPolicy: partial\nTested head: #{tested_head}\nBase: main @ #{base_head}\nSelection: focused\n- `mix test` -> passed\n"
    issue = %Issue{id: "gid-stale-code-commit", identifier: "5496", state: "in-progress"}

    opts = [
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 5525, "body" => body, "head" => %{"sha" => head}, "base" => %{"sha" => base_head}}} end,
      approval_carry_classifier: fn ^tested_head, ^head, 5525, _opts -> :identical end
    ]

    assert {:refused, :stale_pr_body_evidence, message} =
             ReworkHandoffGuard.evidence_blockers(issue, "human-review", repo, opts)

    assert message =~ "Tested head #{tested_head} does not match PR head #{head}"
  end

  @tag :tmp_dir
  test "with the worker's checkout, handoffs run the full PR body check against the live head", %{tmp_dir: workspace} do
    head = String.duplicate("c", 40)
    issue = %Issue{id: "gid-body", identifier: "4937", state: "in-progress"}
    test_pid = self()

    File.mkdir_p!(Path.join(workspace, ".github"))
    File.write!(Path.join(workspace, ".github/pull_request_template.md"), "#### Summary\n\n- <!-- what changed -->\n\n## Local tests\n\nPolicy: <!-- mode -->\n")

    evidence = fn tested ->
      "## Local tests\n\nPolicy: partial\nTested head: #{tested}\nBase: main @ #{String.duplicate("d", 40)}\nSelection: focused\n- `mix test` -> pass\n"
    end

    handoff = fn body ->
      ToolExecutor.build(issue, workspace, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ticket_state_writer: fn issue_id, state ->
          send(test_pid, {:state_write, issue_id, state})
          :ok
        end,
        pull_request_fetcher: fn 4937 -> {:ok, %{"mergeable_state" => "clean"}} end,
        open_pr_fetcher: fn "4937" -> {:ok, %{"number" => 4937, "body" => body, "head" => %{"sha" => head}}} end
      ).("aiur_set_ticket_state", %{"state" => "human-review"})
    end

    # Evidence alone names the live head, but CI's body check also requires the template's headings.
    response = handoff.(evidence.(head))
    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["message"] =~ "Missing required heading: #### Summary"

    stale = handoff.("#### Summary\n\n- Fix.\n\n" <> evidence.(String.duplicate("a", 40)))
    refute stale["success"]
    message = Jason.decode!(stale["output"])["error"]["message"]
    assert message =~ "Tested head #{String.duplicate("a", 40)}"
    assert message =~ "PR head #{head}"
    assert message =~ "Rerun the touched tests"
    refute message =~ "aiur pre-pr"
    refute_received {:state_write, _, _}

    assert handoff.("#### Summary\n\n- Fix.\n\n" <> evidence.(head))["success"]
    assert_receive {:state_write, "gid-body", "human-review"}, 100
  end

  defp git!(git_bin, repo, args) do
    {output, 0} = System.cmd(git_bin, ["-C", repo | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
