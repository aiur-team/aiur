defmodule Aiur.RunTelemetry.Dataset.LifecycleIntervalsTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Dataset

  @fixtures Path.expand("../../../fixtures/run_telemetry", __DIR__)

  test "derives closed, point, and open intervals by attempt and operation" do
    {:ok, dataset} = Dataset.build(@fixtures)
    intervals = dataset.tickets["930"].intervals

    assert Enum.any?(intervals, fn interval ->
             interval.phase == "implement" and interval.attempt_id == "attempt-a" and
               interval.status == "closed" and interval.duration_ms == 2_000
           end)

    assert Enum.any?(intervals, fn interval ->
             interval.phase == "build_test" and interval.attempt_id == "attempt-b" and
               interval.status == "closed" and interval.duration_ms == 3_000 and
               interval.outcome == "failed"
           end)

    assert Enum.any?(intervals, fn interval ->
             interval.phase == "implement" and interval.attempt_id == "attempt-b" and
               interval.status == "open" and interval.end_at == nil
           end)

    assert Enum.any?(intervals, &(&1.phase == "review_pause" and &1.status == "point"))
  end

  test "pairs lifecycle boundaries by durable file order across equal cross-boot clocks" do
    path = temporary_stream!()

    start =
      lifecycle_record(2, "build_test", "start", ~U[2026-07-11 01:00:00Z], "cross-boot")
      |> Map.put(:boot_id, "boot-z")
      |> Map.put(:record_id, "boot-z:2")

    finish =
      lifecycle_record(1, "build_test", "end", ~U[2026-07-11 01:00:00Z], "cross-boot")
      |> Map.put(:boot_id, "boot-a")
      |> Map.put(:record_id, "boot-a:1")

    File.write!(path, Enum.map_join([start, finish], "\n", &Jason.encode!/1) <> "\n")

    assert {:ok, dataset} = Dataset.build(path)
    assert [%{status: "closed", duration_ms: 0}] = dataset.tickets["940"].intervals
  end

  test "clamps reversed lifecycle endpoints without changing future endpoints" do
    path = temporary_stream!()

    start = lifecycle_record(1, "historical_end", "start", ~U[2026-07-11 01:00:00Z])

    reversed =
      lifecycle_record(2, "historical_end", "end", ~U[2020-01-01 00:00:00Z])

    future_start = lifecycle_record(3, "future_end", "start", ~U[2026-07-11 01:00:00Z])

    future_end =
      lifecycle_record(4, "future_end", "end", ~U[2030-01-01 00:00:00Z])

    File.write!(path, Enum.map_join([start, reversed, future_start, future_end], "\n", &Jason.encode!/1) <> "\n")

    assert {:ok, dataset} = Dataset.build(path)

    assert %{status: "closed", start_at: start_at, end_at: start_at, duration_ms: 0} =
             Enum.find(dataset.tickets["940"].intervals, &(&1.phase == "historical_end"))

    assert %{status: "closed", duration_ms: duration_ms, end_at: "2030-01-01T00:00:00Z"} =
             Enum.find(dataset.tickets["940"].intervals, &(&1.phase == "future_end"))

    assert duration_ms == DateTime.diff(~U[2030-01-01 00:00:00Z], ~U[2026-07-11 01:00:00Z], :millisecond)
  end

  test "classifies review wakeups as broken, resolved, or pending from real transitions" do
    {:ok, complete} =
      Dataset.build(@fixtures,
        now: ~U[2026-07-11 00:02:00Z],
        review_resume_grace_seconds: 20
      )

    assert %{status: "broken", missing: ["rework_start", "agent_resume"]} =
             Enum.find(complete.findings, &(&1.ticket == "930"))

    assert %{status: "resolved", missing: []} =
             Enum.find(complete.findings, &(&1.ticket == "931"))

    {:ok, pending} =
      Dataset.build(@fixtures,
        now: ~U[2026-07-11 00:00:10Z],
        review_resume_grace_seconds: 20
      )

    assert Enum.find(pending.findings, &(&1.ticket == "930")).status == "pending"
  end

  test "a carried dispatch replica collapses onto its retained original without a warning" do
    path = temporary_stream!()

    # A segment roll re-emits the boot's terminal points after the boundary
    # while the original segment is still retained, so both records coexist.
    # Neither carries a source_id or operation_id; the event key alone is the
    # identity that must fold them into one dispatch.
    persisted = [
      lifecycle_record(1, "dispatch", "point", ~U[2026-09-09 22:40:00Z], "dispatch-165", %{ticket: "165"}),
      %{
        restart_record("test-boot", ~U[2026-09-10 01:18:26Z])
        | sequence: 2,
          record_id: "test-boot:2",
          attributes: %{event: "segment_boundary", existing_records: true}
      },
      lifecycle_record(3, "dispatch", "point", ~U[2026-09-09 22:40:00Z], "dispatch-165", %{
        ticket: "165",
        segment_continuation: "carried"
      })
    ]

    File.write!(path, Enum.map_join(persisted, "\n", &Jason.encode!/1) <> "\n")

    assert {:ok, dataset} = Dataset.build(path)

    assert [%{event: "dispatch"}] = dataset.tickets["165"].events
    assert [%{phase: "dispatch"}] = dataset.tickets["165"].intervals
    assert dataset.warnings == []
  end

  test "keeps injected GitHub findings chronological with persisted lifecycle events" do
    path = temporary_stream!()

    persisted = [
      lifecycle_record(1, "review_pause", "point", ~U[2026-07-11 01:00:00Z]),
      lifecycle_record(2, "rework_start", "point", ~U[2026-07-11 01:00:02Z]),
      lifecycle_record(3, "agent_resume", "point", ~U[2026-07-11 01:00:03Z])
    ]

    File.write!(path, Enum.map_join(persisted, "\n", &Jason.encode!/1) <> "\n")

    github_events = [
      %{
        id: 702,
        topic: "ticket.940.issue.commented",
        source: :github,
        author_trusted?: true,
        comment: %{"id" => 91, "updated_at" => "2026-07-11T01:00:01Z", "body" => "review"}
      }
    ]

    assert {:ok, dataset} =
             Dataset.build(path,
               github_events: github_events,
               now: ~U[2026-07-11 01:10:00Z]
             )

    assert [%{status: "resolved", missing: []}] = dataset.findings
  end

  test "merge closes the review window and an early resume cannot resolve later rework" do
    path = temporary_stream!()

    records = [
      lifecycle_record(1, "review_pause", "point", ~U[2026-07-11 01:00:00Z]),
      lifecycle_record(2, "comment_received", "point", ~U[2026-07-11 01:00:01Z]),
      lifecycle_record(3, "pr_merged", "point", ~U[2026-07-11 01:00:02Z]),
      lifecycle_record(4, "rework_start", "point", ~U[2026-07-11 01:00:03Z]),
      lifecycle_record(5, "agent_resume", "point", ~U[2026-07-11 01:00:04Z])
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")

    {:ok, merged} = Dataset.build(path, now: ~U[2026-07-11 01:10:00Z])
    assert [%{status: "closed", missing: ["rework_start", "agent_resume"]}] = merged.findings

    reordered = [
      lifecycle_record(1, "review_pause", "point", ~U[2026-07-11 01:00:00Z]),
      lifecycle_record(2, "comment_received", "point", ~U[2026-07-11 01:00:01Z]),
      lifecycle_record(3, "agent_resume", "point", ~U[2026-07-11 01:00:02Z]),
      lifecycle_record(4, "rework_start", "point", ~U[2026-07-11 01:00:03Z])
    ]

    File.write!(path, Enum.map_join(reordered, "\n", &Jason.encode!/1) <> "\n")

    {:ok, out_of_order} =
      Dataset.build(path,
        now: ~U[2026-07-11 01:10:00Z],
        review_resume_grace_seconds: 1
      )

    assert [%{status: "broken", missing: ["agent_resume"]}] = out_of_order.findings
  end

  test "normalizes dispatch complexity and ignores malformed tiers" do
    path = temporary_stream!()

    records = [
      lifecycle_record(1, "dispatch", "point", ~U[2026-07-11 01:00:00Z], "complexity-string", %{complexity: "4"}),
      lifecycle_record(2, "agent_pause", "point", ~U[2026-07-11 01:00:01Z], "complexity-bad", %{complexity: "high"}),
      lifecycle_record(3, "dispatch", "point", ~U[2026-07-11 01:00:02Z], "complexity-out-of-range", %{ticket: "941", complexity: 6}),
      lifecycle_record(4, "build_test", "end", ~U[2026-07-11 01:00:03Z], "orphan-end", %{ticket: "941"})
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")

    assert {:ok, dataset} = Dataset.build(path)
    assert dataset.tickets["940"].complexity == 4
    assert Enum.find(dataset.tickets["940"].events, &(&1.event == "dispatch")).complexity == 4
    assert Enum.find(dataset.tickets["940"].events, &(&1.event == "agent_pause")).complexity == nil
    assert dataset.tickets["941"].complexity == nil
    assert Enum.any?(dataset.tickets["941"].intervals, &(&1.status == "orphan_end"))
  end

  test "preserves repeated runtime transitions while deduplicating replayable boundaries" do
    path = temporary_stream!()

    repeated = [
      lifecycle_record(1, "agent_pause", "point", ~U[2026-07-11 01:00:00Z], "same-runtime-key"),
      lifecycle_record(2, "agent_pause", "point", ~U[2026-07-11 01:01:00Z], "same-runtime-key")
    ]

    File.write!(path, Enum.map_join(repeated, "\n", &Jason.encode!/1) <> "\n")

    assert {:ok, dataset} = Dataset.build(path)
    assert Enum.count(dataset.tickets["940"].events, &(&1.event == "agent_pause")) == 2
    refute Enum.any?(dataset.warnings, &(&1.type == :duplicate_lifecycle_boundary))

    replayable = [
      lifecycle_record(3, "comment_received", "point", ~U[2026-07-11 01:02:00Z], "same-source-key", %{
        source_id: "comment:1"
      }),
      lifecycle_record(4, "comment_received", "point", ~U[2026-07-11 01:02:01Z], "same-source-key", %{
        source_id: "comment:1"
      }),
      lifecycle_record(5, "agent_pause", "point", ~U[2026-07-11 01:03:00Z])
    ]

    File.write!(path, Enum.map_join(replayable, "\n", &Jason.encode!/1) <> "\n")

    assert {:ok, deduplicated} = Dataset.build(path)
    assert Enum.count(deduplicated.tickets["940"].events, &(&1.event == "comment_received")) == 1
    assert Enum.any?(deduplicated.warnings, &(&1.type == :duplicate_lifecycle_boundary))
    refute Enum.any?(deduplicated.warnings, &(&1.type == :sequence_gap))
  end

  test "does not reuse a completed review pause for later comments" do
    path = temporary_stream!()

    records = [
      lifecycle_record(1, "review_pause", "point", ~U[2026-07-11 01:00:00Z]),
      lifecycle_record(2, "comment_received", "point", ~U[2026-07-11 01:00:01Z], "comment-1", %{source_id: "comment:1"}),
      lifecycle_record(3, "rework_start", "point", ~U[2026-07-11 01:00:02Z]),
      lifecycle_record(4, "agent_resume", "point", ~U[2026-07-11 01:00:03Z]),
      lifecycle_record(5, "comment_received", "point", ~U[2026-07-11 01:00:04Z], "comment-2", %{source_id: "comment:2"})
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")

    assert {:ok, dataset} = Dataset.build(path, now: ~U[2026-07-11 01:10:00Z])
    assert [%{status: "resolved", comment_source_id: "comment:1"}] = dataset.findings
  end

  defp temporary_stream! do
    root = Aiur.TestSupport.tmp_root!("aiur-dataset")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Path.join(root, "telemetry.ndjson")
  end

  defp lifecycle_record(sequence, event, boundary, timestamp, event_key \\ nil, extra_attributes \\ %{}) do
    event_key = event_key || "event-#{sequence}"

    %{
      schema_version: 1,
      kind: "lifecycle",
      timestamp: DateTime.to_iso8601(timestamp),
      recorded_at: DateTime.to_iso8601(timestamp),
      boot_id: "test-boot",
      sequence: sequence,
      record_id: "test-boot:#{sequence}",
      attributes:
        Map.merge(
          %{
            ticket: "940",
            attempt_id: "attempt-1",
            event: event,
            boundary: boundary,
            event_key: event_key
          },
          extra_attributes
        )
    }
  end

  defp restart_record(boot_id, timestamp) do
    %{
      schema_version: 1,
      kind: "restart",
      timestamp: DateTime.to_iso8601(timestamp),
      recorded_at: DateTime.to_iso8601(timestamp),
      boot_id: boot_id,
      sequence: 1,
      record_id: "#{boot_id}:1",
      attributes: %{event: "daemon_restart"}
    }
  end
end
