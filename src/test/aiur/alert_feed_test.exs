defmodule Aiur.AlertFeedTest do
  use ExUnit.Case, async: true

  alias Aiur.{AlertFeed, AlertLedger}

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-alert-feed-#{System.unique_integer([:positive])}")
    ledger = Path.join(root, "project.alerts.ndjson")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, ledger: ledger}
  end

  test "reads structured alert fields from the project ledger", %{ledger: ledger} do
    write_ledger!(ledger, """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"ticket.42.agent.paused","message":"Agent paused","reason":"operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"42","agent":"42"}
    """)

    assert [alert] = AlertFeed.list(ledger_paths: [ledger])
    assert alert["source_ticket_id"] == "42"
    assert alert["ticket"] == "42"
    assert alert["agent"] == "42"
    assert alert["topic"] == "ticket.42.agent.paused"
    assert alert["reason"] == "operator paused the agent"
    assert alert["severity"] == "warning"
    assert alert["needs_attention"]
  end

  test "collapses repeated open attentions and removes them after resolution", %{ledger: ledger} do
    write_ledger!(ledger, """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"ticket.42.agent.attention.scope","message":"first","needs_attention":true,"source_ticket_id":"42"}
    {"event":"alert","timestamp":"2026-06-25T01:01:00Z","topic":"ticket.42.agent.attention.scope","message":"latest","needs_attention":true,"source_ticket_id":"42"}
    {"event":"alert","timestamp":"2026-06-25T01:02:00Z","topic":"ticket.42.agent.attention.scope.resolved","message":"resolved","needs_attention":false,"source_ticket_id":"42"}
    """)

    assert [] = AlertFeed.list(ledger_paths: [ledger], needs_attention: true)
  end

  test "does not open workspace transcripts during a normal ledger read", %{root: root, ledger: ledger} do
    workspace_log = Path.join(root, "workspace/repo/42/logs/agent.ndjson")
    File.mkdir_p!(Path.dirname(workspace_log))
    assert {"", 0} = System.cmd("mkfifo", [workspace_log])

    write_ledger!(ledger, """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"ticket.42.agent.paused","message":"paused","needs_attention":true,"source_ticket_id":"42"}
    """)

    task = Task.async(fn -> AlertFeed.list(roots: [root], ledger_paths: [ledger], needs_attention: true) end)

    case Task.yield(task, 200) do
      {:ok, [%{"topic" => "ticket.42.agent.paused"}]} ->
        :ok

      nil ->
        Task.shutdown(task, :brutal_kill)
        flunk("normal AlertFeed reads must not open workspace transcripts")
    end
  end

  test "backfills legacy workspace alerts once outside normal reads", %{root: root, ledger: ledger} do
    legacy = Path.join(root, "repo/42/logs/agent.ndjson")
    File.mkdir_p!(Path.dirname(legacy))

    File.write!(legacy, """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"ticket.42.agent.attention.scope","message":"first","needs_attention":true,"source_ticket_id":"42"}
    {"event":"alert","timestamp":"2026-06-25T01:01:00Z","topic":"ticket.42.agent.attention.scope","message":"latest","needs_attention":true,"source_ticket_id":"42"}
    {"event":"alert","timestamp":"2026-06-25T01:02:00Z","topic":"ticket.42.agent.attention.scope.resolved","message":"resolved","needs_attention":false,"source_ticket_id":"42"}
    """)

    assert [] = AlertFeed.list(ledger_paths: [ledger], needs_attention: true)
    assert :ok = AlertFeed.backfill(roots: [root], log_roots: [], ledger_path: ledger)
    assert [] = AlertFeed.list(ledger_paths: [ledger], needs_attention: true)

    assert :ok = AlertFeed.backfill(roots: [root], log_roots: [], ledger_path: ledger)
    assert 3 == ledger |> File.stream!() |> Enum.count()
  end

  test "backfill does not duplicate alerts already written to the live ledger", %{root: root, ledger: ledger} do
    legacy = Path.join(root, "repo/42/logs/agent.ndjson")
    File.mkdir_p!(Path.dirname(legacy))

    event =
      "{\"event\":\"alert\",\"timestamp\":\"2026-06-25T01:00:00Z\",\"topic\":\"ticket.42.agent.paused\",\"message\":\"paused\",\"reason\":\"paused\",\"severity\":\"warning\",\"needs_attention\":true,\"source_ticket_id\":\"42\",\"agent\":\"42\"}\n"

    File.write!(legacy, event)
    write_ledger!(ledger, event)

    assert :ok = AlertFeed.backfill(roots: [root], log_roots: [], ledger_path: ledger)
    assert 1 == ledger |> File.stream!() |> Enum.count()
  end

  test "backfill keeps a distinct marker for a custom ledger filename", %{root: root} do
    ledger = Path.join(root, "ledger.ndjson")
    legacy = Path.join(root, "repo/42/logs/agent.ndjson")
    File.mkdir_p!(Path.dirname(legacy))
    File.write!(legacy, "{\"event\":\"alert\",\"topic\":\"ticket.42.agent.paused\",\"needs_attention\":true}\n")

    assert :ok = AlertFeed.backfill(roots: [root], log_roots: [], ledger_path: ledger)
    assert File.read!(ledger) =~ "\"event\":\"alert\""
    assert AlertLedger.backfilled?(ledger_path: ledger)
  end

  test "a failed ledger write leaves backfill pending for a later retry", %{root: root} do
    blocked = Path.join(root, "blocked")
    ledger = Path.join(blocked, "ledger.ndjson")
    legacy = Path.join(root, "repo/42/logs/agent.ndjson")
    File.mkdir_p!(root)
    File.write!(blocked, "not a directory")
    File.mkdir_p!(Path.dirname(legacy))
    File.write!(legacy, "{\"event\":\"alert\",\"topic\":\"ticket.42.agent.paused\",\"needs_attention\":true}\n")

    assert :ok = AlertFeed.backfill(roots: [root], log_roots: [], ledger_path: ledger)
    refute AlertLedger.backfilled?(ledger_path: ledger)
  end

  test "projects active decision attentions from the ledger", %{ledger: ledger} do
    write_ledger!(ledger, """
    {"event":"alert","timestamp":"2026-07-12T01:00:00Z","topic":"ticket.42.agent.attention.scope-question","reason":"Executor decision required: Which scope owns this?","needs_attention":true,"source_ticket_id":"42"}
    {"event":"alert","timestamp":"2026-07-12T01:00:30Z","topic":"ticket.42.agent.attention.scope-question","reason":"Executor decision required: Which scope owns this now?","needs_attention":true,"source_ticket_id":"42"}
    """)

    assert [%{identifier: "42", slug: "scope-question", question: "Which scope owns this now?", source_created_at: ~U[2026-07-12 01:00:00Z]}] =
             AlertFeed.list_decision_attentions(ledger_paths: [ledger])
  end

  defp write_ledger!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
