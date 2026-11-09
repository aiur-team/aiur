defmodule Aiur.GitHub.BudgetBrokerCheckpointTelemetryTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Budget, BudgetBroker}

  test "checkpoint age and WAL size are retained after a broker command", %{test: test} do
    root = Aiur.TestSupport.tmp_root!("budget-broker-checkpoint")
    server = start_supervised!({BudgetBroker, name: Module.concat(__MODULE__, test)})
    opts = [state_dir: root, stagger_ms: 0, broker_server: server, enabled?: true]
    request = %{token: "daemon-token", url: "https://api.github.com/repos/owner/repo/issues"}

    assert {:ok, lease} = Budget.acquire(request, opts)
    assert :ok = Budget.release(lease, opts)

    # The checkpoint runs on a background Python thread, and a command reply
    # carries its timing only once that thread has finished; retry until one does.
    assert Enum.any?(1..50, fn _ ->
             Budget.snapshot("daemon-token", opts)

             Enum.any?(:sys.get_state(server).stats, fn {_outcome, measurements} ->
               is_number(measurements[:sqlite_checkpoint_ms]) and
                 is_number(measurements[:sqlite_checkpoint_age_ms]) and
                 is_integer(measurements[:sqlite_wal_size_bytes])
             end)
           end)
  end
end

defmodule Aiur.GitHub.BudgetBrokerCheckpointTest do
  use ExUnit.Case, async: false

  test "a dead checkpoint worker triggers the in-request WAL fallback" do
    root = Aiur.TestSupport.tmp_root!("budget-broker-checkpoint")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    script = """
    import importlib.util, sqlite3, sys
    spec = importlib.util.spec_from_file_location("metrics", sys.argv[1])
    metrics = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metrics)
    db = sys.argv[2]
    conn = sqlite3.connect(db, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE values_table(value)")
    conn.execute("INSERT INTO values_table VALUES (1)")
    metrics.CHECKPOINT_THREAD = None
    metrics.CHECKPOINT_REQUESTS = __import__("queue").Queue(maxsize=1)
    metrics.CHECKPOINT_REQUESTS.put(db)
    status = metrics.recover_checkpoint_if_needed(db, conn)
    assert metrics.LAST_SUCCESSFUL_CHECKPOINT_NS is not None
    assert conn.execute("PRAGMA wal_checkpoint(PASSIVE)").fetchone()[2] >= 2
    conn.close()
    """

    metrics = Path.expand("../../../priv/github_budget_metrics.py", __DIR__)
    db = Path.join(root, "fallback.sqlite3")
    assert {output, 0} = System.cmd("python3", ["-c", script, metrics, db], stderr_to_stdout: true)
    assert output =~ "fallback checkpoint ran"
  end

  test "an idle worker falls back at the observed frame limit only once" do
    root = Aiur.TestSupport.tmp_root!("budget-broker-checkpoint-frames")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    script = """
    import importlib.util, queue, sqlite3, sys, threading, time
    spec = importlib.util.spec_from_file_location("metrics", sys.argv[1])
    metrics = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metrics)
    db = sys.argv[2]
    inner = sqlite3.connect(db, isolation_level=None)
    inner.execute("PRAGMA journal_mode=WAL")
    inner.execute("CREATE TABLE values_table(value)")
    inner.execute("INSERT INTO values_table VALUES (1)")
    class Alive:
        def is_alive(self): return True
    class CountingConnection:
        def __init__(self, conn): self.conn, self.restarts = conn, 0
        def execute(self, sql):
            if sql == "PRAGMA wal_checkpoint(RESTART)": self.restarts += 1
            return self.conn.execute(sql)
    conn = CountingConnection(inner)
    metrics.CHECKPOINT_REQUESTS = queue.Queue(maxsize=1)
    metrics.CHECKPOINT_ACTIVE = threading.Event()
    metrics.CHECKPOINT_THREAD = Alive()
    metrics.LAST_OBSERVED_WAL_FRAMES = 11
    metrics.WAL_FRAME_LIMIT = 10
    metrics.LAST_SUCCESSFUL_CHECKPOINT_NS = time.monotonic_ns()
    metrics.recover_checkpoint_if_needed(db, conn)
    metrics.recover_checkpoint_if_needed(db, conn)
    assert conn.restarts == 1
    assert metrics.LAST_OBSERVED_WAL_FRAMES == 0
    inner.close()
    """

    metrics = Path.expand("../../../priv/github_budget_metrics.py", __DIR__)
    db = Path.join(root, "frames.sqlite3")
    assert {output, 0} = System.cmd("python3", ["-c", script, metrics, db], stderr_to_stdout: true)
    assert output == "budget broker checkpoint worker fallback checkpoint ran\n"
  end

  test "checkpoint age uses worker startup before the first successful checkpoint" do
    root = Aiur.TestSupport.tmp_root!("budget-broker-checkpoint-age")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    script = """
    import importlib.util, sys, time
    spec = importlib.util.spec_from_file_location("metrics", sys.argv[1])
    metrics = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metrics)
    metrics.CHECKPOINT_STARTED_NS = time.monotonic_ns() - 601_000_000_000
    status = metrics.checkpoint_status(sys.argv[2])
    assert status["sqlite_checkpoint_age_ms"] > 600_000
    assert status["sqlite_checkpoint_stale"] is True
    """

    metrics = Path.expand("../../../priv/github_budget_metrics.py", __DIR__)
    db = Path.join(root, "age.sqlite3")
    assert {output, 0} = System.cmd("python3", ["-c", script, metrics, db], stderr_to_stdout: true)
    assert output == ""
  end

  test "a successful worker checkpoint refreshes the checkpoint age" do
    root = Aiur.TestSupport.tmp_root!("budget-broker-checkpoint-worker")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    script = """
    import importlib.util, sqlite3, sys, time
    spec = importlib.util.spec_from_file_location("metrics", sys.argv[1])
    metrics = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metrics)
    db = sys.argv[2]
    conn = sqlite3.connect(db, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE values_table(value)")
    metrics.start_checkpoint_worker()
    metrics.schedule_checkpoint(db)
    deadline = time.monotonic() + 5
    while metrics.take_checkpoint_result(db) is None and time.monotonic() < deadline:
        time.sleep(0.01)
    assert metrics.LAST_SUCCESSFUL_CHECKPOINT_NS is not None
    conn.close()
    """

    metrics = Path.expand("../../../priv/github_budget_metrics.py", __DIR__)
    db = Path.join(root, "worker.sqlite3")
    assert {output, 0} = System.cmd("python3", ["-c", script, metrics, db], stderr_to_stdout: true)
    assert output == ""
  end
end
