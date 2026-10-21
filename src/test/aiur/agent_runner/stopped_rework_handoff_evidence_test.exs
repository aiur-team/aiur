defmodule Aiur.AgentRunner.StoppedReworkHandoffEvidenceTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnLoop

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Aiur.WorkflowStore.force_reload()
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    :ok
  end

  test "stopped rework handoffs refuse a stale Tested head before writing the label" do
    identifier = "5525-#{System.unique_integer([:positive])}"
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "rework", labels: ["agent:rework"]}
    tested_head = "614fb4151899735ade168468555cef15eddc1919"
    head = "d76116f7b7902fd10a52bdb78e0f478000b7951c"

    body =
      "## Local tests\n\nPolicy: partial\nTested head: #{tested_head}\nBase: main @ 798b1ea88a050cef569a183375193b0fa1bff1a5\n" <>
        "Selection: focused\n- `mix test` -> passed\n"

    result =
      TurnLoop.transition_agent_handoff(
        %{
          workspace: nil,
          worker_host: nil,
          opts: [
            rework_head_sha: tested_head,
            open_pr_fetcher: fn _ -> {:ok, %{"number" => 5525, "body" => body, "head" => %{"sha" => head}}} end,
            reviews_fetcher: fn _ -> {:ok, []} end,
            pull_request_approval_fetcher: fn _ -> {:error, :not_approved} end,
            commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end
          ]
        },
        issue
      )

    assert {:error, {:rework_handoff_evidence_refused, :stale_pr_body_evidence, message}} = result
    assert message =~ "Tested head #{tested_head} does not match PR head #{head}"
    refute_received {:memory_tracker_state_update, ^identifier, "human-review"}
  end
end
