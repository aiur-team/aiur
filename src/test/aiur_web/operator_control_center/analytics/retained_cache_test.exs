defmodule AiurWeb.OperatorControlCenter.Analytics.RetainedCacheTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.RunTelemetry.{RetainedCache, Summaries}
  alias AiurWeb.OperatorControlCenter.Analytics.LatestRun

  test "concurrent latest cold loads survive the first requester exiting" do
    parent = self()
    key = make_ref()
    dataset = %{tickets: %{1 => %{}}, provenance: %{time_range: %{end: "2026-10-09T00:00:00Z"}}}

    loader = fn ->
      send(parent, {:started, self()})
      receive do: (:release -> {[dataset], false})
    end

    opts = [cache_identity: key, prior_loader: loader]
    file = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.ndjson")
    first = spawn(fn -> LatestRun.load(file, "current", &analyzable?/1, opts) end)
    assert_receive {:started, worker}, 1_000
    spawn(fn -> send(parent, {:result, LatestRun.load(file, "current", &analyzable?/1, opts)}) end)
    await_waiters({LatestRun, {key, nil}}, 2)
    owner = :ets.info(LatestRun, :owner)
    assert owner != first
    Process.exit(first, :kill)
    assert Process.alive?(worker)
    assert Process.alive?(owner)
    send(worker, :release)
    assert_receive {:result, {:ok, ^dataset}}, 1_000
    refute_receive {:started, _worker}, 50
    assert {:ok, ^dataset} = LatestRun.load(file, "current", &analyzable?/1, Keyword.put(opts, :prior_loader, fn -> flunk("warm request rescanned") end))
  end

  test "coalesced failures reach every waiter and a later request retries" do
    parent = self()
    key = make_ref()

    loader = fn ->
      send(parent, {:started, self()})
      receive do: (:release -> {:error, :retained_unreadable})
    end

    for _ <- 1..2, do: spawn(fn -> send(parent, {:result, RetainedCache.fetch(__MODULE__, key, loader)}) end)
    assert_receive {:started, worker}, 1_000
    await_waiters({__MODULE__, key}, 2)
    send(worker, :release)
    assert_receive {:result, {:error, :retained_unreadable}}, 1_000
    assert_receive {:result, {:error, :retained_unreadable}}, 1_000
    refute_receive {:started, _pid}, 50
    assert :recovered = RetainedCache.fetch(__MODULE__, key, fn -> :recovered end)
  end

  test "future regression guard: raised loader failures propagate without poisoning retries" do
    key = make_ref()
    assert_raise ArgumentError, "broken summary", fn -> RetainedCache.fetch(__MODULE__, key, fn -> raise ArgumentError, "broken summary" end) end
    assert :recovered = RetainedCache.fetch(__MODULE__, key, fn -> :recovered end)
  end

  test "bounds both cumulative cached bytes and entry count" do
    table = Module.concat(__MODULE__, ByteLimit)
    value = :binary.copy("x", 12 * 1024 * 1024 - 16)
    for key <- 1..3, do: assert(value == RetainedCache.fetch(table, key, fn -> value end, max_value_bytes: 12 * 1024 * 1024))
    assert :ets.info(table, :size) == 1
    assert [{3, ^value}] = :ets.tab2list(table)
    for key <- 4..15, do: assert(key == RetainedCache.fetch(table, key, fn -> key end))
    assert :ets.info(table, :size) <= 8
    assert :oversized = RetainedCache.fetch(table, :oversized, fn -> :oversized end, max_value_bytes: 0)
    assert :ets.lookup(table, :oversized) == []
  end

  test "retained identity changes when a summary is atomically replaced in its boot directory" do
    root = Aiur.TestSupport.tmp_root!("retained-identity")
    previous = for key <- [:repo_base_root, :analytics_repo], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "test/retained-identity")
    runs = Path.join(Aiur.RepoBase.repo_path("test/retained-identity"), "analytics/runs")
    File.mkdir_p!(Path.join(runs, "boot-a"))
    summary = Path.join([runs, "boot-a", "run-summary.json"])
    File.write!(summary, "old-summary")
    identity = RetainedCache.summaries_identity("current")

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env(previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    replacement = Path.join(Path.dirname(summary), "run-summary.tmp")
    File.write!(replacement, "new-summary")
    File.rename!(replacement, summary)
    refute RetainedCache.summaries_identity("current") == identity

    path = Path.join(runs, "boot-b")
    File.mkdir_p!(path)
    assert ["boot-a", "boot-b"] = RetainedCache.summaries_identity("current") |> Enum.map(&elem(&1, 0))
  end

  test "dashboard cache identity changes when a summary is rewritten in an existing boot" do
    root = Aiur.TestSupport.tmp_root!("retained-directory-identity")
    previous = for key <- [:repo_base_root, :analytics_repo], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "test/retained-directory-identity")
    runs = Summaries.runs_dir()
    File.mkdir_p!(runs)

    for boot <- 1..256 do
      File.mkdir_p!(Path.join(runs, "boot-#{boot}"))
      File.write!(Summaries.run_summary_path("boot-#{boot}"), "summary")
    end

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env(previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    identity = RetainedCache.identity(nil)

    replacement = Path.join([runs, "boot-1", "run-summary.tmp"])
    File.write!(replacement, "replacement-summary")
    File.rename!(replacement, Summaries.run_summary_path("boot-1"))
    refute identity == RetainedCache.identity(nil)
  end

  test "identity warming runs in the background and invalidation schedules another warm" do
    root = Aiur.TestSupport.tmp_root!("retained-identity-warm")
    previous = for key <- [:repo_base_root, :analytics_repo], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "test/retained-identity-warm")
    File.mkdir_p!(Summaries.runs_dir())

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env(previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    key = {Summaries.state_node(), Aiur.RunTelemetry.boot_id()}
    RetainedCache.warm_identity_async(self())
    receive_barrier(:retained_identity_warmed)
    assert :ets.lookup(Aiur.RunTelemetry.RetainedCache.Identity, key) != []

    RetainedCache.invalidate_identity(self())
    receive_barrier(:retained_identity_warmed)
    assert :ets.lookup(Aiur.RunTelemetry.RetainedCache.Identity, key) != []
  end

  test "identity and invalidation start the cache when no instance is supervised" do
    # A --no-dashboard daemon has no supervised cache; callers must not exit :noproc.
    :ok = Supervisor.terminate_child(Aiur.Supervisor, RetainedCache)

    try do
      refute GenServer.whereis(RetainedCache)
      assert RetainedCache.invalidate_identity() == :ok
      GenServer.stop(RetainedCache)

      {state_node, nil, _identity} = RetainedCache.identity(nil)
      assert state_node == Summaries.state_node()
    after
      if pid = GenServer.whereis(RetainedCache), do: GenServer.stop(pid)
      {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, RetainedCache)
    end
  end

  test "latest-run decodes newest analyzable summary only" do
    root = Aiur.TestSupport.tmp_root!("latest-run-index")
    previous = for key <- [:repo_base_root, :analytics_repo], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "test/latest-run-index")
    runs = Path.join(Aiur.RepoBase.repo_path("test/latest-run-index"), "analytics/runs")
    for boot <- ["boot-old", "boot-middle", "boot-new"], do: File.mkdir_p!(Path.join(runs, boot))

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env(previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    parent = self()
    dataset = %{tickets: %{"7" => %{}}, actors: %{}, provenance: %{time_range: %{end: "2026-10-18T03:00:00Z"}}}
    times = %{"boot-old" => "2026-10-18T01:00:00Z", "boot-middle" => "2026-10-18T02:00:00Z", "boot-new" => "2026-10-18T03:00:00Z"}

    opts = [
      cache_identity: make_ref(),
      summary_index_loader: fn boot ->
        send(parent, {:indexed, boot})
        {:ok, Map.fetch!(times, boot), 256 * 1024, 10 * 1024 * 1024}
      end,
      summary_dataset_loader: fn boot ->
        send(parent, {:decoded, boot})
        {:ok, dataset}
      end
    ]

    assert {:ok, result} = LatestRun.load(Path.join(root, "missing.ndjson"), "live", &analyzable?/1, opts)
    assert Map.drop(result, [:retained_runs]) == dataset
    assert result.retained_runs == %{included: 1, total: 3, skipped_large: 0, skipped_newer: 0}

    receive_barrier({:indexed, "boot-middle"})
    receive_barrier({:indexed, "boot-new"})
    receive_barrier({:indexed, "boot-old"})
    indexed = MapSet.new(["boot-middle", "boot-new", "boot-old"])

    assert indexed == MapSet.new(Map.keys(times))
    assert_received {:decoded, "boot-new"}
    refute_received {:decoded, _older_boot}
  end

  defp analyzable?(dataset), do: map_size(dataset.tickets) > 0

  defp await_waiters(id, count, attempts \\ 100) do
    if length(:sys.get_state(RetainedCache).pending[id].waiters) < count do
      assert attempts > 0
      Process.sleep(10)
      await_waiters(id, count, attempts - 1)
    end
  end
end
