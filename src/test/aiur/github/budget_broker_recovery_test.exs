defmodule Aiur.GitHub.BudgetBrokerRecoveryTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Access.{Settings, StaticSettings}
  alias Aiur.GitHub.{Budget, BudgetBroker, Tracker}
  alias Aiur.TestSupport.Isolation

  @moduletag :tmp_dir
  @topic "system.github.budget_ledger_recovery"

  test "startup reindexes a damaged index and preserves the ledger", %{tmp_dir: root} do
    db = Path.join(root, "budget.sqlite3")
    {:ok, "granted " <> lease, 0} = one_shot(db, acquire_args())
    corrupt_index(db)

    server = start_broker(:startup_index)
    assert {:ok, _, 0} = command(server, db, ["release", "--lease-id", lease])
    assert_receive {:recovery, @topic, alert}, 1_000
    assert alert[:message] =~ "reindexed and passed integrity check"
    assert alert[:reason] =~ "missing from index leases_token_family"
    assert alert[:needs_attention]
    assert sql(db, "print(db.execute('PRAGMA integrity_check').fetchone()[0])") == "ok"
    assert {:ok, json, 0} = command(server, db, ["snapshot"])
    assert %{"admissions" => [_], "inflight" => %{}} = Jason.decode!(json)
    assert Path.wildcard(db <> ".corrupt-*") == []
  end

  test "a corrupt index fails the current ledger write and the next tracker write succeeds", %{tmp_dir: root} do
    db = Path.join(root, "budget.sqlite3")
    configure_tracker(root)
    server = Process.whereis(BudgetBroker)
    assert {:ok, "granted " <> lease, 0} = command(server, db, acquire_args())
    release = ["release", "--lease-id", String.trim(lease)]
    port = :sys.get_state(server).port
    corrupt_index(db)

    assert {:ok, "database disk image is malformed", 1} = command(server, db, release)
    assert_receive {:recovery, @topic, alert}, 1_000
    assert alert[:message] =~ "reindexed and passed integrity check"
    assert :sys.get_state(server).port == port
    assert {:ok, _, 0} = command(server, db, release)
    assert sql(db, "print(db.execute('PRAGMA integrity_check').fetchone()[0])") == "ok"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/repos/owner/repo/issues"
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42"})
    end)

    assert {:ok, %{"number" => 42}} = Tracker.create_issue(%{title: "Recovered write", body: "", labels: []}, token: "test-token")
    assert {:ok, json, 0} = command(server, db, ["snapshot"])
    assert %{"admissions" => [_, _], "inflight" => %{}} = Jason.decode!(json)
  end

  test "table corruption archives the old ledger and rebuilds with a resident peer open", %{tmp_dir: root} do
    db = Path.join(root, "budget.sqlite3")
    peer = start_broker(:archive_peer)
    assert {:ok, "granted " <> _, 0} = command(peer, db, acquire_args())
    peer_port = :sys.get_state(peer).port

    assert sql(db, """
           db.executescript('''
             CREATE TABLE damaged (amount INTEGER CHECK (amount >= 0));
             PRAGMA ignore_check_constraints = ON;
             INSERT INTO damaged VALUES (-1);
             PRAGMA ignore_check_constraints = OFF;
           ''')
           print(db.execute('PRAGMA integrity_check').fetchone()[0])
           """) == "CHECK constraint failed in damaged"

    server = start_broker(:archive_table)
    assert {:ok, "granted " <> _, 0} = command(server, db, acquire_args())
    assert_receive {:recovery, @topic, alert}, 1_000
    assert alert[:needs_attention]
    assert alert[:reason] == "CHECK constraint failed in damaged"
    assert [archive] = Path.wildcard(db <> ".corrupt-*")
    assert alert[:message] =~ "rebuilt, with corrupt files saved in #{archive}"
    archived_db = Path.join(archive, Path.basename(db))
    assert sql(archived_db, "print(db.execute('SELECT amount FROM damaged').fetchone()[0])") == "-1"
    assert sql(db, "print(db.execute('PRAGMA integrity_check').fetchone()[0])") == "ok"
    assert {:ok, json, 0} = command(peer, db, ["snapshot"])
    assert %{"admissions" => [_], "inflight" => %{"issues" => 1}} = Jason.decode!(json)
    assert :sys.get_state(peer).port == peer_port
  end

  defp start_broker(name) do
    parent = self()
    server_name = Module.concat(__MODULE__, name)
    start_supervised!({BudgetBroker, name: server_name, alert_fun: fn topic, alert -> send(parent, {:recovery, topic, alert}) end}, id: name)
  end

  defp configure_tracker(root) do
    parent = self()
    settings = Settings.new(root, budget_dir: root, repo: "owner/repo", alert_sink: fn topic, alert -> send(parent, {:recovery, topic, alert}) end)

    for {key, value} <- [
          github_access_settings_provider: StaticSettings,
          github_access_settings: settings,
          github_quota_server: __MODULE__.DisabledQuota,
          github_transport_test_options: [plug: {Req.Test, __MODULE__}]
        ] do
      Isolation.with_app_env!(:aiur, key, value)
    end
  end

  defp command(server, db, args) do
    BudgetBroker.command(server, Budget.broker_path(), args ++ common(db), System.monotonic_time(:millisecond) + 5_000)
  end

  defp one_shot(db, args) do
    {output, status} = System.cmd("python3", [Budget.broker_path() | args ++ common(db)])
    {:ok, String.trim(output), status}
  end

  defp common(db), do: ["--db", db, "--token-key", Budget.token_key("test-token")]

  defp acquire_args do
    [
      "acquire",
      "--resource",
      "core",
      "--consumer-key",
      "test",
      "--endpoint-family",
      "issues",
      "--max-inflight",
      "4",
      "--max-inflight-per-endpoint",
      "2",
      "--requests-per-minute",
      "1000",
      "--stagger-ms",
      "0",
      "--lease-ttl-ms",
      "30000"
    ]
  end

  defp corrupt_index(db) do
    # Build keys from the wrong column, then restore the original definition.
    assert sql(db, """
           version = db.execute('PRAGMA schema_version').fetchone()[0]
           db.executescript(f'''
             PRAGMA writable_schema = ON;
             UPDATE sqlite_schema SET sql = 'CREATE INDEX leases_token_family ON leases(token_key, lease_id)'
               WHERE name = 'leases_token_family';
             PRAGMA writable_schema = OFF;
             PRAGMA schema_version = {version + 1};
             REINDEX leases_token_family;
             PRAGMA writable_schema = ON;
             UPDATE sqlite_schema SET sql = 'CREATE INDEX leases_token_family ON leases(token_key, endpoint_family)'
               WHERE name = 'leases_token_family';
             PRAGMA writable_schema = OFF;
             PRAGMA schema_version = {version + 2};
           ''')
           print(db.execute('PRAGMA integrity_check').fetchone()[0])
           """) == "row 1 missing from index leases_token_family"
  end

  defp sql(path, script) do
    prefix = "import sqlite3, sys\ndb = sqlite3.connect(sys.argv[1], isolation_level=None)\n"
    assert {output, 0} = System.cmd("python3", ["-c", prefix <> script, path], stderr_to_stdout: true)
    String.trim(output)
  end
end
