defmodule Aiur.GitHub.BudgetLedgerTest do
  @moduledoc """
  The broker admission ledger, read directly.

  The page's zero-fetch guarantee extends to this module: reading the ledger
  must never create an admission, so the tests here also assert that a read
  leaves the seeded rows untouched. `snapshot/1` takes a `:database_path`, so
  each test gets its own seeded database and never touches a host broker.
  """

  use ExUnit.Case, async: true

  alias Aiur.GitHub.BudgetLedger
  alias Exqlite.Basic

  @admissions """
  CREATE TABLE admissions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_key TEXT NOT NULL,
    consumer_key TEXT NOT NULL DEFAULT '',
    lease_id TEXT,
    endpoint_family TEXT NOT NULL,
    admitted_at_ms INTEGER NOT NULL,
    billable INTEGER NOT NULL DEFAULT 1
  )
  """

  @policies """
  CREATE TABLE policies (
    token_key TEXT NOT NULL,
    consumer_key TEXT NOT NULL,
    consumer_label TEXT NOT NULL DEFAULT '',
    max_inflight INTEGER NOT NULL,
    max_inflight_per_endpoint INTEGER NOT NULL,
    requests_per_minute INTEGER NOT NULL,
    stagger_ms INTEGER NOT NULL,
    core_limit_per_hour INTEGER NOT NULL DEFAULT 0,
    graphql_limit_per_hour INTEGER NOT NULL DEFAULT 0,
    observed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (token_key, consumer_key)
  )
  """

  setup do
    path = Aiur.TestSupport.tmp_root!("aiur-budget-ledger") <> ".sqlite3"
    {:ok, conn} = Basic.open(path)
    _ = Basic.exec(conn, @admissions)
    _ = Basic.exec(conn, @policies)
    Basic.close(conn)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  defp seed(path, rows) do
    {:ok, conn} = Basic.open(path)

    for {consumer, family, billable, admitted_at} <- rows do
      _ =
        Basic.exec(
          conn,
          "INSERT INTO admissions(token_key, consumer_key, endpoint_family, admitted_at_ms, billable) VALUES (?, ?, ?, ?, ?)",
          ["t", consumer, family, admitted_at, billable]
        )
    end

    Basic.close(conn)
    :ok
  end

  test "reads billable and 304-free admissions by consumer and family", %{path: path} do
    now = System.system_time(:millisecond)

    seed(path, [
      {"daemon:node@host", "graphql", 1, now - 1_000},
      {"daemon:node@host", "graphql", 0, now - 2_000},
      {"workspace:/x/1", "pulls", 1, now - 3_000},
      {"workspace:/x/1", "pulls", 1, now - 4_000},
      {"workspace:/x/1", "issues", 0, now - 5_000}
    ])

    snapshot = BudgetLedger.snapshot(database_path: path, now_ms: now)

    assert snapshot.available?
    assert snapshot.admission_count == 5
    assert snapshot.billable == 3
    assert snapshot.free == 2

    assert snapshot.by_family["graphql"] == %{billable: 1, free: 1}
    assert snapshot.by_family["pulls"] == %{billable: 2, free: 0}
    assert snapshot.by_family["issues"] == %{billable: 0, free: 1}

    assert snapshot.by_consumer["daemon:node@host"] == %{billable: 1, free: 1}
    assert snapshot.by_consumer["workspace:/x/1"] == %{billable: 2, free: 1}

    rows = snapshot.rows
    assert {"daemon:node@host", "graphql", 1, 1} in Enum.map(rows, &{&1.consumer, &1.family, &1.billable, &1.free})
    assert {"workspace:/x/1", "pulls", 2, 0} in Enum.map(rows, &{&1.consumer, &1.family, &1.billable, &1.free})
    assert {"workspace:/x/1", "issues", 0, 1} in Enum.map(rows, &{&1.consumer, &1.family, &1.billable, &1.free})
  end

  test "falls back to the consumer key when no policy row names the consumer", %{path: path} do
    now = System.system_time(:millisecond)
    seed(path, [{"a-consumer-key-fingerprint", "rest", 1, now - 1_000}])

    snapshot = BudgetLedger.snapshot(database_path: path, now_ms: now)

    assert snapshot.by_consumer["a-consumer-key-fingerprint"] == %{billable: 1, free: 0}
    assert [%{consumer: "a-consumer-key-fingerprint", family: "rest", billable: 1, free: 0}] = snapshot.rows
  end

  test "drops admissions outside the rolling hour", %{path: path} do
    now = System.system_time(:millisecond)

    seed(path, [
      {"daemon:node@host", "graphql", 1, now - 1_000},
      {"daemon:node@host", "core", 1, now - BudgetLedger.window_ms() - 1_000}
    ])

    snapshot = BudgetLedger.snapshot(database_path: path, now_ms: now)

    assert snapshot.admission_count == 1
    assert snapshot.by_family["core"] == nil
  end

  test "reading never creates an admission", %{path: path} do
    now = System.system_time(:millisecond)
    seed(path, [{"daemon:node@host", "graphql", 1, now - 1_000}])

    before = BudgetLedger.snapshot(database_path: path, now_ms: now)
    _read = BudgetLedger.snapshot(database_path: path, now_ms: now)
    after_read = BudgetLedger.snapshot(database_path: path, now_ms: now)

    assert before.admission_count == after_read.admission_count
  end

  test "the ledger is pinned read-only so a read can never write an admission" do
    # `snapshot().admission_count == snapshot().admission_count` would hold for
    # any read implementation, including one that opened the database read-write
    # and just happened not to write. This module touches the broker's live
    # ledger, so the mechanism — `PRAGMA query_only = ON` — is pinned: a future
    # change that drops the guard fails here rather than silently letting a
    # page read write an admission.
    code =
      "../../../lib/aiur/github/budget_ledger.ex"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> String.replace(~r/@(?:module)?doc\s+"""(?:.|\n)*?"""/, "")
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.join("\n")

    assert code =~ "PRAGMA query_only = ON",
           "budget_ledger.ex no longer opens the ledger read-only; the page's zero-fetch proof is lost"
  end

  test "a missing database reads as unavailable, never as zero", %{path: path} do
    File.rm(path)
    snapshot = BudgetLedger.snapshot(database_path: path)

    assert snapshot.available? == false
    assert snapshot.admission_count == nil
    assert snapshot.rows == []
  end
end
