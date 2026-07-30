defmodule Aiur.RunTelemetry.DatasetTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Dataset

  @fixtures Path.expand("../../fixtures/run_telemetry", __DIR__)

  test "discovers and merges multi-boot telemetry while retaining tolerant warnings" do
    assert {:ok, dataset} =
             Dataset.build([@fixtures],
               now: ~U[2026-07-11 00:02:00Z],
               review_resume_grace_seconds: 20
             )

    assert dataset.provenance.files == [
             Path.join(@fixtures, "session-a/telemetry.ndjson"),
             Path.join(@fixtures, "session-b/telemetry.ndjson")
           ]

    assert dataset.provenance.schema_versions == [1]

    assert dataset.provenance.time_range == %{
             start: "2026-07-11T00:00:00Z",
             end: "2026-07-11T00:01:06Z"
           }

    assert Enum.map(dataset.restarts, & &1.boot_id) == ["boot-a", "boot-b"]
    warning_types = MapSet.new(dataset.warnings, & &1.type)

    assert MapSet.subset?(
             MapSet.new([
               :malformed_line,
               :unsupported_schema,
               :unknown_kind,
               :missing_fields
             ]),
             warning_types
           )
  end

  test "resource profiles exclude unavailable values and flag within-boot gaps" do
    {:ok, dataset} = Dataset.build(@fixtures)
    daemon = dataset.actors["_daemon"]
    operator = dataset.actors["_operator"]

    assert daemon.profile["rss_bytes"] == %{
             count: 3,
             min: 100,
             mean: 300.0,
             median: 300,
             p95: 500,
             max: 500
           }

    assert daemon.profile["cpu_percent"].count == 3
    assert Enum.any?(daemon.gaps, &(&1.boot_id == "boot-a" and &1.duration_ms == 10_000))
    assert operator.profile == %{}
    assert operator.availability.unavailable == 1
    assert operator.availability.measured == 0
  end

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

  test "normalizes optional GitHub anchors and rejects ineligible comments" do
    github_events = [
      %{
        id: 700,
        topic: "ticket.932.pr.opened",
        source: :github,
        pr: %{"number" => 80, "created_at" => "2026-07-11T00:01:30Z"}
      },
      %{
        id: 701,
        topic: "ticket.932.issue.commented",
        source: :github,
        author_trusted?: false,
        comment: %{"id" => 90, "updated_at" => "2026-07-11T00:01:31Z", "body" => "ignore"}
      }
    ]

    {:ok, dataset} = Dataset.build(@fixtures, github_events: github_events)

    assert Enum.any?(dataset.tickets["932"].events, &(&1.event == "pr_opened"))
    refute Enum.any?(dataset.tickets["932"].events, &(&1.event == "comment_received"))
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

  test "returns an explicit error when no telemetry file exists" do
    empty = Path.join(System.tmp_dir!(), "aiur-empty-dataset-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)

    assert {:error, {:no_telemetry_files, [^empty]}} = Dataset.build(empty)
  end

  test "current-session reads stop at the newest boot boundary" do
    path = temporary_stream!()

    old_records =
      for sequence <- 1..5_000 do
        lifecycle_record(sequence, "old_event", "point", ~U[2026-07-11 01:00:00Z], "old-#{sequence}")
        |> Map.put(:boot_id, "old-boot")
        |> Map.put(:record_id, "old-boot:#{sequence}")
      end

    current_records = [
      restart_record("current-boot", ~U[2026-07-11 02:00:00Z]),
      lifecycle_record(2, "current_event", "point", ~U[2026-07-11 02:00:01Z], "current-event")
      |> Map.put(:boot_id, "current-boot")
      |> Map.put(:record_id, "current-boot:2")
    ]

    File.write!(path, Enum.map_join(old_records ++ current_records, "\n", &Jason.encode!/1) <> "\n")

    assert {:ok, dataset} = Dataset.build(path, session: :current)
    assert Dataset.boot_ids(dataset) == ["current-boot"]
    assert Enum.map(dataset.records, & &1.record_id) == ["current-boot:1", "current-boot:2"]
    assert dataset.warnings == []
  end

  test "current-session retains valid records beside a malformed trailing line" do
    path = temporary_stream!()

    records = [
      restart_record("current-boot", ~U[2026-07-11 02:00:00Z]),
      lifecycle_record(2, "current_event", "point", ~U[2026-07-11 02:00:01Z], "current-event")
      |> Map.put(:boot_id, "current-boot")
      |> Map.put(:record_id, "current-boot:2")
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\nnot-json\n")

    assert {:ok, dataset} = Dataset.build(path, session: :current)
    assert Enum.map(dataset.records, & &1.record_id) == ["current-boot:1", "current-boot:2"]
    assert [%{type: :malformed_line}] = dataset.warnings
  end

  test "current-session bounds an unterminated tail line" do
    path = temporary_stream!()
    File.write!(path, String.duplicate("x", 1_048_577))

    assert {:ok, dataset} = Dataset.build(path, session: :current)
    assert dataset.records == []
    assert [%{type: :tail_line_too_large, max_bytes: 1_048_576}] = dataset.warnings
  end

  defp temporary_stream! do
    root = Path.join(System.tmp_dir!(), "aiur-dataset-#{System.unique_integer([:positive])}")
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

  describe "filter/2" do
    test "boot_ids/1 lists every session in the stream, oldest first" do
      {:ok, dataset} = Dataset.build(@fixtures)

      assert Dataset.boot_ids(dataset) == ["boot-a", "boot-b"]
    end

    test "scoping to one session keeps only that boot's records" do
      {:ok, dataset} = Dataset.build(@fixtures)

      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      assert scoped.records |> Enum.map(& &1.boot_id) |> Enum.uniq() == ["boot-b"]
      assert Enum.map(scoped.restarts, & &1.boot_id) == ["boot-b"]
    end

    test "an actor with no samples in the session is dropped rather than kept empty" do
      {:ok, dataset} = Dataset.build(@fixtures)

      assert Map.has_key?(dataset.actors, "_operator")

      # The operator only sampled during boot-a; a zero-sample shell would render
      # as a real actor burning nothing.
      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      refute Map.has_key?(scoped.actors, "_operator")
      assert Map.has_key?(scoped.actors, "_daemon")
    end

    test "per-actor statistics are recomputed from the surviving samples" do
      {:ok, dataset} = Dataset.build(@fixtures)
      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      full = get_in(dataset.actors, ["_daemon", :profile, "cpu_percent", :count])
      session = get_in(scoped.actors, ["_daemon", :profile, "cpu_percent", :count])

      assert session < full
      assert session == length(scoped.actors["_daemon"].samples)
    end

    test "a ticket whose lifecycle predates the session drops out of the scope" do
      {:ok, dataset} = Dataset.build(@fixtures)

      assert Map.has_key?(dataset.tickets, "931")

      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      refute Map.has_key?(scoped.tickets, "931")
      assert Map.has_key?(scoped.tickets, "930")
    end

    test "surviving lifecycle intervals are re-paired within the session" do
      {:ok, dataset} = Dataset.build(@fixtures)
      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      phases = scoped.tickets["930"].intervals |> Enum.map(& &1.phase) |> Enum.uniq() |> Enum.sort()

      assert "build_test" in phases
      assert Enum.all?(scoped.tickets["930"].events, &(&1.boot_id == "boot-b"))
    end

    test "scoping to a ticket set keeps the shared baseline actors" do
      {:ok, dataset} = Dataset.build(@fixtures)

      scoped = Dataset.filter(dataset, tickets: MapSet.new(["930"]))

      assert Map.keys(scoped.tickets) == ["930"]
      # Daemon and executor cost is orchestration overhead, not per-ticket cost,
      # so it is never filtered away with the tickets.
      assert Map.has_key?(scoped.actors, "_daemon")
      assert Map.has_key?(scoped.actors, "_operator")
    end

    test "scoping to an empty ticket set yields no tickets rather than every ticket" do
      {:ok, dataset} = Dataset.build(@fixtures)

      scoped = Dataset.filter(dataset, tickets: MapSet.new())

      assert scoped.tickets == %{}
    end

    test "provenance is rescoped so the window reflects the filtered records" do
      {:ok, dataset} = Dataset.build(@fixtures)
      scoped = Dataset.filter(dataset, boot_id: "boot-b")

      assert scoped.provenance.record_count == length(scoped.records)
      assert scoped.provenance.time_range.start >= dataset.provenance.time_range.start
    end

    test "no options is a no-op" do
      {:ok, dataset} = Dataset.build(@fixtures)

      assert Dataset.filter(dataset, []) == dataset
    end
  end
end
