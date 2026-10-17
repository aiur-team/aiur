defmodule Aiur.PRLifecycle.HeadVerdictRouterTest do
  # #4811: the configured reviewer's CHANGES_REQUESTED at the PR's current head
  # moves a waiting ticket to `agent:rework`; an APPROVED there moves a rework
  # ticket to `agent:ci-wait`. Nothing else routes.
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.PRLifecycle.HeadVerdictRouter

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
      HeadVerdictRouter.init(
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

  defp rework_worker(reviews), do: worker(tickets_fetcher: fn -> {:ok, [issue("rework")]} end, reviews_fetcher: fn 4805 -> {:ok, reviews} end)

  # The write is the standard state write (`TicketTransition` -> tracker
  # `update_issue_state/3`), whose add-new-label-first swap is pinned by
  # `Aiur.GitHub.IssueStateTest` ("adds the new state label first ...").
  test "moves a human-review ticket to rework for a changes-requested review at the head" do
    HeadVerdictRouter.tick(worker([]))

    assert_received {:state_write, "3145", "rework", opts}
    assert opts[:expected_state] == "human-review"
  end

  test "moves a ci-wait ticket to rework" do
    HeadVerdictRouter.tick(worker(tickets_fetcher: fn -> {:ok, [issue("ci-wait")]} end))

    assert_received {:state_write, "3145", "rework", opts}
    assert opts[:expected_state] == "ci-wait"
  end

  test "ignores a changes-requested review on an older head" do
    HeadVerdictRouter.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{"commit_id" => "sha-old"})]} end))

    refute_received {:state_write, _, _, _}
  end

  test "ignores COMMENTED and APPROVED reviews at the head of a waiting ticket" do
    for state <- ["COMMENTED", "APPROVED"] do
      HeadVerdictRouter.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{"state" => state})]} end))
    end

    refute_received {:state_write, _, _, _}
  end

  test "a later COMMENTED review does not cancel the reviewer's changes request" do
    comment = review(%{"id" => 2, "state" => "COMMENTED", "submitted_at" => "2026-10-17T02:00:00Z"})
    HeadVerdictRouter.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{}), comment]} end))

    assert_received {:state_write, "3145", "rework", _opts}
  end

  test "a later approval at the head supersedes the reviewer's changes request" do
    approval = review(%{"id" => 2, "state" => "APPROVED", "submitted_at" => "2026-10-17T02:00:00Z"})
    HeadVerdictRouter.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{}), approval]} end))

    refute_received {:state_write, _, _, _}
  end

  test "ignores a review from a reviewer who is not the configured reviewer" do
    HeadVerdictRouter.tick(worker(reviews_fetcher: fn 4805 -> {:ok, [review(%{:authoritative => false})]} end))
    HeadVerdictRouter.tick(rework_worker([review(%{"state" => "APPROVED", :authoritative => false})]))

    refute_received {:state_write, _, _, _}
  end

  test "ignores a closed or merged PR" do
    HeadVerdictRouter.tick(worker(open_pr_fetcher: fn "3145" -> {:ok, nil} end))
    HeadVerdictRouter.tick(worker(open_pr_fetcher: fn "3145" -> {:ok, %{"number" => 4805, "state" => "closed", "head" => %{"sha" => @head}}} end))

    refute_received {:state_write, _, _, _}
  end

  test "routes each review once, so a same-head hand-back does not loop" do
    state = HeadVerdictRouter.tick(worker([]))
    assert_received {:state_write, "3145", "rework", _opts}

    HeadVerdictRouter.tick(state)
    refute_received {:state_write, _, _, _}
  end

  test "a review already seen on a rework ticket is not routed again after hand-back" do
    {:ok, ticket} = Agent.start_link(fn -> "rework" end)
    state = worker(tickets_fetcher: fn -> {:ok, [issue(Agent.get(ticket, & &1))]} end)

    state = HeadVerdictRouter.tick(state)
    Agent.update(ticket, fn _ -> "human-review" end)
    HeadVerdictRouter.tick(state)

    refute_received {:state_write, _, _, _}
  end

  test "moves a rework ticket to ci-wait for an approval at the head" do
    HeadVerdictRouter.tick(rework_worker([review(%{"state" => "APPROVED"})]))

    assert_received {:state_write, "3145", "ci-wait", opts}
    assert opts[:expected_state] == "rework"
  end

  test "an approval after the reviewer's changes request moves a rework ticket to ci-wait" do
    approval = review(%{"id" => 2, "state" => "APPROVED", "submitted_at" => "2026-10-17T02:00:00Z"})
    HeadVerdictRouter.tick(rework_worker([review(%{}), approval]))

    assert_received {:state_write, "3145", "ci-wait", _opts}
  end

  test "ignores an approval on an older head for a rework ticket" do
    HeadVerdictRouter.tick(rework_worker([review(%{"state" => "APPROVED", "commit_id" => "sha-old"})]))

    refute_received {:state_write, _, _, _}
  end

  test "another configured reviewer's changes request at the head keeps a rework ticket in rework" do
    approval = review(%{"id" => 2, "state" => "APPROVED"})
    request = review(%{"id" => 3, "user" => %{"login" => "second-owner"}})
    HeadVerdictRouter.tick(rework_worker([approval, request]))

    refute_received {:state_write, _, _, _}
  end
end
