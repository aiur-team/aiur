defmodule Aiur.PRLifecycle.ErrorReworkTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.PRLifecycle.{ErrorRework, ReworkRequeue}

  defp issue(id), do: %Issue{id: id, identifier: id, title: "t", state: "error", state_labels: ["agent:error"]}

  defp review(overrides) do
    Map.merge(
      %{"id" => 1, "state" => "CHANGES_REQUESTED", "commit_id" => "sha", "submitted_at" => "2026-10-15T11:00:00Z", "user" => %{"login" => "exec"}, :authoritative => true},
      overrides
    )
  end

  defp pr(overrides), do: Map.merge(%{"number" => 4478, "draft" => false, "head" => %{"sha" => "sha"}}, overrides)

  defp state(opts) do
    test_pid = self()

    %{
      error_tickets_fetcher: fn -> {:ok, Keyword.get(opts, :tickets, [issue("4463")])} end,
      open_pr_fetcher: fn key -> Keyword.get(opts, :open_pr, fn _ -> {:ok, pr(%{})} end).(key) end,
      classified_reviews_fetcher: fn 4478 -> {:ok, Keyword.get(opts, :reviews, [review(%{})])} end,
      state_writer: fn key, target ->
        send(test_pid, {:write, key, target})
        Keyword.get(opts, :write_result, :ok)
      end,
      alert_fun: fn name, fields -> send(test_pid, {:alert, name, fields}) end,
      error_rework_routed: MapSet.new()
    }
  end

  test "routes an error ticket with a blocking review to rework once and records why" do
    first = ErrorRework.scan(state([]))
    assert_received {:write, "4463", "rework"}
    assert_received {:alert, "system.pr_health.error_rework", fields}
    assert fields[:reason] =~ "Review 1 by exec on PR #4478"

    ErrorRework.scan(first)
    refute_received {:write, _key, _target}

    # A new blocking review routes it again.
    ErrorRework.scan(%{first | classified_reviews_fetcher: fn 4478 -> {:ok, [review(%{"id" => 2, "submitted_at" => "2026-10-16T00:00:00Z"})]} end})
    assert_received {:write, "4463", "rework"}
  end

  test "error tickets without an open PR keep their state" do
    ErrorRework.scan(state(open_pr: fn _ -> {:ok, nil} end))
    refute_received {:write, _key, _target}
  end

  test "a review on a stale head, a draft PR, or an unknown draft flag is not routed" do
    for open_pr <- [pr(%{"head" => %{"sha" => "newer"}}), pr(%{"draft" => true}), Map.delete(pr(%{}), "draft")] do
      ErrorRework.scan(state(open_pr: fn _ -> {:ok, open_pr} end))
      refute_received {:write, _key, _target}
    end
  end

  test "a superseded, untrusted, or absent blocking review is not routed" do
    approved = review(%{"id" => 2, "state" => "APPROVED", "submitted_at" => "2026-10-16T00:00:00Z"})

    for reviews <- [[review(%{}), approved], [review(%{:authoritative => false})], [review(%{"state" => "COMMENTED"})], []] do
      ErrorRework.scan(state(reviews: reviews))
      refute_received {:write, _key, _target}
    end
  end

  test "paused tickets are skipped and a failed write is retried next tick" do
    paused = %{issue("4463") | paused: true}
    ErrorRework.scan(state(tickets: [paused]))
    refute_received {:write, _key, _target}

    failed = ErrorRework.scan(state(write_result: {:error, :boom}))
    assert_received {:write, "4463", "rework"}
    refute_received {:alert, _name, _fields}
    assert failed.error_rework_routed == MapSet.new()
  end

  test "the rework re-queue tick runs the error sweep" do
    opts = state([]) |> Map.drop([:error_rework_routed]) |> Map.to_list()
    assert {:ok, worker} = ReworkRequeue.init([start_paused?: true, enabled?: fn -> true end, tickets_fetcher: fn -> {:ok, []} end] ++ opts)
    assert MapSet.size(ReworkRequeue.tick(worker).error_rework_routed) == 1
    assert_received {:write, "4463", "rework"}
  end
end
