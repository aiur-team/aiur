defmodule Aiur.Orchestrator.CommentRefusalAlertTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, AlertFeed, Issue}
  alias Aiur.Orchestrator.{CommentWake, PrAnchored, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      pr_watch_enabled: true
    )

    :ok
  end

  defp alerts, do: AlertFeed.list()

  defp state do
    %State{running: %{}, claimed: MapSet.new(), completed: MapSet.new()}
  end

  defp comment_event(issue, extra \\ %{}) do
    Map.merge(
      %{
        author_trusted?: true,
        issue_state_fetcher: fn _ids -> {:ok, [issue]} end
      },
      extra
    )
  end

  defp active_running_state(number) do
    issue = %Issue{id: number, identifier: number, state: "human-review", labels: ["agent:human-review"]}
    entry = %{identifier: number, issue: issue}
    %{state() | running: %{number => entry}}
  end

  defp active_review_event(state, number, review_state) do
    %{
      author_trusted?: true,
      comment: %{"state" => review_state, "body" => "please fix"},
      open_pr_fetcher: fn _issue_key -> {:ok, nil} end
    }
    |> then(fn event -> {state, number, event} end)
  end

  defp reactivation_state(number) do
    issue = %Issue{id: number, identifier: number, state: "human-review", labels: ["agent:human-review"]}
    entry = %{identifier: number, issue: issue, control: %{status: :deactivated}}
    %{state() | running: %{number => entry}}
  end

  defp open_pr_event(issue, extra) do
    Map.merge(
      comment_event(issue, %{
        open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "head-1"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, [%{"isResolved" => false}]} end
      }),
      extra
    )
  end

  test "parked issue refusal is durable and gives the parking remedy" do
    issue = %Issue{id: "r1", identifier: "r1", state: "todo", labels: ["agent:todo", "agent:parked"], parked: true}

    CommentWake.maybe_transition_idle_issue_to_rework(state(), "r1", :pr_comment, comment_event(issue), 1)

    assert [alert] = Enum.filter(alerts(), &(&1["topic"] == "ticket.r1.agent.attention.comment_wake_idle_issue"))
    assert alert["reason"] =~ "unpark the issue"
  end

  test "not-yet-attempted comment is preserved for dispatch without an alert" do
    issue = %Issue{id: "r2", identifier: "r2", state: "todo", labels: ["agent:todo"]}
    event = Map.put(comment_event(issue), :id, 22)

    result =
      CommentWake.maybe_transition_idle_issue_to_rework(
        %{state() | queue_store: AgentQueueStore.new(), last_polled_issues: %{"r2" => issue}},
        "r2",
        :pr_comment,
        event,
        1
      )

    assert result.queue_store.items != %{}
    refute Enum.any?(alerts(), &(&1["topic"] == "ticket.r2.agent.attention.comment_wake_idle_issue"))
    refute Enum.any?(alerts(), &(&1["topic"] == "ticket.r2.agent.attention.comment_wake_dispatch_declined"))
  end

  test "issue state resolution failure is durable and points to tracker access" do
    event = %{
      author_trusted?: true,
      issue_state_fetcher: fn _ids -> {:error, :offline} end
    }

    CommentWake.maybe_transition_idle_issue_to_rework(state(), "r3", :pr_comment, event, 1)

    assert [alert] =
             Enum.filter(
               alerts(),
               &(&1["topic"] == "ticket.r3.agent.attention.comment_wake_state_unresolved")
             )

    assert alert["reason"] =~ "check tracker access and retry"
  end

  test "missing open PR refusal recommends opening a PR" do
    issue = %Issue{id: "r3-no-pr", identifier: "r3-no-pr", state: "human-review", labels: ["agent:human-review"]}

    event =
      comment_event(issue, %{
        open_pr_fetcher: fn _issue_key -> {:ok, nil} end
      })

    CommentWake.maybe_transition_idle_issue_to_rework(state(), "r3-no-pr", :pr_review, event, 1)

    assert [alert] =
             Enum.filter(
               alerts(),
               &(&1["topic"] == "ticket.r3-no-pr.agent.attention.comment_wake_idle_issue")
             )

    assert alert["reason"] =~ "open a pull request before requesting rework"
  end

  test "idle rework state update failure is durable and points to tracker permissions" do
    issue = %Issue{id: "r3-update", identifier: "r3-update", state: "human-review", labels: ["agent:human-review"]}

    event =
      open_pr_event(issue, %{
        comment_update_issue_state_fun: fn _id, "rework" -> {:error, :forbidden} end
      })

    CommentWake.maybe_transition_idle_issue_to_rework(state(), "r3-update", :pr_review, event, 1)

    assert [alert] = Enum.filter(alerts(), &(&1["topic"] == "ticket.r3-update.agent.attention.comment_wake_state_update_failed"))
    assert alert["reason"] =~ "check tracker permissions and retry"
  end

  test "inactive issue reactivation refusal recommends activating the issue" do
    number = "r3-inactive"
    state = reactivation_state(number)

    event = %{
      author_trusted?: true,
      comment: %{"body" => "please fix", "state" => "CHANGES_REQUESTED"},
      open_pr_fetcher: fn _ -> {:ok, nil} end
    }

    CommentWake.maybe_reactivate_on_comment(state, number, :pr_review, event, 1)

    assert [alert] = Enum.filter(alerts(), &(&1["topic"] == "ticket.#{number}.agent.attention.comment_wake_inactive_issue"))
    assert alert["reason"] =~ "change the issue to an active state"
  end

  test "reactivation state update failure is durable and points to tracker permissions" do
    number = "r3-reactivation-write"
    issue = %Issue{id: number, identifier: number, state: "human-review", labels: ["agent:human-review"]}
    state = reactivation_state(number)

    event =
      open_pr_event(issue, %{
        comment: %{"body" => "please fix", "state" => "CHANGES_REQUESTED"},
        comment_update_issue_state_fun: fn _id, "rework" -> {:error, :forbidden} end
      })

    CommentWake.maybe_reactivate_on_comment(state, number, :pr_review, event, 1)

    assert [alert] = Enum.filter(alerts(), &(&1["topic"] == "ticket.#{number}.agent.attention.comment_wake_reactivation_state_failed"))
    assert alert["reason"] =~ "check tracker permissions and retry reactivation"
  end

  test "inactive reactivation refusal is durable and recommends activating the issue" do
    number = "r3-reactivation-inactive"
    state = reactivation_state(number)
    entry = Map.fetch!(state.running, number)
    inactive_issue = %Issue{id: number, identifier: number, state: "done", labels: ["agent:done"]}
    entry = Map.put(entry, :comment_reactivation_issue_fetcher, fn _ids -> {:ok, [inactive_issue]} end)
    state = %{state | running: %{number => entry}}

    event = %{
      author_trusted?: true,
      comment: %{"body" => "follow up", "state" => "COMMENTED"},
      open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "head-1"}}} end,
      unresolved_threads_fetcher: fn _ -> {:ok, []} end
    }

    CommentWake.maybe_reactivate_on_comment(state, number, :pr_comment, event, 1)

    assert [alert] = Enum.filter(alerts(), &(&1["topic"] == "ticket.#{number}.agent.attention.comment_wake_inactive_issue_reactivation"))
    assert alert["reason"] =~ "change the issue to an active state"
  end

  test "reactivation refresh failure is durable and recommends retrying the refresh" do
    number = "r3-reactivation-refresh"
    state = reactivation_state(number)
    entry = Map.fetch!(state.running, number)
    entry = Map.put(entry, :comment_reactivation_issue_fetcher, fn _ids -> {:error, :offline} end)
    state = %{state | running: %{number => entry}}

    event = %{
      author_trusted?: true,
      comment: %{"body" => "follow up", "state" => "COMMENTED"},
      open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "head-1"}}} end,
      unresolved_threads_fetcher: fn _ -> {:ok, []} end
    }

    CommentWake.maybe_reactivate_on_comment(state, number, :pr_comment, event, 1)

    assert [alert] = Enum.filter(alerts(), &(&1["topic"] == "ticket.#{number}.agent.attention.comment_wake_reactivation_refresh_failed"))
    assert alert["reason"] =~ "check tracker access and retry reactivation"
  end

  test "active CHANGES_REQUESTED refusal is durable and directs the operator to rework or re-review" do
    number = "r4"
    state = active_running_state(number)
    {state, number, event} = active_review_event(state, number, "CHANGES_REQUESTED")

    CommentWake.maybe_reactivate_on_comment(state, number, :pr_review, event, 1)

    assert [alert] =
             Enum.filter(
               alerts(),
               &(&1["topic"] == "ticket.r4.agent.attention.review_rework_refused")
             )

    assert alert["reason"] =~ "move the ticket to rework or re-review it"
    refute alert["reason"] =~ "gh pr review --request-changes"
  end

  test "plain conversation comments on active issues do not create refusal alerts" do
    number = "r5"
    state = active_running_state(number)
    {state, number, event} = active_review_event(state, number, "COMMENTED")

    CommentWake.maybe_reactivate_on_comment(state, number, :pr_review, event, 1)

    refute Enum.any?(alerts(), &(&1["topic"] == "ticket.r5.agent.attention.comment_wake_rework_skipped"))
    refute Enum.any?(alerts(), &(&1["topic"] == "ticket.r5.agent.attention.review_rework_refused"))
  end

  test "active correct comment skip retains its info log" do
    number = "r5-log"
    state = active_running_state(number)
    {state, number, event} = active_review_event(state, number, "COMMENTED")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        CommentWake.maybe_reactivate_on_comment(state, number, :pr_review, event, 1)
      end)

    assert log =~ "active comment rework skipped"
  end

  test "PR anchored input deferred by an occupied cap slot is durable" do
    pr = %{"number" => 42, "title" => "PR", "body" => "", "head" => %{"ref" => "feature"}}
    occupied = %{control: %{status: :running}}

    state = %{
      state()
      | running: %{"other" => occupied},
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1
    }

    event = %{
      author_trusted?: true,
      open_pull_request_fetcher: fn _number -> {:ok, pr} end
    }

    PrAnchored.maybe_route_pr_anchored_or_legacy(state, "42", :github, event, 1)

    assert [alert] = Enum.filter(alerts(), &(&1["topic"] == "ticket.42.agent.attention.pr_anchored_dispatch_agent_cap_full"))
    assert alert["reason"] =~ "free an agent slot"
  end

  test "PR anchored input dropped for an existing running claim is durable" do
    pr = %{"number" => 43, "title" => "PR", "body" => "", "head" => %{"ref" => "feature"}}
    state = %{state() | running: %{"pr-43" => %{control: %{status: :running}}}}

    event = %{
      author_trusted?: true,
      open_pull_request_fetcher: fn _number -> {:ok, pr} end
    }

    PrAnchored.maybe_route_pr_anchored_or_legacy(state, "43", :github, event, 1)

    assert [alert] = Enum.filter(alerts(), &(&1["topic"] == "ticket.43.agent.attention.pr_anchored_dispatch_already_running"))
    assert alert["reason"] =~ "send the comment to that agent's session"
  end

  test "dispatch declines persist cause-specific remedies for all gate causes" do
    cases = [
      {:paused, "r7-paused", %Issue{state: "todo", paused: true}, %{}, "resume the issue"},
      {:parked, "r7-parked", %Issue{state: "todo", parked: true}, %{}, "unpark it"},
      {:already_running, "r7-running", %Issue{state: "todo"}, %{running: %{"r7-running" => %{control: %{status: :running}}}}, "send the comment to its session"},
      {:policy, "r7-policy", %Issue{state: "done"}, %{}, "move it to an active state"}
    ]

    for {cause, identifier, %Issue{} = dispatch_attrs, state_overrides, remedy} <- cases do
      issue = %Issue{id: identifier, identifier: identifier, state: "todo", labels: ["agent:todo"]}
      dispatch_issue = %Issue{dispatch_attrs | id: identifier, identifier: identifier, labels: ["agent:#{dispatch_attrs.state}"]}

      event = %{
        author_trusted?: true,
        id: 700,
        issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
        comment_dispatch_issue_fetcher: fn _ids -> {:ok, [dispatch_issue]} end
      }

      current_state =
        state()
        |> Map.merge(state_overrides)
        |> Map.put(:queue_store, AgentQueueStore.new())

      CommentWake.maybe_transition_idle_issue_to_rework(current_state, identifier, :pr_comment, event, 1)

      assert [alert] =
               Enum.filter(
                 alerts(),
                 &(&1["topic"] == "ticket.#{identifier}.agent.attention.comment_wake_dispatch_declined")
               ),
             "expected durable dispatch decline for #{cause}"

      assert alert["reason"] =~ remedy
    end
  end
end
