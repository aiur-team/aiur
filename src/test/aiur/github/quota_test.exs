defmodule Aiur.GitHub.QuotaTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Quota

  @now ~U[2026-08-09 21:00:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

  test "projects rate-limit headers into exact core and GraphQL windows" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 3750))
    Quota.observe(quota, graphql_request("query Ticket($number: Int!) { repository { issue(number: $number) { id } } }", %{"number" => 1670}), response("graphql", 5000, 4400))

    snapshot = Quota.snapshot(quota)

    assert snapshot.state == :observed

    assert snapshot.windows["core"] == %{
             resource: "core",
             limit: 5000,
             remaining: 3750,
             remaining_percent: 75.0,
             used: 1250,
             used_percent: 25.0,
             reset_at: @reset,
             observed_at: @now
           }

    assert snapshot.windows["graphql"].remaining == 4400
    assert snapshot.windows["graphql"].used_percent == 12.0
  end

  test "the low-water crossing alerts once per resource window and names the reset" do
    parent = self()

    quota =
      start_quota(
        emit_fun: fn name, opts ->
          send(parent, {:alert, name, opts})
          :ok
        end
      )

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 500))
    _snapshot = Quota.snapshot(quota)

    assert_receive {:alert, "system.github.quota.core.low", opts}
    assert opts[:needs_attention]
    assert opts[:reason] =~ "500 of 5000"
    assert opts[:reason] =~ "2026-08-09T22:00:00Z"

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 499))
    _snapshot = Quota.snapshot(quota)
    refute_receive {:alert, "system.github.quota.core.low", _opts}
  end

  test "resolves a quota attention after the resource recovers" do
    parent = self()

    quota =
      start_quota(
        emit_fun: fn name, opts ->
          send(parent, {:alert, name, opts})
          :ok
        end
      )

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 500))
    _snapshot = Quota.snapshot(quota)
    assert_receive {:alert, "system.github.quota.core.low", _opts}

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 501))
    _snapshot = Quota.snapshot(quota)

    assert_receive {:alert, "system.github.quota.core.low.resolved", opts}
    refute opts[:needs_attention]
  end

  test "exhaustion blocks only the depleted resource until its reset" do
    {:ok, clock} = Agent.start_link(fn -> @now end)
    quota = start_quota(clock: fn -> Agent.get(clock, & &1) end)

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 0))
    _snapshot = Quota.snapshot(quota)

    assert {:hold, hold} = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
    assert hold.resource == "core"
    assert hold.reset_at == @reset
    assert :ok = Quota.preflight(quota, graphql_request("query { viewer { login } }", %{}))
    assert :ok = Quota.preflight(quota, request(:get, "/rate_limit"))

    Agent.update(clock, fn _ -> DateTime.add(@reset, 1, :second) end)
    assert :ok = Quota.preflight(quota, request(:get, "/repos/owner/repo/issues"))
  end

  test "new dispatch is held at the ten-percent floor and fails open before observation" do
    quota = start_quota()

    assert Quota.dispatch_status(quota) == :available

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 501))
    assert Quota.dispatch_status(quota) == :available

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 500))

    assert {:hold, %{resource: "core", remaining: 500, limit: 5000, reset_at: @reset}} =
             Quota.dispatch_status(quota)
  end

  test "attributes rolling reads and writes to ticket-shaped requests without inventing unknown ownership" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 4999))
    Quota.observe(quota, request(:patch, "/repos/owner/repo/issues/1670"), response("core", 5000, 4998))
    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 4997))
    Quota.observe(quota, graphql_request("mutation AddLabel { addLabelsToLabelable(input: {}) { clientMutationId } }", %{"number" => 1671}), response("graphql", 5000, 4999))

    assert Quota.snapshot(quota).attribution == [
             %{consumer: "ticket:1670", reads: 1, writes: 1, total: 2},
             %{consumer: "ticket:1671", reads: 0, writes: 1, total: 1},
             %{consumer: "unattributed", reads: 1, writes: 0, total: 1}
           ]
  end

  test "hydrates all primary resources from the rate-limit endpoint body" do
    quota = start_quota()

    body = %{
      "resources" => %{
        "core" => %{"limit" => 5000, "remaining" => 4200, "reset" => DateTime.to_unix(@reset)},
        "graphql" => %{"limit" => 5000, "remaining" => 3900, "reset" => DateTime.to_unix(@reset)},
        "search" => %{"limit" => 30, "remaining" => 29, "reset" => DateTime.to_unix(@reset)}
      }
    }

    Quota.observe(quota, request(:get, "/rate_limit"), {:ok, %{status: 200, headers: [], body: body}})

    snapshot = Quota.snapshot(quota)
    assert Map.keys(snapshot.windows) |> Enum.sort() == ["core", "graphql"]
    assert snapshot.windows["core"].remaining == 4200
    assert snapshot.windows["graphql"].remaining == 3900
  end

  test "includes recent agent-shell attribution and ignores stale or malformed rows" do
    path = Path.join(System.tmp_dir!(), "aiur-gh-quota-#{System.unique_integer([:positive])}.tsv")
    now_unix = DateTime.to_unix(@now)

    File.write!(
      path,
      "#{now_unix}\tticket:1670\tread\n#{now_unix}\tticket:1671\twrite\n#{now_unix - 3601}\tticket:999\tread\nmalformed\n"
    )

    on_exit(fn -> File.rm(path) end)
    quota = start_quota(shell_log_path: path)

    assert Quota.snapshot(quota).attribution == [
             %{consumer: "ticket:1670", reads: 1, writes: 0, total: 1},
             %{consumer: "ticket:1671", reads: 0, writes: 1, total: 1}
           ]
  end

  test "publishes and clears resource-specific shell holds" do
    hold_dir = Path.join(System.tmp_dir!(), "aiur-gh-holds-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(hold_dir) end)
    quota = start_quota(hold_dir: hold_dir)

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 0))
    _snapshot = Quota.snapshot(quota)

    assert File.read!(Path.join(hold_dir, "core-hold")) == "#{DateTime.to_unix(@reset)}\n"

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 100))
    _snapshot = Quota.snapshot(quota)
    refute File.exists?(Path.join(hold_dir, "core-hold"))
  end

  test "refreshes immediately and schedules the next probe after completion" do
    parent = self()

    _quota =
      start_quota(
        refresh?: true,
        refresh_interval_ms: 10,
        refresh_fun: fn -> send(parent, :refreshed) end
      )

    assert_receive :refreshed, 500
    assert_receive :refreshed, 500
  end

  defp start_quota(opts \\ []) do
    start_supervised!({Quota, Keyword.merge([name: nil, clock: fn -> @now end, hold_dir: nil], opts)})
  end

  defp request(method, path) do
    %{method: method, url: "https://api.github.com#{path}", token: "secret"}
  end

  defp graphql_request(query, variables) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "secret",
      body: %{"query" => query, "variables" => variables}
    }
  end

  defp response(resource, limit, remaining) do
    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", resource},
         {"x-ratelimit-limit", Integer.to_string(limit)},
         {"x-ratelimit-remaining", Integer.to_string(remaining)},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(@reset))}
       ],
       body: %{}
     }}
  end
end
