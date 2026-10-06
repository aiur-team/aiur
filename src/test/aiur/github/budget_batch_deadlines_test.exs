defmodule Aiur.GitHub.BudgetBatchDeadlinesTest do
  use ExUnit.Case, async: true

  for scenario <- ["lock", "commit", "margin"] do
    @scenario scenario
    test "expired request remains isolated during #{@scenario}" do
      root = Aiur.TestSupport.tmp_root!("batch-deadlines")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      script = """
      import importlib.util, json, sqlite3, sys
      spec = importlib.util.spec_from_file_location("broker", sys.argv[1])
      broker = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(broker)
      broker.SESSION_CONNECTIONS = {}
      db = sys.argv[2] + "/budget.sqlite3"
      conn = broker.connection(db)
      clock = [1000]
      broker.now_ms = lambda: clock[0]
      def timed_acquire(args):
          broker.acquire(args)
          if args.consumer_key == "short" and sys.argv[3] in ("commit", "margin"):
              clock[0] = 1070 if sys.argv[3] == "margin" else 1120
      requests = []
      for n, consumer, deadline in [(1, "short", 1100), (2, "long", 2000)]:
          args = broker.parser().parse_args(["acquire", "--db", db, "--token-key", "shared",
              "--consumer-key", consumer, "--resource", "core", "--endpoint-family", "rest",
              "--max-inflight", "2", "--max-inflight-per-endpoint", "2",
              "--requests-per-minute", "10000", "--stagger-ms", "0", "--lease-ttl-ms", "30000"])
          args.fun = timed_acquire
          requests.append(({"id": n, "deadline_ms": deadline}, args))
      if sys.argv[3] == "lock":
          lock = sqlite3.connect(db, isolation_level=None)
          lock.execute("BEGIN IMMEDIATE")
          def unlock(delay):
              clock[0] = 1120
              lock.execute("ROLLBACK")
          broker.time.sleep = unlock
      replies = broker.run_transaction(db, requests)
      external = sqlite3.connect(db)
      print(json.dumps({"statuses": {str(r["id"]): r["status"] for r in replies},
                        "leases": external.execute("SELECT COUNT(*) FROM leases").fetchone()[0],
                        "consumers": [row[0] for row in external.execute("SELECT consumer_key FROM admissions")]}))
      """

      {output, 0} = System.cmd("python3", ["-c", script, Path.expand("../../../priv/github_budget.py", __DIR__), root, @scenario])
      assert Jason.decode!(output) == %{"statuses" => %{"1" => 2, "2" => 0}, "leases" => 1, "consumers" => ["long"]}
    end
  end
end
