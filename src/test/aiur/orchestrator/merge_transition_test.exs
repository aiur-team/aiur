defmodule Aiur.Orchestrator.MergeTransitionTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState
  alias Aiur.Orchestrator.{CommentWake, MergeTransition, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "agent")
    :ok
  end

  test "GitHub closing keyword before the merge write completes an already done ticket without an alert" do
    issue = %{"state" => "closed", "labels" => [%{"name" => "agent:done"}, %{"name" => "agent:queued"}], "body" => "private issue body"}
    parent = self()

    log =
      capture_log(fn ->
        merge(issue, fn state, identifier ->
          send(parent, {:resumed, identifier})
          state
        end)
      end)

    assert_received {:resumed, "3778"}
    assert_received :terminated
    refute log =~ "merge_terminal_write_failed"
    refute log =~ "private issue body"
  end

  test "a closed ticket with an active label still alerts using only the reason name" do
    issue = %{"state" => "closed", "labels" => [%{"name" => "agent:rework"}], "body" => String.duplicate("private issue body", 500)}

    log = capture_log(fn -> merge(issue) end)
    refute_received :terminated

    assert log =~ "ticket.3778.agent.attention.merge_terminal_write_failed"
    assert log =~ "no_state_label_written"
    refute log =~ "private issue body"
    refute log =~ "ticket was not closed"
  end

  test "future regression guard: only closed issues with exclusively terminal state labels satisfy the merge" do
    for {state, labels} <- [{"open", ["agent:done"]}, {"closed", []}, {"closed", ["agent:done", "agent:rework"]}, {"closed", ["other:done"]}] do
      outcome = {"rework", {:error, {:no_state_label_written, %{"state" => state, "labels" => Enum.map(labels, &%{"name" => &1})}}}}
      assert MergeTransition.normalize(outcome) == outcome
    end
  end

  test "future regression guard: other failures retain their outcome and have bounded cause names" do
    assert MergeTransition.normalize({"done", {:error, :timeout}}) == {"done", {:error, :timeout}}
    assert MergeTransition.reason_name(:timeout) == :timeout
    assert MergeTransition.reason_name({:github, :local_hold, %{body: "private"}}) == :github
    assert MergeTransition.reason_name(%{body: "private"}) == :unknown
  end

  defp merge(issue, resume \\ fn state, _identifier -> state end) do
    request_fun = fn request ->
      case request.method do
        :get -> {:ok, %{status: 200, body: issue}}
        :delete -> {:ok, %{status: 200, body: []}}
        other -> flunk("unexpected write: #{other}")
      end
    end

    context = %{
      request_fun: request_fun,
      token: "test-token",
      owner: "owner",
      repo: "repo",
      issue_number: "3778",
      issue_url: "https://api.github.com/repos/owner/repo/issues/3778",
      prefix: "agent",
      opts: [request_fun: request_fun]
    }

    parent = self()
    ticket = %Aiur.Issue{id: "3778", identifier: "3778", state: "rework"}
    state = %State{running: %{"3778" => %{issue: ticket, identifier: "3778"}}, completed: MapSet.new(), claimed: MapSet.new(["3778"])}

    CommentWake.mark_pr_merged_issue_done(state, "3778",
      pr_body: "Closes #3778",
      target_state: "rework",
      update_issue_state_fun: fn "3778", target -> IssueState.apply_issue_state_update(context, issue, target, "agent:#{target}") end,
      merger_allowed_fun: fn _login -> true end,
      clear_session_handle_fun: fn "3778" -> :ok end,
      terminate_running_issue_fun: fn current, "3778", true ->
        send(parent, :terminated)
        current
      end,
      observe_membership_fun: fn _identity, _lifecycle -> :ok end,
      mark_reconciled_fun: fn _identifier -> :ok end,
      set_terminal_verification_pending_fun: fn _identity, _pending -> :ok end,
      resume_blockees_fun: resume
    )
  end
end
