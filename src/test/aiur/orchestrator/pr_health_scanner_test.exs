defmodule Aiur.Orchestrator.PRHealthScannerTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.PRHealthScanner

  @now ~U[2026-08-22 22:00:00Z]
  @stale_hours 24

  defp pr(number, overrides) do
    Map.merge(
      %{
        "number" => number,
        "title" => "PR ##{number}",
        "state" => "open",
        "draft" => false,
        # Recent by default (1h before @now) so a PR is not inadvertently a
        # stale-unreviewed candidate in tests that only exercise another cause.
        "created_at" => "2026-08-22T21:00:00Z",
        "user" => %{"login" => "its-applekid"}
      },
      overrides
    )
  end

  defp base_state(opts) do
    %{
      interval_ms: 60_000,
      stale_hours: Keyword.get(opts, :stale_hours, @stale_hours),
      open_prs_fetcher: Keyword.get(opts, :open_prs_fetcher, fn -> {:ok, []} end),
      reviews_fetcher: Keyword.get(opts, :reviews_fetcher, fn _ -> {:ok, []} end),
      human_mergers_fun: Keyword.get(opts, :human_mergers_fun, fn -> ["its-everdred"] end),
      comment_fun: Keyword.get(opts, :comment_fun, fn _, _ -> :ok end),
      alert_fun: Keyword.get(opts, :alert_fun, fn _, _ -> :ok end),
      enabled?: Keyword.get(opts, :enabled?, fn -> true end),
      now_fun: Keyword.get(opts, :now_fun, fn -> @now end),
      alerted: MapSet.new(),
      commented: MapSet.new(),
      reviewed: MapSet.new(),
      start_paused?: true
    }
  end

  describe "evaluate/4" do
    test "flags open PRs authored by a configured human merger" do
      unmergeable = pr(2180, %{"user" => %{"login" => "its-everdred"}})
      agent_pr = pr(2181, %{"user" => %{"login" => "its-applekid"}})

      {flagged, _stale} = PRHealthScanner.evaluate([unmergeable, agent_pr], @stale_hours, @now, ["its-everdred"])

      assert [^unmergeable] = flagged
    end

    test "flags non-draft PRs older than the threshold" do
      old = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})
      recent = pr(2148, %{"created_at" => "2026-08-22T21:00:00Z"})
      draft = pr(2149, %{"created_at" => "2026-08-18T00:00:00Z", "draft" => true})

      {_unmergeable, stale} = PRHealthScanner.evaluate([old, recent, draft], @stale_hours, @now, ["its-everdred"])

      assert [^old] = stale
    end

    test "flags a PR exactly at the threshold" do
      boundary = pr(2150, %{"created_at" => "2026-08-21T22:00:00Z"})

      {_unmergeable, stale} = PRHealthScanner.evaluate([boundary], @stale_hours, @now, [])

      assert [^boundary] = stale
    end

    test "does not flag a PR just under the threshold" do
      under = pr(2151, %{"created_at" => "2026-08-21T22:00:01Z"})

      {_unmergeable, stale} = PRHealthScanner.evaluate([under], @stale_hours, @now, [])

      assert stale == []
    end

    test "ignores PRs with no usable number" do
      numbered_unmergeable = pr(2180, %{"user" => %{"login" => "its-everdred"}})
      numbered_stale = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})

      {unmergeable, stale} =
        PRHealthScanner.evaluate(
          [numbered_unmergeable, numbered_stale, %{"state" => "open"}, %{"number" => nil, "state" => "open"}],
          @stale_hours,
          @now,
          ["its-everdred"]
        )

      assert unmergeable == [numbered_unmergeable]
      assert stale == [numbered_stale]
    end
  end

  describe "tick/1 unmergeable-author flagging (cause 1)" do
    test "alerts and comments on a human-merger-authored PR, once" do
      unmergeable = pr(2180, %{"user" => %{"login" => "its-everdred"}})
      alerts = :atomics.new(1, [])
      comments = :atomics.new(1, [])

      state =
        base_state(
          open_prs_fetcher: fn -> {:ok, [unmergeable]} end,
          alert_fun: fn name, _opts ->
            :atomics.add(alerts, 1, 1)
            send(self(), {:alert, name})
            :ok
          end,
          comment_fun: fn _id, _body ->
            :atomics.add(comments, 1, 1)
            send(self(), {:comment, :ok})
            :ok
          end
        )

      state = PRHealthScanner.tick(state)
      assert_receive {:alert, "system.pr_health.unmergeable_author"}
      assert_receive {:comment, :ok}

      # Second tick: deduped — no new alert or comment.
      PRHealthScanner.tick(state)
      refute_receive {:alert, _}, 100
      refute_receive {:comment, _}, 100
      assert :atomics.get(alerts, 1) == 1
      assert :atomics.get(comments, 1) == 1
    end

    test "does not flag an agent-authored PR" do
      agent_pr = pr(2181, %{"user" => %{"login" => "its-applekid"}})

      state = base_state(open_prs_fetcher: fn -> {:ok, [agent_pr]} end)

      state = PRHealthScanner.tick(state)
      assert state.alerted == MapSet.new()
      assert state.commented == MapSet.new()
    end
  end

  describe "tick/1 ageing-unreviewed flagging (cause 3)" do
    test "alerts on a stale non-draft PR with no review, once" do
      stale = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})
      alerts = :atomics.new(1, [])

      state =
        base_state(
          open_prs_fetcher: fn -> {:ok, [stale]} end,
          reviews_fetcher: fn _number -> {:ok, []} end,
          alert_fun: fn name, _opts ->
            :atomics.add(alerts, 1, 1)
            send(self(), {:alert, name})
            :ok
          end
        )

      state = PRHealthScanner.tick(state)
      assert_receive {:alert, "system.pr_health.stale_unreviewed"}

      PRHealthScanner.tick(state)
      refute_receive {:alert, _}, 100
      assert :atomics.get(alerts, 1) == 1
    end

    test "does not alert a stale PR that already has a review" do
      stale = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})

      state =
        base_state(
          open_prs_fetcher: fn -> {:ok, [stale]} end,
          reviews_fetcher: fn _number -> {:ok, [%{"state" => "APPROVED"}]} end,
          alert_fun: fn name, _opts ->
            send(self(), {:alert, name})
            :ok
          end
        )

      state = PRHealthScanner.tick(state)
      refute_receive {:alert, _}, 100
      assert state.alerted == MapSet.new()
    end

    test "does not alert a recent PR" do
      recent = pr(2148, %{"created_at" => "2026-08-22T21:00:00Z"})

      state =
        base_state(
          open_prs_fetcher: fn -> {:ok, [recent]} end,
          alert_fun: fn name, _opts ->
            send(self(), {:alert, name})
            :ok
          end
        )

      state = PRHealthScanner.tick(state)
      refute_receive {:alert, _}, 100
      assert state.alerted == MapSet.new()
    end

    test "a reviewed candidate is memoised and never pays a reviews read again" do
      stale = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})
      reviews_reads = :atomics.new(1, [])

      state =
        base_state(
          open_prs_fetcher: fn -> {:ok, [stale]} end,
          reviews_fetcher: fn _number ->
            :atomics.add(reviews_reads, 1, 1)
            {:ok, [%{"state" => "APPROVED"}]}
          end,
          alert_fun: fn name, _opts ->
            send(self(), {:alert, name})
            :ok
          end
        )

      state = PRHealthScanner.tick(state)
      assert :atomics.get(reviews_reads, 1) == 1
      assert MapSet.member?(state.reviewed, 2147)
      refute_receive {:alert, _}, 100

      # The candidate is still open and still stale, but the review is known —
      # no second reviews read.
      PRHealthScanner.tick(state)
      assert :atomics.get(reviews_reads, 1) == 1
    end

    test "renders the age the decision used, not a re-read clock" do
      stale = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})

      state =
        base_state(
          open_prs_fetcher: fn -> {:ok, [stale]} end,
          reviews_fetcher: fn _number -> {:ok, []} end,
          alert_fun: fn _name, opts ->
            send(self(), {:alert_opts, opts})
            :ok
          end
        )

      PRHealthScanner.tick(state)
      assert_receive {:alert_opts, opts}

      # stale.created_at is 2026-08-18T00:00:00Z and the injected now is
      # 2026-08-22T22:00:00Z (~4.9 days), so the rendered age must be 118 hours,
      # not a number that depends on when the test process happened to run.
      assert Keyword.get(opts, :message) =~ "open 118 hours with no review"
    end
  end

  describe "init/1 wiring" do
    test "init wires injected fns and the first tick scans with them" do
      stale = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})

      {:ok, state} =
        PRHealthScanner.init(
          interval_ms: 60_000,
          stale_hours: 24,
          open_prs_fetcher: fn -> {:ok, [stale]} end,
          reviews_fetcher: fn _ -> {:ok, []} end,
          human_mergers_fun: fn -> [] end,
          comment_fun: fn _, _ -> :ok end,
          alert_fun: fn name, _opts ->
            send(self(), {:alert, name})
            :ok
          end,
          enabled?: fn -> true end,
          start_paused?: true
        )

      assert state.start_paused? == true
      assert %{interval_ms: 60_000, stale_hours: 24, alerted: alerted} = state
      assert alerted == MapSet.new()

      PRHealthScanner.tick(state)
      assert_receive {:alert, "system.pr_health.stale_unreviewed"}
    end
  end

  describe "tick/1 disabled / non-GitHub tracker" do
    test "no-ops when the feature is disabled" do
      fetched = :atomics.new(1, [])

      state =
        base_state(
          enabled?: fn -> false end,
          open_prs_fetcher: fn ->
            :atomics.add(fetched, 1, 1)
            {:ok, []}
          end
        )

      result = PRHealthScanner.tick(state)

      # The scan must not touch GitHub when disabled.
      assert :atomics.get(fetched, 1) == 0
      assert result.alerted == MapSet.new()
      assert result.commented == MapSet.new()
    end
  end

  describe "prune_resolved" do
    test "drops dedup for a PR that is no longer in the open list" do
      stale = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})

      state =
        base_state(
          open_prs_fetcher: fn -> {:ok, [stale]} end,
          reviews_fetcher: fn _ -> {:ok, []} end,
          alert_fun: fn _, _ -> :ok end
        )
        |> PRHealthScanner.tick()

      assert MapSet.member?(state.alerted, {:stale_unreviewed, 2147})

      # The PR is merged/closed on the next scan; its dedup entry is forgotten.
      closed_state = %{state | open_prs_fetcher: fn -> {:ok, []} end}
      pruned = PRHealthScanner.tick(closed_state)

      refute MapSet.member?(pruned.alerted, {:stale_unreviewed, 2147})
    end
  end
end
