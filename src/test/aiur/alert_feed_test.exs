defmodule Aiur.AlertFeedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  describe "bounded ledger persistence" do
    test "compacts across the ceiling while retaining the newest alert and an unresolved attention", %{ledger: ledger} do
      attention = alert_line("ticket.42.agent.attention.scope", "2026-06-25T01:00:00Z", true, "active")
      history = alert_line("ticket.42.agent.progress", "2026-06-25T01:01:00Z", false, String.duplicate("h", 80))
      newest = alert("ticket.42.agent.phase.work.end", "2026-06-25T01:02:00Z", false, "newest")
      newest_line = encoded_line(newest)
      max_bytes = byte_size(attention) + byte_size(newest_line)

      write_ledger!(ledger, attention <> history)

      assert :ok = AlertLedger.append(newest, ledger_path: ledger, max_bytes: max_bytes)
      assert File.stat!(ledger).size <= max_bytes

      assert ["ticket.42.agent.attention.scope", "ticket.42.agent.phase.work.end"] == ledger_topics(ledger)
    end

    test "resolved attentions lose retention priority", %{ledger: ledger} do
      opened = alert_line("ticket.42.agent.attention.scope", "2026-06-25T01:00:00Z", true, String.duplicate("o", 80))
      resolved = alert_line("ticket.42.agent.attention.scope.resolved", "2026-06-25T01:01:00Z", false, "resolved")
      recent = alert_line("ticket.42.agent.progress", "2026-06-25T01:02:00Z", false, "recent")
      newest = alert("ticket.42.agent.phase.work.end", "2026-06-25T01:03:00Z", false, "newest")
      max_bytes = byte_size(recent) + byte_size(encoded_line(newest))

      write_ledger!(ledger, opened <> resolved <> recent)

      assert :ok = AlertLedger.append(newest, ledger_path: ledger, max_bytes: max_bytes)
      refute "ticket.42.agent.attention.scope" in ledger_topics(ledger)
      assert List.last(ledger_topics(ledger)) == "ticket.42.agent.phase.work.end"
    end

    test "warns and keeps the newest active attentions when actionable state exceeds the ceiling", %{ledger: ledger} do
      oldest = alert_line("ticket.1.agent.attention.scope", "2026-06-25T01:00:00Z", true, "oldest")
      middle = alert_line("ticket.2.agent.attention.scope", "2026-06-25T01:01:00Z", true, "middle")
      newest_active = alert_line("ticket.3.agent.attention.scope", "2026-06-25T01:02:00Z", true, "newest active")
      newest = alert("system.alert-ledger.compaction", "2026-06-25T01:03:00Z", false, "newest")
      max_bytes = byte_size(middle) + byte_size(newest_active) + byte_size(encoded_line(newest))

      write_ledger!(ledger, oldest <> middle <> newest_active)

      log =
        capture_log(fn ->
          assert :ok = AlertLedger.append(newest, ledger_path: ledger, max_bytes: max_bytes)
        end)

      assert log =~ "dropped_active_count=1"
      assert ledger_topics(ledger) == ["ticket.2.agent.attention.scope", "ticket.3.agent.attention.scope", "system.alert-ledger.compaction"]
    end

    test "keeps later active attentions that fit after rejecting an oversized candidate", %{ledger: ledger} do
      smaller = alert_line("ticket.1.agent.attention.scope", "2026-06-25T01:00:00Z", true, "small")
      oversized = alert_line("ticket.2.agent.attention.scope", "2026-06-25T01:01:00Z", true, String.duplicate("x", 200))
      newest = alert("system.alert-ledger.compaction", "2026-06-25T01:02:00Z", false, "newest")
      max_bytes = byte_size(smaller) + byte_size(encoded_line(newest))

      write_ledger!(ledger, smaller <> oversized)

      log =
        capture_log(fn ->
          assert :ok = AlertLedger.append(newest, ledger_path: ledger, max_bytes: max_bytes)
        end)

      assert log =~ "dropped_active_count=1"
      assert ledger_topics(ledger) == ["ticket.1.agent.attention.scope", "system.alert-ledger.compaction"]
    end

    test "rejects an indivisible alert larger than the ceiling without mutating the ledger", %{ledger: ledger} do
      original = alert_line("ticket.42.agent.progress", "2026-06-25T01:00:00Z", false, "original")
      oversized = alert("ticket.42.agent.progress", "2026-06-25T01:01:00Z", false, String.duplicate("x", 200))
      max_bytes = byte_size(encoded_line(oversized)) - 1
      write_ledger!(ledger, original)

      assert {:error, {:record_too_large, encoded_size, ^max_bytes}} =
               AlertLedger.append(oversized, ledger_path: ledger, max_bytes: max_bytes)

      assert encoded_size == byte_size(encoded_line(oversized))
      assert File.read!(ledger) == original
    end

    test "blocks concurrent compaction-triggering appends until the append lock is released", %{ledger: ledger} do
      old_history = alert_line("ticket.0.agent.progress", "2026-06-25T01:00:00Z", false, String.duplicate("h", 200))
      first = alert("ticket.1.agent.attention.scope", "2026-06-25T01:01:00Z", true, "first")
      second = alert("ticket.2.agent.attention.scope", "2026-06-25T01:02:00Z", true, "second")
      max_bytes = byte_size(encoded_line(first)) + byte_size(encoded_line(second))
      write_ledger!(ledger, old_history)

      parent = self()

      lock_holder =
        Task.async(fn ->
          AlertLedger.with_lock([ledger_path: ledger, lock_timeout: 5_000], fn ->
            send(parent, :append_lock_acquired)

            receive do
              :release_append_lock -> :ok
            end
          end)
        end)

      assert_receive :append_lock_acquired

      tasks =
        for record <- [first, second] do
          Task.async(fn ->
            send(parent, {:append_started, self()})
            AlertLedger.append(record, ledger_path: ledger, max_bytes: max_bytes, lock_timeout: 5_000)
          end)
        end

      for task <- tasks do
        assert_receive {:append_started, pid} when pid == task.pid
        assert Task.yield(task, 0) == nil
      end

      assert File.read!(ledger) == old_history

      send(lock_holder.pid, :release_append_lock)
      assert :ok = Task.await(lock_holder, 5_000)
      assert Enum.map(tasks, &Task.await(&1, 5_000)) == [:ok, :ok]
      assert MapSet.new(ledger_topics(ledger)) == MapSet.new([first["topic"], second["topic"]])
      assert File.stat!(ledger).size <= max_bytes
    end

    test "backfill compacts an oversized ledger even when its durable marker already exists", %{ledger: ledger} do
      old = alert_line("ticket.42.agent.progress", "2026-06-25T01:00:00Z", false, String.duplicate("o", 100))
      newest = alert_line("ticket.42.agent.phase.review.end", "2026-06-25T01:01:00Z", false, "newest")
      max_bytes = byte_size(newest)
      write_ledger!(ledger, old <> newest)
      assert :ok = AlertLedger.mark_backfilled(ledger_path: ledger)

      assert :ok = AlertFeed.backfill(roots: [], log_roots: [], ledger_path: ledger, max_bytes: max_bytes)
      assert File.stat!(ledger).size <= max_bytes
      assert ledger_topics(ledger) == ["ticket.42.agent.phase.review.end"]
    end
  end

  describe "bounded ledger reads" do
    test "reads only complete records from an oversized ledger tail and skips malformed lines", %{ledger: ledger} do
      old = alert_line("ticket.1.agent.progress", "2026-06-25T01:00:00Z", false, String.duplicate("o", 200))
      recent = alert_line("ticket.2.agent.progress", "2026-06-25T01:01:00Z", false, "recent")
      newest = alert_line("ticket.3.agent.progress", "2026-06-25T01:02:00Z", false, "newest")
      malformed = "not-json\n"
      max_bytes = byte_size(recent <> malformed <> newest) + 10
      write_ledger!(ledger, old <> recent <> malformed <> newest)

      assert Enum.map(AlertFeed.list(ledger_paths: [ledger], max_bytes: max_bytes), & &1["topic"]) == [
               "ticket.2.agent.progress",
               "ticket.3.agent.progress"
             ]
    end

    test "condition state and resolution dedupe use the retained tail", %{ledger: ledger} do
      old = alert_line("ticket.1.agent.progress", "2026-06-25T01:00:00Z", false, String.duplicate("o", 200))
      firing = alert_line("system.dispatch.prewarm_blocked", "2026-06-25T01:01:00Z", true, "blocked")
      resolution = alert_line("system.dispatch.prewarm_blocked.resolved", "2026-06-25T01:02:00Z", false, "ready")
      max_bytes = byte_size(firing <> resolution) + 10
      write_ledger!(ledger, old <> firing <> resolution)

      assert AlertFeed.condition_state("system.dispatch.prewarm_blocked", ledger_paths: [ledger], max_bytes: max_bytes) == :resolved
      assert AlertFeed.duplicate_resolution?("system.dispatch.prewarm_blocked.resolved", ledger_paths: [ledger], max_bytes: max_bytes)
    end
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

  defp alert(topic, timestamp, needs_attention, message) do
    %{
      "event" => "alert",
      "timestamp" => timestamp,
      "topic" => topic,
      "message" => message,
      "needs_attention" => needs_attention
    }
  end

  defp alert_line(topic, timestamp, needs_attention, message), do: encoded_line(alert(topic, timestamp, needs_attention, message))
  defp encoded_line(record), do: Jason.encode!(record) <> "\n"

  defp ledger_topics(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
    |> Enum.map(&Map.fetch!(&1, "topic"))
  end
end
