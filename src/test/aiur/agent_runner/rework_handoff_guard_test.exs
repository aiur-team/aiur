defmodule Aiur.AgentRunner.ReworkHandoffGuardTest do
  use ExUnit.Case, async: true

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

    # The first `aiur pre-pr` ran before `gh pr create`, so the body still holds a placeholder head.
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
      assert error["message"] =~ "Run `aiur pre-pr` again after `gh pr create`"
      refute_received {:state_write, _, _}
    end

    backticked = String.replace(fresh, "Tested head: " <> head, "Tested head: `#{head}`")
    refute executor.(backticked).("aiur_set_ticket_state", %{"state" => "ci-wait"})["success"]

    assert executor.(fresh).("aiur_set_ticket_state", %{"state" => "ci-wait"})["success"]
    assert_receive {:state_write, "gid-evidence", "ci-wait"}, 100
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
    assert Jason.decode!(stale["output"])["error"]["message"] =~ "Tested head does not match PR head"
    refute_received {:state_write, _, _}

    assert handoff.("#### Summary\n\n- Fix.\n\n" <> evidence.(head))["success"]
    assert_receive {:state_write, "gid-body", "human-review"}, 100
  end
end
