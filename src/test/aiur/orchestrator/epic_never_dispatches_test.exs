defmodule Aiur.Orchestrator.EpicNeverDispatchesTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.Orchestrator.{CommentWake, DispatchPolicy, State}
  alias Aiur.Orchestrator.PauseResume.DeclineReason

  # An epic groups member tickets and has no work of its own. A worker label
  # added to it (OGM core #1428 gained `agent:rework`) must not dispatch it.
  defp issue(labels, state \\ "rework") do
    %Issue{id: "1428", identifier: "1428", title: "Launch epic", state: state, labels: labels}
  end

  defp state, do: %State{max_concurrent_agents: 3, running: %{}, claimed: MapSet.new(), retry_attempts: %{}}

  test "an epic carrying a worker state label is declined by dispatch" do
    for labels <- [["epic", "agent:rework"], ["Epic: Launch", "agent:rework"], [" EPIC ", "agent:todo"]] do
      assert DispatchPolicy.dispatch_decision(issue(labels), state()) == {:skip, :epic}, inspect(labels)
    end

    assert :epic in DispatchPolicy.dispatch_decline_reasons()
  end

  test "labels that only start with the word epic do not hold a member ticket" do
    plain = DispatchPolicy.dispatch_decision(issue(["agent:rework"]), state())

    refute plain == {:skip, :epic}
    assert DispatchPolicy.dispatch_decision(issue(["epics-roadmap", "agent:rework"]), state()) == plain
  end

  test "an operator resume of an epic names the epic refusal" do
    assert DeclineReason.resume_decline_reason(:epic, issue(["epic"]), state()) == :ticket_epic
  end

  test "a trusted comment does not flip an epic to rework" do
    epic = issue(["epic", "agent:human-review"], "human-review")

    event = %{
      author_trusted?: true,
      comment: %{"body" => "please fix"},
      issue_state_fetcher: fn _ids -> {:ok, [epic]} end,
      open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
      unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "thread-1"}]} end,
      comment_update_issue_state_fun: fn issue_id, state ->
        send(self(), {:comment_state_write, issue_id, state})
        :ok
      end
    }

    log = capture_log(fn -> assert CommentWake.maybe_transition_idle_issue_to_rework(state(), "1428", "issue comment", event, 1) == state() end)

    assert log =~ ":epic"
    refute_received {:comment_state_write, _, _}
  end
end
