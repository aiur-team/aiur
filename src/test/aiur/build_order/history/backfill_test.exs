defmodule Aiur.BuildOrder.History.BackfillTest do
  use ExUnit.Case, async: false
  require Aiur.TestSupport
  alias Aiur.BuildOrder.History
  alias Aiur.BuildOrder.History.{Backfill, BackfillQuery}
  alias Aiur.HistoryBackfillFixture, as: F
  @store __MODULE__.Store
  @worker __MODULE__.Worker
  @now ~U[2026-10-08 11:00:00Z]
  @opts [server: @store]

  setup do
    dir = Aiur.TestSupport.tmp_root!("history-backfill")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    clock = start_supervised!({Agent, fn -> @now end})
    %{dir: dir, clock: clock, path: Path.join(dir, "history.json")}
  end

  defp store(dir) do
    start_supervised!({History, name: @store, repository: "acme/widgets", state_dir: dir, flush_ms: 60_000}, restart: :temporary)
  end

  defp worker(ctx, responses, extra \\ []) do
    test = self()
    {:ok, queue} = Agent.start_link(fn -> responses end)

    request = fn req ->
      send(test, {:request, req})

      Agent.get_and_update(queue, fn
        [response | rest] -> {response, rest}
        [] -> {F.response(%{}), []}
      end)
    end

    opts = [
      name: @worker,
      history: @store,
      request_fun: request,
      repo_fun: fn -> {:ok, {"acme", "widgets"}} end,
      token_fun: fn -> {:ok, "test-token"} end,
      tracker_kind_fun: fn -> "github" end,
      label_prefix: "agent",
      now_fun: fn -> Agent.get(ctx.clock, & &1) end,
      schedule_fun: fn _pid, msg, delay -> send(test, {:scheduled, msg, delay}) end
    ]

    start_supervised!({Backfill, Keyword.merge(opts, extra)})

    if Keyword.get(extra, :enabled?, true) and Keyword.get(extra, :tracker_kind_fun) == nil and Keyword.get(extra, :repo_fun) == nil and Keyword.get(extra, :token_fun) == nil,
      do: assert_receive({:scheduled, :step, 60_000})
  end

  defp step(ctx, seconds \\ 10) do
    Agent.update(ctx.clock, &DateTime.add(&1, seconds, :second))
    send(@worker, :step)
    Backfill.status(@worker)
  end

  defp request(cursor, operation \\ "AiurBuildOrderHistoryBackfill") do
    assert_receive {:request, %{body: %{"query" => query, "variables" => variables}, caller: caller}}
    assert caller == "build_order_history_backfill"
    assert query =~ "query #{operation}("
    assert variables["cursor"] == cursor
    variables
  end

  defp cp(extra \\ %{}) do
    Map.merge(
      %{
        "query_version" => 1,
        "status" => "running",
        "cursor" => "c2",
        "pages" => 2,
        "issues" => 4,
        "points" => 6,
        "total" => 6,
        "started_at" => "2026-10-08T10:00:00Z",
        "completed_at" => nil,
        "root_done" => false,
        "pending_blockers" => []
      },
      extra
    )
  end

  defp seed(cp) do
    assert {:ok, _} = History.apply([], @opts ++ [checkpoint: {:backfill, cp}])
  end

  defp row(n) do
    assert {:ok, [row], _health} = History.rows([n], @opts)
    row
  end

  test "fresh walk advances cursors, tolerates a growing total and flushes reported cost", ctx do
    store(ctx.dir)

    worker(ctx, [
      F.response(F.page([F.node(1), F.node(2)], true, "c1")),
      F.response(F.page([F.node(3), F.node(4)], true, "c2", 3, 4994, 7)),
      F.response(F.page([F.node(5), F.node(6)], false, nil, 2, 4992, 7))
    ])

    assert {:running, %{pages: 1, issues: 2, points: 3}} = step(ctx, 60)
    request(nil)
    assert_receive {:scheduled, :step, 10_000}
    assert {:running, %{pages: 2}} = step(ctx)
    request("c1")
    assert_receive {:scheduled, :step, 10_000}
    assert {:complete, %{pages: 3, issues: 6, total: 7, points: 8}} = step(ctx)
    request("c2")
    assert History.health(@opts).complete?
    assert {:ok, %{"status" => "complete", "points" => 8}} = History.checkpoint(:backfill, @opts)
    disk = Jason.decode!(File.read!(ctx.path))
    assert disk["complete"] == true
    assert length(disk["rows"]) == 6
    assert disk["checkpoints"]["backfill"]["points"] == 8
    refute_received {:scheduled, :step, _delay}
  end

  test "restart resumes and preserves start watermark", ctx do
    store(ctx.dir)
    seed(cp())
    History.flush(@opts)
    stop_supervised!(@store)
    store(ctx.dir)
    worker(ctx, [F.response(F.page([F.node(5), F.node(6)]))])
    assert {:complete, %{issues: 6, pages: 3, started_at: "2026-10-08T10:00:00Z"}} = step(ctx, 60)
    request("c2")
    refute_received {:request, _req}
  end

  test "a matching complete checkpoint makes no requests", ctx do
    store(ctx.dir)
    seed(cp(%{"status" => "complete", "root_done" => true}))
    History.mark_complete(@opts)
    worker(ctx, [])
    assert {:complete, %{pages: 2}} = step(ctx, 60)
    refute_received {:request, _req}
  end

  test "query version change restarts at the first page", ctx do
    store(ctx.dir)
    seed(cp(%{"query_version" => 0, "status" => "complete"}))
    History.mark_complete(@opts)
    worker(ctx, [F.response(F.page([F.node(1)]))])
    assert {:complete, %{pages: 1, issues: 1}} = step(ctx, 60)
    request(nil)
  end

  test "raw local hold retains cursor and schedules the injected reset", ctx do
    store(ctx.dir)
    seed(cp())
    reset = DateTime.add(@now, 64, :second)
    worker(ctx, [{:error, {:aiur, :locally_held, %{reset_at: reset}}}, F.response(F.page([F.node(5)]))])
    assert {:held, %{until: ^reset, reason: :local_hold}} = step(ctx, 60)
    request("c2")
    assert_receive {:scheduled, :step, 4_000}
    assert {:held, _detail} = step(ctx, 3)
    refute_received {:request, _req}
    assert {:complete, _detail} = step(ctx, 1)
    request("c2")
  end

  test "rate limiting holds without advancing checkpoint or consuming retries", ctx do
    store(ctx.dir)
    seed(cp())
    reset = DateTime.to_unix(DateTime.add(@now, 1260, :second))
    limited = {:ok, %{status: 403, headers: [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", to_string(reset)}], body: %{}}}
    worker(ctx, [limited])
    assert {:held, %{reason: :rate_limited}} = step(ctx, 60)
    request("c2")
    assert_receive {:scheduled, :step, 1_200_000}
    assert {:ok, checkpoint} = History.checkpoint(:backfill, @opts)
    assert checkpoint == cp()
  end

  test "reported low remaining delays the next page until reset", ctx do
    store(ctx.dir)
    worker(ctx, [F.response(F.page([F.node(1)], true, "c1", 3, 900))])
    assert {:held, %{reason: :reserve, until: ~U[2026-10-08 12:00:00Z]}} = step(ctx, 60)
    request(nil)
    assert_receive {:scheduled, :step, 3_540_000}
    assert {:held, _detail} = step(ctx, 10)
    refute_received {:request, _req}
  end

  test "hourly cap stops requests until oldest spend expires", ctx do
    store(ctx.dir)
    worker(ctx, [F.response(F.page([F.node(1)], true, "c1", 150)), F.response(F.page([F.node(2)], true, "c2", 150)), F.response(F.page([F.node(3)]))])
    step(ctx, 60)
    request(nil)
    assert_receive {:scheduled, :step, 10_000}
    step(ctx)
    request("c1")
    assert_receive {:scheduled, :step, 10_000}
    assert {:held, %{reason: :hourly_point_cap}} = step(ctx)
    assert_receive {:scheduled, :step, 3_580_000}
    refute_received {:request, _req}
    assert {:complete, _detail} = step(ctx, 3580)
    request("c2")
  end

  test "permanent errors stop after one request", ctx do
    store(ctx.dir)
    worker(ctx, [{:ok, %{status: 401, headers: [], body: %{}}}])
    assert {:failed, %{reason: {:github, :auth, _detail}}} = step(ctx, 60)
    request(nil)
    refute_received {:scheduled, :step, _delay}
    assert {:failed, _detail} = step(ctx)
    refute_received {:request, _req}
    assert {:ok, nil} = History.checkpoint(:backfill, @opts)
  end

  test "partial GraphQL data is never applied and gets only three retries", ctx do
    store(ctx.dir)
    partial = F.response(Map.put(F.page([F.node(1)]), "errors", [%{"message" => "partial"}]))
    worker(ctx, List.duplicate(partial, 4))

    for seconds <- [60, 120, 120, 120] do
      status = step(ctx, seconds)
      request(nil)
      assert elem(status, 0) in [:running, :failed]
    end

    assert {:failed, %{reason: :graphql_partial}} = Backfill.status(@worker)
    assert {:ok, [], _health} = History.rows([1], @opts)
    assert {:ok, nil} = History.checkpoint(:backfill, @opts)
    assert_receive {:scheduled, :step, _delay}
    assert_receive {:scheduled, :step, _delay}
    assert_receive {:scheduled, :step, _delay}
    refute_received {:scheduled, :step, _delay}
  end

  test "unavailable history waits without claiming completeness", ctx do
    worker(ctx, [])
    assert {:waiting_for_history, %{reason: :history_not_running}} = step(ctx, 60)
    assert_receive {:scheduled, :step, 60_000}
    refute_received {:request, _req}
  end

  test "corrupt history is rebuilt and becomes available", ctx do
    File.write!(ctx.path, "{not json")
    store(ctx.dir)
    assert History.health(@opts).failure == :history_corrupt
    worker(ctx, [F.response(F.page([F.node(1)]))])
    assert {:complete, %{issues: 1}} = step(ctx, 60)
    request(nil)
    assert History.health(@opts).state == :healthy
    assert History.health(@opts).complete?
    assert row(1).title == "Ticket 1"
  end

  test "init guards never reach GitHub", ctx do
    for {extra, expected} <- [
          {[enabled?: false], {:not_applicable, %{}}},
          {[tracker_kind_fun: fn -> "linear" end], {:not_applicable, %{}}},
          {[tracker_kind_fun: fn -> raise "no config" end], {:not_applicable, %{}}},
          {[repo_fun: fn -> {:error, :missing_configured_repository} end], {:unavailable, %{reason: :missing_configured_repository}}},
          {[token_fun: fn -> {:error, :missing_github_token} end], {:unavailable, %{reason: :missing_github_token}}}
        ] do
      worker(ctx, [], extra)
      assert Backfill.status(@worker) == expected
      refute_received {:request, _req}
      refute_received {:scheduled, :step, _delay}
      stop_supervised!(@worker)
    end
  end

  test "dead process status remains unavailable" do
    assert Backfill.status(__MODULE__.Missing) == {:unavailable, %{reason: :backfill_not_running}}
  end

  test "a final flush refusal never reports completion", ctx do
    store(ctx.dir)
    File.ln_s!(Path.join(ctx.dir, "elsewhere"), ctx.path)
    worker(ctx, [F.response(F.page([F.node(1)]))])
    assert {:failed, %{reason: :history_unsafe_path}} = step(ctx, 60)
    request(nil)
    refute_received {:scheduled, :step, _delay}
  end

  test "overflow is checkpointed, survives restart and completes all blockers", ctx do
    store(ctx.dir)
    node = F.node(9, %{"blockedBy" => F.blockers(Enum.map(1..100, &F.ref/1), true, "b1")})
    worker(ctx, [F.response(F.page([node]))])
    assert {:running, _detail} = step(ctx, 60)
    request(nil)
    assert_receive {:scheduled, :step, 10_000}
    assert row(9).blocked_by_complete == false
    assert length(row(9).blocked_by) == 100
    assert :ok = History.flush(@opts)
    stop_supervised!(@worker)
    stop_supervised!(@store)
    store(ctx.dir)
    overflow = put_in(F.page([]), ["data", "repository"], %{"issue" => %{"blockedBy" => F.blockers(Enum.map(101..130, &F.ref/1))}})
    worker(ctx, [F.response(overflow)])
    assert {:complete, %{issues: 1, pages: 1, points: 6}} = step(ctx, 60)
    assert request("b1", "AiurBuildOrderHistoryBackfillBlockedBy")["number"] == 9
    assert row(9).blocked_by_complete == true
    assert length(row(9).blocked_by) == 130
    assert {:ok, %{"pending_blockers" => [], "status" => "complete"}} = History.checkpoint(:backfill, @opts)
  end

  test "page receive time preserves newer webhook title and replayed lists dedupe", ctx do
    store(ctx.dir)
    newer = %{number: 7, observed_at: DateTime.add(@now, 3600, :second), source: :webhook, fields: %{title: "webhook title", updated_at: ~U[2026-10-08 10:00:00Z]}}
    History.apply([newer], @opts)
    child = %{"__typename" => "SubIssueAddedEvent", "createdAt" => F.time(), "subIssue" => F.ref(9)}
    body = F.page([F.node(7, %{"timelineItems" => F.timeline([F.label("feature:home"), child])})])
    worker(ctx, [F.response(body)])
    assert {:complete, _detail} = step(ctx, 60)
    request(nil)
    assert row(7).title == "webhook title"
    assert row(7).label_events |> length() == 1
    assert row(7).sub_issues_added |> length() == 1
    {:ok, events, _info} = BackfillQuery.events(body, %{owner: "acme", repository: "widgets"}, "agent", DateTime.add(@now, 120, :second))
    History.apply(events, @opts)
    assert row(7).label_events |> length() == 1
    assert row(7).sub_issues_added |> length() == 1
  end

  test "failed flush stays failed across a worker-only restart", ctx do
    store(ctx.dir)
    File.ln_s!(Path.join(ctx.dir, "elsewhere"), ctx.path)
    worker(ctx, [F.response(F.page([F.node(1)]))])
    assert {:failed, %{reason: :history_unsafe_path}} = step(ctx, 60)
    request(nil)
    stop_supervised!(@worker)
    worker(ctx, [])
    assert {:failed, %{reason: :history_unsafe_path}} = step(ctx, 60)
    refute_received {:request, _req}
    File.rm!(ctx.path)
    stop_supervised!(@worker)
    worker(ctx, [])
    assert {:complete, _detail} = step(ctx, 60)
    refute_received {:request, _req}
    assert Jason.decode!(File.read!(ctx.path))["complete"] == true
  end

  test "hourly cap survives worker and store restart", ctx do
    store(ctx.dir)
    worker(ctx, [F.response(F.page([F.node(1)], true, "c1", 150)), F.response(F.page([F.node(2)], true, "c2", 150))])
    step(ctx, 60)
    request(nil)
    assert_receive {:scheduled, :step, 10_000}
    step(ctx)
    request("c1")
    assert_receive {:scheduled, :step, 10_000}
    History.flush(@opts)
    stop_supervised!(@worker)
    stop_supervised!(@store)
    store(ctx.dir)
    worker(ctx, [F.response(F.page([F.node(3)]))])
    assert {:held, %{reason: :hourly_point_cap}} = step(ctx, 60)
    assert_receive {:scheduled, :step, 3_530_000}
    refute_received {:request, _req}
    assert {:complete, %{points: 303}} = step(ctx, 3530)
    request("c2")
  end

  test "partial response spend counts even though its rows do not", ctx do
    store(ctx.dir)
    partial = F.response(Map.put(F.page([F.node(1)], false, nil, 150), "errors", [%{"message" => "partial"}]))
    worker(ctx, [partial, F.response(F.page([F.node(2)], true, "c2", 150))])
    assert {:running, _detail} = step(ctx, 60)
    request(nil)
    assert_receive {:scheduled, :step, 1_000}
    assert {:running, %{points: 300, issues: 1}} = step(ctx, 1)
    request(nil)
    assert_receive {:scheduled, :step, 10_000}
    assert {:ok, [], _health} = History.rows([1], @opts)
    assert {:held, %{reason: :hourly_point_cap}} = step(ctx)
    refute_received {:request, _req}
  end

  test "older backfill enriches unknown actors and historical signals", ctx do
    store(ctx.dir)
    label = %{label: "feature:home", action: :labeled, at: ~U[2026-10-08 10:00:00Z], actor: :unknown}

    History.apply(
      [%{number: 7, observed_at: @now, source: :webhook, fields: %{title: "new", updated_at: @now, label_events: [label]}}],
      @opts
    )

    worker(ctx, [F.response(F.page([F.node(7)]))])
    assert {:complete, _detail} = step(ctx, 60)
    request(nil)
    assert row(7).title == "new"
    assert row(7).in_progress_at == ~U[2026-10-08 10:00:00Z]
    assert Enum.find(row(7).label_events, &(&1.label == "feature:home")).actor == "kev"
    assert length(row(7).label_events) == 2
  end

  test "a page without reported cost fails instead of claiming zero spend", ctx do
    store(ctx.dir)
    body = update_in(F.page([F.node(1)]), ["data", "rateLimit"], &Map.delete(&1, "cost"))
    worker(ctx, [F.response(body)])
    assert {:failed, %{reason: :missing_reported_cost}} = step(ctx, 60)
    request(nil)
    assert {:ok, nil} = History.checkpoint(:backfill, @opts)
    assert {:ok, [], _health} = History.rows([1], @opts)
  end

  test "historical merge timestamps keep their matching PR number", ctx do
    store(ctx.dir)

    History.apply(
      [%{number: 7, observed_at: @now, source: :webhook, fields: %{updated_at: @now, merged_at: ~U[2026-05-01 10:00:00Z], pr_number: 40}}],
      @opts
    )

    closed = %{"__typename" => "ClosedEvent", "createdAt" => "2026-06-01T10:00:00Z", "closer" => %{"number" => 50, "mergedAt" => "2026-06-01T10:00:00Z"}}
    worker(ctx, [F.response(F.page([F.node(7, %{"timelineItems" => F.timeline([closed])})]))])
    assert {:complete, _detail} = step(ctx, 60)
    request(nil)
    assert row(7).merged_at == ~U[2026-06-01 10:00:00Z]
    assert row(7).pr_number == 50
  end

  test "a mismatched store waits without claiming complete", ctx do
    store(ctx.dir)
    History.apply([%{number: 1, observed_at: @now, source: :backfill, fields: %{title: "seed"}}], @opts)
    History.flush(@opts)
    stop_supervised!(@store)
    disk = Jason.decode!(File.read!(ctx.path)) |> Map.put("repository", "other/repo")
    File.write!(ctx.path, Jason.encode!(disk))
    store(ctx.dir)
    worker(ctx, [])
    assert {:waiting_for_history, %{reason: :repository_mismatch}} = step(ctx, 60)
    refute_received {:request, _req}
  end

  test "broker holds without reset retry with bounded exponential backoff", ctx do
    store(ctx.dir)
    held = {:error, {:github, :local_hold, %{reason: :github_budget_broker_timeout}}}
    worker(ctx, [held, held, F.response(F.page([F.node(1)]))])
    assert {:running, %{retry: 1}} = step(ctx, 60)
    request(nil)
    assert_receive {:scheduled, :step, 1_000}
    assert {:running, %{retry: 2}} = step(ctx, 1)
    request(nil)
    assert_receive {:scheduled, :step, 2_000}
    assert {:complete, _detail} = step(ctx, 2)
    request(nil)
  end

  test "an unchanged root cursor fails rather than looping forever", ctx do
    store(ctx.dir)
    seed(cp())
    worker(ctx, [F.response(F.page([F.node(1)], true, "c2"))])
    assert {:failed, %{reason: :invalid_backfill_page}} = step(ctx, 60)
    request("c2")
    assert {:ok, checkpoint} = History.checkpoint(:backfill, @opts)
    assert checkpoint == cp()
    refute_received {:scheduled, :step, _delay}
  end
end
