defmodule Aiur.PRLifecycle.ChangesRequestedReworkTest do
  # #4811: a CHANGES_REQUESTED review from the configured reviewer at the PR's
  # current head moves a waiting ticket to `agent:rework`; nothing else does.
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.PRLifecycle.ChangesRequestedRework

  @head "sha-head"

  defmodule FakeTracker do
    @moduledoc false
    def update_issue_state(issue_id, to_state, opts) do
      send(self(), {:state_write, issue_id, to_state, opts})
      :ok
    end
  end

  defp issue(state), do: %Issue{id: "3145", identifier: "3145", title: "t", state: state, state_labels: ["agent:#{state}"]}

  defp review(overrides) do
    Map.merge(
      %{
        "id" => 1,
        "state" => "CHANGES_REQUESTED",
        "commit_id" => @head,
        "submitted_at" => "2026-10-17T01:02:34Z",
        "user" => %{"login" => "its-everdred"},
        :authoritative => true
      },
      overrides
    )
  end

  defp worker(opts) do
    {:ok, state} =
      ChangesRequestedRework.init(
        Keyword.merge(
          [
            start_paused?: true,
            enabled?: fn -> true end,
            tracker: FakeTracker,
            tickets_fetcher: fn -> {:ok, [issue("human-review")]} end,
            open_pr_fetcher: fn "3145" -> {:ok, %{"number" => 4805, "state" => "open", "head" => %{"sha" => @head}}} end,
            reviews_fetcher: fn 4805 -> {:ok, [review(%{})]} end
          ],
          opts
        )
      )

    state
  end

  # The write is the standard state write (`TicketTransition` -> tracker
  # `update_issue_state/3`), whose add-new-label-first swap is pinned by
  # `Aiur.GitHub.IssueStateTest` ("adds the new state label first ...").
  test "moves a human-review ticket to rework for a changes-requested review at the head" do
    ChangesRequestedRework.tick(worker([]))

    assert_received {:state_write, "3145", "rework", opts}
    assert opts[:expected_state] == "human-review"
  end

  test "moves a ci-wait ticket to rework" do
    ChangesRequestedRework.tick(worker(tickets_fetcher: fn -> {:ok, [issue("ci-wait")]} end))

    assert_received {:state_write, "3145", "rework", opts}
    assert opts[:expected_state] == "ci-wait"
  end

  test "ignores a changes-requested review on an older head" do
    ChangesRequestedRework.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{"commit_id" => "sha-old"})]} end))

    refute_received {:state_write, _, _, _}
  end

  test "ignores COMMENTED and APPROVED reviews at the head" do
    for state <- ["COMMENTED", "APPROVED"] do
      ChangesRequestedRework.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{"state" => state})]} end))
    end

    refute_received {:state_write, _, _, _}
  end

  test "a later COMMENTED review does not cancel the reviewer's changes request" do
    comment = review(%{"id" => 2, "state" => "COMMENTED", "submitted_at" => "2026-10-17T02:00:00Z"})
    ChangesRequestedRework.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{}), comment]} end))

    assert_received {:state_write, "3145", "rework", _opts}
  end

  test "a later approval at the head supersedes the reviewer's changes request" do
    approval = review(%{"id" => 2, "state" => "APPROVED", "submitted_at" => "2026-10-17T02:00:00Z"})
    ChangesRequestedRework.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{}), approval]} end))

    refute_received {:state_write, _, _, _}
  end

  test "ignores a review from a reviewer who is not the configured reviewer" do
    ChangesRequestedRework.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{:authoritative => false})]} end))

    refute_received {:state_write, _, _, _}
  end

  test "ignores a closed or merged PR" do
    ChangesRequestedRework.tick(worker(open_pr_fetcher: fn "3145" -> {:ok, nil} end))
    ChangesRequestedRework.tick(worker(open_pr_fetcher: fn "3145" -> {:ok, %{"number" => 4805, "state" => "closed", "head" => %{"sha" => @head}}} end))

    refute_received {:state_write, _, _, _}
  end

  test "routes each review once, so a same-head hand-back does not loop" do
    state = ChangesRequestedRework.tick(worker([]))
    assert_received {:state_write, "3145", "rework", _opts}

    ChangesRequestedRework.tick(state)
    refute_received {:state_write, _, _, _}
  end

  test "a review already seen on a rework ticket is not routed again after hand-back" do
    {:ok, ticket} = Agent.start_link(fn -> "rework" end)
    state = worker(tickets_fetcher: fn -> {:ok, [issue(Agent.get(ticket, & &1))]} end)

    state = ChangesRequestedRework.tick(state)
    Agent.update(ticket, fn _ -> "human-review" end)
    ChangesRequestedRework.tick(state)

    refute_received {:state_write, _, _, _}
  end
end
