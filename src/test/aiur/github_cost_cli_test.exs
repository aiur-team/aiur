defmodule Aiur.GitHubCostCLITest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.GitHub.Quota
  alias Aiur.GitHubCostCLI

  @now ~U[2026-08-17 12:00:00Z]

  test "orders callers by points, not by call count or fixture order" do
    assert {:ok, envelope} = GitHubCostCLI.build(snapshot_fun: fn -> snapshot() end, now: @now)

    assert [top | rest] = envelope["data"]["callers"]

    assert top["caller"] == "build_order_catalog"
    assert top["points"] == 840
    assert top["points_per_hour"] == 1680.0

    # Ranked by points, not by calls: the catalog made three requests and the
    # comment poller made sixty, and the catalog is still the leader. The fixture
    # arrives unsorted, so passing this requires the CLI to order the rows.
    assert Enum.map(rest, & &1["caller"]) == ["comment_poll_batch", "agent-shell:gh"]
  end

  test "scopes the window and the reconciliation to the selected budget" do
    assert {:ok, graphql} = GitHubCostCLI.build(snapshot_fun: fn -> snapshot() end, now: @now)

    # Printing the core window beside a GraphQL ranking invites reading the two
    # budgets as one figure, which is the mistake this command exists to end.
    assert Map.keys(graphql["data"]["windows"]) == ["graphql"]
    assert Map.keys(graphql["data"]["reconciliation"]) == ["graphql"]

    output = capture_io(fn -> assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> snapshot() end, format: :table) end)
    refute output =~ "core"

    assert {:ok, all} = GitHubCostCLI.build(snapshot_fun: fn -> snapshot() end, budget: "all", now: @now)
    assert Enum.sort(Map.keys(all["data"]["windows"])) == ["core", "graphql"]
  end

  test "prints what the read cache saved, and why it refused what it refused" do
    cache = fn ->
      %{
        available?: true,
        entries: 12,
        hit_rate: 0.75,
        totals: %{hit: 30, miss: 10, deposit: 10, refused: 60},
        refused: %{unsafe_kind: 60},
        classes: %{},
        callers: %{},
        invalidations: %{events: 2, marks: 4}
      }
    end

    output =
      capture_io(fn ->
        assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> snapshot() end, cache_fun: cache, format: :records)
      end)

    assert output =~ "read cache: 75.0% of cacheable reads served"
    assert output =~ "30 hits, 10 misses, 10 deposits"
    # A refusal is deliberate spend, not a cache that is failing. Printing it
    # beside the ranking is what separates the two.
    assert output =~ "read cache refusals: unsafe_kind 60"
  end

  test "never prints a hit rate over no observations" do
    cache = fn -> %{available?: true, entries: 0, hit_rate: nil, totals: %{hit: 0, miss: 0, deposit: 0, refused: 0}, refused: %{}} end

    output =
      capture_io(fn ->
        assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> snapshot() end, cache_fun: cache, format: :records)
      end)

    assert output =~ "no cacheable reads observed"
    refute output =~ "0.0% of cacheable reads"
  end

  test "says the read cache is not running rather than printing zeroes for it" do
    output =
      capture_io(fn ->
        assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> snapshot() end, cache_fun: fn -> :unavailable end, format: :records)
      end)

    assert output =~ "read cache: not running (no measurement)"
  end

  test "reports an unattributed remainder as a measurement gap, not an alarm" do
    # Spend Aiur could not see is the normal state, and an all-caps alarm on the
    # normal state teaches operators to ignore the line that matters.
    short =
      put_in(snapshot().reconciliation["graphql"], %{
        attributed: 20,
        spend: 1000,
        delta: -980,
        margin: 0.05,
        reconciled?: false,
        direction: :shortfall,
        estimated?: false
      })

    output = capture_io(fn -> assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> short end, format: :table) end)

    assert output =~ "980 points unattributed"
    refute output =~ "DOES NOT reconcile"
  end

  test "shares are of the attributed total and are labelled as such" do
    assert {:ok, envelope} = GitHubCostCLI.build(snapshot_fun: fn -> snapshot() end, now: @now)

    shares = Enum.map(envelope["data"]["callers"], & &1["share_of_attributed"])

    assert_in_delta Enum.sum(shares), 1.0, 0.001
  end

  test "prints the reconciliation verdict beside the ranking" do
    output = capture_io(fn -> assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> snapshot() end, format: :table) end)

    assert output =~ "build_order_catalog"
    assert output =~ "POINTS/HR"
    assert output =~ "graphql reconciliation:"
    assert output =~ "1000 attributed vs 1000 spent"
    assert output =~ "reconciles"
    refute output =~ "DOES NOT reconcile"
  end

  test "says plainly when the breakdown claims more than was spent" do
    # Points cannot be spent twice, so an excess is a double count in the
    # accounting itself. This is the only case the alarm is reserved for.
    excess =
      put_in(snapshot().reconciliation["graphql"], %{
        attributed: 1400,
        spend: 1000,
        delta: 400,
        margin: 0.05,
        reconciled?: false,
        direction: :excess,
        estimated?: false
      })

    output = capture_io(fn -> assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> excess end, format: :table) end)

    assert output =~ "DOES NOT reconcile"
    assert output =~ "delta 400"
  end

  test "an unobserved meter reports nothing observed, never zero" do
    empty = %{state: :unknown, windows: %{}, attribution: [], callers: [], coverage: %{}, reconciliation: %{}}

    output = capture_io(fn -> assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> empty end) end)

    # Nothing observed and nothing spent are different facts, and reporting the
    # first as a zero would claim a measurement that was never taken.
    assert output =~ "No GitHub API calls have been attributed"
    refute output =~ "reconcil"
  end

  test "filters to one budget and never sums two budgets into one number" do
    assert {:ok, core} = GitHubCostCLI.build(snapshot_fun: fn -> snapshot() end, budget: "core", now: @now)
    assert Enum.map(core["data"]["callers"], & &1["caller"]) == ["rest:GET /repos/:n"]

    assert {:ok, all} = GitHubCostCLI.build(snapshot_fun: fn -> snapshot() end, budget: "all", now: @now)
    assert length(all["data"]["callers"]) == 4
  end

  test "rejects an unknown budget rather than silently showing everything" do
    assert {:error, message} = GitHubCostCLI.build(snapshot_fun: fn -> snapshot() end, budget: "points")
    assert message =~ "--budget accepts graphql, core or all"

    stderr =
      capture_io(:stderr, fn ->
        assert 1 == GitHubCostCLI.run(snapshot_fun: fn -> snapshot() end, budget: "points")
      end)

    assert stderr =~ "aiur: github-cost --budget accepts"
  end

  test "fails when the production meter cannot be reached" do
    meter = Process.whereis(Quota)
    assert is_pid(meter)
    assert Process.unregister(Quota)

    result =
      try do
        GitHubCostCLI.build()
      after
        assert Process.register(meter, Quota)
      end

    assert {:error, message} = result
    assert message =~ "not running"
  end

  test "reads reported GraphQL attribution from the production meter" do
    request = %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "secret",
      caller: :github_cost_live_test,
      body: %{"query" => "query CostTest { viewer { login } }", "variables" => %{}}
    }

    response =
      {:ok,
       %{
         status: 200,
         headers: [],
         body: %{
           "data" => %{
             "rateLimit" => %{
               "cost" => 37,
               "limit" => 5000,
               "remaining" => 4963,
               "resetAt" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
             }
           }
         }
       }}

    Quota.observe(request, response)

    assert {:ok, envelope} = GitHubCostCLI.build()
    assert caller = Enum.find(envelope["data"]["callers"], &(&1["caller"] == "github_cost_live_test"))
    assert caller["resource"] == "graphql"
    assert caller["points"] == 37
    assert caller["calls"] == 1
    assert caller["estimated?"] == false
  end

  test "emits a machine-readable envelope under --json" do
    output = capture_io(fn -> assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> snapshot() end, json: true) end)

    decoded = Jason.decode!(output)

    assert decoded["schema_version"] == 2
    assert decoded["page"] == "github-cost"
    assert decoded["data"]["reconciliation"]["graphql"]["reconciled?"] == true
  end

  defp snapshot do
    %{
      state: :observed,
      windows: %{
        "graphql" => %{limit: 5000, remaining: 4000, used: 1000, reset_at: ~U[2026-08-17 12:30:00Z]},
        "core" => %{limit: 5000, remaining: 4900, used: 100, reset_at: ~U[2026-08-17 12:30:00Z]}
      },
      attribution: [],
      # Deliberately not in ranked order: a pre-sorted fixture cannot tell a
      # ranking apart from a CLI that ignores order entirely. `comment_poll_batch`
      # also leads on call count while trailing on points, so a request-count
      # ranking produces a visibly different table.
      callers: [
        %{
          caller: "agent-shell:gh",
          resource: "graphql",
          calls: 40,
          reads: 40,
          writes: 0,
          points: 40,
          points_per_hour: 80.0,
          elapsed_seconds: 1800,
          estimated?: true
        },
        %{
          caller: "rest:GET /repos/:n",
          resource: "core",
          calls: 100,
          reads: 100,
          writes: 0,
          points: 100,
          points_per_hour: 200.0,
          elapsed_seconds: 1800,
          estimated?: false
        },
        %{
          caller: "comment_poll_batch",
          resource: "graphql",
          calls: 60,
          reads: 60,
          writes: 0,
          points: 120,
          points_per_hour: 240.0,
          elapsed_seconds: 1800,
          estimated?: false
        },
        %{
          caller: "build_order_catalog",
          resource: "graphql",
          calls: 3,
          reads: 3,
          writes: 0,
          points: 840,
          points_per_hour: 1680.0,
          elapsed_seconds: 1800,
          estimated?: false
        }
      ],
      coverage: %{resources: %{}, estimated?: false},
      reconciliation: %{
        "graphql" => %{
          attributed: 1000,
          spend: 1000,
          delta: 0,
          margin: 0.05,
          reconciled?: true,
          direction: :agrees,
          estimated?: false
        },
        "core" => %{
          attributed: 100,
          spend: 100,
          delta: 0,
          margin: 0.05,
          reconciled?: true,
          direction: :agrees,
          estimated?: false
        }
      },
      backoffs: []
    }
  end
end
