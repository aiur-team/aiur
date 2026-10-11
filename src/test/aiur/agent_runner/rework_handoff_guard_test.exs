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
end
