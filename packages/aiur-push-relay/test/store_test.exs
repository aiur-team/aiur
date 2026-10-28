defmodule AiurPushRelay.StoreTest do
  use ExUnit.Case, async: true
  alias AiurPushRelay.Store.SQLite

  test "registry and dedupe survive reopen, then expire after 24 hours" do
    path = Path.join(System.tmp_dir!(), "relay-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    db = Path.join(path, "db")
    pid = start_supervised!({SQLite, path: db})

    row = %{
      handle: "h_test",
      platform: "apns",
      push_token: "token",
      app_topic: "test",
      environment: "sandbox",
      send_secret_sha256: :crypto.hash(:sha256, "secret"),
      created_at: 100
    }

    e = %{"idempotency_key" => "key", "sealed" => "opaque"}
    assert SQLite.create(pid, row) == :ok
    assert SQLite.reserve(pid, row, e, 100) == :new
    stop_supervised!(SQLite)
    pid = start_supervised!({SQLite, path: db})
    assert {:ok, stored} = SQLite.get(pid, row.handle)
    assert stored.push_token == "token"
    assert SQLite.reserve(pid, row, e, 86_499) == {:duplicate, 202}
    assert SQLite.reserve(pid, row, e, 86_500) == :new
    assert SQLite.reserve(pid, row, Map.put(e, "idempotency_key", "later"), 700_000) == :new
    {:ok, conn} = Exqlite.Sqlite3.open(db)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT count(*) FROM send_log")
    assert Exqlite.Sqlite3.fetch_all(conn, stmt) == {:ok, [[1]]}
    Exqlite.Sqlite3.release(conn, stmt)
    Exqlite.Sqlite3.close(conn)
  end

  test "corrupt database refuses startup" do
    path = Path.join(System.tmp_dir!(), "relay-corrupt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    db = Path.join(path, "db")
    File.write!(db, "not a database")
    assert {:error, {:store_unavailable, _}} = start_supervised({SQLite, path: db})
  end
end
