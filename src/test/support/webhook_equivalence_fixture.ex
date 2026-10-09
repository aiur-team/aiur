defmodule Aiur.TestSupport.WebhookEquivalenceFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Aiur.Events.GithubCommentsPoller
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Orchestrator.{CommentPolling, ReadyForReviewTransitions, State}
  @repo "owner/repo"
  @dedup_table Aiur.Events.Publisher.Dedup

  def assert_indistinguishable(polled, pushed) do
    volatile = [:id, :ticket_observation]

    assert Map.drop(polled, volatile) == Map.drop(pushed, volatile),
           """
           webhook and polling payloads diverge

           only in polling: #{inspect(Map.drop(polled, volatile) |> Map.drop(Map.keys(Map.drop(pushed, volatile))))}
           only in webhook: #{inspect(Map.drop(pushed, volatile) |> Map.drop(Map.keys(Map.drop(polled, volatile))))}

           polling: #{inspect(Map.drop(polled, volatile), pretty: true)}
           webhook: #{inspect(Map.drop(pushed, volatile), pretty: true)}
           """
  end

  # Drives the real comment poller the way the orchestrator does (ledger
  # snapshot in the options) over a batch that carries the ticket's open PR,
  # then folds the result into orchestrator state as the async poll does.
  # `history` answers the PR's issue-events read, which reports itself.
  def poll_draft_flag(%State{} = state, target, pr_number, head_sha, draft?, history \\ []) do
    test_pid = self()

    pull_request = %{
      "number" => pr_number,
      "state" => "open",
      "draft" => draft?,
      "head" => %{"ref" => "aiur/#{target}", "sha" => head_sha}
    }

    request_fun = fn %{url: url} ->
      if url =~ "/issues/#{pr_number}/events" do
        send(test_pid, {:history_read, url})
        history_response(history)
      else
        flunk("unexpected GitHub request #{url}")
      end
    end

    poll_result =
      GithubCommentsPoller.poll([target],
        since: "2026-06-24T11:00:00Z",
        repo: @repo,
        request_fun: request_fun,
        review_submission_targets: MapSet.new(),
        pr_ready_ledger: ReadyForReviewTransitions.ledger(state),
        comment_batch: %{
          target => %{
            issue_comments: [],
            open_pull_request: pull_request,
            pr_issue_comments: [],
            review_thread_comments: []
          }
        }
      )

    assert {:ok, %{errors: []}} = poll_result

    ref = make_ref()
    CommentPolling.apply_async(%{state | github_comment_poll: %{ref: ref}}, ref, {:ok, %{}, [], {[target], poll_result}})
  end

  def history_response({:status, status}), do: {:ok, %{status: status, body: %{"message" => "Not Found"}}}
  def history_response(events) when is_list(events), do: {:ok, %{status: 200, body: events}}

  def restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  def restore_app_env(key, value), do: Application.put_env(:aiur, key, value)

  def await_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> event
    after
      1_000 -> flunk("no event published on #{topic}")
    end
  end

  # Empties only the volatile replay window, leaving the durable resource marks
  # in place — the state a daemon restart actually produces.
  def clear_replay_window do
    case :ets.whereis(@dedup_table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end

    :ok
  end

  # These tests deliberately drive both pipes over the *same* comment so the two
  # published events can be compared field by field. In production that second
  # publish is exactly what must not happen — it is the double-processing #2069
  # removes — so every suppression layer has to be cleared between the halves,
  # not just the in-memory window.
  def clear_dedup do
    case :ets.whereis(@dedup_table) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(@dedup_table)
    end

    ResourceStore.reset()

    :ok
  end
end
