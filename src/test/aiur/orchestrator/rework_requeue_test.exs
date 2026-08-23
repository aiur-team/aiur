defmodule Aiur.Orchestrator.ReworkRequeueTest do
  @moduledoc """
  AC for the #2337 rework follow-up (its-everdred 2026-08-23): the inverse of
  cause 2 — a genuinely reworked PR is re-queued for review automatically, and
  a PR whose only new commit is a merge of the base branch is NOT re-queued and
  is reported distinctly (the merge-only state).

  The classification is diff-based, not timestamp-based: it compares the PR's
  own contribution diff (`merge-base..head`) at the blocking review's
  `commit_id` against the current head, so a merge of `main` (which moves
  `head.sha` without touching the own contribution) reads as `:merge_only`,
  not `:addressed`.
  """

  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.ReworkRequeue

  # The blocking review judged head `a`; the PR then moved to head `b`.
  @review_commit "sha-a"
  @head_sha "sha-b"
  @base_sha "base-sha"

  # The fixture deliberately gives the PR a number (2346) DIFFERENT from the
  # issue identifier (2337), so a test can observe which identity production
  # fetches reviews for: fetching reviews for the ticket would 404 and silently
  # turn every rework ticket into `:skip` (review finding, 2026-08-23T20Z).
  defp pr(overrides) do
    Map.merge(
      %{
        "number" => 2346,
        "title" => "PR #2346",
        "state" => "open",
        "draft" => false,
        "base" => %{"sha" => @base_sha, "ref" => "main"},
        "head" => %{"sha" => @head_sha, "ref" => "aiur/2337-pr-turnaround-is-bimodal"}
      },
      overrides
    )
  end

  defp review(overrides) do
    Map.merge(
      %{
        "id" => 1,
        "state" => "CHANGES_REQUESTED",
        "commit_id" => @review_commit,
        "submitted_at" => "2026-08-22T20:00:00Z",
        "user" => %{"login" => "its-everdred"}
      },
      overrides
    )
  end

  defp issue(overrides) do
    %Issue{
      id: "2337",
      identifier: "2337",
      title: "PR #2337",
      state: "rework",
      state_labels: ["agent:rework"]
    }
    |> Map.merge(overrides)
  end

  # The own-diff fingerprint for a head. Defaults to a one-file diff; tests
  # override to simulate a changed contribution.
  defp default_diff_files, do: [{"lib/foo.ex", "blob-sha-1"}]

  describe "latest_blocking_review/1" do
    test "picks the latest CHANGES_REQUESTED review" do
      reviews = [
        review(%{"id" => 1, "submitted_at" => "2026-08-22T18:00:00Z"}),
        review(%{"id" => 2, "submitted_at" => "2026-08-22T20:00:00Z"}),
        %{"id" => 3, "state" => "APPROVED", "submitted_at" => "2026-08-22T21:00:00Z"}
      ]

      assert ReworkRequeue.latest_blocking_review(reviews)["id"] == 2
    end

    test "returns nil when no review blocks" do
      assert ReworkRequeue.latest_blocking_review([%{"state" => "APPROVED"}]) == nil
      assert ReworkRequeue.latest_blocking_review([]) == nil
    end
  end

  describe "classify/3" do
    test ":not_addressed when the head is still the commit the review judged" do
      pr = pr(%{"head" => %{"sha" => @review_commit}})

      assert ReworkRequeue.classify(pr, review(%{}), diff_fetcher: fn _ -> {:ok, default_diff_files()} end) ==
               :not_addressed
    end

    test ":addressed when the own contribution diff changed since the review" do
      # Review-time own diff has one file; the head own diff has a second —
      # genuine rework, whatever the timestamps say.
      diff_fetcher = fn
        {@base_sha, @review_commit} -> {:ok, [{"lib/foo.ex", "blob-sha-1"}]}
        {@base_sha, @head_sha} -> {:ok, [{"lib/foo.ex", "blob-sha-1"}, {"lib/bar.ex", "blob-sha-2"}]}
      end

      assert ReworkRequeue.classify(pr(%{}), review(%{}), diff_fetcher: diff_fetcher) == :addressed
    end

    test ":addressed when the same file's content changed since the review" do
      diff_fetcher = fn
        {@base_sha, @review_commit} -> {:ok, [{"lib/foo.ex", "blob-sha-1"}]}
        {@base_sha, @head_sha} -> {:ok, [{"lib/foo.ex", "blob-sha-2"}]}
      end

      assert ReworkRequeue.classify(pr(%{}), review(%{}), diff_fetcher: diff_fetcher) == :addressed
    end

    test ":merge_only when commits landed but the own contribution diff is identical" do
      # The head moved (a merge of main) but the own contribution is unchanged
      # — a merge-only push must NOT be read as rework.
      diff_fetcher = fn
        {@base_sha, @review_commit} -> {:ok, default_diff_files()}
        {@base_sha, @head_sha} -> {:ok, default_diff_files()}
      end

      assert ReworkRequeue.classify(pr(%{}), review(%{}), diff_fetcher: diff_fetcher) == :merge_only
    end

    test ":unknown when the own-diff cannot be fetched" do
      diff_fetcher = fn _ -> {:error, :timeout} end

      assert ReworkRequeue.classify(pr(%{}), review(%{}), diff_fetcher: diff_fetcher) == :unknown
    end

    test ":unknown when a required identity field is absent" do
      assert ReworkRequeue.classify(pr(%{"head" => %{"sha" => nil}}), review(%{}), diff_fetcher: fn _ -> {:ok, []} end) ==
               :unknown

      assert ReworkRequeue.classify(pr(%{}), review(%{"commit_id" => nil}), diff_fetcher: fn _ -> {:ok, []} end) ==
               :unknown
    end
  end

  defp base_state(opts) do
    %{
      interval_ms: 60_000,
      tickets_fetcher: Keyword.get(opts, :tickets_fetcher, fn -> {:ok, []} end),
      open_pr_fetcher: Keyword.get(opts, :open_pr_fetcher, fn _ -> {:ok, pr(%{})} end),
      reviews_fetcher:
        Keyword.get(opts, :reviews_fetcher, fn number ->
          # Every test that classifies must fetch reviews for the PR (2346),
          # never the issue identifier (2337).
          assert number == 2346
          {:ok, [review(%{})]}
        end),
      diff_fetcher:
        Keyword.get(opts, :diff_fetcher, fn
          {@base_sha, @review_commit} -> {:ok, default_diff_files()}
          {@base_sha, @head_sha} -> {:ok, [{"lib/foo.ex", "blob-sha-1"}, {"lib/bar.ex", "blob-sha-2"}]}
        end),
      state_writer: Keyword.get(opts, :state_writer, fn _, _ -> :ok end),
      alert_fun: Keyword.get(opts, :alert_fun, fn _, _ -> :ok end),
      enabled?: Keyword.get(opts, :enabled?, fn -> true end),
      last_seen: Keyword.get(opts, :last_seen, %{}),
      merge_only_alerted: Keyword.get(opts, :merge_only_alerted, MapSet.new()),
      requeue_failed_alerted: Keyword.get(opts, :requeue_failed_alerted, MapSet.new()),
      start_paused?: true
    }
  end

  describe "tick/1 — re-queue" do
    test "re-queues an addressed ticket to agent:human-review" do
      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          state_writer: fn id, state_name ->
            send(self(), {:state_write, id, state_name})
            :ok
          end
        )

      result = ReworkRequeue.tick(state)

      assert_receive {:state_write, "2337", "human-review"}
      assert %{last_seen: %{"2337" => %{head_sha: @head_sha, classification: :addressed}}} = result
    end

    test "fetches reviews for the PR number, not the issue identifier" do
      # The PR is #2346 while the ticket is #2337; fetching reviews for the
      # ticket would 404 and classify every ticket as `:skip` (dead on
      # arrival). The stub asserts which number production passes.
      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          reviews_fetcher: fn number ->
            send(self(), {:reviews_fetch, number})
            {:ok, [review(%{})]}
          end,
          state_writer: fn id, state_name ->
            send(self(), {:state_write, id, state_name})
            :ok
          end
        )

      ReworkRequeue.tick(state)

      assert_receive {:reviews_fetch, 2346}
      refute_received {:reviews_fetch, 2337}
      assert_receive {:state_write, "2337", "human-review"}
    end

    test "a re-queue refused by the state writer alerts and is not throttled" do
      # The human-review write goes through the thread-clearance gate, which
      # refuses while unresolved review threads remain — the normal state of a
      # rework ticket. The failure must be surfaced (needs-attention alert) and
      # must NOT poison the throttle: the next tick has to retry the write.
      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          state_writer: fn _, _ -> {:error, {:unverified_review_threads, %{count: 2}}} end,
          alert_fun: fn name, opts ->
            send(self(), {:alert, name, opts})
            :ok
          end
        )

      result = ReworkRequeue.tick(state)

      assert_receive {:alert, "system.pr_health.rework_requeue_failed", opts}
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :issue) == "2337"
      # Failed write → head uncached → retried next tick.
      refute Map.has_key?(result.last_seen, "2337")
    end

    test "a failed re-queue alerts once but keeps retrying the write every tick" do
      writes = :atomics.new(1, [])
      alert_calls = :atomics.new(1, [])

      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          state_writer: fn _, _ ->
            :atomics.add(writes, 1, 1)
            {:error, :gate}
          end,
          alert_fun: fn _name, _opts ->
            :atomics.add(alert_calls, 1, 1)
            :ok
          end
        )

      first = ReworkRequeue.tick(state)
      assert :atomics.get(writes, 1) == 1
      assert :atomics.get(alert_calls, 1) == 1
      refute Map.has_key?(first.last_seen, "2337")

      # No throttle entry → the write is retried, but the alert is deduped.
      second = ReworkRequeue.tick(first)
      assert :atomics.get(writes, 1) == 2
      assert :atomics.get(alert_calls, 1) == 1
      refute Map.has_key?(second.last_seen, "2337")
    end

    test "a re-queue write that clears the gate throttles the head for steady state" do
      # Once the threads are resolved the write succeeds and the head is
      # cached, so a steady-state tick stops re-reading reviews/compare.
      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          state_writer: fn id, state_name ->
            send(self(), {:state_write, id, state_name})
            :ok
          end
        )

      result = ReworkRequeue.tick(state)

      assert_receive {:state_write, "2337", "human-review"}
      assert %{last_seen: %{"2337" => %{head_sha: @head_sha, classification: :addressed}}} = result

      # Same head on the next tick: already classified → no finding, no write.
      second = ReworkRequeue.tick(%{result | open_pr_fetcher: fn _ -> {:ok, pr(%{})} end})
      refute_receive {:state_write, _, _}
      assert second.last_seen == result.last_seen
    end

    test "does not re-queue a merge-only ticket and reports it distinctly" do
      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          # Own contribution unchanged at both heads → merge-only.
          diff_fetcher: fn _ -> {:ok, default_diff_files()} end,
          alert_fun: fn name, opts ->
            send(self(), {:alert, name, opts})
            :ok
          end,
          state_writer: fn id, state_name ->
            send(self(), {:state_write, id, state_name})
            :ok
          end
        )

      result = ReworkRequeue.tick(state)

      assert_receive {:alert, "system.pr_health.rework_merge_only", opts}
      assert Keyword.get(opts, :needs_attention) == true
      # The alert names the PR (2346), not the issue identifier (2337).
      assert Keyword.get(opts, :issue) == "2346"
      assert Keyword.get(opts, :message) =~ "PR #2346"
      refute_receive {:state_write, _, _}
      assert %{merge_only_alerted: alerted} = result
      assert MapSet.member?(alerted, "2337")
    end

    test "does not alert a merge-only ticket twice" do
      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          diff_fetcher: fn _ -> {:ok, default_diff_files()} end,
          merge_only_alerted: MapSet.new(["2337"]),
          alert_fun: fn name, opts ->
            send(self(), {:alert, name, opts})
            :ok
          end
        )

      ReworkRequeue.tick(state)
      refute_receive {:alert, "system.pr_health.rework_merge_only", _}
    end

    test "leaves a not_addressed ticket in rework" do
      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          open_pr_fetcher: fn _ -> {:ok, pr(%{"head" => %{"sha" => @review_commit}})} end,
          state_writer: fn id, state_name ->
            send(self(), {:state_write, id, state_name})
            :ok
          end
        )

      ReworkRequeue.tick(state)
      refute_receive {:state_write, _, _}
    end

    test "skips a ticket whose PR has no blocking review" do
      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          reviews_fetcher: fn _ -> {:ok, [%{"state" => "APPROVED"}]} end,
          state_writer: fn id, state_name ->
            send(self(), {:state_write, id, state_name})
            :ok
          end
        )

      ReworkRequeue.tick(state)
      refute_receive {:state_write, _, _}
    end

    test "skips a ticket with no open PR" do
      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          open_pr_fetcher: fn _ -> {:ok, nil} end,
          state_writer: fn id, state_name ->
            send(self(), {:state_write, id, state_name})
            :ok
          end
        )

      ReworkRequeue.tick(state)
      refute_receive {:state_write, _, _}
    end
  end

  describe "tick/1 — throttle and gating" do
    test "does not re-read reviews/compare for a head already classified" do
      reviews_reads = :atomics.new(1, [])
      diff_reads = :atomics.new(1, [])

      state =
        base_state(
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          open_pr_fetcher: fn _ -> {:ok, pr(%{})} end,
          reviews_fetcher: fn _ ->
            :atomics.add(reviews_reads, 1, 1)
            {:ok, [review(%{})]}
          end,
          diff_fetcher: fn _ ->
            :atomics.add(diff_reads, 1, 1)
            {:ok, default_diff_files()}
          end
        )

      first = ReworkRequeue.tick(state)
      assert :atomics.get(reviews_reads, 1) == 1
      # One compare call per head (review commit + current head).
      assert :atomics.get(diff_reads, 1) == 2

      second = ReworkRequeue.tick(%{first | last_seen: first.last_seen})
      assert :atomics.get(reviews_reads, 1) == 1
      assert :atomics.get(diff_reads, 1) == 2

      # A changed head is re-read.
      _changed =
        ReworkRequeue.tick(%{second | open_pr_fetcher: fn _ -> {:ok, pr(%{"head" => %{"sha" => "sha-c"}})} end})

      assert :atomics.get(reviews_reads, 1) == 2
      assert :atomics.get(diff_reads, 1) == 4
    end

    test "makes no fetches when disabled" do
      fetched = :atomics.new(1, [])

      state =
        base_state(
          enabled?: fn -> false end,
          tickets_fetcher: fn ->
            :atomics.add(fetched, 1, 1)
            {:ok, [issue(%{})]}
          end
        )

      ReworkRequeue.tick(state)
      assert :atomics.get(fetched, 1) == 0
    end
  end

  describe "init/1 wiring" do
    test "init wires injected fns and the first tick re-queues with them" do
      {:ok, state} =
        ReworkRequeue.init(
          interval_ms: 60_000,
          tickets_fetcher: fn -> {:ok, [issue(%{})]} end,
          open_pr_fetcher: fn _ -> {:ok, pr(%{})} end,
          reviews_fetcher: fn _ -> {:ok, [review(%{})]} end,
          # Genuine rework: the own contribution differs between the review
          # commit and the head, so the first tick re-queues.
          diff_fetcher: fn
            {@base_sha, @review_commit} -> {:ok, [{"lib/foo.ex", "blob-sha-1"}]}
            {@base_sha, @head_sha} -> {:ok, [{"lib/foo.ex", "blob-sha-1"}, {"lib/bar.ex", "blob-sha-2"}]}
          end,
          state_writer: fn id, state_name ->
            send(self(), {:state_write, id, state_name})
            :ok
          end,
          alert_fun: fn _, _ -> :ok end,
          enabled?: fn -> true end,
          start_paused?: true
        )

      assert state.start_paused? == true
      assert %{interval_ms: 60_000, last_seen: %{}} = state

      ReworkRequeue.tick(state)
      assert_receive {:state_write, "2337", "human-review"}
    end
  end
end
