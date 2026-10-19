defmodule Aiur.GitHub.BudgetBrokerTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Budget, BudgetBroker, Errors}

  setup do
    root = Aiur.TestSupport.tmp_root!("resident-budget-broker")
    File.mkdir_p!(root)
    server = start_supervised!({BudgetBroker, name: __MODULE__})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root, server: server}
  end

  test "Budget routes daemon commands through its resident server", %{root: root, server: server} do
    opts = [state_dir: root, stagger_ms: 0, broker_server: server, enabled?: true]
    request = %{token: "daemon-token", url: "https://api.github.com/repos/owner/repo/issues"}
    assert {:ok, lease} = Budget.acquire(request, opts)
    port = :sys.get_state(server).port
    assert is_port(port)
    assert :ok = Budget.release(lease, opts)
    assert %{admissions: [_], inflight: %{}} = Budget.snapshot("daemon-token", opts)
    assert :sys.get_state(server).port == port
  end

  # #4791: bulk polling that fills every slot must not hold the main watcher.
  test "a priority admission may hold one lease above the in-flight caps", %{root: root, server: server} do
    args = acquire_args(root)
    for _ <- 1..2, do: assert({:ok, "granted " <> _lease, 0} = command(server, Budget.broker_path(), args))
    assert {:ok, "wait " <> _ms, 0} = command(server, Budget.broker_path(), args)
    assert {:ok, "granted " <> _lease, 0} = command(server, Budget.broker_path(), args ++ ["--priority"])
    assert {:ok, "wait " <> _ms, 0} = command(server, Budget.broker_path(), args ++ ["--priority"])
  end

  test "a prioritized process passes --priority to the broker", %{root: root, server: server} do
    opts = [state_dir: root, stagger_ms: 0, broker_server: server, enabled?: true, max_inflight: 1, max_inflight_per_endpoint: 1]
    request = %{token: "daemon-token", url: "https://api.github.com/repos/owner/repo/issues"}
    assert {:ok, _lease} = Budget.acquire(request, opts)
    assert {:hold, %{reason: :shared_budget}} = Budget.acquire(request, Keyword.put(opts, :timeout_ms, 1_000))

    assert {:ok, _lease} =
             Task.async(fn ->
               Budget.prioritize()
               Budget.acquire(request, opts)
             end)
             |> Task.await()
  end

  test "admission and release reuse the daemon port and remain visible to a separate broker", %{root: root, server: server} do
    args = acquire_args(root)
    assert {:ok, "granted " <> lease, 0} = command(server, Budget.broker_path(), args)
    port = :sys.get_state(server).port
    assert {:ok, _output, 0} = command(server, Budget.broker_path(), ["release", "--lease-id", String.trim(lease)] ++ common(root))
    assert :sys.get_state(server).port == port

    {output, 0} = System.cmd("python3", [Budget.broker_path(), "snapshot" | common(root)])
    snapshot = Jason.decode!(output)
    assert snapshot["inflight"] == %{}
    assert length(snapshot["admissions"]) == 1
  end

  test "concurrent resident processes enforce one shared credential ceiling", %{root: root, server: server} do
    other = start_supervised!({BudgetBroker, name: __MODULE__.Other}, id: :other)
    # Freeze the wall clock at its boundary so the zero-stagger policy cannot
    # introduce incidental waits from pre-lock timestamps read by another peer.
    broker = Path.join(root, "frozen_clock.py")

    File.write!(broker, """
    import importlib.util
    spec = importlib.util.spec_from_file_location("broker", #{inspect(Budget.broker_path())})
    broker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(broker)
    broker.now_ms = lambda: #{System.system_time(:millisecond)}
    broker.serve()
    """)

    args = acquire_args(root)
    parent = self()

    tasks =
      Enum.map(1..8, fn n ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> command(if(rem(n, 2) == 0, do: server, else: other), broker, args)
          end
        end)
      end)

    Enum.each(tasks, fn task ->
      receive do
        {:ready, pid} when pid == task.pid -> :ok
      end
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, "granted " <> _, 0}, &1)) == 2
    assert Enum.count(results, &match?({:ok, "wait " <> _, 0}, &1)) == 6
    assert {:ok, output, 0} = command(server, broker, ["snapshot" | common(root)])
    assert %{"inflight" => %{"rest" => 2}, "admissions" => [_, _]} = Jason.decode!(output)
  end

  test "one batch commits successful admissions and rolls back only its failing command", %{root: root} do
    script = """
    import importlib.util, json, sqlite3, sys, time
    spec = importlib.util.spec_from_file_location("broker", sys.argv[1])
    broker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(broker)
    broker.SESSION_CONNECTIONS = {}
    args = json.loads(sys.argv[2])
    db = args[args.index("--db") + 1]
    conn = broker.connection(db)
    conn.execute("CREATE TRIGGER reject_bad BEFORE INSERT ON policies WHEN NEW.consumer_key = 'bad' BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
    statements = []
    conn.conn.set_trace_callback(statements.append)
    requests = []
    for n, consumer in enumerate(["first", "bad", "last"]):
        command = list(args)
        command[command.index("--consumer-key") + 1] = consumer
        command[command.index("--max-inflight") + 1] = "3"
        command[command.index("--max-inflight-per-endpoint") + 1] = "3"
        requests.append({"id": n, "args": command, "deadline_ms": int(time.time() * 1000) + 5000})
    replies = list(broker.run_batch(requests, broker.parser()))
    # Read through an independent connection after the replies are returned.
    external = sqlite3.connect(db)
    print(json.dumps({"statuses": [reply["status"] for reply in replies],
        "leases": external.execute("SELECT COUNT(*) FROM leases").fetchone()[0],
        "consumers": [row[0] for row in external.execute("SELECT consumer_key FROM admissions ORDER BY id")],
        "begins": statements.count("BEGIN IMMEDIATE"), "commits": statements.count("COMMIT")}))
    """

    {output, 0} = System.cmd("python3", ["-c", script, Budget.broker_path(), Jason.encode!(acquire_args(root))])
    assert Jason.decode!(output) == %{"statuses" => [0, 1, 0], "leases" => 2, "consumers" => ["first", "last"], "begins" => 1, "commits" => 1}
  end

  test "an expired caller cannot consume the next caller's reply", %{root: root, server: server} do
    broker = Path.join(root, "late.py")

    File.write!(broker, """
    import json, sys
    first = json.loads(sys.stdin.readline())
    second = json.loads(sys.stdin.readline())
    for request, output in [(first, "late"), (second, "current")]:
        print(json.dumps({"id": request["id"], "output": output, "status": 0}), flush=True)
    for line in sys.stdin:
        pass
    """)

    assert :timeout = BudgetBroker.command(server, broker, [], System.monotonic_time(:millisecond) + 100)
    assert {:ok, "current", 0} = command(server, broker, [])
    assert :sys.get_state(server).pending == %{}
  end

  test "a locked resident admission expires without a late lease and recovers after unlock", %{root: root, server: server} do
    args = acquire_args(root)
    assert {:ok, "granted " <> lease, 0} = command(server, Budget.broker_path(), args)
    assert {:ok, _, 0} = command(server, Budget.broker_path(), ["release", "--lease-id", String.trim(lease)] ++ common(root))
    port = :sys.get_state(server).port

    script = """
    import sqlite3, sys
    conn = sqlite3.connect(sys.argv[1], isolation_level=None)
    conn.execute("BEGIN IMMEDIATE")
    print("locked", flush=True)
    sys.stdin.readline()
    conn.execute("COMMIT")
    print("released", flush=True)
    """

    lock = Port.open({:spawn_executable, System.find_executable("python3")}, [:binary, :exit_status, args: ["-c", script, Path.join(root, "budget.sqlite3")]])
    on_exit(fn -> if Port.info(lock), do: Port.close(lock) end)

    receive do
      {^lock, {:data, "locked\n"}} -> :ok
    end

    assert :timeout = BudgetBroker.command(server, Budget.broker_path(), args, System.monotonic_time(:millisecond) + 50)
    Port.command(lock, "\n")

    receive do
      {^lock, {:data, "released\n"}} -> :ok
    end

    assert {:ok, snapshot, 0} = command(server, Budget.broker_path(), ["snapshot" | common(root)])
    assert %{"inflight" => %{}, "admissions" => [_]} = Jason.decode!(snapshot)
    assert {:ok, "granted " <> _, 0} = command(server, Budget.broker_path(), args)
    assert :sys.get_state(server).port == port
  end

  test "a broker crash fails pending calls and a later call starts a new port", %{root: root, server: server} do
    broker = Path.join(root, "crash.py")

    File.write!(broker, """
    import json, sys
    for line in sys.stdin:
        request = json.loads(line)
        if request["args"] == ["crash"]:
            sys.exit(7)
        print(json.dumps({"id": request["id"], "output": "restarted", "status": 0}), flush=True)
    """)

    assert :timeout = command(server, broker, ["crash"])
    assert {:ok, "restarted", 0} = command(server, broker, [])
  end

  test "a crash holds every pending Budget caller locally and recovers", %{root: root, server: server} do
    broker = Path.join(root, "pending_crash.py")

    File.write!(broker, """
    import json, sys
    first = json.loads(sys.stdin.readline())
    print(json.dumps({"id": first["id"], "output": "ready", "status": 0}), flush=True)
    sys.stdin.readline()
    sys.stdin.readline()
    sys.exit(7)
    """)

    assert {:ok, "ready", 0} = command(server, broker, [])
    opts = [state_dir: root, stagger_ms: 0, broker_server: server, enabled?: true]
    request = %{token: "daemon-token", url: "https://api.github.com/repos/owner/repo/issues"}
    tasks = Enum.map(1..2, fn _ -> Task.async(fn -> Budget.acquire(request, opts) end) end)

    Enum.each(tasks, fn task ->
      assert {:error, :github_budget_broker_timeout} = result = Task.await(task, 5_000)
      assert {:github, :local_hold, %{reason: :github_budget_broker_timeout}} = Errors.classify_error(result)
    end)

    assert :sys.get_state(server).pending == %{}
    assert {:ok, lease} = Budget.acquire(request, opts)
    assert :ok = Budget.release(lease, opts)
  end

  test "failed serialization advances correlation without expiring a subsequent caller", %{root: root, server: server} do
    broker = Path.join(root, "delayed.py")

    File.write!(broker, """
    import json, sys, time
    for line in sys.stdin:
        request = json.loads(line)
        time.sleep(0.2)
        print(json.dumps({"id": request["id"], "output": "current", "status": 0}), flush=True)
    """)

    assert :timeout = BudgetBroker.command(server, broker, [self()], System.monotonic_time(:millisecond) + 50)
    assert %{next_id: 1, pending: %{}, port: nil} = :sys.get_state(server)
    assert {:ok, "current", 0} = command(server, broker, [])
    assert %{next_id: 2, pending: %{}} = :sys.get_state(server)
  end

  test "broker completions report latency, pending requests and mailbox depth", %{root: root} do
    test_pid = self()

    handler =
      :telemetry.attach(
        "budget-broker-observed-#{inspect(test_pid)}",
        [:aiur, :github, :budget_broker, :command],
        fn event, measurements, metadata, pid ->
          send(pid, {event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    server = start_supervised!({BudgetBroker, name: __MODULE__.Observed}, id: :observed)
    broker = Path.join(root, "observed.py")

    File.write!(broker, """
    import json, sys
    for line in sys.stdin:
        request = json.loads(line)
        print(json.dumps({"id": request["id"], "output": "ok", "status": 0}), flush=True)
    """)

    assert {:ok, "ok", 0} = command(server, broker, [])

    assert_receive {[:aiur, :github, :budget_broker, :command], %{duration_ms: duration, mailbox_wait_ms: mailbox_wait, pending: pending, mailbox: mailbox}, %{outcome: :completed}}, 1_000
    assert is_integer(duration) and duration >= 0
    assert is_integer(mailbox_wait) and mailbox_wait >= 0
    assert pending == 0
    assert is_integer(mailbox) and mailbox >= 0
  end

  test "broker telemetry includes time spent waiting in the GenServer mailbox", %{root: root} do
    test_pid = self()

    handler =
      :telemetry.attach(
        "budget-broker-mailbox-#{inspect(test_pid)}",
        [:aiur, :github, :budget_broker, :command],
        fn event, measurements, metadata, pid ->
          send(pid, {event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    server = start_supervised!({BudgetBroker, name: __MODULE__.MailboxObserved}, id: :mailbox_observed)
    broker = Path.join(root, "mailbox.py")

    File.write!(broker, """
    import json, sys
    for line in sys.stdin:
        request = json.loads(line)
        print(json.dumps({"id": request["id"], "output": "ok", "status": 0}), flush=True)
    """)

    :ok = :sys.suspend(server)
    task = Task.async(fn -> command(server, broker, []) end)
    Process.sleep(40)
    :ok = :sys.resume(server)
    assert {:ok, "ok", 0} = Task.await(task)

    assert_receive {[:aiur, :github, :budget_broker, :command], %{mailbox_wait_ms: mailbox_wait}, %{outcome: :completed}}, 1_000
    assert mailbox_wait >= 30
  end

  test "a mailbox-expired call records that its deadline elapsed before dispatch", %{root: root} do
    test_pid = self()

    handler =
      :telemetry.attach(
        "budget-broker-mailbox-timeout-#{inspect(test_pid)}",
        [:aiur, :github, :budget_broker, :command],
        fn event, measurements, metadata, pid -> send(pid, {event, measurements, metadata}) end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    server = start_supervised!({BudgetBroker, name: __MODULE__.MailboxTimeout}, id: :mailbox_timeout)
    :ok = :sys.suspend(server)
    deadline = System.monotonic_time(:millisecond) + 20
    task = Task.async(fn -> BudgetBroker.command(server, Path.join(root, "not-started.py"), [], deadline) end)
    Process.sleep(50)
    :ok = :sys.resume(server)

    assert :timeout = Task.await(task)

    assert_receive {[:aiur, :github, :budget_broker, :command], %{mailbox_wait_ms: mailbox_wait}, %{outcome: :deadline_expired}}, 1_000
    assert mailbox_wait >= 30
  end

  test "late broker replies expose Python and SQLite timings after a caller timeout", %{root: root, server: server} do
    test_pid = self()

    handler =
      :telemetry.attach(
        "budget-broker-late-#{inspect(test_pid)}",
        [:aiur, :github, :budget_broker, :command],
        fn event, measurements, metadata, pid -> send(pid, {event, measurements, metadata}) end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    broker = Path.join(root, "late_reply.py")

    File.write!(broker, """
    import json, sys, time
    for line in sys.stdin:
        request = json.loads(line)
        time.sleep(0.08)
        print(json.dumps({"id": request["id"], "output": "ok", "status": 0, "python_queue_wait_ms": 4, "python_queue_depth": 2, "sqlite_open_ms": 3, "sqlite_lock_wait_ms": 11, "sqlite_transaction_ms": 7}), flush=True)
    """)

    deadline = System.monotonic_time(:millisecond) + 20
    assert :timeout = BudgetBroker.command(server, broker, [], deadline)

    assert_receive {[:aiur, :github, :budget_broker, :command], measurements, %{outcome: :late_response}}, 1_000
    assert measurements.python_queue_wait_ms == 4
    assert measurements.sqlite_lock_wait_ms == 11
    assert measurements.sqlite_transaction_ms == 7
  end

  test "resident Python broker reports inbox and SQLite stage durations", %{root: root, server: server} do
    test_pid = self()

    handler =
      :telemetry.attach(
        "budget-broker-stages-#{inspect(test_pid)}",
        [:aiur, :github, :budget_broker, :command],
        fn event, measurements, metadata, pid ->
          send(pid, {event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _output, 0} = command(server, Budget.broker_path(), ["snapshot" | common(root)])

    assert_receive {[:aiur, :github, :budget_broker, :command], measurements, %{outcome: :completed}}, 1_000
    assert is_number(measurements.python_queue_wait_ms)
    assert is_integer(measurements.python_queue_depth)
    assert is_number(measurements.sqlite_open_ms)
    assert is_number(measurements.sqlite_lock_wait_ms)
    assert is_number(measurements.sqlite_transaction_ms)
  end

  test "one-minute broker summary reports latency percentiles and timeout counts" do
    summary =
      BudgetBroker.summarize_stats([
        {:completed, %{duration_ms: 10, mailbox_wait_ms: 1, mailbox: 2, pending: 1, python_queue_wait_ms: 3, python_queue_depth: 4, sqlite_lock_wait_ms: 5, sqlite_transaction_ms: 6}},
        {:timeout, %{duration_ms: 100, mailbox_wait_ms: 20, mailbox: 8, pending: 3, python_queue_wait_ms: 30, python_queue_depth: 12, sqlite_lock_wait_ms: 40, sqlite_transaction_ms: 50}},
        {:late_response, %{late_duration_ms: 120, python_queue_wait_ms: 35, sqlite_lock_wait_ms: 45}}
      ])

    assert summary.commands == 2
    assert summary.timeouts == 1
    assert summary.late_responses == 1
    assert summary.duration_p50_ms == 10
    assert summary.duration_p99_ms == 100
    assert summary.late_duration_p99_ms == 120
    assert summary.mailbox_depth_max == 8
    assert summary.python_queue_depth_max == 12
    assert summary.sqlite_lock_wait_p99_ms == 45
    assert summary.sqlite_transaction_p99_ms == 50
  end

  defp command(server, broker, args), do: BudgetBroker.command(server, broker, args, System.monotonic_time(:millisecond) + 5_000)
  defp common(root), do: ["--db", Path.join(root, "budget.sqlite3"), "--token-key", "shared-key"]

  defp acquire_args(root) do
    [
      "acquire",
      "--resource",
      "core",
      "--consumer-key",
      "daemon",
      "--endpoint-family",
      "rest",
      "--max-inflight",
      "2",
      "--max-inflight-per-endpoint",
      "2",
      "--requests-per-minute",
      "10000",
      "--stagger-ms",
      "0",
      "--lease-ttl-ms",
      "30000"
    ] ++ common(root)
  end
end
