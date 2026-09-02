defmodule Aiur.WorkflowStoreTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.WorkflowStore.Cache

  # A write that lands in the instant after the store reads the config must not
  # be swallowed. The store used to read the file twice per reload — once to
  # load the workflow, once to stamp it — so a write in between paired the new
  # content's digest with the old content's workflow. Every later stamp
  # comparison then said "unchanged" and the pre-write config was served from
  # the cache indefinitely.
  #
  # `:workflow_store_config_reader` stands in for that interleaving: it hands
  # the store the pre-write bytes and puts the post-write bytes on disk in the
  # same breath.
  test "a write landing while the store reads the config is not masked by the stamp" do
    ensure_workflow_store_running()

    # A config the store has never seen, so its first reload of it takes the
    # `load_state/2` path directly.
    path = Path.join([Path.dirname(Workflow.workflow_file_path()), "raced", ".aiur", "config"])
    File.mkdir_p!(Path.dirname(path))

    write_workflow_file!(path, poll_interval_seconds: 90)
    after_write = File.read!(path)

    write_workflow_file!(path, poll_interval_seconds: 45)
    before_write = File.read!(path)
    refute before_write == after_write

    # Fires once, on the store's own read: hand back what is on disk and land
    # the next write immediately behind it.
    Application.put_env(:aiur, :workflow_store_config_reader, fn read_path ->
      Application.delete_env(:aiur, :workflow_store_config_reader)
      content = File.read!(read_path)
      write_workflow_file_atomic!(read_path, after_write)
      {:ok, content}
    end)

    Workflow.set_workflow_file_path(path)
    :ok = WorkflowStore.force_reload()
    refute Application.get_env(:aiur, :workflow_store_config_reader), "the store never read through the seam"
    assert File.read!(path) == after_write

    # The raced write is on disk and nothing else touches the file. The store
    # must still notice it.
    assert :ok = WorkflowStore.force_reload()
    assert Config.settings!().polling.interval_seconds == 90
  end

  # Regression for #1214: a transient reload error must not advance the change
  # stamp. When it did, the store believed the failed content was already
  # current, skipped the next good reload, and kept serving the previous
  # config — `Config.workspace_root/0` then returned a prior test's value and
  # `CodingAgent.start_session` rejected the cwd with `:outside_workspace_root`.
  test "transient reload error does not mask the next good reload" do
    ensure_workflow_store_running()

    path = Workflow.workflow_file_path()
    dir = Path.dirname(path)
    root_after_recovery = Path.join(dir, "workspaces-after-recovery")

    staging = Path.join(dir, "v2config.yaml")
    write_workflow_file!(staging, workspace_root: root_after_recovery)

    # `prewarm.base_build_file` is read by `Workflow.load/1` but is not part
    # of the change stamp — exactly the shape of a transient load error the
    # stamp cannot see, so a poisoned stamp would never heal on its own.
    File.write!(path, File.read!(staging) <> "\nprewarm:\n  base_build_file: prewarm\n")

    assert {:error, {:missing_prewarm_file, _prewarm_path, :enoent}} = WorkflowStore.force_reload()

    File.write!(Path.join(dir, "prewarm"), "true\n")

    assert :ok = WorkflowStore.force_reload()
    assert Config.workspace_root() == root_after_recovery

    File.write!(Path.join(dir, "prewarm"), "echo rebuilt\n")

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{prewarm: %{base_build: "echo rebuilt"}}} = Config.settings()
  end

  # Regression for #1684: the store is a cache over one small config file, so a
  # stalled store must degrade to reading that file, never kill its caller. When
  # `:timeout` fell through the catch, `Config.settings!/0` — reached from the
  # `aiur status` render path — killed the RPC evaluator, and the operator saw a
  # non-zero exit with an empty buffer.
  #
  # Since #1731 a stalled store is stronger than "does not kill the caller": the
  # read path never touches the store's mailbox, so it serves the cached value
  # (with its real generation) and does not wait at all. The fallback proven
  # here still exists — see `WorkflowStoreReadPathTest`, which kills the store
  # outright — but a merely-suspended store is no longer even a slow path.
  test "a stalled store falls back to the config file instead of killing the caller" do
    ensure_workflow_store_running()

    pid = Process.whereis(WorkflowStore)

    # Captured while the store is healthy so the suspended read below can be
    # pinned to it exactly. Asserting only "integer or :unknown" would span the
    # whole declared return type and could never fail.
    assert {:ok, _workflow, generation} = WorkflowStore.current_with_generation()
    assert is_integer(generation)

    Application.put_env(:aiur, :workflow_store_call_timeout_ms, 25)
    :sys.suspend(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: :sys.resume(pid)
      Application.delete_env(:aiur, :workflow_store_call_timeout_ms)
    end)

    assert {:ok, %{config: config}} = WorkflowStore.current()
    assert is_map(config)

    # The suspended store cannot answer, so this is served from the cache — with
    # the real generation it was published under, not a `:unknown` fallback.
    assert {:ok, %{config: %{}}, ^generation} = WorkflowStore.current_with_generation()

    # The whole point: a saturated store must not take the read path down with it.
    assert %Aiur.Config.Schema{} = Config.settings!()
  end

  test "a missing ETS publication falls back to the live store state" do
    ensure_workflow_store_running()
    path = Workflow.workflow_file_path()

    write_workflow_file!(path, prompt: "Live store prompt")
    assert {:ok, %{prompt: "Live store prompt"}} = WorkflowStore.current()

    File.write!(path, "invalid: [")
    :ets.delete(Cache.table(), :current)

    assert {:ok, %{prompt: "Live store prompt"}, :unknown, :unknown} = WorkflowStore.current_with_cache_identity()
  end

  # Regression for #2133: the singleton's cache can be re-pointed at a *different*
  # config by a reload that lands between a case's `write_workflow_file!/2`
  # (write + awaited `force_reload`) and its read. Reads are fenced to their own
  # current path, so such a reload must not be observable: `current/0` refuses a
  # cache entry whose path differs and falls back to reading the caller's path
  # from disk instead.
  test "reads are fenced to the configured path and ignore a reload from another path" do
    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)
    path = Workflow.workflow_file_path()

    write_workflow_file!(path, prompt: "Fenced prompt")
    assert {:ok, %{prompt: "Fenced prompt"}} = WorkflowStore.current()

    other = Path.join(Path.dirname(path), "fenced-other-config.yaml")
    write_workflow_file!(other, prompt: "Other prompt")

    # Re-point the singleton at `other` and reload it, then move the env path
    # back to `path` WITHOUT a reload — the clobbered state a concurrent reload
    # leaves behind. Suspending the store keeps its own poll from healing the
    # stale cache mid-assertion, so the fence path is exercised deterministically.
    Workflow.set_workflow_file_path(other)
    :ok = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Other prompt"}} = WorkflowStore.current()
    :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      Workflow.set_workflow_file_path(path)
      :ok = ensure_workflow_store_running()
      :ok = WorkflowStore.force_reload()
    end)

    # Move the path back via the managed setter so this process's per-process
    # view stays in sync with the app env it restores. A raw
    # `Application.put_env` would only touch the app env and leave the
    # process-dictionary override — pinned at `other` by the
    # `set_workflow_file_path(other)` call above — still in force. `reload:
    # false` keeps the cache pointing at `other` so the fence below is
    # exercised deterministically.
    Workflow.set_workflow_file_path(path, reload: false)

    # The cache still holds `other`; a reader at `path` must not observe it.
    assert {:ok, %{prompt: "Fenced prompt"}} = WorkflowStore.current()
    assert {:ok, %{prompt: "Fenced prompt"}, :unknown} = WorkflowStore.current_with_generation()
    assert %Aiur.Config.Schema{} = Config.settings!()
    assert Config.workflow_prompt() == "Fenced prompt"
  end

  # A reader can finish parsing after a reload has deleted the derived-value
  # entries. If generations are ever reused, that late reader must not be able
  # to publish settings for old content under the current content's cache key.
  test "a late settings write cannot survive different config content under a reused generation" do
    ensure_workflow_store_running()
    path = Workflow.workflow_file_path()

    write_workflow_file!(path,
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    assert {:ok, valid_workflow, generation} = WorkflowStore.current_with_generation()
    assert {:ok, {"owner", "repo"}} = GitHubConfig.configured_repo()
    assert [{:settings, stale_key, stale_settings}] = :ets.lookup(Cache.table(), :settings)
    assert {{^generation, publication}, _env_epoch} = stale_key
    assert is_reference(publication)

    store = Process.whereis(WorkflowStore)
    :sys.suspend(store)
    on_exit(fn -> if Process.alive?(store), do: :sys.resume(store) end)

    invalid_workflow = put_in(valid_workflow, [:config, "tracker", "github", "repo"], "owner/repo/extra")

    :ok = Cache.put(invalid_workflow, generation, path)
    :ok = Cache.put_settings(stale_key, stale_settings)

    assert {:error, :invalid_configured_repository} = GitHubConfig.configured_repo()
  end

  # The store is a supervised singleton, so it can die between `force_reload/1`
  # checking the registered name and issuing its call. That window turned a
  # sibling test's restart into an EXIT inside an unrelated test — the failure
  # that took down `WorkspaceAndConfigTest` in CI run 31897085819. A caller is
  # promised `:ok | {:error, term()}`, so a dying store must not exit it.
  test "force_reload survives the store dying while the call is in flight" do
    ensure_workflow_store_running()
    :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)

    # Stands in for a store that is registered when `force_reload/1` looks the
    # name up and gone by the time the call lands.
    dying = spawn(fn -> receive do: (_message -> exit(:shutdown)) end)
    true = Process.register(dying, WorkflowStore)
    on_exit(fn -> restore_real_store(dying) end)

    assert WorkflowStore.force_reload() == :ok
  end

  # OTP's shutdown reason may carry a payload, and `GenServer.call/3` then puts
  # the whole `{:shutdown, term}` tuple in the reason position — where a
  # `reason in [...]` guard cannot match it. That shape has its own catch clause,
  # so it needs its own regression test.
  test "force_reload survives a store shutting down with a reason payload" do
    ensure_workflow_store_running()
    :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)

    dying = spawn(fn -> receive do: (_message -> exit({:shutdown, :restarting})) end)
    true = Process.register(dying, WorkflowStore)
    on_exit(fn -> restore_real_store(dying) end)

    assert WorkflowStore.force_reload() == :ok
  end

  # The reason that made a whitelist untenable. `start_link/1` registers the
  # name before `init/1` runs, and `init/1` stops with `{:missing_workflow_file,
  # path}` when a sibling transiently points the config path at a missing file —
  # which `test/support/test_support.exs` documents as real in this suite. So a
  # caller can look the name up successfully and still have its call land on a
  # process that is stopping with a config tuple no fixed list would cover.
  test "force_reload survives a store whose init stops with a config error" do
    ensure_workflow_store_running()
    :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)

    dying = spawn(fn -> receive do: (_message -> exit({:missing_workflow_file, "/nonexistent/config.yaml"})) end)
    true = Process.register(dying, WorkflowStore)
    on_exit(fn -> restore_real_store(dying) end)

    assert WorkflowStore.force_reload() == :ok
  end

  # The counterpart guarantee: a store that is alive but not answering really can
  # be serving a stale cache, so that must stay visible rather than be absorbed
  # by the death fallback above.
  test "force_reload still surfaces a timeout from a live but unresponsive store" do
    ensure_workflow_store_running()
    :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)

    silent = spawn(fn -> Process.sleep(:infinity) end)
    true = Process.register(silent, WorkflowStore)
    on_exit(fn -> restore_real_store(silent) end)

    assert {:timeout, _call} = catch_exit(WorkflowStore.force_reload(25))
  end

  describe "base branch change announcement" do
    test "publishes system.config.base_branch.changed with old and new bases" do
      ensure_workflow_store_running()
      :ok = Exchange.subscribe("system.config.base_branch.changed")

      # The TestSupport setup already committed the default (`main`); re-writing
      # the same base is a no-change reload that must NOT announce. Then a real
      # transition must.
      write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "main")
      write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "develop")

      assert_receive {:event, event}, 2_000
      assert event.topic == "system.config.base_branch.changed"
      assert event.old_base == "main"
      assert event.new_base == "develop"
      assert event["message"] =~ "from main to develop"
    end

    test "does not announce when the base branch is unchanged" do
      ensure_workflow_store_running()
      :ok = Exchange.subscribe("system.config.base_branch.changed")

      write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "main")
      write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "main")

      refute_receive {:event, _event}, 300
    end
  end

  # `Process.exit/2` is asynchronous, so the stub can still hold the registered
  # name when the restart runs. `restart_workflow_store/1` treats an
  # `{:already_started, _}` result as success by falling back to the registered
  # name, so losing that race would leave the stub — not the real singleton —
  # registered as `Aiur.WorkflowStore` for every later test in this VM. Wait for
  # the stub to actually be gone before restarting.
  defp restore_real_store(stub) do
    ref = Process.monitor(stub)
    Process.exit(stub, :kill)

    receive do
      {:DOWN, ^ref, :process, ^stub, _reason} -> :ok
    after
      5_000 -> flunk("stub standing in for #{inspect(WorkflowStore)} did not exit")
    end

    :ok = ensure_workflow_store_running()
    assert Process.whereis(WorkflowStore) != stub
  end
end
