defmodule Aiur.GitHub.CredentialUsageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.GitHub.{Credential, CredentialUsage}

  @now ~U[2026-08-20 12:00:00Z]

  # Unique per credential: these tests are async and the process environment is
  # global, so a fixed name is shared with every other test that wants a
  # credential and one test's cleanup can unset another's token mid-run.
  defp credential(id, attrs) do
    env = "AIUR_TEST_TOKEN_#{String.upcase(id)}_#{System.unique_integer([:positive])}"

    struct!(%Credential{id: id, kind: :machine_user, identity: id, token_env: env}, attrs)
  end

  defp export(credential, token) do
    System.put_env(credential.token_env, token)
    on_exit(fn -> System.delete_env(credential.token_env) end)
    credential
  end

  defp window(remaining, limit) do
    %{limit: limit, remaining: remaining, used: limit - remaining, reset_at: DateTime.add(@now, 600), observed_at: @now}
  end

  setup do
    primary = export(credential("primary", primary?: true, writes?: true), "primary-token")
    spare = export(credential("spare", kind: :human), "spare-token")

    windows = %{
      Credential.token_key(primary) => %{"graphql" => window(1_000, 5_000), "core" => window(4_912, 5_000)},
      Credential.token_key(spare) => %{"graphql" => window(4_500, 5_000), "core" => window(5_000, 5_000)}
    }

    actors = [
      %{
        token_key: Credential.token_key(primary),
        consumer_key: "k1",
        consumer_label: "daemon:aiur@host",
        core: %{used: 88, limit: 3_000, reset_at_ms: nil},
        graphql: %{used: 1_900, limit: 2_000, reset_at_ms: nil}
      },
      %{
        token_key: Credential.token_key(spare),
        consumer_key: "k2",
        consumer_label: "workspace:/tmp/w",
        core: %{used: 4, limit: 1_000, reset_at_ms: nil},
        graphql: %{used: 100, limit: 500, reset_at_ms: nil}
      }
    ]

    opts = [credentials: [primary, spare], windows: windows, now: @now, usage_fun: fn -> %{actors: actors} end]

    %{opts: opts, actors: actors}
  end

  test "rows carry identity, admissions and the credential's own window", %{opts: opts} do
    rows = CredentialUsage.rows(opts)

    assert [primary_row, spare_row] = rows

    assert primary_row.id == "primary"
    assert primary_row.writes?
    assert primary_row.admissions["graphql"] == %{used: 1_900, limit: 2_000, actors: 1}
    assert primary_row.windows["graphql"].remaining == 1_000
    assert primary_row.actors == ["daemon:aiur@host"]

    assert spare_row.kind == :human
    refute spare_row.writes?
    assert spare_row.windows["core"].remaining == 5_000
  end

  test "pool totals sum remaining across credentials and are marked complete", %{opts: opts} do
    pool = CredentialUsage.pool(opts)

    assert pool["graphql"].remaining == 5_500
    assert pool["graphql"].limit == 10_000
    assert pool["graphql"].configured_credentials == 2
    assert pool["graphql"].observed_credentials == 2
    assert pool["graphql"].complete?
    assert pool["graphql"].admissions == 2_000
  end

  test "a partially observed pool is not marked complete", %{opts: opts} do
    [primary, _spare] = Keyword.fetch!(opts, :credentials)
    windows = Map.take(Keyword.fetch!(opts, :windows), [Credential.token_key(primary)])

    pool = CredentialUsage.pool(Keyword.put(opts, :windows, windows))

    assert pool["graphql"].observed_credentials == 1
    assert pool["graphql"].configured_credentials == 2
    refute pool["graphql"].complete?
    assert pool["graphql"].remaining == 1_000
  end

  test "an unobserved resource is nil, never zero", %{opts: opts} do
    pool = CredentialUsage.pool(Keyword.put(opts, :windows, %{}))

    assert pool["core"].remaining == nil
    assert pool["core"].observed_credentials == 0
  end

  test "an unavailable credential keeps its recorded admissions", %{actors: actors} do
    unavailable = credential("primary", primary?: true, writes?: true)
    opts = [credentials: [unavailable], windows: %{}, now: @now, usage_fun: fn -> %{actors: actors} end]

    assert [row] = CredentialUsage.rows(opts)
    refute row.available?
    assert row.admissions["graphql"].used == 1_900
    assert row.actors == ["daemon:aiur@host"]
  end

  describe "aiur github-usage" do
    test "reports per credential and the pool", %{opts: opts, actors: actors} do
      {:ok, envelope} = Aiur.GitHubUsageCLI.build(Keyword.put(opts, :usage_fun, fn -> %{actors: actors} end))

      assert [primary, spare] = envelope["data"]["credentials"]
      assert primary["id"] == "primary"
      assert primary["writes"] == true
      assert spare["kind"] == "human"
      assert spare["writes"] == false
      assert envelope["data"]["pool"]["graphql"]["remaining"] == 5_500
      # The per-actor table the command already printed is unchanged.
      assert length(envelope["data"]["actors"]) == 2
    end

    test "prints the pool as a ceiling, not a balance", %{opts: opts, actors: actors} do
      {:ok, envelope} = Aiur.GitHubUsageCLI.build(Keyword.put(opts, :usage_fun, fn -> %{actors: actors} end))

      output = capture_io(fn -> Aiur.GitHubUsageCLI.run(Keyword.merge(opts, usage_fun: fn -> %{actors: actors} end)) end)

      assert envelope["data"]["pool"]["graphql"]["complete?"]
      assert output =~ "graphql pool: 5500 remaining of 10000 across the pool"
      assert output =~ "windows reset independently"
      assert output =~ "read-only"
    end

    test "names a partial pool total as a floor", %{opts: opts, actors: actors} do
      output =
        capture_io(fn ->
          Aiur.GitHubUsageCLI.run(Keyword.merge(opts, windows: %{}, usage_fun: fn -> %{actors: actors} end))
        end)

      assert output =~ "no credential observed yet (2 configured)"
      assert output =~ "not observed this window"
    end
  end

  describe "single-credential reports are unchanged" do
    setup %{opts: opts} do
      [primary, _spare] = Keyword.fetch!(opts, :credentials)

      %{solo: Keyword.put(opts, :credentials, [primary])}
    end

    test "github-usage omits the credential and pool sections entirely", %{solo: solo, actors: actors} do
      {:ok, envelope} = Aiur.GitHubUsageCLI.build(Keyword.put(solo, :usage_fun, fn -> %{actors: actors} end))

      refute Map.has_key?(envelope["data"], "credentials")
      refute Map.has_key?(envelope["data"], "pool")
      assert Map.has_key?(envelope["data"], "actors")
    end

    test "github-usage prints no pool line", %{solo: solo, actors: actors} do
      output = capture_io(fn -> Aiur.GitHubUsageCLI.run(Keyword.put(solo, :usage_fun, fn -> %{actors: actors} end)) end)

      refute output =~ "pool"
      refute output =~ "Credentials ("
    end

    test "github-cost omits the credential and pool-reconciliation sections", %{solo: solo} do
      snapshot = %{state: :observed, windows: %{}, callers: [], reconciliation: %{}}

      {:ok, envelope} = Aiur.GitHubCostCLI.build(Keyword.put(solo, :snapshot_fun, fn -> snapshot end))

      refute Map.has_key?(envelope["data"], "credentials")
      refute Map.has_key?(envelope["data"], "pool_reconciliation")
    end

    # The pre-existing guarantee this whole feature had to preserve: an
    # unobserved meter says nothing observed and never mentions reconciliation.
    test "github-cost on an unobserved meter still says nothing observed", %{solo: solo} do
      snapshot = %{state: :unknown, windows: %{}, callers: [], reconciliation: %{}}

      output = capture_io(fn -> Aiur.GitHubCostCLI.run(Keyword.put(solo, :snapshot_fun, fn -> snapshot end)) end)

      assert output =~ "No GitHub API calls have been attributed in the current window."
      refute output =~ "reconcil"
    end
  end

  describe "aiur github-cost" do
    test "refuses a pool delta while any credential is unobserved", %{opts: opts} do
      snapshot = %{
        state: :observed,
        windows: %{"graphql" => %{limit: 5_000, remaining: 1_000, used: 4_000, reset_at: @now}},
        callers: [%{caller: "poller", resource: "graphql", points: 3_900, calls: 40, points_per_hour: 3_900.0, estimated?: false}],
        reconciliation: %{}
      }

      windows = Map.take(Keyword.fetch!(opts, :windows), [Credential.token_key(hd(Keyword.fetch!(opts, :credentials)))])

      {:ok, envelope} =
        Aiur.GitHubCostCLI.build(Keyword.merge(opts, snapshot_fun: fn -> snapshot end, windows: windows))

      pool = envelope["data"]["pool_reconciliation"]["graphql"]

      assert pool["measurable?"] == false
      assert pool["delta"] == nil
      assert pool["observed_credentials"] == 1
    end

    test "states the pool delta once every credential is observed", %{opts: opts} do
      snapshot = %{
        state: :observed,
        windows: %{"graphql" => %{limit: 5_000, remaining: 1_000, used: 4_000, reset_at: @now}},
        callers: [%{caller: "poller", resource: "graphql", points: 3_900, calls: 40, points_per_hour: 3_900.0, estimated?: false}],
        reconciliation: %{}
      }

      {:ok, envelope} = Aiur.GitHubCostCLI.build(Keyword.merge(opts, snapshot_fun: fn -> snapshot end))

      pool = envelope["data"]["pool_reconciliation"]["graphql"]

      assert pool["measurable?"] == true
      # 4,000 spent on the primary plus 500 on the spare; attribution is
      # pool-wide, so the delta is against the pool, not one credential.
      assert pool["pool_spend"] == 4_500
      assert pool["attributed"] == 3_900
      assert pool["delta"] == -600
    end

    test "lists each credential's window beside the ranking", %{opts: opts} do
      snapshot = %{
        state: :observed,
        windows: %{"graphql" => %{limit: 5_000, remaining: 1_000, used: 4_000, reset_at: @now}},
        callers: [%{caller: "poller", resource: "graphql", points: 3_900, calls: 40, points_per_hour: 3_900.0, estimated?: false}],
        reconciliation: %{}
      }

      output =
        capture_io(fn ->
          Aiur.GitHubCostCLI.run(Keyword.merge(opts, snapshot_fun: fn -> snapshot end, format: :records))
        end)

      assert output =~ "credential primary (machine_user, primary, read+write): graphql 1000 of 5000 left"
      assert output =~ "credential spare (human, spare, read-only)"
      assert output =~ "graphql pool reconciliation: 3900 attributed vs 4500 spent across 2 credentials"
    end
  end
end
