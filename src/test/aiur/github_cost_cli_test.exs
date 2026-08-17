defmodule Aiur.GitHubCostCLITest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.GitHubCostCLI

  @now ~U[2026-08-17 12:00:00Z]

  test "ranks callers by points per hour and names the top consumer" do
    assert {:ok, envelope} = GitHubCostCLI.build(snapshot_fun: fn -> snapshot() end, now: @now)

    assert [top | rest] = envelope["data"]["callers"]

    assert top["caller"] == "build_order_catalog"
    assert top["points"] == 840
    assert top["points_per_hour"] == 1680.0

    # Ranked by points, not by calls: the catalog made three requests and the
    # comment poller made sixty, and the catalog is still the leader.
    assert Enum.map(rest, & &1["caller"]) == ["comment_poll_batch", "agent-shell:gh"]
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

  test "says plainly when the breakdown does not add up" do
    short = put_in(snapshot().reconciliation["graphql"], %{attributed: 20, spend: 1000, delta: -980, margin: 0.05, reconciled?: false, estimated?: false})

    output = capture_io(fn -> assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> short end, format: :table) end)

    # An unmeasured majority presented as a leader invites acting on a fraction
    # of the spend, so the shortfall is stated rather than rounded away.
    assert output =~ "DOES NOT reconcile"
    assert output =~ "delta -980"
  end

  test "an unobserved meter reports nothing observed, never zero" do
    empty = %{state: :unknown, windows: %{}, attribution: [], callers: [], coverage: %{}, reconciliation: %{}}

    output = capture_io(fn -> assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> empty end) end)

    assert output =~ "No GitHub API calls have been attributed"
    refute output =~ "0%"
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

    assert 1 ==
             capture_io(:stderr, fn ->
               assert 1 == GitHubCostCLI.run(snapshot_fun: fn -> snapshot() end, budget: "points")
             end)
             |> then(fn stderr ->
               assert stderr =~ "aiur: github-cost --budget accepts"
               1
             end)
  end

  test "survives a meter that is not running" do
    assert {:error, message} = GitHubCostCLI.build(snapshot_fun: fn -> exit(:noproc) end)

    assert message =~ "not running"
  end

  test "emits a machine-readable envelope under --json" do
    output = capture_io(fn -> assert 0 == GitHubCostCLI.run(snapshot_fun: fn -> snapshot() end, json: true) end)

    decoded = Jason.decode!(output)

    assert decoded["schema_version"] == 1
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
      callers: [
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
        }
      ],
      coverage: %{resources: %{}, estimated?: false},
      reconciliation: %{
        "graphql" => %{attributed: 1000, spend: 1000, delta: 0, margin: 0.05, reconciled?: true, estimated?: false},
        "core" => %{attributed: 100, spend: 100, delta: 0, margin: 0.05, reconciled?: true, estimated?: false}
      },
      backoffs: []
    }
  end
end
