defmodule Aiur.GitHub.BudgetMapTest do
  @moduledoc """
  The budget-map projection, pure enough to test without a daemon.

  Every seam is an option, so this file hands in deterministic headroom,
  quota, ledger and agent-cache data and asserts the shape the page renders.
  The claims that matter — a stale credential is never zero, a caller with no
  cache layer is visually distinct, an unclassified caller is never guessed —
  are all asserted here.
  """

  use ExUnit.Case, async: true

  alias Aiur.GitHub.BudgetMap

  @now ~U[2030-01-01 12:00:00Z]

  defp observed_window(opts) do
    %{
      limit: Keyword.get(opts, :limit, 5_000),
      remaining: Keyword.get(opts, :remaining, 4_000),
      used: Keyword.get(opts, :used, 1_000),
      reset_at: DateTime.add(@now, 3_600, :second),
      observed_at: DateTime.add(@now, -120, :second)
    }
  end

  describe "identity meters" do
    test "renders observed windows per credential" do
      headroom_fun = fn _opts ->
        [
          %{
            id: "primary",
            kind: :app_installation,
            identity: "aiur-daemon[bot]",
            writes?: true,
            primary?: true,
            available?: true,
            token_key: "a",
            windows: %{"graphql" => observed_window(used: 113), "core" => observed_window(used: 2, remaining: 4_998)}
          }
        ]
      end

      [credential] = BudgetMap.identity_meters(headroom_fun: headroom_fun, now: @now)

      assert credential.identity == "aiur-daemon[bot]"
      assert credential.graphql.state == :observed
      assert credential.graphql.used == 113
      assert credential.graphql.limit == 5_000
      assert credential.graphql.observed_age_seconds == 120
      assert credential.core.used == 2
    end

    test "an available credential with no observation is stale, never zero" do
      headroom_fun = fn _opts ->
        [%{id: "primary", kind: :machine_user, identity: "its-applekid", available?: true, token_key: "b", windows: %{}}]
      end

      [credential] = BudgetMap.identity_meters(headroom_fun: headroom_fun, now: @now)

      assert credential.graphql.state == :stale
      assert credential.graphql.reason == :no_window
      refute Map.has_key?(credential.graphql, :used)
    end

    test "an unresolvable credential is stale with its own reason" do
      headroom_fun = fn _opts ->
        [%{id: "primary", kind: :machine_user, identity: "its-everdred", available?: false, token_key: "c", windows: %{}}]
      end

      [credential] = BudgetMap.identity_meters(headroom_fun: headroom_fun, now: @now)

      assert credential.core.state == :stale
      assert credential.core.reason == :unavailable
    end
  end

  describe "verdict" do
    test "a free-by-nature caller is free" do
      row = %{caller: "webhook_review_thread", resource: "graphql", read_cache: %{observed?: false}, hint: %{}}
      assert BudgetMap.verdict(row) == :free
      assert BudgetMap.pool(row) == :free
    end

    test "the measured no-reuse callers are wasted" do
      for caller <- BudgetMap.wasted_callers() do
        row = %{caller: caller, resource: "graphql", read_cache: %{observed?: false}, hint: %{}}
        assert BudgetMap.verdict(row) == :wasted, "expected #{caller} to be wasted"
      end
    end

    test "a caller with a reuse hint is billed" do
      row = %{caller: "issue_relationships", resource: "graphql", read_cache: %{observed?: false}, hint: %{store?: true, etag?: false}}
      assert BudgetMap.verdict(row) == :billed
      assert BudgetMap.pool(row) == :graphql
    end

    test "a caller with live read-cache hits is billed, never guessed wasted" do
      row = %{caller: "some_caller", resource: "core", read_cache: %{observed?: true, hit: 5, miss: 1, refused: 0}, hint: %{}}
      assert BudgetMap.verdict(row) == :billed
      assert BudgetMap.pool(row) == :core
    end

    test "a caller with no evidence at all is unclassified, never guessed" do
      row = %{caller: "some_caller", resource: "core", read_cache: %{observed?: false}, hint: %{}}
      assert BudgetMap.verdict(row) == :unclassified
    end
  end

  describe "caller rows and map edges" do
    test "ranks callers across both budgets by volume" do
      usage = %{
        budgets: %{
          "graphql" => %{
            resource: "graphql",
            callers: [
              %{caller: "ci_poll_batch", points: 50, calls: 5, estimated?: false}
            ],
            attributed: 50
          },
          "core" => %{
            resource: "core",
            callers: [
              %{caller: "unattributed", points: 3, calls: 3, estimated?: false}
            ],
            attributed: 3
          }
        }
      }

      read_cache = %{available?: true, callers: %{"ci_poll_batch" => %{hit: 0, miss: 1, refused: 2}}}

      callers = BudgetMap.caller_rows(usage, read_cache_fun: fn -> read_cache end)
      edges = BudgetMap.map_edges(callers)

      assert length(edges) == 2

      ci = Enum.find(edges, &(&1.caller == "ci_poll_batch"))
      assert ci.verdict == :wasted
      assert ci.pool == :graphql
      assert ci.read_cache.hit == 0
      assert ci.read_cache.refused == 2

      unattributed = Enum.find(edges, &(&1.caller == "unattributed"))
      assert unattributed.pool == :core
    end

    test "a read-cache hit is carried into the edge for the map's cache layer" do
      usage = %{
        budgets: %{
          "graphql" => %{
            resource: "graphql",
            callers: [%{caller: "issue_relationships", points: 2, calls: 1, estimated?: false}],
            attributed: 2
          }
        }
      }

      read_cache = %{available?: true, callers: %{"issue_relationships" => %{hit: 12, miss: 1, refused: 0}}}

      [edge] = BudgetMap.map_edges(BudgetMap.caller_rows(usage, read_cache_fun: fn -> read_cache end))

      assert edge.read_cache.hit == 12
      assert edge.hint == %{store?: true, etag?: false}
    end
  end

  describe "admissions and agent cache" do
    test "admissions comes from the ledger seam" do
      ledger = %{available?: true, admission_count: 7, billable: 5, free: 2, by_family: %{}, by_consumer: %{}, rows: []}
      snapshot = BudgetMap.admissions(ledger_fun: fn _opts -> ledger end)
      assert snapshot.admission_count == 7
      assert snapshot.billable == 5
    end

    test "a raising ledger reads as unavailable, never as zero" do
      snapshot = BudgetMap.admissions(ledger_fun: fn _opts -> raise "broker gone" end)
      assert snapshot.available? == false
      assert snapshot.admission_count == nil
    end

    test "agent-cache files are parsed into per-workspace hit rates" do
      path = Path.join(System.tmp_dir!(), "aiur-bmap-agent-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([path, ".aiur-runtime", "github-quota"]))

      tsv = Path.join([path, ".aiur-runtime", "github-quota", "agent-cache.tsv"])
      File.write!(tsv, "1000\tconsumer\thit\tissue\t1\n1001\tconsumer\thit\tpr\t2\n1002\tconsumer\tmiss\tissue\t3\n1003\tconsumer\tstore\tpr\t4\n")

      glob_fun = fn -> [tsv] end
      snapshot = BudgetMap.agent_cache(agent_cache_glob_fun: glob_fun)

      assert snapshot.available?
      assert snapshot.totals.hits == 2
      assert snapshot.totals.misses == 1
      assert snapshot.totals.stores == 1
      # The projection rounds hit rates to four decimals for display, so the
      # assertion matches the rounded value rather than the raw fraction.
      assert snapshot.totals.hit_rate == 0.6667

      [workspace] = snapshot.workspaces
      assert workspace.hit_rate == 0.6667
    end

    test "no agent-cache files reads as not measured" do
      snapshot = BudgetMap.agent_cache(agent_cache_glob_fun: fn -> [] end)
      assert snapshot.available? == false
      assert snapshot.workspaces == []
    end
  end

  describe "read cache" do
    test "respects the read-cache seam" do
      provider = %{available?: true, callers: %{"x" => %{hit: 1}}, refused: %{}, totals: %{}}
      assert BudgetMap.read_cache(read_cache_fun: fn -> provider end).available?
    end
  end
end
