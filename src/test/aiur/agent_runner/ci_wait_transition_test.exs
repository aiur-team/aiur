defmodule Aiur.AgentRunner.CiWaitTransitionTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Issue

  defmodule DraftCodeHostTracker do
    def code_host, do: __MODULE__
    def fetch_open_pull_request_for_branch(_), do: {:ok, nil}
  end

  test "refuses ci-wait when the ticket has an open draft PR" do
    issue = %Issue{id: "gid-te-state-draft", identifier: "4316"}
    previous_adapters = Application.fetch_env!(:aiur, :tracker_adapters)

    Application.put_env(:aiur, :tracker_adapters, %{"test" => DraftCodeHostTracker, "linear" => DraftCodeHostTracker})
    on_exit(fn -> Application.put_env(:aiur, :tracker_adapters, previous_adapters) end)

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ci_wait_pr_fetcher: fn "gid-te-state-draft" -> {:ok, %{"number" => 4318, "draft" => true}} end,
        ticket_state_writer: fn _id, _state -> flunk("draft PR must not enter ci-wait") end
      )

    response = executor.("aiur_set_ticket_state", %{"state" => "ci-wait"})
    error = Jason.decode!(response["output"])["error"]

    assert response["success"] == false
    assert error["reason"] == "draft_pr_cannot_enter_ci_wait"
    assert error["pull_request"] == 4318
    assert error["message"] =~ "Mark the draft pull request ready"
  end
end
