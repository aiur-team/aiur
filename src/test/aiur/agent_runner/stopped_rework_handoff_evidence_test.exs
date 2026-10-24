defmodule Aiur.AgentRunner.StoppedReworkHandoffEvidenceTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnCompletion
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

  test "no-op bound keeps rework when the blocking review still has findings" do
    identifier = "5746-noop-#{System.unique_integer([:positive])}"
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "rework", labels: ["agent:rework"]}
    head = "d76116f7b7902fd10a52bdb78e0f478000b7951c"

    review = %{
      "state" => "CHANGES_REQUESTED",
      "body" => "1. turn_completion.ex:162 keep the finding open",
      "commit_id" => head,
      "submitted_at" => "2026-10-22T05:46:21Z",
      "id" => 1,
      "user" => %{"login" => "r"},
      authoritative: true
    }

    assert :none =
             TurnLoop.noop_handoff(
               %{
                 workspace: nil,
                 worker_host: nil,
                 opts: [
                   rework_head_sha: head,
                   open_pr_fetcher: fn _ -> {:ok, %{"number" => 5747, "head" => %{"sha" => head}}} end,
                   reviews_fetcher: fn _ -> {:ok, [review]} end
                 ]
               },
               issue
             )

    assert TurnCompletion.noop_failure_state(issue, reviews_fetcher: fn _ -> {:ok, [review]} end) == nil
  end

  # #5746: a run that hit agent.max_turns after fixing one of two findings stays in rework.
  test "a stopped rework run with unanswered review findings is not handed back" do
    identifier = "5746-#{System.unique_integer([:positive])}"
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "rework", labels: ["agent:rework"]}
    review_head = "614fb4151899735ade168468555cef15eddc1919"
    head = "d76116f7b7902fd10a52bdb78e0f478000b7951c"
    review_body = "1. lib/a.ex:3 rename the helper\n2. **Body:** Tested head is stale.\n"

    review = %{
      "state" => "CHANGES_REQUESTED",
      "body" => review_body,
      "commit_id" => review_head,
      "submitted_at" => "2026-10-22T05:46:21Z",
      "id" => 1,
      "user" => %{"login" => "r"},
      :authoritative => true
    }

    opts = fn reviews ->
      [
        rework_head_sha: review_head,
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 5747, "head" => %{"sha" => head}}} end,
        reviews_fetcher: fn _ -> {:ok, reviews} end,
        pull_request_approval_fetcher: fn _ -> {:error, :not_approved} end,
        commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end
      ]
    end

    handoff = fn reviews -> TurnLoop.transition_agent_handoff(%{workspace: nil, worker_host: nil, opts: opts.(reviews)}, issue) end

    assert handoff.([review]) == :none
    refute_received {:memory_tracker_state_update, ^identifier, _state}

    # Control: with no open review the same stopped run is handed back.
    assert {:handoff, _result} = handoff.([])
  end
end
