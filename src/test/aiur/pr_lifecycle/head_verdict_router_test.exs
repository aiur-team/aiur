defmodule Aiur.PRLifecycle.HeadVerdictRouterTest do
  # #4811: the configured reviewer's CHANGES_REQUESTED at the PR's current head
  # moves a waiting or error ticket to `agent:rework`; an APPROVED there that supersedes a
  # same-head changes request moves a rework ticket to `agent:ci-wait`. Nothing
  # else routes.
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

  defmodule FailingTracker do
    @moduledoc false
    def update_issue_state(issue_id, to_state, opts) do
      send(self(), {:state_write, issue_id, to_state, opts})
      {:error, :boom}
    end
  end

  defp issue(state, fields \\ []),
    do: struct!(%Issue{id: "3145", identifier: "3145", title: "t", state: state, state_labels: ["agent:#{state}"]}, fields)

  defp pr(fields \\ %{}),
    do: Map.merge(%{"number" => 4805, "state" => "open", "draft" => false, "head" => %{"sha" => @head, "ref" => "aiur/3145-fix"}, "updated_at" => "t1"}, fields)

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
    test_pid = self()

    {:ok, state} =
      HeadVerdictRouter.init(
        Keyword.merge(
          [
            start_paused?: true,
            enabled?: fn -> true end,
            tracker: FakeTracker,
            alert_fun: fn name, fields -> send(test_pid, {:alert, name, fields}) end,
            tickets_fetcher: fn -> {:ok, [issue("human-review")]} end,
            open_prs_fetcher: fn -> {:ok, [pr()]} end,
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
    HeadVerdictRouter.tick(worker(open_prs_fetcher: fn -> {:ok, [pr(%{"head" => %{"sha" => @head, "ref" => "aiur/9999-other"}})]} end))
    HeadVerdictRouter.tick(worker(open_prs_fetcher: fn -> {:ok, [pr(%{"state" => "closed"})]} end))

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

  test "an approval with no prior changes request leaves a rework ticket in rework" do
    # The CI-failure shape: CI moved an approved ticket to rework at the approved head.
    HeadVerdictRouter.tick(rework_worker([review(%{"state" => "APPROVED"})]))

    refute_received {:state_write, _, _, _}
  end

  test "an approval after a changes request on an older head leaves a rework ticket in rework" do
    request = review(%{"commit_id" => "sha-old"})
    approval = review(%{"id" => 2, "state" => "APPROVED", "submitted_at" => "2026-10-17T02:00:00Z"})
    HeadVerdictRouter.tick(rework_worker([request, approval]))

    refute_received {:state_write, _, _, _}
  end

  test "an approval after the reviewer's same-head changes request moves a rework ticket to ci-wait" do
    approval = review(%{"id" => 2, "state" => "APPROVED", "submitted_at" => "2026-10-17T02:00:00Z"})
    HeadVerdictRouter.tick(rework_worker([review(%{}), approval]))

    assert_received {:state_write, "3145", "ci-wait", opts}
    assert opts[:expected_state] == "rework"
  end

  test "an approval seen on a ci-wait ticket is not routed after CI moves the ticket to rework" do
    approval = review(%{"id" => 2, "state" => "APPROVED", "submitted_at" => "2026-10-17T02:00:00Z"})
    {:ok, ticket} = Agent.start_link(fn -> "ci-wait" end)

    state =
      worker(
        tickets_fetcher: fn -> {:ok, [issue(Agent.get(ticket, & &1))]} end,
        reviews_fetcher: fn 4805 -> {:ok, [review(%{}), approval]} end
      )

    state = HeadVerdictRouter.tick(state)
    Agent.update(ticket, fn _ -> "rework" end)
    HeadVerdictRouter.tick(state)

    refute_received {:state_write, _, _, _}
  end

  test "skips a parked ticket" do
    HeadVerdictRouter.tick(worker(tickets_fetcher: fn -> {:ok, [issue("human-review", parked: true)]} end))

    refute_received {:state_write, _, _, _}
  end

  test "makes one open-PR listing per tick and re-reads reviews only when the PR changed" do
    {:ok, calls} = Agent.start_link(fn -> %{listings: 0, reviews: 0} end)
    {:ok, current} = Agent.start_link(fn -> pr() end)

    state =
      worker(
        open_prs_fetcher: fn ->
          Agent.update(calls, &Map.update!(&1, :listings, fn n -> n + 1 end))
          {:ok, [Agent.get(current, & &1)]}
        end,
        reviews_fetcher: fn _number ->
          Agent.update(calls, &Map.update!(&1, :reviews, fn n -> n + 1 end))
          {:ok, [review(%{"state" => "COMMENTED"})]}
        end
      )

    state = state |> HeadVerdictRouter.tick() |> HeadVerdictRouter.tick()
    assert Agent.get(calls, & &1) == %{listings: 2, reviews: 1}

    Agent.update(current, &Map.put(&1, "updated_at", "t2"))
    state = HeadVerdictRouter.tick(state)
    assert Agent.get(calls, & &1) == %{listings: 3, reviews: 2}

    Agent.update(current, &Map.put(&1, "head", %{"sha" => "sha-new", "ref" => "aiur/3145-fix"}))
    HeadVerdictRouter.tick(state)
    assert Agent.get(calls, & &1) == %{listings: 4, reviews: 3}
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

  test "paces ticks from pr_health.interval_seconds, not the start option or the default" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), pr_health_interval_seconds: 7)

    state = HeadVerdictRouter.tick(worker(interval_ms: 5))

    assert state.next_delay_ms == 7_000
  end

  describe "error tickets (#4535)" do
    defp error_worker(opts), do: worker(Keyword.merge([tickets_fetcher: fn -> {:ok, [issue("error")]} end], opts))

    test "moves an error ticket to rework for a changes-requested review at the head" do
      HeadVerdictRouter.tick(error_worker([]))

      assert_received {:state_write, "3145", "rework", opts}
      assert opts[:expected_state] == "error"
    end

    test "a rework turn that ends in error on the same review routes once more" do
      {:ok, ticket} = Agent.start_link(fn -> "rework" end)
      state = error_worker(tickets_fetcher: fn -> {:ok, [issue(Agent.get(ticket, & &1))]} end)

      state = HeadVerdictRouter.tick(state)
      refute_received {:state_write, _, _, _}

      Agent.update(ticket, fn _ -> "error" end)
      HeadVerdictRouter.tick(state)

      assert_received {:state_write, "3145", "rework", opts}
      assert opts[:expected_state] == "error"
    end

    test "ci-wait to rework to error routes the same review from error" do
      {:ok, ticket} = Agent.start_link(fn -> "ci-wait" end)
      state = error_worker(tickets_fetcher: fn -> {:ok, [issue(Agent.get(ticket, & &1))]} end)

      state = HeadVerdictRouter.tick(state)
      assert_received {:state_write, "3145", "rework", opts}
      assert opts[:expected_state] == "ci-wait"

      Agent.update(ticket, fn _ -> "error" end)
      HeadVerdictRouter.tick(state)

      assert_received {:state_write, "3145", "rework", opts}
      assert opts[:expected_state] == "error"
    end

    test "routes once, records why, and routes again on a new blocking review" do
      {:ok, current} = Agent.start_link(fn -> {pr(), [review(%{})]} end)

      state =
        error_worker(
          open_prs_fetcher: fn -> {:ok, [Agent.get(current, &elem(&1, 0))]} end,
          reviews_fetcher: fn 4805 -> {:ok, Agent.get(current, &elem(&1, 1))} end
        )

      state = HeadVerdictRouter.tick(state)
      assert_received {:state_write, "3145", "rework", _opts}
      assert_received {:alert, "system.pr_health.error_rework", fields}
      assert fields[:reason] =~ "Review 1 by its-everdred"

      state = HeadVerdictRouter.tick(state)
      refute_received {:state_write, _, _, _}

      Agent.update(current, fn _ -> {pr(%{"updated_at" => "t2"}), [review(%{"id" => 2, "submitted_at" => "2026-10-17T03:00:00Z"})]} end)
      HeadVerdictRouter.tick(state)
      assert_received {:state_write, "3145", "rework", _opts}
    end

    test "an error ticket without an open PR keeps its state" do
      HeadVerdictRouter.tick(error_worker(open_prs_fetcher: fn -> {:ok, []} end))

      refute_received {:state_write, _, _, _}
    end

    test "a review on a stale head, a draft PR, or an unknown draft flag is not routed" do
      for open_pr <- [pr(%{"head" => %{"sha" => "newer", "ref" => "aiur/3145-fix"}}), pr(%{"draft" => true}), Map.delete(pr(), "draft")] do
        HeadVerdictRouter.tick(error_worker(open_prs_fetcher: fn -> {:ok, [open_pr]} end))
      end

      refute_received {:state_write, _, _, _}
    end

    test "a superseded, untrusted, commented, or absent changes request is not routed" do
      approved = review(%{"id" => 2, "state" => "APPROVED", "submitted_at" => "2026-10-17T02:00:00Z"})

      for reviews <- [[review(%{}), approved], [review(%{:authoritative => false})], [review(%{"state" => "COMMENTED"})], []] do
        HeadVerdictRouter.tick(error_worker(reviews_fetcher: fn 4805 -> {:ok, reviews} end))
      end

      refute_received {:state_write, _, _, _}
    end

    test "a paused error ticket is skipped and a failed write is retried next tick" do
      HeadVerdictRouter.tick(error_worker(tickets_fetcher: fn -> {:ok, [issue("error", paused: true)]} end))
      refute_received {:state_write, _, _, _}

      failed = HeadVerdictRouter.tick(error_worker(tracker: FailingTracker))
      assert_received {:state_write, "3145", "rework", _opts}
      refute_received {:alert, _name, _fields}
      assert failed.routed == MapSet.new()
    end
  end
end
