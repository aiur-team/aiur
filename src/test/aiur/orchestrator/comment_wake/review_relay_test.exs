defmodule Aiur.Orchestrator.CommentWake.ReviewRelayTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, Issue}
  alias Aiur.Orchestrator.{CommentWake, State}

  @issue_number "2814"

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok
  end

  test "a trusted COMMENT review with Blocking lines reaches a running worker once" do
    issue = in_progress_issue()
    review = review(9917, "COMMENTED", "Blocking: preserve the retry cursor\n- Add a regression test", 17)
    event = %{comment: review, pull_request: %{}, author_trusted?: true}
    running = running_worker(issue)

    first = CommentWake.maybe_reactivate_on_comment(base_state(running), @issue_number, :pr_review, event)
    second = CommentWake.maybe_reactivate_on_comment(first, @issue_number, :pr_review, event)

    assert_receive {:agent_queue_updated, @issue_number, _, _}, 1_000

    messages = Enum.filter(Map.values(second.queue_store.items), &(&1.category == :operator_message))
    assert length(messages) == 1
    assert [%{body: %{text: text}, message_id: "pr-review:2814:9917"}] = messages
    assert text =~ "PR #17 review findings"
    assert text =~ "https://github.com/example/repo/pull/17#pullrequestreview-9917"
    assert text =~ "Blocking: preserve the retry cursor"
    assert text =~ "- Add a regression test"
  end

  test "a trusted blocking PR comment reaches a running worker once" do
    issue = in_progress_issue()
    body = String.duplicate("background context ", 80) <> "\nBlocking: update the retry guard"
    comment = review(9918, nil, body, 18, "issuecomment")
    event = %{comment: comment, pull_request: %{}, author_trusted?: true}
    running = running_worker(issue)

    first = CommentWake.maybe_reactivate_on_comment(base_state(running), @issue_number, :pr_comment, event)
    second = CommentWake.maybe_reactivate_on_comment(first, @issue_number, :pr_comment, event)

    assert_receive {:agent_queue_updated, @issue_number, _, _}, 1_000

    messages = Enum.filter(Map.values(second.queue_store.items), &(&1.category == :operator_message))
    assert length(messages) == 1
    assert [%{body: %{text: text}, message_id: "pr-review:2814:9918"}] = messages
    assert text =~ "PR #18 review findings"
    assert text =~ "https://github.com/example/repo/pull/18#issuecomment-9918"
    assert text =~ "Blocking: update the retry guard"
  end

  defp review(id, state, body, pr_number, fragment \\ "pullrequestreview") do
    %{
      "id" => id,
      "state" => state,
      "body" => body,
      "html_url" => "https://github.com/example/repo/pull/#{pr_number}##{fragment}-#{id}",
      "user" => %{"login" => "reviewer"}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp in_progress_issue do
    %Issue{id: @issue_number, identifier: @issue_number, state: "in-progress", title: "t", labels: ["agent:in-progress"]}
  end

  defp running_worker(issue) do
    %{
      @issue_number => %{
        identifier: @issue_number,
        issue: issue,
        pid: self(),
        control: %{status: :working, version: 1}
      }
    }
  end

  defp base_state(running), do: %State{queue_store: AgentQueueStore.new(), running: running}
end
