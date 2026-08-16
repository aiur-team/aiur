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

  test "collapses a backlog of repeated resolutions down to the transition that opened it", %{ledger: ledger} do
    write_ledger!(ledger, """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"system.github.quota.core.exhausted","message":"exhausted","needs_attention":true}
    {"event":"alert","timestamp":"2026-06-25T01:01:00Z","topic":"system.github.quota.core.exhausted.resolved","message":"cleared; 4905 of 5000 requests remain","needs_attention":false}
    {"event":"alert","timestamp":"2026-06-25T01:02:00Z","topic":"system.github.quota.core.exhausted.resolved","message":"cleared; 4905 of 5000 requests remain","needs_attention":false}
    {"event":"alert","timestamp":"2026-06-25T01:03:00Z","topic":"system.github.quota.core.exhausted.resolved","message":"cleared; 4905 of 5000 requests remain","needs_attention":false}
    """)

    assert [resolution] = AlertFeed.list(ledger_paths: [ledger])
    assert resolution["topic"] == "system.github.quota.core.exhausted.resolved"
    assert resolution["timestamp"] == "2026-06-25T01:01:00Z"
  end

  test "keeps a resolution that follows a genuine re-fire", %{ledger: ledger} do
    write_ledger!(ledger, """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"system.github.quota.core.exhausted","message":"exhausted","needs_attention":true}
    {"event":"alert","timestamp":"2026-06-25T01:01:00Z","topic":"system.github.quota.core.exhausted.resolved","message":"cleared","needs_attention":false}
    {"event":"alert","timestamp":"2026-06-25T01:02:00Z","topic":"system.github.quota.core.exhausted.resolved","message":"cleared","needs_attention":false}
    {"event":"alert","timestamp":"2026-06-25T01:03:00Z","topic":"system.github.quota.core.exhausted","message":"exhausted again","needs_attention":true}
    {"event":"alert","timestamp":"2026-06-25T01:04:00Z","topic":"system.github.quota.core.exhausted.resolved","message":"cleared again","needs_attention":false}
    """)

    assert [first, second] = AlertFeed.list(ledger_paths: [ledger])
    assert first["timestamp"] == "2026-06-25T01:01:00Z"
    assert second["timestamp"] == "2026-06-25T01:04:00Z"
  end

  describe "condition_state/2 and duplicate_resolution?/2" do
    test "report the ledger's current position in the firing cycle", %{ledger: ledger} do
      assert AlertFeed.condition_state("system.dispatch.prewarm_blocked", ledger_paths: [ledger]) == :unknown
      refute AlertFeed.duplicate_resolution?("system.dispatch.prewarm_blocked.resolved", ledger_paths: [ledger])

      write_ledger!(ledger, """
      {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"system.dispatch.prewarm_blocked","message":"blocked","needs_attention":true}
      """)

      assert AlertFeed.condition_state("system.dispatch.prewarm_blocked", ledger_paths: [ledger]) == :firing
      refute AlertFeed.duplicate_resolution?("system.dispatch.prewarm_blocked.resolved", ledger_paths: [ledger])

      File.write!(
        ledger,
        ~s({"event":"alert","timestamp":"2026-06-25T01:01:00Z","topic":"system.dispatch.prewarm_blocked.resolved","message":"ready","needs_attention":false}\n),
        [:append]
      )

      assert AlertFeed.condition_state("system.dispatch.prewarm_blocked", ledger_paths: [ledger]) == :resolved
      assert AlertFeed.duplicate_resolution?("system.dispatch.prewarm_blocked.resolved", ledger_paths: [ledger])
    end

    test "never treat a non-resolution topic as a duplicate", %{ledger: ledger} do
      write_ledger!(ledger, """
      {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"system.dispatch.prewarm_blocked.resolved","message":"ready","needs_attention":false}
      """)

      refute AlertFeed.duplicate_resolution?("system.dispatch.prewarm_blocked", ledger_paths: [ledger])
      refute AlertFeed.duplicate_resolution?(".resolved", ledger_paths: [ledger])
    end
  end

  test "does not open workspace transcripts during a normal default-ledger read", %{root: root} do
    workspace_log = Path.join(root, "workspace/repo/42/logs/agent.ndjson")
    File.mkdir_p!(Path.dirname(workspace_log))
    assert {"", 0} = System.cmd("mkfifo", [workspace_log])

    ledger = AlertLedger.path(log_roots: [root])

    write_ledger!(ledger, """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"ticket.42.agent.paused","message":"paused","needs_attention":true,"source_ticket_id":"42"}
    """)

    task = Task.async(fn -> AlertFeed.list(roots: [root], log_roots: [root], needs_attention: true) end)

    case Task.yield(task, 1_000) do
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

  test "backfill does not duplicate alerts mirrored in workspace and central logs", %{root: root, ledger: ledger} do
    legacy = Path.join(root, "repo/42/logs/agent.ndjson")
    central = Path.join(root, "alerts.ndjson")
    File.mkdir_p!(Path.dirname(legacy))

    event =
      "{\"event\":\"alert\",\"timestamp\":\"2026-06-25T01:00:00Z\",\"topic\":\"ticket.42.agent.paused\",\"message\":\"paused\",\"reason\":\"paused\",\"severity\":\"warning\",\"needs_attention\":true,\"source_ticket_id\":\"42\",\"agent\":\"42\"}\n"

    File.write!(legacy, event)
    File.write!(central, String.replace(event, ~s(,"agent":"42"), ""))

    assert :ok = AlertFeed.backfill(roots: [root], log_roots: [root], ledger_path: ledger)
    assert 1 == ledger |> File.stream!() |> Enum.count()
  end

  test "backfill keeps legacy alert bytes while normalizing presentation", %{root: root, ledger: ledger} do
    legacy = Path.join(root, "repo/42/logs/agent.ndjson")
    File.mkdir_p!(Path.dirname(legacy))

    File.write!(legacy, "{\"event\":\"alert\",\"topic\":\"ticket.42.agent.attention.scope\",\"message\":\"Operator decision required\",\"needs_attention\":true}\n")

    assert :ok = AlertFeed.backfill(roots: [root], log_roots: [], ledger_path: ledger)
    assert File.read!(ledger) =~ "Operator decision required"
    assert [%{"message" => "Executor decision required"}] = AlertFeed.list(ledger_paths: [ledger])
  end

  test "missing resolution timestamps sort after timestamped opens", %{ledger: ledger} do
    write_ledger!(ledger, """
    {"event":"alert","topic":"ticket.42.agent.attention.scope.resolved","needs_attention":false,"source_ticket_id":"42","timestamp":null}
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"ticket.42.agent.attention.scope","needs_attention":true,"source_ticket_id":"42"}
    """)

    assert [] = AlertFeed.list(ledger_paths: [ledger], needs_attention: true)
  end

  test "attention probes retain central-only scope", %{ledger: ledger} do
    write_ledger!(ledger, """
    {"event":"alert","topic":"system.test.workspace_only","needs_attention":true,"agent":"42"}
    {"event":"alert","topic":"system.test.central","needs_attention":true,"agent":"system"}
    """)

    refute AlertFeed.active_system_attention?("system.test.workspace_only", ledger_paths: [ledger])
    assert AlertFeed.active_system_attention?("system.test.central", ledger_paths: [ledger])
  end

  test "backfill lock does not block ledger appends", %{ledger: ledger} do
    parent = self()

    task =
      Task.async(fn ->
        AlertLedger.with_backfill_lock([ledger_path: ledger], fn ->
          send(parent, :backfill_lock_acquired)

          receive do
            :release_backfill_lock -> :ok
          end
        end)
      end)

    assert_receive :backfill_lock_acquired
    assert :ok = AlertLedger.append(%{"topic" => "ticket.42.agent.paused"}, ledger_path: ledger)
    send(task.pid, :release_backfill_lock)
    assert :ok = Task.await(task)
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
