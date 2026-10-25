defmodule AiurWeb.Build.UsageLoadTest do
  use Aiur.TestSupport
  import Aiur.GitHub.QuotaTestSupport
  alias Aiur.GitHub.Quota
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias AiurWeb.Build.{Read, Usage}
  alias AiurWeb.OperatorControlCenter.RunSummaryStrip.ServiceRows

  defmodule MeterSource do
    def load(pid, _opts) do
      send(pid, :loaded)
      %{codex: I.snapshot(:codex, %{"primary" => I.window(42)})}
    end

    def reload(pid, message, _opts) do
      send(pid, {:reloaded, message})
      load(pid, [])
    end
  end

  defmodule FailedSource do
    def load(_context, _opts), do: raise("meter down")
  end

  setup do
    dir = Aiur.TestSupport.tmp_root!("usage-ledger")
    File.mkdir_p!(dir)
    path = Path.join(dir, "model-usage.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, path: path}
  end

  defp opts(path), do: [meter_source: MeterSource, durable_path: path, accounts_fun: fn -> %{} end, github_server: :absent_usage_github, elevenlabs_server: :absent_usage_elevenlabs]

  test "U11 credential filter follows registry provider credentials", %{path: path} do
    before = System.get_env("DEEPSEEK_API_KEY")
    on_exit(fn -> if before, do: System.put_env("DEEPSEEK_API_KEY", before), else: System.delete_env("DEEPSEEK_API_KEY") end)
    System.delete_env("DEEPSEEK_API_KEY")
    refute :deepseek in Usage.load(self(), opts(path)).families
    System.put_env("DEEPSEEK_API_KEY", "test-only")
    assert :deepseek in Usage.load(self(), opts(path)).families
  end

  test "U6 U15 durable read uses explicit path and failure isolates other sources", %{path: path} do
    write = fn limit -> File.write!(path, Jason.encode!(%{backends: %{codex: %{hourly: %{used: 100, limit: limit}, observed_at: DateTime.to_iso8601(I.now())}}})) end
    write.(100)
    assert Usage.load(self(), opts(path)).durable.codex == %{percent: 100, observed_at: I.now()}
    write.(0)
    inputs = Usage.load(self(), opts(path))
    assert inputs.durable == %{}
    assert inputs.meters.codex.windows["primary"].used_percent == 42
    assert inputs.github == {:error, :unavailable}
    assert inputs.accounts == %{}
  end

  test "reload forwards facade update and locked read performs no I/O", %{path: path} do
    message = {AiurWeb.FinancialData, :updated, :identity}
    inputs = Usage.load(self(), Keyword.put(opts(path), :reload, message))
    assert inputs.meters.codex.provider == :codex
    assert_received {:reloaded, ^message}
    assert_received :loaded
    Usage.read(:locked, opts(path))
    assert Usage.subscribe(:locked) == :ok
    refute_received :loaded
    refute_received {:reloaded, _}
  end

  test "one failed source leaves account and quota values intact", %{path: path} do
    quota = I.quota()
    server = spawn_link(fn -> quota_server(quota) end)
    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :normal) end)
    read_opts = opts(path) |> Keyword.put(:meter_source, FailedSource) |> Keyword.put(:github_server, server) |> Keyword.put(:accounts_fun, fn -> %{"work" => I.account(1, 96)} end)
    inputs = Usage.load(self(), read_opts)
    assert inputs.meters == %{}
    assert inputs.github == {:ok, quota}
    assert inputs.accounts["work"].reading.windows |> hd() |> Map.fetch!(:used_percent) == 1
  end

  test "a quota server that never replies degrades only the GitHub chip, well inside the snapshot cap", %{path: path} do
    server = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
    on_exit(fn -> if Process.alive?(server), do: send(server, :stop) end)
    read_opts = opts(path) |> Keyword.put(:github_server, server)
    started = System.monotonic_time(:millisecond)
    assert {:ok, inputs} = Read.safe_read(fn -> {:ok, Usage.load(self(), read_opts)} end)
    # The default 1 s bound, not the 5 s GenServer default that used to eat the whole Read.safe_read cap.
    assert System.monotonic_time(:millisecond) - started < 2_500
    assert inputs.github == {:error, :unavailable}
    assert inputs.meters.codex.windows["primary"].used_percent == 42
  end

  test "a slow quota server uses its recent snapshot without delaying the build read", %{path: path} do
    server = start_quota(clock: fn -> I.now() end)
    reset_at = DateTime.add(I.now(), 3600)
    Quota.observe(server, request(:get, "/repos/owner/repo/issues") |> Map.put(:credential_id, "primary"), response("core", 5000, 3766, reset_at))
    Quota.observe(server, graphql_request("query { viewer { login } }", %{}) |> Map.put(:credential_id, "primary"), response("graphql", 5000, 4861, reset_at))

    # CI readiness uses an operator credential. It must not replace the
    # daemon credential's primary budget window shown by Units and Build.
    Quota.observe(server, request(:get, "/repos/owner/repo/issues") |> Map.put(:credential_id, "unregistered"), response("core", 5000, 4900, DateTime.add(I.now(), 1740)))
    quota = Quota.snapshot!(server)
    :sys.suspend(server)
    on_exit(fn -> if Process.alive?(server), do: :sys.resume(server) end)

    started = System.monotonic_time(:millisecond)
    inputs = Usage.load(self(), Keyword.put(opts(path), :github_server, server))

    assert System.monotonic_time(:millisecond) - started < 500
    assert {:ok, ^quota} = inputs.github
    assert quota.windows["core"].remaining == 3766
    assert quota.windows["graphql"].remaining == 4861
    assert is_integer(inputs.github_snapshot_observed_at)

    github = Usage.block({:ok, :context}, inputs, I.now()).apis |> hd()
    [core, graphql] = github.lines
    units_core = quota.windows["core"]
    assert core.acc == [100 - round(quota.windows["core"].used_percent)]
    assert graphql.acc == [100 - round(quota.windows["graphql"].used_percent)]
    assert core.reset_at == DateTime.to_unix(quota.windows["core"].reset_at, :millisecond)
    assert graphql.reset_at == DateTime.to_unix(quota.windows["graphql"].reset_at, :millisecond)
    assert core.tip == [["Requests left", "3,766 of 5,000 · #{100 - round(quota.windows["core"].used_percent)}% left"]]
    assert graphql.tip == [["Points left", "4,861 of 5,000 · #{100 - round(quota.windows["graphql"].used_percent)}% left"]]
    assert github.snapshot_observed_at == inputs.github_snapshot_observed_at
    assert ServiceRows.github_window_meta(units_core, I.now()) == "3766/5000 left · 75.3% left · resets in 1h 0m"
    stale_core = Map.merge(units_core, %{snapshot_stale?: true, observed_at: DateTime.add(I.now(), -1_200, :second)})
    assert ServiceRows.github_window_meta(stale_core, I.now()) == "3766/5000 left · 75.3% left · resets in 1h 0m · as of 11:40Z (20m ago)"
  end

  test "an expired quota snapshot uses the bounded fallback", %{path: path} do
    server = start_quota()
    Quota.observe(server, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 3766))
    _quota = Quota.snapshot!(server)
    :sys.suspend(server)
    on_exit(fn -> if Process.alive?(server), do: :sys.resume(server) end)
    expired_now = System.monotonic_time(:millisecond) + 60_001

    started = System.monotonic_time(:millisecond)
    inputs = Usage.load(self(), opts(path) |> Keyword.put(:github_server, server) |> Keyword.put(:github_cache_now_ms, expired_now))

    assert System.monotonic_time(:millisecond) - started < 2_500
    assert inputs.github == {:error, :unavailable}
  end

  defp quota_server(quota) do
    receive do
      {:"$gen_call", from, :snapshot} ->
        GenServer.reply(from, quota)
        quota_server(quota)
    end
  end
end
