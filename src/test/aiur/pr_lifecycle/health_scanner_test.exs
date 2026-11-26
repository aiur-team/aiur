defmodule Aiur.PRLifecycle.HealthScannerTest do
  use Aiur.TestSupport
  import ExUnit.CaptureLog

  alias Aiur.GitHub.LocalHold
  alias Aiur.PRLifecycle.HealthScanner

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
      local_hold_opts: LocalHold.caller_opts(opts),
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

      {flagged, _stale} = HealthScanner.evaluate([unmergeable, agent_pr], @stale_hours, @now, ["its-everdred"])

      assert [^unmergeable] = flagged
    end

    test "flags non-draft PRs older than the threshold" do
      old = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})
      recent = pr(2148, %{"created_at" => "2026-08-22T21:00:00Z"})
      draft = pr(2149, %{"created_at" => "2026-08-18T00:00:00Z", "draft" => true})

      {_unmergeable, stale} = HealthScanner.evaluate([old, recent, draft], @stale_hours, @now, ["its-everdred"])

      assert [^old] = stale
    end

    test "skips a PR whose branch names another instance's ticket (#5803)" do
      path = Workflow.workflow_file_path()
      write_workflow_file!(path)
      write_workflow_file_atomic!(path, File.read!(path) <> "\ninstance:\n  ignore:\n    tickets: [4121]\n")
      :ok = Aiur.WorkflowStore.force_reload()
      native = pr(2152, %{"created_at" => "2026-08-18T00:00:00Z", "head" => %{"ref" => "aiur/2152-native"}, "user" => %{"login" => "its-everdred"}})
      foreign = pr(2153, %{"created_at" => "2026-08-18T00:00:00Z", "head" => %{"ref" => "aiur/4121-foreign"}, "user" => %{"login" => "its-everdred"}})

      assert {[^native], [^native]} = HealthScanner.evaluate([native, foreign], @stale_hours, @now, ["its-everdred"])
    end

    test "flags a PR exactly at the threshold" do
      boundary = pr(2150, %{"created_at" => "2026-08-21T22:00:00Z"})

      {_unmergeable, stale} = HealthScanner.evaluate([boundary], @stale_hours, @now, [])

      assert [^boundary] = stale
    end

    test "does not flag a PR just under the threshold" do
      under = pr(2151, %{"created_at" => "2026-08-21T22:00:01Z"})

      {_unmergeable, stale} = HealthScanner.evaluate([under], @stale_hours, @now, [])

      assert stale == []
    end

    test "ignores PRs with no usable number" do
      numbered_unmergeable = pr(2180, %{"user" => %{"login" => "its-everdred"}})
      numbered_stale = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})

      {unmergeable, stale} =
        HealthScanner.evaluate(
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

      state = HealthScanner.tick(state)
      assert_receive {:alert, "system.pr_health.unmergeable_author"}, 1000
      assert_receive {:comment, :ok}, 1000

      # Second tick: deduped — no new alert or comment.
      HealthScanner.tick(state)
      refute_receive {:alert, _}, 100
      refute_receive {:comment, _}, 100
      assert :atomics.get(alerts, 1) == 1
      assert :atomics.get(comments, 1) == 1
    end

    test "does not flag an agent-authored PR" do
      agent_pr = pr(2181, %{"user" => %{"login" => "its-applekid"}})

      state = base_state(open_prs_fetcher: fn -> {:ok, [agent_pr]} end)

      state = HealthScanner.tick(state)
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

      state = HealthScanner.tick(state)
      assert_receive {:alert, "system.pr_health.stale_unreviewed"}, 1000

      HealthScanner.tick(state)
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

      state = HealthScanner.tick(state)
      refute_receive {:alert, _}, 100
      assert state.alerted == MapSet.new()
    end

    test "retries an expired local hold on reviews lookup without logging a failure" do
      stale = pr(2147, %{"created_at" => "2026-08-18T00:00:00Z"})
      parent = self()

      hold = %{
        reason: :shared_budget,
        resource: "core",
        reset_at: DateTime.add(DateTime.utc_now(), -1, :second)
      }

      error =
        {:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}

      state =
        base_state(
          open_prs_fetcher: fn -> {:ok, [stale]} end,
          reviews_fetcher: fn 2147 ->
            attempt = Process.get(:reviews_attempt, 0) + 1
            Process.put(:reviews_attempt, attempt)
            send(parent, {:reviews_attempt, attempt})
            if attempt == 1, do: error, else: {:ok, [%{"state" => "APPROVED"}]}
          end,
          local_hold_sleep_fun: fn _ms -> flunk("expired hold must retry without sleeping") end
        )

      log =
        capture_log(fn ->
          state = HealthScanner.tick(state)
          send(parent, {:scanner_state, state})
        end)

      assert_receive {:reviews_attempt, 1}, 1_000
      assert_receive {:reviews_attempt, 2}, 1_000
      assert_receive {:scanner_state, %{reviewed: reviewed}}, 1_000
      assert MapSet.member?(reviewed, 2147)
      refute log =~ "PRHealthScanner stale-PR reviews fetch failed"
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

      state = HealthScanner.tick(state)
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

      state = HealthScanner.tick(state)
      assert :atomics.get(reviews_reads, 1) == 1
      assert MapSet.member?(state.reviewed, 2147)
      refute_receive {:alert, _}, 100

      # The candidate is still open and still stale, but the review is known —
      # no second reviews read.
      HealthScanner.tick(state)
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

      HealthScanner.tick(state)
      assert_receive {:alert_opts, opts}, 1000

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
        HealthScanner.init(
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

      HealthScanner.tick(state)
      assert_receive {:alert, "system.pr_health.stale_unreviewed"}, 1000
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

      result = HealthScanner.tick(state)

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
        |> HealthScanner.tick()

      assert MapSet.member?(state.alerted, {:stale_unreviewed, 2147})

      # The PR is merged/closed on the next scan; its dedup entry is forgotten.
      closed_state = %{state | open_prs_fetcher: fn -> {:ok, []} end}
      pruned = HealthScanner.tick(closed_state)

      refute MapSet.member?(pruned.alerted, {:stale_unreviewed, 2147})
    end
  end
end
