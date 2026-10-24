defmodule Aiur.Experiments.Packs.DeliverySpeedTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Catalog, Evaluator}
  alias Aiur.Experiments.Packs.DeliverySpeed
  alias Aiur.RunTelemetry.{Dataset, Summaries, SummaryReader}

  @fixtures Path.expand("../../../fixtures/experiments/telemetry", __DIR__)
  @window %{start: ~U[2026-10-09 09:00:00Z], end: ~U[2026-10-09 14:00:00Z]}

  defp context do
    {:ok, prior} = Dataset.build(Path.join(@fixtures, "boot-a.ndjson"))
    path = Path.join(System.tmp_dir!(), "delivery-summary-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(Aiur.JSONSafe.normalize(prior)))
    on_exit(fn -> File.rm!(path) end)
    {:ok, decoded} = SummaryReader.read(path)
    assert Enum.count(decoded["records"], &(&1["kind"] == "resource")) == 1
    {:ok, prior} = decoded |> Jason.encode!() |> Summaries.decode_summary()

    %{
      telemetry_enabled: true,
      boot_id: "boot-b",
      telemetry_path: Path.join(@fixtures, "boot-b.ndjson"),
      prior_loader: fn "boot-b" -> {[prior], false} end
    }
  end

  defp result(id, ctx \\ context(), window \\ @window) do
    {coverage, observations} = DeliverySpeed.observations([id], window, ctx)[id]
    %{coverage: coverage, observations: observations}
  end

  defp ticket(rows, number), do: Enum.find(rows, &(&1.unit_id == "ticket:#{number}"))

  test "default catalog exposes delivery metrics with kinds and groups, and disabling removes them" do
    ctx = %{repo_path: @fixtures, pack_dirs: []}
    metrics = Catalog.load(ctx).metrics
    assert map_size(metrics) == 26
    assert MapSet.new(metrics, fn {_ref, metric} -> metric.group end) == MapSet.new(~w(flow review throughput cost_quality ci_stability))
    assert metrics["delivery-speed/start_to_merge"].kind == "duration"
    assert metrics["delivery-speed/review_rounds"].kind == "count"
    assert metrics["delivery-speed/merged_per_hour"].kind == "bucketed"
    assert metrics["delivery-speed/binding_gate"].kind == "rate"
    assert metrics["delivery-speed/binding_gate"].default_direction == "none"
    assert Catalog.load(Map.put(ctx, :disabled_packs, ["delivery-speed"])).metrics == %{}
    output = ExUnit.CaptureIO.capture_io(fn -> assert Aiur.ExperimentsCLI.run(verb: :metrics, argv: []) == 0 end)
    listed = Jason.decode!(output)["metrics"]

    for metric <- DeliverySpeed.metrics() do
      assert listed["delivery-speed/" <> metric.id]["kind"] == metric.kind
      assert listed["delivery-speed/" <> metric.id]["group"] == metric.group
      assert listed["delivery-speed/" <> metric.id]["unit"] == metric.unit
      assert listed["delivery-speed/" <> metric.id]["unit_of_analysis"] == metric.unit_of_analysis
      assert listed["delivery-speed/" <> metric.id]["default_direction"] == metric.default_direction
    end
  end

  test "cross-boot ticket is counted once and every ticket metric retains the first dispatch and cohort" do
    row = result("start_to_merge")
    assert Enum.count(row.observations, &(&1.unit_id == "ticket:101")) == 1
    observation = ticket(row.observations, 101)
    assert observation.value == 9_000_000
    assert observation.at == ~U[2026-10-09 10:00:00Z]
    assert observation.attrs["complexity"] == 3
    assert observation.attrs["backend"] == "codex"
    assert observation.attrs["epic"] == "epic-a"
    assert observation.attrs["feature_tags"] == ["shipping"]
    assert observation.attrs["tags"] == %{"trial" => "A"}
    assert observation.attrs["aiur_version"] == "0.0.99"
    assert observation.attrs["config_hash"] == "abc"
    assert observation.attrs["finished_at"] == "2026-10-09T12:30:00Z"
    refute observation.attrs["censored"]
    assert row.coverage.filtered == 1
    refute ticket(row.observations, 103)
  end

  for {id, expected} <- [
        {"start_to_pr_open", 1_800_000},
        {"pr_open_to_merge", 7_200_000},
        {"blocker_merge_to_dependent_start", 120_000},
        {"gap_between_prs", 9_120_000},
        {"pr_ready_to_first_review", 600_000},
        {"review_rounds", 3},
        {"rework_time", 1_800_000}
      ] do
    test "fixture calculates #{id}" do
      output = result(unquote(id))
      assert output.coverage.state == if(unquote(id) in ~w(start_to_pr_open pr_open_to_merge pr_ready_to_first_review), do: :partial, else: :captured)
      assert ticket(output.observations, 101).value == unquote(expected)
      assert ticket(output.observations, 101).at == ~U[2026-10-09 10:00:00Z]
    end
  end

  test "window cuts off later boot events without reassigning redispatched tickets" do
    output = result("start_to_merge", context(), %{@window | end: ~U[2026-10-09 11:00:00Z]})
    refute ticket(output.observations, 101)
    assert ticket(output.observations, 102).value == 2_400_000
    output = result("start_to_merge", context(), %{@window | start: ~U[2026-10-09 11:00:00Z]})
    refute ticket(output.observations, 101)
  end

  test "active hours include zero merges, idle hours are omitted, and utilization uses the configured cap" do
    output = result("merged_per_hour")
    assert Enum.map(output.observations, & &1.value) == [2, 0]
    assert Enum.map(output.observations, & &1.unit_id) == ["hour:2026-10-09T10:00:00Z", "hour:2026-10-09T11:00:00Z"]
    assert Enum.map(result("agents_vs_cap").observations, & &1.value) == [0.75, 0.75]
    assert output.coverage.filtered == 3
  end

  for {id, fact} <- [{"ci_wait", "ci_wait"}, {"idle_slot_hours", "ready_queue_depth"}, {"binding_gate", "gate_reason"}, {"main_red_events", "main_red"}, {"reverts", "reverts"}] do
    test "#{id} reports its uncaptured fact instead of a zero" do
      output = result(unquote(id))
      assert output.coverage == %{state: :not_captured, missing: [unquote(fact)]}
      assert output.observations == []
    end
  end

  test "legacy telemetry cannot claim PR-open, blockers, epic or reviewer capture" do
    {:ok, legacy} = Dataset.build(Path.join(@fixtures, "boot-b.ndjson"))
    records = Enum.map(legacy.records, &Map.update!(&1, :attributes, fn attrs -> Map.drop(attrs, ~w(source_timestamp source blockers epic review_thread_id)) end))
    {actors, tickets, findings} = Dataset.reduce(records)
    legacy = Map.merge(legacy, %{records: records, actors: actors, tickets: tickets, findings: findings})
    ctx = %{context() | telemetry_path: Path.join(@fixtures, "missing.ndjson"), prior_loader: fn _ -> {[legacy], false} end}

    for id <- ~w(start_to_pr_open pr_open_to_merge blocker_merge_to_dependent_start gap_between_prs pr_ready_to_first_review) do
      assert result(id, ctx).coverage.state == :not_captured
      assert result(id, ctx).observations == []
    end
  end

  test "disabled and missing telemetry are unavailable through the evaluator" do
    ctx = Map.merge(context(), %{repo_path: @fixtures, pack_dirs: [], telemetry_enabled: false})
    ref = "delivery-speed/start_to_merge"
    assert Evaluator.observations([ref], @window, ctx)[ref] == %{coverage: %{state: :unavailable, reason: :telemetry_disabled}, observations: []}
    ctx = %{context() | telemetry_path: Path.join(@fixtures, "missing.ndjson"), prior_loader: fn _ -> {[], false} end}
    assert result("start_to_merge", ctx) == %{coverage: %{state: :unavailable, reason: :telemetry_missing}, observations: []}
  end

  test "missing workflow-run rows are unavailable while job metrics remain usable" do
    ctx =
      Map.merge(context(), %{
        github_window: %{
          "required_workflows" => [],
          "runs" => [],
          "jobs" => [%{"id" => 1, "name" => "test", "created_at" => "2026-10-09T10:00:00Z", "started_at" => "2026-10-09T10:02:00Z"}],
          "pulls" => [],
          "incidents" => []
        },
        landing_watch_state_fun: fn _opts -> {:ok, %{}} end
      })

    assert result("ci_run_failure_rate", ctx) == %{coverage: %{state: :unavailable, reason: :github_unavailable}, observations: []}
    job_wait = result("ci_queue_wait", ctx)
    assert job_wait.coverage.state in [:captured, :partial]
    assert [%{value: 120_000}] = job_wait.observations
  end

  test "missing landing-watch journal makes flaky failure rate unavailable" do
    ctx =
      Map.merge(context(), %{
        github_window: %{
          "required_workflows" => ["CI"],
          "runs" => [%{"id" => 1, "name" => "CI", "event" => "merge_group", "conclusion" => "failure", "updated_at" => "2026-10-09T12:00:00Z"}],
          "jobs" => [],
          "pulls" => [],
          "incidents" => []
        },
        landing_watch_state_fun: fn _opts -> {:error, :journal_unavailable} end
      })

    assert result("flaky_failure_rate", ctx) == %{
             coverage: %{state: :unavailable, reason: :landing_watch_journal_unavailable},
             observations: []
           }
  end

  test "sampled GitHub job details make flaky failure coverage partial" do
    ctx =
      Map.merge(context(), %{
        github_window: %{
          "required_workflows" => ["CI"],
          "runs" => [%{"id" => 1, "name" => "CI", "event" => "merge_group", "conclusion" => "failure", "updated_at" => "2026-10-09T12:00:00Z"}],
          "jobs" => [
            %{
              "id" => 1,
              "run_id" => 1,
              "name" => "test",
              "conclusion" => "failure",
              "created_at" => "2026-10-09T10:00:00Z",
              "started_at" => "2026-10-09T10:01:00Z",
              "completed_at" => "2026-10-09T12:00:00Z"
            }
          ],
          "jobs_partial" => true,
          "pulls" => [],
          "incidents" => []
        },
        landing_watch_state_fun: fn _opts -> {:ok, %{"failure_observations" => []}} end
      })

    coverage = result("flaky_failure_rate", ctx).coverage
    assert coverage.state == :partial
    assert coverage.reason == :github_source_incomplete
  end

  test "corrupt retained summaries and pruned history produce partial coverage" do
    ctx = %{context() | prior_loader: fn _ -> {[], true} end}
    assert result("start_to_merge", ctx).coverage.state == :partial
    assert result("start_to_merge", ctx).coverage.covered_from == ~U[2026-10-09 11:00:00Z]
  end

  test "cost metrics query typed identities and preserve USD spend and disjoint token totals" do
    repo = {"fixture", "repo"}
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"number" => 101, "node_id" => "I_fixture"}, repo, repo)

    ctx =
      Map.merge(context(), %{
        identity_lookup: fn ids ->
          assert Enum.sort(ids) == ~w(100 101 102 104)
          {:ok, [%{identifier: "101", tracker_identity: identity}]}
        end,
        usage_query: fn %{tickets: [^identity]} ->
          totals = %{
            money: %{{:provider_reported_estimate, "USD"} => Decimal.new("1.20")},
            tokens: %{input: 150, cached_input: 30, cache_creation_input: 3, output: 60, reasoning_output: 15, provider_reported_total: 223}
          }

          %{
            groups: %{by_ticket: %{Aiur.TrackerIdentity.github_key(identity) => totals}},
            aggregate_generation: 7,
            coverage: %{projection: %{partial_records: 0}},
            health: :healthy,
            freshness: %{status: :fresh},
            totals: %{
              money: %{{:provider_reported_estimate, "USD"} => Decimal.new("1.20")},
              tokens: %{input: 150, cached_input: 30, cache_creation_input: 3, output: 60, reasoning_output: 15, provider_reported_total: 223}
            }
          }
        end,
        usage_snapshot: fn -> accounting_snapshot(identity) end
      })

    assert ticket(result("spend_per_merged_ticket", ctx).observations, 101).value == 1.2
    assert ticket(result("tokens_per_merged_ticket", ctx).observations, 101).value == 223
    assert result("tokens_per_merged_ticket", ctx).coverage.state == :partial
    ctx = Map.put(ctx, :identity_lookup, fn _ -> {:error, :tracker_offline} end)

    for id <- ~w(spend_per_merged_ticket tokens_per_merged_ticket) do
      assert result(id, ctx).coverage == %{state: :unavailable, reason: {:accounting_identity_unavailable, :tracker_offline}}
      assert result(id, ctx).observations == []
    end
  end

  test "missing accounting has no observations" do
    ctx = Map.put(context(), :accounting_available, false)

    for id <- ~w(spend_per_merged_ticket tokens_per_merged_ticket) do
      assert result(id, ctx) == %{coverage: %{state: :unavailable, reason: :accounting_absent}, observations: []}
    end
  end

  test "stale accounting and absent measures never become zero cost or tokens" do
    repo = {"fixture", "repo"}
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"number" => 101, "node_id" => "I_fixture"}, repo, repo)
    ctx = Map.put(context(), :identity_lookup, fn _ -> {:ok, [%{identifier: "101", tracker_identity: identity}]} end)
    ctx = Map.put(ctx, :usage_snapshot, fn -> %{metadata: %{generation: 7}, cells: %{}} end)

    for usage <- [
          %{health: :healthy, freshness: %{status: :stale}, totals: %{money: %{}, tokens: %{input: 3, output: 2}}},
          %{health: :healthy, freshness: %{status: :fresh}, totals: %{money: %{}, tokens: %{provider_reported_total: 5}}},
          %{
            health: :healthy,
            freshness: %{status: :fresh},
            coverage: %{projection: %{partial_records: 1}},
            totals: %{money: %{{:provider_reported_estimate, "USD"} => Decimal.new("1.2")}, tokens: %{input: 5}}
          }
        ] do
      ctx =
        Map.put(ctx, :usage_query, fn _ ->
          usage
          |> Map.put(:aggregate_generation, 7)
          |> Map.put_new(:coverage, %{projection: %{partial_records: 0}})
          |> Map.put(:groups, %{by_ticket: %{Aiur.TrackerIdentity.github_key(identity) => usage.totals}})
        end)

      for id <- ~w(spend_per_merged_ticket tokens_per_merged_ticket) do
        assert result(id, ctx).coverage.state == :unavailable
        assert result(id, ctx).observations == []
      end
    end
  end

  test "open PR durations are censored at the window end" do
    output = result("start_to_pr_open")
    row = ticket(output.observations, 103)
    assert row.value == 10_800_000
    assert row.attrs["censored"] == true
    assert row.attrs["finished_at"] == nil
    refute ticket(output.observations, 100)
    refute ticket(output.observations, 102)
    assert output.coverage.state == :partial
    assert output.coverage.reason == :pr_open_capture_missing
  end

  defp accounting_snapshot(identity) do
    key = Aiur.TrackerIdentity.github_key(identity)

    groups = [
      {%{ticket: key, provider: :codex, relationship_revision: "codex-turn-usage-2026-07"}, %{input: 100, cached_input: 20, output: 40, reasoning_output: 10}},
      {%{ticket: key, provider: :claude, relationship_revision: "claude-remote-control-2026-07"}, %{input: 50, cached_input: 10, cache_creation_input: 3, output: 20, reasoning_output: 5}}
    ]

    cells = Map.new(for {dims, counts} <- groups, {dimension, count} <- counts, do: {{dims, {:token, dimension}}, count})
    %{metadata: %{generation: 7}, cells: cells}
  end
end
