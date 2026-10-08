defmodule Aiur.BuildOrder.History.FeederTest do
  use ExUnit.Case, async: false
  require Aiur.TestSupport
  alias Aiur.BuildOrder.History
  alias Aiur.BuildOrder.History.{Feeder, Feed}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Events.GithubWebhook.Deposit
  @store __MODULE__.Store
  @tasks __MODULE__.Tasks
  @merges __MODULE__.Merges
  @t ~U[2026-10-01 12:00:00Z]
  @later ~U[2026-10-01 12:01:00Z]

  setup do
    Aiur.TestSupport.ensure_pubsub_running()
    Supervisor.terminate_child(Aiur.Supervisor, Feeder)
    if Process.whereis(ResourceStore) == nil, do: Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    dir = Aiur.TestSupport.tmp_root!("history-feeder")
    repo = "feed-#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Enum.each([:issue, :issue_labels, :issue_dependency, :sub_issue], &ResourceStore.clear(&1, "acme", repo))
      Supervisor.restart_child(Aiur.Supervisor, Feeder)
    end)

    start_supervised!({Task.Supervisor, name: @tasks})
    start_supervised!({Aiur.RecentMergeStore, name: @merges, state_dir: Path.join(dir, "merges")})
    %{dir: dir, repo: repo, full: "acme/" <> repo, opts: [server: @store]}
  end

  defp store(ctx, complete \\ false) do
    start_supervised!({History, name: @store, repository: ctx.full, state_dir: ctx.dir, flush_ms: 60_000})

    if complete do
      History.apply([], ctx.opts ++ [checkpoint: {:backfill, %{"started_at" => DateTime.to_iso8601(@t)}}])
      History.mark_complete(ctx.opts)
    end
  end

  defp feeder(ctx, extra \\ []) do
    owner = self()

    opts = [
      merge_store: @merges,
      history: @store,
      task_supervisor: @tasks,
      repo_fun: fn -> {:ok, {"acme", ctx.repo}} end,
      now_fun: fn -> @later end,
      telemetry_path: Path.join(ctx.dir, "telemetry.ndjson"),
      token_fun: fn -> {:ok, "fake"} end,
      graphql_fun: fn _, _, query, vars, options ->
        send(owner, {:graphql, query, vars, options})
        page(Keyword.get(extra, :catch_up_nodes, []))
      end
    ]

    start_supervised!({Feeder, Keyword.merge(opts, extra)})
  end

  defp page(nodes), do: {:ok, %{"data" => %{"repository" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}

  defp closed_node do
    %{
      "id" => "I_7",
      "number" => 7,
      "title" => "Recovered close",
      "state" => "CLOSED",
      "stateReason" => "COMPLETED",
      "createdAt" => DateTime.to_iso8601(@t),
      "closedAt" => DateTime.to_iso8601(@t),
      "updatedAt" => DateTime.to_iso8601(@t),
      "parent" => nil,
      "labels" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []},
      "blockedBy" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
    }
  end

  defp body(n \\ 7, extra \\ %{}),
    do:
      Map.merge(
        %{
          "number" => n,
          "title" => "Issue",
          "state" => "open",
          "state_reason" => nil,
          "created_at" => DateTime.to_iso8601(@t),
          "updated_at" => DateTime.to_iso8601(@t),
          "labels" => [%{"name" => "Agent:Todo"}]
        },
        extra
      )

  defp deposit(ctx, body), do: Deposit.deposit("issues", %{"action" => "edited", "issue" => body}, ctx.full)

  defp row(ctx, n \\ 7) do
    case History.rows([n], ctx.opts) do
      {:ok, [row], _health} -> row
      _other -> nil
    end
  end

  defp settle do
    pid = Process.whereis(Feeder)
    state = :sys.get_state(pid)

    for {timer, message} <- [{state.resource_timer, :apply_resources}, {state.merge_timer, :scan_merges}], not is_nil(timer) do
      Process.cancel_timer(timer)
      send(pid, message)
    end

    :sys.get_state(pid)

    for task <- Task.Supervisor.children(@tasks) do
      ref = Process.monitor(task)
      Aiur.TestSupport.receive_barrier({:DOWN, ^ref, :process, ^task, _reason})
    end

    :sys.get_state(pid)
    :ok
  end

  defp after_feed(fun, _attempts \\ 0) do
    settle()
    assert fun.()
  end

  test "closed delivery batches issue and labels into one change, duplicates stay quiet", ctx do
    store(ctx)
    feeder(ctx)
    settle()
    History.subscribe()
    closed = body(7, %{"state" => "closed", "state_reason" => "completed", "closed_at" => DateTime.to_iso8601(@t)})
    deposit(ctx, closed)
    after_feed(fn -> row(ctx) != nil end)
    assert row(ctx).lifecycle.state == :closed
    assert row(ctx).closed_at == @t
    assert :webhook in row(ctx).sources
    assert_receive {:build_order_history_changed, %{changed: [7]}}
    refute_received {:build_order_history_changed, %{changed: [7]}}
    generation = History.health(ctx.opts).generation
    deposit(ctx, closed)
    Feeder.catch_up_status()
    settle()
    assert History.health(ctx.opts).generation == generation
  end

  test "boot resync, telemetry and stale resync after restart", ctx do
    store(ctx)
    deposit(ctx, body())
    File.write!(Path.join(ctx.dir, "telemetry.ndjson"), Jason.encode!(%{timestamp: DateTime.to_iso8601(@t), attributes: %{event: "dispatch", boundary: "point", ticket: "7"}}))
    feeder(ctx)
    after_feed(fn -> row(ctx) && row(ctx).dispatched_at == @t end)
    assert row(ctx).title == "Issue"
    History.apply([Feed.event(7, %{title: "newer", updated_at: @later}, @later, :catch_up)], ctx.opts)
    History.flush(ctx.opts)
    stop_supervised!(Feeder)
    stop_supervised!(@store)
    store(ctx)
    feeder(ctx)
    Feeder.catch_up_status()
    assert row(ctx).title == "newer"
    assert row(ctx).updated_at == @later
  end

  test "live listings reopen, absence has unknown time, and other repositories are ignored", ctx do
    store(ctx)
    feeder(ctx)
    deposit(ctx, body())
    after_feed(fn -> row(ctx) != nil end)
    Feeder.offer_open_issues("acme", ctx.repo, [], @t)
    Feeder.catch_up_status()
    assert row(ctx).lifecycle.state == :open
    Feeder.offer_open_issues("acme", ctx.repo, [], @later)
    Feeder.catch_up_status()
    assert row(ctx).lifecycle.state == :closed
    assert row(ctx).closed_at == :unknown
    issue = %Aiur.Issue{id: "7", title: "back", labels: ["agent:todo"], updated_at: @t, created_at: @t}
    Feeder.offer_open_issues("acme", ctx.repo, [issue], @later)
    Feeder.catch_up_status()
    assert row(ctx).lifecycle.state == :open
    Feeder.offer_open_issues("other", "repo", [], @later)
    Feeder.catch_up_status()
    assert row(ctx).lifecycle.state == :open
    key = ResourceStore.key(:issue, "acme", ctx.repo, 7)
    ResourceStore.drop_data(key)
    Feeder.catch_up_status()
    assert row(ctx).lifecycle.state == :open
  end

  test "boot catch-up advances checkpoint atomically and failures preserve it", ctx do
    store(ctx, true)
    feeder(ctx, catch_up_nodes: [closed_node()])
    assert_receive {:graphql, query, vars, options}
    assert query =~ "states:[CLOSED]"
    assert vars["since"] == DateTime.to_iso8601(@t)
    assert options[:caller] == "build_history_catch_up"
    after_feed(fn -> Feeder.catch_up_status().status == :ok end)
    assert {:ok, checkpoint} = History.checkpoint(:closed_since, ctx.opts)
    assert checkpoint["watermark"] == DateTime.to_iso8601(@later)
    assert row(ctx).title == "Recovered close"
    assert row(ctx).closed_at == @t
    assert row(ctx).lifecycle.state == :closed
    stop_supervised!(Feeder)

    feeder(ctx,
      graphql_fun: fn _, _, _, vars, _ ->
        send(self(), vars)
        {:error, :timeout}
      end
    )

    after_feed(fn -> Feeder.catch_up_status().status == :failed end)
    assert Feeder.catch_up_status().reason == {:github, :timeout, %{reason: :timeout}}
    assert Feeder.catch_up_status().at == @later
    assert {:ok, failed} = History.checkpoint(:closed_since, ctx.opts)
    assert failed["watermark"] == checkpoint["watermark"]
    assert failed["status"] == "failed"
  end

  test "pending backfill and missing floor never request or report ok", ctx do
    store(ctx)
    feeder(ctx)
    status = Feeder.catch_up_status()
    assert status.status == :not_backfilled
    assert status.at == @later
    refute_received {:graphql, _, _, _}
    History.mark_complete(ctx.opts)
    after_feed(fn -> Feeder.catch_up_status().reason == :no_floor end)
    assert Feeder.catch_up_status().status == :not_backfilled
    refute_received {:graphql, _, _, _}
    History.apply([], ctx.opts ++ [checkpoint: {:backfill, %{"started_at" => DateTime.to_iso8601(@t)}}])
    send(Process.whereis(Feeder), {:webhook_recovered, ctx.full})
    assert_receive {:graphql, _, _, _}
    after_feed(fn -> Feeder.catch_up_status().status == :ok end)
  end

  test "backfill completion triggers recovery; repeated signals coalesce at the hourly window", ctx do
    store(ctx)
    History.apply([], ctx.opts ++ [checkpoint: {:backfill, %{"started_at" => DateTime.to_iso8601(@t)}}])
    pid = feeder(ctx)
    Feeder.catch_up_status()
    History.mark_complete(ctx.opts)
    assert_receive {:graphql, _, _, _}
    after_feed(fn -> Feeder.catch_up_status().status == :ok end)
    send(pid, {:webhook_degraded, ctx.full})
    send(pid, {:view_state_diverged, "other/repo"})
    send(pid, {:webhook_recovered, String.upcase(ctx.full)})
    send(pid, {:view_state_diverged, ctx.full})
    Feeder.catch_up_status()
    state = :sys.get_state(pid)
    assert state.pending?
    assert is_reference(state.window_timer)
    timer = state.window_timer
    send(pid, {:view_state_diverged, ctx.full})
    Feeder.catch_up_status()
    assert :sys.get_state(pid).window_timer == timer
    refute_received {:graphql, _, _, _}
    Process.cancel_timer(timer)
    # Advance only the monotonic window boundary; the trigger and scheduling paths are real.
    :sys.replace_state(pid, &%{&1 | last_start: System.monotonic_time(:millisecond) - 3_600_001})
    send(pid, :catch_up_window)
    assert_receive {:graphql, _, _, _}
  end

  test "task crash reports failed and not-running is explicit", ctx do
    store(ctx, true)
    feeder(ctx, graphql_fun: fn _, _, _, _, _ -> exit(:query_crashed) end)
    after_feed(fn -> Feeder.catch_up_status().status == :failed end)
    assert Feeder.catch_up_status().reason == {:task_down, :query_crashed}
    stop_supervised!(Feeder)
    assert Feeder.catch_up_status() == {:error, :not_running}
  end

  test "unsupported store refuses once per reason and feeder survives", ctx do
    File.write!(Path.join(ctx.dir, "history.json"), Jason.encode!(%{"version" => 3}))
    store(ctx)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = feeder(ctx)
        Feeder.catch_up_status()
        deposit(ctx, body())
        settle()
        deposit(ctx, body(8))
        settle()
        assert Process.alive?(pid)
      end)

    # Boot and repeated live deliveries share one refusal log.
    assert length(Regex.scan(~r/apply_refused reason=:version_unsupported/, log)) == 1
    assert {:error, %{failure: :version_unsupported}} = History.rows([7], ctx.opts)
    refute_received {:graphql, _, _, _}
  end

  test "live dependency and membership deposits update full sets and record the original join", ctx do
    store(ctx)
    History.apply([Feed.event(7, %{blocked_by: []}, @t, :backfill)], ctx.opts)
    pid = feeder(ctx)
    Feeder.catch_up_status()
    edge = %{"action" => "blocked_by_added", "blocked_issue_number" => 7, "blocking_issue_number" => 2}
    Deposit.deposit("issue_dependencies", edge, ctx.full, at: @t)
    after_feed(fn -> row(ctx).blocked_by == [Feed.ref(ctx.full, 2)] end)
    Deposit.deposit("issue_dependencies", %{edge | "action" => "blocked_by_removed"}, ctx.full, at: @later)
    after_feed(fn -> row(ctx).blocked_by == [] end)
    Deposit.deposit("issue_dependencies", edge, ctx.full, at: @t)
    Feeder.catch_up_status()
    assert row(ctx).blocked_by == []
    sub = %{"action" => "sub_issue_added", "parent_issue_number" => 1, "sub_issue_number" => 7}
    Deposit.deposit("sub_issues", sub, ctx.full, at: @t)
    after_feed(fn -> row(ctx).parent == Feed.ref(ctx.full, 1) end)
    assert row(ctx, 1).sub_issues_added == [%{ref: Feed.ref(ctx.full, 7), at: @t}]
    Deposit.deposit("sub_issues", %{sub | "action" => "sub_issue_removed"}, ctx.full, at: @later)
    after_feed(fn -> row(ctx).parent == :none end)
    stop_supervised!(Feeder)
    feeder(ctx)
    Feeder.catch_up_status()
    assert row(ctx, 1).sub_issues_added == [%{ref: Feed.ref(ctx.full, 7), at: @t}]
    assert not Process.alive?(pid)
  end

  test "restart refuses persisted edges older than catch-up facts", ctx do
    store(ctx)
    sub = %{"action" => "sub_issue_added", "parent_issue_number" => 1, "sub_issue_number" => 7}
    edge = %{"action" => "blocked_by_added", "blocked_issue_number" => 7, "blocking_issue_number" => 2}
    Deposit.deposit("sub_issues", sub, ctx.full, at: @t)
    Deposit.deposit("issue_dependencies", edge, ctx.full, at: @t)
    History.apply([Feed.event(7, %{parent: :none, parent_version: DateTime.to_iso8601(@later), blocked_by: [], blocked_by_version: DateTime.to_iso8601(@later)}, @later, :catch_up)], ctx.opts)
    History.flush(ctx.opts)
    stop_supervised!(@store)
    store(ctx)
    feeder(ctx)
    settle()
    assert row(ctx).parent == :none
    assert row(ctx).blocked_by == []
  end

  test "recent merge notifications coalesce and project only matching repository tickets", ctx do
    store(ctx)
    pid = feeder(ctx)

    for {repo, n, at} <- [{ctx.full, 10, @t}, {ctx.full, 11, @later}, {"other/repo", 12, @later}] do
      pull = %{
        "number" => n,
        "title" => "Merge",
        "html_url" => "https://github.com/#{repo}/pull/#{n}",
        "merged_at" => DateTime.to_iso8601(at),
        "head" => %{"ref" => "aiur/7-feed", "sha" => String.duplicate("a", 40)}
      }

      assert {:ok, merge} =
               Aiur.RecentMerge.from_github_event(%{"type" => "PullRequestEvent", "repo" => %{"name" => repo}, "payload" => %{"action" => "closed", "pull_request" => Map.put(pull, "merged", true)}})

      assert {:ok, %{status: :accepted}} = Aiur.RecentMergeStore.upsert(merge, @merges)
    end

    Feeder.catch_up_status()
    timer = :sys.get_state(pid).merge_timer
    assert is_reference(timer)
    send(pid, {:observability_updated, "extra"})
    Feeder.catch_up_status()
    assert :sys.get_state(pid).merge_timer == timer
    after_feed(fn -> row(ctx) && row(ctx).merged_at == @later end, 200)
    assert row(ctx).pr_number == 11
  end

  test "rebuilding store accepts live bodies while catch-up stays unavailable", ctx do
    File.write!(Path.join(ctx.dir, "history.json"), "corrupt")
    store(ctx)
    feeder(ctx)
    deposit(ctx, body())

    after_feed(fn ->
      assert {:error, %{failure: :history_corrupt}} = History.snapshot(ctx.opts)
      :ets.lookup(Module.concat(@store, Mirror), 7) != []
    end)

    assert Feeder.catch_up_status().status == :not_backfilled
    refute_received {:graphql, _, _, _}
    History.mark_complete(ctx.opts)
    assert row(ctx).title == "Issue"
  end

  test "no steady-state GitHub polling (future regression guard)", ctx do
    store(ctx, true)
    feeder(ctx)
    assert_receive {:graphql, _, _, _}
    after_feed(fn -> Feeder.catch_up_status().status == :ok end)
    for n <- 1..100, do: deposit(ctx, body(n))
    for _ <- 1..10, do: Feeder.offer_open_issues("acme", ctx.repo, [], @later)
    after_feed(fn -> row(ctx, 100) != nil end)
    refute_received {:graphql, _, _, _}
  end
end
