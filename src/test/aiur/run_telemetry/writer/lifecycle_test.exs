defmodule Aiur.RunTelemetry.Writer.LifecycleTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.{Exchange, GithubFirehose}
  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.{Dataset, Lifecycle, Writer}
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  setup do
    root =
      Aiur.TestSupport.tmp_root!("aiur-telemetry-writer")

    path = Path.join(root, "log/telemetry.ndjson")
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: path, root: root}
  end

  test "segment rolls preserve lifecycle interval pairing", %{path: path} do
    retention = [max_bytes: 1, prune_interval_bytes: 1]
    boundary_at = ~U[2026-07-11 12:00:01Z]

    {:ok, writer} =
      Writer.start_link(
        name: nil,
        path: path,
        boot_id: "lifecycle-roll",
        retention: retention,
        clock: fn -> boundary_at end
      )

    start = %{
      ticket: "1339",
      attempt_id: "attempt",
      event: "build_test",
      boundary: "start",
      operation_id: "build"
    }

    finish = %{
      ticket: "1339",
      attempt_id: "attempt",
      event: "build_test",
      boundary: "end",
      operation_id: "build"
    }

    assert :ok = Writer.record(writer, :lifecycle, start, timestamp: ~U[2026-07-11 12:00:00Z])
    assert :ok = Writer.record(writer, :lifecycle, finish, timestamp: ~U[2026-07-11 12:00:02Z])
    assert :ok = Writer.flush(writer)

    assert {:ok, dataset} = Dataset.build(path)
    assert [%{status: "closed"}] = dataset.tickets["1339"].intervals
    assert dataset.warnings == []
  end

  test "backward writer clocks cannot reorder queued lifecycle endpoints", %{path: path} do
    {:ok, clock_state} =
      Agent.start_link(fn ->
        [
          ~U[2026-07-11 12:00:00Z],
          ~U[2026-07-11 12:00:00Z],
          ~U[2026-07-11 12:00:00Z],
          ~U[2026-07-11 12:00:00Z],
          ~U[2020-01-01 00:00:00Z]
        ]
      end)

    clock = fn -> Agent.get_and_update(clock_state, fn [timestamp | rest] -> {timestamp, rest} end) end

    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "backward-clock", clock: clock)

    start = %{ticket: "1341", attempt_id: "attempt", event: "build_test", boundary: "start", operation_id: "build"}
    finish = %{ticket: "1341", attempt_id: "attempt", event: "build_test", boundary: "end", operation_id: "build"}

    assert :ok = Writer.record(writer, :lifecycle, start, timestamp: ~U[2026-07-11 12:00:00Z])
    assert :ok = Writer.record(writer, :lifecycle, finish, timestamp: ~U[2026-07-11 12:00:01Z])
    assert :ok = Writer.flush(writer)

    assert {:ok, dataset} = Dataset.build(path)
    assert [%{status: "closed"}] = dataset.tickets["1341"].intervals
  end

  test "malformed and historical lifecycle endpoints are validated and clamped", %{path: path} do
    clock = fn -> ~U[2026-07-11 12:00:00Z] end
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "endpoint-guards", clock: clock)

    start = %{ticket: "1342", attempt_id: "attempt", event: "build_test", boundary: "start", operation_id: "build"}
    finish = %{ticket: "1342", attempt_id: "attempt", event: "build_test", boundary: "end", operation_id: "build"}

    assert :ok = Writer.record(writer, :lifecycle, start, timestamp: ~U[2026-07-11 12:00:00Z])
    assert :ok = Writer.record(writer, :lifecycle, finish, timestamp: "not-a-timestamp")
    assert :ok = Writer.flush(writer)

    assert {:ok, dataset} = Dataset.build(path)
    assert [%{status: "closed", duration_ms: 0, end_at: "2026-07-11T12:00:00Z"}] = dataset.tickets["1342"].intervals
  end

  test "a merge observed before a segment roll still counts for the live boot after the roll", %{path: path} do
    # Every append rolls a segment and prunes the previous one, the shape a boot
    # takes once it outgrows max_bytes (a warning flood did this on a live daemon
    # and the run-scoped counters forgot a merge the graph still showed, #2603).
    boot_id = RunTelemetry.boot_id()

    {:ok, writer} =
      Writer.start_link(
        name: nil,
        path: path,
        boot_id: boot_id,
        retention: [max_bytes: 1, prune_interval_bytes: 1],
        clock: fn -> ~U[2026-09-10 01:40:16Z] end
      )

    recorder = fn kind, attributes, opts -> Writer.record(writer, kind, attributes, opts) end
    attempt = Lifecycle.new_attempt_id("165")

    :ok = Lifecycle.record("165", attempt, :dispatch, :point, %{complexity: 2}, recorder: recorder, timestamp: ~U[2026-09-09 22:40:00Z])
    :ok = Lifecycle.record("165", attempt, :pr_opened, :point, %{pr_number: 177}, recorder: recorder, timestamp: ~U[2026-09-09 23:10:00Z])

    # The live merge exactly as the Exchange subscription hands it to the writer.
    merge_event = %{
      id: 900,
      topic: "ticket.165.pr.merged",
      source: :github,
      action: "closed",
      pr: %{"number" => 177, "merged" => true, "merged_at" => "2026-09-09T23:46:54Z", "user" => %{"login" => "its-applekid"}}
    }

    send(writer, {:event, merge_event})

    # Unrelated traffic after the merge: each append rolls and prunes again.
    for index <- 1..3 do
      :ok = Writer.record(writer, :resource, %{actor: "_daemon", rss_bytes: index}, timestamp: ~U[2026-09-10 01:41:00Z])
    end

    assert :ok = Writer.flush(writer)

    records = read_records(path)
    boundaries = Enum.count(records, &(&1["attributes"]["event"] == "segment_boundary"))
    assert boundaries >= 2, "expected the boot to have rolled segments"

    assert {:ok, dataset} = Dataset.build(path, session: :current, boot_id: boot_id)
    current = Dataset.filter(dataset, boot_id: boot_id)

    ticket = Map.fetch!(current.tickets, "165")
    assert Enum.any?(ticket.intervals, &(&1.phase == "pr_merged"))
    assert Enum.any?(ticket.intervals, &(&1.phase == "dispatch"))
    refute Enum.any?(current.warnings, &(&1.type == :duplicate_lifecycle_boundary))

    model = Presenter.model(current, cap: 4, cores: 4, host_mem_bytes: 1_000_000_000, buckets: 10)
    assert model.kpis.merged == 1
    assert model.kpis.total == 1
    assert [%{id: "165", status: :merged, merged_at: merged_at}] = model.tickets
    assert merged_at == DateTime.to_unix(~U[2026-09-09 23:46:54Z], :millisecond)

    assert {:ok, loaded} = Presenter.load(telemetry_file: path, session: :current)
    assert loaded.kpis.merged == 1
  end

  test "invalid caller timestamps do not make segment boundaries unprunable", %{path: path} do
    retention = [max_bytes: 1, prune_interval_bytes: 1]
    future_clock = fn -> ~U[2026-07-11 12:00:10Z] end

    {:ok, writer} =
      Writer.start_link(
        name: nil,
        path: path,
        boot_id: "invalid-timestamp-roll",
        clock: future_clock,
        retention: retention
      )

    for sample <- 1..40 do
      assert :ok = Writer.record(writer, :resource, %{sample: sample}, timestamp: "not-a-timestamp")
    end

    assert :ok = Writer.flush(writer)

    records = read_records(path)
    boundaries = Enum.filter(records, &(&1["kind"] == "restart" and &1["attributes"]["event"] == "segment_boundary"))

    assert boundaries != []
    assert Enum.all?(boundaries, &match?({:ok, _timestamp, 0}, DateTime.from_iso8601(&1["timestamp"])))
    assert File.stat!(path).size < 10_000
  end

  test "old caller timestamps do not reorder lifecycle intervals or age boundaries", %{path: path} do
    retention = [max_bytes: 1, prune_interval_bytes: 1]
    future_clock = fn -> ~U[2026-07-11 12:00:10Z] end
    start_timestamp = ~U[2020-01-01 00:00:00Z]
    finish_timestamp = ~U[2020-01-01 00:00:01Z]

    {:ok, writer} =
      Writer.start_link(
        name: nil,
        path: path,
        boot_id: "old-timestamp-roll",
        clock: future_clock,
        retention: retention
      )

    start = %{ticket: "1340", attempt_id: "attempt", event: "build_test", boundary: "start", operation_id: "build"}
    finish = %{ticket: "1340", attempt_id: "attempt", event: "build_test", boundary: "end", operation_id: "build"}

    assert :ok = Writer.record(writer, :lifecycle, start, timestamp: start_timestamp)
    assert :ok = Writer.record(writer, :lifecycle, finish, timestamp: finish_timestamp)
    assert :ok = Writer.flush(writer)

    assert {:ok, dataset} = Dataset.build(path)
    assert [%{status: "closed"}] = dataset.tickets["1340"].intervals
    refute Enum.any?(dataset.tickets["1340"].intervals, &(&1.status in ["orphan_end", "open"]))

    records = read_records(path)
    boundaries = Enum.filter(records, &(&1["kind"] == "restart" and &1["attributes"]["event"] == "segment_boundary"))
    assert Enum.all?(boundaries, &(&1["timestamp"] == "2026-07-11T12:00:10Z"))
  end

  test "backfills a pre-boot merged PR as a telemetry lifecycle anchor", %{path: path} do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "anchors")
    :ok = Exchange.subscribe("ticket.930.pr.merged")

    firehose_event = %{
      "id" => "merged-100",
      "type" => "PullRequestEvent",
      "created_at" => "2026-07-11T13:01:00Z",
      "actor" => %{"login" => "merger"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "merged",
        "pull_request" => %{
          "number" => 77,
          "head" => %{"ref" => "aiur/930-analytics", "sha" => "head-77"}
        }
      }
    }

    assert {:ok, %{count: 0}} =
             GithubFirehose.poll(
               request_fun: fn _request ->
                 {:ok, %{status: 200, headers: [{"ETag", ~s("writer-merge")}], body: [firehose_event]}}
               end,
               recent_merge_fun: fn _merge -> {:ok, :stored} end,
               boot_time: ~U[2026-07-11 13:03:00Z] |> DateTime.to_unix(),
               telemetry_writer: writer
             )

    assert :ok = Writer.flush(writer)
    refute_receive {:event, %{topic: "ticket.930.pr.merged"}}, 100

    records = read_records(path)
    [merged] = Enum.take(records, -1)

    assert merged["kind"] == "lifecycle"
    assert merged["timestamp"] == "2026-07-11T13:01:00Z"
    assert merged["attributes"]["event"] == "pr_merged"
    assert merged["attributes"]["pr_number"] == 77
    assert merged["attributes"]["source"] == "github_reconciliation"

    # The anchor stays durable for full-log reconciliation, but a dashboard
    # scoped to this daemon boot must not call a historical merge "this run".
    assert {:ok, dataset} = Dataset.build(path, session: :current, boot_id: "anchors")
    current = Dataset.filter(dataset, boot_id: "anchors")
    refute Enum.any?(current.records, &(&1.attributes["event"] == "pr_merged"))
    assert current.tickets == %{}
  end

  test "persists a live merged PR received through the firehose exchange", %{path: path} do
    {:ok, writer} = Writer.start_link(name: nil, path: path, boot_id: "live-anchors")

    firehose_event = %{
      "id" => "live-merged-100",
      "type" => "PullRequestEvent",
      "created_at" => "2026-07-11T13:01:00Z",
      "actor" => %{"login" => "merger"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "merged",
        "pull_request" => %{
          "number" => 77,
          "head" => %{"ref" => "aiur/930-analytics", "sha" => "live-head-77"}
        }
      }
    }

    assert {:ok, %{count: 1}} =
             GithubFirehose.poll(
               request_fun: fn _request ->
                 {:ok, %{status: 200, headers: [{"ETag", ~s("live-writer-merge")}], body: [firehose_event]}}
               end,
               recent_merge_fun: fn _merge -> {:ok, :stored} end,
               boot_time: ~U[2026-07-11 13:00:00Z] |> DateTime.to_unix()
             )

    assert :ok = Writer.flush(writer)

    records = read_records(path)
    [merged] = Enum.take(records, -1)

    assert merged["kind"] == "lifecycle"
    assert merged["timestamp"] == "2026-07-11T13:01:00Z"
    assert merged["attributes"]["event"] == "pr_merged"
    assert merged["attributes"]["pr_number"] == 77
    assert merged["attributes"]["source"] == "github"

    assert {:ok, dataset} = Dataset.build(path, session: :current, boot_id: "live-anchors")
    current = Dataset.filter(dataset, boot_id: "live-anchors")
    assert Enum.any?(current.records, &(&1.attributes["event"] == "pr_merged"))
    assert Map.has_key?(current.tickets, "930")
  end

  defp read_records(path) do
    path
    |> File.stream!([], :line)
    |> Enum.map(&Jason.decode!/1)
  end
end
